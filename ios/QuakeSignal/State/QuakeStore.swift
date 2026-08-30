import Foundation
import CoreLocation

/// Selects the ordinary earthquake report shown on Home without changing the
/// distance ordering used by the nearby-event list. Reports with unusable or
/// implausibly future timestamps are ignored so malformed feed data cannot
/// displace a valid earthquake.
enum HomeReportSelectionPolicy {
    static let maximumRecentAge: TimeInterval = 24 * 60 * 60
    static let allowedFutureSkew = WarningFreshnessPolicy.allowedFutureSkew

    static func newestReport(
        from events: [EEWEvent],
        now: Date,
        maximumAge: TimeInterval? = nil
    ) -> EEWEvent? {
        events.compactMap { event -> (event: EEWEvent, timestamp: Date)? in
            guard event.kind == "report",
                  let timestamp = event.reportDate ?? event.originDate else {
                return nil
            }
            let age = now.timeIntervalSince(timestamp)
            guard age >= -allowedFutureSkew else { return nil }
            if let maximumAge, age > maximumAge { return nil }
            return (event, timestamp)
        }
        .sorted { left, right in
            if left.timestamp != right.timestamp {
                return left.timestamp > right.timestamp
            }
            if left.event.id != right.event.id {
                return left.event.id < right.event.id
            }
            return left.event.serial > right.event.serial
        }
        .first?.event
    }
}

struct PresentedAlert: Identifiable, Equatable {
    let event: EEWEvent
    let reason: AlertPresentationReason
    let mode: PresentedEventMode

    init(
        event: EEWEvent,
        reason: AlertPresentationReason,
        mode: PresentedEventMode = .emergency
    ) {
        self.event = event
        self.reason = reason
        self.mode = mode
    }

    var id: String { "\(event.id)#\(reason.rawValue)#\(mode.rawValue)#\(event.serial)" }
}

/// Keeps an already-presented warning synchronized with accepted lifecycle
/// frames without allowing an unrelated event to dismiss it. Terminal frames
/// close the warning, fresh revisions update its details, and the foreground
/// clock closes an active warning once its safety window has elapsed.
enum PresentedAlertLifecyclePolicy {
    static func afterAcceptedMerge(
        _ incoming: EEWEvent,
        current: PresentedAlert?,
        now: Date
    ) -> PresentedAlert? {
        guard let current, current.event.id == incoming.id else { return current }

        if current.mode == .detail {
            return PresentedAlert(event: incoming, reason: current.reason, mode: .detail)
        }

        if current.event.isActiveWarning {
            guard incoming.isActiveWarning,
                  WarningFreshnessPolicy.isFresh(incoming, now: now) else {
                return nil
            }
        }

        return PresentedAlert(event: incoming, reason: current.reason, mode: current.mode)
    }

    static func afterClockTick(_ current: PresentedAlert?, now: Date) -> PresentedAlert? {
        guard let current,
              current.mode == .emergency,
              current.event.isActiveWarning,
              !WarningFreshnessPolicy.isFresh(current.event, now: now) else {
            return current
        }
        return nil
    }
}

/// Couples the lifetime of app-owned warning audio to the emergency surface.
/// A dismissal, terminal revision, expiry, or replacement must stop the old
/// voice immediately; an identical assignment must not interrupt playback.
enum PresentedAlertAudioPolicy {
    static func shouldStop(previous: PresentedAlert?, next: PresentedAlert?) -> Bool {
        previous?.mode == .emergency && previous != next
    }
}

enum PushRegistrationPreparationError: LocalizedError {
    case locationRequired

    var errorDescription: String? {
        switch self {
        case .locationRequired:
            String(localized: "settings.pushSubscription.locationRequired")
        }
    }
}

enum MissingLocationRegistrationPolicy {
    static func shouldDeleteServerRegistration(
        registrationState: PushRegistrationState,
        locationRequestInFlight: Bool
    ) -> Bool {
        (registrationState == .active || registrationState == .failed) &&
            !locationRequestInFlight
    }
}

@Observable
@MainActor
final class QuakeStore {
    static let shared = QuakeStore()

