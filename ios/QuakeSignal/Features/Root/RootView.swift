import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = QuakeStore.shared
    @State private var notifications = NotificationManager.shared
    @State private var locationManager = LocationManager.shared
    @State private var isSynchronizingPushRegistration = false
    @State private var needsPushRegistration = false
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
            // `configure()` asks APNs for a fresh token on every authorized
            // launch; this schedules registration immediately if one arrives.
            schedulePushRegistration()
            if AppSettings.shared.useCurrentLocation {
                locationManager.requestCurrentLocation()
            }
            store.setForegroundActive(scenePhase == .active)
            await store.start()
        }
        .onChange(of: notifications.deviceToken) { _, _ in
            schedulePushRegistration()
        }
        .onChange(of: notifications.authorizationStatus) { _, _ in
            schedulePushRegistration()
        }
        .onChange(of: scenePhase) { _, phase in
            store.setForegroundActive(phase == .active)
            guard phase == .active else { return }
            // A person can grant notifications from the iOS Settings screen
            // opened by this app. Refresh when the scene returns so we request
            // a current APNs token and the normal status observer schedules
            // its protected server registration without requiring a relaunch.
            notifications.refreshAuthorizationStatus()
            if AppSettings.shared.useCurrentLocation {
                // Refresh the real CLLocationManager state after returning from
                // iPhone Settings, then request a fresh fix. The cached status
                // can otherwise leave the app stuck on the old city fallback.
                locationManager.requestCurrentLocation()
            }
        }
        .onChange(of: coarseCurrentLocation) { _, _ in
            // Observing the quantized cell, rather than every GPS fix, keeps
            // re-registration bounded while still resyncing after the first
            // current-location result or a meaningful movement.
            schedulePushRegistration()
        }
    }

    private var coarseCurrentLocation: CoarseCoordinate? {
        guard AppSettings.shared.useCurrentLocation,
              let currentLocation = locationManager.currentLocation else {
            return nil
        }
        return CoarseCoordinate(currentLocation)
    }

    /// Coalesces startup, authorization, APNs-token, and coarse-location
    /// triggers. A trigger received during an in-flight request causes one
    /// follow-up registration with the newest preferences and location.
    @MainActor
    private func schedulePushRegistration() {
        guard AppSettings.shared.pushSubscriptionEnabled,
              notifications.canRegisterForRemoteNotifications,
              notifications.deviceToken != nil else {
            return
        }

        needsPushRegistration = true
        guard !isSynchronizingPushRegistration else { return }
        isSynchronizingPushRegistration = true

        Task { @MainActor in
            defer { isSynchronizingPushRegistration = false }

            while needsPushRegistration {
                needsPushRegistration = false
                guard AppSettings.shared.pushSubscriptionEnabled,
                      notifications.canRegisterForRemoteNotifications,
                      let token = notifications.deviceToken else {
                    return
                }
                do {
                    try await store.registerForPush(token: token)
                } catch {
                    // `QuakeStore` durably records `.failed` before it
                    // rethrows. Do not spin on a transient outage here; the
                    // Settings retry control and the next meaningful APNs,
                    // location, or preference trigger can attempt it again.
                    return
                }
            }
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
