import CoreLocation

extension CLAuthorizationStatus {
    var allowsQuakeSignalLocation: Bool {
        switch self {
        case .authorizedWhenInUse:
            return true
#if !os(visionOS)
        case .authorizedAlways:
            return true
#endif
        case .denied, .notDetermined, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}

enum LocationFixPolicy {
    static let maximumAge: TimeInterval = 2 * 60
    static let maximumHorizontalAccuracy: CLLocationAccuracy = 5_000
    typealias ExpirationSleep = @Sendable (Duration) async throws -> Void

    static func isUsable(_ location: CLLocation, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(location.timestamp)
        return location.horizontalAccuracy >= 0 &&
            location.horizontalAccuracy <= maximumHorizontalAccuracy &&
            age >= -10 &&
            age <= maximumAge &&
            CLLocationCoordinate2DIsValid(location.coordinate)
    }

    static func bestUsableLocation(
        in locations: [CLLocation],
        now: Date = Date()
    ) -> CLLocation? {
        locations
            .filter { isUsable($0, now: now) }
            .max { left, right in
                if left.timestamp != right.timestamp {
                    return left.timestamp < right.timestamp
                }
                return left.horizontalAccuracy > right.horizontalAccuracy
            }
    }

    /// Keeps the cache lifetime anchored to the fix's timestamp. Core Location
    /// can return a still-usable cached fix, so starting a new full lifetime at
    /// callback time would retain that coordinate beyond `maximumAge`.
    static func remainingLifetime(
        for location: CLLocation,
        now: Date = Date()
    ) -> TimeInterval {
        remainingLifetime(forTimestamp: location.timestamp, now: now)
    }

    static func remainingLifetime(
        forTimestamp timestamp: Date,
        now: Date = Date()
    ) -> TimeInterval {
        max(0, timestamp.addingTimeInterval(maximumAge).timeIntervalSince(now))
    }

    @MainActor
    static func expirationTask(
        after delay: TimeInterval,
        sleep: @escaping ExpirationSleep = { duration in
            try await Task.sleep(for: duration)
        },
        onExpiration: @escaping @MainActor @Sendable () -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor in
            do {
                if delay > 0 {
                    try await sleep(.seconds(delay))
                }
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            onExpiration()
        }
    }
}

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
    private var locationExpirationTask: Task<Void, Never>?

    private override init() {
        authorizationStatus = .notDetermined
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        authorizationStatus = manager.authorizationStatus
    }

    /// Requests the next location using the appropriate Core Location state.
    /// Calling `requestLocation()` before the authorization prompt completes
    /// can fail without ever producing the fix needed by push registration.
    func requestCurrentLocation() {
        guard !ScreenshotAutomation.isEnabled else { return }
        let currentAuthorization = manager.authorizationStatus
        authorizationStatus = currentAuthorization
        lastRequestFailed = false

        if currentAuthorization.allowsQuakeSignalLocation {
            // Never present a previous trip's coordinate as a fresh fix while
            // a new request is in flight.
            currentLocation = nil
            locationExpirationTask?.cancel()
            locationExpirationTask = nil
            isRequestingLocation = true
            manager.requestLocation()
            return
        }

        if currentAuthorization == .notDetermined {
            isRequestingLocation = true
            manager.requestWhenInUseAuthorization()
            return
        }

        currentLocation = nil
        locationExpirationTask?.cancel()
        locationExpirationTask = nil
        isRequestingLocation = false
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
            if status.allowsQuakeSignalLocation {
                // Use self.manager (the same underlying instance), not the
                // delegate-callback parameter -- CLLocationManager isn't
                // provably Sendable, so passing the parameter itself across
                // into this @MainActor closure trips strict concurrency.
                self.lastRequestFailed = false
                self.isRequestingLocation = true
                self.manager.requestLocation()
            } else {
                self.currentLocation = nil
                self.locationExpirationTask?.cancel()
                self.locationExpirationTask = nil
                self.isRequestingLocation = false
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = LocationFixPolicy.bestUsableLocation(in: locations) else {
            Task { @MainActor in
                self.currentLocation = nil
                self.isRequestingLocation = false
                self.lastRequestFailed = true
            }
            return
        }
        let coordinate = location.coordinate
        let timestamp = location.timestamp
        Task { @MainActor in
            self.currentLocation = coordinate
            self.isRequestingLocation = false
            self.lastRequestFailed = false
            self.scheduleLocationExpiration(for: coordinate, timestamp: timestamp)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.currentLocation = nil
            self.locationExpirationTask?.cancel()
            self.locationExpirationTask = nil
            self.isRequestingLocation = false
            self.lastRequestFailed = true
        }
    }

    private func scheduleLocationExpiration(
        for coordinate: CLLocationCoordinate2D,
        timestamp: Date
    ) {
        locationExpirationTask?.cancel()
        let remainingLifetime = LocationFixPolicy.remainingLifetime(forTimestamp: timestamp)
        locationExpirationTask = LocationFixPolicy.expirationTask(
            after: remainingLifetime
        ) { [weak self] in
            guard let self,
                  self.currentLocation?.latitude == coordinate.latitude,
                  self.currentLocation?.longitude == coordinate.longitude else {
                return
            }
            self.currentLocation = nil
            self.lastRequestFailed = true
            self.locationExpirationTask = nil
        }
    }
}
