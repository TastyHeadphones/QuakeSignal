use crate::domain::SourceId;
use crate::normalize;
use crate::pipeline;
use crate::wolfx_types::*;
use crate::AppState;
use futures_util::{SinkExt, StreamExt};
use std::time::Duration;
use tauri::{AppHandle, Emitter, Manager};
use tokio_tungstenite::tungstenite::Message;

/// Desktop is intentionally serverless: every source connection goes
/// straight from the native app to Wolfx. No QuakeSignal backend, account,
/// device registration, or Cloudflare endpoint is involved.
const WS_BASE: &str = "wss://ws-api.wolfx.jp";
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
}

fn spawn_route(app: AppHandle, route: Route) {
    tauri::async_runtime::spawn(async move {
        run_route(app, route).await;
    });
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

fn has_ranked_keys(value: &serde_json::Value) -> bool {
    value
        .as_object()
        .map(|o| o.keys().any(|k| k.starts_with("No")))
        .unwrap_or(false)
}

/// Routes one text frame after the connection layer identifies its source.
fn handle_message(app: &AppHandle, source: SourceId, text: &str) {
    let value: serde_json::Value = match serde_json::from_str(text) {
        Ok(v) => v,
        Err(e) => {
            log::warn!("{}: invalid json ({e}): {text}", source.as_str());
            return;
        }
    };

    if let Some(kind) = value.get("type").and_then(|t| t.as_str()) {
        if kind == "heartbeat" || kind == "pong" {
            return;
        }
    }

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

    match source {
        SourceId::JmaEew => {
            if value.get("EventID").is_none() {
                return; // idle/no-warning snapshot
            }
            match serde_json::from_value::<JmaEewMessage>(value) {
                Ok(msg) => {
                    pipeline::ingest_event(app, normalize::normalize_jma_eew(&msg), is_backfill)
                }
                Err(e) => log::warn!("jma_eew: parse error: {e}"),
            }
        }
        SourceId::ScEew | SourceId::FjEew => {
            if value.get("EventID").is_none() {
                return;
            }
            match serde_json::from_value::<ScFjEewMessage>(value) {
                Ok(msg) => pipeline::ingest_event(
                    app,
                    normalize::normalize_sc_fj_eew(source.as_str(), &msg),
                    is_backfill,
                ),
                Err(e) => log::warn!("{}: parse error: {e}", source.as_str()),
            }
        }
        SourceId::CencEew | SourceId::CqEew => {
            if value.get("EventID").is_none() {
                return;
            }
            match serde_json::from_value::<CencCqEewMessage>(value) {
                Ok(msg) => pipeline::ingest_event(
                    app,
                    normalize::normalize_cenc_cq_eew(source.as_str(), &msg),
                    is_backfill,
                ),
                Err(e) => log::warn!("{}: parse error: {e}", source.as_str()),
            }
        }
        SourceId::CencEqlist => {
            if !has_ranked_keys(&value) {
                return;
            }
            match serde_json::from_value::<EqlistEnvelope>(value) {
                Ok(envelope) => {
                    for (_, entry) in extract_ranked_entries::<CencEqlistEntry>(&envelope) {
                        pipeline::ingest_event(
                            app,
                            normalize::normalize_cenc_eqlist_entry(&entry),
                            is_backfill,
                        );
                    }
                }
                Err(e) => log::warn!("cenc_eqlist: parse error: {e}"),
            }
        }
        SourceId::JmaEqlist => {
            if !has_ranked_keys(&value) {
                return;
            }
            match serde_json::from_value::<EqlistEnvelope>(value) {
                Ok(envelope) => {
                    for (_, entry) in extract_ranked_entries::<JmaEqlistEntry>(&envelope) {
                        pipeline::ingest_event(
                            app,
                            normalize::normalize_jma_eqlist_entry(&entry),
                            is_backfill,
                        );
                    }
                }
                Err(e) => log::warn!("jma_eqlist: parse error: {e}"),
            }
        }
    }
}
