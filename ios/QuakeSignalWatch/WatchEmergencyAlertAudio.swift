import AVFAudio
import Foundation

/// Adds the selected QuakeSignal-owned custom sound to the Watch's native
/// warning haptic while the app is active. System Default intentionally has no
/// fabricated sound ID on watchOS; the SwiftUI warning feedback remains the
/// system-owned signal for that choice.
@MainActor
final class WatchEmergencyAlertAudio {
    static let shared = WatchEmergencyAlertAudio()

    private var player: AVAudioPlayer?
    private var playbackCompletionTask: Task<Void, Never>?

    private init() {}

    func playCustomSound(for preference: AlertSoundPreference) {
        stop()
        guard let filename = preference.bundledFilename,
              let url = Bundle.main.url(forResource: filename, withExtension: nil) else {
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let nextPlayer = try AVAudioPlayer(contentsOf: url)
            guard nextPlayer.prepareToPlay(), nextPlayer.play() else {
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                return
            }

            player = nextPlayer
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
            // The native warning haptic is the fail-safe signal. Never route a
            // failed custom file through an undocumented Watch sound ID.
            stop()
        }
    }

    func stop() {
        playbackCompletionTask?.cancel()
        playbackCompletionTask = nil
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    private func finishCompletedPlayback() {
        playbackCompletionTask = nil
        player = nil
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }
}
