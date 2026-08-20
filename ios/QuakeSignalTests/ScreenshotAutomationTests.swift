import XCTest
@testable import QuakeSignal

@MainActor
final class ScreenshotAutomationTests: XCTestCase {
    func testActivationRequiresApprovedDebugCaptureEnvironmentArgumentAndEnvironmentTogether() {
        let argument = ["QuakeSignal", ScreenshotAutomation.launchArgument]
        let environment = [ScreenshotAutomation.environmentKey: "1"]

        XCTAssertTrue(ScreenshotAutomation.shouldActivate(
            buildAllowsAutomation: true,
            isCaptureEnvironment: true,
            arguments: argument,
            environment: environment
        ))
        XCTAssertFalse(ScreenshotAutomation.shouldActivate(
            buildAllowsAutomation: true,
            isCaptureEnvironment: true,
            arguments: argument,
            environment: [:]
        ))
        XCTAssertFalse(ScreenshotAutomation.shouldActivate(
            buildAllowsAutomation: true,
            isCaptureEnvironment: true,
            arguments: ["QuakeSignal"],
            environment: environment
        ))
        XCTAssertFalse(ScreenshotAutomation.shouldActivate(
            buildAllowsAutomation: false,
            isCaptureEnvironment: true,
            arguments: argument,
            environment: environment
        ))
        XCTAssertFalse(ScreenshotAutomation.shouldActivate(
            buildAllowsAutomation: true,
            isCaptureEnvironment: false,
            arguments: argument,
            environment: environment
        ))
        XCTAssertFalse(ScreenshotAutomation.shouldActivate(
            buildAllowsAutomation: true,
            isCaptureEnvironment: true,
            arguments: argument,
            environment: [ScreenshotAutomation.environmentKey: "true"]
        ))
    }

    func testOrdinaryUnitTestLaunchDoesNotEnableScreenshotAutomation() {
        XCTAssertFalse(ScreenshotAutomation.isEnabled)
        XCTAssertNil(ScreenshotAutomation.selectedFrame)
    }

    func testFrameSelectionRequiresMatchingArgumentAndEnvironmentPlusActivationGate() {
        let arguments = [
            "QuakeSignal",
            ScreenshotAutomation.launchArgument,
            "\(ScreenshotAutomation.frameArgumentPrefix)visionos-map"
        ]
        let environment = [
            ScreenshotAutomation.environmentKey: "1",
            ScreenshotAutomation.frameEnvironmentKey: "visionos-map"
        ]

        XCTAssertEqual(
            ScreenshotAutomation.selectFrame(
                buildAllowsAutomation: true,
                isCaptureEnvironment: true,
                captureTarget: .visionOS,
                arguments: arguments,
                environment: environment
            ),
            .visionMap
        )
        XCTAssertNil(ScreenshotAutomation.selectFrame(
            buildAllowsAutomation: false,
            isCaptureEnvironment: true,
            captureTarget: .visionOS,
            arguments: arguments,
            environment: environment
        ))
        XCTAssertNil(ScreenshotAutomation.selectFrame(
            buildAllowsAutomation: true,
            isCaptureEnvironment: false,
            captureTarget: .visionOS,
            arguments: arguments,
            environment: environment
        ))
        XCTAssertNil(ScreenshotAutomation.selectFrame(
            buildAllowsAutomation: true,
            isCaptureEnvironment: true,
            captureTarget: .visionOS,
            arguments: arguments.filter { $0 != ScreenshotAutomation.launchArgument },
            environment: environment
        ))
    }

    func testReviewedFrameSelectorInventoryIsExact() {
        XCTAssertEqual(
            ScreenshotAutomation.Frame.allCases.map(\.rawValue),
            [
                "ios-iphone-6.5-home",
                "ios-iphone-6.5-reports",
                "ios-iphone-6.5-map",
                "ios-iphone-6.5-guide",
                "ios-iphone-6.5-alert-preferences",
                "ios-ipad-13-home",
                "ios-ipad-13-reports",
                "ios-ipad-13-map",
                "ios-ipad-13-guide",
                "ios-ipad-13-alert-preferences",
                "tvos-dashboard",
                "tvos-recent-reports",
                "tvos-event-detail",
                "visionos-home",
                "visionos-reports",
                "visionos-map",
                "visionos-guide",
                "visionos-alert-preferences",
                "maccatalyst-home",
                "maccatalyst-reports",
                "maccatalyst-map",
                "maccatalyst-guide",
                "maccatalyst-alert-preferences",
                "watchos-headline",
                "watchos-recent-reports",
                "watchos-event-detail"
            ]
        )
    }

