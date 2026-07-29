import Foundation

enum WolfxError: LocalizedError {
    case invalidResponse

    var errorDescription: String? {
        "Invalid response from Wolfx"
    }
}

/// Fetches earthquake data straight from the public Wolfx API. Cloudflare is
/// intentionally not part of foreground data access; it only delivers APNs.
final class WolfxClient: Sendable {
    static let shared = WolfxClient()

    static let sources = [
        "jma_eew", "sc_eew", "cenc_eew", "fj_eew", "cq_eew",
        "cenc_eqlist", "jma_eqlist",
    ]

    private let session: URLSession = .shared
    private let httpBaseURL = URL(string: "https://api.wolfx.jp")!

    func fetchRecentQuakes(limit: Int = 50) async throws -> [EEWEvent] {
        let batches = try await withThrowingTaskGroup(of: [EEWEvent].self) { group in
            for source in Self.sources {
                group.addTask { [session, httpBaseURL] in
                    let url = httpBaseURL.appending(path: "\(source).json")
                    let (data, response) = try await session.data(from: url)
                    guard let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode) else {
                        throw WolfxError.invalidResponse
                    }
                    return WolfxNormalizer.events(source: source, data: data)
                }
            }

            var output: [[EEWEvent]] = []
            for try await batch in group {
                output.append(batch)
            }
            return output
        }

        var newestByID: [String: EEWEvent] = [:]
        for event in batches.flatMap({ $0 }) {
            if let existing = newestByID[event.id],
               existing.serial > event.serial {
                continue
            }
            newestByID[event.id] = event
        }

        return newestByID.values
            .sorted { ($0.reportTimeUtc ?? $0.originTimeUtc ?? "") > ($1.reportTimeUtc ?? $1.originTimeUtc ?? "") }
            .prefix(max(1, limit))
            .map { $0 }
    }
}

enum WolfxNormalizer {
    typealias Object = [String: Any]

