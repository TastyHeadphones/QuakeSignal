import Foundation
import SwiftUI

struct WatchDashboardView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = ForegroundQuakeStore()
    @State private var manualRefreshLifecycle = ForegroundManualRefreshLifecycle()

    var body: some View {
        NavigationStack {
            switch ScreenshotAutomation.selectedFrame {
            case .watchHeadline:
                dashboard
            case .watchRecentReports:
                reports
            case .watchEventDetail:
                if let event = store.headlineEvent {
                    WatchEventDetailView(event: event)
                } else {
                    dashboard
                }
            default:
                dashboard
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await store.monitorWhileActive(limit: 12)
        }
        .task(id: manualRefreshLifecycle.taskID(isSceneActive: scenePhase == .active)) {
            guard manualRefreshLifecycle.shouldRun(isSceneActive: scenePhase == .active) else { return }
            await store.refresh(limit: 12)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            manualRefreshLifecycle.cancelPendingRefresh()
        }
        .onDisappear {
            manualRefreshLifecycle.cancelPendingRefresh()
        }
    }

    private var dashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                WatchContextBadges(isHistorical: store.isShowingHistoricalFixture)

                headline

                Text("platform.watch.foregroundOnly.short")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.86)

                Button {
                    manualRefreshLifecycle.requestRefresh(isSceneActive: scenePhase == .active)
                } label: {
                    if store.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("platform.refresh", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(store.isLoading)

                if let statusMessage = store.statusMessage {
                    Label(statusMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(Color("CautionColor"))
                }

                NavigationLink {
                    reports
                } label: {
                    if store.isShowingHistoricalFixture {
                        Label("platform.historical.reports", systemImage: "list.bullet")
                    } else {
                        Label("home.section.recent", systemImage: "list.bullet")
                    }
                }
            }
        }
        .navigationTitle("app.name")
    }

    private var reports: some View {
        WatchReportsView(
            events: store.events,
            isHistorical: store.isShowingHistoricalFixture,
            isLoading: store.isLoading
        ) {
            manualRefreshLifecycle.requestRefresh(isSceneActive: scenePhase == .active)
        }
    }

    @ViewBuilder
    private var headline: some View {
        if let event = store.headlineEvent {
            WatchHeadlineCard(event: event)
        } else if store.isLoading {
            ProgressView("platform.loading")
                .frame(maxWidth: .infinity, minHeight: 70)
        } else {
            Text("home.empty.title")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 70)
        }
    }
}

private struct WatchContextBadges: View {
    let isHistorical: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("platform.foreground.badge", systemImage: "applewatch")
                .foregroundStyle(Color("CautionColor"))
            if isHistorical {
                Label("platform.historical.badge", systemImage: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2.weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.78)
        .accessibilityElement(children: .contain)
    }
}

private struct WatchHeadlineCard: View {
    let event: EEWEvent

    var body: some View {
        NavigationLink {
            WatchEventDetailView(event: event)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(event.magnitudeText)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(event.severity.color)
                    Spacer(minLength: 4)
                    Text(event.reportStatus.labelKey)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(event.hypocenter)
                    .font(.headline)
                    .lineLimit(2)
                    .minimumScaleFactor(0.86)
                if let date = event.reportDate ?? event.originDate {
                    Text(date.formatted(date: .numeric, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color("CardColor"),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct WatchReportsView: View {
    let events: [EEWEvent]
    let isHistorical: Bool
    let isLoading: Bool
    let onRefresh: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Label("platform.foreground.badge", systemImage: "eye")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color("CautionColor"))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    Spacer(minLength: 2)

                    Button(action: onRefresh) {
                        if isLoading {
                            ProgressView()
                        } else {
                            Label("platform.refresh", systemImage: "arrow.clockwise")
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(isLoading)
                }

                if isHistorical {
                    Label("platform.historical.reports", systemImage: "clock.arrow.circlepath")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                } else {
                    Text("home.section.recent")
                        .font(.caption.weight(.semibold))
                }

                ForEach(events.prefix(8)) { event in
                    NavigationLink {
                        WatchEventDetailView(event: event)
                    } label: {
                        WatchCompactEventRow(event: event)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("app.name")
    }
}

private struct WatchCompactEventRow: View {
    let event: EEWEvent

    var body: some View {
        HStack(spacing: 7) {
            Text(event.magnitudeText)
                .font(.headline.monospacedDigit())
                .foregroundStyle(event.severity.color)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.hypocenter)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(event.reportStatus.labelKey)
                    Text(event.sourceLabelKey)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color("CardColor"),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }
}

private struct WatchEventDetailView: View {
    let event: EEWEvent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                foregroundBadge

                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(event.magnitudeText)
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(event.severity.color)

                    Spacer(minLength: 3)

                    if let depth = event.depth {
                        Label(localizedDepthLabel(depth), systemImage: "arrow.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }
                }

                Text(event.hypocenter)
                    .font(.headline)
                    .lineLimit(2)
                    .minimumScaleFactor(0.84)

                HStack(spacing: 6) {
                    Label(event.reportStatus.labelKey, systemImage: "waveform.path.ecg")
                    Text(event.sourceLabelKey)
                        .foregroundStyle(.secondary)

                    if let maxIntensity = event.maxIntensity {
                        Spacer(minLength: 2)
                        Text(L("quake.intensity.label", maxIntensity))
                            .foregroundStyle(.secondary)
                            .minimumScaleFactor(0.75)
                    }
                }
                .font(.caption2)
                .lineLimit(1)

                if let date = event.reportDate ?? event.originDate {
                    Label(
                        date.formatted(date: .numeric, time: .shortened),
                        systemImage: "clock"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                }

                Divider()
                Text("platform.watch.foregroundOnly.detail")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("detail.title")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var foregroundBadge: some View {
        Label("platform.foreground.badge", systemImage: "eye")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.black)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color("CautionColor"),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .accessibilityIdentifier("watch-event-detail-foreground-badge")
    }
}

private func localizedDepthLabel(_ depth: Double) -> String {
    let depthText = String(
        format: "%.0f",
        locale: Locale(identifier: "en_US_POSIX"),
        depth
    )
    return L("quake.depth.label", depthText)
}
