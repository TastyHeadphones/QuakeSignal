import SwiftUI
#if DEBUG && targetEnvironment(macCatalyst)
import CryptoKit
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
    @State private var settings = AppSettings.shared
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
                let payload = delivery.payload
                let reason = AlertPresentationReason(wireValue: payload.reason)
                if let snapshot = payload.eventSnapshot {
                    return store.ingestForegroundNotification(
                        event: snapshot,
                        reason: reason,
                        allowsEmergencyPresentation: delivery.allowsEmergencyPresentation
                    )
                }

                if let revisionKey = payload.foregroundRevisionKey {
                    store.reserveSystemPresentation(
                        for: revisionKey,
                        receivedAt: delivery.receivedAt
                    )
                }
                Task { await handleSystemPresentedForegroundNotification(payload) }
                return false
            }
            // AppDelegate configures the notification delegate before launch
            // finishes; callbacks buffered before this task are drained when
            // these handlers are installed. Start a requested GPS renewal
            // first so registration waits for its success/failure instead of
            // deleting a still-valid prior row during the brief launch gap.
            if settings.useCurrentLocation {
                locationManager.requestCurrentLocation()
            }
            schedulePushRegistration()
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
                if !locationManager.isRequestingLocation {
                    // Denied/restricted cannot produce a coordinate callback;
                    // apply the city fallback or stale-row cleanup now.
                    schedulePushRegistration()
                }
            }
        }
        .onChange(of: coarseCurrentLocation) { _, coordinate in
            // Observing the quantized cell, rather than every GPS fix, keeps
            // re-registration bounded while still resyncing after the first
            // current-location result or a meaningful movement.
            if settings.useCurrentLocation, coordinate == nil {
                // Keep the server's last bounded subscription while inactive;
                // foreground renewal will either replace it or explicitly
                // delete it after a failed fix.
                guard scenePhase == .active else { return }
                if !locationManager.isRequestingLocation {
                    locationManager.requestCurrentLocation()
                }
            }
            schedulePushRegistration()
        }
        .onChange(of: locationManager.lastRequestFailed) { _, didFail in
            guard didFail,
                  settings.useCurrentLocation,
                  scenePhase == .active else { return }
            // No coordinate callback follows a failed renewal. Run the same
            // registration path so a city fallback replaces the GPS row, or
            // an absent fallback deletes the now-stale server registration.
            schedulePushRegistration()
        }
        .onChange(of: locationManager.isRequestingLocation) { _, isRequesting in
            guard !isRequesting,
                  settings.useCurrentLocation,
                  scenePhase == .active else { return }
            // A fast cached fix can clear and restore the same coarse cell
            // before SwiftUI observes the intermediate nil coordinate. The
            // request-completion edge guarantees the deferred registration is
            // resumed even when the quantized coordinate itself is unchanged.
            schedulePushRegistration()
        }
        .onChange(of: settings.useCurrentLocation) { _, isEnabled in
            if isEnabled {
                if scenePhase == .active,
                   locationManager.currentLocation == nil,
                   !locationManager.isRequestingLocation {
                    locationManager.requestCurrentLocation()
                }
            } else {
                locationManager.stopUsingSubscriptionLocation()
            }
        }
        .onChange(of: settings.pushRegistrationPreferencesRevision) { _, _ in
            // AppSettings owns this trigger so changes from Home, onboarding,
            // Settings, or any future surface all update the same protected
            // server registration. The coalescer below retains only the newest
            // complete preference/location snapshot.
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
        if settings.useCurrentLocation,
           locationManager.currentLocation == nil,
           locationManager.isRequestingLocation {
            // A saved city is a failure fallback, not an interim replacement
            // for the last server-confirmed GPS area. Wait for this explicit
            // foreground renewal to succeed or fail before changing the row.
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
                    // `QuakeStore` records the authoritative retryable,
                    // failed, or still-active-renewal state before rethrowing.
                    // Do not spin here; Settings and the next meaningful APNs,
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

    /// Snapshotless pushes cannot be claimed synchronously, so APNs has
    /// already retained its banner and sound. Resolve their event only to keep
    /// app state current; never open a duplicate emergency surface afterward.
    private func handleSystemPresentedForegroundNotification(_ payload: PushPayload) async {
        guard let compositeId = payload.compositeEventId else { return }
        let reason = AlertPresentationReason(wireValue: payload.reason)
        if let cached = store.events.first(where: { $0.id == compositeId }) {
            store.ingestForegroundNotification(
                event: cached,
                reason: reason,
                allowsEmergencyPresentation: false
            )
            return
        }
        await store.refresh()
        if let fetched = store.events.first(where: { $0.id == compositeId }) {
            store.ingestForegroundNotification(
                event: fetched,
                reason: reason,
                allowsEmergencyPresentation: false
            )
        }
    }
}

#if DEBUG && targetEnvironment(macCatalyst)
/// Resolves the scene and exact live UIWindow from a UIView hosted by this
/// RootView. Looking at `UIApplication.connectedScenes.first` could resize or
/// render a different window when state restoration creates another scene.
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
        private var captureTask: Task<Void, Never>?
        private var geometryFinished = false
        private var captureFinished = false

        func attach(to window: UIWindow?, probe: ProbeView) {
            guard !geometryFinished,
                  geometryTask == nil,
                  let window,
                  attachedWindow !== window,
                  let windowScene = window.windowScene,
                  ScreenshotAutomation.macHierarchyCaptureIsEnabled(
                      screenshotAutomationEnabled: ScreenshotAutomation.isEnabled,
                      selectedFrame: ScreenshotAutomation.selectedFrame,
                      arguments: ProcessInfo.processInfo.arguments,
                      environment: ProcessInfo.processInfo.environment
                  ),
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

            let evidenceRootURL = URL(fileURLWithPath: evidenceRootPath, isDirectory: true)
            guard let rootValues = try? evidenceRootURL.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            ),
                  rootValues.isDirectory == true,
                  rootValues.isSymbolicLink != true else {
                return
            }

            let evidenceURL = evidenceRootURL
                .appendingPathComponent("geometry-\(ProcessInfo.processInfo.processIdentifier).json")

            attachedWindow = window
            probe.isAccessibilityElement = false
            probe.accessibilityIdentifier = nil
            probe.accessibilityLabel = nil

            // The Catalyst title bar is part of the system frame but not the
            // UIWindow content bounds. Hide its title and toolbar for the
            // reviewed direct-hierarchy capture so the requested 1280x800
            // content surface matches the exact screenshot contract.
            if let titlebar = windowScene.titlebar {
                titlebar.titleVisibility = .hidden
                titlebar.toolbar = nil
                titlebar.separatorStyle = .none
            }

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
                          probe.window === window,
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
                        sourceDisplayScale: window.screen.scale
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
                            sourceDisplayScale: window.screen.scale,
                            window: window,
                            evidenceRootURL: evidenceRootURL
                        )
                        return
                    }
                }

                self?.fail(
                    probe: probe,
                    evidenceURL: evidenceURL,
                    selectedFrame: selectedFrame,
                    reason: "geometry did not stabilize at exactly 1280x800 points"
                )
            }
        }

        func cancel() {
            geometryTask?.cancel()
            geometryTask = nil
            captureTask?.cancel()
            captureTask = nil
        }

        private func markReady(
            probe: ProbeView,
            evidenceURL: URL,
            selectedFrame: ScreenshotAutomation.Frame,
            systemFrame: CGRect,
            sourceDisplayScale: CGFloat,
            window: UIWindow,
            evidenceRootURL: URL
        ) {
            guard !geometryFinished else { return }
            do {
                try writeGeometryEvidence(
                    status: "ready",
                    reason: nil,
                    evidenceURL: evidenceURL,
                    selectedFrame: selectedFrame,
                    systemFrame: systemFrame,
                    sourceDisplayScale: sourceDisplayScale
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
            geometryFinished = true
            geometryTask = nil
            probe.isAccessibilityElement = true
            probe.accessibilityIdentifier = ScreenshotAutomation.macCaptureReadyAccessibilityIdentifier
            probe.accessibilityLabel = "QuakeSignal Catalyst screenshot geometry ready"
            probe.accessibilityValue = "\(Int(systemFrame.width)) by \(Int(systemFrame.height)) points"
            print("CATALYST_SCREENSHOT_GEOMETRY_READY frame=\(systemFrame) sourceDisplayScale=\(sourceDisplayScale)")
            startCaptureRequestPolling(
                window: window,
                probe: probe,
                selectedFrame: selectedFrame,
                stableSystemFrame: systemFrame,
                evidenceRootURL: evidenceRootURL
            )
        }

        private func fail(
            probe: ProbeView?,
            evidenceURL: URL,
            selectedFrame: ScreenshotAutomation.Frame,
            reason: String
        ) {
            guard !geometryFinished else { return }
            geometryFinished = true
            geometryTask?.cancel()
            geometryTask = nil
            try? writeGeometryEvidence(
                status: "failed",
                reason: reason,
                evidenceURL: evidenceURL,
                selectedFrame: selectedFrame,
                systemFrame: attachedWindow?.windowScene?.effectiveGeometry.systemFrame ?? .zero,
                sourceDisplayScale: attachedWindow?.screen.scale ?? 0
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
            sourceDisplayScale: CGFloat
        ) throws {
            let record: [String: Any] = [
                "schemaVersion": 1,
                "status": status,
                "reason": reason.map { $0 as Any } ?? NSNull(),
                "processId": ProcessInfo.processInfo.processIdentifier,
                "captureSelector": selectedFrame.rawValue,
                "logicalFrame": [
                    "x": systemFrame.minX,
                    "y": systemFrame.minY,
                    "width": systemFrame.width,
                    "height": systemFrame.height,
                ],
                "sourceDisplayScale": sourceDisplayScale,
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

        private func startCaptureRequestPolling(
            window: UIWindow,
            probe: ProbeView,
            selectedFrame: ScreenshotAutomation.Frame,
            stableSystemFrame: CGRect,
            evidenceRootURL: URL
        ) {
            let requestURL = evidenceRootURL.appendingPathComponent("capture-request.json")
            let responseURL = evidenceRootURL.appendingPathComponent("capture-response.json")
            let rawURL = evidenceRootURL.appendingPathComponent("capture-raw.png")
            guard captureTask == nil,
                  !captureFinished,
                  !FileManager.default.fileExists(atPath: responseURL.path),
                  !FileManager.default.fileExists(atPath: rawURL.path) else {
                return
            }

            captureTask = Task { @MainActor [weak self, weak window, weak probe] in
                // The host writes its PID/window/selector/nonce-bound request
                // after route settling and its first Core Graphics observation.
                for _ in 0..<900 {
                    guard !Task.isCancelled else { return }
                    guard let self,
                          let window,
                          let probe,
                          self.attachedWindow === window,
                          probe.window === window else {
                        return
                    }
                    if FileManager.default.fileExists(atPath: requestURL.path) {
                        do {
                            let request = try self.readCaptureRequest(
                                at: requestURL,
                                selectedFrame: selectedFrame
                            )
                            try self.captureHierarchy(
                                request: request,
                                requestURL: requestURL,
                                responseURL: responseURL,
                                rawURL: rawURL,
                                window: window,
                                probe: probe,
                                selectedFrame: selectedFrame,
                                stableSystemFrame: stableSystemFrame
                            )
                            self.captureFinished = true
                            self.captureTask = nil
                            probe.accessibilityValue = "Direct 2560 by 1600 hierarchy render captured"
                            print("CATALYST_SCREENSHOT_HIERARCHY_CAPTURED selector=\(selectedFrame.rawValue) nonce=\(request.nonce)")
                        } catch {
                            self.captureFinished = true
                            self.captureTask = nil
                            try? self.writeCaptureFailure(
                                responseURL: responseURL,
                                selectedFrame: selectedFrame,
                                reason: error.localizedDescription
                            )
                            probe.accessibilityIdentifier = ScreenshotAutomation.macCaptureFailedAccessibilityIdentifier
                            probe.accessibilityValue = error.localizedDescription
                            print("CATALYST_SCREENSHOT_HIERARCHY_FAILED \(error.localizedDescription)")
                        }
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }

                guard let self, let probe else { return }
                self.captureFinished = true
                self.captureTask = nil
                probe.accessibilityIdentifier = ScreenshotAutomation.macCaptureFailedAccessibilityIdentifier
                probe.accessibilityValue = "Timed out waiting for the hierarchy-capture request"
                print("CATALYST_SCREENSHOT_HIERARCHY_FAILED timed out waiting for request")
            }
        }

        private struct CaptureRequest {
            let processId: Int
            let windowId: Int
            let captureSelector: String
            let nonce: String
            let logicalViewPoints: [Int]
            let rasterizationScale: Int
        }

        private enum CaptureError: LocalizedError {
            case invalidRequest(String)
            case unsafeWindow(String)
            case renderFailed(String)

            var errorDescription: String? {
                switch self {
                case let .invalidRequest(reason): "invalid capture request: \(reason)"
                case let .unsafeWindow(reason): "unsafe capture window: \(reason)"
                case let .renderFailed(reason): "hierarchy render failed: \(reason)"
                }
            }
        }

        private func readCaptureRequest(
            at requestURL: URL,
            selectedFrame: ScreenshotAutomation.Frame
        ) throws -> CaptureRequest {
            guard let values = try? requestURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            ),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let data = try? Data(contentsOf: requestURL),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let record = object as? [String: Any] else {
                throw CaptureError.invalidRequest("file is missing, indirect, or invalid JSON")
            }
            let expectedKeys: Set<String> = [
                "captureSelector", "logicalViewPoints", "nonce", "processId",
                "rasterizationScale", "schemaVersion", "windowId",
            ]
            guard Set(record.keys) == expectedKeys,
                  (record["schemaVersion"] as? NSNumber)?.intValue == 1,
                  let processId = (record["processId"] as? NSNumber)?.intValue,
                  processId == Int(ProcessInfo.processInfo.processIdentifier),
                  let windowId = (record["windowId"] as? NSNumber)?.intValue,
                  windowId > 0,
                  let captureSelector = record["captureSelector"] as? String,
                  captureSelector == selectedFrame.rawValue,
                  let nonce = record["nonce"] as? String,
                  nonce.count == 64,
                  nonce.allSatisfy({ "0123456789abcdef".contains($0) }),
                  let logicalNumbers = record["logicalViewPoints"] as? [NSNumber],
                  logicalNumbers.map(\.intValue) == [1_280, 800],
                  let rasterizationScale = (record["rasterizationScale"] as? NSNumber)?.intValue,
                  rasterizationScale == Int(ScreenshotAutomation.macCaptureRasterizationScale) else {
                throw CaptureError.invalidRequest("schema, PID, window, selector, nonce, or render geometry differs")
            }
            return CaptureRequest(
                processId: processId,
                windowId: windowId,
                captureSelector: captureSelector,
                nonce: nonce,
                logicalViewPoints: logicalNumbers.map(\.intValue),
                rasterizationScale: rasterizationScale
            )
        }

        private func captureHierarchy(
            request: CaptureRequest,
            requestURL: URL,
            responseURL: URL,
            rawURL: URL,
            window: UIWindow,
            probe: ProbeView,
            selectedFrame: ScreenshotAutomation.Frame,
            stableSystemFrame: CGRect
        ) throws {
            guard attachedWindow === window,
                  probe.window === window,
                  let scene = window.windowScene,
                  scene.activationState == .foregroundActive,
                  window.isKeyWindow,
                  !window.isHidden,
                  window.alpha.isFinite,
                  window.alpha >= 0.999 else {
                throw CaptureError.unsafeWindow("window is not attached, visible, key, opaque, and foreground-active")
            }

            window.layoutIfNeeded()
            let boundsBefore = window.bounds
            let systemFrameBefore = scene.effectiveGeometry.systemFrame
            let sourceDisplayScale = window.screen.scale
            var geometryFailures: [String] = []
            if !exactCaptureBounds(boundsBefore) { geometryFailures.append("logical bounds") }
            if !exactSystemFrame(systemFrameBefore) { geometryFailures.append("system frame size") }
            if !approximatelyEqual(systemFrameBefore, stableSystemFrame) { geometryFailures.append("stable system frame") }
            if !sourceDisplayScale.isFinite || !(0.5...4).contains(sourceDisplayScale) {
                geometryFailures.append("source-display scale")
            }
            if !geometryFailures.isEmpty {
                throw CaptureError.unsafeWindow(
                    "\(geometryFailures.joined(separator: ", ")) " +
                        "bounds=\(boundsBefore.integral) frame=\(window.frame.integral) " +
                        "system=\(systemFrameBefore.integral) stable=\(stableSystemFrame.integral) " +
                        "scale=\(sourceDisplayScale)"
                )
            }

            let format = UIGraphicsImageRendererFormat()
            format.scale = ScreenshotAutomation.macCaptureRasterizationScale
            format.opaque = false
            format.preferredRange = .standard
            let renderer = UIGraphicsImageRenderer(bounds: boundsBefore, format: format)
            var drawHierarchyComplete = false
            let pngData = renderer.pngData { _ in
                drawHierarchyComplete = window.drawHierarchy(
                    in: boundsBefore,
                    afterScreenUpdates: true
                )
            }

            let boundsAfter = window.bounds
            let systemFrameAfter = scene.effectiveGeometry.systemFrame
            let sourceDisplayScaleAfter = window.screen.scale
            guard drawHierarchyComplete else {
                throw CaptureError.renderFailed("UIView.drawHierarchy returned false")
            }
            guard exactCaptureBounds(boundsAfter),
                  exactSystemFrame(systemFrameAfter),
                  approximatelyEqual(boundsBefore, boundsAfter),
                  approximatelyEqual(systemFrameBefore, systemFrameAfter),
                  probe.window === window,
                  window.windowScene === scene,
                  scene.activationState == .foregroundActive,
                  window.isKeyWindow,
                  !window.isHidden,
                  window.alpha.isFinite,
                  window.alpha >= 0.999,
                  sourceDisplayScaleAfter.isFinite,
                  abs(sourceDisplayScaleAfter - sourceDisplayScale) <= 0.01 else {
                throw CaptureError.renderFailed("window visibility or geometry drifted across capture")
            }
            guard let cgImage = UIImage(data: pngData)?.cgImage,
                  cgImage.width == 2_560,
                  cgImage.height == 1_600 else {
                throw CaptureError.renderFailed("renderer did not produce exact 2560x1600 PNG pixels")
            }
            guard !FileManager.default.fileExists(atPath: rawURL.path),
                  !FileManager.default.fileExists(atPath: responseURL.path) else {
                throw CaptureError.renderFailed("capture output already exists")
            }

            // Re-read the host request after drawing so replacement or
            // mutation cannot publish bytes bound to a different handshake.
            let rebound = try readCaptureRequest(
                at: requestURL,
                selectedFrame: selectedFrame
            )
            guard rebound.processId == request.processId,
                  rebound.windowId == request.windowId,
                  rebound.captureSelector == request.captureSelector,
                  rebound.nonce == request.nonce,
                  rebound.logicalViewPoints == request.logicalViewPoints,
                  rebound.rasterizationScale == request.rasterizationScale else {
                throw CaptureError.invalidRequest("request changed across capture")
            }

            let rawSha256 = SHA256.hash(data: pngData).map { String(format: "%02x", $0) }.joined()
            try writeAtomically(pngData, to: rawURL)
            let response: [String: Any] = [
                "schemaVersion": 1,
                "status": "captured",
                "reason": NSNull(),
                "captureApi": "UIKit.UIView.drawHierarchy",
                "captureSurface": "live-catalyst-uiwindow-hierarchy",
                "processId": request.processId,
                "windowId": request.windowId,
                "captureSelector": request.captureSelector,
                "nonce": request.nonce,
                "sourceDisplayScale": sourceDisplayScale,
                "rasterizationScale": request.rasterizationScale,
                "logicalViewPoints": request.logicalViewPoints,
                "pixels": [2_560, 1_600],
                "afterScreenUpdates": true,
                "drawHierarchyComplete": true,
                "postCaptureResizePerformed": false,
                "rendererOpaque": false,
                "rendererPreferredRange": "standard",
                "windowBounds": rectRecord(boundsBefore),
                "systemFrameBefore": rectRecord(systemFrameBefore),
                "systemFrameAfter": rectRecord(systemFrameAfter),
                "windowIsKey": window.isKeyWindow,
                "windowIsHidden": window.isHidden,
                "windowAlpha": window.alpha,
                "sceneActivationState": "foregroundActive",
                "rawOutputFile": rawURL.lastPathComponent,
                "rawSha256": rawSha256,
                "capturedAtUtc": ISO8601DateFormatter().string(from: Date()),
            ]
            let responseData = try JSONSerialization.data(
                withJSONObject: response,
                options: [.prettyPrinted, .sortedKeys]
            )
            try writeAtomically(responseData, to: responseURL)
        }

        private func writeCaptureFailure(
            responseURL: URL,
            selectedFrame: ScreenshotAutomation.Frame,
            reason: String
        ) throws {
            guard !FileManager.default.fileExists(atPath: responseURL.path) else { return }
            let record: [String: Any] = [
                "schemaVersion": 1,
                "status": "failed",
                "reason": reason,
                "processId": ProcessInfo.processInfo.processIdentifier,
                "captureSelector": selectedFrame.rawValue,
                "recordedAtUtc": ISO8601DateFormatter().string(from: Date()),
            ]
            let data = try JSONSerialization.data(
                withJSONObject: record,
                options: [.prettyPrinted, .sortedKeys]
            )
            try writeAtomically(data, to: responseURL)
        }

        private func writeAtomically(_ data: Data, to destinationURL: URL) throws {
            let temporaryURL = destinationURL.deletingLastPathComponent().appendingPathComponent(
                ".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp"
            )
            try data.write(to: temporaryURL, options: .withoutOverwriting)
            do {
                try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
            } catch {
                try? FileManager.default.removeItem(at: temporaryURL)
                throw error
            }
        }

        private func exactCaptureBounds(_ rect: CGRect) -> Bool {
            abs(rect.minX) <= 0.01 &&
                abs(rect.minY) <= 0.01 &&
                abs(rect.width - ScreenshotAutomation.macCaptureLogicalSize.width) <= 0.01 &&
                abs(rect.height - ScreenshotAutomation.macCaptureLogicalSize.height) <= 0.01
        }

        private func exactSystemFrame(_ rect: CGRect) -> Bool {
            rect.minX.isFinite &&
                rect.minY.isFinite &&
                abs(rect.width - ScreenshotAutomation.macCaptureLogicalSize.width) <= 0.25 &&
                abs(rect.height - ScreenshotAutomation.macCaptureLogicalSize.height) <= 0.25
        }

        private func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
            abs(lhs.minX - rhs.minX) <= 0.25 &&
                abs(lhs.minY - rhs.minY) <= 0.25 &&
                abs(lhs.width - rhs.width) <= 0.25 &&
                abs(lhs.height - rhs.height) <= 0.25
        }

        private func rectRecord(_ rect: CGRect) -> [String: CGFloat] {
            [
                "x": rect.minX,
                "y": rect.minY,
                "width": rect.width,
                "height": rect.height,
            ]
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
