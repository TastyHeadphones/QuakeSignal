use crate::domain::SourceId;
use crate::normalize;
use crate::pipeline;
use crate::wolfx_types::*;
use crate::AppState;
use futures_util::{SinkExt, StreamExt};
use std::collections::HashMap;
use std::time::Duration;
use tauri::{AppHandle, Emitter, Manager};
use tokio::time::Instant;
use tokio_tungstenite::tungstenite::Message;

/// Desktop is intentionally serverless: every source connection goes
/// straight from the native app to Wolfx. No QuakeSignal backend, account,
/// device registration, or Cloudflare endpoint is involved.
const WS_BASE: &str = "wss://ws-api.wolfx.jp";
/// The same public HTTPS source endpoints used by the iOS foreground client.
/// This is a data snapshot fallback only; Cloudflare/APNs is never involved in
/// the desktop's direct-to-Wolfx monitoring path.
const HTTP_BASE: &str = "https://api.wolfx.jp";
/// Mirrors backend/src/wolfx/client.ts exactly: 1s floor, 30s ceiling,
/// doubling on every failed/dropped connection, reset on a fresh connect.
const RECONNECT_MIN_MS: u64 = 1_000;
const RECONNECT_MAX_MS: u64 = 30_000;
const CONNECT_TIMEOUT_SECS: u64 = 15;
/// Not present in the backend (Node's WS 'close' event is reliable enough
/// server-side); added here because a long-lived desktop tray app is more
/// likely to sit behind a laptop sleep/wake or flaky wifi, where a dead
/// socket can go quiet without ever firing an error. The server heartbeats
/// every ~60s per docs/WOLFX_API.md, so 90s gives it a safe margin.
const READ_TIMEOUT_SECS: u64 = 90;
/// Wait for the normal WebSocket reconnection loop before starting an HTTP
/// snapshot. This avoids immediately doubling upstream traffic during a brief
/// Wi-Fi transition or laptop wake.
const HTTP_SNAPSHOT_OUTAGE_GRACE_SECS: u64 = 90;
/// A complete snapshot can contain seven requests, so keep degraded-mode
/// refreshes deliberately sparse. This is only active while one or more
/// sockets are down.
const HTTP_SNAPSHOT_REPEAT_SECS: u64 = 300;
const HTTP_SNAPSHOT_REQUEST_TIMEOUT_SECS: u64 = 20;
const HTTP_SNAPSHOT_HEALTH_CHECK_SECS: u64 = 5;
/// Wolfx documents a two-requests-per-second public API ceiling. Serializing
/// fallback sources with a small margin prevents a single degraded refresh
/// from producing an upstream burst.
const HTTP_SNAPSHOT_REQUEST_INTERVAL_MILLIS: u64 = 600;

/// HTTP snapshots are always historical/backfill data. They update the local
/// database and UI but are never allowed to generate an alarm, notification,
/// or foreground alert window.
const HTTP_SNAPSHOT_IS_BACKFILL: bool = true;

#[derive(Clone, Copy)]
enum Route {
    CombinedEew,
    Single(SourceId),
}

pub fn spawn_all(app: AppHandle) {
    // Wolfx exposes the five EEW sources on one combined socket. Using it
    // keeps the desktop app within the upstream concurrent-connection limit;
    // opening seven separate sockets causes some handshakes to return 503.
    spawn_route(app.clone(), Route::CombinedEew);
    for source in SourceId::REPORTS {
        spawn_route(app.clone(), Route::Single(source));
    }
    spawn_http_snapshot_fallback(app);
}

fn spawn_route(app: AppHandle, route: Route) {
    tauri::async_runtime::spawn(async move {
        run_route(app, route).await;
    });
}

/// Watches the normal WebSocket health map and fetches only the sources whose
/// sockets are unavailable. It deliberately has no push/notification path:
/// the regular HTTP payload parsers feed every result through the existing
/// pipeline as a backfill snapshot.
fn spawn_http_snapshot_fallback(app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        run_http_snapshot_fallback(app).await;
    });
}

