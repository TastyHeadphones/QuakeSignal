import XCTest
@testable import QuakeSignal

final class ForegroundManualRefreshLifecycleTests: XCTestCase {
    func testInactiveSceneRejectsManualRefreshRequest() {
        var lifecycle = ForegroundManualRefreshLifecycle()

        lifecycle.requestRefresh(isSceneActive: false)

        XCTAssertNil(lifecycle.pendingRequestID)
        XCTAssertFalse(lifecycle.shouldRun(isSceneActive: false))
    }

    func testActiveRequestCreatesUniqueSceneBoundTaskIDs() throws {
        var lifecycle = ForegroundManualRefreshLifecycle()

        lifecycle.requestRefresh(isSceneActive: true)
        let firstID = lifecycle.taskID(isSceneActive: true)
        XCTAssertTrue(lifecycle.shouldRun(isSceneActive: true))

        lifecycle.requestRefresh(isSceneActive: true)
        let secondID = lifecycle.taskID(isSceneActive: true)

        XCTAssertNotEqual(firstID, secondID)
        XCTAssertNotNil(lifecycle.pendingRequestID)
    }

    func testSceneDeactivationChangesTaskIDAndMakesPendingWorkIneligible() {
        var lifecycle = ForegroundManualRefreshLifecycle()
        lifecycle.requestRefresh(isSceneActive: true)

        let activeTaskID = lifecycle.taskID(isSceneActive: true)
        let inactiveTaskID = lifecycle.taskID(isSceneActive: false)

        XCTAssertNotEqual(activeTaskID, inactiveTaskID)
        XCTAssertFalse(lifecycle.shouldRun(isSceneActive: false))
    }

    func testCancellationPreventsRefreshReplayAfterReactivation() {
        var lifecycle = ForegroundManualRefreshLifecycle()
        lifecycle.requestRefresh(isSceneActive: true)

        lifecycle.cancelPendingRefresh()

        XCTAssertNil(lifecycle.pendingRequestID)
        XCTAssertFalse(lifecycle.shouldRun(isSceneActive: false))
        XCTAssertFalse(lifecycle.shouldRun(isSceneActive: true))
    }
}
