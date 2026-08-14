import Foundation
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

    func testTestAlertRequiresAnActiveServerRegistrationAndDeviceToken() {
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
        XCTAssertFalse(PushTestAlertPolicy.isAvailable(
            subscriptionEnabled: true,
            registrationState: .failed,
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
}
