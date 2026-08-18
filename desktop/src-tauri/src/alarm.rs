use crate::domain::{EventKind, NormalizedEvent, NotifyReason};
use crate::settings::Settings;
use std::sync::atomic::{AtomicBool, Ordering};

static ALARM_PLAYING: AtomicBool = AtomicBool::new(false);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum AlarmPattern {
    WarningSystem,
    WarningUrgent,
    WarningJapaneseVoice,
    Report,
}

/// Plays a native audio alarm after an event has passed every user filter.
///
/// Playback lives in Rust rather than the webview so it still works while the
/// main window is hidden in the tray and is not subject to browser autoplay
/// restrictions. Active EEWs use an urgent repeating pattern; routine reports
/// use a shorter two-note chime. Training messages and cancellations stay
/// silent unless the user explicitly presses the Test Alarm button.
pub fn play_for_event(settings: &Settings, event: &NormalizedEvent, reason: NotifyReason) {
    let Some(pattern) = pattern_for(settings, event, reason, false) else {
        return;
    };
    spawn_pattern(pattern, settings.alarm_volume);
}

#[cfg(not(feature = "macos-app-store"))]
pub fn play_test(settings: &Settings, event: &NormalizedEvent) {
    let Some(pattern) = pattern_for(settings, event, NotifyReason::Training, true) else {
        return;
    };
    spawn_pattern(pattern, settings.alarm_volume);
}

fn pattern_for(
    settings: &Settings,
    event: &NormalizedEvent,
    reason: NotifyReason,
    manual_test: bool,
) -> Option<AlarmPattern> {
    if !settings.alarm_enabled {
        return None;
    }
    if manual_test {
        #[cfg(not(feature = "macos-app-store"))]
        return Some(warning_pattern(settings));
        #[cfg(feature = "macos-app-store")]
        return None;
    }
    match (event.kind, reason) {
        (EventKind::Eew, _) if crate::filter::is_urgent_warning_presentation(event, reason) => {
            Some(warning_pattern(settings))
        }
        (EventKind::Report, NotifyReason::Report) => Some(AlarmPattern::Report),
        _ => None,
    }
}

fn warning_pattern(settings: &Settings) -> AlarmPattern {
    match settings.effective_alert_sound() {
        "urgent-tone" => AlarmPattern::WarningUrgent,
        "japanese-voice" => AlarmPattern::WarningJapaneseVoice,
        _ => AlarmPattern::WarningSystem,
    }
}

fn spawn_pattern(pattern: AlarmPattern, volume: f32) {
    if ALARM_PLAYING
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        log::debug!("alarm already playing; skipping overlapping pattern");
        return;
    }

    let volume = volume.clamp(0.0, 1.0);
    std::thread::spawn(move || {
        struct PlayingGuard;
        impl Drop for PlayingGuard {
            fn drop(&mut self) {
                ALARM_PLAYING.store(false, Ordering::Release);
            }
        }
        let _guard = PlayingGuard;

        #[cfg(any(target_os = "macos", target_os = "windows"))]
        match play_native(pattern, volume) {
            Ok(()) => log::info!("played native earthquake alarm: {pattern:?}"),
            Err(error) => log::warn!("failed to play earthquake alarm: {error}"),
        }

        #[cfg(not(any(target_os = "macos", target_os = "windows")))]
        {
            let _ = (pattern, volume);
            log::warn!("earthquake alarm playback is supported on Windows and macOS");
        }
    });
}

