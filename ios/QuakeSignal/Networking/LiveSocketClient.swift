import Foundation

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

    private var tasks: [WolfxRoute: URLSessionWebSocketTask] = [:]
    private var connectedRoutes: Set<WolfxRoute> = []
    private var seededSources: Set<String> = []
    private var reconnectDelays: [WolfxRoute: TimeInterval] = [:]
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
        tasks.removeAll()
        connectedRoutes.removeAll()
        isConnected = false
    }

    private func connect(_ route: WolfxRoute) {
        guard shouldReconnect,
              let url = URL(string: "wss://ws-api.wolfx.jp/\(route.endpoint)") else { return }

        let task = URLSession.shared.webSocketTask(with: url)
        tasks[route] = task
        task.resume()
        receiveNext(route, task: task)

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
                    self.connectedRoutes.insert(route)
                    self.reconnectDelays[route] = 1
                    self.isConnected = self.connectedRoutes.count == Self.routes.count

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
                    self.tasks[route] = nil
                    self.connectedRoutes.remove(route)
                    self.isConnected = false
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
}
