use crate::domain::{EventKind, NormalizedEvent};
use crate::pipeline;
use crate::AppState;
use std::time::Duration;
use tauri::{AppHandle, Emitter, Manager};

pub const CATALOG_SOURCE_IDS: [&str; 3] = ["usgs_eqlist", "emsc_eqlist", "geonet_eqlist"];

const CATALOG_POLL_SECS: u64 = 120;
const CATALOG_REQUEST_TIMEOUT_SECS: u64 = 20;
const CATALOG_REQUEST_INTERVAL_MILLIS: u64 = 600;
const MAX_CATALOG_EVENTS: usize = 50;

struct CatalogEndpoint {
    source_id: &'static str,
    url: &'static str,
}

const ENDPOINTS: [CatalogEndpoint; 3] = [
    CatalogEndpoint {
        source_id: "usgs_eqlist",
        url: "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/4.5_day.geojson",
    },
    CatalogEndpoint {
        source_id: "emsc_eqlist",
        url: "https://www.seismicportal.eu/fdsnws/event/1/query?format=json&limit=50&minmag=4.5&orderby=time",
    },
    CatalogEndpoint {
        source_id: "geonet_eqlist",
        url: "https://api.geonet.org.nz/quake?MMI=4",
    },
];

pub fn spawn_all(app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        run_catalog_poller(app).await;
    });
}

fn build_client() -> Result<reqwest::Client, reqwest::Error> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    reqwest::Client::builder()
        .https_only(true)
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(CATALOG_REQUEST_TIMEOUT_SECS))
        .timeout(Duration::from_secs(CATALOG_REQUEST_TIMEOUT_SECS))
        .user_agent(concat!("QuakeSignal/", env!("CARGO_PKG_VERSION")))
        .build()
}

async fn run_catalog_poller(app: AppHandle) {
    let client = match build_client() {
        Ok(client) => client,
        Err(error) => {
            log::warn!("catalog poller could not create its HTTPS client: {error}");
            return;
        }
    };

    let mut is_backfill = true;
    loop {
        for (index, endpoint) in ENDPOINTS.iter().enumerate() {
            fetch_catalog(&app, &client, endpoint, is_backfill).await;
            if index + 1 < ENDPOINTS.len() {
                tokio::time::sleep(Duration::from_millis(CATALOG_REQUEST_INTERVAL_MILLIS)).await;
            }
        }
        is_backfill = false;
        tokio::time::sleep(Duration::from_secs(CATALOG_POLL_SECS)).await;
    }
}

async fn fetch_catalog(
    app: &AppHandle,
    client: &reqwest::Client,
    endpoint: &CatalogEndpoint,
    is_backfill: bool,
) {
    let response = match client.get(endpoint.url).send().await {
        Ok(response) => response,
        Err(error) => {
            set_connected(app, endpoint.source_id, false);
            log::warn!("{}: catalog request failed: {error}", endpoint.source_id);
            return;
        }
    };
    let response = match response.error_for_status() {
        Ok(response) => response,
        Err(error) => {
            set_connected(app, endpoint.source_id, false);
            log::warn!(
                "{}: catalog returned an unsuccessful status: {error}",
                endpoint.source_id
            );
            return;
        }
    };
    let body = match response.text().await {
        Ok(body) => body,
        Err(error) => {
            set_connected(app, endpoint.source_id, false);
            log::warn!("{}: could not read catalog body: {error}", endpoint.source_id);
            return;
        }
    };
    match normalize_catalog_geojson(endpoint.source_id, &body) {
        Ok(events) => {
            set_connected(app, endpoint.source_id, true);
            for event in events {
                pipeline::ingest_event(app, event, is_backfill);
            }
        }
        Err(error) => {
            set_connected(app, endpoint.source_id, false);
            log::warn!("{}: invalid catalog payload: {error}", endpoint.source_id);
        }
    }
}

fn set_connected(app: &AppHandle, source_id: &str, connected: bool) {
    let state = app.state::<AppState>();
    if let Ok(mut status) = state.connection_status.lock() {
        status.insert(source_id.to_string(), connected);
    }
    let _ = app.emit("quake-status", ());
}

