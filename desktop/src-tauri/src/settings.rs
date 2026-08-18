use serde::{Deserialize, Serialize};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use tauri::{AppHandle, Manager};

static SETTINGS_FILE_COUNTER: AtomicU64 = AtomicU64::new(0);

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
    /// "system" | "urgent-tone" | "japanese-voice". Unknown values fall
    /// back to the standard tone so a hand-edited settings file stays safe.
    pub alert_sound: String,
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
            alert_sound: "system".to_string(),
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

    pub fn effective_alert_sound(&self) -> &str {
        match self.alert_sound.as_str() {
            "urgent-tone" => "urgent-tone",
            "japanese-voice" => "japanese-voice",
            _ => "system",
        }
    }

    fn file_path(app: &AppHandle) -> Result<PathBuf, String> {
        let dir = app.path().app_data_dir().map_err(|e| e.to_string())?;
        fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
        Ok(dir.join("settings.json"))
    }

    pub fn load(app: &AppHandle) -> Settings {
        let path = match Self::file_path(app) {
            Ok(p) => p,
            Err(error) => {
                log::error!("could not resolve settings path: {error}");
                return Settings::default();
            }
        };
        Self::load_from_path(&path)
    }

    pub fn save(&self, app: &AppHandle) -> Result<(), String> {
        let path = Self::file_path(app)?;
        self.save_to_path(&path)
    }

    fn load_from_path(path: &Path) -> Settings {
        match fs::read_to_string(path) {
            Ok(contents) => match serde_json::from_str(&contents) {
                Ok(settings) => settings,
                Err(error) => {
                    preserve_corrupt_settings(path, &error.to_string());
                    Settings::default()
                }
            },
            Err(error) if error.kind() == io::ErrorKind::NotFound => Settings::default(),
            Err(error) if error.kind() == io::ErrorKind::InvalidData => {
                preserve_corrupt_settings(path, &error.to_string());
                Settings::default()
            }
            Err(error) => {
                log::error!("could not read settings file {}: {error}", path.display());
                Settings::default()
            }
        }
    }

    fn save_to_path(&self, path: &Path) -> Result<(), String> {
        let json = serde_json::to_string_pretty(self).map_err(|e| e.to_string())?;
        atomic_write(path, json.as_bytes()).map_err(|e| e.to_string())
    }
}

fn sibling_path(path: &Path, marker: &str) -> PathBuf {
    let sequence = SETTINGS_FILE_COUNTER.fetch_add(1, Ordering::Relaxed);
    let file_name = path
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("settings.json");
    path.with_file_name(format!(
        ".{file_name}.{marker}-{}-{sequence}",
        std::process::id()
    ))
}

fn corrupt_backup_path(path: &Path) -> PathBuf {
    let file_name = path
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("settings.json");
    loop {
        let sequence = SETTINGS_FILE_COUNTER.fetch_add(1, Ordering::Relaxed);
        let candidate = path.with_file_name(format!(
            "{file_name}.corrupt-{}-{sequence}",
            std::process::id()
        ));
        if !candidate.exists() {
            return candidate;
        }
    }
}

fn atomic_write(path: &Path, contents: &[u8]) -> io::Result<()> {
    let parent = path.parent().ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidInput, "settings path has no parent")
    })?;
    fs::create_dir_all(parent)?;
    let temporary = sibling_path(path, "tmp");

    let result = (|| {
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }

        let mut file = options.open(&temporary)?;
        file.write_all(contents)?;
        file.sync_all()?;
        drop(file);

        replace_file(&temporary, path)?;
        sync_parent_directory(parent);
        Ok(())
    })();

    if result.is_err() {
        // This exact path was created by this write attempt. Removing only the
        // uncommitted sibling never touches the previous valid settings file.
        let _ = fs::remove_file(&temporary);
    }
    result
}

#[cfg(not(windows))]
fn replace_file(from: &Path, to: &Path) -> io::Result<()> {
    fs::rename(from, to)
}

