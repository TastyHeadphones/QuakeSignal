use crate::domain::{EventKind, NormalizedEvent};
use crate::wolfx_types::*;
use chrono::{DateTime, TimeZone, Utc};
use regex::Regex;
use std::sync::OnceLock;

fn datetime_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"(\d{4})[/-](\d{2})[/-](\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?").unwrap()
    })
}

/// Mirrors `parseLocalDateTime` in backend/src/alerts/normalize.ts: reads a
/// "yyyy/MM/dd HH:mm:ss" or "yyyy-MM-dd HH:mm:ss" string in the given fixed
/// UTC offset and returns an RFC3339 UTC timestamp.
pub fn parse_local_datetime(raw: &str, offset_hours: i64) -> Option<String> {
    let caps = datetime_regex().captures(raw)?;
    let y: i32 = caps[1].parse().ok()?;
    let mo: u32 = caps[2].parse().ok()?;
    let d: u32 = caps[3].parse().ok()?;
    let h: u32 = caps[4].parse().ok()?;
    let mi: u32 = caps[5].parse().ok()?;
    let s: u32 = caps
        .get(6)
        .map(|m| m.as_str().parse().unwrap_or(0))
        .unwrap_or(0);
    let naive = chrono::NaiveDate::from_ymd_opt(y, mo, d)?.and_hms_opt(h, mi, s)?;
    let utc_naive = naive - chrono::Duration::hours(offset_hours);
    let dt: DateTime<Utc> = Utc.from_utc_datetime(&utc_naive);
    Some(dt.to_rfc3339_opts(chrono::SecondsFormat::Millis, true))
}

pub fn parse_jst(raw: &str) -> Option<String> {
    parse_local_datetime(raw, 9)
}

pub fn parse_cst(raw: &str) -> Option<String> {
    parse_local_datetime(raw, 8)
}

/// Mirrors `toNumber` in backend/src/alerts/normalize.ts: strips everything
/// except digits/sign/decimal point, so it also handles jma_eqlist's
/// unit-suffixed depth field (e.g. "20km" -> 20.0).
pub fn to_number(v: &str) -> Option<f64> {
    if v.is_empty() {
        return None;
    }
    let cleaned: String = v
        .chars()
        .filter(|c| c.is_ascii_digit() || *c == '.' || *c == '+' || *c == '-')
        .collect();
    cleaned.parse::<f64>().ok().filter(|n| n.is_finite())
}

fn raw_value<T: serde::Serialize>(msg: &T) -> serde_json::Value {
    serde_json::to_value(msg).unwrap_or(serde_json::Value::Null)
}

pub fn normalize_jma_eew(msg: &JmaEewMessage) -> NormalizedEvent {
    NormalizedEvent {
        id: format!("jma_eew:{}", msg.EventID),
        source_id: "jma_eew".to_string(),
        event_id: msg.EventID.clone(),
        serial: msg.Serial,
        kind: EventKind::Eew,
        origin_time_utc: parse_jst(&msg.OriginTime),
        report_time_utc: parse_jst(&msg.OriginTime),
        hypocenter: msg.Hypocenter.clone(),
        latitude: Some(msg.Latitude),
        longitude: Some(msg.Longitude),
        magnitude: Some(msg.Magunitude),
        depth: msg.Depth,
        max_intensity: msg.MaxIntensity.clone(),
        is_warn: msg.isWarn,
        is_final: msg.isFinal,
        is_cancel: msg.isCancel,
        is_training: msg.isTraining,
        tsunami: None,
        raw: raw_value(msg),
    }
}

