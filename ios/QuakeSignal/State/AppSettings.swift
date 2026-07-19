import Foundation

@Observable
@MainActor
final class AppSettings {
    static let shared = AppSettings()

    static let allSources = ["jma_eew", "sc_eew", "cenc_eew", "fj_eew", "cq_eew", "cenc_eqlist", "jma_eqlist"]
    static let radiusTiersKm: [Double] = [50, 100, 300, 500]
    static let magnitudeTiers: [Double] = [3, 4, 5, 6]

    var selectedCityId: String? {
        didSet { UserDefaults.standard.set(selectedCityId, forKey: Keys.cityId) }
    }
    var useCurrentLocation: Bool {
        didSet { UserDefaults.standard.set(useCurrentLocation, forKey: Keys.useCurrentLocation) }
    }
    var radiusKm: Double {
        didSet { UserDefaults.standard.set(radiusKm, forKey: Keys.radiusKm) }
    }
    var minMagnitude: Double {
        didSet { UserDefaults.standard.set(minMagnitude, forKey: Keys.minMagnitude) }
    }
    var enabledSources: Set<String> {
        didSet { UserDefaults.standard.set(Array(enabledSources), forKey: Keys.sources) }
    }
    var criticalAlertsOptIn: Bool {
        didSet { UserDefaults.standard.set(criticalAlertsOptIn, forKey: Keys.criticalOptIn) }
    }
    var includeTestAlerts: Bool {
        didSet { UserDefaults.standard.set(includeTestAlerts, forKey: Keys.includeTestAlerts) }
    }
    var notifyAtNight: Bool {
        didSet { UserDefaults.standard.set(notifyAtNight, forKey: Keys.notifyAtNight) }
    }

    var selectedCity: City? {
        selectedCityId.flatMap { CityDirectory.find(id: $0) }
    }

    private enum Keys {
        static let cityId = "settings.cityId"
        static let useCurrentLocation = "settings.useCurrentLocation"
        static let radiusKm = "settings.radiusKm"
        static let minMagnitude = "settings.minMagnitude"
        static let sources = "settings.sources"
        static let criticalOptIn = "settings.criticalOptIn"
        static let includeTestAlerts = "settings.includeTestAlerts"
        static let notifyAtNight = "settings.notifyAtNight"
    }

    private init() {
        let defaults = UserDefaults.standard
        selectedCityId = defaults.string(forKey: Keys.cityId)
        useCurrentLocation = defaults.object(forKey: Keys.useCurrentLocation) as? Bool ?? false
        radiusKm = defaults.object(forKey: Keys.radiusKm) as? Double ?? 100
        minMagnitude = defaults.object(forKey: Keys.minMagnitude) as? Double ?? 3
        if let saved = defaults.array(forKey: Keys.sources) as? [String] {
            enabledSources = Set(saved)
        } else {
            enabledSources = Set(Self.allSources)
        }
        criticalAlertsOptIn = defaults.object(forKey: Keys.criticalOptIn) as? Bool ?? false
        includeTestAlerts = defaults.object(forKey: Keys.includeTestAlerts) as? Bool ?? false
        notifyAtNight = defaults.object(forKey: Keys.notifyAtNight) as? Bool ?? true
    }
}