#[cfg(any(target_os = "macos", target_os = "windows"))]
fn play_native(pattern: AlarmPattern, volume: f32) -> Result<(), String> {
    use rodio::source::{SineWave, Source};
    use rodio::{Decoder, DeviceSinkBuilder, Player};
    use std::io::Cursor;
    use std::time::Duration;

    const JAPANESE_VOICE_WAV: &[u8] = include_bytes!("../assets/quakesignal_japanese_voice.wav");

    fn append_tone(player: &Player, frequency: f32, millis: u64, volume: f32) {
        player.append(
            SineWave::new(frequency)
                .take_duration(Duration::from_millis(millis))
                .amplify(volume),
        );
    }

    fn append_pause(player: &Player, millis: u64) {
        player.append(
            SineWave::new(440.0)
                .take_duration(Duration::from_millis(millis))
                .amplify(0.0),
        );
    }

    let device = DeviceSinkBuilder::open_default_sink().map_err(|error| error.to_string())?;
    let player = Player::connect_new(device.mixer());

    match pattern {
        AlarmPattern::WarningSystem => {
            for _ in 0..2 {
                append_tone(&player, 660.0, 170, volume * 0.85);
                append_pause(&player, 90);
                append_tone(&player, 880.0, 210, volume * 0.85);
                append_pause(&player, 130);
            }
        }
        AlarmPattern::WarningUrgent => {
            for _ in 0..4 {
                append_tone(&player, 880.0, 180, volume);
                append_pause(&player, 70);
                append_tone(&player, 660.0, 180, volume);
                append_pause(&player, 100);
            }
        }
        AlarmPattern::WarningJapaneseVoice => {
            let audio = Decoder::try_from(Cursor::new(JAPANESE_VOICE_WAV))
                .map_err(|error| error.to_string())?;
            player.append(audio.amplify(volume));
        }
        AlarmPattern::Report => {
            append_tone(&player, 660.0, 140, volume * 0.75);
            append_pause(&player, 80);
            append_tone(&player, 880.0, 220, volume * 0.75);
        }
    }

    player.sleep_until_end();
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event(kind: EventKind) -> NormalizedEvent {
        NormalizedEvent {
            id: "test:event".to_string(),
            source_id: "jma_eew".to_string(),
            event_id: "event".to_string(),
            serial: 1,
            kind,
            origin_time_utc: None,
            report_time_utc: Some(chrono::Utc::now().to_rfc3339()),
            hypocenter: "Test".to_string(),
            latitude: None,
            longitude: None,
            magnitude: Some(5.0),
            depth: Some(10.0),
            max_intensity: None,
            is_warn: kind == EventKind::Eew,
            is_final: false,
            is_cancel: false,
            is_training: false,
            tsunami: None,
            raw: serde_json::Value::Null,
        }
    }

    #[test]
    fn selects_patterns_for_real_events() {
        let settings = Settings::default();
        assert_eq!(
            pattern_for(&settings, &event(EventKind::Eew), NotifyReason::New, false),
            Some(AlarmPattern::WarningSystem)
        );
        assert_eq!(
            pattern_for(
                &settings,
                &event(EventKind::Report),
                NotifyReason::Report,
                false
            ),
            Some(AlarmPattern::Report)
        );
    }

    #[test]
    fn selected_warning_sound_controls_real_and_manual_preview_patterns() {
        let urgent = Settings {
            alert_sound: "urgent-tone".to_string(),
            ..Settings::default()
        };
        assert_eq!(
            pattern_for(&urgent, &event(EventKind::Eew), NotifyReason::New, false),
            Some(AlarmPattern::WarningUrgent)
        );

        let voice = Settings {
            alert_sound: "japanese-voice".to_string(),
            ..Settings::default()
        };
        assert_eq!(
            pattern_for(&voice, &event(EventKind::Eew), NotifyReason::New, false),
            Some(AlarmPattern::WarningJapaneseVoice)
        );

        #[cfg(not(feature = "macos-app-store"))]
        assert_eq!(
            pattern_for(&voice, &event(EventKind::Eew), NotifyReason::Training, true),
            Some(AlarmPattern::WarningJapaneseVoice)
        );
    }

    #[cfg(any(target_os = "macos", target_os = "windows"))]
    #[test]
    fn embedded_japanese_voice_is_a_decodable_mono_pcm_asset() {
        use rodio::{Decoder, Source};
        use std::io::Cursor;

        let bytes: &[u8] = include_bytes!("../assets/quakesignal_japanese_voice.wav");
        let decoder = Decoder::try_from(Cursor::new(bytes)).expect("decode embedded voice");
        assert_eq!(decoder.channels().get(), 1);
        assert_eq!(decoder.sample_rate().get(), 22_050);
        let duration = decoder.total_duration().expect("voice duration");
        assert!(duration.as_secs_f32() > 5.4 && duration.as_secs_f32() < 5.5);
    }

    #[test]
    fn stays_silent_for_cancelled_training_and_disabled_events() {
        let settings = Settings::default();
        let mut cancelled = event(EventKind::Eew);
        cancelled.is_cancel = true;
        assert_eq!(
            pattern_for(&settings, &cancelled, NotifyReason::Cancelled, false),
            None
        );

        let mut training = event(EventKind::Eew);
        training.is_training = true;
        assert_eq!(
            pattern_for(&settings, &training, NotifyReason::Training, false),
            None
        );

        let mut informational = event(EventKind::Eew);
        informational.is_warn = false;
        assert_eq!(
            pattern_for(&settings, &informational, NotifyReason::New, false),
            None
        );

        let mut final_event = event(EventKind::Eew);
        final_event.is_final = true;
        assert_eq!(
            pattern_for(&settings, &final_event, NotifyReason::Final, false),
            None
        );

        let disabled = Settings {
            alarm_enabled: false,
            ..Settings::default()
        };
        assert_eq!(
            pattern_for(&disabled, &event(EventKind::Eew), NotifyReason::New, false),
            None
        );
    }

    #[cfg(not(feature = "macos-app-store"))]
    #[test]
    fn explicit_test_uses_test_pattern() {
        assert_eq!(
            pattern_for(
                &Settings::default(),
                &event(EventKind::Eew),
                NotifyReason::Training,
                true
            ),
            Some(AlarmPattern::WarningSystem)
        );
    }

    #[cfg(feature = "macos-app-store")]
    #[test]
    fn store_build_never_selects_a_manual_test_pattern() {
        assert_eq!(
            pattern_for(
                &Settings::default(),
                &event(EventKind::Eew),
                NotifyReason::Training,
                true
            ),
            None
        );
    }
}
