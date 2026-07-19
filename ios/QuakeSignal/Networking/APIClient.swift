import Foundation

enum APIError: LocalizedError {
    case server(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .server(let message): return message
        case .invalidResponse: return "Invalid response from server"
        }
    }
}

final class APIClient: Sendable {
    static let shared = APIClient()
    private let session: URLSession = .shared

    func registerDevice(_ request: DeviceRegistrationRequest) async throws -> DeviceRegistrationResponse {
        var urlRequest = URLRequest(url: BackendConfig.httpBaseURL.appending(path: "/v1/devices"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await session.data(for: urlRequest)
        try Self.validate(response, data: data)
        return try JSONDecoder().decode(DeviceRegistrationResponse.self, from: data)
    }

    func deleteDevice(token: String) async throws {
        var urlRequest = URLRequest(url: BackendConfig.httpBaseURL.appending(path: "/v1/devices/\(token)"))
        urlRequest.httpMethod = "DELETE"
        let (data, response) = try await session.data(for: urlRequest)
        try Self.validate(response, data: data)
    }

    func sendTestAlert(token: String) async throws {
        var urlRequest = URLRequest(url: BackendConfig.httpBaseURL.appending(path: "/v1/devices/\(token)/test"))
        urlRequest.httpMethod = "POST"
        let (data, response) = try await session.data(for: urlRequest)
        try Self.validate(response, data: data)
    }

    func fetchRecentQuakes(limit: Int = 50) async throws -> [EEWEvent] {
        let url = BackendConfig.httpBaseURL
            .appending(path: "/v1/quakes/recent")
            .appending(queryItems: [URLQueryItem(name: "limit", value: String(limit))])
        let (data, response) = try await session.data(from: url)
        try Self.validate(response, data: data)
        return try JSONDecoder().decode([EEWEvent].self, from: data)
    }

    func fetchQuakeDetail(id: String) async throws -> QuakeDetailResponse {
        let url = BackendConfig.httpBaseURL.appending(path: "/v1/quakes/\(id)")
        let (data, response) = try await session.data(from: url)
        try Self.validate(response, data: data)
        return try JSONDecoder().decode(QuakeDetailResponse.self, from: data)
    }

    private static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if let object = try? JSONDecoder().decode([String: String].self, from: data), let message = object["error"] {
                throw APIError.server(message)
            }
            throw APIError.server("HTTP \(http.statusCode)")
        }
    }
}
