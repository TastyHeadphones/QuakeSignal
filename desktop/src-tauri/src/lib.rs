mod alarm;
mod alert_window;
mod commands;
mod db;
mod domain;
mod filter;
mod normalize;
mod notify;
mod pipeline;
mod settings;
mod tray;
mod wolfx_client;
mod wolfx_types;

use domain::SourceId;
use settings::Settings;
use std::collections::{HashMap, HashSet};
use std::sync::Mutex;
use tauri::Manager;

pub struct AppState {
    pub db: Mutex<rusqlite::Connection>,
    pub settings: Mutex<Settings>,
    /// Sources that have delivered at least one message since app launch —
    /// gates the backfill/no-notify behavior on a fresh connection. See
    /// wolfx_client.rs::handle_message for why this exists.
    pub seeded_sources: Mutex<HashSet<String>>,
    pub connection_status: Mutex<HashMap<String, bool>>,
    pub pending_alert: Mutex<Option<serde_json::Value>>,
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    // tokio-tungstenite intentionally leaves rustls' process-wide crypto
    // provider unspecified. Install one before any background WebSocket task
    // starts; otherwise each task panics before opening a network socket.
    let _ = rustls::crypto::ring::default_provider().install_default();

    let builder = tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_notification::init());

    // The direct distribution uses a LaunchAgent for its optional “launch at
    // login” setting. That legacy mechanism writes to ~/Library/LaunchAgents,
    // which is not available to a Mac App Store sandboxed app.
    #[cfg(not(feature = "macos-app-store"))]
    let builder = builder.plugin(tauri_plugin_autostart::init(
        tauri_plugin_autostart::MacosLauncher::LaunchAgent,
        None,
    ));

    let builder = builder
        .plugin(tauri_plugin_log::Builder::new().build())
        .setup(|app| {
            let handle = app.handle().clone();

            let conn = db::open(&handle).expect("failed to open local database");
            let loaded_settings = Settings::load(&handle);

            app.manage(AppState {
                db: Mutex::new(conn),
                settings: Mutex::new(loaded_settings),
                seeded_sources: Mutex::new(HashSet::new()),
                connection_status: Mutex::new(
                    SourceId::ALL
                        .into_iter()
                        .map(|source| (source.as_str().to_string(), false))
                        .collect(),
                ),
                pending_alert: Mutex::new(None),
            });

            tray::setup(&handle)?;
            wolfx_client::spawn_all(handle.clone());

            if let Some(main) = app.get_webview_window("main") {
                let main_clone = main.clone();
                main.on_window_event(move |event| {
                    // Keep the app (and its WebSocket connections) alive in
                    // the tray when the window is closed -- the whole point
                    // of this app is to keep monitoring in the background.
                    if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                        api.prevent_close();
                        let _ = main_clone.hide();
                    }
                });
            }

            Ok(())
        });

    // Keep the Store invoke surface limited to normal monitoring controls.
    // The synthetic alert is compiled and registered only for direct builds.
    #[cfg(feature = "macos-app-store")]
    let builder = builder.invoke_handler(tauri::generate_handler![
        commands::get_settings,
        commands::save_settings,
        commands::list_recent_events,
        commands::list_revisions,
        commands::get_connection_status,
        commands::get_pending_alert,
    ]);

    #[cfg(not(feature = "macos-app-store"))]
    let builder = builder.invoke_handler(tauri::generate_handler![
        commands::get_settings,
        commands::save_settings,
        commands::list_recent_events,
        commands::list_revisions,
        commands::get_connection_status,
        commands::get_pending_alert,
        commands::send_test_alert,
    ]);

    builder
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