    func testFrameSelectionFailsClosedForMissingMismatchedDuplicateOrUnknownSelectors() {
        let gateArguments = ["QuakeSignal", ScreenshotAutomation.launchArgument]
        let gateEnvironment = [ScreenshotAutomation.environmentKey: "1"]

        XCTAssertNil(ScreenshotAutomation.selectFrame(
            buildAllowsAutomation: true,
            isCaptureEnvironment: true,
            captureTarget: .iPhone,
            arguments: gateArguments,
            environment: gateEnvironment
        ))
        XCTAssertNil(ScreenshotAutomation.selectFrame(
            buildAllowsAutomation: true,
            isCaptureEnvironment: true,
            captureTarget: .iPhone,
            arguments: gateArguments + ["\(ScreenshotAutomation.frameArgumentPrefix)tvos-dashboard"],
            environment: gateEnvironment.merging([
                ScreenshotAutomation.frameEnvironmentKey: "watchos-headline"
            ]) { _, new in new }
        ))
        XCTAssertNil(ScreenshotAutomation.selectFrame(
            buildAllowsAutomation: true,
            isCaptureEnvironment: true,
            captureTarget: .iPhone,
            arguments: gateArguments + [
                "\(ScreenshotAutomation.frameArgumentPrefix)tvos-dashboard",
                "\(ScreenshotAutomation.frameArgumentPrefix)tvos-dashboard"
            ],
            environment: gateEnvironment.merging([
                ScreenshotAutomation.frameEnvironmentKey: "tvos-dashboard"
            ]) { _, new in new }
        ))
        XCTAssertNil(ScreenshotAutomation.selectFrame(
            buildAllowsAutomation: true,
            isCaptureEnvironment: true,
            captureTarget: .iPhone,
            arguments: gateArguments + ["\(ScreenshotAutomation.frameArgumentPrefix)tvos-unreviewed"],
            environment: gateEnvironment.merging([
                ScreenshotAutomation.frameEnvironmentKey: "tvos-unreviewed"
            ]) { _, new in new }
        ))
    }

    func testFrameSelectionRejectsEveryWrongTargetAndPhonePadMismatch() {
        let allTargets: [ScreenshotAutomation.CaptureTarget] = [
            .iPhone, .iPad, .tvOS, .watchOS, .visionOS, .macCatalyst,
        ]
        let examples: [(ScreenshotAutomation.Frame, ScreenshotAutomation.CaptureTarget)] = [
            (.iPhone65Home, .iPhone),
            (.iPad13Home, .iPad),
            (.tvDashboard, .tvOS),
            (.watchHeadline, .watchOS),
            (.visionHome, .visionOS),
            (.macHome, .macCatalyst),
        ]
        for (frame, compatibleTarget) in examples {
            let arguments = [
                "QuakeSignal",
                ScreenshotAutomation.launchArgument,
                "\(ScreenshotAutomation.frameArgumentPrefix)\(frame.rawValue)",
            ]
            let environment = [
                ScreenshotAutomation.environmentKey: "1",
                ScreenshotAutomation.frameEnvironmentKey: frame.rawValue,
            ]
            for target in allTargets {
                let selected = ScreenshotAutomation.selectFrame(
                    buildAllowsAutomation: true,
                    isCaptureEnvironment: true,
                    captureTarget: target,
                    arguments: arguments,
                    environment: environment
                )
                XCTAssertEqual(selected, target == compatibleTarget ? frame : nil)
            }
        }
    }

