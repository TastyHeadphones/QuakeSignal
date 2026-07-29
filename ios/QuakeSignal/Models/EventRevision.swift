import Foundation

/// One in-memory snapshot in an event's report-update timeline.
struct EventRevision: Codable, Identifiable, Equatable {
    let eventRef: String
    let serial: Int
    let magnitude: Double?
    let maxIntensity: String?
    let isWarn: Bool
    let isFinal: Bool
    let isCancel: Bool
    let reportTimeUtc: String?
    let recordedAtUtc: String

    var id: String { "\(eventRef)#\(serial)" }

    var reportDate: Date? {
        guard let reportTimeUtc else { return nil }
        return ISO8601DateFormatter().date(from: reportTimeUtc)
    }
}
