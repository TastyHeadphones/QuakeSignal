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
            preferences: preferences(coordinate: nil),
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

    func testEmergencyAudioLifetimeFollowsDismissalRevisionAndReplacement() {
        let warning = PresentedAlert(
            event: makeEvent(reportDate: now, isWarn: true),
            reason: .new
        )
        let updated = PresentedAlert(
            event: makeEvent(serial: 2, reportDate: now, isWarn: true),
            reason: .updated
        )
        let detail = PresentedAlert(
            event: warning.event,
            reason: .report,
            mode: .detail
        )

        XCTAssertFalse(PresentedAlertAudioPolicy.shouldStop(previous: nil, next: warning))
        XCTAssertFalse(PresentedAlertAudioPolicy.shouldStop(previous: warning, next: warning))
        XCTAssertTrue(PresentedAlertAudioPolicy.shouldStop(previous: warning, next: nil))
        XCTAssertTrue(PresentedAlertAudioPolicy.shouldStop(previous: warning, next: updated))
        XCTAssertTrue(PresentedAlertAudioPolicy.shouldStop(previous: warning, next: detail))
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

    func testHomeReportSelectionUsesTimeInsteadOfNearbyDistanceOrder() {
        let nearerButOlder = makeHomeEvent(
            id: "jma_eqlist:nearer-older",
            reportDate: now.addingTimeInterval(-120)
        )
        let fartherButNewer = makeHomeEvent(
            id: "jma_eqlist:farther-newer",
            reportDate: now.addingTimeInterval(-30)
        )
        let nearestFirst = [nearerButOlder, fartherButNewer]

        XCTAssertEqual(
            HomeReportSelectionPolicy.newestReport(from: nearestFirst, now: now),
            fartherButNewer
        )
        XCTAssertEqual(
            HomeReportSelectionPolicy.newestReport(
                from: nearestFirst,
                now: now,
                maximumAge: HomeReportSelectionPolicy.maximumRecentAge
            ),
            fartherButNewer
        )
    }

    func testHomeReportSelectionFallsBackToOriginAndRejectsMissingTimestamps() {
        let originOnly = makeHomeEvent(
            id: "jma_eqlist:origin-only",
            originDate: now.addingTimeInterval(-60),
            reportDate: nil
        )
        let missingTimestamp = makeHomeEvent(
            id: "jma_eqlist:missing-time",
            originDate: nil,
            reportDate: nil
        )

        XCTAssertEqual(
            HomeReportSelectionPolicy.newestReport(
                from: [missingTimestamp, originOnly],
                now: now
            ),
            originOnly
        )
        XCTAssertNil(HomeReportSelectionPolicy.newestReport(
            from: [missingTimestamp],
            now: now
        ))
    }

    func testHomeRecentReportSelectionEnforcesInclusiveAgeAndFutureBounds() {
        let boundary = makeHomeEvent(
            id: "jma_eqlist:boundary",
            reportDate: now.addingTimeInterval(-HomeReportSelectionPolicy.maximumRecentAge)
        )
        let tooOld = makeHomeEvent(
            id: "jma_eqlist:too-old",
            reportDate: now.addingTimeInterval(-HomeReportSelectionPolicy.maximumRecentAge - 1)
        )
        let allowedFuture = makeHomeEvent(
            id: "jma_eqlist:allowed-future",
            reportDate: now.addingTimeInterval(HomeReportSelectionPolicy.allowedFutureSkew)
        )
        let tooFarFuture = makeHomeEvent(
            id: "jma_eqlist:too-far-future",
            reportDate: now.addingTimeInterval(HomeReportSelectionPolicy.allowedFutureSkew + 1)
        )

        XCTAssertEqual(
            HomeReportSelectionPolicy.newestReport(
                from: [tooOld, boundary],
                now: now,
                maximumAge: HomeReportSelectionPolicy.maximumRecentAge
            ),
            boundary
        )
        XCTAssertEqual(
            HomeReportSelectionPolicy.newestReport(
                from: [tooFarFuture, boundary, allowedFuture],
                now: now,
                maximumAge: HomeReportSelectionPolicy.maximumRecentAge
            ),
            allowedFuture
        )
        XCTAssertNil(HomeReportSelectionPolicy.newestReport(
            from: [tooOld, tooFarFuture],
            now: now,
            maximumAge: HomeReportSelectionPolicy.maximumRecentAge
        ))
    }

    func testHomeReportSelectionRejectsNonReportEEWFrames() {
        let informationalEEW = makeHomeEvent(
            id: "jma_eew:informational",
            kind: "eew",
            reportDate: now,
            isWarn: false,
            isFinal: false
        )
        let finalEEW = makeHomeEvent(
            id: "jma_eew:final",
            kind: "eew",
            reportDate: now,
            isWarn: true,
            isFinal: true
        )
        let cancelledEEW = makeHomeEvent(
            id: "jma_eew:cancelled",
            kind: "eew",
            reportDate: now,
            isWarn: true,
            isFinal: false,
            isCancel: true
        )
        let report = makeHomeEvent(
            id: "jma_eqlist:report",
            reportDate: now.addingTimeInterval(-1)
        )

        XCTAssertEqual(
            HomeReportSelectionPolicy.newestReport(
                from: [informationalEEW, finalEEW, cancelledEEW, report],
                now: now
            ),
            report
        )
    }

    func testHomeReportSelectionBreaksTimestampTiesDeterministically() {
        let alphabeticallyLater = makeHomeEvent(id: "jma_eqlist:z", reportDate: now)
        let alphabeticallyEarlier = makeHomeEvent(id: "jma_eqlist:a", reportDate: now)

        XCTAssertEqual(
            HomeReportSelectionPolicy.newestReport(
                from: [alphabeticallyLater, alphabeticallyEarlier],
                now: now
            ),
            alphabeticallyEarlier
        )
        XCTAssertEqual(
            HomeReportSelectionPolicy.newestReport(
                from: [alphabeticallyEarlier, alphabeticallyLater],
                now: now
            ),
            alphabeticallyEarlier
        )
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
            allowsEmergencyPresentation: true,
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
            allowsEmergencyPresentation: true,
            preferences: preferences,
            now: now
        ))

        XCTAssertEqual(ForegroundPushPolicy.presentationReason(
            for: reopened,
            previous: current,
            requestedReason: .updated,
            allowsEmergencyPresentation: true,
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
            allowsEmergencyPresentation: true,
            preferences: preferences(),
            now: now
        )
        XCTAssertTrue(finalDecision.shouldMerge)
        XCTAssertNil(finalDecision.presentationReason)

        let cancellationDecision = ForegroundPushPolicy.ingestionDecision(
            for: cancellation,
            previous: final,
            requestedReason: .cancelled,
            allowsEmergencyPresentation: true,
            preferences: preferences(),
            now: now
        )
        XCTAssertTrue(cancellationDecision.shouldMerge)
        XCTAssertNil(cancellationDecision.presentationReason)

        let replayDecision = ForegroundPushPolicy.ingestionDecision(
            for: current,
            previous: cancellation,
            requestedReason: .new,
            allowsEmergencyPresentation: true,
            preferences: preferences(),
            now: now
        )
        XCTAssertFalse(replayDecision.shouldMerge)
        XCTAssertNil(replayDecision.presentationReason)
    }

    func testForegroundNotificationRequiresUsableActiveSnapshotBeforeAttemptingInAppPresentation() {
        let payload = PushPayload(userInfo: [
            "sourceId": "jma_eew",
            "eventId": "test",
        ])
        XCTAssertFalse(ForegroundNotificationPresentationPolicy.allowsEmergencyPresentation(
            for: payload,
            isSceneActive: false
        ))
        XCTAssertFalse(ForegroundNotificationPresentationPolicy.allowsEmergencyPresentation(
            for: payload,
            isSceneActive: true
        ))
    }

    func testForegroundNotificationSuppressesSystemAlertOnlyAfterConfirmedInAppOwnership() {
        XCTAssertEqual(
            ForegroundNotificationPresentationPolicy.decision(
                didHandleEmergencyInApp: false
            ),
            ForegroundNotificationPresentationDecision(
                systemPresentation: .alert,
                didHandleEmergencyInApp: false
            )
        )
        XCTAssertEqual(
            ForegroundNotificationPresentationPolicy.decision(
                didHandleEmergencyInApp: true
            ),
            ForegroundNotificationPresentationDecision(
                systemPresentation: .listOnly,
                didHandleEmergencyInApp: true
            )
        )
    }

    func testForegroundEmergencyOwnershipRequiresPermissionAndTheExactHandledRevision() {
        let warning = makeEvent(serial: 1, reportDate: now, isWarn: true)
        let handledKeys = [ForegroundEmergencyRevisionOwnershipPolicy.key(for: warning)]

        XCTAssertTrue(ForegroundEmergencyRevisionOwnershipPolicy.wasAlreadyHandled(
            event: warning,
            handledRevisionKeys: Set(handledKeys),
            allowsEmergencyPresentation: true
        ))
        XCTAssertFalse(ForegroundEmergencyRevisionOwnershipPolicy.wasAlreadyHandled(
            event: warning,
            handledRevisionKeys: Set(handledKeys),
            allowsEmergencyPresentation: false
        ))
        XCTAssertFalse(ForegroundEmergencyRevisionOwnershipPolicy.wasAlreadyHandled(
            event: makeEvent(serial: 2, reportDate: now, isWarn: true),
            handledRevisionKeys: Set(handledKeys),
            allowsEmergencyPresentation: true
        ))
        XCTAssertFalse(ForegroundEmergencyRevisionOwnershipPolicy.wasAlreadyHandled(
            event: makeEvent(serial: 1, reportDate: now, isWarn: true, isFinal: true),
            handledRevisionKeys: Set(handledKeys),
            allowsEmergencyPresentation: true
        ))
    }

    func testNewerHandledWarningClaimsDelayedOlderActivePush() {
        let delayedOlderSerial = makeEvent(serial: 1, reportDate: now, isWarn: true)
        let handledHigherSerial = makeEvent(
            serial: 2,
            reportDate: now.addingTimeInterval(1),
            isWarn: true
        )
        XCTAssertTrue(ForegroundEmergencyRevisionOwnershipPolicy.wasAlreadyHandled(
            event: delayedOlderSerial,
            handledRevisionKeys: [
                ForegroundEmergencyRevisionOwnershipPolicy.key(for: handledHigherSerial),
            ],
            allowsEmergencyPresentation: true
        ))

        let delayedOlderTimestamp = makeEvent(serial: 3, reportDate: now, isWarn: true)
        let handledNewerTimestamp = makeEvent(
            serial: 3,
            reportDate: now.addingTimeInterval(1),
            isWarn: true
        )
        XCTAssertTrue(ForegroundEmergencyRevisionOwnershipPolicy.wasAlreadyHandled(
            event: delayedOlderTimestamp,
            handledRevisionKeys: [
                ForegroundEmergencyRevisionOwnershipPolicy.key(for: handledNewerTimestamp),
            ],
            allowsEmergencyPresentation: true
        ))
    }

    func testOlderHandledWarningDoesNotClaimNewerOrTerminalPush() {
        let earlier = makeEvent(serial: 1, reportDate: now, isWarn: true)
        let higherSerial = makeEvent(
            serial: 2,
            reportDate: now,
            isWarn: true
        )
        let newerTimestamp = makeEvent(
            serial: 1,
            reportDate: now.addingTimeInterval(1),
            isWarn: true
        )
        let handledKeys = [ForegroundEmergencyRevisionOwnershipPolicy.key(for: earlier)]

        for incoming in [
            higherSerial,
            newerTimestamp,
            makeEvent(
                serial: 2,
                reportDate: now.addingTimeInterval(1),
                isWarn: true,
                isFinal: true
            ),
            makeEvent(
                serial: 2,
                reportDate: now.addingTimeInterval(1),
                isWarn: true,
                isCancel: true
            ),
        ] {
            XCTAssertTrue(EventMergePolicy.shouldAccept(incoming, replacing: earlier))
            XCTAssertFalse(ForegroundEmergencyRevisionOwnershipPolicy.wasAlreadyHandled(
                event: incoming,
                handledRevisionKeys: Set(handledKeys),
                allowsEmergencyPresentation: true
            ))
        }
    }

    func testNonActiveHandledRevisionNeverDominatesAnActivePush() {
        let incoming = makeEvent(serial: 1, reportDate: now, isWarn: true)
        let handledFinal = makeEvent(
            serial: 2,
            reportDate: now.addingTimeInterval(1),
            isWarn: true,
            isFinal: true
        )
        let handledTraining = makeEvent(
            serial: 2,
            reportDate: now.addingTimeInterval(1),
            isWarn: false,
            isTraining: true
        )

        XCTAssertTrue(ForegroundEmergencyRevisionOwnershipPolicy.wasAlreadyHandled(
            event: incoming,
            handledRevisionKeys: [
                ForegroundEmergencyRevisionOwnershipPolicy.key(for: handledFinal),
            ],
            allowsEmergencyPresentation: true
        ))
        XCTAssertFalse(ForegroundEmergencyRevisionOwnershipPolicy.wasAlreadyHandled(
            event: incoming,
            handledRevisionKeys: [
                ForegroundEmergencyRevisionOwnershipPolicy.key(for: handledTraining),
            ],
            allowsEmergencyPresentation: true
        ))
    }

    func testConsumedSystemReservationRemainsOwnedForResolvedDuplicate() {
        let event = makeEvent(reportDate: now, isWarn: true)
        let revisionKey = ForegroundEmergencyRevisionOwnershipPolicy.key(for: event)
        var reservations: [ForegroundEmergencyRevisionKey: Date] = [:]
        ForegroundSystemPresentationReservationPolicy.reserve(
            revisionKey: revisionKey,
            receivedAt: now,
            now: now,
            reservations: &reservations
        )

        XCTAssertTrue(ForegroundSystemPresentationReservationPolicy.consume(
            revisionKey: revisionKey,
            now: now,
            reservations: &reservations
        ))
        // QuakeStore records this consumed key so the async snapshot
        // resolution and a duplicate APNs copy cannot reopen the emergency UI.
        XCTAssertTrue(ForegroundEmergencyRevisionOwnershipPolicy.wasAlreadyHandled(
            event: event,
            handledRevisionKeys: [revisionKey],
            allowsEmergencyPresentation: true
        ))
    }

    func testSnapshotlessSystemPresentationReservationIsRevisionBoundShortLivedAndOneShot() {
        let event = makeEvent(reportDate: now, isWarn: true)
        let other = makeEvent(id: "jma_eew:other", reportDate: now, isWarn: true)
        let revisionKey = ForegroundEmergencyRevisionOwnershipPolicy.key(for: event)
        var reservations: [ForegroundEmergencyRevisionKey: Date] = [:]
        ForegroundSystemPresentationReservationPolicy.reserve(
            revisionKey: revisionKey,
            receivedAt: now,
            now: now,
            reservations: &reservations
        )

        XCTAssertFalse(ForegroundSystemPresentationReservationPolicy.consume(
            revisionKey: ForegroundEmergencyRevisionOwnershipPolicy.key(for: other),
            now: now.addingTimeInterval(1),
            reservations: &reservations
        ))
        XCTAssertTrue(ForegroundSystemPresentationReservationPolicy.consume(
            revisionKey: revisionKey,
            now: now.addingTimeInterval(1),
            reservations: &reservations
        ))
        XCTAssertFalse(ForegroundSystemPresentationReservationPolicy.consume(
            revisionKey: revisionKey,
            now: now.addingTimeInterval(2),
            reservations: &reservations
        ))

        ForegroundSystemPresentationReservationPolicy.reserve(
            revisionKey: revisionKey,
            receivedAt: now,
            now: now,
            reservations: &reservations
        )
        XCTAssertFalse(ForegroundSystemPresentationReservationPolicy.consume(
            revisionKey: revisionKey,
            now: now.addingTimeInterval(
                ForegroundSystemPresentationReservationPolicy.lifetime + 1
            ),
            reservations: &reservations
        ))
    }

    func testSystemOwnedReservationSuppressesTheRacingDirectEmergency() {
        let event = makeEvent(reportDate: now, isWarn: true)
        let directReason = ForegroundAlertPolicy.presentationReason(
            for: event,
            previous: nil,
            isBackfill: false,
            preferences: preferences(),
            now: now
        )
        XCTAssertEqual(directReason, .new)

        let revisionKey = ForegroundEmergencyRevisionOwnershipPolicy.key(for: event)
        var reservations: [ForegroundEmergencyRevisionKey: Date] = [:]
        ForegroundSystemPresentationReservationPolicy.reserve(
            revisionKey: revisionKey,
            receivedAt: now,
            now: now,
            reservations: &reservations
        )
        let systemOwnsPresentation = ForegroundSystemPresentationReservationPolicy.consume(
            revisionKey: revisionKey,
            now: now,
            reservations: &reservations
        )
        let firstPresentationReason: AlertPresentationReason? = systemOwnsPresentation
            ? nil
            : directReason
        XCTAssertTrue(systemOwnsPresentation)
        XCTAssertNil(firstPresentationReason)
    }

    func testCachedFirstMatchConsumesReservationWithoutSuppressingNewerUpdate() {
        let cached = makeEvent(serial: 1, reportDate: now, isWarn: true)
        let newer = makeEvent(
            serial: 2,
            reportDate: now.addingTimeInterval(1),
            isWarn: true
        )
        let cachedKey = ForegroundEmergencyRevisionOwnershipPolicy.key(for: cached)
        var reservations: [ForegroundEmergencyRevisionKey: Date] = [:]
        ForegroundSystemPresentationReservationPolicy.reserve(
            revisionKey: cachedKey,
            receivedAt: now,
            now: now,
            reservations: &reservations
        )

        // The cached copy is the first valid event resolved for the system-owned
        // APNs alert, even though monotonic merge correctly rejects its replay.
        let cachedMatchWasSystemOwned =
            ForegroundSystemPresentationReservationPolicy.consume(
                revisionKey: cachedKey,
                now: now,
                reservations: &reservations
            )
        XCTAssertTrue(cachedMatchWasSystemOwned)
        XCTAssertFalse(EventMergePolicy.shouldAccept(cached, replacing: cached))

        // The one-shot reservation is gone before the genuinely newer revision,
        // so that update remains eligible for app-owned cover and audio.
        XCTAssertTrue(EventMergePolicy.shouldAccept(newer, replacing: cached))
        XCTAssertFalse(ForegroundSystemPresentationReservationPolicy.consume(
            revisionKey: ForegroundEmergencyRevisionOwnershipPolicy.key(for: newer),
            now: now.addingTimeInterval(1),
            reservations: &reservations
        ))
        XCTAssertEqual(
            ForegroundAlertPolicy.presentationReason(
                for: newer,
                previous: cached,
                isBackfill: false,
                preferences: preferences(),
                now: now.addingTimeInterval(1)
            ),
            .updated
        )
    }

    func testNewerDirectRevisionCannotConsumeAnOlderSystemPresentationReservation() {
        let reserved = makeEvent(serial: 1, reportDate: now, isWarn: true)
        let newer = makeEvent(
            serial: 2,
            reportDate: now.addingTimeInterval(1),
            isWarn: true
        )
        let laterSameSerial = makeEvent(
            serial: 1,
            reportDate: now.addingTimeInterval(2),
            isWarn: true
        )
        let reservedKey = ForegroundEmergencyRevisionOwnershipPolicy.key(for: reserved)
        var reservations: [ForegroundEmergencyRevisionKey: Date] = [:]
        ForegroundSystemPresentationReservationPolicy.reserve(
            revisionKey: reservedKey,
            receivedAt: now,
            now: now,
            reservations: &reservations
        )

        XCTAssertFalse(ForegroundSystemPresentationReservationPolicy.consume(
            revisionKey: ForegroundEmergencyRevisionOwnershipPolicy.key(for: newer),
            now: now.addingTimeInterval(1),
            reservations: &reservations
        ))
        XCTAssertFalse(ForegroundSystemPresentationReservationPolicy.consume(
            revisionKey: ForegroundEmergencyRevisionOwnershipPolicy.key(for: laterSameSerial),
            now: now.addingTimeInterval(2),
            reservations: &reservations
        ))
        XCTAssertEqual(reservations[reservedKey], now.addingTimeInterval(
            ForegroundSystemPresentationReservationPolicy.lifetime
        ))
        XCTAssertTrue(ForegroundSystemPresentationReservationPolicy.consume(
            revisionKey: reservedKey,
            now: now.addingTimeInterval(3),
            reservations: &reservations
        ))
        XCTAssertTrue(reservations.isEmpty)
    }

    func testReservedNewerRevisionOwnsOlderActiveCopiesUntilExactMatchArrives() {
        let older = makeEvent(serial: 1, reportDate: now, isWarn: true)
        let reserved = makeEvent(
            serial: 2,
            reportDate: now.addingTimeInterval(1),
            isWarn: true
        )
        let reservedKey = ForegroundEmergencyRevisionOwnershipPolicy.key(for: reserved)
        var reservations: [ForegroundEmergencyRevisionKey: Date] = [:]
        ForegroundSystemPresentationReservationPolicy.reserve(
            revisionKey: reservedKey,
            receivedAt: now,
            now: now,
            reservations: &reservations
        )

        XCTAssertTrue(ForegroundSystemPresentationReservationPolicy.consume(
            revisionKey: ForegroundEmergencyRevisionOwnershipPolicy.key(for: older),
            now: now.addingTimeInterval(1),
            reservations: &reservations
        ))
        XCTAssertNotNil(reservations[reservedKey])
        XCTAssertTrue(ForegroundSystemPresentationReservationPolicy.consume(
            revisionKey: reservedKey,
            now: now.addingTimeInterval(2),
            reservations: &reservations
        ))
        XCTAssertTrue(reservations.isEmpty)
    }

    func testTerminalReservationOwnsActiveReplaysButTrainingAndReportsDoNot() {
        let active = makeEvent(serial: 1, reportDate: now, isWarn: true)
        let final = makeEvent(
            serial: 2,
            reportDate: now.addingTimeInterval(1),
            isWarn: true,
            isFinal: true
        )
        let cancellation = makeEvent(
            serial: 1,
            reportDate: now,
            isWarn: false,
            isCancel: true
        )
        let laterActiveReplay = makeEvent(
            serial: 3,
            reportDate: now.addingTimeInterval(2),
            isWarn: true
        )

        for terminal in [final, cancellation] {
            let terminalKey = ForegroundEmergencyRevisionOwnershipPolicy.key(for: terminal)
            var reservations: [ForegroundEmergencyRevisionKey: Date] = [:]
            ForegroundSystemPresentationReservationPolicy.reserve(
                revisionKey: terminalKey,
                receivedAt: now,
                now: now,
                reservations: &reservations
            )
            for replay in [active, laterActiveReplay] {
                XCTAssertTrue(ForegroundSystemPresentationReservationPolicy.consume(
                    revisionKey: ForegroundEmergencyRevisionOwnershipPolicy.key(for: replay),
                    now: now.addingTimeInterval(1),
                    reservations: &reservations
                ))
            }
            XCTAssertNotNil(reservations[terminalKey])
        }

        let nonTerminalOwners = [
            makeEvent(
                serial: 3,
                reportDate: now,
                isWarn: false,
                isTraining: true
            ),
            makeEvent(
                serial: 3,
                kind: "report",
                reportDate: now,
                isWarn: false,
                isFinal: true
            ),
        ]
        for nonTerminalOwner in nonTerminalOwners {
            var reservations: [ForegroundEmergencyRevisionKey: Date] = [:]
            ForegroundSystemPresentationReservationPolicy.reserve(
                revisionKey: ForegroundEmergencyRevisionOwnershipPolicy.key(for: nonTerminalOwner),
                receivedAt: now,
                now: now,
                reservations: &reservations
            )
            XCTAssertFalse(ForegroundSystemPresentationReservationPolicy.consume(
                revisionKey: ForegroundEmergencyRevisionOwnershipPolicy.key(for: active),
                now: now.addingTimeInterval(1),
                reservations: &reservations
            ))
        }
    }

    func testAlreadyExpiredBufferedSystemPresentationIsNotReservedAtDrainTime() {
        let revisionKey = ForegroundEmergencyRevisionOwnershipPolicy.key(
            for: makeEvent(reportDate: now, isWarn: true)
        )
        var reservations: [ForegroundEmergencyRevisionKey: Date] = [:]
        let drainedAt = now.addingTimeInterval(
            ForegroundSystemPresentationReservationPolicy.lifetime + 1
        )

        ForegroundSystemPresentationReservationPolicy.reserve(
            revisionKey: revisionKey,
            receivedAt: now,
            now: drainedAt,
            reservations: &reservations
        )

        XCTAssertTrue(reservations.isEmpty)
        XCTAssertFalse(ForegroundSystemPresentationReservationPolicy.consume(
            revisionKey: revisionKey,
            now: drainedAt,
            reservations: &reservations
        ))
    }

    func testOptedInForegroundTrainingUsesOwnedDeduplicatedAudio() {
        let training = makeEvent(
            reportDate: now,
            isWarn: false,
            isTraining: true
        )
        XCTAssertNil(reason(
            for: training,
            preferences: preferences(includeTraining: false)
        ))
        let acceptedReason = reason(
            for: training,
            preferences: preferences(includeTraining: true)
        )
        XCTAssertEqual(acceptedReason, .training)
        XCTAssertTrue(ForegroundEmergencyAudioPolicy.shouldPlay(
            event: training,
            reason: .training
        ))
        XCTAssertFalse(ForegroundEmergencyAudioPolicy.shouldPlay(
            event: training,
            reason: .new
        ))

        let key = ForegroundEmergencyRevisionOwnershipPolicy.key(for: training)
        XCTAssertTrue(ForegroundEmergencyRevisionOwnershipPolicy.wasAlreadyHandled(
            event: training,
            handledRevisionKeys: [key],
            allowsEmergencyPresentation: true
        ))
    }

    func testWebSocketFirstDuplicateSuppressesSecondBannerWithoutOpeningAnotherCover() {
        let warning = makeEvent(serial: 1, reportDate: now, isWarn: true)
        let mergeDecision = ForegroundPushPolicy.ingestionDecision(
            for: warning,
            previous: warning,
            requestedReason: .new,
            allowsEmergencyPresentation: true,
            preferences: preferences(),
            now: now
        )
        XCTAssertFalse(mergeDecision.shouldMerge)
        XCTAssertNil(mergeDecision.presentationReason)

        let alreadyOwned = ForegroundEmergencyRevisionOwnershipPolicy.wasAlreadyHandled(
            event: warning,
            handledRevisionKeys: [ForegroundEmergencyRevisionOwnershipPolicy.key(for: warning)],
            allowsEmergencyPresentation: true
        )
        XCTAssertTrue(alreadyOwned)
        XCTAssertEqual(
            ForegroundNotificationPresentationPolicy.decision(
                didHandleEmergencyInApp: alreadyOwned
            ),
            ForegroundNotificationPresentationDecision(
                systemPresentation: .listOnly,
                didHandleEmergencyInApp: true
            )
        )
    }

    func testPreferenceOrLocationRejectedForegroundWarningCannotTakeInAppOwnership() {
        let event = makeEvent(reportDate: now, isWarn: true)
        let rejectedPreferences = [
            preferences(subscriptionEnabled: false),
            preferences(enabledSources: []),
            preferences(minimumMagnitude: 6),
            preferences(coordinate: nil),
            preferences(
                coordinate: CLLocationCoordinate2D(latitude: 35.681, longitude: 139.767),
                radiusKm: 10
            ),
        ]

        for rejected in rejectedPreferences {
            let decision = ForegroundPushPolicy.ingestionDecision(
                for: event,
                previous: nil,
                requestedReason: .new,
                allowsEmergencyPresentation: true,
                preferences: rejected,
                now: now
            )
            XCTAssertTrue(decision.shouldMerge)
            XCTAssertNil(decision.presentationReason)
            XCTAssertFalse(ForegroundEmergencyRevisionOwnershipPolicy.wasAlreadyHandled(
                event: event,
                handledRevisionKeys: [],
                allowsEmergencyPresentation: true
            ))
        }
    }

    func testSystemPresentedForegroundPushStillMergesWithoutEmergencyTakeover() {
        let event = makeEvent(reportDate: now, isWarn: true)
        let decision = ForegroundPushPolicy.ingestionDecision(
            for: event,
            previous: nil,
            requestedReason: .new,
            allowsEmergencyPresentation: false,
            preferences: preferences(),
            now: now
        )

        XCTAssertTrue(decision.shouldMerge)
        XCTAssertNil(decision.presentationReason)
    }

    func testNotificationTapUsesEmergencyOnlyForFreshActiveWarning() {
        XCTAssertEqual(
            NotificationTapPresentationPolicy.mode(
                for: makeEvent(reportDate: now, isWarn: true),
                now: now
            ),
            .emergency
        )
        XCTAssertEqual(
            NotificationTapPresentationPolicy.mode(
                for: makeEvent(reportDate: now.addingTimeInterval(-601), isWarn: true),
                now: now
            ),
            .detail
        )
        XCTAssertEqual(
            NotificationTapPresentationPolicy.mode(
                for: makeEvent(reportDate: now, isWarn: true, isFinal: true),
                now: now
            ),
            .detail
        )
        XCTAssertEqual(
            NotificationTapPresentationPolicy.mode(
                for: makeEvent(reportDate: now, isWarn: true, isCancel: true),
                now: now
            ),
            .detail
        )
        XCTAssertEqual(
            NotificationTapPresentationPolicy.mode(
                for: makeEvent(reportDate: now, isWarn: false, isTraining: true),
                now: now
            ),
            .detail
        )
        XCTAssertEqual(
            NotificationTapPresentationPolicy.mode(
                for: makeEvent(kind: "report", reportDate: now, isWarn: false),
                now: now
            ),
            .detail
        )
    }

    func testTappedDetailSurvivesClockExpiryAndAcceptedTerminalMerge() {
        let stale = makeEvent(reportDate: now.addingTimeInterval(-601), isWarn: true)
        let detail = PresentedAlert(event: stale, reason: .new, mode: .detail)

        XCTAssertEqual(
            PresentedAlertLifecyclePolicy.afterClockTick(detail, now: now),
            detail
        )

        let final = makeEvent(
            serial: 2,
            reportDate: now,
            isWarn: true,
            isFinal: true
        )
        XCTAssertEqual(
            PresentedAlertLifecyclePolicy.afterAcceptedMerge(
                final,
                current: detail,
                now: now
            ),
            PresentedAlert(event: final, reason: .new, mode: .detail)
        )
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
        XCTAssertEqual(
            WolfxNormalizer.events(
                source: "jma_eew",
                object: try XCTUnwrap(
                    JSONSerialization.jsonObject(with: wrongSource) as? [String: Any]
                )
            ),
            []
        )
        XCTAssertThrowsError(try WolfxNormalizer.validatedEvents(
            source: "cenc_eew",
            data: wrongSource
        ))
        XCTAssertEqual(
            WolfxNormalizer.events(source: "cenc_eew", object: [:]),
            []
        )
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

    func testMapLocationControlFocusesRequestsOrOffersPermissionRepair() {
        XCTAssertEqual(
            MapLocationControlPolicy.action(
                authorizationStatus: .authorizedWhenInUse,
                hasCurrentLocation: true
            ),
            .focus
        )
        XCTAssertEqual(
            MapLocationControlPolicy.action(
                authorizationStatus: .authorizedWhenInUse,
                hasCurrentLocation: false
            ),
            .request
        )
        XCTAssertEqual(
            MapLocationControlPolicy.action(
                authorizationStatus: .notDetermined,
                hasCurrentLocation: false
            ),
            .request
        )
        XCTAssertEqual(
            MapLocationControlPolicy.action(
                authorizationStatus: .denied,
                hasCurrentLocation: false
            ),
            .openSettings
        )
        XCTAssertEqual(
            MapLocationControlPolicy.action(
                authorizationStatus: .restricted,
                hasCurrentLocation: false
            ),
            .openSettings
        )
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
        coordinate: CLLocationCoordinate2D? = CLLocationCoordinate2D(
            latitude: 34.6937,
            longitude: 135.5023
        ),
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

    private func makeHomeEvent(
        id: String,
        kind: String = "report",
        originDate: Date? = nil,
        reportDate: Date?,
        isWarn: Bool = false,
        isFinal: Bool = true,
        isCancel: Bool = false
    ) -> EEWEvent {
        EEWEvent(
            id: id,
            sourceId: kind == "report" ? "jma_eqlist" : "jma_eew",
            eventId: id,
            serial: 1,
            kind: kind,
            originTimeUtc: originDate.map { ISO8601DateFormatter().string(from: $0) },
            reportTimeUtc: reportDate.map { ISO8601DateFormatter().string(from: $0) },
            hypocenter: "Test",
            latitude: 35.0,
            longitude: 139.0,
            magnitude: 5,
            depth: 10,
            maxIntensity: "5-",
            isWarn: isWarn,
            isFinal: isFinal,
            isCancel: isCancel,
            isTraining: false,
            tsunami: nil
        )
    }
}
