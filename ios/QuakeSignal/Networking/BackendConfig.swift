import Foundation

/// Points at the production QuakeSignal backend (see /backend). Local
/// development and CI can override it with the
/// `QUAKESIGNAL_API_BASE_URL` launch environment variable.
enum BackendConfig {
    private static let defaultBaseURL = "https://quakesignal-api.hopeso.workers.dev"

    static let httpBaseURL: URL = {
        let value = ProcessInfo.processInfo.environment["QUAKESIGNAL_API_BASE_URL"] ?? defaultBaseURL
        guard let url = URL(string: value), let scheme = url.scheme, ["http", "https"].contains(scheme) else {
            preconditionFailure("QUAKESIGNAL_API_BASE_URL must be an absolute HTTP(S) URL")
        }
        return url
    }()

    static let liveSocketURL: URL = {
        var components = URLComponents(url: httpBaseURL, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/v1/live"
        components.query = nil
        components.fragment = nil
        return components.url!
    }()
}
