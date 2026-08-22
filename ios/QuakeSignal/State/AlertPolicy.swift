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

/// Captures the notification-presentation decision after the app has had one
/// synchronous opportunity to take ownership of this warning revision or
/// recognize that a newer revision already owns the emergency presentation.
enum ForegroundNotificationSystemPresentation: Equatable {
    case alert
    case listOnly
}

struct ForegroundNotificationPresentationDecision: Equatable {
    let systemPresentation: ForegroundNotificationSystemPresentation
    let didHandleEmergencyInApp: Bool
}

enum ForegroundNotificationPresentationPolicy {
    static func allowsEmergencyPresentation(
        for payload: PushPayload,
        isSceneActive: Bool
    ) -> Bool {
        payload.hasUsableMatchingEventSnapshot && isSceneActive
    }

    static func decision(
        didHandleEmergencyInApp: Bool
    ) -> ForegroundNotificationPresentationDecision {
        ForegroundNotificationPresentationDecision(
            systemPresentation: didHandleEmergencyInApp ? .listOnly : .alert,
            didHandleEmergencyInApp: didHandleEmergencyInApp
        )
    }
}

/// Identifies one event revision for foreground presentation ownership. A
/// later APNs copy may yield its banner for the same revision, for an older
/// active revision that this key monotonically supersedes, or for an active
/// replay after a system-presented terminal lifecycle boundary.
struct ForegroundEmergencyRevisionKey: Hashable, Sendable {
    let eventID: String
    let serial: Int
    let kind: String
    let isWarning: Bool
    let isFinal: Bool
    let isCancelled: Bool
    let isTraining: Bool
    let effectiveTimestamp: Date?

    init(event: EEWEvent) {
        self.init(
            eventID: event.id,
            serial: event.serial,
            kind: event.kind,
            isWarning: event.isWarn,
            isFinal: event.isFinal,
            isCancelled: event.isCancel,
            isTraining: event.isTraining,
            effectiveTimestamp: event.reportDate ?? event.originDate
        )
    }

    init(
        eventID: String,
        serial: Int,
        kind: String,
        isWarning: Bool,
        isFinal: Bool,
        isCancelled: Bool,
        isTraining: Bool,
        effectiveTimestamp: Date?
    ) {
        self.eventID = eventID
        self.serial = serial
        self.kind = kind
        self.isWarning = isWarning
        self.isFinal = isFinal
        self.isCancelled = isCancelled
        self.isTraining = isTraining
        self.effectiveTimestamp = effectiveTimestamp
    }

    private var isActiveWarning: Bool {
        kind == "eew" && isWarning && !isFinal && !isCancelled && !isTraining
    }

    private var isTerminalWarningLifecycle: Bool {
        kind == "eew" && !isTraining && (isFinal || isCancelled)
    }

    /// A warning already elevated by the app also owns a delayed APNs copy of
    /// an older active revision. The inverse is deliberately false: a handled
    /// older revision must not hide a newer APNs update.
    func monotonicallyDominates(_ incoming: ForegroundEmergencyRevisionKey) -> Bool {
        guard eventID == incoming.eventID else { return false }
        // Once APNs has presented a meaningful final/cancellation, no active
        // replay for that event may reopen imperative UI during the brief
        // snapshot-resolution gap. This mirrors EventMergePolicy, where a
        // terminal lifecycle outranks even a later-serial active replay.
        if isTerminalWarningLifecycle && incoming.isActiveWarning {
            return true
        }
        guard isActiveWarning,
              incoming.isActiveWarning else {
            return false
        }
        if serial != incoming.serial {
            return serial > incoming.serial
        }
        guard let effectiveTimestamp,
              let incomingTimestamp = incoming.effectiveTimestamp else {
            return false
        }
        return effectiveTimestamp > incomingTimestamp
    }
}

enum ForegroundEmergencyRevisionOwnershipPolicy {
    static func key(for event: EEWEvent) -> ForegroundEmergencyRevisionKey {
        ForegroundEmergencyRevisionKey(event: event)
    }

    static func wasAlreadyHandled(
        event: EEWEvent,
        handledRevisionKeys: Set<ForegroundEmergencyRevisionKey>,
        allowsEmergencyPresentation: Bool
    ) -> Bool {
        guard allowsEmergencyPresentation else { return false }
        let incoming = key(for: event)
        if handledRevisionKeys.contains(incoming) { return true }
        guard event.isActiveWarning else { return false }
        return handledRevisionKeys.contains { handled in
            handled.monotonicallyDominates(incoming)
        }
    }
}

/// A snapshotless foreground push has already kept its APNs banner and sound
/// before the matching event can be resolved. Reserve its validated revision
/// briefly so an older direct copy cannot consume ownership intended for a
/// newer live revision. Exact matches consume their one-shot reservation;
/// monotonically older active copies remain system-owned until that exact
/// revision arrives or the bounded reservation expires.
enum ForegroundSystemPresentationReservationPolicy {
    static let lifetime: TimeInterval = 15

    static func reserve(
        revisionKey: ForegroundEmergencyRevisionKey,
        receivedAt: Date,
        now: Date,
        reservations: inout [ForegroundEmergencyRevisionKey: Date]
    ) {
        guard !revisionKey.eventID.isEmpty else { return }
        removeExpired(now: now, reservations: &reservations)
        // A launch-buffered delivery keeps its original receipt time. Starting
        // this TTL when RootView later drains the buffer could suppress an
        // unrelated newer revision long after APNs presented the first one.
        let expiresAt = receivedAt.addingTimeInterval(lifetime)
        guard expiresAt >= now else { return }
        reservations[revisionKey] = expiresAt
    }

    static func consume(
        revisionKey: ForegroundEmergencyRevisionKey,
        now: Date,
        reservations: inout [ForegroundEmergencyRevisionKey: Date]
    ) -> Bool {
        removeExpired(now: now, reservations: &reservations)
        if let expiresAt = reservations.removeValue(forKey: revisionKey) {
            return expiresAt >= now
        }
        return reservations.keys.contains { reserved in
            reserved.monotonicallyDominates(revisionKey)
        }
    }

    private static func removeExpired(
        now: Date,
        reservations: inout [ForegroundEmergencyRevisionKey: Date]
    ) {
        reservations = reservations.filter { $0.value >= now }
    }
}

/// Playback is reached only after the foreground preference/location policy
/// accepts a warning. Training therefore plays only for an opted-in event that
/// was explicitly elevated with the training reason.
enum ForegroundEmergencyAudioPolicy {
    static func shouldPlay(event: EEWEvent, reason: AlertPresentationReason) -> Bool {
        event.isActiveWarning ||
            (event.kind == "eew" && event.isTraining && reason == .training)
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
