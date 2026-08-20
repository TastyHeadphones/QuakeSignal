import Foundation
import SwiftUI

struct TVDashboardView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = ForegroundQuakeStore()
    @State private var manualRefreshLifecycle = ForegroundManualRefreshLifecycle()
    @State private var emergencyMonitor = TVEmergencyMonitor()
    @State private var alertPreferences = TVAlertPreferences()
    @State private var alertAudio = TVUserInitiatedAlertAudio()

    var body: some View {
        ZStack {
            NavigationStack {
                if ScreenshotAutomation.selectedFrame == .tvEventDetail,
                   let event = store.headlineEvent {
                    TVEventDetailView(event: event)
                } else if ScreenshotAutomation.selectedFrame == .tvRecentReports {
                    recentReportsDestination
                } else {
                    dashboard
                }
            }
            .disabled(emergencyMonitor.presentedWarning != nil)
            .accessibilityHidden(emergencyMonitor.presentedWarning != nil)

            if let warning = emergencyMonitor.presentedWarning {
                TVEmergencyAlertView(
                    warning: warning,
                    selectedSound: alertPreferences.alertSound,
                    playUserInitiated: alertAudio.playUserInitiated,
                    stopPlayback: alertAudio.stop,
                    onDismiss: emergencyMonitor.dismissPresentedWarning
                )
                .transition(.opacity.combined(with: .scale(scale: 0.985)))
                .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.2), value: emergencyMonitor.presentedWarning?.id)
        .onChange(of: emergencyMonitor.presentedWarning?.id) { _, warningID in
            // A user-started preview must not bleed into a subsequently received
            // warning and look like automatic alert playback.
            if warningID != nil {
                alertAudio.stop()
            }
        }
        .task(id: scenePhase) {
            let shouldMonitor = scenePhase == .active && !ScreenshotAutomation.isEnabled
            emergencyMonitor.setSceneActive(shouldMonitor)
            guard scenePhase == .active else { return }
            await store.monitorWhileActive()
        }
        .task(id: manualRefreshLifecycle.taskID(isSceneActive: scenePhase == .active)) {
            guard manualRefreshLifecycle.shouldRun(isSceneActive: scenePhase == .active) else { return }
            await store.refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                emergencyMonitor.setSceneActive(!ScreenshotAutomation.isEnabled)
            } else {
                manualRefreshLifecycle.cancelPendingRefresh()
                emergencyMonitor.setSceneActive(false)
                alertAudio.stop()
            }
        }
        .onDisappear {
            manualRefreshLifecycle.cancelPendingRefresh()
            emergencyMonitor.setSceneActive(false)
            alertAudio.stop()
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
                dashboardContent
                    .padding(.horizontal, 72)
                    .padding(.vertical, 54)
            }
        }
    }

    private var dashboardContent: some View {
        VStack(alignment: .leading, spacing: 34) {
            header
            headline
            recentEvents
        }
        .frame(maxWidth: 1_420, alignment: .leading)
    }

    private var recentReportsDestination: some View {
        TVRecentReportsView(
            events: Array(store.events.prefix(12)),
            isLoading: store.isLoading,
            statusMessage: store.statusMessage,
            lastUpdated: store.lastUpdated,
            isShowingHistoricalFixture: store.isShowingHistoricalFixture,
            onRefresh: {
                manualRefreshLifecycle.requestRefresh(isSceneActive: scenePhase == .active)
            }
        )
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

            HStack(spacing: 16) {
                NavigationLink {
                    soundPreferencesDestination
                } label: {
                    Label("settings.alertSound.title", systemImage: "speaker.wave.2.fill")
                        .frame(minWidth: 210)
                }
                .buttonStyle(.bordered)

                Button {
                    manualRefreshLifecycle.requestRefresh(isSceneActive: scenePhase == .active)
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
    }

    private var soundPreferencesDestination: some View {
        TVAlertSoundSettingsView(
            preferences: alertPreferences,
            playUserInitiated: alertAudio.playUserInitiated,
            stopPlayback: alertAudio.stop
        )
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
                NavigationLink {
                    recentReportsDestination
                } label: {
                    HStack(spacing: 12) {
                        if store.isShowingHistoricalFixture {
                            Label("platform.historical.reports", systemImage: "clock.arrow.circlepath")
                        } else {
                            Label("home.section.recent", systemImage: "list.bullet")
                        }
                        Image(systemName: "chevron.right.circle.fill")
                            .foregroundStyle(Color("CautionColor"))
                    }
                    .font(.title2.bold())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)

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
                }
            }
        }
    }
}

