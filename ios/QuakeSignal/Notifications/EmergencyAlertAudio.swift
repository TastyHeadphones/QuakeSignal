import AudioToolbox
import AVFAudio
import Foundation

/// Mirrors the user-selected custom APNs sound when a warning arrives while
/// QuakeSignal is already in the foreground. The System Default choice uses a
/// short platform system alert because Apple's default notification sound is
/// not exposed as a playable file. APNs handles suspended and terminated
/// delivery. The `.ambient` audio session intentionally respects Silent Mode,
/// Focus, and the person's volume; this is not a Critical Alert.
@MainActor
final class EmergencyAlertAudio {
    static let shared = EmergencyAlertAudio()

    private enum PlaybackOwner {
        case preview
        case emergency
    }

    private var player: AVAudioPlayer?
    private var playbackCompletionTask: Task<Void, Never>?
    private var playbackOwner: PlaybackOwner?
    private var recentPlaybackKeys: [ForegroundEmergencyRevisionKey: Date] = [:]
    private let duplicateWindow: TimeInterval = 15

    private init() {}

    func preview(_ preference: AlertSoundPreference) {
        play(preference, deduplicationKey: nil, owner: .preview)
    }

    func playSelectedSound(for event: EEWEvent, reason: AlertPresentationReason) {
        guard ForegroundEmergencyAudioPolicy.shouldPlay(event: event, reason: reason) else {
            return
        }
        let key = ForegroundEmergencyRevisionOwnershipPolicy.key(for: event)
        play(AppSettings.shared.alertSound, deduplicationKey: key, owner: .emergency)
    }

    /// Navigation owns previews, but not a warning that may have replaced one
    /// while the preview screen was disappearing.
    func stopPreview() {
        guard playbackOwner == .preview else { return }
        stop()
    }

    /// Scene deactivation ends any app-owned playback immediately. APNs owns
    /// notification sounds delivered while an eligible iPhone/iPad app is in
    /// the background; a foreground player must never bridge that boundary.
    func stop() {
        playbackCompletionTask?.cancel()
        playbackCompletionTask = nil
        player?.stop()
        player = nil
        playbackOwner = nil
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    private func play(
        _ preference: AlertSoundPreference,
        deduplicationKey: ForegroundEmergencyRevisionKey?,
        owner: PlaybackOwner
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

        stop()
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
            guard nextPlayer.prepareToPlay(), nextPlayer.play() else {
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                AudioServicesPlaySystemSound(1007)
                return
            }
            player = nextPlayer
            playbackOwner = owner
            let duration = max(nextPlayer.duration, 0)
            playbackCompletionTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .seconds(duration + 0.25))
                } catch {
                    return
                }
                self?.finishCompletedPlayback()
            }
        } catch {
            stop()
            AudioServicesPlaySystemSound(1007)
        }
    }

    private func finishCompletedPlayback() {
        playbackCompletionTask = nil
        player = nil
        playbackOwner = nil
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }
}
