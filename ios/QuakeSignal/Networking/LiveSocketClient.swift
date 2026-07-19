import Foundation

private struct LiveEnvelope: Decodable {
    let type: String
    let reason: String
    let event: EEWEvent
}

/// Persistent connection to the backend's `/v1/live` fan-out socket, so the
/// foreground app gets sub-second updates without polling. Reconnects with
/// exponential backoff on drop. Background delivery is handled separately by
/// APNs -- this socket is a foreground-only latency optimization.
@Observable
@MainActor
final class LiveSocketClient {
    private(set) var isConnected = false
    var onEvent: ((EEWEvent, String) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var reconnectDelay: TimeInterval = 1
    private var shouldReconnect = true

    func start() {
        shouldReconnect = true
        connect()
    }

    func stop() {
        shouldReconnect = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isConnected = false
    }

    private func connect() {
        let socketTask = URLSession.shared.webSocketTask(with: BackendConfig.liveSocketURL)
        task = socketTask
        socketTask.resume()
        isConnected = true
        reconnectDelay = 1
        receiveNext()
    }

    private func receiveNext() {
        guard let task else { return }
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let message):
                    if case .string(let text) = message {
                        self.handle(text)
                    }
                    self.receiveNext()
                case .failure:
                    self.isConnected = false
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        guard let envelope = try? JSONDecoder().decode(LiveEnvelope.self, from: data), envelope.type == "quake" else { return }
        onEvent?(envelope.event, envelope.reason)
    }

    private func scheduleReconnect() {
        guard shouldReconnect else { return }
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 30)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.shouldReconnect else { return }
            self.connect()
        }
    }
}
