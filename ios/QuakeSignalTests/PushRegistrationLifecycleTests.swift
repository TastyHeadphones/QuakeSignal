import Foundation
import CoreLocation
import DeviceCheck
import SwiftUI
import XCTest
@testable import QuakeSignal

@MainActor
final class PushRegistrationLifecycleTests: XCTestCase {
    func testDeletionRequestIncludesAPNsTokenWhenAvailable() throws {
        let data = try JSONEncoder().encode(DeviceDeletionRequest(token: "token-123"))

        XCTAssertEqual(data, Data(#"{"token":"token-123"}"#.utf8))
    }

    func testDeletionRequestOmitsTokenInsteadOfEncodingNull() throws {
        let data = try JSONEncoder().encode(DeviceDeletionRequest(token: nil))

        // This exact body is signed by App Attest and asks the Worker to
        // remove the registration associated with the authenticated key.
        XCTAssertEqual(data, Data("{}".utf8))
    }

    func testRegistrationStatePersistsSeparatelyFromSubscriptionPreference() throws {
        let suiteName = "PushRegistrationLifecycleTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.pushRegistrationState, .unregistered)

        settings.pushSubscriptionEnabled = true
        settings.pushRegistrationState = .failed

        let restored = AppSettings(defaults: defaults)
        XCTAssertTrue(restored.pushSubscriptionEnabled)
        XCTAssertEqual(restored.pushRegistrationState, .failed)
        XCTAssertTrue(restored.pushRegistrationState.isRetryable)
    }

    func testInterruptedRegistrationRestoresAsRetryableFailure() throws {
        let suiteName = "PushRegistrationLifecycleTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(PushRegistrationState.registering.rawValue, forKey: "settings.pushRegistrationState")

        let restored = AppSettings(defaults: defaults)
        XCTAssertEqual(restored.pushRegistrationState, .failed)
        XCTAssertTrue(restored.pushRegistrationState.isRetryable)
        XCTAssertEqual(defaults.string(forKey: "settings.pushRegistrationState"), PushRegistrationState.failed.rawValue)
    }

    func testDisabledSubscriptionCannotRestoreContradictoryActiveState() throws {
        let suiteName = "PushRegistrationLifecycleTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: "settings.pushSubscriptionEnabled")
        defaults.set(PushRegistrationState.active.rawValue, forKey: "settings.pushRegistrationState")

        let restored = AppSettings(defaults: defaults)
        XCTAssertFalse(restored.pushSubscriptionEnabled)
        XCTAssertEqual(restored.pushRegistrationState, .unregistered)
        XCTAssertEqual(
            defaults.string(forKey: "settings.pushRegistrationState"),
            PushRegistrationState.unregistered.rawValue
        )
    }

    func testSettingsRegistrationControlRequiresConfirmedRegistrationBeforeOfferingRemoval() {
        XCTAssertEqual(
            PushSubscriptionControlAction.resolve(
                subscriptionEnabled: true,
                registrationState: .unregistered,
                canRegisterForRemoteNotifications: false
            ),
            .none,
            "A fresh permission-skipped install uses the separate Enable Notifications affordance."
        )
        XCTAssertEqual(
            PushSubscriptionControlAction.resolve(
                subscriptionEnabled: true,
                registrationState: .unregistered,
                canRegisterForRemoteNotifications: true
            ),
            .retry
        )
        XCTAssertEqual(
            PushSubscriptionControlAction.resolve(
                subscriptionEnabled: true,
                registrationState: .failed,
                canRegisterForRemoteNotifications: true
            ),
            .retry
        )
        XCTAssertEqual(
            PushSubscriptionControlAction.resolve(
                subscriptionEnabled: true,
                registrationState: .registering,
                canRegisterForRemoteNotifications: true
            ),
            .none
        )
        XCTAssertEqual(
            PushSubscriptionControlAction.resolve(
                subscriptionEnabled: false,
                registrationState: .unregistered,
                canRegisterForRemoteNotifications: true
            ),
            .resume
        )
        XCTAssertEqual(
            PushSubscriptionControlAction.resolve(
                subscriptionEnabled: true,
                registrationState: .active,
                canRegisterForRemoteNotifications: false
            ),
            .remove,
            "A known registration remains removable even when notification permission is off."
        )
    }

    func testTierChipAccessibilityExposesNativeSelectedState() {
        XCTAssertTrue(
            TierChipAccessibility.traits(isSelected: true).contains(.isSelected)
        )
        XCTAssertFalse(
            TierChipAccessibility.traits(isSelected: false).contains(.isSelected)
        )
    }

    func testPersistedSourcesAreMigratedToTheReviewedJMAAllowList() throws {
        let suiteName = "PushRegistrationLifecycleTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(
            ["cenc_eew", "jma_eew", "sc_eew", "jma_eqlist"],
            forKey: "settings.sources"
        )

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(AppSettings.allSources, ["jma_eew", "jma_eqlist"])
        XCTAssertEqual(settings.enabledSources, ["jma_eew", "jma_eqlist"])
        XCTAssertEqual(
            defaults.stringArray(forKey: "settings.sources"),
            ["jma_eew", "jma_eqlist"]
        )
    }

    func testSelectingCurrentLocationPreservesTheLastCityAsFallback() throws {
        let suiteName = "PushRegistrationLifecycleTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        settings.selectedCityId = "tokyo"

        settings.selectCurrentLocation()

        XCTAssertTrue(settings.useCurrentLocation)
        XCTAssertEqual(settings.selectedCityId, "tokyo")
        XCTAssertEqual(defaults.string(forKey: "settings.cityId"), "tokyo")
    }

    func testEveryServerAlertPreferenceAdvancesTheCentralRegistrationRevision() throws {
        let suiteName = "PushRegistrationLifecycleTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        var previousRevision = settings.pushRegistrationPreferencesRevision
        let mutations: [() -> Void] = [
            { settings.selectedCityId = "tokyo" },
            { settings.useCurrentLocation = true },
            { settings.radiusKm = 300 },
            { settings.minMagnitude = 4 },
            { settings.enabledSources = ["jma_eew"] },
            { settings.includeTestAlerts = true },
            { settings.notifyAtNight = false },
            { settings.alertSound = .japaneseVoice },
        ]

        for mutation in mutations {
            mutation()
            XCTAssertEqual(
                settings.pushRegistrationPreferencesRevision,
                previousRevision + 1
            )
            previousRevision = settings.pushRegistrationPreferencesRevision
        }

        settings.alertSound = .japaneseVoice
        XCTAssertEqual(
            settings.pushRegistrationPreferencesRevision,
            previousRevision,
            "Re-selecting an already-active value must not enqueue another server update."
        )
    }

    func testSourceSelectionNeverBecomesEmptyOrRestoresAnEmptyLegacyValue() throws {
        let suiteName = "PushRegistrationLifecycleTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set([], forKey: "settings.sources")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.enabledSources, Set(AppSettings.allSources))
        XCTAssertEqual(
            Set(defaults.stringArray(forKey: "settings.sources") ?? []),
            Set(AppSettings.allSources)
        )

        settings.enabledSources = ["jma_eew"]
        let revision = settings.pushRegistrationPreferencesRevision
        settings.enabledSources = []
        XCTAssertEqual(settings.enabledSources, ["jma_eew"])
        XCTAssertEqual(settings.pushRegistrationPreferencesRevision, revision)
        XCTAssertEqual(defaults.stringArray(forKey: "settings.sources"), ["jma_eew"])
    }

    func testMissingLocationRegistrationErrorIsActionable() {
        XCTAssertEqual(
            PushRegistrationPreparationError.locationRequired.errorDescription,
            String(localized: "settings.pushSubscription.locationRequired")
        )
        XCTAssertTrue(MissingLocationRegistrationPolicy.shouldDeleteServerRegistration(
            registrationState: .active,
            locationRequestInFlight: false
        ))
        XCTAssertFalse(MissingLocationRegistrationPolicy.shouldDeleteServerRegistration(
            registrationState: .active,
            locationRequestInFlight: true
        ))
        XCTAssertTrue(MissingLocationRegistrationPolicy.shouldDeleteServerRegistration(
            registrationState: .failed,
            locationRequestInFlight: false
        ))
        XCTAssertFalse(MissingLocationRegistrationPolicy.shouldDeleteServerRegistration(
            registrationState: .unregistered,
            locationRequestInFlight: false
        ))
    }

    func testAlertSoundPreferencePersistsAndUsesStableWireValue() throws {
        let suiteName = "PushRegistrationLifecycleTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.alertSound, .system)
        settings.alertSound = .japaneseVoice
        XCTAssertEqual(AppSettings(defaults: defaults).alertSound, .japaneseVoice)

        let request = DeviceRegistrationRequest(
            token: "token",
            environment: "sandbox",
            locale: "ja_JP",
            sources: ["jma_eew"],
            minMagnitude: 4,
            cityName: "東京",
            latitude: 35.7,
            longitude: 139.7,
            radiusKm: 100,
            includeTestAlerts: false,
            utcOffsetMinutes: 540,
            notifyAtNight: true,
            alertSound: .japaneseVoice
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )
        XCTAssertEqual(object["alertSound"] as? String, "japanese-voice")
    }

    func testPushPayloadDecodesCompactEventSnapshot() throws {
        let event = EEWEvent(
            id: "jma_eew:test",
            sourceId: "jma_eew",
            eventId: "test",
            serial: 2,
            kind: "eew",
            originTimeUtc: "2026-08-19T01:00:00Z",
            reportTimeUtc: "2026-08-19T01:00:02Z",
            hypocenter: "Test",
            latitude: 35,
            longitude: 140,
            magnitude: 5,
            depth: 10,
            maxIntensity: "5-",
            isWarn: true,
            isFinal: false,
            isCancel: false,
            isTraining: false,
            tsunami: nil
        )
        var snapshot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any]
        )
        snapshot.removeValue(forKey: "id")
        let payload = PushPayload(userInfo: [
            "sourceId": "jma_eew",
            "eventId": "test",
            "reason": "updated",
            "event": snapshot,
        ])

