import SwiftUI
import XCTest
@testable import QuakeSignal

private struct VisionReadabilitySnapshot {
    var windowWidth: CGFloat
    var windowHeight: CGFloat
    var surfaceOpacity: Double
    var rowSurfaceOpacity: Double
    var supportingTextOpacity: Double
    var minimumControlTargetSize: CGFloat
    var reportRowHeight: CGFloat
    var guideRowHeight: CGFloat
    var alertSoundRowHeight: CGFloat

    static var current: Self {
        Self(
            windowWidth: VisionReadabilityMetrics.defaultWindowWidth,
            windowHeight: VisionReadabilityMetrics.defaultWindowHeight,
            surfaceOpacity: VisionReadabilityMetrics.surfaceOpacity,
            rowSurfaceOpacity: VisionReadabilityMetrics.rowSurfaceOpacity,
            supportingTextOpacity: VisionReadabilityMetrics.supportingTextOpacity,
            minimumControlTargetSize: VisionReadabilityMetrics.minimumControlTargetSize,
            reportRowHeight: VisionReadabilityMetrics.reportMinimumRowHeight,
            guideRowHeight: VisionReadabilityMetrics.guideMinimumRowHeight,
            alertSoundRowHeight: VisionReadabilityMetrics.alertSoundMinimumRowHeight
        )
    }

    var aspectRatio: CGFloat {
        windowWidth / windowHeight
    }

    var retainsReviewedComposition: Bool {
        windowWidth == 1_600 &&
            windowHeight == 800 &&
            (1.9...2.1).contains(aspectRatio) &&
            (0.95...0.99).contains(surfaceOpacity) &&
            rowSurfaceOpacity >= surfaceOpacity &&
            rowSurfaceOpacity <= 1.0 &&
            (0.80...0.90).contains(supportingTextOpacity) &&
            minimumControlTargetSize == 60 &&
            (120...140).contains(reportRowHeight) &&
            (80...96).contains(guideRowHeight) &&
            (100...128).contains(alertSoundRowHeight)
    }

