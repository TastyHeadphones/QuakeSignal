import XCTest
@testable import QuakeSignal

final class ForegroundHTTPFallbackPolicyTests: XCTestCase {
    func testDirectMonitoringRequiresBothStartupAndAnActiveScene() {
        XCTAssertFalse(
            DirectMonitoringLifecyclePolicy.shouldRun(
                hasStarted: false,
                isForegroundActive: true
            )
        )
        XCTAssertFalse(
            DirectMonitoringLifecyclePolicy.shouldRun(
                hasStarted: true,
                isForegroundActive: false
            )
        )
        XCTAssertTrue(
            DirectMonitoringLifecyclePolicy.shouldRun(
                hasStarted: true,
                isForegroundActive: true
            )
        )
    }

    func testStartWhileActiveStartsSocketMaintenanceAndInitialRefreshExactlyOnce() {
        XCTAssertEqual(
            DirectMonitoringLifecyclePolicy.actionsForStart(
                hasStarted: false,
                isForegroundActive: true
            ),
            [.startSocket, .startForegroundMaintenance, .refreshSnapshot]
        )
        XCTAssertEqual(
            DirectMonitoringLifecyclePolicy.actionsForStart(
                hasStarted: true,
                isForegroundActive: true
            ),
            []
        )
    }

    func testActiveToInactiveStopsEveryForegroundOwnedResource() {
        XCTAssertEqual(
            DirectMonitoringLifecyclePolicy.actionsForSceneTransition(
                hasStarted: true,
                wasForegroundActive: true,
                isForegroundActive: false
            ),
            [.stopSocket, .cancelRefreshes, .stopForegroundMaintenance, .stopAlertAudio]
        )
    }

    func testInactiveToActiveRestartsSocketAndRefreshWithoutDuplicateStarts() {
        XCTAssertEqual(
            DirectMonitoringLifecyclePolicy.actionsForSceneTransition(
                hasStarted: true,
                wasForegroundActive: false,
                isForegroundActive: true
            ),
            [.startSocket, .startForegroundMaintenance, .refreshSnapshot]
        )
        XCTAssertEqual(
            DirectMonitoringLifecyclePolicy.actionsForSceneTransition(
                hasStarted: true,
                wasForegroundActive: true,
                isForegroundActive: true
            ),
            []
        )
    }

    func testInactiveSceneRejectsDirectEventsAndForegroundEmergencyPresentation() {
        XCTAssertFalse(
            DirectMonitoringLifecyclePolicy.shouldAcceptDirectEvent(
                isForegroundActive: false
            )
        )
        XCTAssertFalse(
            DirectMonitoringLifecyclePolicy.shouldPresentForegroundEmergency(
                isForegroundActive: false
            )
        )
        XCTAssertTrue(
            DirectMonitoringLifecyclePolicy.shouldAcceptDirectEvent(
                isForegroundActive: true
            )
        )
        XCTAssertTrue(
            DirectMonitoringLifecyclePolicy.shouldPresentForegroundEmergency(
                isForegroundActive: true
            )
        )
    }

    func testStartsOnlyForForegroundSocketOutage() {
        XCTAssertEqual(
            ForegroundHTTPFallbackPolicy.nextDelaySeconds(
                isForegroundActive: true,
                socketsConnected: false,
                hasCompletedFallbackRefresh: false
            ),
            90
        )
        XCTAssertNil(
            ForegroundHTTPFallbackPolicy.nextDelaySeconds(
                isForegroundActive: false,
                socketsConnected: false,
                hasCompletedFallbackRefresh: false
            )
        )
        XCTAssertNil(
            ForegroundHTTPFallbackPolicy.nextDelaySeconds(
                isForegroundActive: true,
                socketsConnected: true,
                hasCompletedFallbackRefresh: false
            )
        )
    }

    func testUsesConservativeRepeatDelayAfterFirstFallbackRefresh() {
        XCTAssertEqual(
            ForegroundHTTPFallbackPolicy.nextDelaySeconds(
                isForegroundActive: true,
                socketsConnected: false,
                hasCompletedFallbackRefresh: true
            ),
            300
        )
    }
}
