import SwiftUI
import UIKit

struct SettingsView: View {
    @State private var settings = AppSettings.shared
    @State private var notifications = NotificationManager.shared
    @State private var isSendingTest = false
    @State private var testResultMessage: String?
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
                            Text(settings.selectedCity?.localizedName ?? String(localized: "city.none"))
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
                            Task { await notifications.requestAuthorization() }
                        }
                    } else if notifications.authorizationStatus == .denied {
                        Button("settings.openSystemSettings") { openSystemSettings() }
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
                    .disabled(isSendingTest || notifications.deviceToken == nil)

                    if let testResultMessage {
                        Text(testResultMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("settings.section.language") {
                    Text("settings.language.systemNote")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("settings.openSystemSettings") { openSystemSettings() }
                }

                Section {
                    NavigationLink("settings.section.disclaimer") {
                        SourceDisclaimerView()
                    }
                }
            }
            .navigationTitle("settings.title")
            .onChange(of: settings.minMagnitude) { _, _ in resyncPushPreferences() }
            .onChange(of: settings.notifyAtNight) { _, _ in resyncPushPreferences() }
            .onChange(of: settings.includeTestAlerts) { _, _ in resyncPushPreferences() }
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

    private func resyncPushPreferences() {
        guard let token = notifications.deviceToken else { return }
        Task { await QuakeStore.shared.registerForPush(token: token) }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func sendTestAlert() async {
        guard let token = notifications.deviceToken else { return }
        isSendingTest = true
        testResultMessage = nil
        do {
            try await APIClient.shared.sendTestAlert(token: token)
            testResultMessage = String(localized: "settings.testAlert.success")
        } catch {
            testResultMessage = L("settings.testAlert.failure", error.localizedDescription)
        }
        isSendingTest = false
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
