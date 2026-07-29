use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;
use tauri::{AppHandle, Manager};

/// All 7 Wolfx source ids the user can subscribe to. Kept here (rather than
/// pulled from domain::SourceId) so the default list is a single, obvious
/// literal to audit.
pub const DEFAULT_SOURCES: &[&str] = &["jma_eew", "sc_eew", "cenc_eew", "fj_eew", "cq_eew"];

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[serde(default)]
pub struct Settings {
    /// "system" | "en" | "ja" | "zh-Hans"
    pub language: String,
    pub sources: Vec<String>,
    pub min_magnitude: f64,
    pub location_label: Option<String>,
    pub latitude: Option<f64>,
    pub longitude: Option<f64>,
    pub radius_km: Option<f64>,
    pub include_test_alerts: bool,
    /// Inverted like the backend's device flag: true (default) means quiet
    /// hours are NOT enforced. Only ever gates "report" (routine bulletin)
    /// notifications — active EEW warnings always go through regardless.
    pub notify_at_night: bool,
    /// Plays a native alarm for real events that pass the user's filters.
    /// This is independent of OS notification sound/DND behavior.
    pub alarm_enabled: bool,
    /// Linear 0.0–1.0 volume applied to the generated alarm tone.
    pub alarm_volume: f32,
    pub launch_at_login: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            language: "system".to_string(),
            sources: DEFAULT_SOURCES.iter().map(|s| s.to_string()).collect(),
            min_magnitude: 0.0,
            location_label: None,
            latitude: None,
            longitude: None,
            radius_km: None,
            include_test_alerts: false,
            notify_at_night: true,
            alarm_enabled: true,
            alarm_volume: 0.8,
            launch_at_login: false,
        }
    }
}

impl Settings {
    pub fn effective_latitude(&self) -> Option<f64> {
        self.latitude
    }

    pub fn effective_longitude(&self) -> Option<f64> {
        self.longitude
    }

    fn file_path(app: &AppHandle) -> Result<PathBuf, String> {
        let dir = app.path().app_data_dir().map_err(|e| e.to_string())?;
        fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
        Ok(dir.join("settings.json"))
    }

    pub fn load(app: &AppHandle) -> Settings {
        let path = match Self::file_path(app) {
            Ok(p) => p,
            Err(_) => return Settings::default(),
        };
        match fs::read_to_string(&path) {
            Ok(contents) => serde_json::from_str(&contents).unwrap_or_default(),
            Err(_) => Settings::default(),
        }
    }

    pub fn save(&self, app: &AppHandle) -> Result<(), String> {
        let path = Self::file_path(app)?;
        let json = serde_json::to_string_pretty(self).map_err(|e| e.to_string())?;
        fs::write(&path, json).map_err(|e| e.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn older_settings_files_gain_alarm_defaults() {
        let json = r#"{
          "language": "en",
          "sources": ["jma_eew"],
          "minMagnitude": 4.0,
          "locationLabel": null,
          "latitude": null,
          "longitude": null,
          "radiusKm": null,
          "includeTestAlerts": false,
          "notifyAtNight": true,
          "launchAtLogin": false
        }"#;
        let settings: Settings = serde_json::from_str(json).unwrap();
        assert!(settings.alarm_enabled);
        assert_eq!(settings.alarm_volume, 0.8);
        assert_eq!(settings.min_magnitude, 4.0);
    }
}
