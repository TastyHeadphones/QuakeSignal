import Foundation

/// The last known server-side lifecycle of this device's QuakeSignal alert
/// registration. It is deliberately separate from `pushSubscriptionEnabled`:
/// that preference records the person's intent, while this status tells the
/// UI whether the latest request actually reached QuakeSignal.
enum PushRegistrationState: String, Codable, Sendable, Equatable {
    case unregistered
    case registering
    case active
    case failed

    /// Both a never-completed registration and a failed update can be retried
    /// as soon as APNs has supplied a token and notification permission allows
    /// registration.
    var isRetryable: Bool {
        self == .unregistered || self == .failed
    }
}

enum PushTestAlertPolicy {
    static func isAvailable(
        subscriptionEnabled: Bool,
        registrationState: PushRegistrationState,
        hasDeviceToken: Bool
    ) -> Bool {
        subscriptionEnabled && registrationState != .registering && hasDeviceToken
    }

    /// A proof can fail after a registration was previously accepted, for
    /// example when iOS can no longer use the Secure Enclave key associated
    /// with that registration. These failures are known to happen before an
    /// APNs test send. Repair the server registration once, then issue the
    /// user-requested test; never retry an ambiguous network/provider error
    /// which might otherwise produce two notifications.
    static func shouldRepairRegistration(after error: Error) -> Bool {
        if let apiError = error as? APIError {
            return apiError.statusCode == 404
        }
        guard let appAttestError = error as? AppAttestError else { return false }
        if case .proofGenerationFailed = appAttestError {
            return true
        }
        if case .serverRejectedCredential = appAttestError {
            return true
        }
        return false
    }
}

@Observable
@MainActor
final class AppSettings {
    static let shared = AppSettings()

    /// Build 8's reviewed source-rights boundary. Keep settings and direct
    /// foreground fetches on the same allow-list so a stale preference cannot
    /// silently restore an unreviewed upstream feed.
    static let allSources = WolfxClient.sources
    static let radiusTiersKm: [Double] = [50, 100, 300, 500]
    static let magnitudeTiers: [Double] = [3, 4, 5, 6]

    var selectedCityId: String? {
        didSet {
            guard oldValue != selectedCityId else { return }
            defaults.set(selectedCityId, forKey: Keys.cityId)
            markPushRegistrationPreferencesChanged()
        }
    }
    var useCurrentLocation: Bool {
        didSet {
            guard oldValue != useCurrentLocation else { return }
            defaults.set(useCurrentLocation, forKey: Keys.useCurrentLocation)
            markPushRegistrationPreferencesChanged()
        }
    }
    var radiusKm: Double {
        didSet {
            guard oldValue != radiusKm else { return }
            defaults.set(radiusKm, forKey: Keys.radiusKm)
            markPushRegistrationPreferencesChanged()
        }
    }
    var minMagnitude: Double {
        didSet {
            guard oldValue != minMagnitude else { return }
            defaults.set(minMagnitude, forKey: Keys.minMagnitude)
            markPushRegistrationPreferencesChanged()
        }
    }
    var enabledSources: Set<String> {
        didSet {
            let reviewedSources = enabledSources.intersection(Self.allSources)
            let previousReviewedSources = oldValue.intersection(Self.allSources)
            let normalizedSources = reviewedSources.isEmpty
                ? (previousReviewedSources.isEmpty ? Set(Self.allSources) : previousReviewedSources)
                : reviewedSources
            if enabledSources != normalizedSources {
                // At least one reviewed JMA source is required by both the
                // foreground policy and protected registration contract.
                enabledSources = normalizedSources
            }
            guard oldValue != enabledSources else { return }
            defaults.set(enabledSources.sorted(), forKey: Keys.sources)
            markPushRegistrationPreferencesChanged()
        }
    }
    var includeTestAlerts: Bool {
        didSet {
            guard oldValue != includeTestAlerts else { return }
            defaults.set(includeTestAlerts, forKey: Keys.includeTestAlerts)
            markPushRegistrationPreferencesChanged()
        }
    }
    var notifyAtNight: Bool {
        didSet {
            guard oldValue != notifyAtNight else { return }
            defaults.set(notifyAtNight, forKey: Keys.notifyAtNight)
            markPushRegistrationPreferencesChanged()
        }
    }
    var alertSound: AlertSoundPreference {
        didSet {
            guard oldValue != alertSound else { return }
            defaults.set(alertSound.rawValue, forKey: Keys.alertSound)
            WatchAlertPreferenceBridge.synchronizeFromPhone(alertSound)
            markPushRegistrationPreferencesChanged()
        }
    }
    /// A single observable trigger for every preference encoded into the
    /// protected APNs registration. CityPickerView is reachable from Home and
    /// onboarding as well as Settings, so registration resynchronization must
    /// be owned by RootView rather than by one presentation of SettingsView.
    private(set) var pushRegistrationPreferencesRevision = 0
    /// Controls whether this device is registered with QuakeSignal's alert
    /// service. It is separate from iOS notification permission, which only
    /// the user can change in Settings.
    var pushSubscriptionEnabled: Bool {
        didSet { defaults.set(pushSubscriptionEnabled, forKey: Keys.pushSubscriptionEnabled) }
    }
    /// Durable registration status. `.active` is written only after the
    /// protected device-registration request receives a successful response.
    var pushRegistrationState: PushRegistrationState {
        didSet { defaults.set(pushRegistrationState.rawValue, forKey: Keys.pushRegistrationState) }
    }

