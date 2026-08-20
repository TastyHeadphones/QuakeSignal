import AVFAudio
import Foundation

enum TVAlertAudioPlaybackResult: Equatable, Sendable {
    case played
    case visualOnly
    case unavailable
}

/// Short foreground playback that can only be reached from an explicit tvOS
/// button action. There is deliberately no event- or lifecycle-based play API.
/// The ambient category mixes with other audio and the scene owner stops the
/// player whenever QuakeSignal is no longer active.
@MainActor
final class TVUserInitiatedAlertAudio {
    private var player: AVAudioPlayer?
    private var playbackCompletionTask: Task<Void, Never>?

    func playUserInitiated(
        _ preference: AlertSoundPreference
    ) -> TVAlertAudioPlaybackResult {
        guard TVAlertAudioPolicy.permitsUserInitiatedPlayback(preference),
              let filename = preference.bundledFilename else {
            stop()
            return .visualOnly
        }
        guard let url = Bundle.main.url(forResource: filename, withExtension: nil) else {
            stop()
            return .unavailable
        }

        stop()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let nextPlayer = try AVAudioPlayer(contentsOf: url)
            guard nextPlayer.prepareToPlay(), nextPlayer.play() else {
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                return .unavailable
            }
            player = nextPlayer
            let completionDelay = TVAlertAudioPolicy.playbackCompletionDelay(
                for: nextPlayer.duration
            )
            playbackCompletionTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .seconds(completionDelay))
                } catch {
                    return
                }
                self?.finishCompletedPlayback()
            }
            return .played
        } catch {
            stop()
            return .unavailable
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
