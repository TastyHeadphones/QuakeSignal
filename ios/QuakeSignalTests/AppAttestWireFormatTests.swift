import CryptoKit
import Foundation
import XCTest
@testable import QuakeSignal

final class AppAttestWireFormatTests: XCTestCase {
    func testCanonicalClientDataIsByteExactAndEndsWithLineFeed() throws {
        let body = Data(#"{"token":"abc"}"#.utf8)
        let challengeBytes = Data([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15])
        let challenge = AppAttestChallenge(
            id: "challenge-123",
            challenge: base64URL(challengeBytes),
            proofType: .attestation
        )
        let binding = AppAttestRequestBinding(
            operation: .deviceRegistration,
            method: "POST",
            path: "/v1/devices"
        )

        let actual = try AppAttestWireFormat.clientData(
            keyID: "opaque-apple-key-id",
            challenge: challenge,
            binding: binding,
            body: body
        )
        let expected = [
            "version=MQ",
            "key_id=b3BhcXVlLWFwcGxlLWtleS1pZA",
            "challenge_id=Y2hhbGxlbmdlLTEyMw",
            "challenge=AAECAwQFBgcICQoLDA0ODw",
            "operation=ZGV2aWNlLXJlZ2lzdHJhdGlvbg",
            "method=UE9TVA",
            "path=L3YxL2RldmljZXM",
            "body_sha256=\(base64URL(Data(SHA256.hash(data: body))))",
            "",
        ].joined(separator: "\n")

        XCTAssertEqual(actual, Data(expected.utf8))
        XCTAssertEqual(actual.last, 0x0A)
    }

    func testDifferentOriginalBodyProducesDifferentSignedData() throws {
        let challenge = AppAttestChallenge(
            id: "challenge-123",
            challenge: base64URL(Data(repeating: 7, count: 32)),
            proofType: .assertion
        )
        let binding = AppAttestRequestBinding(
            operation: .deviceDeletion,
            method: "DELETE",
            path: "/v1/devices"
        )

        let original = try AppAttestWireFormat.clientData(
            keyID: "opaque-key",
            challenge: challenge,
            binding: binding,
            body: Data(#"{"token":"one"}"#.utf8)
        )
        let changed = try AppAttestWireFormat.clientData(
            keyID: "opaque-key",
            challenge: challenge,
            binding: binding,
            body: Data(#"{"token":"two"}"#.utf8)
        )

        XCTAssertNotEqual(original, changed)
    }

    func testIdentifierValidationRejectsHeaderInjection() {
        XCTAssertTrue(AppAttestWireFormat.isValidOpaqueIdentifier("AbCd-0123_opaque"))
        XCTAssertFalse(AppAttestWireFormat.isValidOpaqueIdentifier(""))
        XCTAssertFalse(AppAttestWireFormat.isValidOpaqueIdentifier("key\nforged-header"))
        XCTAssertFalse(AppAttestWireFormat.isValidOpaqueIdentifier(String(repeating: "a", count: 513)))
    }

    func testOnlyDevelopmentPolicyAllowsUnsupportedServiceBypass() {
        XCTAssertTrue(AppAttestClientPolicy.development.allowsUnsupportedServiceBypass)
        XCTAssertFalse(AppAttestClientPolicy.production.allowsUnsupportedServiceBypass)
    }

    func testUnsupportedServiceBypassIsExplicitlyUnavailableInProduction() throws {
        let developmentHeaders = try AppAttestClient.unsupportedServiceHeaders(for: .development)
        XCTAssertEqual(
            developmentHeaders["X-QuakeSignal-App-Attest-Bypass"],
            "development-unsupported"
        )

        XCTAssertThrowsError(
            try AppAttestClient.unsupportedServiceHeaders(for: .production)
        ) { error in
            guard case AppAttestError.unsupportedInProduction = error else {
                return XCTFail("Expected unsupportedInProduction, got \(error)")
            }
        }
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
