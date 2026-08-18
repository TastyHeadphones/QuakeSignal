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
    let alertSound: AlertSoundPreference
}

/// The token-bearing request used by the ordinary, user-visible test alert.
/// It intentionally contains no client-selectable delivery mode.
struct DeviceTokenRequest: Encodable, Equatable {
    let token: String
}

#if QUAKESIGNAL_INTERNAL_QA
/// A fixed server-side background-delivery verification request. This type is
/// compiled only into the controlled InternalQA configuration, never into the
/// public Release archive.
struct DelayedTrainingTestRequest: Encodable, Equatable {
    private enum Delivery: String, Encodable {
        case delayedTraining = "delayed-training"
    }

    let token: String

    private enum CodingKeys: String, CodingKey {
        case token
        case delivery
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(token, forKey: .token)
        try container.encode(Delivery.delayedTraining, forKey: .delivery)
    }
}
#endif

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
