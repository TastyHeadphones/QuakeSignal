use crate::domain::{EventKind, NormalizedEvent, NotifyReason};
use crate::settings::Settings;
use chrono::{Local, Timelike, Utc};

const EARTH_RADIUS_KM: f64 = 6371.0;

/// Mirrors backend/src/util/geo.ts::haversineDistanceKm exactly.
pub fn haversine_distance_km(lat1: f64, lon1: f64, lat2: f64, lon2: f64) -> f64 {
    let to_rad = |deg: f64| deg * std::f64::consts::PI / 180.0;
    let d_lat = to_rad(lat2 - lat1);
    let d_lon = to_rad(lon2 - lon1);
    let a = (d_lat / 2.0).sin().powi(2)
        + to_rad(lat1).cos() * to_rad(lat2).cos() * (d_lon / 2.0).sin().powi(2);
    let c = 2.0 * a.sqrt().atan2((1.0 - a).sqrt());
    EARTH_RADIUS_KM * c
}

/// Mirrors backend/src/util/time.ts::isQuietHours: true if the local time at
/// `utc_offset_minutes` falls in [22:00, 07:00). Desktop computes the
/// offset live from the OS clock rather than storing it, so DST just works.
pub fn is_quiet_hours(utc_offset_minutes: i64) -> bool {
    let shifted = Utc::now() + chrono::Duration::minutes(utc_offset_minutes);
    let local_hour = shifted.hour();
    !(7..22).contains(&local_hour)
}

pub fn local_utc_offset_minutes() -> i64 {
    Local::now().offset().local_minus_utc() as i64 / 60
}

pub fn is_genuine_active_warning(event: &NormalizedEvent) -> bool {
    event.kind == EventKind::Eew
        && event.is_warn
        && !event.is_final
        && !event.is_cancel
        && !event.is_training
}

pub fn is_urgent_warning_presentation(event: &NormalizedEvent, reason: NotifyReason) -> bool {
    is_genuine_active_warning(event) && matches!(reason, NotifyReason::New | NotifyReason::Updated)
}

/// Applies the same monotonic alert lifecycle as the backend: training/report
/// short-circuits precede the new/cancel/final/updated state machine, while
/// stale revisions and terminal-state regressions are ignored.
pub fn determine_reason(
    event: &NormalizedEvent,
    previous: Option<&NormalizedEvent>,
) -> Option<NotifyReason> {
    if event.is_training {
        return if previous.is_none() {
            Some(NotifyReason::Training)
        } else {
            None
        };
    }
    if event.kind == EventKind::Report {
        return if previous.is_none() {
            Some(NotifyReason::Report)
        } else {
            None
        };
    }
    if let Some(previous) = previous {
        if event.serial < previous.serial || previous.is_cancel {
            return None;
        }
    }
    let previous_belonged_to_warning = previous
        .map(|previous| {
            previous.kind == EventKind::Eew && previous.is_warn && !previous.is_training
        })
        .unwrap_or(false);
    if event.is_cancel {
        return if previous_belonged_to_warning
            && !previous.map(|previous| previous.is_cancel).unwrap_or(false)
        {
            Some(NotifyReason::Cancelled)
        } else {
            None
        };
    }
    if event.is_final {
        return if previous_belonged_to_warning
            && !previous.map(|previous| previous.is_final).unwrap_or(false)
        {
            Some(NotifyReason::Final)
        } else {
            None
        };
    }
    if previous.map(|previous| previous.is_final).unwrap_or(false) {
        return None;
    }
    if !is_genuine_active_warning(event) {
        return None;
    }
    match previous {
        None => Some(NotifyReason::New),
        Some(prev) => {
            if !is_genuine_active_warning(prev) {
                Some(NotifyReason::New)
            } else if event.serial > prev.serial {
                Some(NotifyReason::Updated)
            } else {
                None
            }
        }
    }
}

/// Decides whether a revision-history row should be recorded (used for the
/// Events list timeline), independent of whether a notification should fire.
/// Stale revisions and terminal-state regressions are never meaningful.
pub fn is_meaningful_revision(event: &NormalizedEvent, previous: Option<&NormalizedEvent>) -> bool {
    match previous {
        None => true,
        Some(prev) => {
            if event.serial < prev.serial || prev.is_cancel {
                return false;
            }
            if event.is_cancel && !prev.is_cancel {
                return true;
            }
            if event.is_final && !prev.is_final {
                return true;
            }
            if prev.is_final {
                return false;
            }
            event.serial > prev.serial
        }
    }
}

