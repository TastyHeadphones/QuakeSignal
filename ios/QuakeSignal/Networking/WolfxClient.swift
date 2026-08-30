import CoreFoundation
import Foundation

/// Direct Wolfx earthquake feeds plus official catalog companions. Keep this
/// identical to the Worker APNs relay Wolfx allow-list.
enum EarthquakeSources {
    static let wolfx = [
        "jma_eew",
        "jma_eqlist",
        "cenc_eew",
        "cenc_eqlist",
        "sc_eew",
        "fj_eew",
        "cq_eew",
    ]
    static let catalog = ["usgs_eqlist", "emsc_eqlist", "geonet_eqlist"]
    static let all = wolfx + catalog

    static func isCatalog(_ source: String) -> Bool {
        catalog.contains(source)
    }
}

enum WolfxError: LocalizedError {
    case invalidResponse(source: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let source):
            return L("error.wolfx.invalidResponse", source)
        }
    }
}

/// The result used by the WebSocket-outage fallback. Unlike an explicit user
/// refresh, it preserves data from every HTTP source that answered even when
/// one of the other public endpoints is temporarily unavailable.
struct WolfxSnapshotFetchResult: Sendable {
    let events: [EEWEvent]
    let failedSources: [String]
    let successfulSourceCount: Int

    var hasSuccessfulSources: Bool { successfulSourceCount > 0 }

    /// Suitable for the existing non-blocking offline banner. It intentionally
    /// gives a compact source summary instead of exposing transport internals.
    var statusDescription: String? {
        guard !failedSources.isEmpty else { return nil }
        let unavailable = failedSources.joined(separator: ", ")
        if successfulSourceCount == 0 {
            return "Earthquake snapshot unavailable; affected sources: \(unavailable)."
        }
        let total = successfulSourceCount + failedSources.count
        return "Updated from \(successfulSourceCount) of \(total) sources; unavailable: \(unavailable)."
    }

    static func aggregate(
        batches: [[EEWEvent]],
        failedSources: [String],
        successfulSourceCount: Int,
        limit: Int
    ) -> WolfxSnapshotFetchResult {
        var newestByID: [String: EEWEvent] = [:]
        for event in batches.flatMap({ $0 }) {
            if let existing = newestByID[event.id], existing.serial > event.serial {
                continue
            }
            newestByID[event.id] = event
        }

        return WolfxSnapshotFetchResult(
            events: newestByID.values
                .sorted { ($0.reportTimeUtc ?? $0.originTimeUtc ?? "") > ($1.reportTimeUtc ?? $1.originTimeUtc ?? "") }
                .prefix(max(1, limit))
                .map { $0 },
            failedSources: failedSources.sorted(),
            successfulSourceCount: successfulSourceCount
        )
    }
}

/// Wolfx documents a two-requests-per-second public API ceiling. Both manual
/// refreshes and the foreground WebSocket-recovery fallback share this pacing
/// so a multi-source snapshot never creates a burst.
enum WolfxHTTPFetchPacing {
    static let requestIntervalNanoseconds: UInt64 = 600_000_000

    static func delayNanoseconds(forSourceIndex index: Int) -> UInt64 {
        UInt64(max(0, index)) * requestIntervalNanoseconds
    }
}

/// Direct Wolfx traffic must not create an on-disk HTTP cache, cookie jar, or
/// credential store. The companion targets intentionally keep report state in
/// memory only, and the full-interface Apple targets make the same guarantee
/// for fetched report payloads.
enum WolfxURLSessionPolicy {
    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return configuration
    }

    static func makeSession() -> URLSession {
        URLSession(configuration: configuration())
    }

    static func request(for url: URL) -> URLRequest {
        URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData
        )
    }
}

/// Drives a manual foreground refresh through SwiftUI's scene-bound `.task`.
/// Including scene activity in `TaskID` makes deactivation cancel the task
/// immediately, while clearing the pending request prevents a refresh replay
/// when the scene later becomes active again.
struct ForegroundManualRefreshLifecycle: Equatable, Sendable {
    struct TaskID: Equatable, Sendable {
        let isSceneActive: Bool
        let requestID: UInt64?
    }

