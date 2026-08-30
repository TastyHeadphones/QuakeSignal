import CoreFoundation
import Foundation

enum LiveSocketLivenessPolicy {
    static let silenceTimeout: TimeInterval = 90

    static func isStale(lastActivity: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(lastActivity) > silenceTimeout
    }

    /// A heartbeat-only connection proves transport liveness, not that the
    /// route honored its initial data query. Bound that state separately so a
    /// silent query failure cannot suppress real-time monitoring forever.
    static func shouldReconnect(
        isReady: Bool,
        connectedAt: Date,
        lastActivity: Date,
        now: Date = Date()
    ) -> Bool {
        if !isReady, now.timeIntervalSince(connectedAt) > silenceTimeout {
            return true
        }
        return isStale(lastActivity: lastActivity, now: now)
    }
}

enum LiveSocketPayload: Equatable {
    case keepAlive
    case events([EEWEvent])
    case invalid
}

/// Classifies one WebSocket frame without letting transport activity
/// impersonate a usable data route. HTTP and WebSocket snapshots share the
/// same fail-closed normalizer; a malformed data frame makes the route
/// unavailable until a later validated snapshot arrives.
enum LiveSocketPayloadPolicy {
    static func decode(source: String, data: Data) -> LiveSocketPayload {
        guard WolfxClient.sources.contains(source),
              let object = try? JSONSerialization.jsonObject(with: data) as? WolfxNormalizer.Object else {
            return .invalid
        }
        if let type = object["type"] as? String,
           type == "heartbeat" || type == "pong" {
            return WolfxControlFramePolicy.isValid(object) ? .keepAlive : .invalid
        }
        guard object["type"] as? String == source,
              let events = try? WolfxNormalizer.validatedEvents(source: source, data: data) else {
            return .invalid
        }
        return .events(events)
    }

    static func routeIsReady(wasReady: Bool, payload: LiveSocketPayload) -> Bool {
        switch payload {
        case .keepAlive:
            return wasReady
        case .events:
            return true
        case .invalid:
            return false
        }
    }

}

/// Wolfx's published WebSocket examples and the current production service use
/// two canonical encodings for control-frame identity/timestamps. Accept those
/// exact forms, while rejecting coerced strings/numbers that could otherwise
/// keep a malformed data route marked ready indefinitely.
enum WolfxControlFramePolicy {
    private static let maximumVersion = 99_999_999
    private static let maximumDecimalIDDigits = 20
    private static let minimumEpochMilliseconds: Int64 = 1_000_000_000_000
    private static let maximumEpochMilliseconds: Int64 = 9_999_999_999_999

    static func isValid(_ object: WolfxNormalizer.Object) -> Bool {
        switch object["type"] as? String {
        case "heartbeat":
            return validVersion(object["ver"]) &&
                validConnectionID(object["id"]) &&
                validTimestamp(object["timestamp"])
        case "pong":
            return validTimestamp(object["timestamp"])
        default:
            return false
        }
    }

    private static func validVersion(_ value: Any?) -> Bool {
        guard let integer = safeInteger(value) else { return false }
        return (1...Int64(maximumVersion)).contains(integer)
    }

    private static func validConnectionID(_ value: Any?) -> Bool {
        guard let value = value as? String else { return false }
        if value.wholeMatch(
            of: /[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/
        ) != nil {
            return true
        }
        return value.count <= maximumDecimalIDDigits &&
            value.wholeMatch(of: /[1-9]\d*/) != nil
    }

    private static func validTimestamp(_ value: Any?) -> Bool {
        if let string = value as? String {
            guard string.wholeMatch(of: /[1-9]\d{12}/) != nil,
                  let integer = Int64(string),
                  String(integer) == string else { return false }
            return (minimumEpochMilliseconds...maximumEpochMilliseconds).contains(integer)
        }
        guard let integer = safeInteger(value) else { return false }
        return (minimumEpochMilliseconds...maximumEpochMilliseconds).contains(integer)
    }

    private static func safeInteger(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite,
              double.rounded(.towardZero) == double,
              double >= Double(Int64.min),
              double <= Double(Int64.max) else { return nil }
        return Int64(double)
    }
}

private enum WolfxRoute: Hashable {
    case source(String)

