import CoreLocation
import XCTest
@testable import QuakeSignal

final class AlertPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_787_000_000)

    func testOnlyFreshMatchingActionableWarningTakesOverForeground() {
        let event = makeEvent(reportDate: now, isWarn: true)
        let matching = preferences()

        XCTAssertEqual(
            ForegroundAlertPolicy.presentationReason(
                for: event,
                previous: nil,
                isBackfill: false,
                preferences: matching,
                now: now
            ),
            .new
        )
        XCTAssertNil(ForegroundAlertPolicy.presentationReason(
            for: event,
            previous: nil,
            isBackfill: true,
            preferences: matching,
            now: now
        ))
        XCTAssertNil(ForegroundAlertPolicy.presentationReason(
            for: event,
            previous: nil,
            isBackfill: false,
            preferences: preferences(subscriptionEnabled: false),
            now: now
        ))
        XCTAssertNil(ForegroundAlertPolicy.presentationReason(
            for: event,
            previous: nil,
            isBackfill: false,
            preferences: preferences(enabledSources: []),
            now: now
        ))
        XCTAssertNil(ForegroundAlertPolicy.presentationReason(
            for: event,
            previous: nil,
            isBackfill: false,
            preferences: preferences(minimumMagnitude: 6),
            now: now
        ))
        XCTAssertNil(ForegroundAlertPolicy.presentationReason(
            for: event,
            previous: nil,
            isBackfill: false,
            preferences: preferences(
                coordinate: CLLocationCoordinate2D(latitude: 35.681, longitude: 139.767),
                radiusKm: 10
            ),
            now: now
        ))
    }

    func testInformationalTerminalAndStaleFramesNeverMasqueradeAsEmergency() {
        let matching = preferences()
        XCTAssertNil(reason(for: makeEvent(reportDate: now, isWarn: false), preferences: matching))
        XCTAssertNil(reason(for: makeEvent(reportDate: now, isWarn: true, isFinal: true), preferences: matching))
        XCTAssertNil(reason(for: makeEvent(reportDate: now, isWarn: true, isCancel: true), preferences: matching))
        XCTAssertNil(reason(
            for: makeEvent(reportDate: now.addingTimeInterval(-601), isWarn: true),
            preferences: matching
        ))
    }

    func testCompanionHeadlineRejectsStaleAndFutureWarningsForLatestReport() {
        let latestReport = makeEvent(
            id: "jma_eqlist:latest",
            kind: "report",
            reportDate: now.addingTimeInterval(-30),
            isWarn: false
        )
        let olderReport = makeEvent(
            id: "jma_eqlist:older",
            kind: "report",
            reportDate: now.addingTimeInterval(-60),
            isWarn: false
        )
        let staleWarning = makeEvent(
            id: "jma_eew:stale",
            reportDate: now.addingTimeInterval(-601),
            isWarn: true
        )
        let futureWarning = makeEvent(
            id: "jma_eew:future",
            reportDate: now.addingTimeInterval(61),
            isWarn: true
        )

        XCTAssertEqual(
            ForegroundHeadlinePolicy.headline(
                from: [olderReport, staleWarning, latestReport],
                now: now
            ),
            latestReport
        )
        XCTAssertEqual(
            ForegroundHeadlinePolicy.headline(
                from: [futureWarning, olderReport, latestReport],
                now: now
            ),
            latestReport
        )

        let freshWarning = makeEvent(
            id: "jma_eew:fresh",
            reportDate: now.addingTimeInterval(-600),
            isWarn: true
        )
        let allowedFutureWarning = makeEvent(
            id: "jma_eew:bounded-future",
            reportDate: now.addingTimeInterval(60),
            isWarn: true
        )
        XCTAssertEqual(
            ForegroundHeadlinePolicy.headline(from: [latestReport, freshWarning], now: now),
            freshWarning
        )
        XCTAssertEqual(
            ForegroundHeadlinePolicy.headline(from: [latestReport, allowedFutureWarning], now: now),
            allowedFutureWarning
        )

        XCTAssertNil(ForegroundHeadlinePolicy.headline(from: [staleWarning], now: now))
        XCTAssertNil(ForegroundHeadlinePolicy.headline(from: [futureWarning], now: now))
    }

    func testTrainingRequiresExplicitOptInAndReconnectUpdateIsRecognized() {
        let training = makeEvent(reportDate: now, isWarn: false, isTraining: true)
        XCTAssertNil(reason(for: training, preferences: preferences(includeTraining: false)))
        XCTAssertEqual(reason(for: training, preferences: preferences(includeTraining: true)), .training)

        let previous = makeEvent(serial: 1, reportDate: now.addingTimeInterval(-5), isWarn: true)
        let update = makeEvent(serial: 2, reportDate: now, isWarn: true)
        XCTAssertEqual(
            ForegroundAlertPolicy.presentationReason(
                for: update,
                previous: previous,
                isBackfill: true,
                preferences: preferences(),
                now: now
            ),
            .updated
        )
    }

    func testMonotonicMergeRejectsOlderAndTerminalRegressions() {
        let current = makeEvent(serial: 3, reportDate: now, isWarn: true)
        let older = makeEvent(serial: 2, reportDate: now.addingTimeInterval(10), isWarn: true)
        XCTAssertFalse(EventMergePolicy.shouldAccept(older, replacing: current))
        XCTAssertFalse(EventMergePolicy.shouldAccept(current, replacing: current))

        let final = makeEvent(serial: 3, reportDate: now, isWarn: true, isFinal: true)
        let sameSerialPreliminary = makeEvent(
            serial: 3,
            reportDate: now.addingTimeInterval(5),
            isWarn: true
        )
        XCTAssertFalse(EventMergePolicy.shouldAccept(sameSerialPreliminary, replacing: final))
        let laterActive = makeEvent(
            serial: 4,
            reportDate: now.addingTimeInterval(5),
            isWarn: true
        )
        XCTAssertFalse(EventMergePolicy.shouldAccept(laterActive, replacing: final))

        let cancelled = makeEvent(
            serial: 3,
            reportDate: now,
            isWarn: true,
            isCancel: true
        )
        XCTAssertFalse(EventMergePolicy.shouldAccept(laterActive, replacing: cancelled))

        let informational = makeEvent(serial: 3, reportDate: now, isWarn: false)
        let promotedWarning = makeEvent(serial: 3, reportDate: now, isWarn: true)
        XCTAssertTrue(EventMergePolicy.shouldAccept(promotedWarning, replacing: informational))
        XCTAssertFalse(EventMergePolicy.shouldAccept(informational, replacing: promotedWarning))
    }

    func testForegroundPushRejectsStaleAndTerminalRegressions() {
        let preferences = preferences()
        let current = makeEvent(serial: 4, reportDate: now, isWarn: true)
        let stale = makeEvent(
            serial: 3,
            reportDate: now.addingTimeInterval(1),
            isWarn: true
        )
        XCTAssertNil(ForegroundPushPolicy.presentationReason(
            for: stale,
            previous: current,
            requestedReason: .updated,
            preferences: preferences,
            now: now
        ))

        let final = makeEvent(serial: 4, reportDate: now, isWarn: true, isFinal: true)
        let reopened = makeEvent(
            serial: 5,
            reportDate: now.addingTimeInterval(1),
            isWarn: true
        )
        XCTAssertNil(ForegroundPushPolicy.presentationReason(
            for: reopened,
            previous: final,
            requestedReason: .new,
            preferences: preferences,
            now: now
        ))

        XCTAssertEqual(ForegroundPushPolicy.presentationReason(
            for: reopened,
            previous: current,
            requestedReason: .updated,
            preferences: preferences,
            now: now
        ), .updated)
    }

    func testForegroundPushMergesTerminalLifecycleWithoutEmergencyPresentation() {
        let current = makeEvent(serial: 4, reportDate: now, isWarn: true)
        let final = makeEvent(
            serial: 5,
            reportDate: now.addingTimeInterval(1),
            isWarn: true,
            isFinal: true
        )
        let cancellation = makeEvent(
            serial: 6,
            reportDate: now.addingTimeInterval(2),
            isWarn: true,
            isCancel: true
        )

        let finalDecision = ForegroundPushPolicy.ingestionDecision(
            for: final,
            previous: current,
            requestedReason: .final,
            preferences: preferences(),
            now: now
        )
        XCTAssertTrue(finalDecision.shouldMerge)
        XCTAssertNil(finalDecision.presentationReason)

        let cancellationDecision = ForegroundPushPolicy.ingestionDecision(
            for: cancellation,
            previous: final,
            requestedReason: .cancelled,
            preferences: preferences(),
            now: now
        )
        XCTAssertTrue(cancellationDecision.shouldMerge)
        XCTAssertNil(cancellationDecision.presentationReason)

        let replayDecision = ForegroundPushPolicy.ingestionDecision(
            for: current,
            previous: cancellation,
            requestedReason: .new,
            preferences: preferences(),
            now: now
        )
        XCTAssertFalse(replayDecision.shouldMerge)
        XCTAssertNil(replayDecision.presentationReason)
    }

    func testPresentedWarningReconcilesOnlyMatchingAcceptedLifecycle() {
        let active = makeEvent(serial: 4, reportDate: now, isWarn: true)
        let presented = PresentedAlert(event: active, reason: .new)
        let unrelatedFinal = makeEvent(
            id: "jma_eew:unrelated",
            serial: 5,
            reportDate: now.addingTimeInterval(1),
            isWarn: true,
            isFinal: true
        )

        XCTAssertEqual(
            PresentedAlertLifecyclePolicy.afterAcceptedMerge(
                unrelatedFinal,
                current: presented,
                now: now
            ),
            presented
        )

        let update = makeEvent(
            serial: 5,
            reportDate: now.addingTimeInterval(1),
            isWarn: true
        )
        let updatedPresentation = PresentedAlertLifecyclePolicy.afterAcceptedMerge(
            update,
            current: presented,
            now: now
        )
        XCTAssertEqual(updatedPresentation?.event, update)
        XCTAssertEqual(updatedPresentation?.reason, .new)

        let final = makeEvent(
            serial: 6,
            reportDate: now.addingTimeInterval(2),
            isWarn: true,
            isFinal: true
        )
        XCTAssertNil(PresentedAlertLifecyclePolicy.afterAcceptedMerge(
            final,
            current: updatedPresentation,
            now: now
        ))

        let cancelled = makeEvent(
            serial: 6,
            reportDate: now.addingTimeInterval(2),
            isWarn: true,
            isCancel: true
        )
        XCTAssertNil(PresentedAlertLifecyclePolicy.afterAcceptedMerge(
            cancelled,
            current: updatedPresentation,
            now: now
        ))

        let informationalDemotion = makeEvent(
            serial: 6,
            reportDate: now.addingTimeInterval(2),
            isWarn: false
        )
        XCTAssertNil(PresentedAlertLifecyclePolicy.afterAcceptedMerge(
            informationalDemotion,
            current: updatedPresentation,
            now: now
        ))
    }

    func testPresentedWarningExpiresWithoutDismissingNonWarningNavigation() {
        let freshWarning = PresentedAlert(
            event: makeEvent(reportDate: now, isWarn: true),
            reason: .new
        )
        XCTAssertEqual(
            PresentedAlertLifecyclePolicy.afterClockTick(freshWarning, now: now),
            freshWarning
        )
        XCTAssertNil(PresentedAlertLifecyclePolicy.afterClockTick(
            freshWarning,
            now: now.addingTimeInterval(601)
        ))

        let report = PresentedAlert(
            event: makeEvent(kind: "report", reportDate: now.addingTimeInterval(-86_400), isWarn: false),
            reason: .report
        )
        XCTAssertEqual(
            PresentedAlertLifecyclePolicy.afterClockTick(report, now: now),
            report
        )
    }

    func testHttpNormalizerRejectsMalformedEmptyAndWrongSourceSnapshots() throws {
        XCTAssertThrowsError(try WolfxNormalizer.validatedEvents(
            source: "jma_eew",
            data: Data("{".utf8)
        ))
        XCTAssertThrowsError(try WolfxNormalizer.validatedEvents(
            source: "jma_eew",
            data: Data("{}".utf8)
        ))

        let wrongSource = try JSONSerialization.data(withJSONObject: [
            "type": "sc_eew",
            "EventID": "202608190001",
            "Serial": 1,
            "OriginTime": "2026/08/19 12:00:00",
            "AnnouncedTime": "2026/08/19 12:00:01",
            "Hypocenter": "Test",
            "Latitude": 35.0,
            "Longitude": 140.0,
            "Magunitude": 5.0,
            "isWarn": true,
        ])
        XCTAssertThrowsError(try WolfxNormalizer.validatedEvents(
            source: "jma_eew",
            data: wrongSource
        ))
    }

    func testLocationFixPolicyRejectsStaleInvalidAndInaccurateLocations() {
        let coordinate = CLLocationCoordinate2D(latitude: 35.0, longitude: 140.0)
        let valid = CLLocation(
            coordinate: coordinate,
            altitude: 0,
            horizontalAccuracy: 25,
            verticalAccuracy: 25,
            timestamp: now
        )
        let stale = CLLocation(
            coordinate: coordinate,
            altitude: 0,
            horizontalAccuracy: 25,
            verticalAccuracy: 25,
            timestamp: now.addingTimeInterval(-121)
        )
        let invalidAccuracy = CLLocation(
            coordinate: coordinate,
            altitude: 0,
            horizontalAccuracy: -1,
            verticalAccuracy: 25,
            timestamp: now
        )
        let tooCoarse = CLLocation(
            coordinate: coordinate,
            altitude: 0,
            horizontalAccuracy: 5_001,
            verticalAccuracy: 25,
            timestamp: now
        )

        XCTAssertTrue(LocationFixPolicy.isUsable(valid, now: now))
        XCTAssertFalse(LocationFixPolicy.isUsable(stale, now: now))
        XCTAssertFalse(LocationFixPolicy.isUsable(invalidAccuracy, now: now))
        XCTAssertFalse(LocationFixPolicy.isUsable(tooCoarse, now: now))
    }

    func testSilentWebSocketRouteExpiresAfterBoundedTimeout() {
        XCTAssertFalse(LiveSocketLivenessPolicy.isStale(
            lastActivity: now.addingTimeInterval(-90),
            now: now
        ))
        XCTAssertTrue(LiveSocketLivenessPolicy.isStale(
            lastActivity: now.addingTimeInterval(-91),
            now: now
        ))
    }

    private func reason(
        for event: EEWEvent,
        preferences: AlertPreferenceSnapshot
    ) -> AlertPresentationReason? {
        ForegroundAlertPolicy.presentationReason(
            for: event,
            previous: nil,
            isBackfill: false,
            preferences: preferences,
            now: now
        )
    }

    private func preferences(
        subscriptionEnabled: Bool = true,
        enabledSources: Set<String> = ["jma_eew"],
        minimumMagnitude: Double = 3,
        coordinate: CLLocationCoordinate2D? = nil,
        radiusKm: Double = 100,
        includeTraining: Bool = false
    ) -> AlertPreferenceSnapshot {
        AlertPreferenceSnapshot(
            subscriptionEnabled: subscriptionEnabled,
            enabledSources: enabledSources,
            minimumMagnitude: minimumMagnitude,
            coordinate: coordinate,
            radiusKm: radiusKm,
            includeTraining: includeTraining
        )
    }

    private func makeEvent(
        id: String = "jma_eew:test",
        serial: Int = 1,
        kind: String = "eew",
        reportDate: Date,
        isWarn: Bool,
        isFinal: Bool = false,
        isCancel: Bool = false,
        isTraining: Bool = false
    ) -> EEWEvent {
        let timestamp = ISO8601DateFormatter().string(from: reportDate)
        return EEWEvent(
            id: id,
            sourceId: "jma_eew",
            eventId: "test",
            serial: serial,
            kind: kind,
            originTimeUtc: timestamp,
            reportTimeUtc: timestamp,
            hypocenter: "Test",
            latitude: 34.6937,
            longitude: 135.5023,
            magnitude: 5,
            depth: 10,
            maxIntensity: "5-",
            isWarn: isWarn,
            isFinal: isFinal,
            isCancel: isCancel,
            isTraining: isTraining,
            tsunami: nil
        )
    }
}
