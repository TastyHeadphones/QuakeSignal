import AudioToolbox
import AVFAudio
import Foundation

/// Plays the same user-selected sound used by APNs when a warning arrives
/// while QuakeSignal is already in the foreground. APNs handles suspended and
/// terminated delivery. The `.ambient` audio session intentionally respects
/// Silent Mode, Focus, and the person's volume; this is not a Critical Alert.
@MainActor
final class EmergencyAlertAudio {
    static let shared = EmergencyAlertAudio()

    private var player: AVAudioPlayer?
    private var recentPlaybackKeys: [String: Date] = [:]
    private let duplicateWindow: TimeInterval = 15

    private init() {}

    func preview(_ preference: AlertSoundPreference) {
        play(preference, deduplicationKey: nil)
    }

    func playSelectedSound(for event: EEWEvent, reason: AlertPresentationReason) {
        guard event.isActiveWarning else { return }
        let key = "\(event.id)#\(event.serial)#\(reason.rawValue)"
        play(AppSettings.shared.alertSound, deduplicationKey: key)
    }

    /// Scene deactivation ends any app-owned playback immediately. APNs owns
    /// notification sounds delivered while an eligible iPhone/iPad app is in
    /// the background; a foreground player must never bridge that boundary.
    func stop() {
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    private func play(
        _ preference: AlertSoundPreference,
        deduplicationKey: String?
    ) {
        let now = Date()
        recentPlaybackKeys = recentPlaybackKeys.filter {
            now.timeIntervalSince($0.value) <= duplicateWindow
        }
        if let deduplicationKey,
           let previous = recentPlaybackKeys[deduplicationKey],
           now.timeIntervalSince(previous) <= duplicateWindow {
            return
        }
        if let deduplicationKey {
            recentPlaybackKeys[deduplicationKey] = now
        }

        guard let filename = preference.bundledFilename else {
            AudioServicesPlaySystemSound(1007)
            return
        }
        guard let url = Bundle.main.url(forResource: filename, withExtension: nil) else {
            // A missing custom resource must fail safely to a normal system
            // sound instead of turning an emergency warning silent.
            AudioServicesPlaySystemSound(1007)
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.ambient, options: [.mixWithOthers])
            try session.setActive(true)
            let nextPlayer = try AVAudioPlayer(contentsOf: url)
            nextPlayer.prepareToPlay()
            nextPlayer.play()
            player = nextPlayer
        } catch {
            AudioServicesPlaySystemSound(1007)
        }
    }
}
