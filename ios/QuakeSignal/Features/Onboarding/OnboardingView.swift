import SwiftUI

private enum OnboardingStep: Int, CaseIterable {
    case welcome, sources, notifications, location

    var title: LocalizedStringKey {
        switch self {
        case .welcome: return "onboarding.title1"
        case .sources: return "onboarding.title2"
        case .notifications:
            return PlatformCapabilities.supportsAttestedAlertRegistration
                ? "onboarding.title3"
                : "platform.alertRegistration.foregroundOnly"
        case .location: return "onboarding.title4"
        }
    }

    var body: LocalizedStringKey {
        switch self {
        case .welcome: return "onboarding.body1"
        case .sources: return "onboarding.body2"
        case .notifications:
            return PlatformCapabilities.supportsAttestedAlertRegistration
                ? "onboarding.body3"
                : "platform.alertRegistration.foregroundOnly.detail"
        case .location: return "onboarding.body4"
        }
    }

    var symbol: String {
        switch self {
        case .welcome: return "bolt.fill"
        case .sources: return "globe.asia.australia.fill"
        case .notifications:
            return PlatformCapabilities.supportsAttestedAlertRegistration
                ? "bell.badge.fill"
                : "eye"
        case .location: return "location.circle.fill"
        }
    }
}

struct OnboardingView: View {
    @Binding var hasCompletedOnboarding: Bool
    @State private var page: OnboardingStep = .welcome
    @State private var isRequesting = false
    @State private var showingCityPicker = false

    var body: some View {
        VStack(spacing: 24) {
            TabView(selection: $page) {
                ForEach(OnboardingStep.allCases, id: \.self) { step in
                    VStack(spacing: 20) {
                        Image(systemName: step.symbol)
                            .font(.system(size: 64))
                            .foregroundStyle(.tint)
                        Text(step.title)
                            .font(.title.bold())
                            .multilineTextAlignment(.center)
                        Text(step.body)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)

                        if step == .sources {
                            Text("onboarding.disclaimer")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(12)
                                .background(RoundedRectangle(cornerRadius: 12).fill(Color("CautionColor").opacity(0.12)))
                                .padding(.horizontal, 32)
                        }
                    }
                    .tag(step)
                }
            }
            .tabViewStyle(.page)

            actionArea
        }
        .padding(.vertical, 40)
        .sheet(isPresented: $showingCityPicker, onDismiss: { hasCompletedOnboarding = true }) {
            CityPickerView()
        }
    }

    @ViewBuilder
    private var actionArea: some View {
        switch page {
        case .welcome, .sources:
            Button {
                withAnimation { page = OnboardingStep(rawValue: page.rawValue + 1) ?? page }
            } label: {
                Text("onboarding.continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 32)

        case .notifications:
            if PlatformCapabilities.supportsAttestedAlertRegistration {
                notificationPermissionActions
            } else {
                Button {
                    withAnimation { page = .location }
                } label: {
                    Text("onboarding.continue").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 32)
            }

        case .location:
            VStack(spacing: 12) {
                Button {
                    showingCityPicker = true
                } label: {
                    Text("onboarding.chooseLocation").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("onboarding.skip") {
                    hasCompletedOnboarding = true
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 32)
        }
    }

    private var notificationPermissionActions: some View {
        VStack(spacing: 12) {
            Button {
                Task {
                    isRequesting = true
                    _ = await NotificationManager.shared.requestAuthorization()
                    isRequesting = false
                    withAnimation { page = .location }
                }
            } label: {
                Group {
                    if isRequesting {
                        ProgressView()
                    } else {
                        Text("onboarding.enableNotifications")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isRequesting)

            Button("onboarding.skip") {
                withAnimation { page = .location }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 32)
    }
}