    private(set) var pendingRequestID: UInt64?
    private var nextRequestID: UInt64 = 0

    func taskID(isSceneActive: Bool) -> TaskID {
        TaskID(isSceneActive: isSceneActive, requestID: pendingRequestID)
    }

    func shouldRun(isSceneActive: Bool) -> Bool {
        isSceneActive && pendingRequestID != nil
    }

    mutating func requestRefresh(isSceneActive: Bool) {
        guard isSceneActive else { return }
        nextRequestID &+= 1
        pendingRequestID = nextRequestID
    }

    mutating func cancelPendingRefresh() {
        pendingRequestID = nil
    }
}

/// A process-wide reservation gate. Multiple refreshes can overlap (manual,
/// startup, and socket recovery), so per-refresh index delays alone do not
/// enforce Wolfx's aggregate two-requests-per-second ceiling.
actor WolfxHTTPRequestPacer {
    static let shared = WolfxHTTPRequestPacer()

    private var nextRequestUptimeNanoseconds: UInt64 = 0

    func waitForTurn() async throws {
        let now = DispatchTime.now().uptimeNanoseconds
        let scheduled = max(now, nextRequestUptimeNanoseconds)
        nextRequestUptimeNanoseconds = scheduled + WolfxHTTPFetchPacing.requestIntervalNanoseconds
        if scheduled > now {
            try await Task.sleep(nanoseconds: scheduled - now)
        }
        try Task.checkCancellation()
    }
}

/// Fetches earthquake data straight from the public Wolfx API. Cloudflare is
/// intentionally not part of foreground data access; it only delivers APNs.
final class WolfxClient: Sendable {
    static let shared = WolfxClient()

    /// Direct Wolfx HTTP/WebSocket earthquake feeds. Keep this identical to
    /// `EarthquakeSources.wolfx` and the Worker APNs relay Wolfx allow-list.
    static let sources = EarthquakeSources.wolfx

    private let session: URLSession
    private let httpBaseURL: URL

    init(
        session: URLSession = WolfxURLSessionPolicy.makeSession(),
        httpBaseURL: URL = URL(string: "https://api.wolfx.jp")!
    ) {
        self.session = session
        self.httpBaseURL = httpBaseURL
    }

    /// The standard explicit-refresh behavior: any endpoint failure reports a
    /// refresh error rather than presenting a deliberately partial result.
    func fetchRecentQuakes(limit: Int = 50) async throws -> [EEWEvent] {
        let batches = try await withThrowingTaskGroup(of: [EEWEvent].self) { group in
            for source in Self.sources {
                group.addTask { [session, httpBaseURL] in
                    try await WolfxHTTPRequestPacer.shared.waitForTurn()
                    return try await Self.fetchEvents(
                        session: session,
                        httpBaseURL: httpBaseURL,
                        source: source
                    )
                }
            }

            var output: [[EEWEvent]] = []
            for try await batch in group {
                output.append(batch)
            }
            return output
        }

        return WolfxSnapshotFetchResult.aggregate(
            batches: batches,
            failedSources: [],
            successfulSourceCount: Self.sources.count,
            limit: limit
        ).events
    }

    /// Used only for the bounded foreground recovery path after a sustained
    /// WebSocket outage. Source-level HTTP failures are collected so healthy
    /// sources still refresh the UI; cancellation still propagates normally.
    func fetchRecentQuakesAllowingPartialResults(limit: Int = 50) async throws -> WolfxSnapshotFetchResult {
        let outcomes = try await withThrowingTaskGroup(of: SourceFetchOutcome.self) { group in
            for source in Self.sources {
                group.addTask { [session, httpBaseURL] in
                    do {
                        try await WolfxHTTPRequestPacer.shared.waitForTurn()
                        try Task.checkCancellation()
                        return .success(
                            source: source,
                            events: try await Self.fetchEvents(
                                session: session,
                                httpBaseURL: httpBaseURL,
                                source: source
                            )
                        )
                    } catch {
                        if error is CancellationError || Task.isCancelled {
                            throw CancellationError()
                        }
                        return .failure(source: source)
                    }
                }
            }

            var output: [SourceFetchOutcome] = []
            for try await outcome in group {
                output.append(outcome)
            }
            return output
        }

        var batches: [[EEWEvent]] = []
        var failedSources: [String] = []
        var successfulSourceCount = 0
        for outcome in outcomes {
            switch outcome {
            case let .success(_, events):
                successfulSourceCount += 1
                batches.append(events)
            case let .failure(source):
                failedSources.append(source)
            }
        }

        return WolfxSnapshotFetchResult.aggregate(
            batches: batches,
            failedSources: failedSources,
            successfulSourceCount: successfulSourceCount,
            limit: limit
        )
    }

