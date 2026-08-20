import SwiftUI

struct TVEmergencyAlertView: View {
    let warning: TVPresentedWarning
    let selectedSound: AlertSoundPreference
    let playUserInitiated: (AlertSoundPreference) -> TVAlertAudioPlaybackResult
    let stopPlayback: () -> Void
    let onDismiss: () -> Void

    @FocusState private var focusedAction: Action?
    @State private var playbackResult: TVAlertAudioPlaybackResult?

    private enum Action: Hashable {
        case playSound
        case dismiss
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [backgroundColor, backgroundColor.opacity(0.72), .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    alertHeader

                    HStack(alignment: .top, spacing: 48) {
                        safetyInstructions
                        eventSummary
                    }

                    controls

                    Text("shared.disclaimer")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.76))
                        .frame(maxWidth: 1_260, alignment: .leading)
                }
                .frame(maxWidth: 1_460, alignment: .leading)
                .padding(.horizontal, 84)
                .padding(.vertical, 54)
            }
        }
        .foregroundStyle(.white)
        .accessibilityAddTraits(.isModal)
        .task(id: warning.id) {
            playbackResult = nil
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            focusedAction = TVAlertAudioPolicy.permitsUserInitiatedPlayback(selectedSound)
                ? .playSound
                : .dismiss
        }
        .onExitCommand {
            stopPlayback()
            onDismiss()
        }
        .onDisappear(perform: stopPlayback)
    }

    private var alertHeader: some View {
        HStack(alignment: .center, spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 58, weight: .bold))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 7) {
                Text(headerKey)
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("alert.action.now")
                    .font(.title2.bold())
            }

            Spacer()

            Label("platform.foreground.badge", systemImage: "tv")
                .font(.headline)
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(Capsule().fill(.black.opacity(0.24)))
        }
    }

    private var safetyInstructions: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("platform.tv.alert.safetyTitle")
                .font(.title.bold())
                .accessibilityAddTraits(.isHeader)

            HStack(spacing: 18) {
                safetyStep(symbol: "arrow.down.to.line", key: "alert.step.drop")
                safetyStep(symbol: "shield.lefthalf.filled", key: "alert.step.cover")
                safetyStep(symbol: "hand.raised.fill", key: "alert.step.holdOn")
            }

            VStack(alignment: .leading, spacing: 13) {
                Label("alert.warning.windows", systemImage: "window.vertical.closed")
                Label("alert.warning.elevator", systemImage: "xmark.octagon.fill")
            }
            .font(.title3.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(30)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.black.opacity(0.22))
        )
    }

    private func safetyStep(
        symbol: String,
        key: LocalizedStringKey
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 42, weight: .bold))
                .frame(width: 82, height: 82)
                .background(Circle().fill(.white.opacity(0.15)))
                .accessibilityHidden(true)
            Text(key)
                .font(.title3.bold())
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(key))
    }

    private var eventSummary: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(warning.event.magnitudeText)
                        .font(.system(size: 104, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("alert.magnitudeLabel")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.76))
                }

                if let intensity = warning.event.maxIntensity {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(intensity)
                            .font(.system(size: 54, weight: .bold, design: .rounded))
                        Text("alert.intensityLabel")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.76))
                    }
                }
            }

            Text(warning.event.hypocenter)
                .font(.title.bold())
                .lineLimit(2)
                .minimumScaleFactor(0.76)

            VStack(alignment: .leading, spacing: 10) {
                if let depth = warning.event.depth {
                    Label(tvLocalizedDepthLabel(depth), systemImage: "arrow.down")
                }
                Label(warning.event.sourceLabelKey, systemImage: "antenna.radiowaves.left.and.right")
                if let date = warning.event.reportDate ?? warning.event.originDate {
                    Label(
                        date.formatted(date: .abbreviated, time: .standard),
                        systemImage: "clock"
                    )
                }
            }
            .font(.headline)
            .foregroundStyle(.white.opacity(0.86))
        }
        .frame(maxWidth: 570, alignment: .leading)
        .padding(30)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.black.opacity(0.28))
        )
        .accessibilityElement(children: .combine)
    }

    private var controls: some View {
        HStack(spacing: 22) {
            if TVAlertAudioPolicy.permitsUserInitiatedPlayback(selectedSound) {
                Button {
                    playbackResult = playUserInitiated(selectedSound)
                } label: {
                    Label("platform.tv.alert.playSelectedSound", systemImage: "play.fill")
                        .frame(minWidth: 330)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(backgroundColor)
                .focused($focusedAction, equals: .playSound)
                .accessibilityHint(Text("platform.tv.alert.playSelectedSound.hint"))
            } else {
                Label("platform.tv.alertSound.system.visualOnly", systemImage: "eye.fill")
                    .font(.headline)
                    .padding(.horizontal, 20)
            }

            Button {
                stopPlayback()
                onDismiss()
            } label: {
                Label("alert.dismiss", systemImage: "xmark")
                    .frame(minWidth: 220)
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .focused($focusedAction, equals: .dismiss)

            if let playbackResult {
                Label(
                    playbackStatusKey(playbackResult),
                    systemImage: playbackResult == .played
                        ? "speaker.wave.2.fill"
                        : "exclamationmark.triangle.fill"
                )
                .font(.headline)
            }

            Spacer()

            Label(
                LocalizedStringKey(selectedSound.titleKey),
                systemImage: selectedSound.systemImage
            )
            .font(.headline)
            .foregroundStyle(.white.opacity(0.82))
        }
        .controlSize(.large)
    }

    private var backgroundColor: Color {
        switch warning.event.severity {
        case .minor:
            Color(red: 0.04, green: 0.23, blue: 0.46)
        case .moderate:
            Color(red: 0.43, green: 0.22, blue: 0.01)
        case .strong:
            Color(red: 0.50, green: 0.13, blue: 0.01)
        case .severe:
            Color(red: 0.50, green: 0.02, blue: 0.05)
        case .cancelled:
            Color(red: 0.15, green: 0.15, blue: 0.17)
        }
    }

    private var headerKey: LocalizedStringKey {
        warning.reason == .updated ? "alert.badge.updated" : "alert.badge.new"
    }

    private func playbackStatusKey(
        _ result: TVAlertAudioPlaybackResult
    ) -> LocalizedStringKey {
        switch result {
        case .played:
            "platform.tv.alertSound.previewPlaying"
        case .visualOnly:
            "platform.tv.alertSound.system.visualOnly"
        case .unavailable:
            "platform.tv.alertSound.previewUnavailable"
        }
    }
}

private func tvLocalizedDepthLabel(_ depth: Double) -> String {
    let depthText = String(
        format: "%.0f",
        locale: Locale(identifier: "en_US_POSIX"),
        depth
    )
    return L("quake.depth.label", depthText)
}
