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

    func testHeartbeatOnlyRouteGetsABoundedInitialDataWindow() {
        let connectedAt = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(LiveSocketLivenessPolicy.shouldReconnect(
            isReady: false,
            connectedAt: connectedAt,
            lastActivity: connectedAt.addingTimeInterval(80),
            now: connectedAt.addingTimeInterval(90)
        ))
        XCTAssertTrue(LiveSocketLivenessPolicy.shouldReconnect(
            isReady: false,
            connectedAt: connectedAt,
            lastActivity: connectedAt.addingTimeInterval(90),
            now: connectedAt.addingTimeInterval(91)
        ))
        XCTAssertFalse(LiveSocketLivenessPolicy.shouldReconnect(
            isReady: true,
            connectedAt: connectedAt,
            lastActivity: connectedAt.addingTimeInterval(90),
            now: connectedAt.addingTimeInterval(91)
        ))
        XCTAssertTrue(LiveSocketLivenessPolicy.shouldReconnect(
            isReady: true,
            connectedAt: connectedAt,
            lastActivity: connectedAt.addingTimeInterval(90),
            now: connectedAt.addingTimeInterval(181)
        ))
    }

    func testSocketReadinessRequiresValidatedDataInsteadOfTransportHeartbeats() throws {
        let heartbeatObjects: [[String: Any]] = [
            [
                "type": "heartbeat",
                "ver": 22,
                "id": "2094581",
                "timestamp": 1_787_241_213_884,
            ],
            [
                "type": "heartbeat",
                "ver": 20_260_415,
                "id": "123e4567-e89b-42d3-a456-426614174000",
                "timestamp": "1787241213884",
            ],
            ["type": "pong", "timestamp": 1_787_241_234_570],
            ["type": "pong", "timestamp": "1787241234570"],
        ]
        for heartbeat in heartbeatObjects {
            let keepAlive = LiveSocketPayloadPolicy.decode(
                source: "jma_eew",
                data: try data(heartbeat)
            )
            XCTAssertEqual(keepAlive, .keepAlive)
            XCTAssertFalse(LiveSocketPayloadPolicy.routeIsReady(wasReady: false, payload: keepAlive))
            XCTAssertTrue(LiveSocketPayloadPolicy.routeIsReady(wasReady: true, payload: keepAlive))
        }

        let validated = LiveSocketPayloadPolicy.decode(
            source: "jma_eew",
            data: try data(validEEW(type: "jma_eew"))
        )
        guard case .events(let events) = validated else {
            return XCTFail("a complete JMA frame must be accepted")
        }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.sourceId, "jma_eew")
        XCTAssertTrue(LiveSocketPayloadPolicy.routeIsReady(wasReady: false, payload: validated))

        guard case .events(let reportEvents) = LiveSocketPayloadPolicy.decode(
            source: "jma_eqlist",
            data: try data(validEqlist(type: "jma_eqlist"))
        ) else {
            return XCTFail("a complete JMA report list must be accepted")
        }
        XCTAssertEqual(reportEvents.count, 1)
        XCTAssertEqual(reportEvents.first?.sourceId, "jma_eqlist")
    }

    func testHttpSnapshotsAcceptAbsentEnvelopeButRejectWrongDeclaredSource() throws {
        let eewEvents = try WolfxNormalizer.validatedEvents(
            source: "jma_eew",
            data: data(validEEW())
        )
        XCTAssertEqual(eewEvents.map(\.id), ["jma_eew:20260820120000"])

        let reportEvents = try WolfxNormalizer.validatedEvents(
            source: "jma_eqlist",
            data: data(validEqlist())
        )
        XCTAssertEqual(reportEvents.map(\.id), ["jma_eqlist:20260820120003"])

        var differingOriginAndReportMinute = validEqlist()
        var delayedEntry = try XCTUnwrap(differingOriginAndReportMinute["No1"] as? [String: Any])
        delayedEntry["EventID"] = "20260820120103"
        differingOriginAndReportMinute["No1"] = delayedEntry
        XCTAssertNoThrow(try WolfxNormalizer.validatedEvents(
            source: "jma_eqlist",
            data: data(differingOriginAndReportMinute)
        ))

        XCTAssertThrowsError(try WolfxNormalizer.validatedEvents(
            source: "jma_eew",
            data: data(validEEW(type: "sc_eew"))
        ))
        XCTAssertThrowsError(try WolfxNormalizer.validatedEvents(
            source: "jma_eqlist",
            data: data(validEqlist(type: "jma_eew"))
        ))
    }

    func testMalformedControlFramesNeverPreserveReadyRoute() throws {
        let malformed: [[String: Any]] = [
            ["type": "heartbeat"],
            ["type": "heartbeat", "ver": "22", "id": "2094581", "timestamp": 1_787_241_213_884],
            ["type": "heartbeat", "ver": 0, "id": "2094581", "timestamp": 1_787_241_213_884],
            ["type": "heartbeat", "ver": 22.5, "id": "2094581", "timestamp": 1_787_241_213_884],
            ["type": "heartbeat", "ver": 22, "id": "02094581", "timestamp": 1_787_241_213_884],
            ["type": "heartbeat", "ver": 22, "id": 2_094_581, "timestamp": 1_787_241_213_884],
            ["type": "heartbeat", "ver": 22, "id": "arbitrary", "timestamp": 1_787_241_213_884],
            ["type": "heartbeat", "ver": 22, "id": "2094581", "timestamp": "01787241213884"],
            ["type": "heartbeat", "ver": 22, "id": "2094581", "timestamp": 1_787_241_213.5],
            ["type": "pong", "timestamp": "178724123457"],
        ]
        for object in malformed {
            let payload = LiveSocketPayloadPolicy.decode(
                source: "jma_eew",
                data: try data(object)
            )
            XCTAssertEqual(payload, .invalid, "unexpectedly accepted \(object)")
            XCTAssertFalse(LiveSocketPayloadPolicy.routeIsReady(wasReady: true, payload: payload))
        }
    }

    func testMalformedSocketFrameDemotesReadyRouteAndCannotExtendLiveness() throws {
        var partial = validEEW(type: "jma_eew")
        partial.removeValue(forKey: "Serial")
        let invalid = LiveSocketPayloadPolicy.decode(source: "jma_eew", data: try data(partial))
        XCTAssertEqual(invalid, .invalid)
        XCTAssertFalse(LiveSocketPayloadPolicy.routeIsReady(wasReady: true, payload: invalid))

        XCTAssertEqual(
            LiveSocketPayloadPolicy.decode(source: "jma_eew", data: Data("{".utf8)),
            .invalid
        )
        XCTAssertEqual(
            LiveSocketPayloadPolicy.decode(source: "cenc_eew", data: try data(partial)),
            .invalid
        )

        var wrongList = validEqlist(type: "jma_eqlist")
        wrongList["type"] = "sc_eew"
        XCTAssertEqual(
            LiveSocketPayloadPolicy.decode(
                source: "jma_eqlist",
                data: try data(wrongList)
            ),
            .invalid
        )
    }

    func testStrictJmaDomainsRejectCoercionCalendarRolloverAndPartialLists() throws {
        var invalidEEWFrames: [[String: Any]] = []
        var invalidDate = validEEW()
        invalidDate["OriginTime"] = "2026/02/31 12:00:00"
        invalidEEWFrames.append(invalidDate)
        var invalidMagnitude = validEEW()
        invalidMagnitude["Magunitude"] = "5.8"
        invalidEEWFrames.append(invalidMagnitude)
        var invalidDepth = validEEW()
        invalidDepth["Depth"] = -1
        invalidEEWFrames.append(invalidDepth)
        var invalidIntensity = validEEW()
        invalidIntensity["MaxIntensity"] = "5"
        invalidEEWFrames.append(invalidIntensity)
        for flag in ["isWarn", "isFinal", "isCancel", "isTraining"] {
            var missing = validEEW()
            missing.removeValue(forKey: flag)
            invalidEEWFrames.append(missing)
            var nonBoolean = validEEW()
            nonBoolean[flag] = 0
            invalidEEWFrames.append(nonBoolean)
        }
        for object in invalidEEWFrames {
            XCTAssertThrowsError(try WolfxNormalizer.validatedEvents(
                source: "jma_eew",
                data: data(object)
            ), "unexpectedly accepted \(object)")
        }

        var invalidLists: [[String: Any]] = []
        var badMD5 = validEqlist()
        badMD5["md5"] = "fixture"
        invalidLists.append(badMD5)
        var soleNo50 = validEqlist()
        soleNo50["No50"] = soleNo50.removeValue(forKey: "No1")
        invalidLists.append(soleNo50)
        var gap = validEqlist()
        gap["No3"] = gap["No1"]
        invalidLists.append(gap)
        for (field, badValue) in [
            ("time_full", "2026/02/31 12:00:00"),
            ("magnitude", "abc"),
            ("depth", "+"),
            ("shindo", "not-jma"),
        ] {
            var object = validEqlist()
            var entry = try XCTUnwrap(object["No1"] as? [String: Any])
            entry[field] = badValue
            object["No1"] = entry
            invalidLists.append(object)
        }
        for object in invalidLists {
            XCTAssertThrowsError(try WolfxNormalizer.validatedEvents(
                source: "jma_eqlist",
                data: data(object)
            ), "unexpectedly accepted \(object)")
        }
    }

    private func validEEW(type: String? = nil) -> [String: Any] {
        var object: [String: Any] = [
            "Title": "Earthquake Early Warning",
            "CodeType": "Fixture",
            "Issue": ["Source": "JMA", "Status": "通常"],
            "EventID": "20260820120000",
            "Serial": 1,
            "OriginTime": "2026/08/20 12:00:00",
            "AnnouncedTime": "2026/08/20 12:00:01",
            "Hypocenter": "Noto Peninsula",
            "Latitude": 37.4,
            "Longitude": 137.2,
            "Magunitude": 5.8,
            "Depth": 10,
            "MaxIntensity": "5+",
            "Accuracy": ["Epicenter": "1", "Depth": "1", "Magnitude": "1"],
            "MaxIntChange": ["String": "0", "Reason": "0"],
            "WarnArea": [],
            "isSea": true,
            "isAssumption": false,
            "isWarn": true,
            "isFinal": false,
            "isCancel": false,
            "isTraining": false,
            "OriginalText": "fixture",
        ]
        object["type"] = type
        return object
    }

    private func validEqlist(type: String? = nil) -> [String: Any] {
        var object: [String: Any] = [
            "md5": "0123456789abcdef0123456789abcdef",
            "No1": [
                "Title": "Hypocenter and intensity information",
                "EventID": "20260820120003",
                "time": "2026/08/20 12:00",
                "time_full": "2026/08/20 12:00:00",
                "location": "Noto Peninsula",
                "magnitude": "5.8",
                "shindo": "5+",
                "depth": "10km",
                "latitude": "37.4",
                "longitude": "137.2",
                "info": "No tsunami concern.",
            ],
        ]
        object["type"] = type
        return object
    }

    private func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
