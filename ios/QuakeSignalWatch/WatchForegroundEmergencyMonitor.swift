import Foundation
import Observation

/// Owns Watch's foreground-only direct monitoring lifecycle. Validated
/// WebSocket snapshots are primary; a conservative, bounded HTTP loop covers a
/// sustained socket outage. Neither path runs after the scene becomes inactive.
///
/// Retained first snapshots establish state only. This monitor exposes a
/// warning surface only for a new live frame or a monotonic update to an event
/// already known during the current foreground launch.
@Observable
@MainActor
final class WatchForegroundEmergencyMonitor {
    private(set) var presentedWarning: WatchForegroundEmergencyPresentation?
    private(set) var isConnected = false

    private let socket: LiveSocketClient
    private let client: WolfxClient
    private let now: () -> Date
    private let screenshotAutomationEnabled: Bool
    private var latestByEventID: [String: EEWEvent] = [:]
    private var fallbackTask: Task<Void, Never>?
    private var expirationTask: Task<Void, Never>?
    private var isSceneActive = false

    private static let expirationTick: Duration = .seconds(15)
    private static let retainedEventLimit = 128

    init(
        socket: LiveSocketClient = LiveSocketClient(),
        client: WolfxClient = .shared,
        now: @escaping () -> Date = Date.init,
        screenshotAutomationEnabled: Bool = ScreenshotAutomation.isEnabled
    ) {
        self.socket = socket
        self.client = client
        self.now = now
        self.screenshotAutomationEnabled = screenshotAutomationEnabled
    }

    func setSceneActive(_ isActive: Bool) {
        let shouldMonitor = isActive && !screenshotAutomationEnabled
        guard isSceneActive != shouldMonitor else { return }
        isSceneActive = shouldMonitor
        if shouldMonitor {
            startForegroundMonitoring()
        } else {
            stopForegroundMonitoring()
        }
    }

    func dismissPresentedWarning() {
        presentedWarning = nil
    }

    private func startForegroundMonitoring() {
        latestByEventID.removeAll()
        presentedWarning = nil
        isConnected = false

        socket.onEvents = { [weak self] events, isBackfill in
            self?.ingest(events, isBackfill: isBackfill)
        }
        socket.onConnectionStateChanged = { [weak self] connected in
            self?.connectionStateChanged(connected)
        }
        socket.start()
        scheduleHTTPFallback()
        startExpirationClock()
    }

    private func stopForegroundMonitoring() {
        socket.onEvents = nil
        socket.onConnectionStateChanged = nil
        socket.stop()
        fallbackTask?.cancel()
        fallbackTask = nil
        expirationTask?.cancel()
        expirationTask = nil
        latestByEventID.removeAll()
        presentedWarning = nil
        isConnected = false
    }

    private func connectionStateChanged(_ connected: Bool) {
        guard isSceneActive else { return }
        isConnected = connected
        if connected {
            fallbackTask?.cancel()
            fallbackTask = nil
        } else {
            scheduleHTTPFallback()
        }
    }

    private func scheduleHTTPFallback() {
        guard isSceneActive, !socket.isConnected, fallbackTask == nil else { return }
        fallbackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var hasCompletedRefresh = false

            while !Task.isCancelled {
                guard let delaySeconds = ForegroundHTTPFallbackPolicy.nextDelaySeconds(
                    isForegroundActive: self.isSceneActive,
                    socketsConnected: self.socket.isConnected,
                    hasCompletedFallbackRefresh: hasCompletedRefresh
                ) else {
                    return
                }

                do {
                    try await Task.sleep(for: .seconds(delaySeconds))
                } catch {
                    return
                }
                guard self.isSceneActive, !self.socket.isConnected else { return }

                do {
                    let snapshot = try await self.client
                        .fetchRecentQuakesAllowingPartialResults(limit: 24)
                    guard self.isSceneActive, !self.socket.isConnected else { return }
                    if snapshot.hasSuccessfulSources {
                        // HTTP recovery is always retained state. It cannot
                        // impersonate a newly delivered foreground frame.
                        self.ingest(snapshot.events, isBackfill: true)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    // Socket reconnection and the next conservative foreground
                    // recovery turn remain available.
                }
                hasCompletedRefresh = true
            }
        }
    }

    private func startExpirationClock() {
        expirationTask?.cancel()
        expirationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.isSceneActive else { return }
                if let warning = self.presentedWarning,
                   WatchForegroundEmergencyPolicy.shouldExpire(
                       warning.event,
                       now: self.now()
                   ) {
                    self.presentedWarning = nil
                }
                do {
                    try await Task.sleep(for: Self.expirationTick)
                } catch {
                    return
                }
            }
        }
    }

    private func ingest(_ events: [EEWEvent], isBackfill: Bool) {
        guard isSceneActive else { return }
        let locallyKnownEventIDs = Set(latestByEventID.keys)

        // Process same-event revisions oldest-first so array order cannot skip
        // the monotonic lifecycle. A whole first retained batch remains
        // baseline-only, even when it contains multiple revisions.
        let orderedEvents = events.sorted { left, right in
            if left.id != right.id { return left.id < right.id }
            if left.serial != right.serial { return left.serial < right.serial }
            let leftDate = left.reportDate ?? left.originDate ?? .distantPast
            let rightDate = right.reportDate ?? right.originDate ?? .distantPast
            return leftDate < rightDate
        }

        for event in orderedEvents {
            let previous = latestByEventID[event.id]
            let action = WatchForegroundEmergencyPolicy.action(
                for: event,
                previous: previous,
                presentedEventID: presentedWarning?.event.id,
                isBackfill: isBackfill,
                hadLocalHistoryBeforeBatch: locallyKnownEventIDs.contains(event.id),
                now: now()
            )
            guard action != .ignore else { continue }

            latestByEventID[event.id] = event
            switch action {
            case .presentNew:
                presentedWarning = WatchForegroundEmergencyPresentation(
                    event: event,
                    reason: .new
                )
            case .presentUpdate:
                presentedWarning = WatchForegroundEmergencyPresentation(
                    event: event,
                    reason: .updated
                )
            case .updatePresented:
                let reason = presentedWarning?.reason ?? .updated
                presentedWarning = WatchForegroundEmergencyPresentation(
                    event: event,
                    reason: reason
                )
            case .clearPresented:
                if presentedWarning?.event.id == event.id {
                    presentedWarning = nil
                }
            case .baseline, .ignore:
                break
            }
        }

        pruneRetainedEventsIfNeeded()
    }

    private func pruneRetainedEventsIfNeeded() {
        guard latestByEventID.count > Self.retainedEventLimit else { return }
        let oldest = latestByEventID.values.sorted {
            ($0.reportDate ?? $0.originDate ?? .distantPast)
                < ($1.reportDate ?? $1.originDate ?? .distantPast)
        }
        for event in oldest.prefix(latestByEventID.count - Self.retainedEventLimit) {
            latestByEventID[event.id] = nil
        }
    }
}
