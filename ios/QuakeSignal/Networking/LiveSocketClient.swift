import Foundation

enum LiveSocketLivenessPolicy {
    static let silenceTimeout: TimeInterval = 90

    static func isStale(lastActivity: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(lastActivity) > silenceTimeout
    }
}

private enum WolfxRoute: Hashable {
    case combinedEEW
    case source(String)

    var endpoint: String {
        switch self {
        case .combinedEEW: return "all_eew"
        case .source(let source): return source
        }
    }

    var initialQueries: [String] {
        switch self {
        case .combinedEEW:
            return [
                "query_jmaeew", "query_sceew", "query_cenceew",
                "query_fjeew", "query_cqeew",
            ]
        case .source("cenc_eqlist"):
            return ["query_cenceqlist"]
        case .source("jma_eqlist"):
            return ["query_jmaeqlist"]
        case .source:
            return []
        }
    }

    var sourceIDs: Set<String> {
        switch self {
        case .combinedEEW:
            return ["jma_eew", "sc_eew", "cenc_eew", "fj_eew", "cq_eew"]
        case .source(let source):
            return [source]
        }
    }
}

/// Foreground-only direct connections to Wolfx. APNs remains the background
/// path, but Cloudflare is never used as a data relay.
@Observable
@MainActor
final class LiveSocketClient {
    private static let routes: [WolfxRoute] = [
        .combinedEEW,
        .source("cenc_eqlist"),
        .source("jma_eqlist"),
    ]

    private(set) var isConnected = false
    var onEvents: (([EEWEvent], Bool) -> Void)?
    /// Reports transitions between a fully live socket set and an incomplete
    /// one. The foreground store uses this to enable a deliberately slow HTTP
    /// fallback only while a Wolfx WebSocket route remains unavailable.
    var onConnectionStateChanged: ((Bool) -> Void)?

    private var tasks: [WolfxRoute: URLSessionWebSocketTask] = [:]
    private var connectedRoutes: Set<WolfxRoute> = []
    private var seededSources: Set<String> = []
    private var reconnectDelays: [WolfxRoute: TimeInterval] = [:]
    private var watchdogTasks: [WolfxRoute: Task<Void, Never>] = [:]
    private var lastActivityByRoute: [WolfxRoute: Date] = [:]
    private var shouldReconnect = true

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
        lastActivityByRoute.removeAll()
        connectedRoutes.removeAll()
        updateConnectionState()
    }

    private func connect(_ route: WolfxRoute) {
        guard shouldReconnect,
              let url = URL(string: "wss://ws-api.wolfx.jp/\(route.endpoint)") else { return }

        let task = URLSession.shared.webSocketTask(with: url)
        // Every connection begins with retained snapshots. Mark the first
        // frame for each route source as baseline again; QuakeStore's
        // monotonic comparison can still recognize a genuinely newer warning.
        seededSources.subtract(route.sourceIDs)
        tasks[route] = task
        lastActivityByRoute[route] = Date()
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
                    self.lastActivityByRoute[route] = Date()
                    self.connectedRoutes.insert(route)
                    self.reconnectDelays[route] = 1
                    self.updateConnectionState()

                    switch message {
                    case .string(let text):
                        self.handle(text, route: route)
                    case .data(let data):
                        self.handle(data, route: route)
                    @unknown default:
                        break
                    }
                    self.receiveNext(route, task: task)

                case .failure:
                    self.watchdogTasks[route]?.cancel()
                    self.watchdogTasks[route] = nil
                    self.lastActivityByRoute[route] = nil
                    self.tasks[route] = nil
                    self.connectedRoutes.remove(route)
                    self.updateConnectionState()
                    self.scheduleReconnect(route)
                }
            }
        }
    }

    private func handle(_ text: String, route: WolfxRoute) {
        guard let data = text.data(using: .utf8) else { return }
        handle(data, route: route)
    }

    private func handle(_ data: Data, route: WolfxRoute) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? WolfxNormalizer.Object else {
            return
        }
        if let type = object["type"] as? String, type == "heartbeat" || type == "pong" {
            return
        }

        let source: String?
        switch route {
        case .combinedEEW:
            source = object["type"] as? String
        case .source(let sourceID):
            source = sourceID
        }

        guard let source, WolfxClient.sources.contains(source) else { return }
        let events = WolfxNormalizer.events(source: source, object: object)
        guard !events.isEmpty else { return }

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
                let lastActivity = self.lastActivityByRoute[route] ?? .distantPast
                guard LiveSocketLivenessPolicy.isStale(lastActivity: lastActivity) else { continue }

                task.cancel(with: .goingAway, reason: nil)
                self.tasks[route] = nil
                self.connectedRoutes.remove(route)
                self.lastActivityByRoute[route] = nil
                self.watchdogTasks[route] = nil
                self.updateConnectionState()
                self.scheduleReconnect(route)
                return
            }
        }
    }

    private func updateConnectionState() {
        let nextState = connectedRoutes.count == Self.routes.count
        guard isConnected != nextState else { return }
        isConnected = nextState
        onConnectionStateChanged?(nextState)
    }
}
