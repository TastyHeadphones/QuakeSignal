import Foundation
import Observation

enum TVEmergencyPresentationReason: String, Equatable, Sendable {
    case new
    case updated
}

struct TVPresentedWarning: Identifiable, Equatable, Sendable {
    let event: EEWEvent
    let reason: TVEmergencyPresentationReason

    var id: String {
        "\(event.id)#\(event.serial)#\(reason.rawValue)"
    }
}

/// Owns Apple TV's foreground-only direct monitoring lifecycle. It has no APNs,
/// background task, notification entitlement, or audio side effect. A warning
/// can become visible only while the scene is active and after a validated live
/// route has established baseline state for this foreground launch.
@Observable
@MainActor
final class TVEmergencyMonitor {
    private(set) var presentedWarning: TVPresentedWarning?
    private(set) var isLive = false

    private let socket: LiveSocketClient
    private let client: WolfxClient
    private let now: () -> Date
    private var latestByEventID: [String: EEWEvent] = [:]
    private var fallbackTask: Task<Void, Never>?
    private var expirationTask: Task<Void, Never>?
    private var isSceneActive = false

    private static let initialFallbackDelay: Duration = .seconds(90)
    private static let repeatFallbackDelay: Duration = .seconds(300)
    private static let expirationTick: Duration = .seconds(15)
    private static let retainedEventLimit = 128

    init(
        socket: LiveSocketClient? = nil,
        client: WolfxClient = .shared,
        now: @escaping () -> Date = Date.init
    ) {
        // Default arguments are evaluated from a nonisolated context in Swift
        // 6. Construct the main-actor socket inside this main-actor initializer.
        self.socket = socket ?? LiveSocketClient()
        self.client = client
        self.now = now
    }

    func setSceneActive(_ isActive: Bool) {
        guard isSceneActive != isActive else { return }
        isSceneActive = isActive
        if isActive {
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
        isLive = false

        socket.onEvents = { [weak self] events, isBackfill in
            self?.ingest(events, isBackfill: isBackfill)
        }
        socket.onConnectionStateChanged = { [weak self] isConnected in
            self?.connectionStateChanged(isConnected)
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
        isLive = false
    }

    private func connectionStateChanged(_ connected: Bool) {
        guard isSceneActive else { return }
        isLive = connected
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

            while !Task.isCancelled, self.isSceneActive, !self.socket.isConnected {
                do {
                    try await Task.sleep(
                        for: hasCompletedRefresh
                            ? Self.repeatFallbackDelay
                            : Self.initialFallbackDelay
                    )
                } catch {
                    return
                }
                guard self.isSceneActive, !self.socket.isConnected else { return }

                do {
                    let snapshot = try await self.client
                        .fetchRecentQuakesAllowingPartialResults(limit: 24)
                    if snapshot.hasSuccessfulSources {
                        self.ingest(snapshot.events, isBackfill: true)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    // The dashboard already communicates partial/unavailable
                    // HTTP state. This recovery loop remains silent and retries
                    // at the conservative foreground cadence.
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
                   TVEmergencyPresentationPolicy.shouldExpire(
                       warning.event.tvEmergencyRevision,
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

        // Process same-event revisions oldest-first so a batch cannot skip over
        // its monotonic lifecycle or make array order change the decision.
        let orderedEvents = events.sorted { left, right in
            if left.id != right.id { return left.id < right.id }
            if left.serial != right.serial { return left.serial < right.serial }
            let leftDate = left.reportDate ?? left.originDate ?? .distantPast
            let rightDate = right.reportDate ?? right.originDate ?? .distantPast
            return leftDate < rightDate
        }

        for event in orderedEvents where event.isEew {
            let previous = latestByEventID[event.id]
            let action = TVEmergencyPresentationPolicy.action(
                for: event.tvEmergencyRevision,
                previous: previous?.tvEmergencyRevision,
                presentedEventID: presentedWarning?.event.id,
                isBackfill: isBackfill,
                hadLocalHistoryBeforeBatch: locallyKnownEventIDs.contains(event.id),
                now: now()
            )
            guard action != .ignore else { continue }

            latestByEventID[event.id] = event
            switch action {
            case .presentNew:
                presentedWarning = TVPresentedWarning(event: event, reason: .new)
            case .presentUpdate:
                presentedWarning = TVPresentedWarning(event: event, reason: .updated)
            case .updatePresented:
                let reason = presentedWarning?.reason ?? .updated
                presentedWarning = TVPresentedWarning(event: event, reason: reason)
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

private extension EEWEvent {
    var tvEmergencyRevision: TVEmergencyRevision {
        TVEmergencyRevision(
            eventID: id,
            serial: serial,
            reportDate: reportDate ?? originDate,
            isEEW: isEew,
            isWarning: isWarn,
            isFinal: isFinal,
            isCancelled: isCancel,
            isTraining: isTraining
        )
    }
}
