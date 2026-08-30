import CoreLocation
import UIKit
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
        serial: Int = 1,
        reportDate: Date,
        isWarn: Bool,
        isFinal: Bool = false,
        isCancel: Bool = false,
        isTraining: Bool = false
    ) -> EEWEvent {
        let timestamp = ISO8601DateFormatter().string(from: reportDate)
        return EEWEvent(
            id: "jma_eew:test",
            sourceId: "jma_eew",
            eventId: "test",
            serial: serial,
            kind: "eew",
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

final class NativeUIPresentationTests: XCTestCase {
    func testRootTabsAndQuickActionsMatchTheNativeUIRedesign() {
        XCTAssertEqual(
            NativeUINavigation.rootTabs,
            [.home, .reports, .map, .guide, .settings]
        )
        XCTAssertEqual(
            NativeUINavigation.rootTabs.map(\.titleKey),
            ["tab.home", "tab.list", "tab.map", "tab.guide", "tab.settings"]
        )
        XCTAssertEqual(NativeUITab.reports.destinations, [.reports, .reportsFilters])
        XCTAssertEqual(
            NativeUIQuickAction.allCases.map(\.destination),
            [.cityPicker, .notifications, .map]
        )
        XCTAssertTrue(NativeUITab.home.destinations.contains(.statusHero))
        XCTAssertTrue(NativeUITab.home.destinations.contains(.latestEventCard))
        XCTAssertTrue(NativeUITab.guide.destinations.contains(.familyCheckIn))
        XCTAssertTrue(NativeUITab.settings.destinations.contains(.alertSources))
        XCTAssertTrue(NativeUITab.settings.destinations.contains(.alertSound))
        XCTAssertTrue(NativeUITab.settings.destinations.contains(.sourcesDisclaimer))
        XCTAssertTrue(NativeUINavigation.overlayDestinations.contains(.onboarding))
        XCTAssertTrue(NativeUINavigation.overlayDestinations.contains(.eewOverlay))
        XCTAssertTrue(NativeUINavigation.eventDetailDestinations.contains(.revisionTimeline))
    }

    func testStatusHeroMappingPrefersLiveWarningOverNearbyReport() {
        XCTAssertEqual(
            NativeStatusHeroMapping.bannerState(
                hasActiveWarning: false,
                hasRecentNearbyReport: false
            ),
            .normal
        )
        XCTAssertEqual(
            NativeStatusHeroMapping.bannerState(
                hasActiveWarning: false,
                hasRecentNearbyReport: true
            ),
            .caution
        )
        XCTAssertEqual(
            NativeStatusHeroMapping.bannerState(
                hasActiveWarning: true,
                hasRecentNearbyReport: true
            ),
            .alert
        )
        XCTAssertEqual(NativeStatusHeroMapping.titleKey(for: .normal), "home.status.normal")
        XCTAssertEqual(NativeStatusHeroMapping.titleKey(for: .caution), "home.status.caution")
        XCTAssertEqual(NativeStatusHeroMapping.titleKey(for: .alert), "home.status.alert")
        XCTAssertEqual(NativeStatusHeroMapping.detailKey(for: .normal), "home.status.normal.detail")
        XCTAssertEqual(NativeStatusHeroMapping.detailKey(for: .caution), "home.status.caution.detail")
        XCTAssertEqual(NativeStatusHeroMapping.detailKey(for: .alert), "home.status.alert.detail")
    }

    func testNotificationRelayRegistersOnlyOniPhoneAndiPad() {
        XCTAssertTrue(
            NativeUIRelaySurface.resolve(
                userInterfaceIdiom: .phone,
                isMacCatalyst: false
            ).registersForNotificationRelay
        )
        XCTAssertTrue(
            NativeUIRelaySurface.resolve(
                userInterfaceIdiom: .pad,
                isMacCatalyst: false
            ).registersForNotificationRelay
        )
        XCTAssertFalse(
            NativeUIRelaySurface.resolve(
                userInterfaceIdiom: .phone,
                isMacCatalyst: true
            ).registersForNotificationRelay
        )
        XCTAssertFalse(
            NativeUIRelaySurface.resolve(
                userInterfaceIdiom: .mac,
                isMacCatalyst: false
            ).registersForNotificationRelay
        )
        XCTAssertFalse(
            NativeUIRelaySurface.resolve(
                userInterfaceIdiom: .vision,
                isMacCatalyst: false
            ).registersForNotificationRelay
        )
        XCTAssertFalse(NativeUIRelaySurface.watch.registersForNotificationRelay)
        XCTAssertEqual(
            NativeUIRelaySurface.iPhone.notificationsTitleKey,
            "settings.section.notifications"
        )
        XCTAssertEqual(
            NativeUIRelaySurface.macCatalyst.notificationsTitleKey,
            "settings.foregroundAlerts"
        )
    }

    func testCurrentIOSHostJoinsThePhoneOrPadRelay() {
        let surface = NativeUIRelaySurface.current()
        XCTAssertTrue(
            surface == .iPhone || surface == .iPad,
            "iOS unit tests run on iPhone/iPad Simulator and must keep the live APNs relay path"
        )
        XCTAssertTrue(surface.registersForNotificationRelay)
    }

    func testReportsTabEnglishTitleIsTheRedesignLabel() throws {
        let appBundle = try XCTUnwrap(Bundle(identifier: "com.quakesignal.app"))
        let enPath = try XCTUnwrap(appBundle.path(forResource: "en", ofType: "lproj"))
        let enBundle = try XCTUnwrap(Bundle(path: enPath))
        XCTAssertEqual(enBundle.localizedString(forKey: "tab.list", value: "MISSING", table: nil), "Reports")
        XCTAssertNotEqual(enBundle.localizedString(forKey: "tab.list", value: "MISSING", table: nil), "List")
    }
}
