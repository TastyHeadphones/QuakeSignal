import CoreFoundation
import Foundation

/// The custom (non-`aps`) keys the backend attaches to every push -- see
/// `buildRawPayload` in backend/src/push/payload.ts.
struct PushPayload {
    let eventId: String?
    let sourceId: String?
    let reason: String?
    let eventSnapshot: EEWEvent?
    let foregroundRevisionKey: ForegroundEmergencyRevisionKey?

    init(userInfo: [AnyHashable: Any]) {
        let parsedEventID = Self.nonEmptyString(userInfo["eventId"])
        let parsedSourceID = Self.nonEmptyString(userInfo["sourceId"]).flatMap {
            EarthquakeSources.all.contains($0) ? $0 : nil
        }
        eventId = parsedEventID
        sourceId = parsedSourceID
        reason = userInfo["reason"] as? String
        let snapshot = userInfo["event"] ?? userInfo["eventSnapshot"]
        let parsedSnapshot: EEWEvent?
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
                parsedSnapshot = decoded
            } else {
                parsedSnapshot = nil
            }
        } else {
            parsedSnapshot = nil
        }
        eventSnapshot = parsedSnapshot
        foregroundRevisionKey = parsedSnapshot.map {
            ForegroundEmergencyRevisionOwnershipPolicy.key(for: $0)
        } ?? Self.legacyRevisionKey(
            userInfo: userInfo,
            sourceID: parsedSourceID,
            eventID: parsedEventID
        )
    }

    /// Matches the backend's `NormalizedEvent.id` format (`${sourceId}:${eventId}`).
    var compositeEventId: String? {
        guard let sourceId, let eventId else { return nil }
        return "\(sourceId):\(eventId)"
    }

    /// A usable snapshot grants the foreground app one synchronous opportunity
    /// to take ownership; APNs is suppressed only after the store confirms it
    /// handled that revision or already elevated a newer active revision. A
    /// cache lookup or network refresh is not sufficient because either can
    /// fail after `willPresent` returns.
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

    /// Older/smaller backend payloads may omit the typed event snapshot. Only
    /// a complete, strictly typed top-level revision boundary may then reserve
    /// system presentation; an event ID alone could hide a newer live warning.
    private static func legacyRevisionKey(
        userInfo: [AnyHashable: Any],
        sourceID: String?,
        eventID: String?
    ) -> ForegroundEmergencyRevisionKey? {
        guard let sourceID,
              let eventID,
              let kind = nonEmptyString(userInfo["kind"]),
              (sourceID == "jma_eew" && kind == "eew") ||
                (sourceID == "cenc_eew" && kind == "eew") ||
                (sourceID == "sc_eew" && kind == "eew") ||
                (sourceID == "fj_eew" && kind == "eew") ||
                (sourceID == "cq_eew" && kind == "eew") ||
                (sourceID == "jma_eqlist" && kind == "report") ||
                (sourceID == "cenc_eqlist" && kind == "report") ||
                (EarthquakeSources.isCatalog(sourceID) && kind == "report"),
              let serial = nonnegativeInteger(userInfo["serial"]),
              let isWarning = strictBoolean(userInfo["isWarn"]),
              let isFinal = strictBoolean(userInfo["isFinal"]),
              let isCancelled = strictBoolean(userInfo["isCancel"]),
              let isTraining = strictBoolean(userInfo["isTraining"]),
              let effectiveTimestamp = parsedTimestamp(userInfo["reportTimeUtc"])
                ?? parsedTimestamp(userInfo["originTimeUtc"]) else {
            return nil
        }
        return ForegroundEmergencyRevisionKey(
            eventID: "\(sourceID):\(eventID)",
            serial: serial,
            kind: kind,
            isWarning: isWarning,
            isFinal: isFinal,
            isCancelled: isCancelled,
            isTraining: isTraining,
            effectiveTimestamp: effectiveTimestamp
        )
    }

    private static func nonnegativeInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite,
              double >= 0,
              double.rounded(.towardZero) == double,
              double <= Double(Int.max),
              let integer = Int(exactly: double) else { return nil }
        return integer
    }

    private static func strictBoolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func parsedTimestamp(_ value: Any?) -> Date? {
        guard let value = nonEmptyString(value) else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
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
        case "jma_eew", "cenc_eew", "sc_eew", "fj_eew", "cq_eew":
            return event.kind == "eew"
        case "jma_eqlist", "cenc_eqlist":
            return event.kind == "report"
        case "usgs_eqlist", "emsc_eqlist", "geonet_eqlist":
            return event.kind == "report"
        default:
            return false
        }
    }
}
