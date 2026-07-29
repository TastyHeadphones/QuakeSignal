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

/// Mirrors backend/src/alerts/pipeline.ts::determineReason exactly, including
/// the ordering of checks (training/report short-circuit before the
/// new/cancel/final/updated state machine).
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
    if event.is_cancel {
        return if previous.map(|p| p.is_cancel).unwrap_or(false) {
            None
        } else {
            Some(NotifyReason::Cancelled)
        };
    }
    match previous {
        None => Some(NotifyReason::New),
        Some(prev) => {
            if event.is_final && !prev.is_final {
                Some(NotifyReason::Final)
            } else if event.serial > prev.serial {
                Some(NotifyReason::Updated)
            } else {
                None
            }
        }
    }
}

/// Mirrors backend/src/db.ts::isMeaningfulRevision exactly — decides whether
/// a revision-history row should be recorded (used for the Events list
/// timeline), independent of whether a notification should fire.
pub fn is_meaningful_revision(event: &NormalizedEvent, previous: Option<&NormalizedEvent>) -> bool {
    match previous {
        None => true,
        Some(prev) => {
            if event.is_cancel && !prev.is_cancel {
                return true;
            }
            if event.is_final && !prev.is_final {
                return true;
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