#[cfg(windows)]
fn replace_file(from: &Path, to: &Path) -> io::Result<()> {
    use std::os::windows::ffi::OsStrExt;

    const MOVEFILE_REPLACE_EXISTING: u32 = 0x1;
    const MOVEFILE_WRITE_THROUGH: u32 = 0x8;

    #[link(name = "Kernel32")]
    unsafe extern "system" {
        fn MoveFileExW(existing: *const u16, replacement: *const u16, flags: u32) -> i32;
    }

    let existing: Vec<u16> = from.as_os_str().encode_wide().chain(Some(0)).collect();
    let replacement: Vec<u16> = to.as_os_str().encode_wide().chain(Some(0)).collect();
    let result = unsafe {
        MoveFileExW(
            existing.as_ptr(),
            replacement.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    };
    if result == 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

#[cfg(unix)]
fn sync_parent_directory(parent: &Path) {
    if let Err(error) = File::open(parent).and_then(|directory| directory.sync_all()) {
        // The file itself was flushed and atomically replaced. Some filesystems
        // do not support syncing directory handles; keep the successful save
        // while recording that its directory entry could not be separately synced.
        log::warn!(
            "could not sync settings directory {}: {error}",
            parent.display()
        );
    }
}

#[cfg(not(unix))]
fn sync_parent_directory(_parent: &Path) {}

fn preserve_corrupt_settings(path: &Path, reason: &str) {
    let backup = corrupt_backup_path(path);
    match fs::rename(path, &backup) {
        Ok(()) => log::error!(
            "settings file {} was invalid ({reason}); preserved it as {}",
            path.display(),
            backup.display()
        ),
        Err(error) => log::error!(
            "settings file {} was invalid ({reason}) and could not be preserved: {error}",
            path.display()
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct TestDirectory(PathBuf);

    impl TestDirectory {
        fn new(name: &str) -> Self {
            let sequence = SETTINGS_FILE_COUNTER.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir().join(format!(
                "quakesignal-settings-{name}-{}-{sequence}",
                std::process::id()
            ));
            fs::create_dir_all(&path).expect("create test directory");
            Self(path)
        }

        fn join(&self, name: &str) -> PathBuf {
            self.0.join(name)
        }
    }

    impl Drop for TestDirectory {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

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
        assert_eq!(settings.alert_sound, "system");
        assert_eq!(settings.min_magnitude, 4.0);
    }

    #[test]
    fn unknown_alert_sound_falls_back_without_discarding_other_settings() {
        let settings = Settings {
            alert_sound: "unknown-external-value".to_string(),
            min_magnitude: 4.5,
            ..Settings::default()
        };
        assert_eq!(settings.effective_alert_sound(), "system");
        assert_eq!(settings.min_magnitude, 4.5);
    }

    #[test]
    fn save_atomically_replaces_existing_settings_without_temp_files() {
        let directory = TestDirectory::new("atomic-save");
        let path = directory.join("settings.json");
        let mut settings = Settings {
            language: "ja".to_string(),
            ..Settings::default()
        };
        settings.save_to_path(&path).expect("first save");

        settings.language = "en".to_string();
        settings.min_magnitude = 5.0;
        settings.save_to_path(&path).expect("replacement save");

        let loaded = Settings::load_from_path(&path);
        assert_eq!(loaded.language, "en");
        assert_eq!(loaded.min_magnitude, 5.0);
        let sibling_names: Vec<String> = fs::read_dir(&directory.0)
            .expect("list settings directory")
            .map(|entry| {
                entry
                    .expect("directory entry")
                    .file_name()
                    .to_string_lossy()
                    .into_owned()
            })
            .collect();
        assert_eq!(sibling_names, vec!["settings.json"]);
    }

    #[test]
    fn invalid_settings_are_preserved_before_defaults_are_used() {
        let directory = TestDirectory::new("corrupt-backup");
        let path = directory.join("settings.json");
        let invalid = b"{ partial settings";
        fs::write(&path, invalid).expect("write invalid settings");

        let loaded = Settings::load_from_path(&path);
        assert_eq!(loaded.language, Settings::default().language);
        assert!(!path.exists());

        let backups: Vec<PathBuf> = fs::read_dir(&directory.0)
            .expect("list settings directory")
            .map(|entry| entry.expect("directory entry").path())
            .filter(|candidate| {
                candidate
                    .file_name()
                    .and_then(|name| name.to_str())
                    .is_some_and(|name| name.contains("settings.json.corrupt-"))
            })
            .collect();
        assert_eq!(backups.len(), 1);
        assert_eq!(fs::read(&backups[0]).expect("read backup"), invalid);
    }
}
