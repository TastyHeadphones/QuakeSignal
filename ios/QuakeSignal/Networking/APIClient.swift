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
    private let appAttest = AppAttestClient.shared

    func registerDevice(_ request: DeviceRegistrationRequest) async throws {
        let body = try JSONEncoder().encode(request)
        try await performProtectedRequest(
            binding: AppAttestRequestBinding(
                operation: .deviceRegistration,
                method: "POST",
                path: "/v1/devices"
            ),
            body: body
        )
    }

    /// Deletes the registration identified by the token when available, or by
    /// the authenticated App Attest key when that key already owns a
    /// registration and APNs has not supplied a token in this launch.
    /// `DeviceDeletionRequest` deliberately encodes the latter case as `{}`;
    /// that exact body is included in the App Attest proof and cannot claim a
    /// legacy registration for a newly created key.
    func deleteDevice(token: String?) async throws {
        let body = try JSONEncoder().encode(DeviceDeletionRequest(token: token))
        try await performProtectedRequest(
            binding: AppAttestRequestBinding(
                operation: .deviceDeletion,
                method: "DELETE",
                path: "/v1/devices"
            ),
            body: body
        )
    }

    func sendTestAlert(token: String) async throws {
        let body = try JSONEncoder().encode(DeviceTokenRequest(token: token))
        try await performProtectedRequest(
            binding: AppAttestRequestBinding(
                operation: .testPush,
                method: "POST",
                path: "/v1/devices/test"
            ),
            body: body
        )
    }

#if QUAKESIGNAL_INTERNAL_QA
    /// Schedules one fixed-delay, clearly labelled training notification for a
    /// controlled TestFlight background/locked/terminated delivery check. The
    /// Worker rejects it unless the reviewed production test window is open.
    /// This request path is excluded from public Release compilation.
    func scheduleDelayedTestAlert(token: String) async throws {
        let body = try JSONEncoder().encode(DelayedTrainingTestRequest(token: token))
        try await performProtectedRequest(
            binding: AppAttestRequestBinding(
                operation: .testPush,
                method: "POST",
                path: "/v1/devices/test"
            ),
            body: body
        )
    }
#endif

    /// App Attest signs `body` before the protected URL request is created. Do
    /// not encode a model a second time here: its exact byte sequence is part
    /// of the proof the Worker validates.
    private func performProtectedRequest(
        binding: AppAttestRequestBinding,
        body: Data
    ) async throws {
        try await appAttest.performProtectedRequest(binding: binding, body: body)
    }

    static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if let object = try? JSONDecoder().decode([String: String].self, from: data), let message = object["error"] {
                throw APIError.server(message)
            }
            throw APIError.server("HTTP \(http.statusCode)")
        }
    }
}
