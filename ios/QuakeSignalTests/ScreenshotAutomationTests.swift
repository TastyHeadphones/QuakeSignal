import XCTest
@testable import QuakeSignal

final class ScreenshotAutomationTests: XCTestCase {
    func testActivationRequiresDebugSimulatorArgumentAndEnvironmentTogether() {
        let argument = ["QuakeSignal", ScreenshotAutomation.launchArgument]
        let environment = [ScreenshotAutomation.environmentKey: "1"]

        XCTAssertTrue(ScreenshotAutomation.shouldActivate(
            buildAllowsAutomation: true,
            isSimulator: true,
            arguments: argument,
            environment: environment
        ))
        XCTAssertFalse(ScreenshotAutomation.shouldActivate(
            buildAllowsAutomation: true,
            isSimulator: true,
            arguments: argument,
            environment: [:]
        ))
        XCTAssertFalse(ScreenshotAutomation.shouldActivate(
            buildAllowsAutomation: true,
            isSimulator: true,
            arguments: ["QuakeSignal"],
            environment: environment
        ))
        XCTAssertFalse(ScreenshotAutomation.shouldActivate(
            buildAllowsAutomation: false,
            isSimulator: true,
            arguments: argument,
            environment: environment
        ))
        XCTAssertFalse(ScreenshotAutomation.shouldActivate(
            buildAllowsAutomation: true,
            isSimulator: false,
            arguments: argument,
            environment: environment
        ))
        XCTAssertFalse(ScreenshotAutomation.shouldActivate(
            buildAllowsAutomation: true,
            isSimulator: true,
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
                isSimulator: true,
                arguments: arguments,
                environment: environment
            ),
            .visionMap
        )
        XCTAssertNil(ScreenshotAutomation.selectFrame(
            buildAllowsAutomation: false,
            isSimulator: true,
            arguments: arguments,
            environment: environment
        ))
        XCTAssertNil(ScreenshotAutomation.selectFrame(
            buildAllowsAutomation: true,
            isSimulator: false,
            arguments: arguments,
            environment: environment
        ))
        XCTAssertNil(ScreenshotAutomation.selectFrame(
            buildAllowsAutomation: true,
            isSimulator: true,
            arguments: arguments.filter { $0 != ScreenshotAutomation.launchArgument },
            environment: environment
        ))
    }

    func testReviewedFrameSelectorInventoryIsExact() {
        XCTAssertEqual(
            ScreenshotAutomation.Frame.allCases.map(\.rawValue),
            [
                "tvos-dashboard",
                "tvos-recent-reports",
                "tvos-event-detail",
                "visionos-home",
                "visionos-reports",
                "visionos-map",
                "visionos-guide",
                "visionos-alert-preferences",
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
            isSimulator: true,
            arguments: gateArguments,
            environment: gateEnvironment
        ))
        XCTAssertNil(ScreenshotAutomation.selectFrame(
            buildAllowsAutomation: true,
            isSimulator: true,
            arguments: gateArguments + ["\(ScreenshotAutomation.frameArgumentPrefix)tvos-dashboard"],
            environment: gateEnvironment.merging([
                ScreenshotAutomation.frameEnvironmentKey: "watchos-headline"
            ]) { _, new in new }
        ))
        XCTAssertNil(ScreenshotAutomation.selectFrame(
            buildAllowsAutomation: true,
            isSimulator: true,
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
            isSimulator: true,
            arguments: gateArguments + ["\(ScreenshotAutomation.frameArgumentPrefix)tvos-unreviewed"],
            environment: gateEnvironment.merging([
                ScreenshotAutomation.frameEnvironmentKey: "tvos-unreviewed"
            ]) { _, new in new }
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
