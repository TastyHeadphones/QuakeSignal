import SwiftUI

struct RootView: View {
    @State private var store = QuakeStore.shared
    @State private var notifications = NotificationManager.shared
    @State private var locationManager = LocationManager.shared
    @AppStorage("onboarding.completed") private var hasCompletedOnboarding = false

    var body: some View {
        @Bindable var store = store

        Group {
            if hasCompletedOnboarding {
                TabView {
                    HomeView()
                        .tabItem { Label("tab.home", systemImage: "waveform.path.ecg") }
                    QuakeListView()
                        .tabItem { Label("tab.list", systemImage: "list.bullet") }
                    EpicenterMapView()
                        .tabItem { Label("tab.map", systemImage: "map") }
                    DisasterGuideView()
                        .tabItem { Label("tab.guide", systemImage: "cross.case") }
                    SettingsView()
                        .tabItem { Label("tab.settings", systemImage: "gearshape") }
                }
                .tint(Color("BrandColor"))
            } else {
                OnboardingView(hasCompletedOnboarding: $hasCompletedOnboarding)
            }
        }
        .fullScreenCover(item: $store.presentedAlert) { alert in
            EEWAlertView(event: alert.event, reason: alert.reason) {
                store.presentedAlert = nil
            }
        }
        .task {
            notifications.configure()
            notifications.onNotificationTapped = { payload in
                Task { await handleTap(payload) }
            }
            if AppSettings.shared.useCurrentLocation {
                locationManager.requestLocationUpdate()
            }
            await store.start()
        }
        .onChange(of: notifications.deviceToken) { _, newToken in
            guard let newToken else { return }
            Task { await store.registerForPush(token: newToken) }
        }
    }

    /// A tapped push only carries eventId/sourceId/reason (see PushPayload).
    /// Resolve it from memory or refresh directly from Wolfx; Cloudflare never
    /// serves earthquake data.
    private func handleTap(_ payload: PushPayload) async {
        guard let compositeId = payload.compositeEventId else { return }
        let reason = payload.reason ?? "new"

        if let cached = store.events.first(where: { $0.id == compositeId }) {
            store.presentedAlert = PresentedAlert(event: cached, reason: reason)
            return
        }

        await store.refresh()
        if let fetched = store.events.first(where: { $0.id == compositeId }) {
            store.ingest(event: fetched, reason: reason)
        }
    }
}
