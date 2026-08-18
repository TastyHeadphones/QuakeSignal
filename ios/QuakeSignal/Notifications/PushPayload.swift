import Foundation

/// The custom (non-`aps`) keys the backend attaches to every push -- see
/// `buildRawPayload` in backend/src/push/payload.ts.
struct PushPayload {
    let eventId: String?
    let sourceId: String?
    let reason: String?
    let eventSnapshot: EEWEvent?

    init(userInfo: [AnyHashable: Any]) {
        eventId = userInfo["eventId"] as? String
        sourceId = userInfo["sourceId"] as? String
        reason = userInfo["reason"] as? String
        let snapshot = userInfo["event"] ?? userInfo["eventSnapshot"]
        if var snapshotObject = snapshot as? [String: Any] {
            if snapshotObject["id"] == nil,
               let snapshotSource = snapshotObject["sourceId"] as? String,
               let snapshotEventID = snapshotObject["eventId"] as? String {
                snapshotObject["id"] = "\(snapshotSource):\(snapshotEventID)"
            }
            let data = JSONSerialization.isValidJSONObject(snapshotObject)
                ? try? JSONSerialization.data(withJSONObject: snapshotObject)
                : nil
            if let data, data.count <= 3_500 {
                eventSnapshot = try? JSONDecoder().decode(EEWEvent.self, from: data)
            } else {
                eventSnapshot = nil
            }
        } else {
            eventSnapshot = nil
        }
    }

    /// Matches the backend's `NormalizedEvent.id` format (`${sourceId}:${eventId}`).
    var compositeEventId: String? {
        guard let sourceId, let eventId else { return nil }
        return "\(sourceId):\(eventId)"
    }
}
