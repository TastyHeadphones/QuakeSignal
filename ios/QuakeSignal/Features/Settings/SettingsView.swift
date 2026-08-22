import SwiftUI
import UIKit

enum PushSubscriptionControlAction: Equatable {
    case none
    case remove
    case resume
    case retry

    static func resolve(
        subscriptionEnabled: Bool,
        registrationState: PushRegistrationState,
        canRegisterForRemoteNotifications: Bool
    ) -> Self {
        // Only a successful protected registration proves that there is a
        // server-side record to remove. The subscription preference defaults
        // on so the app can register after permission is granted, but that
        // intent must never be presented as an existing registration.
        if registrationState == .active {
            return .remove
        }
        if !subscriptionEnabled {
            return .resume
        }
        guard canRegisterForRemoteNotifications else {
            // The surrounding notification-permission control supplies the
            // actionable Enable/Open Settings affordance in this state.
            return .none
        }
        return registrationState.isRetryable ? .retry : .none
    }
}

enum TierChipAccessibility {
    static func traits(isSelected: Bool) -> AccessibilityTraits {
        isSelected ? .isSelected : []
    }
}

struct SettingsView: View {
    @State private var settings = AppSettings.shared
    @State private var notifications = NotificationManager.shared
    @State private var locationManager = LocationManager.shared
    @State private var isSendingTest = false
    @State private var testResultMessage: String?
#if QUAKESIGNAL_INTERNAL_QA
    @State private var isSchedulingDelayedTest = false
    @State private var delayedTestResultMessage: String?
    @State private var showingDelayedTestConfirmation = false
#endif
    @State private var isUpdatingPushSubscription = false
    @State private var pushSubscriptionMessage: String?
    @State private var pushSubscriptionMessageState: PushRegistrationState?
    @State private var showingRemovePushConfirmation = false
    @State private var showingCityPicker = false

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            if ScreenshotAutomation.isAlertPreferencesFrame(
                ScreenshotAutomation.selectedFrame
            ) {
                AlertSoundSelectionView(screenshotSelectedPreference: .japaneseVoice)
            } else {
                Form {
                Section("settings.section.subscription") {
                    Button {
                        showingCityPicker = true
                    } label: {
                        HStack {
                            Text(settings.useCurrentLocation ? "city.useCurrentLocation" : "settings.subscribedCity")
                            Spacer()
                            Text(locationSelectionDetail)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(.primary)

                    HStack(spacing: 8) {
                        ForEach(AppSettings.radiusTiersKm, id: \.self) { tier in
                            TierChip(label: "\(Int(tier)) km", isSelected: settings.radiusKm == tier) {
                                settings.radiusKm = tier
                            }
                        }
                    }
                    .listRowSeparator(.hidden)

                    Text("settings.section.threshold")
                        .font(.subheadline)
                    HStack(spacing: 8) {
                        ForEach(AppSettings.magnitudeTiers, id: \.self) { tier in
                            TierChip(label: "M\(Int(tier))+", isSelected: settings.minMagnitude == tier) {
                                settings.minMagnitude = tier
                            }
                        }
                    }
                }

                Section {
                    ForEach(AppSettings.allSources, id: \.self) { source in
                        Toggle(isOn: sourceBinding(source)) {
                            Text(NSLocalizedString("settings.source.\(source)", comment: "Earthquake data source"))
                        }
                        .disabled(
                            settings.enabledSources.count == 1 &&
                                settings.enabledSources.contains(source)
                        )
                    }
                } header: {
                    Text("settings.section.sources")
                } footer: {
                    Text("settings.sources.minimum")
                }

                Section("settings.section.notifications") {
                    if PlatformCapabilities.supportsAttestedAlertRegistration {
                        if notifications.authorizationStatus == .notDetermined {
                            Button("onboarding.enableNotifications") {
                                Task { await enableNotifications() }
                            }
                        } else if notifications.authorizationStatus == .denied {
                            Button("settings.openSystemSettings") { openNotificationSettings() }
                            if settings.pushRegistrationState == .active {
                                Text("settings.pushSubscription.permissionDenied")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        pushSubscriptionControl
                    } else {
                        Label("platform.alertRegistration.foregroundOnly", systemImage: "eye")
                            .font(.subheadline.weight(.semibold))
                        Text("platform.alertRegistration.foregroundOnly.detail")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    NavigationLink {
                        AlertSoundSelectionView()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: settings.alertSound.systemImage)
                                .foregroundStyle(Color("BrandColor"))
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("settings.alertSound.title")
                                Text(LocalizedStringKey(settings.alertSound.titleKey))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if PlatformCapabilities.supportsAttestedAlertRegistration,
                       notifications.canRegisterForRemoteNotifications,
                       (!notifications.hasVisibleAlertsEnabled ||
                        !notifications.hasSoundsEnabled ||
                        !notifications.hasTimeSensitiveAlertsEnabled) {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("settings.notificationDelivery.degraded", systemImage: "exclamationmark.triangle.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.orange)
                            Text("settings.notificationDelivery.degraded.detail")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Button("settings.openNotificationSettings") {
                                openNotificationSettings()
                            }
                        }
                    }

                    if PlatformCapabilities.supportsAttestedAlertRegistration {
                        Toggle(isOn: $settings.notifyAtNight) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("settings.notifyAtNight")
                                Text("settings.notifyAtNight.detail")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Toggle(isOn: $settings.includeTestAlerts) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("settings.includeTestAlerts")
                            Text("settings.includeTestAlerts.detail")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if PlatformCapabilities.supportsAttestedAlertRegistration {
                        Button {
                            Task { await sendTestAlert() }
                        } label: {
                            if isSendingTest {
                                ProgressView()
                            } else {
                                Text("settings.testAlert")
                            }
                        }
                        .disabled(
                            isSendingTest ||
                            !PushTestAlertPolicy.isAvailable(
                                subscriptionEnabled: settings.pushSubscriptionEnabled,
                                registrationState: settings.pushRegistrationState,
                                hasDeviceToken: notifications.deviceToken != nil
                            )
                        )

                        if let testResultMessage {
                            Text(testResultMessage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

#if QUAKESIGNAL_INTERNAL_QA
                        Button {
                            showingDelayedTestConfirmation = true
                        } label: {
                            if isSchedulingDelayedTest {
                                ProgressView()
                            } else {
                                Text("settings.delayedTestAlert")
                            }
                        }
                        .disabled(
                            isSchedulingDelayedTest ||
                            !settings.pushSubscriptionEnabled ||
                            settings.pushRegistrationState != .active ||
                            notifications.deviceToken == nil
                        )

                        Text("settings.delayedTestAlert.detail")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        if let delayedTestResultMessage {
                            Text(delayedTestResultMessage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
#endif
                    }
                }

                Section("settings.section.language") {
                    Text("settings.language.systemNote")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("settings.openSystemSettings") { openSystemSettings() }
                }

                Section("settings.section.about") {
                    Link(destination: BackendConfig.httpBaseURL.appending(path: "/privacy")) {
                        Label("settings.privacyPolicy", systemImage: "hand.raised")
                    }
                    Link(destination: BackendConfig.httpBaseURL.appending(path: "/support")) {
                        Label("settings.support", systemImage: "questionmark.circle")
                    }
                }

                Section {
                    NavigationLink("settings.section.disclaimer") {
                        SourceDisclaimerView()
                    }
                }
            }
            .navigationTitle("settings.title")
            .confirmationDialog(
                String(localized: "settings.pushSubscription.remove.confirmation.title"),
                isPresented: $showingRemovePushConfirmation,
                titleVisibility: .visible
            ) {
                Button("settings.pushSubscription.remove.confirm", role: .destructive) {
                    Task { await removePushSubscription() }
                }
                Button("settings.pushSubscription.remove.cancel", role: .cancel) {}
            } message: {
                Text("settings.pushSubscription.remove.confirmation.message")
            }
#if QUAKESIGNAL_INTERNAL_QA
            .confirmationDialog(
                String(localized: "settings.delayedTestAlert.confirmation.title"),
                isPresented: $showingDelayedTestConfirmation,
                titleVisibility: .visible
            ) {
                Button("settings.delayedTestAlert.confirm") {
                    Task { await scheduleDelayedTestAlert() }
                }
                Button("settings.pushSubscription.remove.cancel", role: .cancel) {}
            } message: {
                Text("settings.delayedTestAlert.confirmation.message")
            }
#endif
            .sheet(isPresented: $showingCityPicker) {
                CityPickerView()
            }
            .onChange(of: settings.pushRegistrationState) { _, _ in
                // Keep a result produced by the manual operation that just
                // completed, but retire a message whose tagged state no
                // longer matches an external or centralized resync outcome.
                guard pushSubscriptionMessageState != settings.pushRegistrationState else {
                    return
                }
                setPushSubscriptionMessage(nil)
            }
            .onChange(of: settings.pushRegistrationPreferencesRevision) { _, _ in
                setPushSubscriptionMessage(nil)
            }
        }
    }

    }

    private func sourceBinding(_ source: String) -> Binding<Bool> {
        Binding(
            get: { settings.enabledSources.contains(source) },
            set: { isOn in
                if isOn {
                    settings.enabledSources.insert(source)
                } else {
                    settings.enabledSources.remove(source)
                }
            }
        )
    }

    private var locationSelectionDetail: String {
        guard settings.useCurrentLocation else {
            return settings.selectedCity?.localizedName ?? String(localized: "city.none")
        }
        return locationManager.selectionStatus.localizedDetail(
            fallbackCityName: settings.selectedCity?.localizedName
        )
    }

    private func setPushSubscriptionMessage(_ message: String?) {
        pushSubscriptionMessage = message
        pushSubscriptionMessageState = message == nil ? nil : settings.pushRegistrationState
    }

    @ViewBuilder
    private var pushSubscriptionControl: some View {
        switch PushSubscriptionControlAction.resolve(
            subscriptionEnabled: settings.pushSubscriptionEnabled,
            registrationState: settings.pushRegistrationState,
            canRegisterForRemoteNotifications: notifications.canRegisterForRemoteNotifications
        ) {
        case .remove:
            // Server-side deletion is authenticated by App Attest. An active
            // state is persisted only after the Worker accepts registration,
            // so this destructive action never appears for a fresh install.
            Button(role: .destructive) {
                showingRemovePushConfirmation = true
            } label: {
                Group {
                    if isUpdatingPushSubscription {
                        ProgressView()
                    } else {
                        Text("settings.pushSubscription.remove")
                    }
                }
            }
            .disabled(isUpdatingPushSubscription)

            Text("settings.pushSubscription.remove.detail")
                .font(.footnote)
                .foregroundStyle(.secondary)

            pushRegistrationStatus
        case .retry:
            pushRegistrationStatus

            Button {
                Task { await retryPushRegistration() }
            } label: {
                Group {
                    if isUpdatingPushSubscription {
                        ProgressView()
                    } else {
                        Text("settings.pushSubscription.retry")
                    }
                }
            }
            .disabled(isUpdatingPushSubscription)

            if notifications.deviceToken == nil {
                Text("settings.pushSubscription.waiting")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .resume:
            Button {
                Task { await resumePushSubscription() }
            } label: {
                Group {
                    if isUpdatingPushSubscription {
                        ProgressView()
                    } else {
                        Text("settings.pushSubscription.resume")
                    }
                }
            }
            .disabled(isUpdatingPushSubscription || !notifications.canRegisterForRemoteNotifications)

            Text("settings.pushSubscription.resume.detail")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .none:
            if settings.pushSubscriptionEnabled {
                pushRegistrationStatus
            }
        }

        if let pushSubscriptionMessage {
            Text(pushSubscriptionMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var pushRegistrationStatus: some View {
        switch settings.pushRegistrationState {
        case .unregistered:
            Text("settings.pushSubscription.status.unregistered")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .registering:
            Label("settings.pushSubscription.status.registering", systemImage: "arrow.triangle.2.circlepath")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .active:
            Label("settings.pushSubscription.status.active", systemImage: "checkmark.circle")
                .font(.footnote)
                .foregroundStyle(.green)
        case .failed:
            Label("settings.pushSubscription.status.failed", systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    private func enableNotifications() async {
        guard PlatformCapabilities.supportsAttestedAlertRegistration else { return }
        let granted = await notifications.requestAuthorization()
        guard granted else { return }
        await resumePushSubscription()
    }

    private func resumePushSubscription() async {
        guard PlatformCapabilities.supportsAttestedAlertRegistration,
              notifications.canRegisterForRemoteNotifications else { return }
        isUpdatingPushSubscription = true
        setPushSubscriptionMessage(nil)
        settings.pushSubscriptionEnabled = true
        settings.pushRegistrationState = .unregistered
        notifications.registerForRemoteNotificationsIfAuthorized()

        if let token = notifications.deviceToken {
            do {
                try await QuakeStore.shared.registerForPush(token: token)
                setPushSubscriptionMessage(String(localized: "settings.pushSubscription.resume.success"))
            } catch {
                setPushSubscriptionMessage(L("settings.pushSubscription.resume.failure", error.localizedDescription))
            }
        } else {
            setPushSubscriptionMessage(String(localized: "settings.pushSubscription.waiting"))
        }
        isUpdatingPushSubscription = false
    }

    private func retryPushRegistration() async {
        guard PlatformCapabilities.supportsAttestedAlertRegistration,
              settings.pushSubscriptionEnabled else { return }
        isUpdatingPushSubscription = true
        setPushSubscriptionMessage(nil)
        notifications.registerForRemoteNotificationsIfAuthorized()

        guard notifications.canRegisterForRemoteNotifications,
              let token = notifications.deviceToken else {
            setPushSubscriptionMessage(String(localized: "settings.pushSubscription.waiting"))
            isUpdatingPushSubscription = false
            return
        }

        do {
            try await QuakeStore.shared.registerForPush(token: token)
            setPushSubscriptionMessage(String(localized: "settings.pushSubscription.retry.success"))
        } catch {
            setPushSubscriptionMessage(L("settings.pushSubscription.retry.failure", error.localizedDescription))
        }
        isUpdatingPushSubscription = false
    }

    private func removePushSubscription() async {
        isUpdatingPushSubscription = true
        setPushSubscriptionMessage(nil)
        do {
            try await QuakeStore.shared.unregisterForPush(token: notifications.deviceToken)
            notifications.clearDeviceToken()
            setPushSubscriptionMessage(String(localized: "settings.pushSubscription.remove.success"))
        } catch {
            setPushSubscriptionMessage(L("settings.pushSubscription.remove.failure", error.localizedDescription))
        }
        isUpdatingPushSubscription = false
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func openNotificationSettings() {
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else {
            openSystemSettings()
            return
        }
        UIApplication.shared.open(url)
    }

    private func sendTestAlert() async {
        guard PlatformCapabilities.supportsAttestedAlertRegistration,
              PushTestAlertPolicy.isAvailable(
                  subscriptionEnabled: settings.pushSubscriptionEnabled,
                  registrationState: settings.pushRegistrationState,
                  hasDeviceToken: notifications.deviceToken != nil
              ),
              let token = notifications.deviceToken else {
            return
        }
        isSendingTest = true
        testResultMessage = nil
        do {
            if settings.pushRegistrationState != .active {
                try await QuakeStore.shared.registerForPush(token: token)
            }
            do {
                try await APIClient.shared.sendTestAlert(token: token)
            } catch {
                guard PushTestAlertPolicy.shouldRepairRegistration(after: error) else {
                    throw error
                }
                // A fresh registration is the ownership hand-off for a
                // replacement App Attest key. Only after that succeeds may the
                // test endpoint use the new key to address this APNs token.
                try await QuakeStore.shared.registerForPush(token: token)
                try await APIClient.shared.sendTestAlert(token: token)
            }
            testResultMessage = String(localized: "settings.testAlert.success")
        } catch {
            testResultMessage = L("settings.testAlert.failure", error.localizedDescription)
        }
        isSendingTest = false
    }

#if QUAKESIGNAL_INTERNAL_QA
    private func scheduleDelayedTestAlert() async {
        guard PlatformCapabilities.supportsAttestedAlertRegistration,
              settings.pushRegistrationState == .active,
              let token = notifications.deviceToken else {
            return
        }
        isSchedulingDelayedTest = true
        delayedTestResultMessage = nil
        defer { isSchedulingDelayedTest = false }
        do {
            try await APIClient.shared.scheduleDelayedTestAlert(token: token)
            delayedTestResultMessage = String(localized: "settings.delayedTestAlert.success")
        } catch {
            delayedTestResultMessage = L(
                "settings.delayedTestAlert.failure",
                error.localizedDescription
            )
        }
    }
#endif
}

private struct AlertSoundSelectionView: View {
    @State private var settings = AppSettings.shared
    let screenshotSelectedPreference: AlertSoundPreference?

    init(screenshotSelectedPreference: AlertSoundPreference? = nil) {
        self.screenshotSelectedPreference = screenshotSelectedPreference
    }

    var body: some View {
        @Bindable var settings = settings

        List {
            if screenshotSelectedPreference != nil {
                Text("Alert Sound")
                    .font(.title2.weight(.heavy))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                Text("Japanese Safety Voice")
                    .font(.title2.weight(.heavy))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
                Text("CC BY 3.0")
                    .font(.title2.weight(.heavy))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 8)
            }

            Section {
                ForEach(AlertSoundPreference.allCases, id: \.self) { preference in
                    Button {
                        if screenshotSelectedPreference == nil {
                            settings.alertSound = preference
                        }
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: preference.systemImage)
                                .font(.title3)
                                .visionFont(.title2)
                                .foregroundStyle(Color("BrandColor"))
                                .frame(width: optionIconSize, height: optionIconSize)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(LocalizedStringKey(preference.titleKey))
                                    .font(.body.weight(.medium))
                                    .visionFont(.title3.weight(.semibold))
                                    .foregroundStyle(.primary)
                                if preference == .japaneseVoice {
                                    Text("CC BY 3.0")
                                        // Keep the license attribution legible in the
                                        // native iPad screenshot capture. The regular
                                        // supporting-text treatment is too faint for
                                        // OCR at the 13-inch capture scale.
                                        .font(.title2.weight(.bold))
                                        .visionFont(.title3.weight(.semibold))
                                        .foregroundStyle(.primary)
                                }
                                Text(LocalizedStringKey(preference.detailKey))
                                    .font(.caption)
                                    .visionFont(.body)
                                    .visionSupportingText()
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 8)
                            if selectedPreference == preference {
                                Image(systemName: "checkmark.circle.fill")
                                    .visionFont(.title3)
                                    .foregroundStyle(Color("BrandColor"))
                                    .accessibilityHidden(true)
                            }
                        }
                        .padding(.vertical, optionVerticalPadding)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedPreference == preference ? .isSelected : [])
                    .visionReadableRow()
                }
            }

            Section {
                Button {
                    EmergencyAlertAudio.shared.preview(selectedPreference)
                } label: {
                    Label("settings.alertSound.preview", systemImage: "play.circle.fill")
                        .visionFont(.title3.weight(.semibold))
                }
                .visionReadableRow(minimumHeight: 76)
            }

            Section {
                Label("settings.alertSound.disclosure", systemImage: "info.circle")
                    .font(.footnote)
                    .visionFont(.body)
                    .visionSupportingText()
                    .visionReadableRow(minimumHeight: 96)
            }
        }
        .visionReadableListSurface(
            minimumRowHeight: VisionReadabilityMetrics.alertSoundMinimumRowHeight
        )
        .navigationTitle("settings.alertSound.title")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            EmergencyAlertAudio.shared.stopPreview()
        }
    }

    private var selectedPreference: AlertSoundPreference {
        screenshotSelectedPreference ?? settings.alertSound
    }

    private var optionIconSize: CGFloat {
#if os(visionOS)
        38
#else
        30
#endif
    }

    private var optionVerticalPadding: CGFloat {
#if os(visionOS)
        10
#else
        5
#endif
    }
}

private struct TierChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Capsule().fill(isSelected ? Color("BrandColor") : Color("GroupedBGColor")))
                .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
        // VoiceOver localizes and announces the native selected state; the
        // visible label remains the chip's accessible name.
        .accessibilityAddTraits(TierChipAccessibility.traits(isSelected: isSelected))
    }
}
