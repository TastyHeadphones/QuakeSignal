import Foundation
#if os(iOS)
import UIKit
#endif

/// Non-distributable Debug state used to capture deterministic App Store review
/// candidates in Apple simulators and the native Mac Catalyst host. Activation
/// deliberately requires two independent inputs so an ordinary Debug launch
/// cannot silently replace live data with fixtures. InternalQA, Release, and
/// physical-device builds always evaluate `isEnabled` to false.
enum ScreenshotAutomation {
    static let launchArgument = "--quakesignal-screenshot-automation"
    static let environmentKey = "QUAKESIGNAL_SCREENSHOT_AUTOMATION"
    static let frameArgumentPrefix = "--quakesignal-screenshot-frame="
    static let frameEnvironmentKey = "QUAKESIGNAL_SCREENSHOT_FRAME"
    static let macCaptureEvidenceRootEnvironmentKey =
        "QUAKESIGNAL_CATALYST_SCREENSHOT_EVIDENCE_ROOT"

    /// Mac App Store captures use a 1280 × 800-point Catalyst window on a
    /// Retina display. `screencapture` therefore returns the selected native
    /// 2560 × 1600 pixels without any resize operation.
    static let macCaptureLogicalSize = CGSize(width: 1_280, height: 800)
    static let macCaptureBackingScale: CGFloat = 2
    static let macCaptureReadyAccessibilityIdentifier =
        "com.quakesignal.screenshot.maccatalyst.geometry-ready"
    static let macCaptureFailedAccessibilityIdentifier =
        "com.quakesignal.screenshot.maccatalyst.geometry-failed"

    /// Exact destinations in the reviewed native-platform screenshot plans.
    /// Public and physical-device builds cannot enter these screenshot-only
    /// routes even when arbitrary process inputs are supplied.
    enum Frame: String, CaseIterable, Sendable {
        case iPhone65Home = "ios-iphone-6.5-home"
        case iPhone65Reports = "ios-iphone-6.5-reports"
        case iPhone65Map = "ios-iphone-6.5-map"
        case iPhone65Guide = "ios-iphone-6.5-guide"
        case iPhone65AlertPreferences = "ios-iphone-6.5-alert-preferences"
        case iPad13Home = "ios-ipad-13-home"
        case iPad13Reports = "ios-ipad-13-reports"
        case iPad13Map = "ios-ipad-13-map"
        case iPad13Guide = "ios-ipad-13-guide"
        case iPad13AlertPreferences = "ios-ipad-13-alert-preferences"
        case tvDashboard = "tvos-dashboard"
        case tvRecentReports = "tvos-recent-reports"
        case tvEventDetail = "tvos-event-detail"
        case visionHome = "visionos-home"
        case visionReports = "visionos-reports"
        case visionMap = "visionos-map"
        case visionGuide = "visionos-guide"
        case visionAlertPreferences = "visionos-alert-preferences"
        case macHome = "maccatalyst-home"
        case macReports = "maccatalyst-reports"
        case macMap = "maccatalyst-map"
        case macGuide = "maccatalyst-guide"
        case macAlertPreferences = "maccatalyst-alert-preferences"
        case watchHeadline = "watchos-headline"
        case watchRecentReports = "watchos-recent-reports"
        case watchEventDetail = "watchos-event-detail"
    }

    enum RootDestination: Equatable, Sendable {
        case home
        case reports
        case map
        case guide
        case settings
    }

    enum CaptureTarget: Equatable, Sendable {
        case iPhone
        case iPad
        case tvOS
        case watchOS
        case visionOS
        case macCatalyst
    }

    /// Pure routing policy shared by the iPhone, iPad, visionOS, and Catalyst
    /// screenshot entry points. Unknown/non-tab selectors fail closed to Home.
    static func rootDestination(for frame: Frame?) -> RootDestination {
        switch frame {
        case .iPhone65Reports, .iPad13Reports, .visionReports, .macReports:
            .reports
        case .iPhone65Map, .iPad13Map, .visionMap, .macMap:
            .map
        case .iPhone65Guide, .iPad13Guide, .visionGuide, .macGuide:
            .guide
        case .iPhone65AlertPreferences, .iPad13AlertPreferences,
             .visionAlertPreferences, .macAlertPreferences:
            .settings
        default:
            .home
        }
    }

    static func isAlertPreferencesFrame(_ frame: Frame?) -> Bool {
        rootDestination(for: frame) == .settings
    }

    static func shouldActivate(
        buildAllowsAutomation: Bool,
        isCaptureEnvironment: Bool,
        arguments: [String],
        environment: [String: String]
    ) -> Bool {
        buildAllowsAutomation
            && isCaptureEnvironment
            && arguments.contains(launchArgument)
            && environment[environmentKey] == "1"
    }

