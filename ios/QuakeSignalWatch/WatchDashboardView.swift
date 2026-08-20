import Foundation
import SwiftUI

struct WatchDashboardView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(WatchAlertPreferenceContext.watchDefaultsKey)
    private var alertSoundRawValue = AlertSoundPreference.system.rawValue
    @State private var store = ForegroundQuakeStore()
    @State private var emergencyMonitor = WatchForegroundEmergencyMonitor()
    @State private var manualRefreshLifecycle = ForegroundManualRefreshLifecycle()
    @State private var emergencyFeedbackTrigger = 0

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
            emergencyMonitor.setSceneActive(
                scenePhase == .active && !ScreenshotAutomation.isEnabled
            )
            guard scenePhase == .active else { return }
            await store.monitorWhileActive(limit: 12)
        }
        .task(id: manualRefreshLifecycle.taskID(isSceneActive: scenePhase == .active)) {
            guard manualRefreshLifecycle.shouldRun(isSceneActive: scenePhase == .active) else { return }
            await store.refresh(limit: 12)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                emergencyMonitor.setSceneActive(!ScreenshotAutomation.isEnabled)
            } else {
                manualRefreshLifecycle.cancelPendingRefresh()
                emergencyMonitor.setSceneActive(false)
                WatchEmergencyAlertAudio.shared.stop()
            }
        }
        .onChange(of: emergencyMonitor.presentedWarning?.id) { _, warningID in
            guard warningID != nil else {
                WatchEmergencyAlertAudio.shared.stop()
                return
            }
            emergencyFeedbackTrigger &+= 1
            WatchEmergencyAlertAudio.shared.playCustomSound(for: selectedAlertSound)
        }
        .onDisappear {
            manualRefreshLifecycle.cancelPendingRefresh()
            emergencyMonitor.setSceneActive(false)
            WatchEmergencyAlertAudio.shared.stop()
        }
        .fullScreenCover(item: presentedEmergencyBinding) { presentation in
            NavigationStack {
                WatchEmergencyAlertView(
                    presentation: presentation,
                    onDismiss: {
                        emergencyMonitor.dismissPresentedWarning()
                        WatchEmergencyAlertAudio.shared.stop()
                    }
                )
            }
        }
        .sensoryFeedback(.warning, trigger: emergencyFeedbackTrigger)
    }

    private var dashboard: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        WatchContextBadges(isHistorical: store.isShowingHistoricalFixture)
                        headline
                    }
                    .frame(
                        maxWidth: .infinity,
                        minHeight: geometry.size.height,
                        alignment: .topLeading
                    )
                    .id(WatchDashboardPage.headline)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("platform.watch.foregroundOnly.short")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        WatchAlertSoundStatus(preference: selectedAlertSound)

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
                    .frame(
                        maxWidth: .infinity,
                        minHeight: geometry.size.height,
                        alignment: .topLeading
                    )
                    .id(WatchDashboardPage.controls)
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .navigationTitle("app.name")
        .navigationBarTitleDisplayMode(.inline)
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

    private var selectedAlertSound: AlertSoundPreference {
        AlertSoundPreference(rawValue: alertSoundRawValue) ?? .system
    }

    private var presentedEmergencyBinding: Binding<WatchForegroundEmergencyPresentation?> {
        Binding(
            get: { emergencyMonitor.presentedWarning },
            set: { presentation in
                if presentation == nil {
                    emergencyMonitor.dismissPresentedWarning()
                }
            }
        )
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

private enum WatchDashboardPage: Hashable {
    case headline
    case controls
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
    @FocusState private var isFocused: Bool

    private var primaryTextColor: Color {
        isFocused ? .black : .white
    }

    private var secondaryTextColor: Color {
        isFocused ? Color.black.opacity(0.72) : Color.white.opacity(0.72)
    }

    private var cardBackgroundColor: Color {
        if isFocused { return .white }
        return event.isActiveWarning
            ? Color(red: 0.55, green: 0.03, blue: 0.06)
            : Color(white: 0.16)
    }

    var body: some View {
        NavigationLink {
            WatchEventDetailView(event: event)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                if event.isActiveWarning {
                    Label("alert.badge.new", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(primaryTextColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(event.magnitudeText)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(event.severity.color)
                    Spacer(minLength: 4)
                    Text(event.reportStatus.labelKey)
                        .font(.caption2)
                        .foregroundStyle(secondaryTextColor)
                        .lineLimit(1)
                }
                Text(event.hypocenter)
                    .font(.headline)
                    .foregroundStyle(primaryTextColor)
                    .lineLimit(2)
                    .minimumScaleFactor(0.86)
                if let date = event.reportDate ?? event.originDate {
                    Text(date.formatted(date: .numeric, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(secondaryTextColor)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                cardBackgroundColor,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
        }
        .focused($isFocused)
        .buttonStyle(.plain)
        .accessibilityHint(event.isActiveWarning ? Text("alert.action.now") : Text("detail.title"))
    }
}

private struct WatchAlertSoundStatus: View {
    let preference: AlertSoundPreference

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: preference.systemImage)
                .foregroundStyle(Color("BrandColor"))
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("settings.alertSound.title")
                    .font(.caption.weight(.semibold))
                Text(LocalizedStringKey(preference.titleKey))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("platform.watch.alertSound.changeOnPhone")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct WatchReportsView: View {
    let events: [EEWEvent]
    let isHistorical: Bool
    let isLoading: Bool
    let onRefresh: () -> Void

    private var firstPageEvents: [EEWEvent] {
        Array(events.prefix(2))
    }

    private var remainingEvents: [EEWEvent] {
        Array(events.dropFirst(2).prefix(6))
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 3) {
                        WatchReportsHeader(
                            isHistorical: isHistorical,
                            isLoading: isLoading,
                            onRefresh: onRefresh
                        )

                        ForEach(firstPageEvents) { event in
                            WatchReportLink(event: event)
                        }
                    }
                    .frame(
                        maxWidth: .infinity,
                        minHeight: geometry.size.height,
                        alignment: .topLeading
                    )
                    .id(WatchReportsPage.first)

                    if !remainingEvents.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(remainingEvents) { event in
                                WatchReportLink(event: event)
                            }
                        }
                        .frame(
                            maxWidth: .infinity,
                            minHeight: geometry.size.height,
                            alignment: .topLeading
                        )
                        .id(WatchReportsPage.remaining)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .navigationTitle("app.name")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private enum WatchReportsPage: Hashable {
    case first
    case remaining
}

private struct WatchReportsHeader: View {
    let isHistorical: Bool
    let isLoading: Bool
    let onRefresh: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            VStack(alignment: .leading, spacing: 4) {
                Label("platform.foreground.badge", systemImage: "eye")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color("CautionColor"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                if isHistorical {
                    Label("platform.historical.reports", systemImage: "clock.arrow.circlepath")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                } else {
                    Text("home.section.recent")
                        .font(.caption.weight(.semibold))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onRefresh) {
                WatchRefreshControlLabel(isLoading: isLoading)
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
            .accessibilityLabel(Text("platform.refresh"))
        }
    }
}

private struct WatchRefreshControlLabel: View {
    let isLoading: Bool

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else {
                Image(systemName: "arrow.clockwise")
                    .font(.caption.weight(.semibold))
            }
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .background(
            Color.white.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }
}

private struct WatchReportLink: View {
    let event: EEWEvent
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationLink {
            WatchEventDetailView(event: event)
        } label: {
            WatchCompactEventRow(event: event, isFocused: isFocused)
        }
        .focused($isFocused)
        .buttonStyle(.plain)
    }
}

private struct WatchCompactEventRow: View {
    let event: EEWEvent
    let isFocused: Bool

    private var primaryTextColor: Color {
        isFocused ? .black : .white
    }

    private var secondaryTextColor: Color {
        isFocused ? Color.black.opacity(0.72) : Color.white.opacity(0.72)
    }

    private var cardBackgroundColor: Color {
        isFocused ? .white : Color(white: 0.16)
    }

    var body: some View {
        HStack(spacing: 7) {
            Text(event.magnitudeText)
                .font(.headline.monospacedDigit())
                .foregroundStyle(event.severity.color)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.hypocenter)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(primaryTextColor)
                    .lineLimit(2, reservesSpace: true)
                    .minimumScaleFactor(0.82)
                HStack(spacing: 5) {
                    Text(event.reportStatus.labelKey)
                    Text(event.sourceLabelKey)

                    Spacer(minLength: 1)

                    if let date = event.reportDate ?? event.originDate {
                        Text(date.formatted(date: .omitted, time: .shortened))
                    }
                }
                .font(.caption2)
                .foregroundStyle(secondaryTextColor)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            cardBackgroundColor,
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

private struct WatchEmergencyAlertView: View {
    let presentation: WatchForegroundEmergencyPresentation
    let onDismiss: () -> Void

    private var event: EEWEvent { presentation.event }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                emergencyHeader

                Label("alert.action.now", systemImage: "shield.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("M\(event.magnitudeText)")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .accessibilityLabel(
                            Text("\(String(localized: "alert.magnitudeLabel")) \(event.magnitudeText)")
                        )

                    Spacer(minLength: 2)

                    if let maxIntensity = event.maxIntensity {
                        Text(L("quake.intensity.label", maxIntensity))
                            .font(.caption.weight(.semibold))
                            .minimumScaleFactor(0.75)
                    }
                }
                .foregroundStyle(.white)

                Text(event.hypocenter)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)

                VStack(alignment: .leading, spacing: 5) {
                    safetyStep("alert.step.drop", systemImage: "arrow.down.circle.fill")
                    safetyStep("alert.step.cover", systemImage: "shield.lefthalf.filled")
                    safetyStep("alert.step.holdOn", systemImage: "hand.raised.fill")
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 12))

                Text("platform.watch.emergency.foregroundOnly")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.82))

                NavigationLink {
                    WatchEventDetailView(event: event)
                } label: {
                    Label("alert.viewDetails", systemImage: "info.circle")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(.white)

                Button(action: onDismiss) {
                    Text("alert.dismiss")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.red)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
        .containerBackground(
            LinearGradient(
                colors: [
                    Color(red: 0.58, green: 0.02, blue: 0.06),
                    Color(red: 0.28, green: 0.01, blue: 0.03),
                ],
                startPoint: .top,
                endPoint: .bottom
            ),
            for: .navigation
        )
        .navigationTitle("app.name")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var emergencyHeader: some View {
        Label(
            presentation.isUpdate ? "alert.badge.updated" : "alert.badge.new",
            systemImage: "exclamationmark.triangle.fill"
        )
        .font(.caption.weight(.heavy))
        .foregroundStyle(.white)
        .lineLimit(2)
        .minimumScaleFactor(0.76)
        .accessibilityAddTraits(.isHeader)
    }

    private func safetyStep(_ key: LocalizedStringKey, systemImage: String) -> some View {
        Label(key, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
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