    private(set) var events: [EEWEvent] = []
    private(set) var isLoading = false
    private(set) var loadError: String?
    var presentedAlert: PresentedAlert? {
        didSet {
            if PresentedAlertAudioPolicy.shouldStop(previous: oldValue, next: presentedAlert) {
                EmergencyAlertAudio.shared.stop()
            }
        }
    }

    private let liveSocket = LiveSocketClient()
    private let api = APIClient.shared
    private let wolfx = WolfxClient.shared
    private let pushRegistrationSerialiser = PushRegistrationSerialiser()
    private var revisionsByEvent: [String: [EventRevision]] = [:]
    private var isForegroundActive = true
    private var hasStarted = false
    private var foregroundHTTPFallbackTask: Task<Void, Never>?
    private var expirationClockTask: Task<Void, Never>?
    private var activeRefreshTask: Task<WolfxSnapshotFetchResult, Error>?
    private var foregroundResumeTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var clockNow = Date()
    private var alertedRevisionKeys: Set<ForegroundEmergencyRevisionKey> = []
    private var systemPresentationReservations: [ForegroundEmergencyRevisionKey: Date] = [:]
    private let screenshotAutomationEnabled: Bool

    var isConnected: Bool { liveSocket.isConnected }

    private init() {
        screenshotAutomationEnabled = ScreenshotAutomation.isEnabled
        if screenshotAutomationEnabled {
            events = ScreenshotAutomation.finalizedHistoricalEvents
        }
        liveSocket.onEvents = { [weak self] events, isBackfill in
            for event in events {
                self?.ingestDirect(event: event, isBackfill: isBackfill)
            }
        }
        liveSocket.onConnectionStateChanged = { [weak self] _ in
            self?.updateForegroundHTTPFallback()
        }
    }

    func start() async {
        guard !screenshotAutomationEnabled else { return }
        let actions = DirectMonitoringLifecyclePolicy.actionsForStart(
            hasStarted: hasStarted,
            isForegroundActive: isForegroundActive
        )
        guard !actions.isEmpty else { return }
        hasStarted = true

        for action in actions where action != .refreshSnapshot {
            performDirectMonitoringAction(action)
        }
        if actions.contains(.refreshSnapshot) {
            await refresh()
        }
    }

    /// Owns the complete direct-Wolfx lifecycle. All targets suspend sockets,
    /// in-flight HTTP refreshes, and app-owned alert audio outside an active
    /// scene. iPhone/iPad background warnings remain an APNs responsibility;
    /// relay-disabled targets therefore have no hidden background data path.
    func setForegroundActive(_ isActive: Bool) {
        let wasActive = isForegroundActive
        isForegroundActive = isActive
        if isActive {
            // Scene activation and notification callbacks can arrive before
            // the periodic clock task gets its first turn. Refresh
            // synchronously so a warm-background tap cannot classify a stale
            // warning using the time from before the app was suspended.
            clockNow = Date()
            presentedAlert = PresentedAlertLifecyclePolicy.afterClockTick(
                presentedAlert,
                now: clockNow
            )
        }
        guard !screenshotAutomationEnabled else {
            for action in DirectMonitoringLifecyclePolicy.suspensionActions {
                performDirectMonitoringAction(action)
            }
            return
        }

        let actions = DirectMonitoringLifecyclePolicy.actionsForSceneTransition(
            hasStarted: hasStarted,
            wasForegroundActive: wasActive,
            isForegroundActive: isForegroundActive
        )
        for action in actions {
            if action == .refreshSnapshot {
                foregroundResumeTask?.cancel()
                foregroundResumeTask = Task { @MainActor [weak self] in
                    await self?.refresh()
                }
            } else {
                performDirectMonitoringAction(action)
            }
        }
    }

    /// A snapshotless push cannot be resolved before `willPresent` returns, so
    /// APNs keeps its banner and sound. Reserve the validated revision boundary
    /// synchronously so a racing newer direct revision remains app-owned while
    /// an exact or monotonically older active copy remains system-owned.
    func reserveSystemPresentation(
        for revisionKey: ForegroundEmergencyRevisionKey,
        receivedAt: Date
    ) {
        ForegroundSystemPresentationReservationPolicy.reserve(
            revisionKey: revisionKey,
            receivedAt: receivedAt,
            now: Date(),
            reservations: &systemPresentationReservations
        )
    }

