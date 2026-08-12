import XCTest
@testable import QuakeSignal

final class ForegroundHTTPFallbackPolicyTests: XCTestCase {
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
