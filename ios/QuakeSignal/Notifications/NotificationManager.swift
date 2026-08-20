import UIKit
import UserNotifications

struct ForegroundNotificationDelivery {
    let payload: PushPayload
    let shouldPresentEmergencyInApp: Bool
}

@Observable
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private(set) var deviceToken: String?
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    private(set) var alertSetting: UNNotificationSetting = .notSupported
    private(set) var soundSetting: UNNotificationSetting = .notSupported
    private(set) var timeSensitiveSetting: UNNotificationSetting = .notSupported
    private var isForegroundSceneActive = false
    var onNotificationTapped: ((PushPayload) -> Void)? {
        didSet { drainPendingTappedPayloads() }
    }
    var onForegroundNotification: ((ForegroundNotificationDelivery) -> Void)? {
        didSet { drainPendingForegroundPayloads() }
    }

    private var pendingTappedPayloads: [PushPayload] = []
    private var pendingForegroundPayloads: [ForegroundNotificationDelivery] = []

    private override init() { super.init() }

    /// Must be called synchronously from `didFinishLaunching`. Apple may
    /// deliver a cold-launch notification response before SwiftUI mounts its
    /// root view, so callbacks are buffered until RootView installs handlers.
    func configureForLaunch() {
        guard !ScreenshotAutomation.isEnabled else { return }
        UNUserNotificationCenter.current().delegate = self
        refreshAuthorizationStatus()
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        guard !ScreenshotAutomation.isEnabled,
              PlatformCapabilities.supportsAttestedAlertRegistration else {
            return false
        }
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
        guard !ScreenshotAutomation.isEnabled else { return }
        Task { await refreshAuthorizationStatusAsync() }
    }

    /// RootView updates this synchronously with QuakeStore's lifecycle. The
    /// value is sampled when each notification arrives and that exact decision
    /// travels with buffered callbacks.
    func setForegroundSceneActive(_ isActive: Bool) {
        isForegroundSceneActive = isActive
    }

    private func refreshAuthorizationStatusAsync() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
        alertSetting = settings.alertSetting
        soundSetting = settings.soundSetting
        timeSensitiveSetting = settings.timeSensitiveSetting
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
        guard !ScreenshotAutomation.isEnabled,
              PlatformCapabilities.supportsAttestedAlertRegistration,
              canRegisterForRemoteNotifications else { return }
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
        guard PlatformCapabilities.supportsAttestedAlertRegistration else {
            return false
        }
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined, .denied:
            return false
        @unknown default:
            return false
        }
    }

    var hasVisibleAlertsEnabled: Bool {
        canRegisterForRemoteNotifications && alertSetting == .enabled
    }

    var hasSoundsEnabled: Bool {
        canRegisterForRemoteNotifications && soundSetting == .enabled
    }

    var hasTimeSensitiveAlertsEnabled: Bool {
        canRegisterForRemoteNotifications && timeSensitiveSetting == .enabled
    }

    private func deliverTapped(_ payload: PushPayload) {
        if let onNotificationTapped {
            onNotificationTapped(payload)
        } else {
            pendingTappedPayloads.append(payload)
            pendingTappedPayloads = Array(pendingTappedPayloads.suffix(5))
        }
    }

    private func deliverForeground(_ delivery: ForegroundNotificationDelivery) {
        if let onForegroundNotification {
            onForegroundNotification(delivery)
        } else {
            pendingForegroundPayloads.append(delivery)
            pendingForegroundPayloads = Array(pendingForegroundPayloads.suffix(5))
        }
    }

    private func drainPendingTappedPayloads() {
        guard let onNotificationTapped, !pendingTappedPayloads.isEmpty else { return }
        let pending = pendingTappedPayloads
        pendingTappedPayloads.removeAll()
        pending.forEach(onNotificationTapped)
    }

    private func drainPendingForegroundPayloads() {
        guard let onForegroundNotification, !pendingForegroundPayloads.isEmpty else { return }
        let pending = pendingForegroundPayloads
        pendingForegroundPayloads.removeAll()
        pending.forEach(onForegroundNotification)
    }

    // MARK: UNUserNotificationCenterDelegate
    // These are called by the system off the main actor, so they're kept
    // nonisolated and hop back to the main actor explicitly before touching
    // any of this class's state.

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let payload = PushPayload(userInfo: notification.request.content.userInfo)
        let decision = await MainActor.run {
            let decision = ForegroundNotificationPresentationPolicy.decision(
                for: payload,
                // Require both the scene callback and UIKit's receipt-time
                // application state. During a Control/Notification Center or
                // interruption transition, UIKit can become inactive before
                // SwiftUI delivers scenePhase's onChange callback.
                isSceneActive: self.isForegroundSceneActive &&
                    UIApplication.shared.applicationState == .active
            )
            self.deliverForeground(ForegroundNotificationDelivery(
                payload: payload,
                shouldPresentEmergencyInApp: decision.shouldPresentEmergencyInApp
            ))
            return decision
        }

        switch decision.systemPresentation {
        case .alert:
            // Token tests, unusable/mismatched snapshots, launch-buffered
            // pushes, and real events received while the scene is inactive
            // retain the APNs banner and sound.
            return [.banner, .sound, .list]
        case .listOnly:
            // The active app owns the visible emergency UI and selected sound.
            return [.list]
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let payload = PushPayload(userInfo: response.notification.request.content.userInfo)
        await MainActor.run {
            self.deliverTapped(payload)
        }
    }
}
