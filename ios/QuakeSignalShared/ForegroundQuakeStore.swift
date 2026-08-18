import Foundation
import Observation

/// Small shared state container for platforms that only show data while their
/// app is open. It deliberately has no APNs, App Attest, background task, or
/// persistent WebSocket dependency.
@Observable
@MainActor
final class ForegroundQuakeStore {
    private(set) var events: [EEWEvent] = []
    private(set) var isLoading = false
    private(set) var statusMessage: String?
    private(set) var lastUpdated: Date?
    private(set) var headlineEvaluationDate = Date()

    private let client: WolfxClient
    private let screenshotAutomationEnabled: Bool
    private static let headlineRevalidationInterval: Duration = .seconds(15)
    private static let snapshotRefreshTickCount = 20

    init(
        client: WolfxClient = .shared,
        screenshotAutomationEnabled: Bool = ScreenshotAutomation.isEnabled
    ) {
        self.client = client
        self.screenshotAutomationEnabled = screenshotAutomationEnabled
        if screenshotAutomationEnabled {
            events = ScreenshotAutomation.finalizedHistoricalEvents
            lastUpdated = ScreenshotAutomation.fixtureLastUpdated
        }
    }

    var headlineEvent: EEWEvent? {
        ForegroundHeadlinePolicy.headline(from: events, now: headlineEvaluationDate)
    }

    func refresh(limit: Int = 24) async {
        guard !screenshotAutomationEnabled else { return }
        guard !isLoading else { return }
        headlineEvaluationDate = Date()
        isLoading = true
        statusMessage = nil
        defer { isLoading = false }

        do {
            let snapshot = try await client.fetchRecentQuakesAllowingPartialResults(limit: limit)
            guard snapshot.hasSuccessfulSources else {
                statusMessage = snapshot.statusDescription
                    ?? String(localized: "platform.foreground.refreshUnavailable")
                return
            }
            events = snapshot.events
            lastUpdated = Date()
            statusMessage = snapshot.statusDescription
        } catch is CancellationError {
            return
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// Keeps the foreground-only companion truthful while its scene is active.
    /// The local clock re-evaluates warning freshness every 15 seconds, even if
    /// the upstream snapshot is quiet, and the network snapshot is refreshed at
    /// the existing five-minute cadence. The view's scene-bound task owns
    /// cancellation, so no background polling survives after deactivation.
    func monitorWhileActive(limit: Int = 24) async {
        guard !screenshotAutomationEnabled else { return }
        await refresh(limit: limit)
        var ticksUntilSnapshotRefresh = Self.snapshotRefreshTickCount

        while !Task.isCancelled {
            do {
                try await Task.sleep(for: Self.headlineRevalidationInterval)
            } catch {
                return
            }

            headlineEvaluationDate = Date()
            ticksUntilSnapshotRefresh -= 1
            if ticksUntilSnapshotRefresh == 0 {
                await refresh(limit: limit)
                ticksUntilSnapshotRefresh = Self.snapshotRefreshTickCount
            }
        }
    }
}
