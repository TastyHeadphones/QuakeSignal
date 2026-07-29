import Foundation
import CoreLocation

struct PresentedAlert: Identifiable, Equatable {
    let event: EEWEvent
    let reason: String
    var id: String { "\(event.id)#\(reason)#\(event.serial)" }
}

@Observable
@MainActor
final class QuakeStore {
    static let shared = QuakeStore()

    private(set) var events: [EEWEvent] = []
    private(set) var isLoading = false
    private(set) var loadError: String?
    var presentedAlert: PresentedAlert?

    private let liveSocket = LiveSocketClient()
    private let api = APIClient.shared

    var isConnected: Bool { liveSocket.isConnected }

    private init() {
        liveSocket.onEvent = { [weak self] event, reason in
            self?.ingest(event: event, reason: reason)
        }
    }

    func start() async {
        liveSocket.start()
        await refresh()
    }

    func refresh() async {
        isLoading = true
        loadError = nil
        do {
            events = try await api.fetchRecentQuakes()
                .sorted { ($0.reportTimeUtc ?? "") > ($1.reportTimeUtc ?? "") }
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    func registerForPush(token: String) async {
        let settings = AppSettings.shared
        let coordinate = effectiveCoordinate
        let request = DeviceRegistrationRequest(
            token: token,
            environment: AppEnvironment.isDebugBuild ? "sandbox" : "production",
            locale: Locale.current.identifier,
            sources: Array(settings.enabledSources),
            minMagnitude: settings.minMagnitude,
            // Critical Alerts require a separate Apple-granted entitlement.
            // The public build deliberately uses time-sensitive notifications
            // until that entitlement is approved for this bundle identifier.
            criticalAlertsEnabled: false,
            cityName: settings.selectedCity?.localizedName,
            latitude: coordinate?.latitude,
            longitude: coordinate?.longitude,
            radiusKm: coordinate != nil ? settings.radiusKm : nil,
            includeTestAlerts: settings.includeTestAlerts,
            utcOffsetMinutes: TimeZone.current.secondsFromGMT() / 60,
            notifyAtNight: settings.notifyAtNight
        )
        _ = try? await api.registerDevice(request)
    }

    /// Applies an update from either the live socket or a tapped push notification.
    func ingest(event: EEWEvent, reason: String) {
        if let index = events.firstIndex(where: { $0.id == event.id }) {
            events[index] = event
        } else {
            events.insert(event, at: 0)
        }

        if event.isEew {
            presentedAlert = PresentedAlert(event: event, reason: reason)
        }
    }

    // MARK: - Location-aware derived state (drives the Home banner)

    /// GPS location if the user opted in and it's available, else the subscribed city, else nil.
    var effectiveCoordinate: CLLocationCoordinate2D? {
        let settings = AppSettings.shared
        if settings.useCurrentLocation, let gps = LocationManager.shared.currentLocation {
            return gps
        }
        return settings.selectedCity?.coordinate
    }

    /// True when `effectiveCoordinate` came from GPS rather than a picked city -- Views use this to
    /// decide between showing the subscribed city's name and a generic "current location" label.
    var isUsingGPSLocation: Bool {
        AppSettings.shared.useCurrentLocation && LocationManager.shared.currentLocation != nil
    }

    /// Events within the configured radius of `effectiveCoordinate`, nearest first. Falls back to
    /// all events (unfiltered) when no location is set, so the app is still useful before onboarding a city.
    var nearbyEvents: [EEWEvent] {
        guard let coordinate = effectiveCoordinate else { return events }
        let radius = AppSettings.shared.radiusKm
        return events
            .compactMap { event -> (EEWEvent, Double)? in
                guard let distance = event.distanceKm(from: coordinate) else { return nil }
                return (event, distance)
            }
            .filter { $0.1 <= radius }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    var activeWarning: EEWEvent? {
        let now = Date()
        return nearbyEvents.first { event in
            guard event.isActiveWarning, let timestamp = event.reportDate ?? event.originDate else {
                return false
            }
            // Some upstream EEW endpoints retain their last message while idle.
            // A preliminary message is only actionable for a short window; an
            // old retained payload must never look like a current warning.
            let age = now.timeIntervalSince(timestamp)
            return age >= -60 && age <= 10 * 60
        }
    }

    /// A recent (last 24h), non-warning event nearby -- drives the "caution" banner state.
    var recentNearbyReport: EEWEvent? {
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        return nearbyEvents.first { event in
            guard let reportDate = event.reportDate else { return false }
            return reportDate >= cutoff
        }
    }

    var bannerState: HomeBannerState {
        if activeWarning != nil { return .alert }
        if recentNearbyReport != nil { return .caution }
        return .normal
    }
}