    private static func fetchEvents(
        session: URLSession,
        httpBaseURL: URL,
        source: String
    ) async throws -> [EEWEvent] {
        let url = httpBaseURL.appending(path: "\(source).json")
        let request = WolfxURLSessionPolicy.request(for: url)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw WolfxError.invalidResponse(source: source)
        }
        return try WolfxNormalizer.validatedEvents(source: source, data: data)
    }

    private enum SourceFetchOutcome: Sendable {
        case success(source: String, events: [EEWEvent])
        case failure(source: String)
    }
}

enum WolfxNormalizer {
    typealias Object = [String: Any]

    private struct JmaCalendarParts {
        let year: Int
        let month: Int
        let day: Int
        let hour: Int
        let minute: Int
        let second: Int
    }

    private static let minimumMagnitude = -2.0
    private static let maximumMagnitude = 12.0
    private static let maximumDepthKm = 1_000.0
    private static let jmaIntensities: Set<String> = [
        "0", "1", "2", "3", "4", "5-", "5+", "6-", "6+", "7",
    ]

    static func events(source: String, data: Data) -> [EEWEvent] {
        (try? validatedEvents(source: source, data: data)) ?? []
    }

    /// HTTP snapshots fail closed. Wolfx's documented feeds retain at least
    /// one event, so malformed JSON, an idle-looking empty object, a wrong
    /// source envelope, or a partially normalizable list is a source failure
    /// rather than a successful empty refresh.
    static func validatedEvents(source: String, data: Data) throws -> [EEWEvent] {
        guard WolfxClient.sources.contains(source),
              let json = try? JSONSerialization.jsonObject(with: data),
              let object = json as? Object else {
            throw WolfxError.invalidResponse(source: source)
        }
        return try validatedEvents(source: source, object: object)
    }

    static func events(source: String, object: Object) -> [EEWEvent] {
        (try? validatedEvents(source: source, object: object)) ?? []
    }

    private static func validatedEvents(source: String, object: Object) throws -> [EEWEvent] {
        if let declaredSource = object["type"] {
            guard declaredSource as? String == source else {
                throw WolfxError.invalidResponse(source: source)
            }
        }

        let events: [EEWEvent]
        switch source {
        case "jma_eew":
            events = [try validatedJmaEew(object)]
        case "jma_eqlist":
            events = try validatedJmaEqlist(object)
        case "sc_eew", "fj_eew":
            events = [try validatedScFjEew(object, source: source)]
        case "cenc_eew", "cq_eew":
            events = [try validatedCencCqEew(object, source: source)]
        case "cenc_eqlist":
            events = try validatedCencEqlist(object)
        default:
            throw WolfxError.invalidResponse(source: source)
        }

        guard !events.isEmpty,
              Set(events.map(\.id)).count == events.count,
              events.allSatisfy({ event in
                  event.sourceId == source &&
                  !event.eventId.isEmpty &&
                  event.serial > 0 &&
                  (event.reportDate ?? event.originDate) != nil &&
                  event.coordinate != nil
              }) else {
            throw WolfxError.invalidResponse(source: source)
        }
        return events
    }

