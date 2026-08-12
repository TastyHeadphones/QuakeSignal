import Foundation

struct DeviceRegistrationRequest: Encodable {
    let token: String
    let environment: String // "sandbox" | "production"
    let locale: String
    let sources: [String]
    let minMagnitude: Double
    let cityName: String?
    let latitude: Double?
    let longitude: Double?
    let radiusKm: Double?
    let includeTestAlerts: Bool
    let utcOffsetMinutes: Int
    let notifyAtNight: Bool
}

/// The token-bearing request shared by the test-alert endpoint and the
/// token-specific form of deletion. Keep this model separate from
/// `DeviceDeletionRequest`: a deletion is also valid when the app no longer
/// has an in-memory APNs token and the server identifies the registration from
/// the App Attest credential instead.
struct DeviceTokenRequest: Encodable, Equatable {
    let token: String
}

/// A device deletion can be bound to an APNs token when one is still present,
/// or to the authenticated App Attest credential alone after an APNs token has
/// been cleared or has not yet been delivered during this launch.
///
/// Encoding a missing token as `{}` rather than `{"token": null}` makes the
/// server contract unambiguous and keeps the exact signed App Attest body
/// stable. The Worker treats this as a request to delete the registration for
/// the authenticated App Attest key.
struct DeviceDeletionRequest: Encodable, Equatable {
    let token: String?

    private enum CodingKeys: String, CodingKey {
        case token
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let token {
            try container.encode(token, forKey: .token)
        }
    }
}
