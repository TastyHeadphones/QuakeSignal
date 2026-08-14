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
        subscriptionEnabled && registrationState == .active && hasDeviceToken
    }
}

@Observable
@MainActor
final class AppSettings {
    static let shared = AppSettings()

    static let allSources = ["jma_eew", "sc_eew", "cenc_eew", "fj_eew", "cq_eew", "cenc_eqlist", "jma_eqlist"]
    static let radiusTiersKm: [Double] = [50, 100, 300, 500]
    static let magnitudeTiers: [Double] = [3, 4, 5, 6]

    var selectedCityId: String? {
        didSet { defaults.set(selectedCityId, forKey: Keys.cityId) }
    }
    var useCurrentLocation: Bool {
        didSet { defaults.set(useCurrentLocation, forKey: Keys.useCurrentLocation) }
    }
    var radiusKm: Double {
        didSet { defaults.set(radiusKm, forKey: Keys.radiusKm) }
    }
    var minMagnitude: Double {
        didSet { defaults.set(minMagnitude, forKey: Keys.minMagnitude) }
    }
    var enabledSources: Set<String> {
        didSet { defaults.set(Array(enabledSources), forKey: Keys.sources) }
    }
    var includeTestAlerts: Bool {
        didSet { defaults.set(includeTestAlerts, forKey: Keys.includeTestAlerts) }
    }
    var notifyAtNight: Bool {
        didSet { defaults.set(notifyAtNight, forKey: Keys.notifyAtNight) }
    }
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
        static let pushSubscriptionEnabled = "settings.pushSubscriptionEnabled"
        static let pushRegistrationState = "settings.pushRegistrationState"
    }

    private let defaults: UserDefaults

    /// The injected defaults suite makes persistence behavior directly
    /// testable without mutating the application's live preferences.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedCityId = defaults.string(forKey: Keys.cityId)
        useCurrentLocation = defaults.object(forKey: Keys.useCurrentLocation) as? Bool ?? false
        radiusKm = defaults.object(forKey: Keys.radiusKm) as? Double ?? 100
        minMagnitude = defaults.object(forKey: Keys.minMagnitude) as? Double ?? 3
        if let saved = defaults.array(forKey: Keys.sources) as? [String] {
            enabledSources = Set(saved)
        } else {
            enabledSources = Set(Self.allSources)
        }
        includeTestAlerts = defaults.object(forKey: Keys.includeTestAlerts) as? Bool ?? false
        notifyAtNight = defaults.object(forKey: Keys.notifyAtNight) as? Bool ?? true
        // Preserve existing installations' behavior. A device cannot be
        // registered until it has both notification permission and an APNs
        // device token, so this default does not opt an unprompted install in.
        pushSubscriptionEnabled = defaults.object(forKey: Keys.pushSubscriptionEnabled) as? Bool ?? true
        let persistedRegistrationState = defaults.string(forKey: Keys.pushRegistrationState)
            .flatMap(PushRegistrationState.init(rawValue:))
            ?? .unregistered
        // An app termination can interrupt a request after it has been sent
        // but before its response is observed. Never restore that ambiguous
        // state as active: surface a retryable failure instead.
        if persistedRegistrationState == .registering {
            pushRegistrationState = .failed
            defaults.set(PushRegistrationState.failed.rawValue, forKey: Keys.pushRegistrationState)
        } else {
            pushRegistrationState = persistedRegistrationState
        }
    }
}