    var selectedCity: City? {
        selectedCityId.flatMap { CityDirectory.find(id: $0) }
    }

    /// Selects GPS-backed filtering without discarding the last explicit city.
    /// Core Location can take time to authorize or produce a fix, and the
    /// selected city remains the safe subscription fallback until then.
    func selectCurrentLocation() {
        useCurrentLocation = true
    }

    private enum Keys {
        static let cityId = "settings.cityId"
        static let useCurrentLocation = "settings.useCurrentLocation"
        static let radiusKm = "settings.radiusKm"
        static let minMagnitude = "settings.minMagnitude"
        static let sources = "settings.sources"
        static let includeTestAlerts = "settings.includeTestAlerts"
        static let notifyAtNight = "settings.notifyAtNight"
        static let alertSound = "settings.alertSound"
        static let pushSubscriptionEnabled = "settings.pushSubscriptionEnabled"
        static let pushRegistrationState = "settings.pushRegistrationState"
    }

    private let defaults: UserDefaults

    private func markPushRegistrationPreferencesChanged() {
        pushRegistrationPreferencesRevision &+= 1
    }

    /// The injected defaults suite makes persistence behavior directly
    /// testable without mutating the application's live preferences.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedCityId = defaults.string(forKey: Keys.cityId)
        useCurrentLocation = defaults.object(forKey: Keys.useCurrentLocation) as? Bool ?? false
        radiusKm = defaults.object(forKey: Keys.radiusKm) as? Double ?? 100
        minMagnitude = defaults.object(forKey: Keys.minMagnitude) as? Double ?? 3
        if let saved = defaults.array(forKey: Keys.sources) as? [String] {
            let reviewedSources = Set(saved).intersection(Self.allSources)
            let normalizedSources = reviewedSources.isEmpty
                ? Set(Self.allSources)
                : reviewedSources
            enabledSources = normalizedSources
            if normalizedSources != Set(saved) {
                defaults.set(normalizedSources.sorted(), forKey: Keys.sources)
            }
        } else {
            enabledSources = Set(Self.allSources)
        }
        includeTestAlerts = defaults.object(forKey: Keys.includeTestAlerts) as? Bool ?? false
        notifyAtNight = defaults.object(forKey: Keys.notifyAtNight) as? Bool ?? true
        alertSound = defaults.string(forKey: Keys.alertSound)
            .flatMap(AlertSoundPreference.init(rawValue:))
            ?? .system
        // Preserve existing installations' behavior. A device cannot be
        // registered until it has both notification permission and an APNs
        // device token, so this default does not opt an unprompted install in.
        let subscriptionEnabled = defaults.object(forKey: Keys.pushSubscriptionEnabled) as? Bool ?? true
        pushSubscriptionEnabled = subscriptionEnabled
        let persistedRegistrationState = defaults.string(forKey: Keys.pushRegistrationState)
            .flatMap(PushRegistrationState.init(rawValue:))
            ?? .unregistered
        // An app termination can interrupt a request after it has been sent
        // but before its response is observed. Never restore that ambiguous
        // state as active: surface a retryable failure instead.
        if !subscriptionEnabled {
            pushRegistrationState = .unregistered
            defaults.set(PushRegistrationState.unregistered.rawValue, forKey: Keys.pushRegistrationState)
        } else if persistedRegistrationState == .registering {
            pushRegistrationState = .failed
            defaults.set(PushRegistrationState.failed.rawValue, forKey: Keys.pushRegistrationState)
        } else {
            pushRegistrationState = persistedRegistrationState
        }
    }
}