    @MainActor static var isEnabled: Bool {
#if DEBUG && (targetEnvironment(simulator) || targetEnvironment(macCatalyst))
        selectedFrame != nil
#else
        false
#endif
    }

    static func selectFrame(
        buildAllowsAutomation: Bool,
        isCaptureEnvironment: Bool,
        captureTarget: CaptureTarget,
        arguments: [String],
        environment: [String: String]
    ) -> Frame? {
        guard shouldActivate(
            buildAllowsAutomation: buildAllowsAutomation,
            isCaptureEnvironment: isCaptureEnvironment,
            arguments: arguments,
            environment: environment
        ), let environmentValue = environment[frameEnvironmentKey] else {
            return nil
        }

        let argumentValues = arguments.compactMap { argument -> String? in
            guard argument.hasPrefix(frameArgumentPrefix) else { return nil }
            return String(argument.dropFirst(frameArgumentPrefix.count))
        }
        guard argumentValues.count == 1,
              argumentValues[0] == environmentValue else {
            return nil
        }
        guard let frame = Frame(rawValue: environmentValue),
              isCompatible(frame, with: captureTarget) else {
            return nil
        }
        return frame
    }

    @MainActor static var selectedFrame: Frame? {
#if DEBUG && (targetEnvironment(simulator) || targetEnvironment(macCatalyst))
        guard let captureTarget = currentCaptureTarget else { return nil }
        return selectFrame(
            buildAllowsAutomation: true,
            isCaptureEnvironment: true,
            captureTarget: captureTarget,
            arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment
        )
#else
        nil
#endif
    }

    static func isCompatible(_ frame: Frame, with target: CaptureTarget) -> Bool {
        switch target {
        case .iPhone:
            return iPhoneCaptureFrames.contains(frame)
        case .iPad:
            return iPadCaptureFrames.contains(frame)
        case .tvOS:
            return tvCaptureFrames.contains(frame)
        case .watchOS:
            return watchCaptureFrames.contains(frame)
        case .visionOS:
            return visionCaptureFrames.contains(frame)
        case .macCatalyst:
            return macCaptureFrames.contains(frame)
        }
    }

    @MainActor private static var currentCaptureTarget: CaptureTarget? {
#if targetEnvironment(macCatalyst)
        .macCatalyst
#elseif os(iOS)
        switch UIDevice.current.userInterfaceIdiom {
        case .phone: .iPhone
        case .pad: .iPad
        default: nil
        }
#elseif os(tvOS)
        .tvOS
#elseif os(watchOS)
        .watchOS
#elseif os(visionOS)
        .visionOS
#else
        nil
#endif
    }

    static func macCaptureTargetSystemFrame(
        screenshotAutomationEnabled: Bool,
        selectedFrame: Frame?,
        currentSystemFrame: CGRect
    ) -> CGRect? {
        guard screenshotAutomationEnabled,
              let selectedFrame,
              macCaptureFrames.contains(selectedFrame),
              !currentSystemFrame.isNull,
              !currentSystemFrame.isInfinite,
              currentSystemFrame.minX.isFinite,
              currentSystemFrame.minY.isFinite else {
            return nil
        }

        return CGRect(
            origin: currentSystemFrame.origin,
            size: macCaptureLogicalSize
        )
    }

    static func macCaptureEvidenceRootPath(
        screenshotAutomationEnabled: Bool,
        selectedFrame: Frame?,
        environment: [String: String]
    ) -> String? {
        guard screenshotAutomationEnabled,
              let selectedFrame,
              macCaptureFrames.contains(selectedFrame),
              let path = environment[macCaptureEvidenceRootEnvironmentKey],
              path.hasPrefix("/"),
              path != "/",
              !path.contains("\0") else {
            return nil
        }

        let standardized = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL.path
        guard path == standardized else { return nil }
        return path
    }

    /// A pure policy used by the Catalyst scene probe. The target size and
    /// Retina scale must match, and two consecutive full system frames must be
    /// unchanged before the probe counts an observation as stable.
    static func macCaptureGeometryIsStable(
        systemFrame: CGRect,
        previousSystemFrame: CGRect?,
        backingScale: CGFloat,
        tolerance: CGFloat = 0.25
    ) -> Bool {
        guard let previousSystemFrame,
              tolerance >= 0,
              systemFrame.width.isFinite,
              systemFrame.height.isFinite,
              backingScale.isFinite,
              approximatelyEqual(systemFrame.width, macCaptureLogicalSize.width, tolerance: tolerance),
              approximatelyEqual(systemFrame.height, macCaptureLogicalSize.height, tolerance: tolerance),
              approximatelyEqual(backingScale, macCaptureBackingScale, tolerance: 0.01) else {
            return false
        }

        return approximatelyEqual(systemFrame.minX, previousSystemFrame.minX, tolerance: tolerance)
            && approximatelyEqual(systemFrame.minY, previousSystemFrame.minY, tolerance: tolerance)
            && approximatelyEqual(systemFrame.width, previousSystemFrame.width, tolerance: tolerance)
            && approximatelyEqual(systemFrame.height, previousSystemFrame.height, tolerance: tolerance)
    }

