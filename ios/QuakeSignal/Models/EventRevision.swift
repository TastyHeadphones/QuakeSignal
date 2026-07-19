import Foundation

/// Mirrors the backend's `EventRevision` (backend/src/types/domain.ts) --
/// one snapshot in an event's report-update timeline.
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

/// The `/v1/quakes/:id` response shape: the event plus its oldest-first revision history.
struct QuakeDetailResponse: Decodable {
    let event: EEWEvent
    let revisions: [EventRevision]
}
