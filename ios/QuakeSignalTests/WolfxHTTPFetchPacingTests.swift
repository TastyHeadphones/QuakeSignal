import XCTest
@testable import QuakeSignal

final class WolfxHTTPFetchPacingTests: XCTestCase {
    func testDirectWolfxSessionDisablesPersistentTransportState() {
        let configuration = WolfxURLSessionPolicy.configuration()

        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.urlCredentialStorage)
    }

    func testEveryWolfxHTTPRequestExplicitlyBypassesLocalCacheData() throws {
        let url = try XCTUnwrap(URL(string: "https://api.wolfx.jp/jma_eew.json"))
        let request = WolfxURLSessionPolicy.request(for: url)

        XCTAssertEqual(request.url, url)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testSnapshotRequestsAreSpacedWithinWolfxPublicLimit() {
        XCTAssertEqual(WolfxClient.sources, ["jma_eew", "jma_eqlist"])
        XCTAssertEqual(WolfxHTTPFetchPacing.delayNanoseconds(forSourceIndex: 0), 0)
        XCTAssertGreaterThanOrEqual(WolfxHTTPFetchPacing.requestIntervalNanoseconds, 500_000_000)
        XCTAssertEqual(
            WolfxHTTPFetchPacing.delayNanoseconds(forSourceIndex: WolfxClient.sources.count - 1),
            600_000_000
        )
    }

    func testPartialSnapshotRetainsSuccessfulSourcesAndSummarizesFailure() {
        let older = event(id: "jma_eew:one", serial: 1, reportTime: "2026-08-12T01:00:00Z")
        let newer = event(id: "jma_eew:one", serial: 2, reportTime: "2026-08-12T01:01:00Z")
        let report = event(id: "jma_eqlist:two", serial: 1, reportTime: "2026-08-12T01:02:00Z")

        let result = WolfxSnapshotFetchResult.aggregate(
            batches: [[older], [newer, report]],
            failedSources: ["jma_eqlist"],
            successfulSourceCount: 1,
            limit: 50
        )

        XCTAssertTrue(result.hasSuccessfulSources)
        XCTAssertEqual(result.events.map(\.id), ["jma_eqlist:two", "jma_eew:one"])
        XCTAssertEqual(result.events.last?.serial, 2)
        XCTAssertEqual(
            result.statusDescription,
            "Updated from 1 of 2 Wolfx sources; unavailable: jma_eqlist."
        )
    }

    private func event(id: String, serial: Int, reportTime: String) -> EEWEvent {
        EEWEvent(
            id: id,
            sourceId: id.components(separatedBy: ":").first ?? "jma_eew",
            eventId: id,
            serial: serial,
            kind: "eew",
            originTimeUtc: reportTime,
            reportTimeUtc: reportTime,
            hypocenter: "Test",
            latitude: nil,
            longitude: nil,
            magnitude: nil,
            depth: nil,
            maxIntensity: nil,
            isWarn: false,
            isFinal: false,
            isCancel: false,
            isTraining: false,
            tsunami: nil
        )
    }
}