async fn run_http_snapshot_fallback(app: AppHandle) {
    let client = match build_http_snapshot_client() {
        Ok(client) => client,
        Err(error) => {
            log::warn!("HTTP snapshot fallback could not create its HTTPS client: {error}");
            return;
        }
    };

    let mut outage_started_at: Option<Instant> = None;
    let mut next_snapshot_at: Option<Instant> = None;

    loop {
        if !has_unavailable_websocket_source(&app) {
            // All sockets recovered: cancel the degraded schedule completely.
            // The next outage receives a fresh grace period rather than inheriting
            // the previous snapshot cadence.
            outage_started_at = None;
            next_snapshot_at = None;
            tokio::time::sleep(Duration::from_secs(HTTP_SNAPSHOT_HEALTH_CHECK_SECS)).await;
            continue;
        }

        let now = Instant::now();
        let outage_start = *outage_started_at.get_or_insert(now);
        let due_at = *next_snapshot_at.get_or_insert_with(|| {
            outage_start + Duration::from_secs(HTTP_SNAPSHOT_OUTAGE_GRACE_SECS)
        });

        if now < due_at {
            let remaining = due_at.saturating_duration_since(now);
            tokio::time::sleep(remaining.min(Duration::from_secs(HTTP_SNAPSHOT_HEALTH_CHECK_SECS)))
                .await;
            continue;
        }

        log::warn!("Wolfx WebSocket remains degraded; refreshing unavailable sources over HTTPS");
        fetch_unavailable_http_snapshots(&app, &client).await;
        next_snapshot_at = Some(Instant::now() + Duration::from_secs(HTTP_SNAPSHOT_REPEAT_SECS));
    }
}

fn build_http_snapshot_client() -> Result<reqwest::Client, reqwest::Error> {
    // The WebSocket client and this HTTPS fallback deliberately share a
    // process-wide Ring provider. `run()` installs it before any background
    // task starts; this idempotent call also keeps the client builder safe for
    // unit tests and future non-app entry points.
    let _ = rustls::crypto::ring::default_provider().install_default();

    reqwest::Client::builder()
        .https_only(true)
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(HTTP_SNAPSHOT_REQUEST_TIMEOUT_SECS))
        .timeout(Duration::from_secs(HTTP_SNAPSHOT_REQUEST_TIMEOUT_SECS))
        .user_agent(concat!("QuakeSignal/", env!("CARGO_PKG_VERSION")))
        .build()
}

async fn fetch_unavailable_http_snapshots(app: &AppHandle, client: &reqwest::Client) {
    let unavailable_sources: Vec<_> = SourceId::ALL
        .into_iter()
        .filter(|source| !is_source_websocket_connected(app, *source))
        .collect();
    let source_count = unavailable_sources.len();

    for (index, source) in unavailable_sources.into_iter().enumerate() {
        // Stop immediately if every socket recovers during the staggered
        // refresh. Each source is re-checked because it may independently
        // reconnect while an earlier request is in flight.
        if !has_unavailable_websocket_source(app) {
            return;
        }
        if !is_source_websocket_connected(app, source) {
            fetch_http_snapshot(app, client, source).await;
        }
        if index + 1 < source_count {
            tokio::time::sleep(Duration::from_millis(HTTP_SNAPSHOT_REQUEST_INTERVAL_MILLIS)).await;
        }
    }
}