fn json_number(value: Option<&serde_json::Value>) -> Option<f64> {
    match value? {
        serde_json::Value::Number(number) => number.as_f64(),
        serde_json::Value::String(text) => {
            let cleaned: String = text
                .chars()
                .filter(|c| c.is_ascii_digit() || *c == '.' || *c == '+' || *c == '-')
                .collect();
            cleaned.parse().ok()
        }
        _ => None,
    }
}

fn catalog_timestamp(value: Option<&serde_json::Value>) -> Option<String> {
    match value? {
        serde_json::Value::Number(number) => {
            let raw = number.as_f64()?;
            let ms = if raw > 1e12 { raw } else { raw * 1000.0 };
            chrono::DateTime::from_timestamp_millis(ms as i64)
                .map(|dt| dt.to_rfc3339_opts(chrono::SecondsFormat::Millis, true))
        }
        serde_json::Value::String(text) if !text.trim().is_empty() => {
            chrono::DateTime::parse_from_rfc3339(text)
                .ok()
                .map(|dt| dt.with_timezone(&chrono::Utc).to_rfc3339_opts(chrono::SecondsFormat::Millis, true))
                .or_else(|| {
                    let parsed = text.parse::<f64>().ok()?;
                    let ms = if parsed > 1e12 { parsed } else { parsed * 1000.0 };
                    chrono::DateTime::from_timestamp_millis(ms as i64)
                        .map(|dt| dt.to_rfc3339_opts(chrono::SecondsFormat::Millis, true))
                })
        }
        _ => None,
    }
}

fn catalog_event_id(feature: &serde_json::Value, properties: &serde_json::Value) -> Option<String> {
    if let Some(id) = feature.get("id") {
        if let Some(text) = id.as_str().map(str::trim).filter(|value| !value.is_empty()) {
            return Some(text.to_string());
        }
        if let Some(number) = id.as_f64().filter(|value| value.is_finite()) {
            return Some(number.to_string());
        }
    }
    for key in ["ids", "code", "publicID", "publicid", "unid", "sourceId"] {
        if let Some(text) = properties
            .get(key)
            .and_then(serde_json::Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            return Some(text.to_string());
        }
    }
    None
}

fn catalog_place(properties: &serde_json::Value) -> Option<String> {
    for key in ["place", "flynn_region", "locality", "title", "region"] {
        if let Some(text) = properties
            .get(key)
            .and_then(serde_json::Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            return Some(text.to_string());
        }
    }
    None
}

