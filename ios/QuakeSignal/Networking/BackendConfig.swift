import Foundation

/// Points at the notification-only Cloudflare service. Earthquake data never
/// uses this URL; iOS fetches it directly from Wolfx. Local development and CI
/// can override notification registration with `QUAKESIGNAL_API_BASE_URL`.
enum BackendConfig {
    /// Release bundles the user-approved public Cloudflare Workers endpoint.
    /// Local development and CI can still override it with the process
    /// environment without changing client code.
    private static let defaultBaseURL =
        Bundle.main.object(forInfoDictionaryKey: "QUAKESIGNAL_API_BASE_URL") as? String
        ?? "https://quakesignal-api.hopeso.workers.dev"

    static let httpBaseURL: URL = {
        let value = ProcessInfo.processInfo.environment["QUAKESIGNAL_API_BASE_URL"] ?? defaultBaseURL
        guard let url = URL(string: value), let scheme = url.scheme, ["http", "https"].contains(scheme) else {
            preconditionFailure("QUAKESIGNAL_API_BASE_URL must be an absolute HTTP(S) URL")
        }
        return url
    }()
}
