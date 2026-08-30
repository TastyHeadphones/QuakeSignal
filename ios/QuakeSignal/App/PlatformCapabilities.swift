import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Capabilities that differ even when the same SwiftUI application binary can
/// run on several Apple platforms. Keep the decision at the edge of the app so
/// the protected registration path itself never grows a platform bypass.
enum NativeUIRelaySurface: String, CaseIterable, Equatable {
    case iPhone
    case iPad
    case macCatalyst
    case watch
    case vision
    case other

    /// APNs / App Attest relay registration exists only on iPhone and iPad.
    var registersForNotificationRelay: Bool {
        switch self {
        case .iPhone, .iPad: return true
        case .macCatalyst, .watch, .vision, .other: return false
        }
    }

    var notificationsTitleKey: String {
        registersForNotificationRelay ? "settings.section.notifications" : "settings.foregroundAlerts"
    }

    static func resolve(
        isMacCatalyst: Bool,
        isiOSAppOnMac: Bool,
        isPad: Bool,
        isVisionOS: Bool,
        isWatchOS: Bool
    ) -> NativeUIRelaySurface {
        if isMacCatalyst || isiOSAppOnMac { return .macCatalyst }
        if isVisionOS { return .vision }
        if isWatchOS { return .watch }
        return isPad ? .iPad : .iPhone
    }

    static func current() -> NativeUIRelaySurface {
#if targetEnvironment(macCatalyst)
        return .macCatalyst
#elseif os(visionOS)
        return .vision
#elseif os(watchOS)
        return .watch
#elseif os(iOS)
        let isPad: Bool = {
            #if canImport(UIKit)
            UIDevice.current.userInterfaceIdiom == .pad
            #else
            false
            #endif
        }()
        return resolve(
            isMacCatalyst: false,
            isiOSAppOnMac: ProcessInfo.processInfo.isiOSAppOnMac,
            isPad: isPad,
            isVisionOS: false,
            isWatchOS: false
        )
#else
        return .other
#endif
    }
}

enum PlatformCapabilities {
    /// QuakeSignal's background alert service requires both App Attest and
    /// APNs. Mac does not support App Attest, and Apple's visionOS provisioning
    /// capability table does not support Push or Time Sensitive Notifications.
    /// Those experiences therefore stay foreground/local-only even though
    /// visionOS itself supports App Attest.
    static var supportsAttestedAlertRegistration: Bool {
        NativeUIRelaySurface.current().registersForNotificationRelay
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