    func testReviewedIOSAndIPadFramesHaveExactDeterministicRootRoutes() {
        let expected: [(ScreenshotAutomation.Frame, ScreenshotAutomation.RootDestination)] = [
            (.iPhone65Home, .home),
            (.iPhone65Reports, .reports),
            (.iPhone65Map, .map),
            (.iPhone65Guide, .guide),
            (.iPhone65AlertPreferences, .settings),
            (.iPad13Home, .home),
            (.iPad13Reports, .reports),
            (.iPad13Map, .map),
            (.iPad13Guide, .guide),
            (.iPad13AlertPreferences, .settings),
        ]

        for (frame, destination) in expected {
            XCTAssertEqual(ScreenshotAutomation.rootDestination(for: frame), destination)
        }
        XCTAssertEqual(ScreenshotAutomation.rootDestination(for: nil), .home)
        XCTAssertEqual(ScreenshotAutomation.rootDestination(for: .watchHeadline), .home)
    }

    func testOnlyReviewedAlertPreferenceFramesOpenTheDeterministicSoundPicker() {
        XCTAssertTrue(ScreenshotAutomation.isAlertPreferencesFrame(.iPhone65AlertPreferences))
        XCTAssertTrue(ScreenshotAutomation.isAlertPreferencesFrame(.iPad13AlertPreferences))
        XCTAssertTrue(ScreenshotAutomation.isAlertPreferencesFrame(.visionAlertPreferences))
        XCTAssertTrue(ScreenshotAutomation.isAlertPreferencesFrame(.macAlertPreferences))
        XCTAssertFalse(ScreenshotAutomation.isAlertPreferencesFrame(.iPhone65Home))
        XCTAssertFalse(ScreenshotAutomation.isAlertPreferencesFrame(.tvDashboard))
        XCTAssertFalse(ScreenshotAutomation.isAlertPreferencesFrame(nil))
    }

    func testMacCaptureGeometryPolicyAcceptsOnlyReviewedMacSelectors() throws {
        let currentFrame = CGRect(x: 144, y: 72, width: 900, height: 700)

        for frame in [
            ScreenshotAutomation.Frame.macHome,
            .macReports,
            .macMap,
            .macGuide,
            .macAlertPreferences,
        ] {
            XCTAssertEqual(
                ScreenshotAutomation.macCaptureTargetSystemFrame(
                    screenshotAutomationEnabled: true,
                    selectedFrame: frame,
                    currentSystemFrame: currentFrame
                ),
                CGRect(x: 144, y: 72, width: 1_280, height: 800)
            )
        }

        XCTAssertNil(ScreenshotAutomation.macCaptureTargetSystemFrame(
            screenshotAutomationEnabled: false,
            selectedFrame: .macHome,
            currentSystemFrame: currentFrame
        ))
        XCTAssertNil(ScreenshotAutomation.macCaptureTargetSystemFrame(
            screenshotAutomationEnabled: true,
            selectedFrame: .visionHome,
            currentSystemFrame: currentFrame
        ))
        XCTAssertNil(ScreenshotAutomation.macCaptureTargetSystemFrame(
            screenshotAutomationEnabled: true,
            selectedFrame: nil,
            currentSystemFrame: currentFrame
        ))
        XCTAssertNil(ScreenshotAutomation.macCaptureTargetSystemFrame(
            screenshotAutomationEnabled: true,
            selectedFrame: .macHome,
            currentSystemFrame: .infinite
        ))
    }

    func testMacCaptureGeometryRequiresStable1280By800RetinaFrame() {
        let target = CGRect(x: 40, y: 60, width: 1_280, height: 800)

        XCTAssertTrue(ScreenshotAutomation.macCaptureGeometryIsStable(
            systemFrame: target,
            previousSystemFrame: target,
            backingScale: 2
        ))
        XCTAssertFalse(ScreenshotAutomation.macCaptureGeometryIsStable(
            systemFrame: target,
            previousSystemFrame: nil,
            backingScale: 2
        ))
        XCTAssertFalse(ScreenshotAutomation.macCaptureGeometryIsStable(
            systemFrame: target,
            previousSystemFrame: target.offsetBy(dx: 1, dy: 0),
            backingScale: 2
        ))
        XCTAssertFalse(ScreenshotAutomation.macCaptureGeometryIsStable(
            systemFrame: CGRect(x: 40, y: 60, width: 1_279, height: 800),
            previousSystemFrame: CGRect(x: 40, y: 60, width: 1_279, height: 800),
            backingScale: 2
        ))
        XCTAssertFalse(ScreenshotAutomation.macCaptureGeometryIsStable(
            systemFrame: target,
            previousSystemFrame: target,
            backingScale: 1
        ))
    }