    private static func validatedJmaEew(_ value: Object) throws -> EEWEvent {
        guard nonEmptyString(value["Title"]) != nil,
              nonEmptyString(value["CodeType"]) != nil,
              let issue = value["Issue"] as? Object,
              nonEmptyString(issue["Source"]) != nil,
              nonEmptyString(issue["Status"]) != nil,
              let eventID = string(value["EventID"]),
              parseEventID(eventID) != nil,
              let serial = positiveInteger(value["Serial"]),
              let originRaw = string(value["OriginTime"]),
              let origin = parseDateTime(originRaw, includesSeconds: true),
              let announcedRaw = string(value["AnnouncedTime"]),
              let announced = parseDateTime(announcedRaw, includesSeconds: true),
              milliseconds(announced) >= milliseconds(origin),
              let hypocenter = nonEmptyString(value["Hypocenter"]),
              let latitude = finiteJSONNumber(value["Latitude"]), (-90...90).contains(latitude),
              let longitude = finiteJSONNumber(value["Longitude"]), (-180...180).contains(longitude),
              let magnitude = finiteJSONNumber(value["Magunitude"]),
              (minimumMagnitude...maximumMagnitude).contains(magnitude),
              let depth = finiteJSONNumber(value["Depth"]),
              (0...maximumDepthKm).contains(depth),
              let maxIntensity = string(value["MaxIntensity"]),
              jmaIntensities.contains(maxIntensity),
              let isWarn = strictBoolean(value["isWarn"]),
              let isFinal = strictBoolean(value["isFinal"]),
              let isCancel = strictBoolean(value["isCancel"]),
              let isTraining = strictBoolean(value["isTraining"]),
              strictBoolean(value["isSea"]) != nil,
              strictBoolean(value["isAssumption"]) != nil,
              value["OriginalText"] is String,
              let accuracy = value["Accuracy"] as? Object,
              accuracy["Epicenter"] is String,
              accuracy["Depth"] is String,
              accuracy["Magnitude"] is String,
              let maxIntChange = value["MaxIntChange"] as? Object,
              maxIntChange["String"] is String,
              maxIntChange["Reason"] is String,
              let warnAreas = value["WarnArea"] as? [Any],
              warnAreas.allSatisfy(isValidWarnArea) else {
            throw WolfxError.invalidResponse(source: "jma_eew")
        }

        return EEWEvent(
            id: "jma_eew:\(eventID)",
            sourceId: "jma_eew",
            eventId: eventID,
            serial: serial,
            kind: "eew",
            originTimeUtc: iso8601(origin, offsetHours: 9),
            reportTimeUtc: iso8601(announced, offsetHours: 9),
            hypocenter: hypocenter,
            latitude: latitude,
            longitude: longitude,
            magnitude: magnitude,
            depth: depth,
            maxIntensity: maxIntensity,
            isWarn: isWarn,
            isFinal: isFinal,
            isCancel: isCancel,
            isTraining: isTraining,
            tsunami: nil
        )
    }

    private static func validatedJmaEqlist(_ value: Object) throws -> [EEWEvent] {
        guard let md5 = string(value["md5"]),
              md5.wholeMatch(of: /[0-9a-f]{32}/) != nil else {
            throw WolfxError.invalidResponse(source: "jma_eqlist")
        }
        let ranked = rankedEntries(value)
        let rankedKeys = value.keys.filter { $0.hasPrefix("No") }
        guard !ranked.isEmpty,
              ranked.count <= 50,
              rankedKeys.count == ranked.count,
              ranked.enumerated().allSatisfy({ index, item in item.rank == index + 1 }) else {
            throw WolfxError.invalidResponse(source: "jma_eqlist")
        }
        return try ranked.map { try validatedJmaEqlistEntry($0.entry) }
    }

