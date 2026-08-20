import Foundation

enum WatchEmergencyPresentationReason: String, Equatable, Sendable {
    case new
    case updated
}

struct WatchForegroundEmergencyPresentation: Identifiable, Equatable, Sendable {
    let event: EEWEvent
    let reason: WatchEmergencyPresentationReason

    var id: String {
        WatchForegroundEmergencyPolicy.revisionKey(for: event)
    }

    var isUpdate: Bool {
        reason == .updated
    }
}

enum WatchEmergencyPresentationAction: Equatable, Sendable {
    /// The frame is unrelated, malformed, duplicated, or older than local state.
    case ignore
    /// Retain lifecycle state without interrupting the foreground dashboard.
    case baseline
    /// Present a genuinely new warning received after route seeding.
    case presentNew
    /// Present a monotonic revision of a warning already known this launch.
    case presentUpdate
    /// Refresh the warning that is already visible without a second alert.
    case updatePresented
    /// A terminal, malformed, or expired revision retires the visible warning.
    case clearPresented
}

/// Fail-closed, transport-independent gate for the foreground-only Watch
/// emergency surface. A retained first WebSocket/HTTP snapshot establishes a
/// baseline; it never masquerades as a warning that arrived while the app was
/// active. Reconnect backfill may surface only a monotonic revision of an event
/// already observed during this foreground launch.
enum WatchForegroundEmergencyPolicy {
    static func action(
        for incoming: EEWEvent,
        previous: EEWEvent?,
        presentedEventID: String?,
        isBackfill: Bool,
        hadLocalHistoryBeforeBatch: Bool,
        now: Date
    ) -> WatchEmergencyPresentationAction {
        guard isLifecycleFrame(incoming),
              isMonotonic(incoming, replacing: previous) else {
            return .ignore
        }

        let isCurrentlyPresented = presentedEventID == incoming.id
        guard isPresentableWarning(incoming, now: now) else {
            return isCurrentlyPresented ? .clearPresented : .baseline
        }

        if isCurrentlyPresented {
            return .updatePresented
        }

        // First snapshots are retained state, not evidence of a new delivery.
        guard !(isBackfill && !hadLocalHistoryBeforeBatch) else {
            return .baseline
        }

        return previous?.isActiveWarning == true ? .presentUpdate : .presentNew
    }

    static func shouldExpire(_ event: EEWEvent, now: Date) -> Bool {
        !isPresentableWarning(event, now: now)
    }

    static func revisionKey(for event: EEWEvent) -> String {
        "\(event.id)#\(event.serial)"
    }

    static func isPresentableWarning(_ event: EEWEvent, now: Date = Date()) -> Bool {
        guard isLifecycleFrame(event),
              event.isActiveWarning,
              !event.hypocenter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let magnitude = event.magnitude,
              magnitude.isFinite,
              event.maxIntensity != nil,
              event.coordinate != nil else {
            return false
        }
        return WarningFreshnessPolicy.isFresh(event, now: now)
    }

    static func isLifecycleFrame(_ event: EEWEvent) -> Bool {
        event.sourceId == "jma_eew" &&
            event.kind == "eew" &&
            !event.eventId.isEmpty &&
            event.id == "jma_eew:\(event.eventId)" &&
            event.serial > 0 &&
            (event.reportDate ?? event.originDate) != nil
    }

    static func isMonotonic(_ incoming: EEWEvent, replacing previous: EEWEvent?) -> Bool {
        guard let previous else { return true }
        guard incoming.id == previous.id, incoming != previous else { return false }

        // A reconnect replay must never resurrect an event that reached a
        // final or cancelled state, even if the replay claims a later serial.
        if isTerminal(previous) && !isTerminal(incoming) {
            return false
        }

        if incoming.serial != previous.serial {
            return incoming.serial > previous.serial
        }

        if isTerminal(incoming) && !isTerminal(previous) {
            return isNotOlder(incoming, than: previous)
        }

        // Permit same-serial promotion from informational EEW to warning, but
        // reject a later informational replay that would erase a warning.
        if incoming.isActiveWarning != previous.isActiveWarning {
            return incoming.isActiveWarning && isNotOlder(incoming, than: previous)
        }

        guard let incomingDate = incoming.reportDate ?? incoming.originDate,
              let previousDate = previous.reportDate ?? previous.originDate else {
            return false
        }
        return incomingDate > previousDate
    }

    private static func isTerminal(_ event: EEWEvent) -> Bool {
        event.isFinal || event.isCancel
    }

    private static func isNotOlder(_ incoming: EEWEvent, than previous: EEWEvent) -> Bool {
        guard let incomingDate = incoming.reportDate ?? incoming.originDate,
              let previousDate = previous.reportDate ?? previous.originDate else {
            return true
        }
        return incomingDate >= previousDate
    }
}
