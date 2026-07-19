import Foundation

/// The custom (non-`aps`) keys the backend attaches to every push -- see
/// `buildRawPayload` in backend/src/push/payload.ts.
struct PushPayload {
    let eventId: String?
    let sourceId: String?
    let reason: String?

    init(userInfo: [AnyHashable: Any]) {
        eventId = userInfo["eventId"] as? String
        sourceId = userInfo["sourceId"] as? String
        reason = userInfo["reason"] as? String
    }

    /// Matches the backend's `NormalizedEvent.id` format (`${sourceId}:${eventId}`).
    var compositeEventId: String? {
        guard let sourceId, let eventId else { return nil }
        return "\(sourceId):\(eventId)"
    }
}
