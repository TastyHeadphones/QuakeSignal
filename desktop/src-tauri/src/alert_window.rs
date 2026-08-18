use crate::domain::{NormalizedEvent, NotifyReason};
use crate::AppState;
use chrono::{DateTime, Utc};
use std::time::Duration;
use tauri::{AppHandle, Emitter, Manager, WebviewUrl, WebviewWindowBuilder};

const ALERT_LABEL: &str = "alert";

#[derive(Debug, Clone, PartialEq, Eq)]
struct AlertPresentationIdentity {
    event_id: String,
    serial: i64,
}

impl From<&NormalizedEvent> for AlertPresentationIdentity {
    fn from(event: &NormalizedEvent) -> Self {
        Self {
            event_id: event.id.clone(),
            serial: event.serial,
        }
    }
}

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
    let _lifecycle = state.alert_window_lifecycle.lock().unwrap();
    let payload = serde_json::json!({
        "event": event,
        "reason": reason.as_str(),
        "lang": lang,
    });
    *state.pending_alert.lock().unwrap() = Some(payload);

    schedule_expiry(app, event);

    if let Some(existing) = app.get_webview_window(ALERT_LABEL) {
        return perform_existing_refresh(
            || existing.emit_to(ALERT_LABEL, "alert-updated", ()),
            || existing.show(),
            || existing.set_focus(),
        );
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

/// Attempts every part of an existing-window refresh, with content delivery
/// first. Visibility and focus are best-effort OS operations; either can fail
/// during a workspace transition, but that must never prevent the webview from
/// learning that a newer accepted revision is waiting in `pending_alert`.
fn perform_existing_refresh<E>(
    emit_update: impl FnOnce() -> Result<(), E>,
    show: impl FnOnce() -> Result<(), E>,
    focus: impl FnOnce() -> Result<(), E>,
) -> Result<(), E> {
    let emit_result = emit_update();
    let show_result = show();
    let focus_result = focus();

    emit_result.and(show_result).and(focus_result)
}

/// Removes an already-present emergency window when the same warning reaches a
/// terminal state. This deliberately never creates, shows, or focuses a
/// window: final/cancellation updates remain ordinary notifications, while an
/// old red active-warning surface cannot outlive the warning it represents.
///
/// The event-id check is important because the app has one shared alert
/// window. A late terminal revision for warning A must not dismiss a newer
/// warning B that has since taken over that window.
pub fn clear_for_terminal_event(
    app: &AppHandle,
    event: &NormalizedEvent,
    reason: NotifyReason,
) -> tauri::Result<bool> {
    let state = app.state::<AppState>();
    let _lifecycle = state.alert_window_lifecycle.lock().unwrap();
    let mut pending = state.pending_alert.lock().unwrap();
    if !terminal_matches_pending(pending.as_ref(), event, reason) {
        return Ok(false);
    }

    *pending = None;
    drop(pending);

    hide_and_close(app)?;
    Ok(true)
}

fn schedule_expiry(app: &AppHandle, event: &NormalizedEvent) {
    let identity = AlertPresentationIdentity::from(event);
    // `show_alert` is reached only for a warning that just passed the freshness
    // gate. If its timestamp nevertheless becomes unreadable between layers,
    // expire immediately instead of leaving an unbounded emergency surface.
    let delay = expiry_delay_at(event, Utc::now()).unwrap_or(Duration::ZERO);
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(delay).await;
        if let Err(error) = clear_expired_presentation(&app, &identity) {
            log::warn!(
                "failed to expire alert window for {} revision {}: {error}",
                identity.event_id,
                identity.serial
            );
        }
    });
}

fn expiry_delay_at(event: &NormalizedEvent, now: DateTime<Utc>) -> Option<Duration> {
    let timestamp = event
        .report_time_utc
        .as_deref()
        .or(event.origin_time_utc.as_deref())?;
    let event_time = DateTime::parse_from_rfc3339(timestamp)
        .ok()?
        .with_timezone(&Utc);
    let warning_lifetime = chrono::Duration::seconds(crate::filter::MAX_ACTIVE_WARNING_AGE_SECONDS);
    let expires_at = std::cmp::min(event_time + warning_lifetime, now + warning_lifetime);
    let remaining_ms = expires_at.signed_duration_since(now).num_milliseconds();
    Some(Duration::from_millis(remaining_ms.max(0) as u64))
}

fn clear_expired_presentation(
    app: &AppHandle,
    identity: &AlertPresentationIdentity,
) -> tauri::Result<bool> {
    let state = app.state::<AppState>();
    let _lifecycle = state.alert_window_lifecycle.lock().unwrap();
    let mut pending = state.pending_alert.lock().unwrap();
    if !presentation_matches_pending(pending.as_ref(), identity) {
        return Ok(false);
    }

    *pending = None;
    drop(pending);

    hide_and_close(app)?;
    Ok(true)
}

fn presentation_matches_pending(
    pending: Option<&serde_json::Value>,
    identity: &AlertPresentationIdentity,
) -> bool {
    let Some(event) = pending.and_then(|payload| payload.get("event")) else {
        return false;
    };
    event.get("id").and_then(serde_json::Value::as_str) == Some(identity.event_id.as_str())
        && event.get("serial").and_then(serde_json::Value::as_i64) == Some(identity.serial)
}

