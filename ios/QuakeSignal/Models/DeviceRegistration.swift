import Foundation

struct DeviceRegistrationRequest: Encodable {
    let token: String
    let environment: String // "sandbox" | "production"
    let locale: String
    let sources: [String]
    let minMagnitude: Double
    let criticalAlertsEnabled: Bool
    let cityName: String?
    let latitude: Double?
    let longitude: Double?
    let radiusKm: Double?
    let includeTestAlerts: Bool
    let utcOffsetMinutes: Int
    let notifyAtNight: Bool
}

struct DeviceRegistrationResponse: Decodable {
    let token: String
    let environment: String
    let locale: String?
    let sources: [String]
    let minMagnitude: Double
    let criticalAlertsEnabled: Bool
    let cityName: String?
    let latitude: Double?
    let longitude: Double?
    let radiusKm: Double?
    let includeTestAlerts: Bool
    let createdAt: String
    let updatedAt: String
}
