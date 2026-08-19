import SwiftUI

private enum RootTab: Hashable {
    case home
    case reports
    case map
    case guide
    case settings
}

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = QuakeStore.shared
    @State private var notifications = NotificationManager.shared
    @State private var locationManager = LocationManager.shared
    @State private var isSynchronizingPushRegistration = false
    @State private var needsPushRegistration = false
    @State private var showingUnavailableAlert = false
    @AppStorage("onboarding.completed") private var hasCompletedOnboarding = false
    @State private var selectedTab: RootTab

    init() {
        let initialTab: RootTab = switch ScreenshotAutomation.selectedFrame {
        case .visionReports: .reports
        case .visionMap: .map
        case .visionGuide: .guide
        case .visionAlertPreferences: .settings
        default: .home
        }
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        @Bindable var store = store

        Group {
            if hasCompletedOnboarding || ScreenshotAutomation.isEnabled {
                TabView(selection: $selectedTab) {
                    HomeView()
                        .tabItem { Label("tab.home", systemImage: "waveform.path.ecg") }
                        .tag(RootTab.home)
                    QuakeListView()
                        .tabItem { Label("tab.list", systemImage: "list.bullet") }
                        .tag(RootTab.reports)
                    EpicenterMapView()
                        .tabItem { Label("tab.map", systemImage: "map") }
                        .tag(RootTab.map)
                    DisasterGuideView()
                        .tabItem { Label("tab.guide", systemImage: "cross.case") }
                        .tag(RootTab.guide)
                    SettingsView()
                        .tabItem { Label("tab.settings", systemImage: "gearshape") }
                        .tag(RootTab.settings)
                }
                .tint(Color("BrandColor"))
            } else {
                OnboardingView(hasCompletedOnboarding: $hasCompletedOnboarding)
            }
        }
        .fullScreenCover(item: $store.presentedAlert) { alert in
            switch alert.mode {
            case .emergency:
                EEWAlertView(event: alert.event, reason: alert.reason) {
                    store.presentedAlert = nil
                }
            case .detail:
                NotificationEventDetailCover(event: alert.event) {
                    store.presentedAlert = nil
                }
            }
        }
        .task {
            guard !ScreenshotAutomation.isEnabled else {
                updateForegroundLifecycle(isActive: false)
                return
            }
            updateForegroundLifecycle(isActive: scenePhase == .active)
            notifications.onNotificationTapped = { payload in
                Task { await handleTap(payload) }
            }
            notifications.onForegroundNotification = { delivery in
                Task { await handleForegroundNotification(delivery) }
            }
            // AppDelegate configures the notification delegate before launch
            // finishes; callbacks buffered before this task are drained when
            // these handlers are installed.
            schedulePushRegistration()
            if AppSettings.shared.useCurrentLocation {
                locationManager.requestCurrentLocation()
            }
            await store.start()
        }
        .onChange(of: notifications.deviceToken) { _, _ in
            schedulePushRegistration()
        }
        .onChange(of: notifications.authorizationStatus) { _, _ in
            schedulePushRegistration()
        }
        .onChange(of: scenePhase) { _, phase in
            guard !ScreenshotAutomation.isEnabled else { return }
            updateForegroundLifecycle(isActive: phase == .active)
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
        .alert("notification.unavailable.title", isPresented: $showingUnavailableAlert) {
            Button("alert.dismiss", role: .cancel) {}
        } message: {
            Text("notification.unavailable.message")
        }
    }

    @MainActor
    private func updateForegroundLifecycle(isActive: Bool) {
        store.setForegroundActive(isActive)
        notifications.setForegroundSceneActive(isActive)
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
        guard !ScreenshotAutomation.isEnabled,
              PlatformCapabilities.supportsAttestedAlertRegistration,
              AppSettings.shared.pushSubscriptionEnabled,
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
        let reason = AlertPresentationReason(wireValue: payload.reason)

        if let snapshot = payload.eventSnapshot, snapshot.id == compositeId {
            store.ingestTapped(event: snapshot, reason: reason)
            return
        }

        if let cached = store.events.first(where: { $0.id == compositeId }) {
            store.ingestTapped(event: cached, reason: reason)
            return
        }

        await store.refresh()
        if let fetched = store.events.first(where: { $0.id == compositeId }) {
            store.ingestTapped(event: fetched, reason: reason)
        } else {
            showingUnavailableAlert = true
        }
    }

    private func handleForegroundNotification(_ delivery: ForegroundNotificationDelivery) async {
        let payload = delivery.payload
        guard let compositeId = payload.compositeEventId else { return }
        let reason = AlertPresentationReason(wireValue: payload.reason)
        if let snapshot = payload.eventSnapshot, snapshot.id == compositeId {
            store.ingestForegroundNotification(
                event: snapshot,
                reason: reason,
                allowsEmergencyPresentation: delivery.shouldPresentEmergencyInApp
            )
            return
        }
        if let cached = store.events.first(where: { $0.id == compositeId }) {
            store.ingestForegroundNotification(
                event: cached,
                reason: reason,
                allowsEmergencyPresentation: delivery.shouldPresentEmergencyInApp
            )
            return
        }
        await store.refresh()
        if let fetched = store.events.first(where: { $0.id == compositeId }) {
            store.ingestForegroundNotification(
                event: fetched,
                reason: reason,
                allowsEmergencyPresentation: delivery.shouldPresentEmergencyInApp
            )
        }
    }
}

private struct NotificationEventDetailCover: View {
    let event: EEWEvent
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            QuakeDetailView(event: event)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("alert.dismiss", action: onDismiss)
                    }
                }
        }
    }
}
