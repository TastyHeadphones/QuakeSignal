import Foundation

/// A transport-independent snapshot used to decide whether tvOS should replace
/// the dashboard with its foreground warning surface. Keeping this policy free
/// of SwiftUI, networking, and audio makes the safety boundary deterministic.
struct TVEmergencyRevision: Equatable, Sendable {
    let eventID: String
    let serial: Int
    let reportDate: Date?
    let isEEW: Bool
    let isWarning: Bool
    let isFinal: Bool
    let isCancelled: Bool
    let isTraining: Bool

    var isActiveWarning: Bool {
        isEEW && isWarning && !isFinal && !isCancelled && !isTraining
    }

    var isTerminal: Bool {
        isFinal || isCancelled
    }
}

enum TVEmergencyPresentationAction: Equatable, Sendable {
    /// The frame is older than local state or is not an EEW lifecycle frame.
    case ignore
    /// Retain the frame as local state without interrupting the dashboard.
    case baseline
    /// Present a genuinely new warning received after a live route is seeded.
    case presentNew
    /// Present a monotonic revision of a warning already known on this launch.
    case presentUpdate
    /// Refresh the currently visible warning without creating a second alert.
    case updatePresented
    /// A terminal, informational, or expired frame retires the visible warning.
    case clearPresented
}

/// Fail-closed foreground-warning policy for Apple TV.
///
/// The first retained WebSocket/HTTP snapshot establishes a baseline instead
/// of masquerading as a newly delivered emergency. Once a warning is known on
/// this foreground launch, only monotonic revisions can update or reopen its
/// safety surface. Final and cancelled state can never be resurrected by a
/// later replay of an active frame.
enum TVEmergencyPresentationPolicy {
    static let maximumWarningAge: TimeInterval = 10 * 60
    static let allowedFutureSkew: TimeInterval = 60

    static func action(
        for incoming: TVEmergencyRevision,
        previous: TVEmergencyRevision?,
        presentedEventID: String?,
        isBackfill: Bool,
        hadLocalHistoryBeforeBatch: Bool,
        now: Date
    ) -> TVEmergencyPresentationAction {
        guard incoming.isEEW else { return .ignore }
        guard isMonotonic(incoming, replacing: previous) else { return .ignore }

        let isCurrentlyPresented = presentedEventID == incoming.eventID
        guard incoming.isActiveWarning, isFresh(incoming, now: now) else {
            return isCurrentlyPresented ? .clearPresented : .baseline
        }

        if isCurrentlyPresented {
            return .updatePresented
        }

        // A first snapshot can be a retained warning from before launch. It is
        // useful dashboard state, but it is not proof of a new foreground event.
        guard !(isBackfill && !hadLocalHistoryBeforeBatch) else { return .baseline }

        return previous?.isActiveWarning == true ? .presentUpdate : .presentNew
    }

    static func shouldExpire(_ presented: TVEmergencyRevision, now: Date) -> Bool {
        !presented.isActiveWarning || !isFresh(presented, now: now)
    }

    static func isFresh(_ revision: TVEmergencyRevision, now: Date) -> Bool {
        guard let reportDate = revision.reportDate else { return false }
        let age = now.timeIntervalSince(reportDate)
        return age >= -allowedFutureSkew && age <= maximumWarningAge
    }

    static func isMonotonic(
        _ incoming: TVEmergencyRevision,
        replacing previous: TVEmergencyRevision?
    ) -> Bool {
        guard let previous else { return true }
        guard incoming.eventID == previous.eventID else { return true }
        guard incoming != previous else { return false }

        // Once final or cancelled, an upstream reconnect must not resurrect the
        // same event as an active warning, even if that replay has a later serial.
        if previous.isTerminal && !incoming.isTerminal { return false }

        if incoming.serial != previous.serial {
            return incoming.serial > previous.serial
        }

        if incoming.isTerminal && !previous.isTerminal {
            return isNotOlder(incoming, than: previous)
        }

        // Permit same-serial promotion from an informational EEW to a warning,
        // while rejecting the opposite regression.
        if incoming.isActiveWarning != previous.isActiveWarning {
            return incoming.isActiveWarning && isNotOlder(incoming, than: previous)
        }

        guard let incomingDate = incoming.reportDate,
              let previousDate = previous.reportDate else {
            return false
        }
        return incomingDate > previousDate
    }

    private static func isNotOlder(
        _ incoming: TVEmergencyRevision,
        than previous: TVEmergencyRevision
    ) -> Bool {
        guard let incomingDate = incoming.reportDate,
              let previousDate = previous.reportDate else {
            return true
        }
        return incomingDate >= previousDate
    }
}
