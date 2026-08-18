import SwiftUI
import UIKit

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
    @State private var isSynchronizingPushPreferences = false
    @State private var needsPushPreferenceResync = false
    @State private var pushSubscriptionMessage: String?
    @State private var showingRemovePushConfirmation = false
    @State private var showingCityPicker = false

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
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

                Section("settings.section.sources") {
                    ForEach(AppSettings.allSources, id: \.self) { source in
                        Toggle(isOn: sourceBinding(source)) {
                            Text(NSLocalizedString("settings.source.\(source)", comment: "Earthquake data source"))
                        }
                    }
                }

                Section("settings.section.notifications") {
                    if notifications.authorizationStatus == .notDetermined {
                        Button("onboarding.enableNotifications") {
                            Task { await enableNotifications() }
                        }
                    } else if notifications.authorizationStatus == .denied {
                        Button("settings.openSystemSettings") { openNotificationSettings() }
                        Text("settings.pushSubscription.permissionDenied")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    pushSubscriptionControl

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

                    if notifications.canRegisterForRemoteNotifications,
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

                    Toggle("settings.notifyAtNight", isOn: $settings.notifyAtNight)
                    Toggle(isOn: $settings.includeTestAlerts) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("settings.includeTestAlerts")
                            Text("settings.includeTestAlerts.detail")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

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
            .onChange(of: settings.minMagnitude) { _, _ in resyncPushPreferences() }
            .onChange(of: settings.notifyAtNight) { _, _ in resyncPushPreferences() }
            .onChange(of: settings.includeTestAlerts) { _, _ in resyncPushPreferences() }
            .onChange(of: settings.alertSound) { _, _ in resyncPushPreferences() }
            .onChange(of: settings.radiusKm) { _, _ in resyncPushPreferences() }
            .onChange(of: settings.selectedCityId) { _, _ in resyncPushPreferences() }
            .onChange(of: settings.useCurrentLocation) { _, _ in resyncPushPreferences() }
            .sheet(isPresented: $showingCityPicker) {
                CityPickerView()
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
                resyncPushPreferences()
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

    private func resyncPushPreferences() {
        guard settings.pushSubscriptionEnabled,
              notifications.canRegisterForRemoteNotifications,
              notifications.deviceToken != nil else {
            return
        }

        // Multiple controls can change in one interaction. Keep only one
        // protected request in flight, then send a follow-up with the latest
        // saved preferences if another change occurred while it was running.
        needsPushPreferenceResync = true
        guard !isSynchronizingPushPreferences else { return }
        isSynchronizingPushPreferences = true

        Task { @MainActor in
            defer { isSynchronizingPushPreferences = false }

            while needsPushPreferenceResync {
                needsPushPreferenceResync = false
                guard settings.pushSubscriptionEnabled,
                      notifications.canRegisterForRemoteNotifications,
                      let token = notifications.deviceToken else {
                    return
                }

                do {
                    try await QuakeStore.shared.registerForPush(token: token)
                    pushSubscriptionMessage = nil
                } catch {
                    // `QuakeStore` has already persisted `.failed`; retain a
                    // human-readable reason in this settings session and
                    // leave the retry affordance visible.
                    pushSubscriptionMessage = L(
                        "settings.pushSubscription.sync.failure",
                        error.localizedDescription
                    )
                    return
                }
            }
        }
    }

    @ViewBuilder
    private var pushSubscriptionControl: some View {
        if settings.pushSubscriptionEnabled {
            // Server-side deletion is authenticated by App Attest. It remains
            // available if APNs has not provided a token in this app session;
            // the Worker then removes the registration for that credential.
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

            if settings.pushRegistrationState.isRetryable {
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
                .disabled(isUpdatingPushSubscription || !notifications.canRegisterForRemoteNotifications)

                if notifications.deviceToken == nil,
                   notifications.canRegisterForRemoteNotifications {
                    Text("settings.pushSubscription.waiting")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
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
        let granted = await notifications.requestAuthorization()
        guard granted else { return }
        await resumePushSubscription()
    }

    private func resumePushSubscription() async {
        guard notifications.canRegisterForRemoteNotifications else { return }
        isUpdatingPushSubscription = true
        pushSubscriptionMessage = nil
        settings.pushSubscriptionEnabled = true
        settings.pushRegistrationState = .unregistered
        notifications.registerForRemoteNotificationsIfAuthorized()

        if let token = notifications.deviceToken {
            do {
                try await QuakeStore.shared.registerForPush(token: token)
                pushSubscriptionMessage = String(localized: "settings.pushSubscription.resume.success")
            } catch {
                pushSubscriptionMessage = L("settings.pushSubscription.resume.failure", error.localizedDescription)
            }
        } else {
            pushSubscriptionMessage = String(localized: "settings.pushSubscription.waiting")
        }
        isUpdatingPushSubscription = false
    }

    private func retryPushRegistration() async {
        guard settings.pushSubscriptionEnabled else { return }
        isUpdatingPushSubscription = true
        pushSubscriptionMessage = nil
        notifications.registerForRemoteNotificationsIfAuthorized()

        guard notifications.canRegisterForRemoteNotifications,
              let token = notifications.deviceToken else {
            pushSubscriptionMessage = String(localized: "settings.pushSubscription.waiting")
            isUpdatingPushSubscription = false
            return
        }

        do {
            try await QuakeStore.shared.registerForPush(token: token)
            pushSubscriptionMessage = String(localized: "settings.pushSubscription.retry.success")
        } catch {
            pushSubscriptionMessage = L("settings.pushSubscription.retry.failure", error.localizedDescription)
        }
        isUpdatingPushSubscription = false
    }

    private func removePushSubscription() async {
        isUpdatingPushSubscription = true
        pushSubscriptionMessage = nil
        do {
            try await QuakeStore.shared.unregisterForPush(token: notifications.deviceToken)
            notifications.clearDeviceToken()
            pushSubscriptionMessage = String(localized: "settings.pushSubscription.remove.success")
        } catch {
            pushSubscriptionMessage = L("settings.pushSubscription.remove.failure", error.localizedDescription)
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
        guard PushTestAlertPolicy.isAvailable(
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
        guard settings.pushRegistrationState == .active,
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

    var body: some View {
        @Bindable var settings = settings

        List {
            Section {
                ForEach(AlertSoundPreference.allCases, id: \.self) { preference in
                    Button {
                        settings.alertSound = preference
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: preference.systemImage)
                                .font(.title3)
                                .foregroundStyle(Color("BrandColor"))
                                .frame(width: 30, height: 30)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(LocalizedStringKey(preference.titleKey))
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text(LocalizedStringKey(preference.detailKey))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 8)
                            if settings.alertSound == preference {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color("BrandColor"))
                                    .accessibilityHidden(true)
                            }
                        }
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(settings.alertSound == preference ? .isSelected : [])
                }
            }

            Section {
                Button {
                    EmergencyAlertAudio.shared.preview(settings.alertSound)
                } label: {
                    Label("settings.alertSound.preview", systemImage: "play.circle.fill")
                }
            }

            Section {
                Label("settings.alertSound.disclosure", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("settings.alertSound.title")
        .navigationBarTitleDisplayMode(.inline)
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
    }
}
