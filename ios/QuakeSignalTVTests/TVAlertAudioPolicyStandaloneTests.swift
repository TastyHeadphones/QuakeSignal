import Foundation

@main
@MainActor
enum TVAlertAudioPolicyStandaloneTests {
    static func main() throws {
        try testPersistenceAndInvalidValueRecovery()
        testPlaybackBoundary()
        testPlaybackCompletionDelay()
        print("TV alert audio policy tests passed")
    }

    private static func testPersistenceAndInvalidValueRecovery() throws {
        let suiteName = "TVAlertAudioPolicyStandaloneTests-\(UUID().uuidString)"
        let defaults = try require(UserDefaults(suiteName: suiteName), "missing test defaults")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = TVAlertPreferences(defaults: defaults)
        expect(settings.alertSound == .system, "the safe default must be visual-only System")

        settings.alertSound = .japaneseVoice
        expect(
            TVAlertPreferences(defaults: defaults).alertSound == .japaneseVoice,
            "the explicit Japanese voice choice must persist"
        )

        defaults.set("unknown-future-sound", forKey: "settings.alertSound")
        let recovered = TVAlertPreferences(defaults: defaults)
        expect(recovered.alertSound == .system, "unknown raw values must fail closed")
        expect(
            defaults.string(forKey: "settings.alertSound") == AlertSoundPreference.system.rawValue,
            "invalid persisted state must be normalized"
        )
    }

    private static func testPlaybackBoundary() {
        expect(
            !TVAlertAudioPolicy.permitsUserInitiatedPlayback(.system),
            "tvOS System must remain visual-only"
        )
        expect(
            TVAlertAudioPolicy.permitsUserInitiatedPlayback(.urgentTone),
            "the original urgent tone should support explicit preview"
        )
        expect(
            TVAlertAudioPolicy.permitsUserInitiatedPlayback(.japaneseVoice),
            "the licensed Japanese voice should support explicit preview"
        )
        for preference in AlertSoundPreference.allCases {
            expect(
                !TVAlertAudioPolicy.permitsAutomaticWarningPlayback(preference),
                "no Apple TV sound may start from warning ingestion"
            )
        }
    }

    private static func testPlaybackCompletionDelay() {
        expect(
            TVAlertAudioPolicy.playbackCompletionDelay(for: 2) == 2.25,
            "natural completion must allow the player duration plus a short margin"
        )
        expect(
            TVAlertAudioPolicy.playbackCompletionDelay(for: -1) == 0.25,
            "invalid negative durations must still produce a bounded cleanup delay"
        )
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else {
            FileHandle.standardError.write(Data("error: \(message)\n".utf8))
            exit(1)
        }
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            throw NSError(
                domain: "TVAlertAudioPolicyStandaloneTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
        return value
    }
}
