import SwiftUI
#if DEBUG && targetEnvironment(macCatalyst)
import UIKit
#endif

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
        let initialTab: RootTab = switch ScreenshotAutomation.rootDestination(
            for: ScreenshotAutomation.selectedFrame
        ) {
        case .home: .home
        case .reports: .reports
        case .map: .map
        case .guide: .guide
        case .settings: .settings
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
        .background {
#if DEBUG && targetEnvironment(macCatalyst)
            CatalystScreenshotGeometryProbe()
#endif
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

    /// Prefer the compact, structurally validated push snapshot. Legacy or
    /// unusable payloads resolve from memory or refresh directly from Wolfx;
    /// Cloudflare never serves earthquake data.
    private func handleTap(_ payload: PushPayload) async {
        guard let compositeId = payload.compositeEventId else { return }
        let reason = AlertPresentationReason(wireValue: payload.reason)

        if let snapshot = payload.eventSnapshot {
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
        if let snapshot = payload.eventSnapshot {
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

#if DEBUG && targetEnvironment(macCatalyst)
/// Resolves the scene from a UIView hosted by this exact RootView. Looking at
/// `UIApplication.connectedScenes.first` can resize a different window when
/// state restoration or another scene is present.
private struct CatalystScreenshotGeometryProbe: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.onWindowChanged = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window, probe: view)
        }
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        context.coordinator.attach(to: uiView.window, probe: uiView)
    }

    static func dismantleUIView(_ uiView: ProbeView, coordinator: Coordinator) {
        coordinator.cancel()
        uiView.onWindowChanged = nil
    }

    final class ProbeView: UIView {
        var onWindowChanged: ((UIWindow?) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onWindowChanged?(window)
        }
    }

    @MainActor
    final class Coordinator {
        private weak var attachedWindow: UIWindow?
        private var geometryTask: Task<Void, Never>?
        private var finished = false

        func attach(to window: UIWindow?, probe: ProbeView) {
            guard !finished,
                  geometryTask == nil,
                  let window,
                  attachedWindow !== window,
                  let windowScene = window.windowScene,
                  let evidenceRootPath = ScreenshotAutomation.macCaptureEvidenceRootPath(
                      screenshotAutomationEnabled: ScreenshotAutomation.isEnabled,
                      selectedFrame: ScreenshotAutomation.selectedFrame,
                      environment: ProcessInfo.processInfo.environment
                  ),
                  let selectedFrame = ScreenshotAutomation.selectedFrame,
                  let targetFrame = ScreenshotAutomation.macCaptureTargetSystemFrame(
                      screenshotAutomationEnabled: ScreenshotAutomation.isEnabled,
                      selectedFrame: ScreenshotAutomation.selectedFrame,
                      currentSystemFrame: windowScene.effectiveGeometry.systemFrame
                  ) else {
                return
            }

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: evidenceRootPath, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return
            }

            let evidenceURL = URL(fileURLWithPath: evidenceRootPath, isDirectory: true)
                .appendingPathComponent("geometry-\(ProcessInfo.processInfo.processIdentifier).json")

            attachedWindow = window
            probe.isAccessibilityElement = false
            probe.accessibilityIdentifier = nil
            probe.accessibilityLabel = nil

            windowScene.requestGeometryUpdate(
                UIWindowScene.GeometryPreferences.Mac(systemFrame: targetFrame)
            ) { [weak self, weak probe] error in
                Task { @MainActor in
                    self?.fail(
                        probe: probe,
                        evidenceURL: evidenceURL,
                        selectedFrame: selectedFrame,
                        reason: "geometry request failed: \(error.localizedDescription)"
                    )
                }
            }

            geometryTask = Task { @MainActor [weak self, weak window, weak probe, weak windowScene] in
                var previousFrame: CGRect?
                var stableObservationCount = 0

                // Eight seconds is intentionally bounded. Capture tooling must
                // observe the atomic ready evidence or fail without image bytes.
                for _ in 0..<80 {
                    guard !Task.isCancelled else { return }
                    try? await Task.sleep(for: .milliseconds(100))
                    guard let self,
                          let window,
                          let probe,
                          let windowScene,
                          window.windowScene === windowScene else {
                        self?.fail(
                            probe: probe,
                            evidenceURL: evidenceURL,
                            selectedFrame: selectedFrame,
                            reason: "window scene changed before geometry stabilized"
                        )
                        return
                    }

                    let currentFrame = windowScene.effectiveGeometry.systemFrame
                    if ScreenshotAutomation.macCaptureGeometryIsStable(
                        systemFrame: currentFrame,
                        previousSystemFrame: previousFrame,
                        backingScale: window.screen.scale
                    ) {
                        stableObservationCount += 1
                    } else {
                        stableObservationCount = 0
                    }
                    previousFrame = currentFrame

                    if stableObservationCount >= 3 {
                        self.markReady(
                            probe: probe,
                            evidenceURL: evidenceURL,
                            selectedFrame: selectedFrame,
                            systemFrame: currentFrame,
                            scale: window.screen.scale
                        )
                        return
                    }
                }

                self?.fail(
                    probe: probe,
                    evidenceURL: evidenceURL,
                    selectedFrame: selectedFrame,
                    reason: "geometry did not stabilize at 1280x800 points and 2x"
                )
            }
        }

        func cancel() {
            geometryTask?.cancel()
            geometryTask = nil
        }

        private func markReady(
            probe: ProbeView,
            evidenceURL: URL,
            selectedFrame: ScreenshotAutomation.Frame,
            systemFrame: CGRect,
            scale: CGFloat
        ) {
            guard !finished else { return }
            do {
                try writeGeometryEvidence(
                    status: "ready",
                    reason: nil,
                    evidenceURL: evidenceURL,
                    selectedFrame: selectedFrame,
                    systemFrame: systemFrame,
                    scale: scale
                )
            } catch {
                fail(
                    probe: probe,
                    evidenceURL: evidenceURL,
                    selectedFrame: selectedFrame,
                    reason: "could not publish geometry evidence: \(error.localizedDescription)"
                )
                return
            }
            finished = true
            geometryTask = nil
            probe.isAccessibilityElement = true
            probe.accessibilityIdentifier = ScreenshotAutomation.macCaptureReadyAccessibilityIdentifier
            probe.accessibilityLabel = "QuakeSignal Catalyst screenshot geometry ready"
            probe.accessibilityValue = "\(Int(systemFrame.width)) by \(Int(systemFrame.height)) points at \(Int(scale))x"
            print("CATALYST_SCREENSHOT_GEOMETRY_READY frame=\(systemFrame) scale=\(scale)")
        }

        private func fail(
            probe: ProbeView?,
            evidenceURL: URL,
            selectedFrame: ScreenshotAutomation.Frame,
            reason: String
        ) {
            guard !finished else { return }
            finished = true
            geometryTask?.cancel()
            geometryTask = nil
            try? writeGeometryEvidence(
                status: "failed",
                reason: reason,
                evidenceURL: evidenceURL,
                selectedFrame: selectedFrame,
                systemFrame: attachedWindow?.windowScene?.effectiveGeometry.systemFrame ?? .zero,
                scale: attachedWindow?.screen.scale ?? 0
            )
            probe?.isAccessibilityElement = true
            probe?.accessibilityIdentifier = ScreenshotAutomation.macCaptureFailedAccessibilityIdentifier
            probe?.accessibilityLabel = "QuakeSignal Catalyst screenshot geometry failed"
            probe?.accessibilityValue = reason
            print("CATALYST_SCREENSHOT_GEOMETRY_FAILED \(reason)")
        }

        private func writeGeometryEvidence(
            status: String,
            reason: String?,
            evidenceURL: URL,
            selectedFrame: ScreenshotAutomation.Frame,
            systemFrame: CGRect,
            scale: CGFloat
        ) throws {
            let record: [String: Any] = [
                "schemaVersion": 1,
                "status": status,
                "reason": reason as Any,
                "processId": ProcessInfo.processInfo.processIdentifier,
                "captureSelector": selectedFrame.rawValue,
                "logicalFrame": [
                    "x": systemFrame.minX,
                    "y": systemFrame.minY,
                    "width": systemFrame.width,
                    "height": systemFrame.height,
                ],
                "backingScale": scale,
                "recordedAtUtc": ISO8601DateFormatter().string(from: Date()),
            ]
            let data = try JSONSerialization.data(
                withJSONObject: record,
                options: [.prettyPrinted, .sortedKeys]
            )
            let temporaryURL = evidenceURL.deletingLastPathComponent().appendingPathComponent(
                ".\(evidenceURL.lastPathComponent).\(UUID().uuidString).tmp"
            )
            try data.write(to: temporaryURL, options: .withoutOverwriting)
            do {
                try FileManager.default.moveItem(at: temporaryURL, to: evidenceURL)
            } catch {
                try? FileManager.default.removeItem(at: temporaryURL)
                throw error
            }
        }
    }
}
#endif

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
