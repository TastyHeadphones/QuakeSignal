import Foundation

/// Capabilities that differ even when the same SwiftUI application binary can
/// run on several Apple platforms. Keep the decision at the edge of the app so
/// the protected registration path itself never grows a platform bypass.
enum PlatformCapabilities {
    /// QuakeSignal's background alert service requires both App Attest and
    /// APNs. Mac does not support App Attest, and Apple's visionOS provisioning
    /// capability table does not support Push or Time Sensitive Notifications.
    /// Those experiences therefore stay foreground/local-only even though
    /// visionOS itself supports App Attest.
    static var supportsAttestedAlertRegistration: Bool {
#if targetEnvironment(macCatalyst)
        false
#elseif os(iOS)
        !ProcessInfo.processInfo.isiOSAppOnMac
#elseif os(visionOS)
        false
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