/// The single-user equivalent of backend/src/db.ts::listDevicesForSource:
/// same five gates (source subscription, training opt-in, magnitude
/// threshold, quiet hours for routine reports only, radius) composed in the
/// same order, just returning a bool for "would this device receive it"
/// instead of filtering a device list.
pub fn passes_user_filters(event: &NormalizedEvent, settings: &Settings) -> bool {
    if !settings.sources.iter().any(|s| s == &event.source_id) {
        return false;
    }
    if event.is_training && !settings.include_test_alerts {
        return false;
    }
    if event.magnitude.unwrap_or(0.0) < settings.min_magnitude {
        return false;
    }
    if event.is_routine_report()
        && !settings.notify_at_night
        && is_quiet_hours(local_utc_offset_minutes())
    {
        return false;
    }
    if let Some(radius_km) = settings.radius_km {
        let (Some(user_lat), Some(user_lon)) = (
            settings.effective_latitude(),
            settings.effective_longitude(),
        ) else {
            return false;
        };
        match (event.latitude, event.longitude) {
            (Some(lat), Some(lon)) => {
                if haversine_distance_km(user_lat, user_lon, lat, lon) > radius_km {
                    return false;
                }
            }
            _ => return false,
        }
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event(serial: i64, is_final: bool, is_cancel: bool) -> NormalizedEvent {
        NormalizedEvent {
            id: "jma_eew:test".to_string(),
            source_id: "jma_eew".to_string(),
            event_id: "test".to_string(),
            serial,
            kind: EventKind::Eew,
            origin_time_utc: None,
            report_time_utc: None,
            hypocenter: "Test".to_string(),
            latitude: None,
            longitude: None,
            magnitude: Some(5.0),
            depth: None,
            max_intensity: None,
            is_warn: true,
            is_final,
            is_cancel,
            is_training: false,
            tsunami: None,
            raw: serde_json::Value::Null,
        }
    }

    #[test]
    fn stale_terminal_messages_do_not_notify_or_create_revisions() {
        let current = event(5, false, false);
        let stale_cancel = event(4, false, true);
        let stale_final = event(4, true, false);

        assert_eq!(determine_reason(&stale_cancel, Some(&current)), None);
        assert_eq!(determine_reason(&stale_final, Some(&current)), None);
        assert!(!is_meaningful_revision(&stale_cancel, Some(&current)));
        assert!(!is_meaningful_revision(&stale_final, Some(&current)));
    }

    #[test]
    fn terminal_events_only_progress_to_cancellation() {
        let final_event = event(5, true, false);
        let reopened = event(6, false, false);
        assert_eq!(determine_reason(&reopened, Some(&final_event)), None);
        assert!(!is_meaningful_revision(&reopened, Some(&final_event)));

        let cancelled = event(6, true, true);
        assert_eq!(
            determine_reason(&cancelled, Some(&final_event)),
            Some(NotifyReason::Cancelled)
        );
        assert!(is_meaningful_revision(&cancelled, Some(&final_event)));

        let after_cancel = event(7, true, false);
        assert_eq!(determine_reason(&after_cancel, Some(&cancelled)), None);
        assert!(!is_meaningful_revision(&after_cancel, Some(&cancelled)));
    }

    #[test]
    fn informational_eew_never_becomes_an_urgent_alert() {
        let mut informational = event(1, false, false);
        informational.is_warn = false;
        assert_eq!(determine_reason(&informational, None), None);
        assert!(!is_urgent_warning_presentation(
            &informational,
            NotifyReason::New
        ));

        let promoted_warning = event(1, false, false);
        assert_eq!(
            determine_reason(&promoted_warning, Some(&informational)),
            Some(NotifyReason::New)
        );
        assert!(is_urgent_warning_presentation(
            &promoted_warning,
            NotifyReason::New
        ));

        let final_event = event(1, true, false);
        assert_eq!(
            determine_reason(&final_event, Some(&promoted_warning)),
            Some(NotifyReason::Final)
        );
        assert!(!is_urgent_warning_presentation(
            &final_event,
            NotifyReason::Final
        ));
    }
}
