import CoreLocation

/// GCJ-02 (China encrypted datum) ↔ WGS-84. Core Location in mainland China
/// returns GCJ-02; CENC/Sichuan/Fujian/Chongqing Wolfx feeds publish GCJ-02;
/// JMA/USGS/EMSC/GeoNet publish WGS-84. Alert matching always compares WGS-84.
enum ChinaCoordinateTransform {
    static let chinaDomesticSources: Set<String> = [
        "cenc_eew", "cenc_eqlist", "sc_eew", "fj_eew", "cq_eew",
    ]

    static func isInsideChina(latitude: Double, longitude: Double) -> Bool {
        longitude >= 72.004 && longitude <= 137.8347 && latitude >= 0.8293 && latitude <= 55.8271
    }

    static func isChinaDomesticSource(_ sourceId: String) -> Bool {
        chinaDomesticSources.contains(sourceId)
    }

    static func wgs84ToGcj02(latitude: Double, longitude: Double) -> CLLocationCoordinate2D {
        guard isInsideChina(latitude: latitude, longitude: longitude) else {
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
        let dLat = transformLat(longitude: longitude, latitude: latitude)
        let dLon = transformLon(longitude: longitude, latitude: latitude)
        let radLat = latitude / 180 * .pi
        let magic = sin(radLat)
        let magicFactor = 1 - 0.00669342162296594323 * magic * magic
        let sqrtMagic = sqrt(magicFactor)
        let a = 6378245.0
        return CLLocationCoordinate2D(
            latitude: latitude + (dLat * 180) / ((a * (1 - 0.00669342162296594323)) / (magicFactor * sqrtMagic) * .pi),
            longitude: longitude + (dLon * 180) / (a / sqrtMagic * cos(radLat) * .pi)
        )
    }

    static func gcj02ToWgs84(latitude: Double, longitude: Double) -> CLLocationCoordinate2D {
        guard isInsideChina(latitude: latitude, longitude: longitude) else {
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
        let gcj = wgs84ToGcj02(latitude: latitude, longitude: longitude)
        return CLLocationCoordinate2D(
            latitude: latitude * 2 - gcj.latitude,
            longitude: longitude * 2 - gcj.longitude
        )
    }

    static func deviceGPSToWgs84(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        gcj02ToWgs84(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    static func eventToWgs84(
        latitude: Double,
        longitude: Double,
        sourceId: String
    ) -> CLLocationCoordinate2D {
        if isChinaDomesticSource(sourceId) {
            return gcj02ToWgs84(latitude: latitude, longitude: longitude)
        }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    static func alertDistanceKm(
        userLatitude: Double,
        userLongitude: Double,
        eventLatitude: Double,
        eventLongitude: Double,
        eventSourceId: String
    ) -> Double {
        let event = eventToWgs84(
            latitude: eventLatitude,
            longitude: eventLongitude,
            sourceId: eventSourceId
        )
        let user = CLLocation(latitude: userLatitude, longitude: userLongitude)
        let epicenter = CLLocation(latitude: event.latitude, longitude: event.longitude)
        return user.distance(from: epicenter) / 1000
    }

    private static func transformLat(longitude: Double, latitude: Double) -> Double {
        let x = longitude - 105
        let y = latitude - 35
        return -100 + 2 * x + 3 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
            + (20 * sin(6 * x * .pi) + 20 * sin(2 * x * .pi)) * 2 / 3
            + (20 * sin(y * .pi) + 40 * sin(y / 3 * .pi)) * 2 / 3
            + (160 * sin(y / 12 * .pi) + 320 * sin(y * .pi / 30)) * 2 / 3
    }

    private static func transformLon(longitude: Double, latitude: Double) -> Double {
        let x = longitude - 105
        let y = latitude - 35
        return 300 + x + 2 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
            + (20 * sin(6 * x * .pi) + 20 * sin(2 * x * .pi)) * 2 / 3
            + (20 * sin(x * .pi) + 40 * sin(x / 3 * .pi)) * 2 / 3
            + (150 * sin(x / 12 * .pi) + 300 * sin(x / 30 * .pi)) * 2 / 3
    }
}

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
