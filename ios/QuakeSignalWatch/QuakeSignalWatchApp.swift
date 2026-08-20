import SwiftUI

@main
struct QuakeSignalWatchApp: App {
    init() {
        guard !ScreenshotAutomation.isEnabled else { return }
        WatchAlertPreferenceBridge.activateWatch()
    }

    var body: some Scene {
        WindowGroup {
            WatchDashboardView()
        }
    }
}
