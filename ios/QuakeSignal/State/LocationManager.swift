import CoreLocation

enum LocationSelectionStatus: Equatable {
    case permissionRequired
    case denied
    case locating
    case current
    case unavailable

    /// A denied/restricted authorization cannot be repaired by another Core
    /// Location request. Keep the existing city subscription unchanged and
    /// direct the person to iOS Settings instead.
    var canRequestCurrentLocation: Bool {
        self != .denied
    }

    static func resolve(
        authorizationStatus: CLAuthorizationStatus,
        hasCurrentLocation: Bool,
        isRequestingLocation: Bool,
        lastRequestFailed: Bool
    ) -> Self {
        if authorizationStatus == .denied || authorizationStatus == .restricted {
            return .denied
        }
        if hasCurrentLocation {
            return .current
        }
        if authorizationStatus == .notDetermined {
            return .permissionRequired
        }
        if lastRequestFailed {
            return .unavailable
        }
        return isRequestingLocation ? .locating : .unavailable
    }

    func localizedDetail(fallbackCityName: String?) -> String {
        switch self {
        case .current:
            return String(localized: "city.currentLocation.active")
        case .permissionRequired:
            if let fallbackCityName {
                return L("city.currentLocation.permissionFallback", fallbackCityName)
            }
            return String(localized: "city.currentLocation.permissionRequired")
        case .denied:
            if let fallbackCityName {
                return L("city.currentLocation.deniedFallback", fallbackCityName)
            }
            return String(localized: "home.banner.locationOff")
        case .locating:
            if let fallbackCityName {
                return L("city.currentLocation.locatingFallback", fallbackCityName)
            }
            return String(localized: "city.currentLocation.locating")
        case .unavailable:
            if let fallbackCityName {
                return L("city.currentLocation.unavailableFallback", fallbackCityName)
            }
            return String(localized: "city.currentLocation.unavailable")
        }
    }
}

@Observable
@MainActor
final class LocationManager: NSObject, CLLocationManagerDelegate {
    static let shared = LocationManager()

    private(set) var authorizationStatus: CLAuthorizationStatus
    private(set) var currentLocation: CLLocationCoordinate2D?
    private(set) var isRequestingLocation = false
    private(set) var lastRequestFailed = false

    private let manager = CLLocationManager()

    private override init() {
        authorizationStatus = .notDetermined
        super.init()
        manager.delegate = self
        authorizationStatus = manager.authorizationStatus
    }

    /// Requests the next location using the appropriate Core Location state.
    /// Calling `requestLocation()` before the authorization prompt completes
    /// can fail without ever producing the fix needed by push registration.
    func requestCurrentLocation() {
        let currentAuthorization = manager.authorizationStatus
        authorizationStatus = currentAuthorization
        lastRequestFailed = false

        switch currentAuthorization {
        case .authorizedAlways, .authorizedWhenInUse:
            isRequestingLocation = true
            manager.requestLocation()
        case .notDetermined:
            isRequestingLocation = true
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            currentLocation = nil
            isRequestingLocation = false
        @unknown default:
            currentLocation = nil
            isRequestingLocation = false
        }
    }

    var selectionStatus: LocationSelectionStatus {
        LocationSelectionStatus.resolve(
            authorizationStatus: authorizationStatus,
            hasCurrentLocation: currentLocation != nil,
            isRequestingLocation: isRequestingLocation,
            lastRequestFailed: lastRequestFailed
        )
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                // Use self.manager (the same underlying instance), not the
                // delegate-callback parameter -- CLLocationManager isn't
                // provably Sendable, so passing the parameter itself across
                // into this @MainActor closure trips strict concurrency.
                self.lastRequestFailed = false
                self.isRequestingLocation = true
                self.manager.requestLocation()
            } else {
                self.currentLocation = nil
                self.isRequestingLocation = false
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        Task { @MainActor in
            self.currentLocation = coordinate
            self.isRequestingLocation = false
            self.lastRequestFailed = false
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.isRequestingLocation = false
            self.lastRequestFailed = true
        }
    }
}
