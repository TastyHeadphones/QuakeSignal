use serde::{Deserialize, Serialize};

/// The 7 Wolfx feeds. Mirrors `WolfxSourceId` in backend/src/types/wolfx.ts —
/// keep the string values in sync, they are used as WS path segments.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SourceId {
    JmaEew,
    ScEew,
    CencEew,
    FjEew,
    CqEew,
    CencEqlist,
    JmaEqlist,
}

impl SourceId {
    pub const EEW: [SourceId; 5] = [
        SourceId::JmaEew,
        SourceId::ScEew,
        SourceId::CencEew,
        SourceId::FjEew,
        SourceId::CqEew,
    ];
    pub const REPORTS: [SourceId; 2] = [SourceId::CencEqlist, SourceId::JmaEqlist];
    pub const ALL: [SourceId; 7] = [
        SourceId::JmaEew,
        SourceId::ScEew,
        SourceId::CencEew,
        SourceId::FjEew,
        SourceId::CqEew,
        SourceId::CencEqlist,
        SourceId::JmaEqlist,
    ];

    pub fn as_str(&self) -> &'static str {
        match self {
            SourceId::JmaEew => "jma_eew",
            SourceId::ScEew => "sc_eew",
            SourceId::CencEew => "cenc_eew",
            SourceId::FjEew => "fj_eew",
            SourceId::CqEew => "cq_eew",
            SourceId::CencEqlist => "cenc_eqlist",
            SourceId::JmaEqlist => "jma_eqlist",
        }
    }
}

/// "eew" = a live/active early-warning feed, "report" = a routine post-hoc
/// earthquake bulletin (cenc_eqlist / jma_eqlist). Mirrors `NormalizedEvent.kind`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum EventKind {
    Eew,
    Report,
}

/// Mirrors `NotifyReason` in backend/src/types/domain.ts exactly.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum NotifyReason {
    New,
    Updated,
    Final,
    Cancelled,
    Report,
    Training,
}

impl NotifyReason {
    pub fn as_str(&self) -> &'static str {
        match self {
            NotifyReason::New => "new",
            NotifyReason::Updated => "updated",
            NotifyReason::Final => "final",
            NotifyReason::Cancelled => "cancelled",
            NotifyReason::Report => "report",
            NotifyReason::Training => "training",
        }
    }
}

/// The common shape every Wolfx source is normalized into. Mirrors
/// `NormalizedEvent` in backend/src/types/domain.ts field-for-field.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NormalizedEvent {
    pub id: String,
    pub source_id: String,
    pub event_id: String,
    pub serial: i64,
    pub kind: EventKind,
    pub origin_time_utc: Option<String>,
    pub report_time_utc: Option<String>,
    pub hypocenter: String,
    pub latitude: Option<f64>,
    pub longitude: Option<f64>,
    pub magnitude: Option<f64>,
    pub depth: Option<f64>,
    pub max_intensity: Option<String>,
    pub is_warn: bool,
    pub is_final: bool,
    pub is_cancel: bool,
    pub is_training: bool,
    pub tsunami: Option<String>,
    pub raw: serde_json::Value,
}

impl NormalizedEvent {
    /// Mirrors the `isSevere` gate in backend/src/push/payload.ts — a second,
    /// fixed magnitude threshold (distinct from the user's configurable
    /// `min_magnitude`) used to decide critical/urgent notification treatment.
    pub fn is_severe(&self) -> bool {
        self.magnitude.unwrap_or(0.0) >= 5.5
    }

    pub fn is_routine_report(&self) -> bool {
        self.kind == EventKind::Report
    }
}
