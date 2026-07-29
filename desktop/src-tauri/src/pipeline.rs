use crate::db;
use crate::domain::NormalizedEvent;
use crate::filter;
use crate::notify;
use crate::AppState;
use tauri::{AppHandle, Emitter, Manager};

/// Mirrors backend/src/alerts/pipeline.ts::ingestEvent: upsert + revision
/// bookkeeping always happens; the reason/notify/emit steps are skipped
/// entirely for backfill (the first message a fresh connection delivers,
/// which may describe a warning that started before this app was running).
pub fn ingest_event(app: &AppHandle, event: NormalizedEvent, is_backfill: bool) {
    let state = app.state::<AppState>();

    let previous = {
        let conn = state.db.lock().unwrap();
        db::get_event(&conn, &event.id)
    };
    let reason = filter::determine_reason(&event, previous.as_ref());
    let meaningful = filter::is_meaningful_revision(&event, previous.as_ref());
    let reason_label = reason.map(|r| r.as_str()).unwrap_or("none");

    {
        let conn = state.db.lock().unwrap();
        if let Err(e) = db::upsert_event(&conn, &event, meaningful, reason_label) {
            log::warn!("db upsert failed for {}: {e}", event.id);
        }
    }

    let _ = app.emit("quake-db-updated", ());

    if is_backfill {
        return;
    }
    let Some(reason) = reason else { return };

    log::info!("{}: {} (M{:?})", reason_label, event.id, event.magnitude);

    let settings = state.settings.lock().unwrap().clone();
    if !filter::passes_user_filters(&event, &settings) {
        return;
    }

    let _ = app.emit(
        "quake-event",
        serde_json::json!({ "event": &event, "reason": reason.as_str() }),
    );
    notify::dispatch(app, &settings, &event, reason);
}
