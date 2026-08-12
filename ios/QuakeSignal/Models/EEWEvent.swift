import SwiftUI
import CoreLocation

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
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    func distanceKm(from coordinate: CLLocationCoordinate2D) -> Double? {
        guard let latitude, let longitude else { return nil }
        let eventLocation = CLLocation(latitude: latitude, longitude: longitude)
        let fromLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return eventLocation.distance(from: fromLocation) / 1000.0
    }

    /// Simplified EEW countdown: estimated S-wave (strong shaking) arrival,
    /// assuming a typical shallow-crust S-wave velocity. Real EEW systems
    /// factor in depth, wave-propagation models, and per-station travel
    /// times; this is a deliberately simple approximation for a "how long do
    /// I have" display, not a precise seismological estimate.
    static let sWaveVelocityKmPerSecond = 4.0

    func secondsUntilShaking(at coordinate: CLLocationCoordinate2D, now: Date = Date()) -> Int? {
        guard let originDate, let distance = distanceKm(from: coordinate) else { return nil }
        let estimatedArrival = originDate.addingTimeInterval(distance / Self.sWaveVelocityKmPerSecond)
        let remaining = estimatedArrival.timeIntervalSince(now)
        return remaining > 0 ? Int(remaining.rounded()) : nil
    }

    /// 8-point compass direction from `coordinate` to this event's epicenter, e.g. "NW".
    func compassDirection(from coordinate: CLLocationCoordinate2D) -> CompassDirection? {
        guard let latitude, let longitude else { return nil }
        let lat1 = coordinate.latitude * .pi / 180
        let lat2 = latitude * .pi / 180
        let deltaLon = (longitude - coordinate.longitude) * .pi / 180
        let y = sin(deltaLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLon)
        let bearingDegrees = (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        return CompassDirection(bearingDegrees: bearingDegrees)
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
