import Foundation

enum CatalogClientError: LocalizedError {
    case invalidResponse(source: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let source):
            return L("error.wolfx.invalidResponse", source)
        }
    }
}

/// HTTP snapshots for USGS, EMSC, and GeoNet. Uses the same ephemeral session
/// policy as Wolfx so catalog traffic also creates no on-disk cache.
final class CatalogClient: Sendable {
    static let shared = CatalogClient()
    static let sources = EarthquakeSources.catalog

    private static let endpoints: [String: URL] = [
        "usgs_eqlist": URL(string: "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/4.5_day.geojson")!,
        "emsc_eqlist": URL(string: "https://www.seismicportal.eu/fdsnws/event/1/query?format=json&limit=50&minmag=4.5&orderby=time")!,
        "geonet_eqlist": URL(string: "https://api.geonet.org.nz/quake?MMI=4")!,
    ]

    private let session: URLSession

    init(session: URLSession = WolfxURLSessionPolicy.makeSession()) {
        self.session = session
    }

    func fetchRecentQuakesAllowingPartialResults(limit: Int = 50) async throws -> WolfxSnapshotFetchResult {
        let outcomes = try await withThrowingTaskGroup(of: SourceFetchOutcome.self) { group in
            for source in Self.sources {
                group.addTask { [session] in
                    do {
                        try Task.checkCancellation()
                        return .success(
                            source: source,
                            events: try await Self.fetchEvents(session: session, source: source)
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
            for try await outcome in group { output.append(outcome) }
            return output
        }

        var batches: [[EEWEvent]] = []
        var failed: [String] = []
        var successCount = 0
        for outcome in outcomes {
            switch outcome {
            case .success(_, let events):
                batches.append(events)
                successCount += 1
            case .failure(let source):
                failed.append(source)
            }
        }
        return WolfxSnapshotFetchResult.aggregate(
            batches: batches,
            failedSources: failed,
            successfulSourceCount: successCount,
            limit: limit
        )
    }

    private static func fetchEvents(session: URLSession, source: String) async throws -> [EEWEvent] {
        guard let url = endpoints[source] else {
            throw CatalogClientError.invalidResponse(source: source)
        }
        var request = WolfxURLSessionPolicy.request(for: url)
        request.setValue(
            "QuakeSignal/1.2 (https://github.com/TastyHeadphones/QuakeSignal)",
            forHTTPHeaderField: "User-Agent"
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw CatalogClientError.invalidResponse(source: source)
        }
        return try CatalogNormalizer.validatedEvents(source: source, data: data)
    }

    private enum SourceFetchOutcome: Sendable {
        case success(source: String, events: [EEWEvent])
        case failure(source: String)
    }
}

enum CatalogNormalizer {
    typealias Object = [String: Any]
    private static let maximumEvents = 50

    static func events(source: String, data: Data) -> [EEWEvent] {
        (try? validatedEvents(source: source, data: data)) ?? []
    }

    static func validatedEvents(source: String, data: Data) throws -> [EEWEvent] {
        guard EarthquakeSources.isCatalog(source),
              let json = try? JSONSerialization.jsonObject(with: data),
              let object = json as? Object else {
            throw CatalogClientError.invalidResponse(source: source)
        }
        return try validatedEvents(source: source, object: object)
    }

    static func validatedEvents(source: String, object: Object) throws -> [EEWEvent] {
        guard object["type"] as? String == "FeatureCollection",
              let features = object["features"] as? [Any] else {
            throw CatalogClientError.invalidResponse(source: source)
        }
        var events: [EEWEvent] = []
        for feature in features.prefix(maximumEvents) {
            guard let record = feature as? Object,
                  let event = event(source: source, feature: record) else {
                continue
            }
            events.append(event)
        }
        let unique = Set(events.map(\.id))
        guard unique.count == events.count else {
            throw CatalogClientError.invalidResponse(source: source)
        }
        return events
    }

    private static func event(source: String, feature: Object) -> EEWEvent? {
        guard feature["type"] as? String == "Feature" else { return nil }
        let properties = feature["properties"] as? Object ?? [:]
        if source == "usgs_eqlist",
           let type = properties["type"] as? String,
           type != "earthquake" {
            return nil
        }
        let eventID = identifier(feature: feature, properties: properties)
        let hypocenter = place(properties)
        let magnitude = finiteNumber(properties["mag"] ?? properties["magnitude"])
        let origin = timestamp(properties["time"] ?? properties["origintime"] ?? properties["origin_time"])
        let reported = timestamp(properties["updated"] ?? properties["lastupdate"]) ?? origin
        let coordinates = point(feature["geometry"])
        guard let eventID, !hypocenter.isEmpty, let magnitude, let origin, let coordinates else {
            return nil
        }
        return EEWEvent(
            id: "\(source):\(eventID)",
            sourceId: source,
            eventId: eventID,
            serial: 1,
            kind: "report",
            originTimeUtc: origin,
            reportTimeUtc: reported,
            hypocenter: hypocenter,
            latitude: coordinates.latitude,
            longitude: coordinates.longitude,
            magnitude: magnitude,
            depth: coordinates.depth,
            maxIntensity: intensity(properties),
            isWarn: false,
            isFinal: true,
            isCancel: false,
            isTraining: false,
            tsunami: tsunami(properties)
        )
    }

    private static func identifier(feature: Object, properties: Object) -> String? {
        if let value = feature["id"] as? String, !value.trimmingCharacters(in: .whitespaces).isEmpty {
            return value
        }
        if let value = feature["id"] as? NSNumber { return value.stringValue }
        for key in ["publicid", "code", "unid"] {
            if let value = properties[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private static func place(_ properties: Object) -> String {
        for key in ["place", "flynn_region", "locality", "title", "region"] {
            if let value = properties[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return ""
    }

    private static func intensity(_ properties: Object) -> String? {
        if let value = properties["mmi"] ?? properties["intensity"] {
            return String(describing: value)
        }
        return nil
    }

    private static func tsunami(_ properties: Object) -> String? {
        let value = properties["tsunami"]
        if value as? Int == 1 || value as? Bool == true { return "tsunami" }
        if let text = value as? String, text != "0", !text.isEmpty { return text }
        return nil
    }

    private static func point(_ geometry: Any?) -> (latitude: Double, longitude: Double, depth: Double?)? {
        guard let object = geometry as? Object,
              object["type"] as? String == "Point",
              let coordinates = object["coordinates"] as? [Any],
              coordinates.count >= 2,
              let longitude = finiteNumber(coordinates[0]),
              let latitude = finiteNumber(coordinates[1]) else {
            return nil
        }
        let depth = coordinates.count > 2 ? finiteNumber(coordinates[2]) : nil
        return (latitude, longitude, depth)
    }

    private static func timestamp(_ value: Any?) -> String? {
        if let number = finiteNumber(value) {
            let millis = number > 1_000_000_000_000 ? number : number * 1_000
            return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: millis / 1_000))
        }
        if let text = value as? String, let parsed = parseISO8601(text) {
            return ISO8601DateFormatter().string(from: parsed)
        }
        return nil
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func finiteNumber(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            let double = number.doubleValue
            return double.isFinite ? double : nil
        }
        if let text = value as? String {
            let double = Double(text)
            return double?.isFinite == true ? double : nil
        }
        return nil
    }
}