async fn fetch_http_snapshot(app: &AppHandle, client: &reqwest::Client, source: SourceId) {
    let url = format!("{HTTP_BASE}/{}.json", source.as_str());
    let response = match client.get(&url).send().await {
        Ok(response) => response,
        Err(error) => {
            log::warn!("{}: HTTP snapshot request failed: {error}", source.as_str());
            return;
        }
    };

    let response = match response.error_for_status() {
        Ok(response) => response,
        Err(error) => {
            log::warn!(
                "{}: HTTP snapshot returned an unsuccessful status: {error}",
                source.as_str()
            );
            return;
        }
    };

    let body = match response.text().await {
        Ok(body) => body,
        Err(error) => {
            log::warn!(
                "{}: could not read HTTP snapshot body: {error}",
                source.as_str()
            );
            return;
        }
    };

    // A recovered source can have received a newer WebSocket revision while
    // its HTTP request was in flight. Discard this delayed snapshot instead of
    // potentially replacing a live value with a stale one.
    if is_source_websocket_connected(app, source) {
        return;
    }

    ingest_http_snapshot(app, source, &body);
}

async fn run_route(app: AppHandle, route: Route) {
    let path = match route {
        Route::CombinedEew => "all_eew",
        Route::Single(source) => source.as_str(),
    };
    let url = format!("{WS_BASE}/{path}");
    let mut backoff_ms = RECONNECT_MIN_MS;

    loop {
        log::info!("{path}: connecting");
        let connection = tokio::time::timeout(
            Duration::from_secs(CONNECT_TIMEOUT_SECS),
            tokio_tungstenite::connect_async(&url),
        )
        .await;
        match connection {
            Ok(Ok((mut stream, _response))) => {
                log::info!("{path}: connected");
                backoff_ms = RECONNECT_MIN_MS;
                set_route_connected(&app, route, true);

                // Wolfx sockets otherwise wait for the next upstream change.
                // Query the current snapshots so the local database and UI
                // are useful immediately after launch. These first replies
                // are classified as backfill and never trigger an alarm.
                let queries: &[&str] = match route {
                    Route::CombinedEew => &[
                        "query_jmaeew",
                        "query_sceew",
                        "query_cenceew",
                        "query_fjeew",
                        "query_cqeew",
                    ],
                    Route::Single(SourceId::CencEqlist) => &["query_cenceqlist"],
                    Route::Single(SourceId::JmaEqlist) => &["query_jmaeqlist"],
                    Route::Single(_) => &[],
                };
                for query in queries {
                    if let Err(error) = stream.send(Message::Text((*query).to_string())).await {
                        log::warn!("{path}: initial query failed: {error}");
                        break;
                    }
                }

                loop {
                    let next =
                        tokio::time::timeout(Duration::from_secs(READ_TIMEOUT_SECS), stream.next())
                            .await;
                    match next {
                        Ok(Some(Ok(Message::Text(text)))) => route_message(&app, route, &text),
                        Ok(Some(Ok(_))) => { /* ignore binary/ping/pong/close frames */ }
                        Ok(Some(Err(e))) => {
                            log::warn!("{path}: read error: {e}");
                            break;
                        }
                        Ok(None) => {
                            log::info!("{path}: stream closed by server");
                            break;
                        }
                        Err(_) => {
                            log::warn!("{path}: no data for {READ_TIMEOUT_SECS}s, reconnecting");
                            break;
                        }
                    }
                }
            }
            Ok(Err(e)) => {
                log::warn!("{path}: connect failed: {e}");
            }
            Err(_) => {
                log::warn!("{path}: connection timed out after {CONNECT_TIMEOUT_SECS}s");
            }
        }
        set_route_connected(&app, route, false);
        tokio::time::sleep(Duration::from_millis(backoff_ms)).await;
        backoff_ms = (backoff_ms * 2).min(RECONNECT_MAX_MS);
    }
}

fn route_message(app: &AppHandle, route: Route, text: &str) {
    match route {
        Route::Single(source) => handle_message(app, source, text),
        Route::CombinedEew => {
            let source = serde_json::from_str::<serde_json::Value>(text)
                .ok()
                .and_then(|value| value.get("type")?.as_str().and_then(source_from_type));
            if let Some(source) = source {
                handle_message(app, source, text);
            }
        }
    }
}

fn source_from_type(kind: &str) -> Option<SourceId> {
    match kind {
        "jma_eew" => Some(SourceId::JmaEew),
        "sc_eew" => Some(SourceId::ScEew),
        "cenc_eew" => Some(SourceId::CencEew),
        "fj_eew" => Some(SourceId::FjEew),
        "cq_eew" => Some(SourceId::CqEew),
        _ => None,
    }
}

