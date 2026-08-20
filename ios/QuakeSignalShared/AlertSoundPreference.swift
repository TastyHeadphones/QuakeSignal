import Foundation

/// Stable sound choices shared by every native Apple surface and by the
/// notification Worker wire format. The names deliberately describe
/// QuakeSignal-owned sounds, not a government warning system.
enum AlertSoundPreference: String, CaseIterable, Codable, Sendable, Equatable {
    case system
    case urgentTone = "urgent-tone"
    case japaneseVoice = "japanese-voice"

    var titleKey: String {
        switch self {
        case .system: "settings.alertSound.system"
        case .urgentTone: "settings.alertSound.urgentTone"
        case .japaneseVoice: "settings.alertSound.japaneseVoice"
        }
    }

    var detailKey: String {
        switch self {
        case .system: "settings.alertSound.system.detail"
        case .urgentTone: "settings.alertSound.urgentTone.detail"
        case .japaneseVoice: "settings.alertSound.japaneseVoice.detail"
        }
    }

    var systemImage: String {
        switch self {
        case .system: "bell"
        case .urgentTone: "waveform"
        case .japaneseVoice: "person.wave.2"
        }
    }

    var bundledFilename: String? {
        switch self {
        case .system: nil
        case .urgentTone: "quakesignal_urgent.caf"
        case .japaneseVoice: "quakesignal_japanese_voice.caf"
        }
    }
}