    private static let macCaptureFrames: Set<Frame> = [
        .macHome,
        .macReports,
        .macMap,
        .macGuide,
        .macAlertPreferences,
    ]
    private static let iPhoneCaptureFrames: Set<Frame> = [
        .iPhone65Home, .iPhone65Reports, .iPhone65Map,
        .iPhone65Guide, .iPhone65AlertPreferences,
    ]
    private static let iPadCaptureFrames: Set<Frame> = [
        .iPad13Home, .iPad13Reports, .iPad13Map,
        .iPad13Guide, .iPad13AlertPreferences,
    ]
    private static let tvCaptureFrames: Set<Frame> = [
        .tvDashboard, .tvRecentReports, .tvEventDetail,
    ]
    private static let watchCaptureFrames: Set<Frame> = [
        .watchHeadline, .watchRecentReports, .watchEventDetail,
    ]
    private static let visionCaptureFrames: Set<Frame> = [
        .visionHome, .visionReports, .visionMap, .visionGuide,
        .visionAlertPreferences,
    ]

    private static func approximatelyEqual(
        _ lhs: CGFloat,
        _ rhs: CGFloat,
        tolerance: CGFloat
    ) -> Bool {
        abs(lhs - rhs) <= tolerance
    }

    /// Fixed, terminal reports provide useful native UI without ever looking
    /// like a current warning or a training alert. These exist only in Debug
    /// products; public and InternalQA binaries contain no screenshot data.
    static var finalizedHistoricalEvents: [EEWEvent] {
#if DEBUG
        [
            EEWEvent(
                id: "jma_eqlist:screenshot-20240101-noto",
                sourceId: "jma_eqlist",
                eventId: "screenshot-20240101-noto",
                serial: 1,
                kind: "report",
                originTimeUtc: "2024-01-01T07:10:09Z",
                reportTimeUtc: "2024-01-01T07:20:00Z",
                hypocenter: "Noto Peninsula · Ishikawa",
                latitude: 37.498,
                longitude: 137.242,
                magnitude: 7.6,
                depth: 16,
                maxIntensity: "7",
                isWarn: false,
                isFinal: true,
                isCancel: false,
                isTraining: false,
                tsunami: "observed"
            ),
            EEWEvent(
                id: "jma_eqlist:screenshot-20220316-fukushima",
                sourceId: "jma_eqlist",
                eventId: "screenshot-20220316-fukushima",
                serial: 1,
                kind: "report",
                originTimeUtc: "2022-03-16T14:36:33Z",
                reportTimeUtc: "2022-03-16T14:48:00Z",
                hypocenter: "Off Fukushima Prefecture",
                latitude: 37.697,
                longitude: 141.622,
                magnitude: 7.4,
                depth: 57,
                maxIntensity: "6+",
                isWarn: false,
                isFinal: true,
                isCancel: false,
                isTraining: false,
                tsunami: "advisory"
            ),
            EEWEvent(
                id: "jma_eqlist:screenshot-20210213-fukushima",
                sourceId: "jma_eqlist",
                eventId: "screenshot-20210213-fukushima",
                serial: 1,
                kind: "report",
                originTimeUtc: "2021-02-13T14:07:50Z",
                reportTimeUtc: "2021-02-13T14:20:00Z",
                hypocenter: "Off Fukushima Prefecture",
                latitude: 37.729,
                longitude: 141.698,
                magnitude: 7.3,
                depth: 55,
                maxIntensity: "6+",
                isWarn: false,
                isFinal: true,
                isCancel: false,
                isTraining: false,
                tsunami: "none"
            ),
            EEWEvent(
                id: "jma_eqlist:screenshot-20180906-iburi",
                sourceId: "jma_eqlist",
                eventId: "screenshot-20180906-iburi",
                serial: 1,
                kind: "report",
                originTimeUtc: "2018-09-05T18:07:59Z",
                reportTimeUtc: "2018-09-05T18:20:00Z",
                hypocenter: "Eastern Iburi, Hokkaido",
                latitude: 42.691,
                longitude: 142.007,
                magnitude: 6.7,
                depth: 37,
                maxIntensity: "7",
                isWarn: false,
                isFinal: true,
                isCancel: false,
                isTraining: false,
                tsunami: "none"
            )
        ]
#else
        []
#endif
    }

    static var fixtureLastUpdated: Date? {
        finalizedHistoricalEvents.compactMap(\.reportDate).max()
    }
}
