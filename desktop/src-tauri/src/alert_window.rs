use crate::domain::{NormalizedEvent, NotifyReason};
use crate::AppState;
use tauri::{AppHandle, Emitter, Manager, WebviewUrl, WebviewWindowBuilder};

const ALERT_LABEL: &str = "alert";

/// Creates (or refreshes, if already open) the always-on-top alert window.
/// The window's own HTML entry point (alert.html) calls the `get_pending_alert`
/// command on load to fetch what's stored in `AppState.pending_alert` rather
/// than us threading data through the window URL — simpler and avoids any
/// encoding concerns.
pub fn show_alert(
    app: &AppHandle,
    event: &NormalizedEvent,
    reason: NotifyReason,
    lang: &str,
) -> tauri::Result<()> {
    let state = app.state::<AppState>();
    let payload = serde_json::json!({
        "event": event,
        "reason": reason.as_str(),
        "lang": lang,
    });
    *state.pending_alert.lock().unwrap() = Some(payload);

    if let Some(existing) = app.get_webview_window(ALERT_LABEL) {
        existing.show()?;
        existing.set_focus()?;
        existing.emit_to(ALERT_LABEL, "alert-updated", ())?;
        return Ok(());
    }

    let window = WebviewWindowBuilder::new(app, ALERT_LABEL, WebviewUrl::App("alert.html".into()))
        .title("QuakeSignal")
        .inner_size(440.0, 300.0)
        .resizable(false)
        .minimizable(false)
        .maximizable(false)
        .always_on_top(true)
        .center()
        .build()?;
    window.set_focus()?;
    Ok(())
}