    var endpoint: String {
        switch self {
        case .source(let source): return source
        }
    }

    var initialQueries: [String] {
        switch self {
        case .source("jma_eew"):
            return ["query_jmaeew"]
        case .source("jma_eqlist"):
            return ["query_jmaeqlist"]
        case .source("sc_eew"):
            return ["query_sceew"]
        case .source("cenc_eew"):
            return ["query_cenceew"]
        case .source("fj_eew"):
            return ["query_fjeew"]
        case .source("cq_eew"):
            return ["query_cqeew"]
        case .source("cenc_eqlist"):
            return ["query_cenceqlist"]
        case .source:
            return []
        }
    }

    var sourceIDs: Set<String> {
        switch self {
        case .source(let source): return [source]
        }
    }
}

/// Foreground-only direct connections to Wolfx. APNs remains the background
/// path, but Cloudflare is never used as a data relay.
@Observable
@MainActor
final class LiveSocketClient {
    private static let routes: [WolfxRoute] = EarthquakeSources.wolfx.map(WolfxRoute.source)

    private(set) var isConnected = false
    var onEvents: (([EEWEvent], Bool) -> Void)?
    /// Reports transitions between a fully live socket set and an incomplete
    /// one. The foreground store uses this to enable a deliberately slow HTTP
    /// fallback only while a Wolfx WebSocket route remains unavailable.
    var onConnectionStateChanged: ((Bool) -> Void)?

    private var tasks: [WolfxRoute: URLSessionWebSocketTask] = [:]
    private var readyRoutes: Set<WolfxRoute> = []
    private var seededSources: Set<String> = []
    private var reconnectDelays: [WolfxRoute: TimeInterval] = [:]
    private var watchdogTasks: [WolfxRoute: Task<Void, Never>] = [:]
    private var connectedAtByRoute: [WolfxRoute: Date] = [:]
    private var lastActivityByRoute: [WolfxRoute: Date] = [:]
    private var shouldReconnect = true
    private let session: URLSession

    init(session: URLSession = WolfxURLSessionPolicy.makeSession()) {
        self.session = session
    }

    func start() {
        stop()
        shouldReconnect = true
        seededSources.removeAll()
        for route in Self.routes {
            connect(route)
        }
    }

    func stop() {
        shouldReconnect = false
        for task in tasks.values {
            task.cancel(with: .goingAway, reason: nil)
        }
        for watchdog in watchdogTasks.values {
            watchdog.cancel()
        }
        tasks.removeAll()
        watchdogTasks.removeAll()
        connectedAtByRoute.removeAll()
        lastActivityByRoute.removeAll()
        readyRoutes.removeAll()
        updateConnectionState()
    }

    private func connect(_ route: WolfxRoute) {
        guard shouldReconnect,
              let url = URL(string: "wss://ws-api.wolfx.jp/\(route.endpoint)") else { return }

        readyRoutes.remove(route)
        updateConnectionState()
        let task = session.webSocketTask(with: url)
        // Every connection begins with retained snapshots. Mark the first
        // frame for each route source as baseline again; QuakeStore's
        // monotonic comparison can still recognize a genuinely newer warning.
        seededSources.subtract(route.sourceIDs)
        tasks[route] = task
        let connectedAt = Date()
        connectedAtByRoute[route] = connectedAt
        lastActivityByRoute[route] = connectedAt
        task.resume()
        receiveNext(route, task: task)
        startWatchdog(route, task: task)

        Task {
            for query in route.initialQueries {
                try? await task.send(.string(query))
            }
        }
    }

