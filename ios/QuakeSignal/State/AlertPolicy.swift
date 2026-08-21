import CoreLocation
import Foundation

enum AlertPresentationReason: String, Codable, Sendable, Equatable {
    case new
    case updated
    case final
    case cancelled
    case training
    case report

    init(wireValue: String?) {
        switch wireValue {
        case "updated", "update": self = .updated
        case "final": self = .final
        case "cancelled", "cancel": self = .cancelled
        case "training": self = .training
        case "report": self = .report
        default: self = .new
        }
    }
}

/// Captures the notification-presentation decision at receipt time. Keeping
/// this decision with a buffered payload prevents a launch or scene-state
/// transition from causing both the system and the app to present the same
/// warning.
enum ForegroundNotificationSystemPresentation: Equatable {
    case alert
    case listOnly
}

struct ForegroundNotificationPresentationDecision: Equatable {
    let systemPresentation: ForegroundNotificationSystemPresentation
    let shouldPresentEmergencyInApp: Bool
}

enum ForegroundNotificationPresentationPolicy {
    static func decision(
        for payload: PushPayload,
        isSceneActive: Bool
    ) -> ForegroundNotificationPresentationDecision {
        guard payload.hasUsableMatchingEventSnapshot, isSceneActive else {
            return ForegroundNotificationPresentationDecision(
                systemPresentation: .alert,
                shouldPresentEmergencyInApp: false
            )
        }

        return ForegroundNotificationPresentationDecision(
            systemPresentation: .listOnly,
            shouldPresentEmergencyInApp: true
        )
    }
}

enum PresentedEventMode: String, Equatable {
    case emergency
    case detail
}

/// A notification tap is navigation intent, but only a warning that is still
/// active and fresh may reopen the imperative emergency surface. Historical,
/// terminal, informational, training, or malformed frames open ordinary event
/// details instead.
enum NotificationTapPresentationPolicy {
    static func mode(for event: EEWEvent, now: Date = Date()) -> PresentedEventMode {
        event.isActiveWarning && WarningFreshnessPolicy.isFresh(event, now: now)
            ? .emergency
            : .detail
    }
}

struct AlertPreferenceSnapshot: Sendable {
    let subscriptionEnabled: Bool
    let enabledSources: Set<String>
    let minimumMagnitude: Double
    let coordinate: CLLocationCoordinate2D?
    let radiusKm: Double
    let includeTraining: Bool
}

/// One monotonic merge rule for WebSocket, HTTP, and foreground-push data.
/// Lower serials and non-terminal replays can never replace a newer or
/// cancelled/final revision already visible in the app.
enum EventMergePolicy {
    static func shouldAccept(_ incoming: EEWEvent, replacing current: EEWEvent?) -> Bool {
        guard let current else { return true }
        guard incoming.id == current.id else { return true }
        if incoming == current { return false }

        // Terminal lifecycle state outranks a later serial. Some upstream
        // reconnects replay an active snapshot after a final/cancellation;
        // allowing that frame would resurrect a completed warning.
        if current.isCancel && !incoming.isCancel { return false }
        if current.isFinal && !incoming.isFinal && !incoming.isCancel { return false }

        if incoming.serial != current.serial {
            return incoming.serial > current.serial
        }

        if incoming.isCancel && !current.isCancel { return isNotOlder(incoming, than: current) }
        if incoming.isFinal && !current.isFinal { return isNotOlder(incoming, than: current) }

        // Some sources promote an informational frame to a genuine warning
        // without incrementing the serial or report timestamp. Treat that
        // safety escalation as monotonic, while never allowing a same-serial
        // non-warning replay to erase an already active warning.
        if incoming.isWarn != current.isWarn {
            return incoming.isWarn && isNotOlder(incoming, than: current)
        }

        guard let incomingDate = incoming.reportDate ?? incoming.originDate,
              let currentDate = current.reportDate ?? current.originDate else {
            return false
        }
        return incomingDate > currentDate
    }

    static func preferred(_ left: EEWEvent, _ right: EEWEvent) -> EEWEvent {
        shouldAccept(right, replacing: left) ? right : left
    }