    private static func validatedJmaEqlistEntry(_ value: Object) throws -> EEWEvent {
        guard nonEmptyString(value["Title"]) != nil,
              let eventID = string(value["EventID"]),
              parseEventID(eventID) != nil,
              let minuteRaw = string(value["time"]),
              let minute = parseDateTime(minuteRaw, includesSeconds: false),
              let fullRaw = string(value["time_full"]),
              let full = parseDateTime(fullRaw, includesSeconds: true),
              sameMinute(minute, full),
              let hypocenter = nonEmptyString(value["location"]),
              let magnitude = canonicalDecimal(value["magnitude"]),
              (minimumMagnitude...maximumMagnitude).contains(magnitude),
              let maxIntensity = string(value["shindo"]),
              jmaIntensities.contains(maxIntensity),
              let depth = canonicalDepth(value["depth"]),
              let latitude = canonicalDecimal(value["latitude"]), (-90...90).contains(latitude),
              let longitude = canonicalDecimal(value["longitude"]), (-180...180).contains(longitude),
              let info = value["info"] as? String else {
            throw WolfxError.invalidResponse(source: "jma_eqlist")
        }

        return EEWEvent(
            id: "jma_eqlist:\(eventID)",
            sourceId: "jma_eqlist",
            eventId: eventID,
            serial: 1,
            kind: "report",
            originTimeUtc: iso8601(full, offsetHours: 9),
            reportTimeUtc: iso8601(full, offsetHours: 9),
            hypocenter: hypocenter,
            latitude: latitude,
            longitude: longitude,
            magnitude: magnitude,
            depth: depth,
            maxIntensity: maxIntensity,
            isWarn: false,
            isFinal: true,
            isCancel: false,
            isTraining: false,
            tsunami: info
        )
    }

    private static func validatedScFjEew(_ value: Object, source: String) throws -> EEWEvent {
        guard let eventID = nonEmptyString(value["EventID"]), eventID.count <= 64,
              let serial = positiveInteger(value["ReportNum"]),
              let originRaw = string(value["OriginTime"]),
              let origin = parseCstDateTime(originRaw),
              let reportRaw = string(value["ReportTime"]),
              let report = parseCstDateTime(reportRaw),
              milliseconds(report) >= milliseconds(origin),
              let hypocenter = nonEmptyString(value["HypoCenter"]),
              let latitude = finiteJSONNumber(value["Latitude"]), (-90...90).contains(latitude),
              let longitude = finiteJSONNumber(value["Longitude"]), (-180...180).contains(longitude),
              let magnitude = finiteJSONNumber(value["Magunitude"]),
              (minimumMagnitude...maximumMagnitude).contains(magnitude) else {
            throw WolfxError.invalidResponse(source: source)
        }
        let depth = finiteJSONNumber(value["Depth"])
        if let depth, !(0...maximumDepthKm).contains(depth) {
            throw WolfxError.invalidResponse(source: source)
        }
        let intensity = finiteJSONNumber(value["MaxIntensity"])
        return EEWEvent(
            id: "\(source):\(eventID)",
            sourceId: source,
            eventId: eventID,
            serial: serial,
            kind: "eew",
            originTimeUtc: iso8601(origin, offsetHours: 8),
            reportTimeUtc: iso8601(report, offsetHours: 8),
            hypocenter: hypocenter,
            latitude: latitude,
            longitude: longitude,
            magnitude: magnitude,
            depth: depth,
            maxIntensity: intensity.map { String(format: "%.1f", $0) },
            isWarn: true,
            isFinal: strictBoolean(value["isFinal"]) ?? false,
            isCancel: false,
            isTraining: false,
            tsunami: nil
        )
    }

    private static func validatedCencCqEew(_ value: Object, source: String) throws -> EEWEvent {
        guard let eventID = nonEmptyString(value["EventID"]), eventID.count <= 64,
              let serial = positiveInteger(value["ReportNum"]),
              let originRaw = string(value["OriginTime"]),
              let origin = parseCstDateTime(originRaw),
              let reportRaw = string(value["ReportTime"]),
              let report = parseCstDateTime(reportRaw),
              milliseconds(report) >= milliseconds(origin),
              let hypocenter = nonEmptyString(value["HypoCenter"]),
              let latitude = finiteJSONNumber(value["Latitude"]), (-90...90).contains(latitude),
              let longitude = finiteJSONNumber(value["Longitude"]), (-180...180).contains(longitude),
              let magnitude = finiteJSONNumber(value["Magnitude"]),
              (minimumMagnitude...maximumMagnitude).contains(magnitude),
              let depth = finiteJSONNumber(value["Depth"]),
              (0...maximumDepthKm).contains(depth) else {
            throw WolfxError.invalidResponse(source: source)
        }
        let intensity = finiteJSONNumber(value["MaxIntensity"])
        return EEWEvent(
            id: "\(source):\(eventID)",
            sourceId: source,
            eventId: eventID,
            serial: serial,
            kind: "eew",
            originTimeUtc: iso8601(origin, offsetHours: 8),
            reportTimeUtc: iso8601(report, offsetHours: 8),
            hypocenter: hypocenter,
            latitude: latitude,
            longitude: longitude,
            magnitude: magnitude,
            depth: depth,
            maxIntensity: intensity.map { String(format: "%.1f", $0) },
            isWarn: true,
            isFinal: false,
            isCancel: false,
            isTraining: false,
            tsunami: nil
        )
    }