    func testMacCaptureEvidenceRootRequiresExactAbsoluteNormalizedPathAndMacSelector() {
        let environment = [
            ScreenshotAutomation.macCaptureEvidenceRootEnvironmentKey:
                "/Volumes/RC20/quakesignal-catalyst-capture"
        ]

        XCTAssertEqual(
            ScreenshotAutomation.macCaptureEvidenceRootPath(
                screenshotAutomationEnabled: true,
                selectedFrame: .macMap,
                environment: environment
            ),
            "/Volumes/RC20/quakesignal-catalyst-capture"
        )
        XCTAssertNil(ScreenshotAutomation.macCaptureEvidenceRootPath(
            screenshotAutomationEnabled: false,
            selectedFrame: .macMap,
            environment: environment
        ))
        XCTAssertNil(ScreenshotAutomation.macCaptureEvidenceRootPath(
            screenshotAutomationEnabled: true,
            selectedFrame: .visionMap,
            environment: environment
        ))
        XCTAssertNil(ScreenshotAutomation.macCaptureEvidenceRootPath(
            screenshotAutomationEnabled: true,
            selectedFrame: .macMap,
            environment: [ScreenshotAutomation.macCaptureEvidenceRootEnvironmentKey: "relative"]
        ))
        XCTAssertNil(ScreenshotAutomation.macCaptureEvidenceRootPath(
            screenshotAutomationEnabled: true,
            selectedFrame: .macMap,
            environment: [ScreenshotAutomation.macCaptureEvidenceRootEnvironmentKey: "/Volumes/RC20/a/../b"]
        ))
        XCTAssertNil(ScreenshotAutomation.macCaptureEvidenceRootPath(
            screenshotAutomationEnabled: true,
            selectedFrame: .macMap,
            environment: [:]
        ))
    }

    func testMapTimelineUsesFixtureClockOnlyForScreenshotAutomation() {
        let fixtureDate = Date(timeIntervalSince1970: 1_700_000_000)
        var readLiveClock = false

        let referenceDate = MapTimelineReference.resolve(
            screenshotAutomationEnabled: true,
            fixtureLastUpdated: fixtureDate
        ) {
            readLiveClock = true
            return .distantFuture
        }

        XCTAssertEqual(referenceDate, fixtureDate)
        XCTAssertFalse(readLiveClock)
    }

    func testMapTimelineFailsClosedWhenScreenshotFixtureDateIsMissing() {
        var readLiveClock = false

        let referenceDate = MapTimelineReference.resolve(
            screenshotAutomationEnabled: true,
            fixtureLastUpdated: nil
        ) {
            readLiveClock = true
            return .distantFuture
        }

        XCTAssertNil(referenceDate)
        XCTAssertFalse(readLiveClock)
    }

    func testMapTimelineUsesLiveClockOutsideScreenshotAutomation() {
        let liveDate = Date(timeIntervalSince1970: 1_800_000_000)

        let referenceDate = MapTimelineReference.resolve(
            screenshotAutomationEnabled: false,
            fixtureLastUpdated: .distantPast
        ) {
            liveDate
        }

        XCTAssertEqual(referenceDate, liveDate)
    }

    func testScreenshotFixturesAreFinalHistoricalReportsNeverWarningsOrTraining() throws {
        let fixtures = ScreenshotAutomation.finalizedHistoricalEvents
#if DEBUG
        XCTAssertFalse(fixtures.isEmpty)
        XCTAssertEqual(Set(fixtures.map(\.id)).count, fixtures.count)

        let newestAllowedDate = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2025-01-01T00:00:00Z")
        )
        for event in fixtures {
            XCTAssertEqual(event.kind, "report")
            XCTAssertTrue(event.isFinal)
            XCTAssertFalse(event.isWarn)
            XCTAssertFalse(event.isCancel)
            XCTAssertFalse(event.isTraining)
            XCTAssertFalse(event.isActiveWarning)
            XCTAssertLessThan(try XCTUnwrap(event.reportDate), newestAllowedDate)
        }
#else
        XCTAssertTrue(
            fixtures.isEmpty,
            "Screenshot fixtures must not be compiled into InternalQA or public Release products"
        )
#endif
    }
}