    private static func isNotOlder(_ incoming: EEWEvent, than current: EEWEvent) -> Bool {
        guard let incomingDate = incoming.reportDate ?? incoming.originDate,
              let currentDate = current.reportDate ?? current.originDate else {
            return true
        }
        return incomingDate >= currentDate
    }
}

enum ForegroundPushPolicy {
    struct IngestionDecision: Equatable {
        let shouldMerge: Bool
        let presentationReason: AlertPresentationReason?
    }

    static func ingestionDecision(
        for event: EEWEvent,
        previous: EEWEvent?,
        requestedReason: AlertPresentationReason,
        allowsEmergencyPresentation: Bool,
        preferences: AlertPreferenceSnapshot,
        now: Date = Date()
    ) -> IngestionDecision {
        guard EventMergePolicy.shouldAccept(event, replacing: previous) else {
            return IngestionDecision(shouldMerge: false, presentationReason: nil)
        }

        guard allowsEmergencyPresentation else {
            return IngestionDecision(shouldMerge: true, presentationReason: nil)
        }

        guard let eligibleReason = ForegroundAlertPolicy.presentationReason(
            for: event,
            previous: previous,
            isBackfill: false,
            preferences: preferences,
            now: now
        ) else {
            // Final, cancelled, informational, stale, and filtered frames must
            // still retire or update the visible lifecycle monotonically. They
            // simply must not take over the screen as a new emergency.
            return IngestionDecision(shouldMerge: true, presentationReason: nil)
        }

        let presentationReason = eligibleReason == .training
            ? AlertPresentationReason.training
            : requestedReason == .updated ? .updated : eligibleReason
        return IngestionDecision(
            shouldMerge: true,
            presentationReason: presentationReason
        )
    }

    static func presentationReason(
        for event: EEWEvent,
        previous: EEWEvent?,
        requestedReason: AlertPresentationReason,
        allowsEmergencyPresentation: Bool,
        preferences: AlertPreferenceSnapshot,
        now: Date = Date()
    ) -> AlertPresentationReason? {
        ingestionDecision(
            for: event,
            previous: previous,
            requestedReason: requestedReason,
            allowsEmergencyPresentation: allowsEmergencyPresentation,
            preferences: preferences,
            now: now
        ).presentationReason
    }
}

/// Safety-critical foreground presentation policy. Only a fresh, actionable
/// warning that matches the person's saved alert filters may take over the
/// screen. Informational EEW frames, routine reports, final messages, and
/// cancellations remain available in the event list without masquerading as
/// a new emergency.
enum ForegroundAlertPolicy {
    static let maximumWarningAge = WarningFreshnessPolicy.maximumAge

    static func presentationReason(
        for event: EEWEvent,
        previous: EEWEvent?,
        isBackfill: Bool,
        preferences: AlertPreferenceSnapshot,
        now: Date = Date()
    ) -> AlertPresentationReason? {
        guard preferences.subscriptionEnabled,
              preferences.enabledSources.contains(event.sourceId),
              (event.magnitude ?? 0) >= preferences.minimumMagnitude,
              isFresh(event, now: now) else {
            return nil
        }

        // QuakeSignal has no user-visible nationwide alert mode. Until a city
        // or current-location fix exists, foreground delivery must match the
        // server's fail-closed nearby-subscription behavior.
        guard let coordinate = preferences.coordinate,
              let distance = event.distanceKm(from: coordinate),
              distance <= preferences.radiusKm else {
            return nil
        }

        if event.isTraining {
            guard preferences.includeTraining, !isBackfill || previous != nil else { return nil }
            return .training
        }

        guard event.isActiveWarning else { return nil }
        // A retained snapshot with no local history establishes baseline state
        // only. If local history exists, the monotonic merge has already
        // proved that a reconnect frame is genuinely newer and may alert.
        guard !isBackfill || previous != nil else { return nil }
        return previous?.isActiveWarning == true ? .updated : .new
    }

    static func isFresh(_ event: EEWEvent, now: Date = Date()) -> Bool {
        WarningFreshnessPolicy.isFresh(event, now: now)
    }
}
