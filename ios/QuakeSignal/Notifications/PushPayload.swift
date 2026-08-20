import Foundation

/// The custom (non-`aps`) keys the backend attaches to every push -- see
/// `buildRawPayload` in backend/src/push/payload.ts.
struct PushPayload {
    let eventId: String?
    let sourceId: String?
    let reason: String?
    let eventSnapshot: EEWEvent?

    init(userInfo: [AnyHashable: Any]) {
        let parsedEventID = Self.nonEmptyString(userInfo["eventId"])
        let parsedSourceID = Self.nonEmptyString(userInfo["sourceId"]).flatMap {
            WolfxClient.sources.contains($0) ? $0 : nil
        }
        eventId = parsedEventID
        sourceId = parsedSourceID
        reason = userInfo["reason"] as? String
        let snapshot = userInfo["event"] ?? userInfo["eventSnapshot"]
        if var snapshotObject = snapshot as? [String: Any],
           let parsedEventID,
           let parsedSourceID {
            if snapshotObject["id"] == nil,
               let snapshotSource = snapshotObject["sourceId"] as? String,
               let snapshotEventID = snapshotObject["eventId"] as? String {
                snapshotObject["id"] = "\(snapshotSource):\(snapshotEventID)"
            }
            let data = JSONSerialization.isValidJSONObject(snapshotObject)
                ? try? JSONSerialization.data(withJSONObject: snapshotObject)
                : nil
            if let data, data.count <= 3_500,
               let decoded = try? JSONDecoder().decode(EEWEvent.self, from: data),
               Self.isStructurallyUsable(
                   decoded,
                   matchingSourceID: parsedSourceID,
                   eventID: parsedEventID
               ) {
                eventSnapshot = decoded
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

    /// The foreground app may suppress APNs' banner and sound only when this
    /// snapshot can be consumed immediately. A cache lookup or network refresh
    /// is deliberately not sufficient: either can fail after `willPresent`
    /// has already returned its irreversible system-presentation decision.
    var hasUsableMatchingEventSnapshot: Bool {
        eventSnapshot != nil
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private static func isStructurallyUsable(
        _ event: EEWEvent,
        matchingSourceID sourceID: String,
        eventID: String
    ) -> Bool {
        guard event.sourceId == sourceID,
              event.eventId == eventID,
              event.id == "\(sourceID):\(eventID)",
              event.serial >= 0,
              !event.hypocenter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              event.originDate != nil,
              event.reportDate != nil,
              event.coordinate != nil,
              let magnitude = event.magnitude,
              magnitude.isFinite,
              event.depth?.isFinite != false else {
            return false
        }

        switch sourceID {
        case "jma_eew":
            return event.kind == "eew"
        case "jma_eqlist":
            return event.kind == "report"
        default:
            return false
        }
    }
}
