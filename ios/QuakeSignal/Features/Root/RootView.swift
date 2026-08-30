import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = QuakeStore.shared
    @State private var notifications = NotificationManager.shared
    @State private var locationManager = LocationManager.shared
    @State private var isSynchronizingPushRegistration = false
    @State private var needsPushRegistration = false
    @State private var showingUnavailableAlert = false
    @AppStorage("onboarding.completed") private var hasCompletedOnboarding = false

    var body: some View {
        @Bindable var store = store

        Group {
            if hasCompletedOnboarding {
                NativeRootTabs()
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
            notifications.onNotificationTapped = { payload in
                Task { await handleTap(payload) }
            }
            notifications.onForegroundNotification = { payload in
                Task { await handleForegroundNotification(payload) }
            }
            // AppDelegate configures the notification delegate before launch
            // finishes; callbacks buffered before this task are drained when
            // these handlers are installed.
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
        .alert("notification.unavailable.title", isPresented: $showingUnavailableAlert) {
            Button("alert.dismiss", role: .cancel) {}
        } message: {
            Text("notification.unavailable.message")
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
        let reason = AlertPresentationReason(wireValue: payload.reason)

        if let snapshot = payload.eventSnapshot, snapshot.id == compositeId {
            store.ingestTapped(event: snapshot, reason: reason)
            return
        }

        if let cached = store.events.first(where: { $0.id == compositeId }) {
            store.presentedAlert = PresentedAlert(event: cached, reason: reason)
            return
        }

        await store.refresh()
        if let fetched = store.events.first(where: { $0.id == compositeId }) {
            store.ingestTapped(event: fetched, reason: reason)
        } else {
            showingUnavailableAlert = true
        }
    }

    private func handleForegroundNotification(_ payload: PushPayload) async {
        guard let compositeId = payload.compositeEventId else { return }
        let reason = AlertPresentationReason(wireValue: payload.reason)
        if let snapshot = payload.eventSnapshot, snapshot.id == compositeId {
            store.ingestForegroundNotification(event: snapshot, reason: reason)
            return
        }
        if let cached = store.events.first(where: { $0.id == compositeId }) {
            store.ingestForegroundNotification(event: cached, reason: reason)
            return
        }
        await store.refresh()
        if let fetched = store.events.first(where: { $0.id == compositeId }) {
            store.ingestForegroundNotification(event: fetched, reason: reason)
        }
    }
}

private struct NativeRootTabs: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedTab: NativeUITab = .home

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                NavigationSplitView {
                    NativeGlassSidebar(selection: $selectedTab)
                } detail: {
                    nativeTabRoot(selectedTab)
                }
            } else {
                TabView(selection: $selectedTab) {
                    ForEach(NativeUINavigation.rootTabs) { tab in
                        nativeTabRoot(tab)
                            .tag(tab)
                    }
                }
                .toolbar(.hidden, for: .tabBar)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    NativeGlassTabBar(selection: $selectedTab)
                }
            }
        }
        .tint(Color("BrandColor"))
        .environment(\.nativeUITabSelection, $selectedTab)
    }

    @ViewBuilder
    private func nativeTabRoot(_ tab: NativeUITab) -> some View {
        switch tab {
        case .home: HomeView()
        case .reports: QuakeListView()
        case .map: EpicenterMapView()
        case .guide: DisasterGuideView()
        case .settings: SettingsView()
        }
    }
}

private struct NativeGlassTabBar: View {
    @Binding var selection: NativeUITab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(NativeUINavigation.rootTabs) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 1) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 18, weight: .medium))
                        Text(LocalizedStringKey(tab.titleKey))
                            .font(.system(size: 10, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .foregroundStyle(selection == tab ? Color("BrandColor") : Color.secondary)
                    .background {
                        if selection == tab {
                            Capsule()
                                .fill(Color("GroupedBGColor").opacity(0.72))
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(LocalizedStringKey(tab.titleKey)))
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .padding(4)
        .nativeGlassCard(cornerRadius: 32)
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }
}

private struct NativeGlassSidebar: View {
    @Binding var selection: NativeUITab

    var body: some View {
        List {
            ForEach(NativeUINavigation.rootTabs) { tab in
                Button {
                    selection = tab
                } label: {
                    Label(LocalizedStringKey(tab.titleKey), systemImage: tab.systemImage)
                }
                .listRowBackground(selection == tab ? Color("BrandColor").opacity(0.12) : Color.clear)
                .foregroundStyle(selection == tab ? Color("BrandColor") : Color.primary)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("app.name")
        .nativeGroupedChrome()
    }
}
