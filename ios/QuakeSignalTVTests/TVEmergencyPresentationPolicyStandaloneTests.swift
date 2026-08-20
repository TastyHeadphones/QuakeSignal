import Foundation

@main
enum TVEmergencyPresentationPolicyStandaloneTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func main() {
        testFirstSnapshotIsOnlyABaseline()
        testLiveWarningsAndUpdatesPresentOnce()
        testBackfillCanOnlyUpdateKnownState()
        testTerminalStateClearsAndCannotBeResurrected()
        testUnrelatedAndNonEEWFramesCannotDismissAnAlert()
        testFreshnessFailsClosed()
        testSameSerialPromotionAndRegressions()
        print("TV emergency presentation policy tests passed")
    }

    private static func testFirstSnapshotIsOnlyABaseline() {
        let warning = revision()
        expect(
            TVEmergencyPresentationPolicy.action(
                for: warning,
                previous: nil,
                presentedEventID: nil,
                isBackfill: true,
                hadLocalHistoryBeforeBatch: false,
                now: now
            ) == .baseline,
            "a retained first snapshot must not impersonate a new warning"
        )
        expect(
            TVEmergencyPresentationPolicy.action(
                for: warning,
                previous: nil,
                presentedEventID: nil,
                isBackfill: false,
                hadLocalHistoryBeforeBatch: false,
                now: now
            ) == .presentNew,
            "a fresh post-seed warning should present"
        )
    }

    private static func testLiveWarningsAndUpdatesPresentOnce() {
        let first = revision(serial: 1)
        let update = revision(serial: 2, secondsFromNow: 1)
        expect(
            TVEmergencyPresentationPolicy.action(
                for: update,
                previous: first,
                presentedEventID: nil,
                isBackfill: false,
                hadLocalHistoryBeforeBatch: true,
                now: now.addingTimeInterval(1)
            ) == .presentUpdate,
            "a newer known warning should reopen as an update after dismissal"
        )
        expect(
            TVEmergencyPresentationPolicy.action(
                for: update,
                previous: first,
                presentedEventID: first.eventID,
                isBackfill: false,
                hadLocalHistoryBeforeBatch: true,
                now: now.addingTimeInterval(1)
            ) == .updatePresented,
            "a visible warning should update in place"
        )
        expect(
            TVEmergencyPresentationPolicy.action(
                for: first,
                previous: first,
                presentedEventID: nil,
                isBackfill: false,
                hadLocalHistoryBeforeBatch: true,
                now: now
            ) == .ignore,
            "a replay of the same revision must not reopen a dismissed alert"
        )
    }

    private static func testBackfillCanOnlyUpdateKnownState() {
        let first = revision(serial: 1)
        let update = revision(serial: 2, secondsFromNow: 1)
        expect(
            TVEmergencyPresentationPolicy.action(
                for: update,
                previous: first,
                presentedEventID: nil,
                isBackfill: true,
                hadLocalHistoryBeforeBatch: true,
                now: now.addingTimeInterval(1)
            ) == .presentUpdate,
            "a reconnect baseline may surface a monotonic update to known local state"
        )
        expect(
            TVEmergencyPresentationPolicy.action(
                for: revision(eventID: "retained-other"),
                previous: nil,
                presentedEventID: nil,
                isBackfill: true,
                hadLocalHistoryBeforeBatch: false,
                now: now
            ) == .baseline,
            "an unknown reconnect event remains baseline-only"
        )
        expect(
            TVEmergencyPresentationPolicy.action(
                for: update,
                previous: first,
                presentedEventID: nil,
                isBackfill: true,
                hadLocalHistoryBeforeBatch: false,
                now: now.addingTimeInterval(1)
            ) == .baseline,
            "multiple revisions inside a first retained batch remain baseline-only"
        )
    }

    private static func testTerminalStateClearsAndCannotBeResurrected() {
        let active = revision(serial: 3)
        let final = revision(serial: 4, isFinal: true)
        expect(
            TVEmergencyPresentationPolicy.action(
                for: final,
                previous: active,
                presentedEventID: active.eventID,
                isBackfill: false,
                hadLocalHistoryBeforeBatch: true,
                now: now
            ) == .clearPresented,
            "a final frame must retire the visible warning"
        )
        let replay = revision(serial: 5, secondsFromNow: 1)
        expect(
            TVEmergencyPresentationPolicy.action(
                for: replay,
                previous: final,
                presentedEventID: nil,
                isBackfill: false,
                hadLocalHistoryBeforeBatch: true,
                now: now.addingTimeInterval(1)
            ) == .ignore,
            "an active replay must never resurrect terminal state"
        )
    }

    private static func testUnrelatedAndNonEEWFramesCannotDismissAnAlert() {
        let report = revision(eventID: "report", isEEW: false, isWarning: false)
        expect(
            TVEmergencyPresentationPolicy.action(
                for: report,
                previous: nil,
                presentedEventID: "warning",
                isBackfill: false,
                hadLocalHistoryBeforeBatch: false,
                now: now
            ) == .ignore,
            "ordinary reports must not affect emergency presentation"
        )
        let unrelatedFinal = revision(eventID: "unrelated", isFinal: true)
        expect(
            TVEmergencyPresentationPolicy.action(
                for: unrelatedFinal,
                previous: nil,
                presentedEventID: "warning",
                isBackfill: false,
                hadLocalHistoryBeforeBatch: false,
                now: now
            ) == .baseline,
            "an unrelated terminal frame must not clear the current warning"
        )
    }

    private static func testFreshnessFailsClosed() {
        let stale = revision(secondsFromNow: -601)
        let future = revision(secondsFromNow: 61)
        let missingDate = revision(reportDate: nil)
        for candidate in [stale, future, missingDate] {
            expect(
                TVEmergencyPresentationPolicy.action(
                    for: candidate,
                    previous: nil,
                    presentedEventID: nil,
                    isBackfill: false,
                    hadLocalHistoryBeforeBatch: false,
                    now: now
                ) == .baseline,
                "stale, future, and undated warnings must remain non-interruptive"
            )
        }
        expect(
            TVEmergencyPresentationPolicy.shouldExpire(stale, now: now),
            "the foreground clock must expire stale warnings"
        )
    }

    private static func testSameSerialPromotionAndRegressions() {
        let informational = revision(isWarning: false)
        let warning = revision()
        expect(
            TVEmergencyPresentationPolicy.isMonotonic(warning, replacing: informational),
            "same-serial warning promotion should be accepted"
        )
        expect(
            !TVEmergencyPresentationPolicy.isMonotonic(informational, replacing: warning),
            "same-serial informational replay must not erase a warning"
        )
        expect(
            !TVEmergencyPresentationPolicy.isMonotonic(
                revision(serial: 1),
                replacing: revision(serial: 2)
            ),
            "older serials must be rejected"
        )
    }

    private static func revision(
        eventID: String = "warning",
        serial: Int = 1,
        secondsFromNow: TimeInterval = 0,
        reportDate: Date? = now,
        isEEW: Bool = true,
        isWarning: Bool = true,
        isFinal: Bool = false,
        isCancelled: Bool = false,
        isTraining: Bool = false
    ) -> TVEmergencyRevision {
        TVEmergencyRevision(
            eventID: eventID,
            serial: serial,
            reportDate: reportDate.map { $0.addingTimeInterval(secondsFromNow) },
            isEEW: isEEW,
            isWarning: isWarning,
            isFinal: isFinal,
            isCancelled: isCancelled,
            isTraining: isTraining
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
}
