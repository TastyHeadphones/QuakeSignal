import Foundation

/// Simulator-only state used to capture deterministic App Store review
/// candidates. Activation deliberately requires two independent inputs so an
/// ordinary Debug launch cannot silently replace live data with fixtures.
/// Release and physical-device builds always evaluate `isEnabled` to false.
enum ScreenshotAutomation {
    static let launchArgument = "--quakesignal-screenshot-automation"
    static let environmentKey = "QUAKESIGNAL_SCREENSHOT_AUTOMATION"
    static let frameArgumentPrefix = "--quakesignal-screenshot-frame="
    static let frameEnvironmentKey = "QUAKESIGNAL_SCREENSHOT_FRAME"

    /// Exact destinations in the reviewed tvOS, visionOS, and watchOS
    /// screenshot plans. Public and physical-device builds cannot enter these
    /// screenshot-only routes even when arbitrary process inputs are supplied.
    enum Frame: String, CaseIterable, Sendable {
        case tvDashboard = "tvos-dashboard"
        case tvRecentReports = "tvos-recent-reports"
        case tvEventDetail = "tvos-event-detail"
        case visionHome = "visionos-home"
        case visionReports = "visionos-reports"
        case visionMap = "visionos-map"
        case visionGuide = "visionos-guide"
        case visionAlertPreferences = "visionos-alert-preferences"
        case watchHeadline = "watchos-headline"
        case watchRecentReports = "watchos-recent-reports"
        case watchEventDetail = "watchos-event-detail"
    }

    static func shouldActivate(
        buildAllowsAutomation: Bool,
        isSimulator: Bool,
        arguments: [String],
        environment: [String: String]
    ) -> Bool {
        buildAllowsAutomation
            && isSimulator
            && arguments.contains(launchArgument)
            && environment[environmentKey] == "1"
    }

    static var isEnabled: Bool {
#if DEBUG && targetEnvironment(simulator)
        shouldActivate(
            buildAllowsAutomation: true,
            isSimulator: true,
            arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment
        )
#else
        false
#endif
    }

    static func selectFrame(
        buildAllowsAutomation: Bool,
        isSimulator: Bool,
        arguments: [String],
        environment: [String: String]
    ) -> Frame? {
        guard shouldActivate(
            buildAllowsAutomation: buildAllowsAutomation,
            isSimulator: isSimulator,
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
        return Frame(rawValue: environmentValue)
    }

    static var selectedFrame: Frame? {
#if DEBUG && targetEnvironment(simulator)
        selectFrame(
            buildAllowsAutomation: true,
            isSimulator: true,
            arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment
        )
#else
        nil
#endif
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