    func replacing<Value>(
        _ keyPath: WritableKeyPath<Self, Value>,
        with value: Value
    ) -> Self {
        var copy = self
        copy[keyPath: keyPath] = value
        return copy
    }
}

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

    func testVisionReadabilityMetricsKeepTheCaptureLargeOpaqueAndLegible() {
        let metrics = VisionReadabilitySnapshot.current

        XCTAssertEqual(metrics.windowWidth, 1_600)
        XCTAssertEqual(metrics.windowHeight, 800)
        XCTAssertGreaterThanOrEqual(metrics.aspectRatio, 1.9)
        XCTAssertLessThanOrEqual(metrics.aspectRatio, 2.1)
        XCTAssertGreaterThanOrEqual(metrics.surfaceOpacity, 0.95)
        XCTAssertLessThanOrEqual(metrics.surfaceOpacity, 0.99)
        XCTAssertGreaterThanOrEqual(metrics.rowSurfaceOpacity, metrics.surfaceOpacity)
        XCTAssertLessThanOrEqual(metrics.rowSurfaceOpacity, 1.0)
        XCTAssertGreaterThanOrEqual(metrics.supportingTextOpacity, 0.80)
        XCTAssertLessThanOrEqual(metrics.supportingTextOpacity, 0.90)
        XCTAssertEqual(metrics.minimumControlTargetSize, 60)
        XCTAssertGreaterThanOrEqual(metrics.reportRowHeight, 120)
        XCTAssertLessThanOrEqual(metrics.reportRowHeight, 140)
        XCTAssertGreaterThanOrEqual(metrics.guideRowHeight, 80)
        XCTAssertLessThanOrEqual(metrics.guideRowHeight, 96)
        XCTAssertGreaterThanOrEqual(metrics.alertSoundRowHeight, 100)
        XCTAssertLessThanOrEqual(metrics.alertSoundRowHeight, 128)
        XCTAssertTrue(metrics.retainsReviewedComposition)
    }

    func testVisionReadabilityBoundsRejectHighAndLowMutations() {
        let baseline = VisionReadabilitySnapshot.current
        XCTAssertTrue(baseline.retainsReviewedComposition)

        let invalidMutations: [(String, VisionReadabilitySnapshot)] = [
            ("window width below exact review", baseline.replacing(\.windowWidth, with: 1_599)),
            ("window width above exact review", baseline.replacing(\.windowWidth, with: 1_601)),
            ("window height below exact review", baseline.replacing(\.windowHeight, with: 799)),
            ("window height above exact review", baseline.replacing(\.windowHeight, with: 801)),
            ("surface opacity below range", baseline.replacing(\.surfaceOpacity, with: 0.949)),
            ("surface opacity above range", baseline.replacing(\.surfaceOpacity, with: 0.991)),
            ("row opacity below surface", baseline.replacing(\.rowSurfaceOpacity, with: 0.969)),
            ("row opacity above one", baseline.replacing(\.rowSurfaceOpacity, with: 1.001)),
            ("supporting opacity below range", baseline.replacing(\.supportingTextOpacity, with: 0.799)),
            ("supporting opacity above range", baseline.replacing(\.supportingTextOpacity, with: 0.901)),
            ("control target below exact review", baseline.replacing(\.minimumControlTargetSize, with: 59)),
            ("control target above exact review", baseline.replacing(\.minimumControlTargetSize, with: 61)),
            ("report row below range", baseline.replacing(\.reportRowHeight, with: 119)),
            ("report row above range", baseline.replacing(\.reportRowHeight, with: 141)),
            ("guide row below range", baseline.replacing(\.guideRowHeight, with: 79)),
            ("guide row above range", baseline.replacing(\.guideRowHeight, with: 97)),
            ("alert row below range", baseline.replacing(\.alertSoundRowHeight, with: 99)),
            ("alert row above range", baseline.replacing(\.alertSoundRowHeight, with: 129)),
        ]

        for (name, mutation) in invalidMutations {
            XCTAssertFalse(mutation.retainsReviewedComposition, name)
        }
    }

    func testVisionGuideUsesOneWideReviewedRowWithAccessibleDynamicTypeFallback() {
        XCTAssertEqual(
            GuideContent.afterQuakeKeys.count,
            VisionGuideLayoutPolicy.wideAfterQuakeItemCount
        )

        for dynamicTypeSize in [
            DynamicTypeSize.xSmall,
            .small,
            .medium,
            .large,
            .xLarge,
            .xxLarge,
            .xxxLarge,
        ] {
            XCTAssertTrue(VisionGuideLayoutPolicy.usesWideAfterQuakeRow(
                itemCount: GuideContent.afterQuakeKeys.count,
                dynamicTypeSize: dynamicTypeSize
            ))
        }

        for dynamicTypeSize in [
            DynamicTypeSize.accessibility1,
            .accessibility2,
            .accessibility3,
            .accessibility4,
            .accessibility5,
        ] {
            XCTAssertFalse(VisionGuideLayoutPolicy.usesWideAfterQuakeRow(
                itemCount: GuideContent.afterQuakeKeys.count,
                dynamicTypeSize: dynamicTypeSize
            ))
        }

        XCTAssertFalse(VisionGuideLayoutPolicy.usesWideAfterQuakeRow(
            itemCount: VisionGuideLayoutPolicy.wideAfterQuakeItemCount - 1,
            dynamicTypeSize: .large
        ))
        XCTAssertFalse(VisionGuideLayoutPolicy.usesWideAfterQuakeRow(
            itemCount: VisionGuideLayoutPolicy.wideAfterQuakeItemCount + 1,
            dynamicTypeSize: .large
        ))
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

    func testMacCaptureGeometryRequiresStable1280By800FrameAndHonestSourceScale() {
        let target = CGRect(x: 40, y: 60, width: 1_280, height: 800)

        XCTAssertTrue(ScreenshotAutomation.macCaptureGeometryIsStable(
            systemFrame: target,
            previousSystemFrame: target,
            sourceDisplayScale: 1
        ))
        XCTAssertTrue(ScreenshotAutomation.macCaptureGeometryIsStable(
            systemFrame: target,
            previousSystemFrame: target,
            sourceDisplayScale: 2
        ))
        XCTAssertFalse(ScreenshotAutomation.macCaptureGeometryIsStable(
            systemFrame: target,
            previousSystemFrame: nil,
            sourceDisplayScale: 1
        ))
        XCTAssertFalse(ScreenshotAutomation.macCaptureGeometryIsStable(
            systemFrame: target,
            previousSystemFrame: target.offsetBy(dx: 1, dy: 0),
            sourceDisplayScale: 1
        ))
        XCTAssertFalse(ScreenshotAutomation.macCaptureGeometryIsStable(
            systemFrame: CGRect(x: 40, y: 60, width: 1_279, height: 800),
            previousSystemFrame: CGRect(x: 40, y: 60, width: 1_279, height: 800),
            sourceDisplayScale: 1
        ))
        XCTAssertFalse(ScreenshotAutomation.macCaptureGeometryIsStable(
            systemFrame: target,
            previousSystemFrame: target,
            sourceDisplayScale: 0
        ))
    }

    func testMacHierarchyRendererRequiresItsIndependentExactDualGate() {
        let enabledArguments = [
            "QuakeSignal",
            ScreenshotAutomation.launchArgument,
            ScreenshotAutomation.macHierarchyCaptureArgument,
        ]
        let enabledEnvironment = [
            ScreenshotAutomation.environmentKey: "1",
            ScreenshotAutomation.macHierarchyCaptureEnvironmentKey: "1",
        ]

        XCTAssertTrue(ScreenshotAutomation.macHierarchyCaptureIsEnabled(
            screenshotAutomationEnabled: true,
            selectedFrame: .macMap,
            arguments: enabledArguments,
            environment: enabledEnvironment
        ))
        XCTAssertFalse(ScreenshotAutomation.macHierarchyCaptureIsEnabled(
            screenshotAutomationEnabled: true,
            selectedFrame: .macMap,
            arguments: enabledArguments.filter {
                $0 != ScreenshotAutomation.macHierarchyCaptureArgument
            },
            environment: enabledEnvironment
        ))
        XCTAssertFalse(ScreenshotAutomation.macHierarchyCaptureIsEnabled(
            screenshotAutomationEnabled: false,
            selectedFrame: .macMap,
            arguments: enabledArguments,
            environment: enabledEnvironment
        ))
        XCTAssertFalse(ScreenshotAutomation.macHierarchyCaptureIsEnabled(
            screenshotAutomationEnabled: true,
            selectedFrame: .macMap,
            arguments: enabledArguments,
            environment: enabledEnvironment.filter {
                $0.key != ScreenshotAutomation.macHierarchyCaptureEnvironmentKey
            }
        ))
        XCTAssertFalse(ScreenshotAutomation.macHierarchyCaptureIsEnabled(
            screenshotAutomationEnabled: true,
            selectedFrame: .macMap,
            arguments: enabledArguments + [ScreenshotAutomation.macHierarchyCaptureArgument],
            environment: enabledEnvironment
        ))
        XCTAssertFalse(ScreenshotAutomation.macHierarchyCaptureIsEnabled(
            screenshotAutomationEnabled: true,
            selectedFrame: .visionMap,
            arguments: enabledArguments,
            environment: enabledEnvironment
        ))
        XCTAssertFalse(ScreenshotAutomation.macHierarchyCaptureIsEnabled(
            screenshotAutomationEnabled: true,
            selectedFrame: .macMap,
            arguments: enabledArguments,
            environment: enabledEnvironment.merging([
                ScreenshotAutomation.macHierarchyCaptureEnvironmentKey: "true"
            ]) { _, new in new }
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