    func refresh() async {
        guard !screenshotAutomationEnabled,
              DirectMonitoringLifecyclePolicy.shouldAcceptDirectEvent(
                  isForegroundActive: isForegroundActive
              ) else { return }
        // The upstream feeds are independent. One malformed or temporarily
        // unavailable source must not hide validated reports from every
        // healthy source. The partial path still fails closed when all
        // sources fail and keeps a concise degradation message for the UI.
        await refresh(allowingPartialResults: true)
    }

    private func refresh(allowingPartialResults: Bool) async {
        guard DirectMonitoringLifecyclePolicy.shouldAcceptDirectEvent(
            isForegroundActive: isForegroundActive
        ) else { return }

        refreshGeneration += 1
        let generation = refreshGeneration
        isLoading = true
        loadError = nil

        activeRefreshTask?.cancel()
        let refreshTask = Task { [wolfx] in
            if allowingPartialResults {
                return try await wolfx.fetchRecentQuakesAllowingPartialResults()
            }
            let events = try await wolfx.fetchRecentQuakes()
            return WolfxSnapshotFetchResult(
                events: events,
                failedSources: [],
                successfulSourceCount: WolfxClient.sources.count
            )
        }
        activeRefreshTask = refreshTask

        do {
            let snapshot = try await refreshTask.value
            guard generation == refreshGeneration, isForegroundActive else { return }
            guard snapshot.hasSuccessfulSources else {
                loadError = snapshot.statusDescription
                    ?? "Wolfx snapshot unavailable."
                isLoading = false
                activeRefreshTask = nil
                return
            }
            applyFetchedEvents(snapshot.events)
            // A partial fallback is useful data, not a failed refresh. The
            // existing banner exposes the concise source summary without
            // removing the refreshed event list.
            loadError = snapshot.statusDescription
        } catch is CancellationError {
            // Scene deactivation and a newer refresh both cancel obsolete
            // requests. Neither is a user-visible network failure.
        } catch {
            if generation == refreshGeneration {
                loadError = error.localizedDescription
            }
        }
        if generation == refreshGeneration {
            isLoading = false
            activeRefreshTask = nil
        }
    }

    func registerForPush(token: String) async throws {
        guard !screenshotAutomationEnabled,
              PlatformCapabilities.supportsAttestedAlertRegistration else {
            AppSettings.shared.pushRegistrationState = .unregistered
            throw PlatformCapabilityError.attestedAlertRegistrationUnavailable
        }

        await pushRegistrationSerialiser.acquire()
        defer { pushRegistrationSerialiser.release() }

        let settings = AppSettings.shared
        guard settings.pushSubscriptionEnabled else {
            settings.pushRegistrationState = .unregistered
            return
        }

        // A missing location must never become an implicit nationwide alert
        // subscription. Onboarding permits location to be skipped, and a GPS
        // fix can arrive after APNs, so keep this state retryable until either
        // the selected-city fallback or a valid coarse GPS coordinate exists.
        guard let coordinate = effectiveCoordinate.flatMap(CoarseCoordinate.init) else {
            let locationRequestInFlight = settings.useCurrentLocation &&
                LocationManager.shared.isRequestingLocation
            let shouldDelete = MissingLocationRegistrationPolicy.shouldDeleteServerRegistration(
                registrationState: settings.pushRegistrationState,
                locationRequestInFlight: locationRequestInFlight
            )
            if shouldDelete {
                do {
                    // Do not leave a previously confirmed GPS registration
                    // active at a stale coordinate after permission loss or a
                    // failed/expired renewal. Keep the person's intent enabled
                    // so a later city/fix can register again automatically.
                    try await api.deleteDevice(token: token)
                    settings.pushRegistrationState = .unregistered
                } catch {
                    settings.pushRegistrationState = .failed
                    throw error
                }
            } else if !locationRequestInFlight {
                settings.pushRegistrationState = .unregistered
            }
            throw PushRegistrationPreparationError.locationRequired
        }

        // This is intentionally set before building/sending the request. The
        // status only moves to `.active` below after the server accepts the
        // protected registration, so an optimistic UI state can never claim
        // that background alerts are configured when they are not.
        settings.pushRegistrationState = .registering
        let request = DeviceRegistrationRequest(
            token: token,
            environment: AppEnvironment.isDebugBuild ? "sandbox" : "production",
            locale: Locale.current.identifier,
            sources: Array(settings.enabledSources),
            minMagnitude: settings.minMagnitude,
            cityName: settings.selectedCity?.localizedName,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            radiusKm: settings.radiusKm,
            includeTestAlerts: settings.includeTestAlerts,
            utcOffsetMinutes: TimeZone.current.secondsFromGMT() / 60,
            notifyAtNight: settings.notifyAtNight,
            alertSound: settings.alertSound
        )
        do {
            try await api.registerDevice(request)
            // A removal may have completed while this request was in flight.
            // In that case do not resurrect an active status from a stale
            // response; the removal path remains authoritative.
            settings.pushRegistrationState = settings.pushSubscriptionEnabled ? .active : .unregistered
        } catch {
            if settings.pushSubscriptionEnabled {
                settings.pushRegistrationState = .failed
            }
            throw error
        }
    }