    private static func validatedCencEqlist(_ value: Object) throws -> [EEWEvent] {
        guard let md5 = string(value["md5"]),
              md5.wholeMatch(of: /[0-9a-f]{32}/) != nil else {
            throw WolfxError.invalidResponse(source: "cenc_eqlist")
        }
        let ranked = rankedEntries(value)
        let rankedKeys = value.keys.filter { $0.hasPrefix("No") }
        guard !ranked.isEmpty,
              ranked.count <= 50,
              rankedKeys.count == ranked.count,
              ranked.enumerated().allSatisfy({ index, item in item.rank == index + 1 }) else {
            throw WolfxError.invalidResponse(source: "cenc_eqlist")
        }
        return try ranked.map { try validatedCencEqlistEntry($0.entry) }
    }

    private static func validatedCencEqlistEntry(_ value: Object) throws -> EEWEvent {
        guard let eventID = nonEmptyString(value["EventID"]), eventID.count <= 64,
              let originRaw = string(value["time"]),
              let origin = parseCstDateTime(originRaw),
              let reportRaw = string(value["ReportTime"]),
              let report = parseCstDateTime(reportRaw),
              let hypocenter = nonEmptyString(value["placeName"]) ?? nonEmptyString(value["location"]),
              let magnitude = canonicalDecimal(value["magnitude"]),
              (minimumMagnitude...maximumMagnitude).contains(magnitude),
              let latitude = canonicalDecimal(value["latitude"]), (-90...90).contains(latitude),
              let longitude = canonicalDecimal(value["longitude"]), (-180...180).contains(longitude) else {
            throw WolfxError.invalidResponse(source: "cenc_eqlist")
        }
        let reviewed = string(value["type"]) == "reviewed"
        let depth = canonicalDecimal(value["depth"])
        if let depth, !(0...maximumDepthKm).contains(depth) {
            throw WolfxError.invalidResponse(source: "cenc_eqlist")
        }
        return EEWEvent(
            id: "cenc_eqlist:\(eventID)",
            sourceId: "cenc_eqlist",
            eventId: eventID,
            serial: reviewed ? 2 : 1,
            kind: "report",
            originTimeUtc: iso8601(origin, offsetHours: 8),
            reportTimeUtc: iso8601(report, offsetHours: 8),
            hypocenter: hypocenter,
            latitude: latitude,
            longitude: longitude,
            magnitude: magnitude,
            depth: depth,
            maxIntensity: nonEmptyString(value["intensity"]),
            isWarn: false,
            isFinal: reviewed,
            isCancel: false,
            isTraining: false,
            tsunami: nil
        )
    }

    private static func rankedEntries(_ object: Object) -> [(rank: Int, entry: Object)] {
        object.compactMap { key, value -> (Int, Object)? in
            guard key.wholeMatch(of: /No(?:[1-9]|[1-4]\d|50)/) != nil,
                  let rank = Int(key.dropFirst(2)),
                  let entry = value as? Object else { return nil }
            return (rank, entry)
        }
        .sorted { $0.0 < $1.0 }
    }

    private static func string(_ value: Any?) -> String? {
        value as? String
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String,
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return string
    }

    private static func finiteJSONNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    private static func positiveInteger(_ value: Any?) -> Int? {
        guard let number = finiteJSONNumber(value),
              number > 0,
              number.rounded(.towardZero) == number,
              number <= Double(Int.max) else { return nil }
        return Int(number)
    }

    private static func strictBoolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func canonicalDecimal(_ value: Any?) -> Double? {
        guard let raw = value as? String,
              raw.count <= 24,
              raw.wholeMatch(of: /-?(?:0|[1-9]\d*)(?:\.\d+)?/) != nil,
              let parsed = Double(raw), parsed.isFinite else { return nil }
        return parsed
    }

