import Foundation

/// Points at the QuakeSignal backend (see /backend). Defaults to localhost
/// for Simulator development against `npm run dev`. iOS exempts literal
/// "localhost" from App Transport Security, so this works with plain HTTP/WS
/// for local dev with no Info.plist changes -- but a real deployment MUST
/// use https/wss with a valid certificate; ATS will block plain HTTP to any
/// other host by default, which is the correct behavior to keep.
enum BackendConfig {
    static let httpBaseURL = URL(string: "http://localhost:8080")!
    static let liveSocketURL = URL(string: "ws://localhost:8080/v1/live")!
}
