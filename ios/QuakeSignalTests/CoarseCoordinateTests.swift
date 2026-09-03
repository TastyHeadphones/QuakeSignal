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

    func testTokyoIsNotTreatedAsChinaGCJ02() {
        XCTAssertFalse(ChinaCoordinateTransform.isInsideChina(latitude: 35.681, longitude: 139.767))
        let gps = ChinaCoordinateTransform.deviceGPSToWgs84(
            CLLocationCoordinate2D(latitude: 35.681, longitude: 139.767)
        )
        XCTAssertEqual(gps.latitude, 35.681, accuracy: 0.000_000_1)
        XCTAssertEqual(gps.longitude, 139.767, accuracy: 0.000_000_1)
    }

    func testBeijingDeviceGPSIsConvertedFromGCJ02ToWGS84() {
        let wgs = CLLocationCoordinate2D(latitude: 39.9042, longitude: 116.4074)
        let gcj = ChinaCoordinateTransform.wgs84ToGcj02(latitude: wgs.latitude, longitude: wgs.longitude)
        let recovered = ChinaCoordinateTransform.deviceGPSToWgs84(gcj)
        XCTAssertGreaterThan(
            CLLocation(latitude: wgs.latitude, longitude: wgs.longitude)
                .distance(from: CLLocation(latitude: gcj.latitude, longitude: gcj.longitude)),
            200
        )
        XCTAssertLessThan(
            CLLocation(latitude: recovered.latitude, longitude: recovered.longitude)
                .distance(from: CLLocation(latitude: wgs.latitude, longitude: wgs.longitude)),
            200
        )
    }

    func testCENCEventMatchesWGS84CityAfterChinaTransfer() throws {
        let city = CLLocationCoordinate2D(latitude: 39.9042, longitude: 116.4074)
        let gcj = ChinaCoordinateTransform.wgs84ToGcj02(latitude: city.latitude, longitude: city.longitude)
        var chinaEvent = event(latitude: gcj.latitude, longitude: gcj.longitude)
        chinaEvent = EEWEvent(
            id: "cenc_eew:beijing",
            sourceId: "cenc_eew",
            eventId: "beijing",
            serial: 1,
            kind: "eew",
            originTimeUtc: chinaEvent.originTimeUtc,
            reportTimeUtc: chinaEvent.reportTimeUtc,
            hypocenter: "Beijing",
            latitude: gcj.latitude,
            longitude: gcj.longitude,
            magnitude: 5.0,
            depth: 10,
            maxIntensity: "5",
            isWarn: true,
            isFinal: false,
            isCancel: false,
            isTraining: false,
            tsunami: nil
        )
        let distance = try XCTUnwrap(chinaEvent.distanceKm(from: city))
        XCTAssertLessThan(distance, 0.2)

        var usgsEvent = chinaEvent
        usgsEvent = EEWEvent(
            id: "usgs_eqlist:beijing",
            sourceId: "usgs_eqlist",
            eventId: "beijing",
            serial: 1,
            kind: "report",
            originTimeUtc: chinaEvent.originTimeUtc,
            reportTimeUtc: chinaEvent.reportTimeUtc,
            hypocenter: "Beijing",
            latitude: gcj.latitude,
            longitude: gcj.longitude,
            magnitude: 5.0,
            depth: 10,
            maxIntensity: nil,
            isWarn: false,
            isFinal: true,
            isCancel: false,
            isTraining: false,
            tsunami: nil
        )
        let usgsDistance = try XCTUnwrap(usgsEvent.distanceKm(from: city))
        XCTAssertGreaterThan(usgsDistance, 0.2)
    }

    func testEventCoordinateRejectsNonFiniteAndOutOfRangeValues() throws {
        XCTAssertEqual(
            try XCTUnwrap(event(latitude: 90, longitude: 180).coordinate).latitude,
            90
        )
        XCTAssertNil(event(latitude: 90.000_001, longitude: 0).coordinate)
        XCTAssertNil(event(latitude: 0, longitude: -180.000_001).coordinate)
        XCTAssertNil(event(latitude: .infinity, longitude: 0).coordinate)
        XCTAssertNil(event(latitude: 0, longitude: .nan).coordinate)
    }

    func testEventDistanceAndBearingRejectInvalidEndpoints() {
        let valid = event(latitude: 35, longitude: 140)
        let invalidEvent = event(latitude: 91, longitude: 140)
        let invalidOrigin = CLLocationCoordinate2D(latitude: 0, longitude: 181)

        XCTAssertNotNil(valid.distanceKm(from: CLLocationCoordinate2D(latitude: 34, longitude: 139)))
        XCTAssertNil(invalidEvent.distanceKm(from: CLLocationCoordinate2D(latitude: 34, longitude: 139)))
        XCTAssertNil(valid.distanceKm(from: invalidOrigin))
        XCTAssertNil(invalidEvent.compassDirection(from: CLLocationCoordinate2D(latitude: 34, longitude: 139)))
        XCTAssertNil(valid.compassDirection(from: invalidOrigin))
    }

    func testWolfxNormalizerRejectsOutOfRangeCoordinatesForWarningsAndReports() throws {
        let warning = try JSONSerialization.data(withJSONObject: [
            "type": "jma_eew",
            "EventID": "invalid-coordinate-warning",
            "Serial": 1,
            "OriginTime": "2026/08/19 12:00:00",
            "AnnouncedTime": "2026/08/19 12:00:01",
            "Hypocenter": "Test",
            "Latitude": 91,
            "Longitude": 140,
            "Magunitude": 5,
            "isWarn": true,
        ])
        XCTAssertThrowsError(try WolfxNormalizer.validatedEvents(source: "jma_eew", data: warning))

        let reports = try JSONSerialization.data(withJSONObject: [
            "md5": "invalid-coordinate-report-list",
            "No1": [
                "Title": "report",
                "EventID": "invalid-coordinate-report",
                "time": "2026/08/19 12:00",
                "time_full": "2026/08/19 12:00:00",
                "location": "Test",
                "magnitude": "4.2",
                "shindo": "2",
                "depth": "10km",
                "latitude": "35",
                "longitude": "181",
                "info": "",
            ],
        ])
        XCTAssertThrowsError(try WolfxNormalizer.validatedEvents(source: "jma_eqlist", data: reports))
    }

    private func event(latitude: Double, longitude: Double) -> EEWEvent {
        EEWEvent(
            id: "jma_eew:test",
            sourceId: "jma_eew",
            eventId: "test",
            serial: 1,
            kind: "eew",
            originTimeUtc: "2026-08-19T03:00:00Z",
            reportTimeUtc: "2026-08-19T03:00:01Z",
            hypocenter: "Test",
            latitude: latitude,
            longitude: longitude,
            magnitude: 5,
            depth: 10,
            maxIntensity: "4",
            isWarn: true,
            isFinal: false,
            isCancel: false,
            isTraining: false,
            tsunami: nil
        )
    }
}