    private static func canonicalDepth(_ value: Any?) -> Double? {
        guard let raw = value as? String,
              let match = raw.wholeMatch(of: /(0|[1-9]\d*)km/),
              let depth = Double(match.1),
              depth <= maximumDepthKm else { return nil }
        return depth
    }

    private static func isValidWarnArea(_ value: Any) -> Bool {
        guard let area = value as? Object else { return false }
        return area["Chiiki"] is String &&
            area["Shindo1"] is String &&
            area["Shindo2"] is String &&
            area["Time"] is String &&
            area["Type"] is String &&
            strictBoolean(area["Arrive"]) != nil
    }

    private static func parseEventID(_ raw: String) -> JmaCalendarParts? {
        guard let match = raw.wholeMatch(of: /([1-9]\d{3})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})/) else {
            return nil
        }
        return validatedParts(
            year: Int(match.1), month: Int(match.2), day: Int(match.3),
            hour: Int(match.4), minute: Int(match.5), second: Int(match.6)
        )
    }

    private static func parseCstDateTime(_ raw: String) -> JmaCalendarParts? {
        guard let match = raw.wholeMatch(of: /([1-9]\d{3})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})/) else {
            return nil
        }
        return validatedParts(
            year: Int(match.1), month: Int(match.2), day: Int(match.3),
            hour: Int(match.4), minute: Int(match.5), second: Int(match.6)
        )
    }

    private static func parseDateTime(_ raw: String, includesSeconds: Bool) -> JmaCalendarParts? {
        if includesSeconds {
            guard let match = raw.wholeMatch(of: /([1-9]\d{3})\/(\d{2})\/(\d{2}) (\d{2}):(\d{2}):(\d{2})/) else {
                return nil
            }
            return validatedParts(
                year: Int(match.1), month: Int(match.2), day: Int(match.3),
                hour: Int(match.4), minute: Int(match.5), second: Int(match.6)
            )
        }
        guard let match = raw.wholeMatch(of: /([1-9]\d{3})\/(\d{2})\/(\d{2}) (\d{2}):(\d{2})/) else {
            return nil
        }
        return validatedParts(
            year: Int(match.1), month: Int(match.2), day: Int(match.3),
            hour: Int(match.4), minute: Int(match.5), second: 0
        )
    }

    private static func validatedParts(
        year: Int?, month: Int?, day: Int?, hour: Int?, minute: Int?, second: Int?
    ) -> JmaCalendarParts? {
        guard let year, let month, let day, let hour, let minute, let second,
              (1_000...9_999).contains(year),
              (1...12).contains(month),
              (0...23).contains(hour),
              (0...59).contains(minute),
              (0...59).contains(second) else { return nil }
        let monthLengths = [
            31, isLeapYear(year) ? 29 : 28, 31, 30, 31, 30,
            31, 31, 30, 31, 30, 31,
        ]
        guard (1...monthLengths[month - 1]).contains(day) else { return nil }
        return JmaCalendarParts(
            year: year, month: month, day: day,
            hour: hour, minute: minute, second: second
        )
    }

    private static func isLeapYear(_ year: Int) -> Bool {
        year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
    }

    private static func sameMinute(_ lhs: JmaCalendarParts, _ rhs: JmaCalendarParts) -> Bool {
        lhs.year == rhs.year && lhs.month == rhs.month && lhs.day == rhs.day &&
            lhs.hour == rhs.hour && lhs.minute == rhs.minute
    }

    private static func milliseconds(_ parts: JmaCalendarParts) -> TimeInterval {
        DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0),
            year: parts.year,
            month: parts.month,
            day: parts.day,
            hour: parts.hour,
            minute: parts.minute,
            second: parts.second
        ).date?.timeIntervalSince1970 ?? -.infinity
    }

    private static func iso8601(_ parts: JmaCalendarParts, offsetHours: Int) -> String? {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: offsetHours * 3_600)
        components.year = parts.year
        components.month = parts.month
        components.day = parts.day
        components.hour = parts.hour
        components.minute = parts.minute
        components.second = parts.second
        guard let date = components.date else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