pub fn normalize_catalog_geojson(
    source_id: &str,
    text: &str,
) -> Result<Vec<NormalizedEvent>, String> {
    let value: serde_json::Value = serde_json::from_str(text).map_err(|error| error.to_string())?;
    if value.get("type").and_then(serde_json::Value::as_str) != Some("FeatureCollection") {
        return Err("expected FeatureCollection".to_string());
    }
    let features = value
        .get("features")
        .and_then(serde_json::Value::as_array)
        .ok_or_else(|| "missing features".to_string())?;
    let mut events = Vec::new();
    for feature in features {
        if events.len() >= MAX_CATALOG_EVENTS {
            break;
        }
        if feature.get("type").and_then(serde_json::Value::as_str) != Some("Feature") {
            continue;
        }
        let properties = match feature.get("properties") {
            Some(properties) if properties.is_object() => properties,
            _ => continue,
        };
        if source_id == "usgs_eqlist" {
            if let Some(kind) = properties.get("type").and_then(serde_json::Value::as_str) {
                if kind != "earthquake" {
                    continue;
                }
            }
        }
        let Some(event_id) = catalog_event_id(feature, properties) else {
            continue;
        };
        let Some(hypocenter) = catalog_place(properties) else {
            continue;
        };
        let Some(magnitude) = json_number(properties.get("mag")).or_else(|| json_number(properties.get("magnitude")))
        else {
            continue;
        };
        let Some(origin_time_utc) = catalog_timestamp(
            properties
                .get("time")
                .or_else(|| properties.get("origintime"))
                .or_else(|| properties.get("origin_time")),
        ) else {
            continue;
        };
        let report_time_utc = catalog_timestamp(
            properties
                .get("updated")
                .or_else(|| properties.get("lastupdate"))
                .or_else(|| properties.get("time"))
                .or_else(|| properties.get("origintime")),
        )
        .or_else(|| Some(origin_time_utc.clone()));
        let geometry = feature.get("geometry");
        if geometry.and_then(|value| value.get("type")).and_then(serde_json::Value::as_str) != Some("Point")
        {
            continue;
        }
        let coordinates = geometry.and_then(|value| value.get("coordinates")).and_then(serde_json::Value::as_array);
        let Some(coordinates) = coordinates else { continue };
        if coordinates.len() < 2 {
            continue;
        }
        let Some(longitude) = json_number(coordinates.first()) else { continue };
        let Some(latitude) = json_number(coordinates.get(1)) else { continue };
        let depth = json_number(coordinates.get(2));
        let max_intensity = properties
            .get("mmi")
            .or_else(|| properties.get("intensity"))
            .and_then(|value| match value {
                serde_json::Value::Null => None,
                serde_json::Value::String(text) if text.is_empty() => None,
                other => Some(other.to_string().trim_matches('"').to_string()),
            });
        let tsunami = match properties.get("tsunami") {
            Some(serde_json::Value::Number(number)) if number.as_f64() == Some(1.0) => {
                Some("tsunami".to_string())
            }
            Some(serde_json::Value::Bool(true)) => Some("tsunami".to_string()),
            Some(serde_json::Value::String(text)) if text != "0" && !text.is_empty() => Some(text.clone()),
            _ => None,
        };
        events.push(NormalizedEvent {
            id: format!("{source_id}:{event_id}"),
            source_id: source_id.to_string(),
            event_id,
            serial: 1,
            kind: EventKind::Report,
            origin_time_utc: Some(origin_time_utc),
            report_time_utc,
            hypocenter,
            latitude: Some(latitude),
            longitude: Some(longitude),
            magnitude: Some(magnitude),
            depth,
            max_intensity,
            is_warn: false,
            is_final: true,
            is_cancel: false,
            is_training: false,
            tsunami,
            raw: feature.clone(),
        });
    }
    Ok(events)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn geonet_public_id_without_feature_id_is_the_event_identity() {
        let payload = r#"{
            "type": "FeatureCollection",
            "features": [{
                "type": "Feature",
                "properties": {
                    "publicID": "2014p715167",
                    "time": "2026-08-30T01:12:00.000Z",
                    "magnitude": 5.2,
                    "depth": 12.3,
                    "locality": "20 km north of Wellington",
                    "mmi": 5
                },
                "geometry": { "type": "Point", "coordinates": [174.78, -41.29, 12.3] }
            }]
        }"#;
        let events = normalize_catalog_geojson("geonet_eqlist", payload).unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].id, "geonet_eqlist:2014p715167");
        assert_eq!(events[0].kind, EventKind::Report);
        assert_eq!(events[0].hypocenter, "20 km north of Wellington");
    }

    #[test]
    fn geonet_feature_without_identity_is_dropped() {
        let payload = r#"{
            "type": "FeatureCollection",
            "features": [{
                "type": "Feature",
                "properties": {
                    "time": "2026-08-30T01:12:00.000Z",
                    "magnitude": 5.2,
                    "locality": "20 km north of Wellington"
                },
                "geometry": { "type": "Point", "coordinates": [174.78, -41.29, 12.3] }
            }]
        }"#;
        let events = normalize_catalog_geojson("geonet_eqlist", payload).unwrap();
        assert!(events.is_empty());
    }

    #[test]
    fn usgs_feature_id_maps_onto_the_report_path() {
        let payload = r#"{
            "type": "FeatureCollection",
            "features": [{
                "type": "Feature",
                "id": "us7000abcd",
                "properties": {
                    "mag": 6.1,
                    "place": "32 km WSW of Ovalle, Chile",
                    "time": 1756515600000,
                    "type": "earthquake"
                },
                "geometry": { "type": "Point", "coordinates": [-71.3, -30.6, 40] }
            }]
        }"#;
        let events = normalize_catalog_geojson("usgs_eqlist", payload).unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].id, "usgs_eqlist:us7000abcd");
        assert_eq!(events[0].magnitude, Some(6.1));
    }
}
