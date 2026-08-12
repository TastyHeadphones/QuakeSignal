import UIKit
import UserNotifications

@Observable
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private(set) var deviceToken: String?
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    var onNotificationTapped: ((PushPayload) -> Void)?

    private override init() { super.init() }

    func configure() {
        UNUserNotificationCenter.current().delegate = self
        refreshAuthorizationStatus()
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            // The backend marks genuinely current warnings as time-sensitive.
            // iOS 26 uses the signed time-sensitive entitlement instead of a
            // separate permission option; people still control that behavior
            // in the system notification settings. Critical Alerts remain
            // intentionally unsupported.
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorizationStatusAsync()
            return granted
        } catch {
            return false
        }
    }

    func refreshAuthorizationStatus() {
        Task { await refreshAuthorizationStatusAsync() }
    }

    private func refreshAuthorizationStatusAsync() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
        registerForRemoteNotificationsIfAuthorized()
    }

    func didRegister(deviceToken data: Data) {
        deviceToken = data.map { String(format: "%02x", $0) }.joined()
    }

    /// APNs failures are part of the alert-registration lifecycle, not merely
    /// diagnostic output. Preserve a retryable state so Settings can explain
    /// what happened and offer the same retry path used for server failures.
    func didFailToRegisterForRemoteNotifications() {
        deviceToken = nil
        if AppSettings.shared.pushSubscriptionEnabled {
            AppSettings.shared.pushRegistrationState = .failed
        }
    }

    /// Requests the current APNs token when notification permission permits
    /// it. Calling this on each app launch lets APNs rotate a token safely.
    func registerForRemoteNotificationsIfAuthorized() {
        guard canRegisterForRemoteNotifications else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// The token is only cached in memory. Clearing it after a successful
    /// server-side deletion prevents an in-session preference change from
    /// accidentally creating a new registration.
    func clearDeviceToken() {
        deviceToken = nil
        UIApplication.shared.unregisterForRemoteNotifications()
    }

    var canRegisterForRemoteNotifications: Bool {
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            true
        case .notDetermined, .denied:
            false
        @unknown default:
            false
        }
    }

    // MARK: UNUserNotificationCenterDelegate
    // These are called by the system off the main actor, so they're kept
    // nonisolated and hop back to the main actor explicitly before touching
    // any of this class's state.

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let payload = PushPayload(userInfo: response.notification.request.content.userInfo)
        await MainActor.run {
            self.onNotificationTapped?(payload)
        }
    }
}