    /// Removes this device from QuakeSignal's server-side alert service. This
    /// does not modify the notification permission managed by iOS. A missing
    /// token asks the Worker to delete by the authenticated App Attest key,
    /// which supports removal before APNs has returned a token this launch
    /// when that key already protects the registration.
    func unregisterForPush(token: String?) async throws {
        guard !screenshotAutomationEnabled,
              PlatformCapabilities.supportsAttestedAlertRegistration else {
            throw PlatformCapabilityError.attestedAlertRegistrationUnavailable
        }

        await pushRegistrationSerialiser.acquire()
        defer { pushRegistrationSerialiser.release() }

        try await api.deleteDevice(token: token)
        AppSettings.shared.pushSubscriptionEnabled = false
        AppSettings.shared.pushRegistrationState = .unregistered
    }

    /// Presents a notification the person explicitly tapped. The event still
    /// merges monotonically. A fresh active warning may reopen the emergency
    /// cover; every historical or terminal frame opens ordinary details so a
    /// stale tap cannot issue imperative safety instructions.
    func ingestTapped(event: EEWEvent, reason: AlertPresentationReason) {
        let now = Date()
        clockNow = now
        merge(event)
        let displayedEvent = events.first(where: { $0.id == event.id }) ?? event
        presentedAlert = PresentedAlert(
            event: displayedEvent,
            reason: reason,
            mode: NotificationTapPresentationPolicy.mode(for: displayedEvent, now: now)
        )
    }

    /// Applies a real push received while the app is foreground. It shares the
    /// same merge and preference policy as direct WebSocket delivery, which
    /// prevents duplicate full-screen UI and duplicate sound. The return value
    /// confirms that this revision was already handled, is an older active
    /// revision superseded by one already handled, or was presented now. That
    /// lets NotificationManager yield the APNs banner atomically.
    @discardableResult
    func ingestForegroundNotification(
        event: EEWEvent,
        reason requestedReason: AlertPresentationReason,
        allowsEmergencyPresentation: Bool
    ) -> Bool {
        let now = Date()
        clockNow = now
        let previous = events.first(where: { $0.id == event.id })
        let systemOwnsPresentation = consumeSystemPresentationReservation(
            for: event,
            now: now
        )
        let canOwnEmergencyPresentation = allowsEmergencyPresentation &&
            DirectMonitoringLifecyclePolicy.shouldPresentForegroundEmergency(
                isForegroundActive: isForegroundActive
            )
        let wasAlreadyHandledInApp = ForegroundEmergencyRevisionOwnershipPolicy.wasAlreadyHandled(
            event: event,
            handledRevisionKeys: alertedRevisionKeys,
            allowsEmergencyPresentation: canOwnEmergencyPresentation
        )
        let decision = ForegroundPushPolicy.ingestionDecision(
            for: event,
            previous: previous,
            requestedReason: requestedReason,
            allowsEmergencyPresentation: canOwnEmergencyPresentation,
            preferences: alertPreferenceSnapshot,
            now: now
        )
        guard decision.shouldMerge else {
            if !systemOwnsPresentation {
                recordSystemPresentationOwnership(for: event)
            }
            return systemOwnsPresentation || wasAlreadyHandledInApp
        }
        merge(event)
        // APNs already owns the visible banner/sound for a snapshotless
        // delivery. Keep that ownership in the revision set so the
        // later resolved snapshot (and any duplicate copy) cannot present a
        // second emergency surface after the one-shot reservation is consumed.
        guard !systemOwnsPresentation else { return true }
        guard let reason = decision.presentationReason else {
            recordSystemPresentationOwnership(for: event)
            return wasAlreadyHandledInApp
        }
        let mergedEvent = events.first(where: { $0.id == event.id }) ?? event
        let didPresent = presentEmergencyIfNeeded(event: mergedEvent, reason: reason)
        if !didPresent {
            recordSystemPresentationOwnership(for: event)
        }
        return didPresent
    }

