import Foundation
import SwiftUI

struct TVDashboardView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = ForegroundQuakeStore()
    @FocusState private var focusedEventID: EEWEvent.ID?

    var body: some View {
        NavigationStack {
            if ScreenshotAutomation.selectedFrame == .tvEventDetail,
               let event = store.headlineEvent {
                TVEventDetailView(event: event)
            } else {
                dashboard
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await store.monitorWhileActive()
        }
        .task {
            guard ScreenshotAutomation.selectedFrame == .tvRecentReports else { return }
            try? await Task.sleep(for: .milliseconds(500))
            focusedEventID = store.events.first?.id
        }
    }

    private var dashboard: some View {
        ZStack {
            LinearGradient(
                colors: [Color("GroupedBGColor"), Color("TintBGColor")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 34) {
                    header
                    headline
                    recentEvents
                }
                .frame(maxWidth: 1_420, alignment: .leading)
                .padding(.horizontal, 72)
                .padding(.vertical, 54)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
                Text("platform.tv.title")
                    .font(.largeTitle.bold())
                Label("platform.foreground.badge", systemImage: "tv")
                    .font(.headline)
                    .foregroundStyle(Color("CautionColor"))
                Text("platform.tv.foregroundOnly.detail")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 760, alignment: .leading)
            }

            Spacer()

            Button {
                Task { await store.refresh() }
            } label: {
                if store.isLoading {
                    ProgressView()
                        .frame(minWidth: 160)
                } else {
                    Label("platform.refresh", systemImage: "arrow.clockwise")
                        .frame(minWidth: 160)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color("CautionColor"))
            .disabled(store.isLoading)
        }
    }

    @ViewBuilder
    private var headline: some View {
        if let event = store.headlineEvent {
            NavigationLink {
                TVEventDetailView(event: event)
            } label: {
                HStack(spacing: 34) {
                    VStack(spacing: 2) {
                        Text(event.magnitudeText)
                            .font(.system(size: 82, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("alert.magnitudeLabel")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text(event.hypocenter)
                            .font(.title.bold())
                            .lineLimit(2)
                        HStack(spacing: 18) {
                            Label(event.reportStatus.labelKey, systemImage: "waveform.path.ecg")
                            Text(event.sourceLabelKey)
                            if let date = event.reportDate ?? event.originDate {
                                Text(date.formatted(date: .abbreviated, time: .shortened))
                            }
                        }
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    }

                    Spacer()
                    Image(systemName: "chevron.right.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(event.severity.color)
                }
                .padding(36)
                .background(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(Color("CardColor"))
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(event.severity.color)
                                .frame(width: 8)
                                .padding(.vertical, 22)
                        }
                )
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
        } else if store.isLoading {
            ProgressView("platform.loading")
                .controlSize(.large)
                .frame(maxWidth: .infinity, minHeight: 240)
        } else {
            VStack(spacing: 14) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 54))
                    .foregroundStyle(.secondary)
                Text("home.empty.title")
                    .font(.title2.bold())
                Text("home.empty.body")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 240)
            .background(RoundedRectangle(cornerRadius: 30).fill(Color("CardColor")))
        }
    }

    private var recentEvents: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                if store.isShowingHistoricalFixture {
                    Label("platform.historical.reports", systemImage: "clock.arrow.circlepath")
                        .font(.title2.bold())
                } else {
                    Text("home.section.recent")
                        .font(.title2.bold())
                }
                Spacer()
                if let lastUpdated = store.lastUpdated {
                    if store.isShowingHistoricalFixture {
                        Text(lastUpdated.formatted(date: .abbreviated, time: .omitted))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(L("home.status.lastUpdated", lastUpdated.formatted(date: .omitted, time: .shortened)))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let statusMessage = store.statusMessage {
                Label(statusMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(Color("CautionColor"))
            }

            LazyVStack(spacing: 14) {
                ForEach(store.events.prefix(12)) { event in
                    NavigationLink {
                        TVEventDetailView(event: event)
                    } label: {
                        TVEventRow(event: event)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .focused($focusedEventID, equals: event.id)
                }
            }
        }
    }
}

private struct TVEventRow: View {
    let event: EEWEvent

    var body: some View {
        HStack(spacing: 24) {
            Text(event.magnitudeText)
                .font(.title.bold().monospacedDigit())
                .foregroundStyle(event.severity.color)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(width: 130)
            VStack(alignment: .leading, spacing: 7) {
                Text(event.hypocenter)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                HStack(spacing: 14) {
                    Text(event.reportStatus.labelKey)
                    Text(event.sourceLabelKey)
                    if let date = event.reportDate ?? event.originDate {
                        Text(date.formatted(date: .omitted, time: .shortened))
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if let maxIntensity = event.maxIntensity {
                Text(L("quake.intensity.label", maxIntensity))
                    .font(.headline)
            }
            Image(systemName: "chevron.right")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color("CardSecondaryColor")))
    }
}

private struct TVEventDetailView: View {
    let event: EEWEvent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Label(event.reportStatus.labelKey, systemImage: "waveform.path.ecg")
                    .font(.headline)
                    .foregroundStyle(event.severity.color)
                Text(event.hypocenter)
                    .font(.largeTitle.bold())
                HStack(alignment: .firstTextBaseline, spacing: 36) {
                    Text(event.magnitudeText)
                        .font(.system(size: 96, weight: .bold, design: .rounded))
                        .foregroundStyle(event.severity.color)
                    VStack(alignment: .leading, spacing: 12) {
                        if let maxIntensity = event.maxIntensity {
                            Label(L("quake.intensity.label", maxIntensity), systemImage: "gauge.with.dots.needle.67percent")
                        }
                        if let depth = event.depth {
                            Label(localizedDepthLabel(depth), systemImage: "arrow.down")
                        }
                        Label(event.sourceLabelKey, systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .font(.title3)
                }
                if let date = event.reportDate ?? event.originDate {
                    Label(date.formatted(date: .long, time: .standard), systemImage: "clock")
                        .font(.headline)
                }
                Text("shared.disclaimer")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 1_100, alignment: .leading)
            .padding(72)
        }
        .navigationTitle("detail.title")
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