    private func receiveNext(_ route: WolfxRoute, task: URLSessionWebSocketTask) {
        task.receive { [weak self, weak task] result in
            Task { @MainActor in
                guard let self, let task, self.tasks[route] === task else { return }
                switch result {
                case .success(let message):
                    let payload: LiveSocketPayload = switch message {
                    case .string(let text):
                        text.data(using: .utf8).map {
                            self.decode($0, route: route)
                        } ?? .invalid
                    case .data(let data):
                        self.decode(data, route: route)
                    @unknown default:
                        .invalid
                    }

                    let wasReady = self.readyRoutes.contains(route)
                    self.lastActivityByRoute[route] = Date()
                    if LiveSocketPayloadPolicy.routeIsReady(
                        wasReady: wasReady,
                        payload: payload
                    ) {
                        self.readyRoutes.insert(route)
                    } else {
                        self.readyRoutes.remove(route)
                    }
                    self.updateConnectionState()

                    switch payload {
                    case .keepAlive:
                        break
                    case .events(let events):
                        self.reconnectDelays[route] = 1
                        self.deliver(events, route: route)
                    case .invalid:
                        self.watchdogTasks[route]?.cancel()
                        self.watchdogTasks[route] = nil
                        task.cancel(with: .goingAway, reason: nil)
                        self.tasks[route] = nil
                        self.connectedAtByRoute[route] = nil
                        self.lastActivityByRoute[route] = nil
                        self.scheduleReconnect(route)
                        return
                    }
                    self.receiveNext(route, task: task)

                case .failure:
                    self.watchdogTasks[route]?.cancel()
                    self.watchdogTasks[route] = nil
                    self.connectedAtByRoute[route] = nil
                    self.lastActivityByRoute[route] = nil
                    self.tasks[route] = nil
                    self.readyRoutes.remove(route)
                    self.updateConnectionState()
                    self.scheduleReconnect(route)
                }
            }
        }
    }

    private func decode(_ data: Data, route: WolfxRoute) -> LiveSocketPayload {
        let source: String
        switch route {
        case .source(let sourceID): source = sourceID
        }
        return LiveSocketPayloadPolicy.decode(source: source, data: data)
    }

    private func deliver(_ events: [EEWEvent], route: WolfxRoute) {
        let source: String
        switch route {
        case .source(let sourceID): source = sourceID
        }
        let isBackfill = seededSources.insert(source).inserted
        onEvents?(events, isBackfill)
    }

    private func scheduleReconnect(_ route: WolfxRoute) {
        guard shouldReconnect else { return }
        let delay = reconnectDelays[route] ?? 1
        reconnectDelays[route] = min(delay * 2, 30)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.shouldReconnect, self.tasks[route] == nil else { return }
            self.connect(route)
        }
    }

    private func startWatchdog(_ route: WolfxRoute, task: URLSessionWebSocketTask) {
        watchdogTasks[route]?.cancel()
        watchdogTasks[route] = Task { @MainActor [weak self, weak task] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    return
                }
                guard let self, let task, self.tasks[route] === task else { return }
                let connectedAt = self.connectedAtByRoute[route] ?? .distantPast
                let lastActivity = self.lastActivityByRoute[route] ?? .distantPast
                guard LiveSocketLivenessPolicy.shouldReconnect(
                    isReady: self.readyRoutes.contains(route),
                    connectedAt: connectedAt,
                    lastActivity: lastActivity
                ) else { continue }

                task.cancel(with: .goingAway, reason: nil)
                self.tasks[route] = nil
                self.readyRoutes.remove(route)
                self.connectedAtByRoute[route] = nil
                self.lastActivityByRoute[route] = nil
                self.watchdogTasks[route] = nil
                self.updateConnectionState()
                self.scheduleReconnect(route)
                return
            }
        }
    }

    private func updateConnectionState() {
        let nextState = readyRoutes.count == Self.routes.count
        guard isConnected != nextState else { return }
        isConnected = nextState
        onConnectionStateChanged?(nextState)
    }
}
