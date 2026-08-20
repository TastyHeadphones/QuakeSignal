import SwiftUI

struct TVAlertSoundSettingsView: View {
    @Bindable var preferences: TVAlertPreferences
    let playUserInitiated: (AlertSoundPreference) -> TVAlertAudioPlaybackResult
    let stopPlayback: () -> Void

    @FocusState private var focusedSoundValue: String?
    @State private var playbackResult: TVAlertAudioPlaybackResult?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color("GroupedBGColor"), Color("TintBGColor")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    header
                    soundChoices
                    playbackControl
                    Text("platform.tv.alertSound.disclosure")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 1_180, alignment: .leading)
                }
                .frame(maxWidth: 1_420, alignment: .leading)
                .padding(.horizontal, 72)
                .padding(.vertical, 48)
            }
        }
        .navigationTitle("settings.alertSound.title")
        .task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            focusedSoundValue = preferences.alertSound.rawValue
        }
        .onDisappear(perform: stopPlayback)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("settings.alertSound.title", systemImage: "speaker.wave.2.fill")
                .font(.largeTitle.bold())
            Label("platform.foreground.badge", systemImage: "tv")
                .font(.headline)
                .foregroundStyle(Color("CautionColor"))
            Text("platform.tv.alertSound.detail")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 1_100, alignment: .leading)
        }
    }

    private var soundChoices: some View {
        HStack(alignment: .top, spacing: 22) {
            ForEach(AlertSoundPreference.allCases, id: \.rawValue) { preference in
                soundChoice(preference)
            }
        }
    }

    private func soundChoice(_ preference: AlertSoundPreference) -> some View {
        let isSelected = preferences.alertSound == preference
        let isFocused = focusedSoundValue == preference.rawValue

        return Button {
            stopPlayback()
            playbackResult = nil
            preferences.alertSound = preference
        } label: {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: preference.systemImage)
                        .font(.system(size: 42, weight: .semibold))
                        .accessibilityHidden(true)
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(isSelected ? Color("CautionColor") : .secondary)
                        .accessibilityHidden(true)
                }
                Text(LocalizedStringKey(preference.titleKey))
                    .font(.title2.bold())
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Text(detailKey(for: preference))
                    .font(.callout)
                    .foregroundStyle(isFocused ? Color.black.opacity(0.72) : Color.secondary)
                    .lineLimit(4)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)
            .padding(26)
            .foregroundStyle(isFocused ? Color.black : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(isFocused ? .white : Color("CardSecondaryColor"))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(
                        isSelected ? Color("CautionColor") : .clear,
                        lineWidth: isSelected ? 6 : 0
                    )
            }
            .shadow(color: isFocused ? .black.opacity(0.3) : .clear, radius: 18, y: 10)
            .scaleEffect(isFocused ? 1.035 : 1)
            .animation(.easeOut(duration: 0.16), value: isFocused)
        }
        .buttonStyle(.plain)
        .focused($focusedSoundValue, equals: preference.rawValue)
        .accessibilityValue(Text(LocalizedStringKey(
            isSelected
                ? "platform.tv.alertSound.selected"
                : "platform.tv.alertSound.notSelected"
        )))
    }

    @ViewBuilder
    private var playbackControl: some View {
        if TVAlertAudioPolicy.permitsUserInitiatedPlayback(preferences.alertSound) {
            HStack(spacing: 24) {
                Button {
                    playbackResult = playUserInitiated(preferences.alertSound)
                } label: {
                    Label("settings.alertSound.preview", systemImage: "play.fill")
                        .frame(minWidth: 280)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color("CautionColor"))

                if let playbackResult {
                    Label(
                        playbackStatusKey(playbackResult),
                        systemImage: playbackResult == .played
                            ? "speaker.wave.2.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    .font(.headline)
                    .foregroundStyle(playbackResult == .played ? .secondary : Color("CautionColor"))
                }
            }
        } else {
            Label("platform.tv.alertSound.system.visualOnly", systemImage: "eye.fill")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }

    private func detailKey(for preference: AlertSoundPreference) -> LocalizedStringKey {
        preference == .system
            ? "platform.tv.alertSound.system.detail"
            : LocalizedStringKey(preference.detailKey)
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