    static func events(source: String, data: Data) -> [EEWEvent] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? Object else {
            return []
        }
        return events(source: source, object: object)
    }

    static func events(source: String, object: Object) -> [EEWEvent] {
        switch source {
        case "jma_eew":
            return normalizeJmaEew(object).map { [$0] } ?? []
        case "sc_eew", "fj_eew":
            return normalizeScFjEew(object, source: source).map { [$0] } ?? []
        case "cenc_eew", "cq_eew":
            return normalizeCencCqEew(object, source: source).map { [$0] } ?? []
        case "cenc_eqlist":
            return rankedEntries(object).compactMap(normalizeCencEqlist)
        case "jma_eqlist":
            return rankedEntries(object).compactMap(normalizeJmaEqlist)
        default:
            return []
        }
    }

    private static func normalizeJmaEew(_ value: Object) -> EEWEvent? {
        guard let eventID = string(value["EventID"]), !eventID.isEmpty else { return nil }
        return EEWEvent(
            id: "jma_eew:\(eventID)",
            sourceId: "jma_eew",
            eventId: eventID,
            serial: int(value["Serial"]) ?? 1,
            kind: "eew",
            originTimeUtc: localDate(string(value["OriginTime"]), offsetHours: 9),
            reportTimeUtc: localDate(string(value["AnnouncedTime"]), offsetHours: 9),
            hypocenter: string(value["Hypocenter"]) ?? "",
            latitude: number(value["Latitude"]),
            longitude: number(value["Longitude"]),
            magnitude: number(value["Magunitude"]),
            depth: number(value["Depth"]),
            maxIntensity: string(value["MaxIntensity"]),
            isWarn: bool(value["isWarn"]),
            isFinal: bool(value["isFinal"]),
            isCancel: bool(value["isCancel"]),
            isTraining: bool(value["isTraining"]),
            tsunami: nil
        )
    }

    private static func normalizeScFjEew(_ value: Object, source: String) -> EEWEvent? {
        guard let eventID = string(value["EventID"]), !eventID.isEmpty else { return nil }
        return EEWEvent(
            id: "\(source):\(eventID)",
            sourceId: source,
            eventId: eventID,
            serial: int(value["ReportNum"]) ?? 1,
            kind: "eew",
            originTimeUtc: localDate(string(value["OriginTime"]), offsetHours: 8),
            reportTimeUtc: localDate(string(value["ReportTime"]), offsetHours: 8),
            hypocenter: string(value["HypoCenter"]) ?? "",
            latitude: number(value["Latitude"]),
            longitude: number(value["Longitude"]),
            magnitude: number(value["Magunitude"]),
            depth: number(value["Depth"]),
            maxIntensity: string(value["MaxIntensity"]),
            isWarn: true,
            isFinal: bool(value["isFinal"]),
            isCancel: false,
            isTraining: false,
            tsunami: nil
        )
    }

    private static func normalizeCencCqEew(_ value: Object, source: String) -> EEWEvent? {
        guard let eventID = string(value["EventID"]), !eventID.isEmpty else { return nil }
        return EEWEvent(
            id: "\(source):\(eventID)",
            sourceId: source,
            eventId: eventID,
            serial: int(value["ReportNum"]) ?? 1,
            kind: "eew",
            originTimeUtc: localDate(string(value["OriginTime"]), offsetHours: 8),
            reportTimeUtc: localDate(string(value["ReportTime"]), offsetHours: 8),
            hypocenter: string(value["HypoCenter"]) ?? "",
            latitude: number(value["Latitude"]),
            longitude: number(value["Longitude"]),
            magnitude: number(value["Magnitude"]),
            depth: number(value["Depth"]),
            maxIntensity: number(value["MaxIntensity"]).map { String(format: "%.1f", $0) },
            isWarn: true,
            isFinal: false,
            isCancel: false,
            isTraining: false,
            tsunami: nil
        )
    }

    private static func normalizeCencEqlist(_ value: Object) -> EEWEvent? {
        guard let eventID = string(value["EventID"]), !eventID.isEmpty else { return nil }
        let reviewed = string(value["type"]) == "reviewed"
        return EEWEvent(
            id: "cenc_eqlist:\(eventID)",
            sourceId: "cenc_eqlist",
            eventId: eventID,
            serial: reviewed ? 2 : 1,
            kind: "report",
            originTimeUtc: localDate(string(value["time"]), offsetHours: 8),
            reportTimeUtc: localDate(string(value["ReportTime"]), offsetHours: 8),
            hypocenter: string(value["placeName"]) ?? string(value["location"]) ?? "",
            latitude: number(value["latitude"]),
            longitude: number(value["longitude"]),
            magnitude: number(value["magnitude"]),
            depth: number(value["depth"]),
            maxIntensity: string(value["intensity"]),
            isWarn: false,
            isFinal: reviewed,
            isCancel: false,
            isTraining: false,
            tsunami: nil
        )
    }

    private static func normalizeJmaEqlist(_ value: Object) -> EEWEvent? {
        guard let eventID = string(value["EventID"]), !eventID.isEmpty else { return nil }
        let time = string(value["time_full"]) ?? string(value["time"])
        return EEWEvent(
            id: "jma_eqlist:\(eventID)",
            sourceId: "jma_eqlist",
            eventId: eventID,
            serial: 1,
            kind: "report",
            originTimeUtc: localDate(time, offsetHours: 9),
            reportTimeUtc: localDate(time, offsetHours: 9),
            hypocenter: string(value["location"]) ?? "",
            latitude: number(value["latitude"]),
            longitude: number(value["longitude"]),
            magnitude: number(value["magnitude"]),
            depth: number(value["depth"]),
            maxIntensity: string(value["shindo"]),
            isWarn: false,
            isFinal: true,
            isCancel: false,
            isTraining: false,
            tsunami: string(value["info"])
        )
    }

    private static func rankedEntries(_ object: Object) -> [Object] {
        object.compactMap { key, value -> (Int, Object)? in
            guard key.hasPrefix("No"),
                  let rank = Int(key.dropFirst(2)),
                  let entry = value as? Object else { return nil }
            return (rank, entry)
        }
        .sorted { $0.0 < $1.0 }
        .map(\.1)
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            return value.isEmpty ? nil : value
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        guard let raw = value as? String, !raw.isEmpty else { return nil }
        let cleaned = raw.filter { "0123456789.+-".contains($0) }
        return Double(cleaned)
    }

    private static func int(_ value: Any?) -> Int? {
        number(value).map(Int.init)
    }

    private static func bool(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            return ["true", "1", "yes"].contains(string.lowercased())
        }
        return false
    }

    private static func localDate(_ raw: String?, offsetHours: Int) -> String? {
        guard let raw,
              let match = raw.wholeMatch(of: /(\d{4})[\/-](\d{2})[\/-](\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?/) else {
            return nil
        }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: offsetHours * 3600)
        components.year = Int(match.1)
        components.month = Int(match.2)
        components.day = Int(match.3)
        components.hour = Int(match.4)
        components.minute = Int(match.5)
        components.second = match.6.flatMap { Int($0) } ?? 0
        guard let date = components.date else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
