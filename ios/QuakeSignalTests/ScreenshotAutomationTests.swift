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
