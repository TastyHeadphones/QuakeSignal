import Foundation

/// Direct Wolfx monitoring is scene-bound on every full-interface target.
/// iPhone and iPad use APNs—not a hidden WebSocket or HTTP task—as their
/// background warning path; targets without the attested relay have no
/// background emergency-alert path at all.
enum DirectMonitoringLifecycleAction: Equatable {
    case startSocket
    case stopSocket
    case cancelRefreshes
    case refreshSnapshot
    case startForegroundMaintenance
    case stopForegroundMaintenance
    case stopAlertAudio
}

enum DirectMonitoringLifecyclePolicy {
    static let suspensionActions: [DirectMonitoringLifecycleAction] = [
        .stopSocket,
        .cancelRefreshes,
        .stopForegroundMaintenance,
        .stopAlertAudio,
    ]

    static let activationActions: [DirectMonitoringLifecycleAction] = [
        .startSocket,
        .startForegroundMaintenance,
        .refreshSnapshot,
    ]

    static func shouldRun(hasStarted: Bool, isForegroundActive: Bool) -> Bool {
        hasStarted && isForegroundActive
    }

    static func actionsForStart(
        hasStarted: Bool,
        isForegroundActive: Bool
    ) -> [DirectMonitoringLifecycleAction] {
        guard !hasStarted else { return [] }
        return isForegroundActive ? activationActions : suspensionActions
    }

    static func actionsForSceneTransition(
        hasStarted: Bool,
        wasForegroundActive: Bool,
        isForegroundActive: Bool
    ) -> [DirectMonitoringLifecycleAction] {
        guard isForegroundActive else { return suspensionActions }
        guard hasStarted, !wasForegroundActive else { return [] }
        return activationActions
    }

    static func shouldAcceptDirectEvent(isForegroundActive: Bool) -> Bool {
        isForegroundActive
    }

    static func shouldPresentForegroundEmergency(isForegroundActive: Bool) -> Bool {
        isForegroundActive
    }
}

/// Scheduling policy for foreground recovery when Wolfx's WebSocket service is
/// unavailable but its normal HTTPS endpoints still work. This is intentionally
/// not an alert-delivery fallback: it refreshes the same public data that the
/// user can already pull to refresh in the foreground.
enum ForegroundHTTPFallbackPolicy {
    /// Give sockets time to reconnect before creating any additional HTTP load.
    static let initialDelaySeconds: UInt64 = 90
    /// Two upstream requests are made by one normal JMA-only `refresh()`, so five
    /// minutes is deliberately conservative and stays far below Wolfx's
    /// documented public request limit.
    static let repeatDelaySeconds: UInt64 = 300

    /// Returns nil when HTTP fallback must be idle. A socket set is considered
    /// healthy only once every subscribed route has delivered data; until then,
    /// one slow foreground refresh can cover the data routes that are down.
    static func nextDelaySeconds(
        isForegroundActive: Bool,
        socketsConnected: Bool,
        hasCompletedFallbackRefresh: Bool
    ) -> UInt64? {
        guard isForegroundActive, !socketsConnected else { return nil }
        return hasCompletedFallbackRefresh ? repeatDelaySeconds : initialDelaySeconds
    }
}
