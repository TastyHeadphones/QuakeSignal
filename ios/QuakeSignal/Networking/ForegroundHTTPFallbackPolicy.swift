import Foundation

/// Scheduling policy for foreground recovery when Wolfx's WebSocket service is
/// unavailable but its normal HTTPS endpoints still work. This is intentionally
/// not an alert-delivery fallback: it refreshes the same public data that the
/// user can already pull to refresh in the foreground.
enum ForegroundHTTPFallbackPolicy {
    /// Give sockets time to reconnect before creating any additional HTTP load.
    static let initialDelaySeconds: UInt64 = 90
    /// Seven upstream requests are made by one normal `refresh()`, so five
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
