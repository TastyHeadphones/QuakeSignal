#![allow(non_snake_case)]
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Raw wire shapes for each Wolfx feed. Field names/types are taken from live
/// samples (curl'd from api.wolfx.jp) plus backend/src/types/wolfx.ts. Do not
/// "clean up" a field's type to match another source — the quirks (e.g. an
/// EventID that's numeric-looking-but-a-string, or a MaxIntensity that's a
/// string on JMA but a float everywhere else) are real and intentional.

#[derive(Debug, Deserialize, Serialize)]
pub struct JmaWarnArea {
    pub Chiiki: String,
    #[allow(dead_code)]
    pub Shindo1: Option<String>,
    #[allow(dead_code)]
    pub Shindo2: Option<String>,
    pub Time: Option<String>,
    #[allow(dead_code)]
    pub Type: Option<String>,
    pub Arrive: Option<bool>,
}

/// jma_eew — https://api.wolfx.jp/jma_eew.json / wss://ws-api.wolfx.jp/jma_eew
/// NOTE the "Magunitude" typo — that is the real wire field name, not ours.
#[derive(Debug, Deserialize, Serialize)]
pub struct JmaEewMessage {
    #[allow(dead_code)]
    pub Title: Option<String>,
    pub EventID: String,
    pub Serial: i64,
    #[allow(dead_code)]
    pub AnnouncedTime: Option<String>,
    pub OriginTime: String,
    pub Hypocenter: String,
    pub Latitude: f64,
    pub Longitude: f64,
    pub Magunitude: f64,
    pub Depth: Option<f64>,
    pub MaxIntensity: Option<String>,
    #[serde(default)]
    pub WarnArea: Vec<JmaWarnArea>,
    #[serde(default)]
    pub isTraining: bool,
    #[serde(default)]
    pub isWarn: bool,
    #[serde(default)]
    pub isFinal: bool,
    #[serde(default)]
    pub isCancel: bool,
}

/// sc_eew / fj_eew — Sichuan and Fujian bureaus share this shape. Fujian
/// omits Depth/MaxIntensity (confirmed live: fj_eew samples don't carry them).
#[derive(Debug, Deserialize, Serialize)]
pub struct ScFjEewMessage {
    pub EventID: String,
    pub ReportTime: String,
    pub ReportNum: i64,
    pub OriginTime: String,
    pub HypoCenter: String,
    pub Latitude: f64,
    pub Longitude: f64,
    pub Magunitude: f64,
    pub Depth: Option<f64>,
    pub MaxIntensity: Option<f64>,
    #[serde(default)]
    pub isFinal: bool,
}

/// cenc_eew / cq_eew — CENC (nationwide) and Chongqing bureau share this
/// shape. These are the two sources that spell it "Magnitude" correctly.
#[derive(Debug, Deserialize, Serialize)]
pub struct CencCqEewMessage {
    pub EventID: String,
    pub ReportTime: String,
    pub ReportNum: i64,
    pub OriginTime: String,
    pub HypoCenter: String,
    pub Latitude: f64,
    pub Longitude: f64,
    pub Magnitude: f64,
    pub Depth: Option<f64>,
    pub MaxIntensity: Option<f64>,
    #[serde(default)]
    pub isFinal: bool,
}

/// One ranked entry inside a cenc_eqlist response. Every value is a string on
/// the wire, even the numeric-looking ones — confirmed live.
#[derive(Debug, Deserialize, Serialize)]
pub struct CencEqlistEntry {
    #[serde(rename = "type")]
    pub kind: String, // "automatic" | "reviewed"
    pub EventID: String,
    pub time: String,
    #[allow(dead_code)]
    pub ReportTime: Option<String>,
    pub location: String,
    pub magnitude: String,
    pub depth: String,
    pub latitude: String,
    pub longitude: String,
    pub intensity: Option<String>,
}

/// One ranked entry inside a jma_eqlist response. `depth` carries its unit
/// inline (e.g. "20km"); `shindo` may be a non-numeric string like "不明".
#[derive(Debug, Deserialize, Serialize)]
pub struct JmaEqlistEntry {
    #[allow(dead_code)]
    pub Title: Option<String>,
    pub EventID: String,
    pub time_full: Option<String>,
    pub time: String,
    pub location: String,
    pub magnitude: String,
    pub shindo: Option<String>,
    pub depth: String,
    pub latitude: String,
    pub longitude: String,
    pub info: Option<String>,
}

/// A generic envelope for the two "list" feeds: keys are "No1".."No50" (rank)
/// plus a trailing "md5" we don't care about. Deserialize into a HashMap of
/// raw Values first, then pull out the "No<n>" keys — mirrors
/// `extractEqlistEntries` in backend/src/alerts/normalize.ts.
pub type EqlistEnvelope = HashMap<String, serde_json::Value>;

pub fn extract_ranked_entries<T: serde::de::DeserializeOwned>(
    envelope: &EqlistEnvelope,
) -> Vec<(u32, T)> {
    let mut out: Vec<(u32, T)> = Vec::new();
    for (key, value) in envelope {
        if let Some(rank_str) = key.strip_prefix("No") {
            if let Ok(rank) = rank_str.parse::<u32>() {
                if let Ok(entry) = serde_json::from_value::<T>(value.clone()) {
                    out.push((rank, entry));
                }
            }
        }
    }
    out.sort_by_key(|(rank, _)| *rank);
    out
}
