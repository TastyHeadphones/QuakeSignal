import CoreLocation

/// A deliberately imprecise location sent to the notification service.
///
/// A 0.1° grid is roughly 11 km north/south (and somewhat less east/west at
/// the latitudes QuakeSignal covers). That is sufficient for broad alert
/// matching while ensuring the service never receives the device's GPS fix.
struct CoarseCoordinate: Equatable, Sendable {
    static let gridDegrees: CLLocationDegrees = 0.1

    let latitude: CLLocationDegrees
    let longitude: CLLocationDegrees

    init?(_ coordinate: CLLocationCoordinate2D) {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }

        latitude = Self.quantize(coordinate.latitude)
        longitude = Self.quantize(coordinate.longitude)
    }

    private static func quantize(_ value: CLLocationDegrees) -> CLLocationDegrees {
        let quantized = (value / gridDegrees).rounded(.toNearestOrAwayFromZero) * gridDegrees
        // Avoid encoding a negative zero in the device-registration payload.
        return quantized == 0 ? 0 : quantized
    }
}
