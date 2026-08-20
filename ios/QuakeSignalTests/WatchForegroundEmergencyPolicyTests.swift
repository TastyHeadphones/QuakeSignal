import XCTest
@testable import QuakeSignal

final class WatchForegroundEmergencyPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testFreshLiveWarningPresentsAndDuplicateIsIgnored() {
        let event = makeEvent(serial: 3)

        XCTAssertEqual(action(for: event), .presentNew)
        XCTAssertEqual(action(for: event, previous: event), .ignore)
    }

    func testHigherSerialPresentsAsUpdateButOlderReplayDoesNotRegress() {
        let original = makeEvent(serial: 3)
        let update = makeEvent(serial: 4, reportDate: now.addingTimeInterval(-5))

        XCTAssertEqual(
            action(
                for: update,
                previous: original,
                hadLocalHistoryBeforeBatch: true
            ),
            .presentUpdate
        )
        XCTAssertEqual(
            action(
                for: original,
                previous: update,
                hadLocalHistoryBeforeBatch: true
            ),
            .ignore
        )
    }

    func testUnknownBackfillOnlySeedsButKnownBackfillCanPresentAnUpdate() {
        let original = makeEvent(serial: 3)
        let update = makeEvent(serial: 4, reportDate: now.addingTimeInterval(-5))

        XCTAssertEqual(
            action(for: original, isBackfill: true),
            .baseline,
            "a first retained socket or HTTP snapshot must not impersonate a new warning"
        )
        XCTAssertEqual(
            action(
                for: update,
                previous: original,
                isBackfill: true,
                hadLocalHistoryBeforeBatch: true
            ),
            .presentUpdate,
            "reconnect backfill may surface a monotonic update to known foreground state"
        )
    }

    func testEveryRevisionInAFirstRetainedBatchRemainsBaselineOnly() {
        let first = makeEvent(serial: 1, reportDate: now.addingTimeInterval(-10))
        let second = makeEvent(serial: 2, reportDate: now.addingTimeInterval(-5))

        XCTAssertEqual(action(for: first, isBackfill: true), .baseline)
        XCTAssertEqual(
            action(
                for: second,
                previous: first,
                isBackfill: true,
                hadLocalHistoryBeforeBatch: false
            ),
            .baseline
        )
    }

    func testTerminalRevisionClearsAndCannotBeResurrected() {
        let active = makeEvent(serial: 3)
        let final = makeEvent(
            serial: 4,
            reportDate: now.addingTimeInterval(-5),
            isFinal: true
        )
        let replay = makeEvent(
            serial: 5,
            reportDate: now.addingTimeInterval(-4)
        )

        XCTAssertEqual(
            action(
                for: final,
                previous: active,
                presentedEventID: active.id,
                hadLocalHistoryBeforeBatch: true
            ),
            .clearPresented
        )
        XCTAssertEqual(
            action(
                for: replay,
                previous: final,
                hadLocalHistoryBeforeBatch: true
            ),
            .ignore
        )
    }

    func testOnlyFreshStructurallyUsableActiveJmaEewCanPresent() {
        let stale = makeEvent(
            reportDate: now.addingTimeInterval(-WarningFreshnessPolicy.maximumAge - 1)
        )
        let future = makeEvent(
            reportDate: now.addingTimeInterval(WarningFreshnessPolicy.allowedFutureSkew + 1)
        )
        let report = makeEvent(kind: "report", isWarn: false, isFinal: true)
        let training = makeEvent(isTraining: true)
        let cancelled = makeEvent(isCancel: true)
        let wrongSource = makeEvent(sourceID: "jma_eqlist")
        let missingCoordinate = makeEvent(latitude: nil)
        let missingMagnitude = makeEvent(magnitude: nil)
        let missingIntensity = makeEvent(maxIntensity: nil)
        let malformedID = makeEvent(id: "wrong-id")

        XCTAssertEqual(action(for: stale), .baseline)
        XCTAssertEqual(action(for: future), .baseline)
        XCTAssertEqual(action(for: training), .baseline)
        XCTAssertEqual(action(for: cancelled), .baseline)
        XCTAssertEqual(action(for: missingCoordinate), .baseline)
        XCTAssertEqual(action(for: missingMagnitude), .baseline)
        XCTAssertEqual(action(for: missingIntensity), .baseline)
        XCTAssertEqual(action(for: report), .ignore)
        XCTAssertEqual(action(for: wrongSource), .ignore)
        XCTAssertEqual(action(for: malformedID), .ignore)
    }

    func testSameSerialWarningPromotionIsMonotonicButRegressionIsNot() {
        let informational = makeEvent(isWarn: false)
        let warning = makeEvent(reportDate: now.addingTimeInterval(-5))

        XCTAssertTrue(
            WatchForegroundEmergencyPolicy.isMonotonic(
                warning,
                replacing: informational
            )
        )
        XCTAssertFalse(
            WatchForegroundEmergencyPolicy.isMonotonic(
                informational,
                replacing: warning
            )
        )
    }

    func testWatchPreferenceContextIsExactVersionedAndFailSafe() {
        let context = WatchAlertPreferenceContext.applicationContext(for: .japaneseVoice)
        XCTAssertEqual(context.count, 2)
        XCTAssertEqual(context[WatchAlertPreferenceContext.schemaVersionKey] as? Int, 1)
        XCTAssertEqual(
            WatchAlertPreferenceContext.preference(from: context),
            .japaneseVoice
        )

        var unknown = context
        unknown[WatchAlertPreferenceContext.alertSoundKey] = "government-siren"
        XCTAssertNil(WatchAlertPreferenceContext.preference(from: unknown))

        var future = context
        future[WatchAlertPreferenceContext.schemaVersionKey] = 2
        XCTAssertNil(WatchAlertPreferenceContext.preference(from: future))

        var booleanVersion = context
        booleanVersion[WatchAlertPreferenceContext.schemaVersionKey] = true
        XCTAssertNil(WatchAlertPreferenceContext.preference(from: booleanVersion))

        var floatingVersion = context
        floatingVersion[WatchAlertPreferenceContext.schemaVersionKey] = 1.0
        XCTAssertNil(WatchAlertPreferenceContext.preference(from: floatingVersion))

        var expanded = context
        expanded["event"] = "must-not-become-a-data-relay"
        XCTAssertNil(WatchAlertPreferenceContext.preference(from: expanded))
    }

    func testWatchPreferencePersistenceRejectsMalformedContextAndNormalizesCorruption() throws {
        let suite = "WatchForegroundEmergencyPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("corrupt", forKey: WatchAlertPreferenceContext.watchDefaultsKey)
        XCTAssertEqual(WatchAlertPreferenceContext.storedPreference(defaults: defaults), .system)
        WatchAlertPreferenceContext.normalizeStoredPreference(defaults: defaults)
        XCTAssertEqual(
            defaults.string(forKey: WatchAlertPreferenceContext.watchDefaultsKey),
            AlertSoundPreference.system.rawValue
        )

        XCTAssertFalse(WatchAlertPreferenceContext.persist(
            applicationContext: [WatchAlertPreferenceContext.alertSoundKey: "urgent-tone"],
            defaults: defaults
        ))
        XCTAssertEqual(WatchAlertPreferenceContext.storedPreference(defaults: defaults), .system)

        XCTAssertTrue(WatchAlertPreferenceContext.persist(
            applicationContext: WatchAlertPreferenceContext.applicationContext(for: .urgentTone),
            defaults: defaults
        ))
        XCTAssertEqual(WatchAlertPreferenceContext.storedPreference(defaults: defaults), .urgentTone)
    }

    private func action(
        for incoming: EEWEvent,
        previous: EEWEvent? = nil,
        presentedEventID: String? = nil,
        isBackfill: Bool = false,
        hadLocalHistoryBeforeBatch: Bool = false
    ) -> WatchEmergencyPresentationAction {
        WatchForegroundEmergencyPolicy.action(
            for: incoming,
            previous: previous,
            presentedEventID: presentedEventID,
            isBackfill: isBackfill,
            hadLocalHistoryBeforeBatch: hadLocalHistoryBeforeBatch,
            now: now
        )
    }

    private func makeEvent(
        id: String? = nil,
        sourceID: String = "jma_eew",
        eventID: String = "20270115090000",
        serial: Int = 1,
        kind: String = "eew",
        reportDate: Date? = nil,
        latitude: Double? = 35.68,
        longitude: Double? = 139.76,
        magnitude: Double? = 6.4,
        maxIntensity: String? = "6-",
        isWarn: Bool = true,
        isFinal: Bool = false,
        isCancel: Bool = false,
        isTraining: Bool = false
    ) -> EEWEvent {
        let resolvedReportDate = reportDate ?? now.addingTimeInterval(-10)
        return EEWEvent(
            id: id ?? "\(sourceID):\(eventID)",
            sourceId: sourceID,
            eventId: eventID,
            serial: serial,
            kind: kind,
            originTimeUtc: Self.iso8601(resolvedReportDate.addingTimeInterval(-5)),
            reportTimeUtc: Self.iso8601(resolvedReportDate),
            hypocenter: "Tokyo Bay",
            latitude: latitude,
            longitude: longitude,
            magnitude: magnitude,
            depth: 40,
            maxIntensity: maxIntensity,
            isWarn: isWarn,
            isFinal: isFinal,
            isCancel: isCancel,
            isTraining: isTraining,
            tsunami: nil
        )
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