        XCTAssertEqual(payload.compositeEventId, event.id)
        XCTAssertEqual(payload.eventSnapshot, event)
        XCTAssertTrue(payload.hasUsableMatchingEventSnapshot)
        XCTAssertEqual(AlertPresentationReason(wireValue: payload.reason), .updated)
        XCTAssertEqual(
            ForegroundNotificationPresentationPolicy.decision(
                for: payload,
                isSceneActive: true
            ),
            ForegroundNotificationPresentationDecision(
                systemPresentation: .listOnly,
                shouldPresentEmergencyInApp: true
            )
        )
        XCTAssertEqual(
            ForegroundNotificationPresentationPolicy.decision(
                for: payload,
                isSceneActive: false
            ),
            ForegroundNotificationPresentationDecision(
                systemPresentation: .alert,
                shouldPresentEmergencyInApp: false
            )
        )
    }

    func testForegroundNotificationKeepsSystemAlertForMissingMalformedOrMismatchedSnapshot() throws {
        let event = EEWEvent(
            id: "jma_eew:test",
            sourceId: "jma_eew",
            eventId: "test",
            serial: 2,
            kind: "eew",
            originTimeUtc: "2026-08-19T01:00:00Z",
            reportTimeUtc: "2026-08-19T01:00:02Z",
            hypocenter: "Test",
            latitude: 35,
            longitude: 140,
            magnitude: 5,
            depth: 10,
            maxIntensity: "5-",
            isWarn: true,
            isFinal: false,
            isCancel: false,
            isTraining: false,
            tsunami: nil
        )
        let validSnapshot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any]
        )
        var malformedSnapshot = validSnapshot
        malformedSnapshot["serial"] = -1
        var mismatchedIDSnapshot = validSnapshot
        mismatchedIDSnapshot["id"] = "jma_eew:another-event"

        let payloads = [
            PushPayload(userInfo: [
                "sourceId": "jma_eew",
                "eventId": "test",
            ]),
            PushPayload(userInfo: [
                "sourceId": "jma_eew",
                "eventId": "test",
                "event": malformedSnapshot,
            ]),
            PushPayload(userInfo: [
                "sourceId": "jma_eew",
                "eventId": "different-event",
                "event": validSnapshot,
            ]),
            PushPayload(userInfo: [
                "sourceId": "jma_eqlist",
                "eventId": "test",
                "event": validSnapshot,
            ]),
            PushPayload(userInfo: [
                "sourceId": "jma_eew",
                "eventId": "test",
                "event": mismatchedIDSnapshot,
            ]),
        ]

        for payload in payloads {
            XCTAssertNotNil(payload.compositeEventId)
            XCTAssertNil(payload.eventSnapshot)
            XCTAssertFalse(payload.hasUsableMatchingEventSnapshot)
            XCTAssertEqual(
                ForegroundNotificationPresentationPolicy.decision(
                    for: payload,
                    isSceneActive: true
                ),
                ForegroundNotificationPresentationDecision(
                    systemPresentation: .alert,
                    shouldPresentEmergencyInApp: false
                )
            )
        }
    }

    func testPushPayloadRejectsAnUnreviewedSourceAndSnapshot() throws {
        let event = EEWEvent(
            id: "cenc_eew:test",
            sourceId: "cenc_eew",
            eventId: "test",
            serial: 1,
            kind: "eew",
            originTimeUtc: "2026-08-19T01:00:00Z",
            reportTimeUtc: "2026-08-19T01:00:02Z",
            hypocenter: "Test",
            latitude: 35,
            longitude: 140,
            magnitude: 5,
            depth: 10,
            maxIntensity: "5-",
            isWarn: true,
            isFinal: false,
            isCancel: false,
            isTraining: false,
            tsunami: nil
        )
        let snapshot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any]
        )

        let payload = PushPayload(userInfo: [
            "sourceId": "cenc_eew",
            "eventId": "test",
            "event": snapshot,
        ])

        XCTAssertNil(payload.sourceId)
        XCTAssertNil(payload.compositeEventId)
        XCTAssertNil(payload.eventSnapshot)
        XCTAssertFalse(payload.hasUsableMatchingEventSnapshot)
    }

    func testLocationSelectionStatusDistinguishesGPSFallbackAndPermissionStates() {
        XCTAssertEqual(
            LocationSelectionStatus.resolve(
                authorizationStatus: .authorizedWhenInUse,
                hasCurrentLocation: true,
                isRequestingLocation: false,
                lastRequestFailed: false
            ),
            .current
        )
        XCTAssertEqual(
            LocationSelectionStatus.resolve(
                authorizationStatus: .authorizedWhenInUse,
                hasCurrentLocation: false,
                isRequestingLocation: true,
                lastRequestFailed: false
            ),
            .locating
        )
        XCTAssertEqual(
            LocationSelectionStatus.resolve(
                authorizationStatus: .notDetermined,
                hasCurrentLocation: false,
                isRequestingLocation: true,
                lastRequestFailed: false
            ),
            .permissionRequired
        )
        XCTAssertEqual(
            LocationSelectionStatus.resolve(
                authorizationStatus: .denied,
                hasCurrentLocation: true,
                isRequestingLocation: false,
                lastRequestFailed: false
            ),
            .denied
        )
        XCTAssertEqual(
            LocationSelectionStatus.resolve(
                authorizationStatus: .authorizedWhenInUse,
                hasCurrentLocation: false,
                isRequestingLocation: false,
                lastRequestFailed: true
            ),
            .unavailable
        )
        XCTAssertFalse(LocationSelectionStatus.denied.canRequestCurrentLocation)
        XCTAssertTrue(LocationSelectionStatus.permissionRequired.canRequestCurrentLocation)
        XCTAssertTrue(LocationSelectionStatus.current.canRequestCurrentLocation)
    }

    func testAuthorizationContinuationRequiresExplicitCurrentLocationIntent() {
        XCTAssertTrue(LocationAuthorizationContinuationPolicy.shouldRequestFix(
            authorizationStatus: .authorizedWhenInUse,
            useCurrentLocation: true,
            pendingPurpose: .subscription
        ))
        XCTAssertFalse(LocationAuthorizationContinuationPolicy.shouldRequestFix(
            authorizationStatus: .authorizedWhenInUse,
            useCurrentLocation: false,
            pendingPurpose: .subscription
        ))
        XCTAssertTrue(LocationAuthorizationContinuationPolicy.shouldRequestFix(
            authorizationStatus: .authorizedWhenInUse,
            useCurrentLocation: false,
            pendingPurpose: .mapFocus
        ))
        XCTAssertFalse(LocationAuthorizationContinuationPolicy.shouldRequestFix(
            authorizationStatus: .denied,
            useCurrentLocation: true,
            pendingPurpose: .subscription
        ))
        XCTAssertFalse(LocationAuthorizationContinuationPolicy.shouldRequestFix(
            authorizationStatus: .authorizedWhenInUse,
            useCurrentLocation: true,
            pendingPurpose: nil
        ))
    }

    func testLocationFixRemainingLifetimeUsesOriginalTimestampBoundaries() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func location(age: TimeInterval) -> CLLocation {
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 35, longitude: 140),
                altitude: 0,
                horizontalAccuracy: 25,
                verticalAccuracy: 25,
                timestamp: now.addingTimeInterval(-age)
            )
        }

        XCTAssertEqual(
            LocationFixPolicy.remainingLifetime(for: location(age: 0), now: now),
            120,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            LocationFixPolicy.remainingLifetime(for: location(age: 119), now: now),
            1,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            LocationFixPolicy.remainingLifetime(for: location(age: 120), now: now),
            0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            LocationFixPolicy.remainingLifetime(for: location(age: 121), now: now),
            0,
            accuracy: 0.000_001
        )
    }

    func testCancelledLocationExpirationTaskDoesNotRunCallback() async {
        var didExpire = false
        let task = LocationFixPolicy.expirationTask(
            after: 1,
            sleep: { _ in
                await Task.yield()
                try Task.checkCancellation()
            }
        ) {
            didExpire = true
        }

        task.cancel()
        await task.value

        XCTAssertFalse(didExpire)
    }

    func testExpiredLocationTaskRunsAtZeroRemainingLifetime() async {
        var didExpire = false
        let task = LocationFixPolicy.expirationTask(after: 0) {
            didExpire = true
        }

        await task.value

        XCTAssertTrue(didExpire)
    }

    func testTestAlertCanRepairAStoppedRegistrationWhenADeviceTokenExists() {
        XCTAssertTrue(PushTestAlertPolicy.isAvailable(
            subscriptionEnabled: true,
            registrationState: .active,
            hasDeviceToken: true
        ))
        XCTAssertFalse(PushTestAlertPolicy.isAvailable(
            subscriptionEnabled: true,
            registrationState: .registering,
            hasDeviceToken: true
        ))
        XCTAssertTrue(PushTestAlertPolicy.isAvailable(
            subscriptionEnabled: true,
            registrationState: .failed,
            hasDeviceToken: true
        ))
        XCTAssertTrue(PushTestAlertPolicy.isAvailable(
            subscriptionEnabled: true,
            registrationState: .unregistered,
            hasDeviceToken: true
        ))
        XCTAssertFalse(PushTestAlertPolicy.isAvailable(
            subscriptionEnabled: false,
            registrationState: .active,
            hasDeviceToken: true
        ))
        XCTAssertFalse(PushTestAlertPolicy.isAvailable(
            subscriptionEnabled: true,
            registrationState: .active,
            hasDeviceToken: false
        ))
    }

    func testTestAlertRepairsOnlyKnownPreDeliveryIntegrityFailures() {
        XCTAssertTrue(PushTestAlertPolicy.shouldRepairRegistration(
            after: APIError.server(statusCode: 404, message: "device not found")
        ))
        XCTAssertTrue(PushTestAlertPolicy.shouldRepairRegistration(
            after: AppAttestError.proofGenerationFailed(
                underlying: NSError(domain: DCErrorDomain, code: DCError.invalidKey.rawValue)
            )
        ))
        XCTAssertTrue(PushTestAlertPolicy.shouldRepairRegistration(
            after: AppAttestError.serverRejectedCredential
        ))
        XCTAssertFalse(PushTestAlertPolicy.shouldRepairRegistration(
            after: APIError.server(statusCode: 503, message: "APNs unavailable")
        ))
        XCTAssertFalse(PushTestAlertPolicy.shouldRepairRegistration(
            after: URLError(.timedOut)
        ))
    }

    func testAPIValidationPreservesTheHTTPStatusUsedForRegistrationRepair() throws {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://example.invalid/v1/devices/test")!,
            statusCode: 404,
            httpVersion: nil,
            headerFields: nil
        ))
        let body = Data(#"{"error":"device not found"}"#.utf8)

        XCTAssertThrowsError(try APIClient.validate(response, data: body)) { error in
            guard let apiError = error as? APIError else {
                return XCTFail("Expected APIError, received \(error)")
            }
            XCTAssertEqual(apiError.statusCode, 404)
            XCTAssertEqual(apiError.errorDescription, "device not found")
            XCTAssertTrue(PushTestAlertPolicy.shouldRepairRegistration(after: apiError))
        }
    }
}
