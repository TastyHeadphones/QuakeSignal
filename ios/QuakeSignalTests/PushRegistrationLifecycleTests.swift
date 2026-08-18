import Foundation
import CoreLocation
import DeviceCheck
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
        XCTAssertEqual(AlertPresentationReason(wireValue: payload.reason), .updated)
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
