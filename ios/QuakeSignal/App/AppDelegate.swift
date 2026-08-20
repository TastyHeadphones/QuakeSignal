import UIKit

/// Bridges UIKit's remote-notification registration callbacks into the
/// (SwiftUI-lifecycle) app. Required because there is no SwiftUI-native way
/// to receive `didRegisterForRemoteNotificationsWithDeviceToken`.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        guard !ScreenshotAutomation.isEnabled else { return true }
        NotificationManager.shared.configureForLaunch()
        WatchAlertPreferenceBridge.activatePhone(current: AppSettings.shared.alertSound)
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in
            NotificationManager.shared.didRegister(deviceToken: deviceToken)
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in
            NotificationManager.shared.didFailToRegisterForRemoteNotifications()
        }
    }
}
