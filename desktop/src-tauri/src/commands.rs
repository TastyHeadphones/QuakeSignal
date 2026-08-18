#[cfg(not(feature = "macos-app-store"))]
use crate::alarm;
use crate::db;
use crate::domain::NormalizedEvent;
#[cfg(not(feature = "macos-app-store"))]
use crate::domain::{EventKind, NotifyReason};
#[cfg(not(feature = "macos-app-store"))]
use crate::notify;
use crate::settings::Settings;
use crate::AppState;
use std::collections::HashMap;
use tauri::{AppHandle, State};
#[cfg(not(feature = "macos-app-store"))]
use tauri_plugin_autostart::ManagerExt;

#[tauri::command]
pub fn get_settings(state: State<AppState>) -> Settings {
    state.settings.lock().unwrap().clone()
}

#[tauri::command]
pub fn save_settings(
    app: AppHandle,
    state: State<AppState>,
    settings: Settings,
) -> Result<(), String> {
    #[cfg(feature = "macos-app-store")]
    if settings.launch_at_login {
        return Err("Launch at Login is unavailable in the Mac App Store build".to_string());
    }

    settings.save(&app)?;

    #[cfg(not(feature = "macos-app-store"))]
    {
        let autostart = app.autolaunch();
        let want_autostart = settings.launch_at_login;
        let currently_enabled = autostart.is_enabled().unwrap_or(false);
        if want_autostart && !currently_enabled {
            autostart.enable().map_err(|e| e.to_string())?;
        } else if !want_autostart && currently_enabled {
            autostart.disable().map_err(|e| e.to_string())?;
        }
    }

    *state.settings.lock().unwrap() = settings;
    Ok(())
}

#[tauri::command]
pub fn list_recent_events(state: State<AppState>, limit: Option<i64>) -> Vec<NormalizedEvent> {
    let conn = state.db.lock().unwrap();
    db::list_recent_events(&conn, limit.unwrap_or(100))
}

#[tauri::command]
pub fn list_revisions(state: State<AppState>, event_id: String) -> Vec<NormalizedEvent> {
    let conn = state.db.lock().unwrap();
    db::list_revisions(&conn, &event_id)
}

#[tauri::command]
pub fn get_connection_status(state: State<AppState>) -> HashMap<String, bool> {
    state.connection_status.lock().unwrap().clone()
}

#[tauri::command]
pub fn get_database_persistence_available(state: State<AppState>) -> bool {
    state.database_persistence_available
}

#[tauri::command]
pub fn get_pending_alert(state: State<AppState>) -> Option<serde_json::Value> {
    state.pending_alert.lock().unwrap().clone()
}

/// Fires a synthetic training-style alert through the exact same
/// notification + alert-window path a real event would use, so the user can
/// verify OS notification permissions / sound / do-not-disturb behavior
/// without waiting for an actual earthquake. Bypasses storage and the
/// subscription/magnitude/radius filters entirely since it's not real data.
///
/// This direct-distribution diagnostic is deliberately absent from the
/// sandboxed Mac App Store binary and its invoke handler.
#[cfg(not(feature = "macos-app-store"))]
#[tauri::command]
pub fn send_test_alert(app: AppHandle, state: State<AppState>) {
    let settings = state.settings.lock().unwrap().clone();
    let event = NormalizedEvent {
        id: "test:local-test-alert".to_string(),
        source_id: "test".to_string(),
        event_id: "local-test-alert".to_string(),
        serial: 1,
        kind: EventKind::Eew,
        origin_time_utc: Some(chrono::Utc::now().to_rfc3339()),
        report_time_utc: Some(chrono::Utc::now().to_rfc3339()),
        hypocenter: "Test Location".to_string(),
        latitude: settings.latitude,
        longitude: settings.longitude,
        magnitude: Some(5.0),
        depth: Some(10.0),
        max_intensity: Some("4".to_string()),
        is_warn: true,
        is_final: false,
        is_cancel: false,
        is_training: true,
        tsunami: None,
        raw: serde_json::Value::Null,
    };
    notify::dispatch(&app, &settings, &event, NotifyReason::Training);
    alarm::play_test(&settings, &event);
}
