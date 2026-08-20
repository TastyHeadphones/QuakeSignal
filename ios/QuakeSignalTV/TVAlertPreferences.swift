import Foundation
import Observation

/// Apple TV keeps a local sound choice without registering a push subscription.
/// The raw value intentionally matches the iPhone/iPad wire preference so the
/// three choices remain semantically identical across native Apple surfaces.
@Observable
@MainActor
final class TVAlertPreferences {
    var alertSound: AlertSoundPreference {
        didSet {
            defaults.set(alertSound.rawValue, forKey: Self.alertSoundKey)
        }
    }

    private static let alertSoundKey = "settings.alertSound"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let storedValue = defaults.string(forKey: Self.alertSoundKey),
           let storedPreference = AlertSoundPreference(rawValue: storedValue) {
            alertSound = storedPreference
        } else {
            alertSound = .system
            if defaults.object(forKey: Self.alertSoundKey) != nil {
                defaults.set(AlertSoundPreference.system.rawValue, forKey: Self.alertSoundKey)
            }
        }
    }
}

/// tvOS does not accompany alerts or notifications with system sounds. Custom
/// QuakeSignal audio is therefore available only after a person explicitly
/// chooses a Preview/Play button with the Remote; warning ingestion itself can
/// never initiate playback.
enum TVAlertAudioPolicy {
    static let playbackCompletionMargin: TimeInterval = 0.25

    static func permitsUserInitiatedPlayback(_ preference: AlertSoundPreference) -> Bool {
        preference.bundledFilename != nil
    }

    static func permitsAutomaticWarningPlayback(_ preference: AlertSoundPreference) -> Bool {
        false
    }

    static func playbackCompletionDelay(for duration: TimeInterval) -> TimeInterval {
        max(duration, 0) + playbackCompletionMargin
    }
}