private struct TVRecentReportsView: View {
    let events: [EEWEvent]
    let isLoading: Bool
    let statusMessage: String?
    let lastUpdated: Date?
    let isShowingHistoricalFixture: Bool
    let onRefresh: () -> Void

    @FocusState private var focusedEventID: EEWEvent.ID?
    @State private var didAssignInitialFocus = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color("GroupedBGColor"), Color("TintBGColor")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 26) {
                reportsHeader

                if let statusMessage {
                    Label(statusMessage, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(Color("CautionColor"))
                }

                if events.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: reportColumns, spacing: 20) {
                        ForEach(events) { event in
                            NavigationLink {
                                TVEventDetailView(event: event)
                            } label: {
                                TVReportCard(
                                    event: event,
                                    isFocused: focusedEventID == event.id
                                )
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.primary)
                            .focused($focusedEventID, equals: event.id)
                        }
                    }
                }
            }
            .frame(maxWidth: 1_420, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 72)
            .padding(.vertical, 42)
        }
        .task(id: events.first?.id) {
            guard !didAssignInitialFocus,
                  let firstEventID = events.first?.id else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            didAssignInitialFocus = true
            focusedEventID = firstEventID
        }
    }

    private var reportColumns: [GridItem] {
        let columnCount = events.count <= 4 ? 2 : 3
        return Array(
            repeating: GridItem(.flexible(), spacing: 20, alignment: .top),
            count: columnCount
        )
    }

    private var reportsHeader: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
                if isShowingHistoricalFixture {
                    Label("platform.historical.reports", systemImage: "clock.arrow.circlepath")
                } else {
                    Label("home.section.recent", systemImage: "list.bullet")
                }
                Text("platform.tv.foregroundOnly.detail")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 760, alignment: .leading)
            }
            .font(.largeTitle.bold())

            Spacer()

            VStack(alignment: .trailing, spacing: 12) {
                if let lastUpdated {
                    if isShowingHistoricalFixture {
                        Text(lastUpdated.formatted(date: .abbreviated, time: .omitted))
                    } else {
                        Text(L(
                            "home.status.lastUpdated",
                            lastUpdated.formatted(date: .omitted, time: .shortened)
                        ))
                    }
                }

                Button(action: onRefresh) {
                    if isLoading {
                        ProgressView()
                            .frame(minWidth: 160)
                    } else {
                        Label("platform.refresh", systemImage: "arrow.clockwise")
                            .frame(minWidth: 160)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color("CautionColor"))
                .disabled(isLoading)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 54))
                .foregroundStyle(.secondary)
            Text("home.empty.title")
                .font(.title2.bold())
            Text("home.empty.body")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .background(RoundedRectangle(cornerRadius: 30).fill(Color("CardColor")))
    }
}

private struct TVReportCard: View {
    let event: EEWEvent
    let isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(event.magnitudeText)
                    .font(.title.bold().monospacedDigit())
                    .foregroundStyle(event.severity.color)
                Spacer()
                if let maxIntensity = event.maxIntensity {
                    Text(L("quake.intensity.label", maxIntensity))
                        .font(.headline)
                }
            }

            Text(event.hypocenter)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            HStack(spacing: 10) {
                Text(event.reportStatus.labelKey)
                Text(event.sourceLabelKey)
                Spacer(minLength: 8)
                if let date = event.reportDate ?? event.originDate {
                    Text(date.formatted(date: .omitted, time: .shortened))
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.78)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color("CardSecondaryColor"))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(
                    isFocused ? Color("CautionColor") : .clear,
                    lineWidth: 6
                )
        }
        .animation(.easeOut(duration: 0.15), value: isFocused)
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
