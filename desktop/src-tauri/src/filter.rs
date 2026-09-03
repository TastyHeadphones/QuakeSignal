use crate::domain::{EventKind, NormalizedEvent, NotifyReason};
use crate::geo;
use crate::settings::Settings;
use chrono::{DateTime, Local, Timelike, Utc};

pub(crate) const MAX_ACTIVE_WARNING_AGE_SECONDS: i64 = 10 * 60;
const MAX_FUTURE_CLOCK_SKEW_SECONDS: i64 = 60;

/// Mirrors backend/src/util/geo.ts::haversineDistanceKm exactly.
pub fn haversine_distance_km(lat1: f64, lon1: f64, lat2: f64, lon2: f64) -> f64 {
    geo::haversine_distance_km(lat1, lon1, lat2, lon2)
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

fn is_fresh_active_warning_at(event: &NormalizedEvent, now: DateTime<Utc>) -> bool {
    if !is_genuine_active_warning(event) {
        return false;
    }
    let Some(timestamp) = event
        .report_time_utc
        .as_deref()
        .or(event.origin_time_utc.as_deref())
    else {
        return false;
    };
    let Ok(event_time) = DateTime::parse_from_rfc3339(timestamp) else {
        return false;
    };
    let age_seconds = now
        .signed_duration_since(event_time.with_timezone(&Utc))
        .num_seconds();
    (-MAX_FUTURE_CLOCK_SKEW_SECONDS..=MAX_ACTIVE_WARNING_AGE_SECONDS).contains(&age_seconds)
}

pub fn is_urgent_warning_presentation(event: &NormalizedEvent, reason: NotifyReason) -> bool {
    is_fresh_active_warning_at(event, Utc::now())
        && matches!(reason, NotifyReason::New | NotifyReason::Updated)
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
    if !is_fresh_active_warning_at(event, Utc::now()) {
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
                if !geo::event_matches_device_location(
                    user_lat,
                    user_lon,
                    lat,
                    lon,
                    &event.source_id,
                    radius_km,
                ) {
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
            report_time_utc: Some(Utc::now().to_rfc3339()),
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

    #[test]
    fn stale_or_malformed_warning_never_notifies_or_takes_over_the_screen() {
        let mut stale = event(1, false, false);
        stale.report_time_utc = Some((Utc::now() - chrono::Duration::minutes(11)).to_rfc3339());
        assert_eq!(determine_reason(&stale, None), None);
        assert!(!is_urgent_warning_presentation(&stale, NotifyReason::New));

        let mut malformed = event(1, false, false);
        malformed.report_time_utc = Some("not-a-date".to_string());
        assert_eq!(determine_reason(&malformed, None), None);
        assert!(!is_urgent_warning_presentation(
            &malformed,
            NotifyReason::New
        ));
    }

    #[test]
    fn warning_future_clock_skew_is_bounded_to_one_minute() {
        let now = DateTime::parse_from_rfc3339("2026-08-19T12:00:00Z")
            .unwrap()
            .with_timezone(&Utc);
        let mut warning = event(1, false, false);
        warning.report_time_utc = Some((now + chrono::Duration::seconds(60)).to_rfc3339());
        assert!(is_fresh_active_warning_at(&warning, now));

        warning.report_time_utc = Some((now + chrono::Duration::seconds(61)).to_rfc3339());
        assert!(!is_fresh_active_warning_at(&warning, now));
    }

    #[test]
    fn china_cenc_warning_matches_wgs84_city_after_gps_transfer() {
        let user_lat = 39.9042;
        let user_lon = 116.4074;
        let (event_lat, event_lon) = crate::geo::wgs84_to_gcj02(user_lat, user_lon);
        let mut warning = event(1, false, false);
        warning.source_id = "cenc_eew".to_string();
        warning.id = "cenc_eew:beijing".to_string();
        warning.latitude = Some(event_lat);
        warning.longitude = Some(event_lon);
        let mut settings = Settings::default();
        settings.sources = vec!["cenc_eew".to_string()];
        settings.latitude = Some(user_lat);
        settings.longitude = Some(user_lon);
        settings.radius_km = Some(0.2);
        assert!(passes_user_filters(&warning, &settings));
        warning.source_id = "usgs_eqlist".to_string();
        settings.sources = vec!["usgs_eqlist".to_string()];
        assert!(!passes_user_filters(&warning, &settings));
    }
}