    private func merge(_ event: EEWEvent) {
        let previous = events.first(where: { $0.id == event.id })
        guard EventMergePolicy.shouldAccept(event, replacing: previous) else { return }
        recordRevision(for: event)
        if let index = events.firstIndex(where: { $0.id == event.id }) {
            events[index] = event
        } else {
            events.insert(event, at: 0)
        }
        sortAndLimitEvents()
        presentedAlert = PresentedAlertLifecyclePolicy.afterAcceptedMerge(
            event,
            current: presentedAlert,
            now: clockNow
        )
    }

    func revisions(for eventID: String) -> [EventRevision] {
        revisionsByEvent[eventID] ?? []
    }

    private func ingestDirect(event: EEWEvent, isBackfill: Bool) {
        guard DirectMonitoringLifecyclePolicy.shouldAcceptDirectEvent(
            isForegroundActive: isForegroundActive
        ) else { return }

        let systemOwnsPresentation = consumeSystemPresentationReservation(
            for: event,
            now: Date()
        )
        let previous = events.first(where: { $0.id == event.id })
        guard EventMergePolicy.shouldAccept(event, replacing: previous) else { return }
        let reason = ForegroundAlertPolicy.presentationReason(
            for: event,
            previous: previous,
            isBackfill: isBackfill,
            preferences: alertPreferenceSnapshot,
            now: clockNow
        )

        merge(event)

        if let reason, !systemOwnsPresentation {
            presentEmergencyIfNeeded(event: event, reason: reason)
        }
    }

    private func consumeSystemPresentationReservation(
        for event: EEWEvent,
        now: Date
    ) -> Bool {
        let revisionKey = ForegroundEmergencyRevisionOwnershipPolicy.key(for: event)
        let consumed = ForegroundSystemPresentationReservationPolicy.consume(
            revisionKey: revisionKey,
            now: now,
            reservations: &systemPresentationReservations
        )
        if consumed {
            recordSystemPresentationOwnership(for: event)
        }
        return consumed
    }

    private func recordSystemPresentationOwnership(for event: EEWEvent) {
        alertedRevisionKeys.insert(
            ForegroundEmergencyRevisionOwnershipPolicy.key(for: event)
        )
    }

    @discardableResult
    private func presentEmergencyIfNeeded(
        event: EEWEvent,
        reason: AlertPresentationReason
    ) -> Bool {
        guard DirectMonitoringLifecyclePolicy.shouldPresentForegroundEmergency(
            isForegroundActive: isForegroundActive
        ) else { return false }

        let key = ForegroundEmergencyRevisionOwnershipPolicy.key(for: event)
        guard alertedRevisionKeys.insert(key).inserted else { return true }
        presentedAlert = PresentedAlert(event: event, reason: reason)
        EmergencyAlertAudio.shared.playSelectedSound(for: event, reason: reason)
        return true
    }

    private func performDirectMonitoringAction(_ action: DirectMonitoringLifecycleAction) {
        switch action {
        case .startSocket:
            liveSocket.start()
        case .stopSocket:
            liveSocket.stop()
        case .cancelRefreshes:
            refreshGeneration += 1
            activeRefreshTask?.cancel()
            activeRefreshTask = nil
            foregroundResumeTask?.cancel()
            foregroundResumeTask = nil
            isLoading = false
        case .refreshSnapshot:
            // The async callers own this action so startup can await its first
            // snapshot and a scene transition can retain a cancellable task.
            assertionFailure("refreshSnapshot must be performed by the async caller")
        case .startForegroundMaintenance:
            updateForegroundHTTPFallback()
            updateExpirationClock()
        case .stopForegroundMaintenance:
            foregroundHTTPFallbackTask?.cancel()
            foregroundHTTPFallbackTask = nil
            expirationClockTask?.cancel()
            expirationClockTask = nil
        case .stopAlertAudio:
            EmergencyAlertAudio.shared.stop()
        }
    }