fn set_route_connected(app: &AppHandle, route: Route, connected: bool) {
    match route {
        Route::CombinedEew => {
            for source in SourceId::EEW {
                set_connected(app, source, connected, false);
            }
            let _ = app.emit("quake-status", ());
        }
        Route::Single(source) => set_connected(app, source, connected, true),
    }
}

fn set_connected(app: &AppHandle, source: SourceId, connected: bool, emit: bool) {
    let state = app.state::<AppState>();
    state
        .connection_status
        .lock()
        .unwrap()
        .insert(source.as_str().to_string(), connected);
    if emit {
        let _ = app.emit("quake-status", ());
    }
}

fn has_unavailable_websocket_source(app: &AppHandle) -> bool {
    let state = app.state::<AppState>();
    let statuses = state.connection_status.lock().unwrap();
    has_unavailable_source_status(&statuses)
}

fn is_source_websocket_connected(app: &AppHandle, source: SourceId) -> bool {
    let state = app.state::<AppState>();
    let statuses = state.connection_status.lock().unwrap();
    statuses.get(source.as_str()).copied().unwrap_or(false)
}

fn has_unavailable_source_status(statuses: &HashMap<String, bool>) -> bool {
    SourceId::ALL
        .into_iter()
        .any(|source| !statuses.get(source.as_str()).copied().unwrap_or(false))
}

fn has_ranked_keys(value: &serde_json::Value) -> bool {
    value
        .as_object()
        .map(|o| o.keys().any(|k| k.starts_with("No")))
        .unwrap_or(false)
}

/// Routes one text frame after the connection layer identifies its source.
fn handle_message(app: &AppHandle, source: SourceId, text: &str) {
    // Mirrors the seedFromHttp/manager.ts boot-seeding logic: the first data
    // message a source delivers this run is treated as backfill so we never
    // fire a "new" notification for a warning that was already in progress
    // before the app started.
    let state = app.state::<AppState>();
    let is_backfill = state
        .seeded_sources
        .lock()
        .unwrap()
        .insert(source.as_str().to_string());

    ingest_source_payload(app, source, text, is_backfill, "WebSocket");
}

fn ingest_http_snapshot(app: &AppHandle, source: SourceId, text: &str) {
    ingest_source_payload(
        app,
        source,
        text,
        HTTP_SNAPSHOT_IS_BACKFILL,
        "HTTP snapshot",
    );
}

fn ingest_source_payload(
    app: &AppHandle,
    source: SourceId,
    text: &str,
    is_backfill: bool,
    transport: &str,
) {
    let events = match parse_source_events(source, text) {
        Ok(events) => events,
        Err(error) => {
            // Do not log remote payload bodies: public source responses may be
            // large and we only need the source, transport, and parse reason to
            // diagnose an upstream schema change.
            log::warn!("{}: invalid {transport} payload: {error}", source.as_str());
            return;
        }
    };

    for event in events {
        pipeline::ingest_event(app, event, is_backfill);
    }
}

