import CoreLocation
import Foundation
import SwiftUI

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

/// Client-side normalized Wolfx event shared by the app's direct HTTP and
/// WebSocket data paths.
struct EEWEvent: Codable, Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let sourceId: String
    let eventId: String
    let serial: Int
    let kind: String // "eew" | "report"
    let originTimeUtc: String?
    let reportTimeUtc: String?
    let hypocenter: String
    let latitude: Double?
    let longitude: Double?
    let magnitude: Double?
    let depth: Double?
    let maxIntensity: String?
    let isWarn: Bool
    let isFinal: Bool
    let isCancel: Bool
    let isTraining: Bool
    let tsunami: String?
}

extension EEWEvent {
    /// A live, ongoing early warning: not a finished report, not cancelled, not a drill.
    var isActiveWarning: Bool { kind == "eew" && isWarn && !isFinal && !isCancel && !isTraining }

    var isEew: Bool { kind == "eew" }

    var magnitudeText: String {
        guard let magnitude else { return "--" }
        return String(format: "%.1f", magnitude)
    }

    var severity: Severity {
        Severity.from(magnitude: magnitude, isCancel: isCancel)
    }

    var reportStatus: ReportStatus {
        ReportStatus.from(isFinal: isFinal, isCancel: isCancel, isTraining: isTraining)
    }

    var sourceLabelKey: LocalizedStringKey {
        switch sourceId {
        case "jma_eew", "jma_eqlist": return "quake.source.jma"
        case "cenc_eew", "cenc_eqlist": return "quake.source.cenc"
        case "sc_eew": return "quake.source.sc"
        case "fj_eew": return "quake.source.fj"
        case "cq_eew": return "quake.source.cq"
        case "usgs_eqlist": return "quake.source.usgs"
        case "emsc_eqlist": return "quake.source.emsc"
        case "geonet_eqlist": return "quake.source.geonet"
        default: return LocalizedStringKey(sourceId)
        }
    }

    /// Same as `sourceLabelKey` but as a plain String, for contexts (like `LabeledContent(value:)`) that need one.
    var sourceLabelText: String {
        switch sourceId {
        case "jma_eew", "jma_eqlist": return String(localized: "quake.source.jma")
        case "cenc_eew", "cenc_eqlist": return String(localized: "quake.source.cenc")
        case "sc_eew": return String(localized: "quake.source.sc")
        case "fj_eew": return String(localized: "quake.source.fj")
        case "cq_eew": return String(localized: "quake.source.cq")
        case "usgs_eqlist": return String(localized: "quake.source.usgs")
        case "emsc_eqlist": return String(localized: "quake.source.emsc")
        case "geonet_eqlist": return String(localized: "quake.source.geonet")
        default: return sourceId
        }
    }

    var originDate: Date? {
        guard let originTimeUtc else { return nil }
        return Self.parseISO8601(originTimeUtc)
    }

    var reportDate: Date? {
        guard let reportTimeUtc else { return nil }
        return Self.parseISO8601(reportTimeUtc)
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value)
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
    }

    func distanceKm(from coordinate: CLLocationCoordinate2D) -> Double? {
        guard let eventCoordinate = self.coordinate,
              CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        return ChinaCoordinateTransform.alertDistanceKm(
            userLatitude: coordinate.latitude,
            userLongitude: coordinate.longitude,
            eventLatitude: eventCoordinate.latitude,
            eventLongitude: eventCoordinate.longitude,
            eventSourceId: sourceId
        )
    }

    /// 8-point compass direction from `coordinate` to this event's epicenter, e.g. "NW".
    func compassDirection(from coordinate: CLLocationCoordinate2D) -> CompassDirection? {
        guard let eventCoordinate = self.coordinate,
              CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        let latitude = eventCoordinate.latitude
        let longitude = eventCoordinate.longitude
        let lat1 = coordinate.latitude * .pi / 180
        let lat2 = latitude * .pi / 180
        let deltaLon = (longitude - coordinate.longitude) * .pi / 180
        let y = sin(deltaLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLon)
        let bearingDegrees = (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        return CompassDirection(bearingDegrees: bearingDegrees)
    }
}

/// One freshness boundary for every foreground surface that elevates an EEW
/// above ordinary reports. The future allowance handles small device/source
/// clock differences without letting a malformed future timestamp remain
/// prominent indefinitely.
enum WarningFreshnessPolicy {
    static let maximumAge: TimeInterval = 10 * 60
    static let allowedFutureSkew: TimeInterval = 60

    static func isFresh(_ event: EEWEvent, now: Date = Date()) -> Bool {
        guard let timestamp = event.reportDate ?? event.originDate else { return false }
        let age = now.timeIntervalSince(timestamp)
        return age >= -allowedFutureSkew && age <= maximumAge
    }
}

/// Selects the foreground-only TV/Watch headline from an arbitrary snapshot.
/// A fresh actionable warning takes precedence; retained or future-dated EEW
/// frames fall back to the newest ordinary earthquake report.
enum ForegroundHeadlinePolicy {
    static func headline(from events: [EEWEvent], now: Date = Date()) -> EEWEvent? {
        let newestFirst = events.sorted {
            let leftDate = $0.reportDate ?? $0.originDate ?? .distantPast
            let rightDate = $1.reportDate ?? $1.originDate ?? .distantPast
            if leftDate != rightDate { return leftDate > rightDate }
            return $0.id < $1.id
        }

        return newestFirst.first {
            $0.isActiveWarning && WarningFreshnessPolicy.isFresh($0, now: now)
        } ?? newestFirst.first {
            $0.kind == "report"
        }
    }
}

enum CompassDirection: CaseIterable {
    case n, ne, e, se, s, sw, w, nw

    init(bearingDegrees: Double) {
        let index = Int((bearingDegrees / 45).rounded()) % 8
        self = CompassDirection.allCases[index]
    }

    var labelKey: LocalizedStringKey {
        switch self {
        case .n: return "compass.n"
        case .ne: return "compass.ne"
        case .e: return "compass.e"
        case .se: return "compass.se"
        case .s: return "compass.s"
        case .sw: return "compass.sw"
        case .w: return "compass.w"
        case .nw: return "compass.nw"
        }
    }
}