    private func recordRevision(for event: EEWEvent) {
        let revision = EventRevision(
            eventRef: event.id,
            serial: event.serial,
            magnitude: event.magnitude,
            maxIntensity: event.maxIntensity,
            isWarn: event.isWarn,
            isFinal: event.isFinal,
            isCancel: event.isCancel,
            reportTimeUtc: event.reportTimeUtc,
            recordedAtUtc: ISO8601DateFormatter().string(from: Date())
        )
        var revisions = revisionsByEvent[event.id] ?? []
        if let last = revisions.last,
           last.serial == revision.serial,
           last.magnitude == revision.magnitude,
           last.maxIntensity == revision.maxIntensity,
           last.isWarn == revision.isWarn,
           last.isFinal == revision.isFinal,
           last.isCancel == revision.isCancel,
           last.reportTimeUtc == revision.reportTimeUtc {
            return
        }
        revisions.append(revision)
        revisionsByEvent[event.id] = revisions
    }

    private func updateForegroundHTTPFallback() {
        let shouldRun = ForegroundHTTPFallbackPolicy.nextDelaySeconds(
            isForegroundActive: isForegroundActive,
            socketsConnected: liveSocket.isConnected,
            hasCompletedFallbackRefresh: false
        ) != nil

        guard shouldRun else {
            foregroundHTTPFallbackTask?.cancel()
            foregroundHTTPFallbackTask = nil
            return
        }

        guard foregroundHTTPFallbackTask == nil else { return }
        foregroundHTTPFallbackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var hasCompletedFallbackRefresh = false

            while !Task.isCancelled {
                guard let delaySeconds = ForegroundHTTPFallbackPolicy.nextDelaySeconds(
                    isForegroundActive: self.isForegroundActive,
                    socketsConnected: self.liveSocket.isConnected,
                    hasCompletedFallbackRefresh: hasCompletedFallbackRefresh
                ) else {
                    return
                }

                do {
                    try await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
                } catch is CancellationError {
                    return
                } catch {
                    return
                }

                guard self.isForegroundActive, !self.liveSocket.isConnected else {
                    return
                }

                // Reuse the regular HTTP snapshot path rather than creating a
                // second parser or an alert path. A socket recovery cancels
                // this task before its next refresh.
                await self.refresh(allowingPartialResults: true)
                hasCompletedFallbackRefresh = true
            }
        }
    }

    private func applyFetchedEvents(_ fetchedEvents: [EEWEvent]) {
        var newestByID = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
        for event in fetchedEvents {
            _ = consumeSystemPresentationReservation(for: event, now: Date())
            if let current = newestByID[event.id],
               !EventMergePolicy.shouldAccept(event, replacing: current) {
                continue
            }
            newestByID[event.id] = event
            presentedAlert = PresentedAlertLifecyclePolicy.afterAcceptedMerge(
                event,
                current: presentedAlert,
                now: clockNow
            )
        }
        events = Array(newestByID.values)
        sortAndLimitEvents()
        for event in events {
            recordRevision(for: event)
        }
    }

    private func sortAndLimitEvents() {
        events.sort {
            ($0.reportTimeUtc ?? $0.originTimeUtc ?? "") >
            ($1.reportTimeUtc ?? $1.originTimeUtc ?? "")
        }
        if events.count > 50 {
            events.removeLast(events.count - 50)
        }
    }

    private var alertPreferenceSnapshot: AlertPreferenceSnapshot {
        let settings = AppSettings.shared
        return AlertPreferenceSnapshot(
            // On Catalyst (and an iOS app running on Apple silicon), push
            // registration is unavailable and its control is intentionally
            // hidden. Do not let a migrated push opt-out also strand the
            // foreground-only warning experience in a permanently disabled
            // state.
            subscriptionEnabled: PlatformCapabilities.supportsAttestedAlertRegistration
                ? settings.pushSubscriptionEnabled
                : true,
            enabledSources: settings.enabledSources,
            minimumMagnitude: settings.minMagnitude,
            coordinate: effectiveCoordinate,
            radiusKm: settings.radiusKm,
            includeTraining: settings.includeTestAlerts
        )
    }

    private func updateExpirationClock() {
        guard isForegroundActive else {
            expirationClockTask?.cancel()
            expirationClockTask = nil
            return
        }
        guard expirationClockTask == nil else { return }
        expirationClockTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.clockNow = Date()
                self.presentedAlert = PresentedAlertLifecyclePolicy.afterClockTick(
                    self.presentedAlert,
                    now: self.clockNow
                )
                do {
                    try await Task.sleep(for: .seconds(15))
                } catch {
                    return
                }
            }
        }
    }

    // MARK: - Location-aware derived state (drives the Home banner)

    /// GPS location if the user opted in and it's available, else the subscribed city, else nil.
    var effectiveCoordinate: CLLocationCoordinate2D? {
        let settings = AppSettings.shared
        if settings.useCurrentLocation, let gps = LocationManager.shared.currentLocation {
            return gps
        }
        if let city = settings.selectedCity {
            return city.coordinate
        }
        // Screenshot-only Debug launches intentionally use a fresh simulator
        // with no persisted onboarding choice. Bind the seeded historical
        // Noto report to its own epicenter so the reviewed Home frame can show
        // the normal no-nearby-activity state alongside the latest report.
        if screenshotAutomationEnabled {
            return ScreenshotAutomation.finalizedHistoricalEvents.first?.coordinate
        }
        return nil
    }

    /// True when `effectiveCoordinate` came from GPS rather than a picked city -- Views use this to
    /// decide between showing the subscribed city's name and a generic "current location" label.
    var isUsingGPSLocation: Bool {
        AppSettings.shared.useCurrentLocation && LocationManager.shared.currentLocation != nil
    }

    /// Events within the configured radius of `effectiveCoordinate`, nearest first. Falls back to
    /// all events (unfiltered) when no location is set, so the app is still useful before onboarding a city.
    var nearbyEvents: [EEWEvent] {
        guard let coordinate = effectiveCoordinate else { return events }
        let radius = AppSettings.shared.radiusKm
        return events
            .compactMap { event -> (EEWEvent, Double)? in
                guard let distance = event.distanceKm(from: coordinate) else { return nil }
                return (event, distance)
            }
            .filter { $0.1 <= radius }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    var activeWarning: EEWEvent? {
        guard effectiveCoordinate != nil else { return nil }
        return nearbyEvents.first { event in
            guard event.isActiveWarning, let timestamp = event.reportDate ?? event.originDate else {
                return false
            }
            // Some upstream EEW endpoints retain their last message while idle.
            // A preliminary message is only actionable for a short window; an
            // old retained payload must never look like a current warning.
            let age = clockNow.timeIntervalSince(timestamp)
            return age >= -60 && age <= ForegroundAlertPolicy.maximumWarningAge
        }
    }

    /// The newest ordinary report in the nearby set. This is intentionally
    /// independent of `nearbyEvents`' nearest-first presentation order.
    var latestNearbyReport: EEWEvent? {
        HomeReportSelectionPolicy.newestReport(from: nearbyEvents, now: clockNow)
    }

    /// The newest ordinary report from the last 24 hours -- drives the
    /// "caution" banner state.
    var recentNearbyReport: EEWEvent? {
        guard effectiveCoordinate != nil else { return nil }
        return HomeReportSelectionPolicy.newestReport(
            from: nearbyEvents,
            now: clockNow,
            maximumAge: HomeReportSelectionPolicy.maximumRecentAge
        )
    }

    var bannerState: HomeBannerState {
        NativeStatusHeroMapping.bannerState(
            hasActiveWarning: activeWarning != nil,
            hasRecentNearbyReport: recentNearbyReport != nil
        )
    }
}

/// Serializes register and remove requests at the lifecycle layer. App Attest
/// also serializes signed requests, but that is too low-level to stop a
/// registration that was queued while a removal was in flight. By acquiring
/// this lock before checking `pushSubscriptionEnabled`, a queued registration
/// sees the successful removal and exits without recreating the subscription.
@MainActor
private final class PushRegistrationSerialiser {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard let next = waiters.first else {
            isHeld = false
            return
        }

        waiters.removeFirst()
        // Keep the lock held while ownership transfers directly to `next`.
        next.resume()
    }
}