fn parse_source_events(
    source: SourceId,
    text: &str,
) -> Result<Vec<crate::domain::NormalizedEvent>, String> {
    let value: serde_json::Value = serde_json::from_str(text).map_err(|error| error.to_string())?;

    if let Some(kind) = value.get("type").and_then(|kind| kind.as_str()) {
        if kind == "heartbeat" || kind == "pong" {
            return Ok(Vec::new());
        }
    }

    match source {
        SourceId::JmaEew => {
            if value.get("EventID").is_none() {
                return Ok(Vec::new()); // idle/no-warning snapshot
            }
            match serde_json::from_value::<JmaEewMessage>(value) {
                Ok(msg) => Ok(vec![normalize::normalize_jma_eew(&msg)]),
                Err(error) => Err(error.to_string()),
            }
        }
        SourceId::ScEew | SourceId::FjEew => {
            if value.get("EventID").is_none() {
                return Ok(Vec::new());
            }
            match serde_json::from_value::<ScFjEewMessage>(value) {
                Ok(msg) => Ok(vec![normalize::normalize_sc_fj_eew(source.as_str(), &msg)]),
                Err(error) => Err(error.to_string()),
            }
        }
        SourceId::CencEew | SourceId::CqEew => {
            if value.get("EventID").is_none() {
                return Ok(Vec::new());
            }
            match serde_json::from_value::<CencCqEewMessage>(value) {
                Ok(msg) => Ok(vec![normalize::normalize_cenc_cq_eew(
                    source.as_str(),
                    &msg,
                )]),
                Err(error) => Err(error.to_string()),
            }
        }
        SourceId::CencEqlist => {
            if !has_ranked_keys(&value) {
                return Ok(Vec::new());
            }
            match serde_json::from_value::<EqlistEnvelope>(value) {
                Ok(envelope) => Ok(extract_ranked_entries::<CencEqlistEntry>(&envelope)
                    .into_iter()
                    .map(|(_, entry)| normalize::normalize_cenc_eqlist_entry(&entry))
                    .collect()),
                Err(error) => Err(error.to_string()),
            }
        }
        SourceId::JmaEqlist => {
            if !has_ranked_keys(&value) {
                return Ok(Vec::new());
            }
            match serde_json::from_value::<EqlistEnvelope>(value) {
                Ok(envelope) => Ok(extract_ranked_entries::<JmaEqlistEntry>(&envelope)
                    .into_iter()
                    .map(|(_, entry)| normalize::normalize_jma_eqlist_entry(&entry))
                    .collect()),
                Err(error) => Err(error.to_string()),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn complete_statuses(connected: bool) -> HashMap<String, bool> {
        SourceId::ALL
            .into_iter()
            .map(|source| (source.as_str().to_string(), connected))
            .collect()
    }

    #[test]
    fn http_snapshot_fallback_requires_a_degraded_websocket_source() {
        let mut healthy = complete_statuses(true);
        assert!(!has_unavailable_source_status(&healthy));

        healthy.insert(SourceId::CencEqlist.as_str().to_string(), false);
        assert!(has_unavailable_source_status(&healthy));

        // A missing status is fail-closed: it means the source was never
        // observed as a healthy WebSocket route and should receive a snapshot.
        healthy.remove(SourceId::JmaEqlist.as_str());
        assert!(has_unavailable_source_status(&healthy));
    }

    #[test]
    fn http_snapshot_cadence_is_conservative_and_backfill_only() {
        assert_eq!(HTTP_SNAPSHOT_OUTAGE_GRACE_SECS, 90);
        assert_eq!(HTTP_SNAPSHOT_REPEAT_SECS, 300);
        assert!(HTTP_SNAPSHOT_REQUEST_INTERVAL_MILLIS >= 500);
        assert!(HTTP_SNAPSHOT_IS_BACKFILL);
    }

    #[test]
    fn http_snapshot_client_builds_with_https_only_configuration() {
        assert!(build_http_snapshot_client().is_ok());
    }

    #[test]
    fn http_snapshot_payloads_reuse_the_source_normalizers() {
        let payload = r#"{
          "EventID":"20260812130555",
          "Serial":13,
          "OriginTime":"2026/08/12 13:05:52",
          "Hypocenter":"Kumamoto",
          "Latitude":32.5,
          "Longitude":130.5,
          "Magunitude":4.8,
          "Depth":10,
          "MaxIntensity":"4",
          "isWarn":true,
          "isFinal":false,
          "isCancel":false,
          "isTraining":false
        }"#;

        let events = parse_source_events(SourceId::JmaEew, payload).expect("valid HTTP snapshot");
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].id, "jma_eew:20260812130555");
        assert_eq!(events[0].magnitude, Some(4.8));
        assert!(events[0].is_warn);
    }
}