fn hide_and_close(app: &AppHandle) -> tauri::Result<()> {
    if let Some(existing) = app.get_webview_window(ALERT_LABEL) {
        // Hiding first makes the safety state correct even if the platform
        // refuses to destroy the webview during shutdown or an OS transition.
        let hide_result = existing.hide();
        let close_result = existing.close();
        if let Err(close_error) = close_result {
            if let Err(hide_error) = hide_result {
                log::warn!("failed to hide terminal alert window before close: {hide_error}");
                return Err(close_error);
            }
            log::warn!("terminal alert window was hidden but could not be closed: {close_error}");
        }
    }

    Ok(())
}

fn terminal_matches_pending(
    pending: Option<&serde_json::Value>,
    event: &NormalizedEvent,
    reason: NotifyReason,
) -> bool {
    if !matches!(reason, NotifyReason::Final | NotifyReason::Cancelled) {
        return false;
    }

    pending
        .and_then(|payload| payload.get("event"))
        .and_then(|pending_event| pending_event.get("id"))
        .and_then(serde_json::Value::as_str)
        == Some(event.id.as_str())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::EventKind;

    fn event(id: &str) -> NormalizedEvent {
        NormalizedEvent {
            id: id.to_string(),
            source_id: "jma_eew".to_string(),
            event_id: id.to_string(),
            serial: 2,
            kind: EventKind::Eew,
            origin_time_utc: None,
            report_time_utc: Some(chrono::Utc::now().to_rfc3339()),
            hypocenter: "Test".to_string(),
            latitude: None,
            longitude: None,
            magnitude: Some(5.0),
            depth: None,
            max_intensity: None,
            is_warn: true,
            is_final: true,
            is_cancel: false,
            is_training: false,
            tsunami: None,
            raw: serde_json::Value::Null,
        }
    }

    fn pending(id: &str) -> serde_json::Value {
        serde_json::json!({
            "event": { "id": id, "serial": 2 },
            "reason": "new",
            "lang": "en",
        })
    }

    #[test]
    fn matching_final_or_cancellation_clears_the_pending_active_warning() {
        let event = event("jma_eew:warning-a");
        let pending = pending("jma_eew:warning-a");

        assert!(terminal_matches_pending(
            Some(&pending),
            &event,
            NotifyReason::Final
        ));
        assert!(terminal_matches_pending(
            Some(&pending),
            &event,
            NotifyReason::Cancelled
        ));
    }

    #[test]
    fn terminal_for_another_event_cannot_dismiss_the_current_warning() {
        let event = event("jma_eew:warning-a");
        let other_pending = pending("jma_eew:warning-b");

        assert!(!terminal_matches_pending(
            Some(&other_pending),
            &event,
            NotifyReason::Cancelled
        ));
    }

    #[test]
    fn expiry_only_matches_the_exact_presented_revision() {
        let current = pending("jma_eew:warning-a");
        let current_identity = AlertPresentationIdentity {
            event_id: "jma_eew:warning-a".to_string(),
            serial: 2,
        };
        let older_identity = AlertPresentationIdentity {
            event_id: "jma_eew:warning-a".to_string(),
            serial: 1,
        };
        let other_identity = AlertPresentationIdentity {
            event_id: "jma_eew:warning-b".to_string(),
            serial: 2,
        };

        assert!(presentation_matches_pending(
            Some(&current),
            &current_identity
        ));
        assert!(!presentation_matches_pending(
            Some(&current),
            &older_identity
        ));
        assert!(!presentation_matches_pending(
            Some(&current),
            &other_identity
        ));
    }

    #[test]
    fn expiry_delay_uses_a_ten_minute_event_and_wall_clock_cap() {
        let now = DateTime::parse_from_rfc3339("2026-08-19T12:00:00Z")
            .unwrap()
            .with_timezone(&Utc);
        let mut warning = event("jma_eew:warning-a");
        warning.report_time_utc = Some("2026-08-19T11:55:00Z".to_string());
        assert_eq!(
            expiry_delay_at(&warning, now),
            Some(Duration::from_secs(300))
        );

        warning.report_time_utc = Some("2026-08-19T11:49:00Z".to_string());
        assert_eq!(expiry_delay_at(&warning, now), Some(Duration::ZERO));

        warning.report_time_utc = Some("2026-08-19T12:05:00Z".to_string());
        assert_eq!(
            expiry_delay_at(&warning, now),
            Some(Duration::from_secs(600))
        );

        warning.report_time_utc = Some("not-a-date".to_string());
        assert_eq!(expiry_delay_at(&warning, now), None);
    }

    #[test]
    fn nonterminal_and_missing_payloads_never_clear_the_window() {
        let event = event("jma_eew:warning-a");
        let pending = pending("jma_eew:warning-a");

        assert!(!terminal_matches_pending(
            Some(&pending),
            &event,
            NotifyReason::Updated
        ));
        assert!(!terminal_matches_pending(None, &event, NotifyReason::Final));
        assert!(!terminal_matches_pending(
            Some(&serde_json::json!({ "event": {} })),
            &event,
            NotifyReason::Final
        ));
    }

    #[test]
    fn refresh_delivery_is_attempted_before_visibility_and_focus_even_when_show_fails() {
        use std::cell::RefCell;

        let attempts = RefCell::new(Vec::new());
        let result = perform_existing_refresh(
            || {
                attempts.borrow_mut().push("emit");
                Ok(())
            },
            || {
                attempts.borrow_mut().push("show");
                Err("show failed")
            },
            || {
                attempts.borrow_mut().push("focus");
                Ok(())
            },
        );

        assert_eq!(*attempts.borrow(), ["emit", "show", "focus"]);
        assert_eq!(result, Err("show failed"));
    }
}
