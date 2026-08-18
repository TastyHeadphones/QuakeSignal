import Foundation

/// Capabilities that differ even when the same SwiftUI application binary can
/// run on several Apple platforms. Keep the decision at the edge of the app so
/// the protected registration path itself never grows a platform bypass.
enum PlatformCapabilities {
    /// QuakeSignal's background alert service requires App Attest. Apple does
    /// not support App Attest on Mac, including Mac Catalyst and an iOS app
    /// running on Apple silicon, so those experiences stay foreground-only.
    static var supportsAttestedAlertRegistration: Bool {
#if targetEnvironment(macCatalyst)
        false
#elseif os(iOS)
        !ProcessInfo.processInfo.isiOSAppOnMac
#elseif os(visionOS)
        true
#else
        false
#endif
    }
}

enum PlatformCapabilityError: LocalizedError {
    case attestedAlertRegistrationUnavailable

    var errorDescription: String? {
        switch self {
        case .attestedAlertRegistrationUnavailable:
            return String(localized: "platform.alertRegistration.unavailable.error")
        }
    }
}
