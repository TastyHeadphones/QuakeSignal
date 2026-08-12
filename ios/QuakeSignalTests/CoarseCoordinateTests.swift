import CoreLocation
import XCTest
@testable import QuakeSignal

final class CoarseCoordinateTests: XCTestCase {
    func testQuantizesCoordinatesToOneTenthOfADegree() throws {
        let coarse = try XCTUnwrap(CoarseCoordinate(CLLocationCoordinate2D(latitude: 35.6762, longitude: 139.6503)))

        XCTAssertEqual(coarse.latitude, 35.7, accuracy: 0.000_001)
        XCTAssertEqual(coarse.longitude, 139.7, accuracy: 0.000_001)
    }

    func testQuantizesNegativeCoordinatesWithoutLeakingNegativeZero() throws {
        let coarse = try XCTUnwrap(CoarseCoordinate(CLLocationCoordinate2D(latitude: -33.8688, longitude: -0.02)))

        XCTAssertEqual(coarse.latitude, -33.9, accuracy: 0.000_001)
        XCTAssertEqual(coarse.longitude, 0, accuracy: 0.000_001)
        XCTAssertEqual(coarse.longitude.sign, .plus)
    }

    func testRejectsInvalidCoordinates() {
        XCTAssertNil(CoarseCoordinate(CLLocationCoordinate2D(latitude: 91, longitude: 0)))
        XCTAssertNil(CoarseCoordinate(CLLocationCoordinate2D(latitude: 0, longitude: 181)))
    }
}
