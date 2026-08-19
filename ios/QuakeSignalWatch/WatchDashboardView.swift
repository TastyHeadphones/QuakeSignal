import SwiftUI

struct WatchDashboardView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = ForegroundQuakeStore()

    var body: some View {
        NavigationStack {
            if ScreenshotAutomation.selectedFrame == .watchEventDetail,
               let event = store.headlineEvent {
                WatchEventDetailView(event: event)
            } else {
                dashboard
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await store.monitorWhileActive(limit: 12)
        }
    }

    private var dashboard: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Label("platform.foreground.badge", systemImage: "applewatch")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color("CautionColor"))

                        if store.isShowingHistoricalFixture {
                            Label("platform.historical.badge", systemImage: "clock.arrow.circlepath")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }

                    headline

                    Text("platform.watch.foregroundOnly.short")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    Button {
                        Task { await store.refresh(limit: 12) }
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

                    VStack(alignment: .leading, spacing: 4) {
                        Label("platform.foreground.badge", systemImage: "eye")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color("CautionColor"))
                        Text("platform.historical.reports")
                            .font(.caption.weight(.semibold))
                    }
                    .id("watch-recent-reports")

                    ForEach(store.events.prefix(8)) { event in
                        NavigationLink {
                            WatchEventDetailView(event: event)
                        } label: {
                            WatchEventRow(event: event)
                        }
                    }
                }
            }
            .navigationTitle("app.name")
            .task {
                guard ScreenshotAutomation.selectedFrame == .watchRecentReports else { return }
                await Task.yield()
                proxy.scrollTo("watch-recent-reports", anchor: .top)
            }
        }
    }

    @ViewBuilder
    private var headline: some View {
        if let event = store.headlineEvent {
            NavigationLink {
                WatchEventDetailView(event: event)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(event.magnitudeText)
                            .font(.system(.title, design: .rounded, weight: .bold))
                            .foregroundStyle(event.severity.color)
                        Spacer()
                        Text(event.reportStatus.labelKey)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(event.hypocenter)
                        .font(.headline)
                        .lineLimit(2)
                    if let date = event.reportDate ?? event.originDate {
                        Text(date.formatted(date: .numeric, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
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

private struct WatchEventRow: View {
    let event: EEWEvent

    var body: some View {
        HStack(spacing: 8) {
            Text(event.magnitudeText)
                .font(.headline.monospacedDigit())
                .foregroundStyle(event.severity.color)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.hypocenter)
                    .font(.caption)
                    .lineLimit(1)
                Text(event.sourceLabelKey)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct WatchEventDetailView: View {
    let event: EEWEvent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Label("platform.foreground.badge", systemImage: "eye")
                    .foregroundStyle(Color("CautionColor"))
                Text(event.magnitudeText)
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .foregroundStyle(event.severity.color)
                Text(event.hypocenter)
                    .font(.headline)
                Label(event.reportStatus.labelKey, systemImage: "waveform.path.ecg")
                if let maxIntensity = event.maxIntensity {
                    Label(L("quake.intensity.label", maxIntensity), systemImage: "gauge.with.dots.needle.67percent")
                }
                if let depth = event.depth {
                    Label(L("quake.depth.label", depth), systemImage: "arrow.down")
                }
                Text(event.sourceLabelKey)
                    .foregroundStyle(.secondary)
                if let date = event.reportDate ?? event.originDate {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(.secondary)
                }
                Divider()
                Text("platform.watch.foregroundOnly.detail")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .navigationTitle("detail.title")
    }
}