/// sc_eew / fj_eew: presence on this feed *is* the warning — these bureaus
/// only ever publish while a warning is active, unlike JMA which has an
/// explicit isWarn flag. isCancel/isTraining are hardcoded false to match
/// backend/src/alerts/normalize.ts's normalizeScFjEew exactly.
pub fn normalize_sc_fj_eew(source_id: &str, msg: &ScFjEewMessage) -> NormalizedEvent {
    NormalizedEvent {
        id: format!("{}:{}", source_id, msg.EventID),
        source_id: source_id.to_string(),
        event_id: msg.EventID.clone(),
        serial: msg.ReportNum,
        kind: EventKind::Eew,
        origin_time_utc: parse_cst(&msg.OriginTime),
        report_time_utc: parse_cst(&msg.ReportTime),
        hypocenter: msg.HypoCenter.clone(),
        latitude: Some(msg.Latitude),
        longitude: Some(msg.Longitude),
        magnitude: Some(msg.Magunitude),
        depth: msg.Depth,
        max_intensity: msg.MaxIntensity.map(|v| format!("{:.1}", v)),
        is_warn: true,
        is_final: msg.isFinal,
        is_cancel: false,
        is_training: false,
        tsunami: None,
        raw: raw_value(msg),
    }
}

/// cenc_eew / cq_eew: same hardcoded-isWarn reasoning as sc/fj above.
pub fn normalize_cenc_cq_eew(source_id: &str, msg: &CencCqEewMessage) -> NormalizedEvent {
    NormalizedEvent {
        id: format!("{}:{}", source_id, msg.EventID),
        source_id: source_id.to_string(),
        event_id: msg.EventID.clone(),
        serial: msg.ReportNum,
        kind: EventKind::Eew,
        origin_time_utc: parse_cst(&msg.OriginTime),
        report_time_utc: parse_cst(&msg.ReportTime),
        hypocenter: msg.HypoCenter.clone(),
        latitude: Some(msg.Latitude),
        longitude: Some(msg.Longitude),
        magnitude: Some(msg.Magnitude),
        depth: msg.Depth,
        max_intensity: msg.MaxIntensity.map(|v| format!("{:.1}", v)),
        is_warn: true,
        is_final: msg.isFinal,
        is_cancel: false,
        is_training: false,
        tsunami: None,
        raw: raw_value(msg),
    }
}

pub fn normalize_cenc_eqlist_entry(entry: &CencEqlistEntry) -> NormalizedEvent {
    let is_final = entry.kind == "reviewed";
    NormalizedEvent {
        id: format!("cenc_eqlist:{}", entry.EventID),
        source_id: "cenc_eqlist".to_string(),
        event_id: entry.EventID.clone(),
        serial: if is_final { 2 } else { 1 },
        kind: EventKind::Report,
        origin_time_utc: parse_cst(&entry.time),
        report_time_utc: entry
            .ReportTime
            .as_deref()
            .and_then(parse_cst)
            .or_else(|| parse_cst(&entry.time)),
        hypocenter: entry.location.clone(),
        latitude: to_number(&entry.latitude),
        longitude: to_number(&entry.longitude),
        magnitude: to_number(&entry.magnitude),
        depth: to_number(&entry.depth),
        max_intensity: entry.intensity.clone(),
        is_warn: false,
        is_final,
        is_cancel: false,
        is_training: false,
        tsunami: None,
        raw: raw_value(entry),
    }
}

pub fn normalize_jma_eqlist_entry(entry: &JmaEqlistEntry) -> NormalizedEvent {
    NormalizedEvent {
        id: format!("jma_eqlist:{}", entry.EventID),
        source_id: "jma_eqlist".to_string(),
        event_id: entry.EventID.clone(),
        serial: 1,
        kind: EventKind::Report,
        origin_time_utc: parse_jst(entry.time_full.as_deref().unwrap_or(&entry.time)),
        report_time_utc: parse_jst(entry.time_full.as_deref().unwrap_or(&entry.time)),
        hypocenter: entry.location.clone(),
        latitude: to_number(&entry.latitude),
        longitude: to_number(&entry.longitude),
        magnitude: to_number(&entry.magnitude),
        depth: to_number(&entry.depth),
        max_intensity: entry.shindo.clone(),
        is_warn: false,
        is_final: true,
        is_cancel: false,
        is_training: false,
        tsunami: entry.info.clone().filter(|s| !s.is_empty()),
        raw: raw_value(entry),
    }
}
