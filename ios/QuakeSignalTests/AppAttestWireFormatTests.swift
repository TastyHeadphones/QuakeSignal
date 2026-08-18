import CryptoKit
import DeviceCheck
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

    func testTestAlertRequestContainsOnlyTheDeviceToken() throws {
        let request = try JSONEncoder().encode(DeviceTokenRequest(token: "device-token"))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: request) as? [String: String]
        )
        XCTAssertEqual(object, ["token": "device-token"])
    }

#if QUAKESIGNAL_INTERNAL_QA
    func testDelayedTrainingRequestIsStrictlyEncodedAndChangesTheAttestedBody() throws {
        let immediate = try JSONEncoder().encode(DeviceTokenRequest(token: "device-token"))
        let delayed = try JSONEncoder().encode(DelayedTrainingTestRequest(token: "device-token"))
        let delayedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: delayed) as? [String: String]
        )
        XCTAssertEqual(
            delayedObject,
            ["token": "device-token", "delivery": "delayed-training"]
        )

        let challenge = AppAttestChallenge(
            id: "challenge-123",
            challenge: base64URL(Data(repeating: 7, count: 32)),
            proofType: .assertion
        )
        let binding = AppAttestRequestBinding(
            operation: .testPush,
            method: "POST",
            path: "/v1/devices/test"
        )
        let immediateProof = try AppAttestWireFormat.clientData(
            keyID: "opaque-key",
            challenge: challenge,
            binding: binding,
            body: immediate
        )
        let delayedProof = try AppAttestWireFormat.clientData(
            keyID: "opaque-key",
            challenge: challenge,
            binding: binding,
            body: delayed
        )
        XCTAssertNotEqual(immediateProof, delayedProof)
    }
#endif

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

    func testAttestationRetriesServerUnavailableWithTheSameKeyAndHash() async throws {
        let service = AppAttestServiceDouble(attestationServerUnavailableFailures: 2)
        let delayRecorder = AppAttestDelayRecorder()
        let hash = Data(repeating: 0xA5, count: 32)
        let proof = try await AppAttestProofGenerator(
            service: service,
            sleep: { delay in await delayRecorder.record(delay) }
        ).proof(
            type: .attestation,
            keyID: "stable-key",
            clientDataHash: hash
        )

        XCTAssertEqual(proof, Data([0x01, 0x02, 0x03]))
        let calls = await service.attestationCalls
        XCTAssertEqual(calls.count, 3)
        XCTAssertTrue(calls.allSatisfy { $0.keyID == "stable-key" && $0.hash == hash })
        let recordedDelayCount = await delayRecorder.count
        XCTAssertEqual(recordedDelayCount, 2)
    }

    func testNonTransientAttestationFailureReplacesTheKey() {
        let error = NSError(
            domain: DCErrorDomain,
            code: DCError.unknownSystemFailure.rawValue
        )

        XCTAssertEqual(
            AppAttestProofRecoveryPolicy.action(
                for: error,
                proofType: .attestation,
                operation: .deviceRegistration
            ),
            .replaceKey
        )
    }

    func testAnyAssertionFailureReplacesTheKeyInsteadOfReusingABrokenCredential() {
        let serverUnavailable = NSError(
            domain: DCErrorDomain,
            code: DCError.serverUnavailable.rawValue
        )

        XCTAssertEqual(
            AppAttestProofRecoveryPolicy.action(
                for: serverUnavailable,
                proofType: .assertion,
                operation: .deviceRegistration
            ),
            .replaceKey
        )
    }

    func testAssertionFailureDuringDeletionPreservesTheOnlyOwningKey() {
        let failure = NSError(
            domain: DCErrorDomain,
            code: DCError.unknownSystemFailure.rawValue
        )

        XCTAssertEqual(
            AppAttestProofRecoveryPolicy.action(
                for: failure,
                proofType: .assertion,
                operation: .deviceDeletion
            ),
            .fail
        )
        XCTAssertEqual(
            AppAttestProofRecoveryPolicy.action(
                for: failure,
                proofType: .assertion,
                operation: .testPush
            ),
            .fail
        )
    }

    func testServerIntegrityRejectionUsesOperationSpecificSafeRecovery() {
        let rejected = APIError.server(
            statusCode: 401,
            message: "app integrity verification failed"
        )

        XCTAssertEqual(AppAttestServerRejectionRecoveryPolicy.action(
            after: rejected,
            operation: .deviceRegistration,
            mayRecoverRejectedKey: true
        ), .replaceKeyAndRetry)
        XCTAssertEqual(AppAttestServerRejectionRecoveryPolicy.action(
            after: rejected,
            operation: .testPush,
            mayRecoverRejectedKey: true
        ), .replaceKeyAndFail)
        XCTAssertEqual(AppAttestServerRejectionRecoveryPolicy.action(
            after: rejected,
            operation: .deviceDeletion,
            mayRecoverRejectedKey: true
        ), .fail)
        XCTAssertEqual(AppAttestServerRejectionRecoveryPolicy.action(
            after: rejected,
            operation: .deviceRegistration,
            mayRecoverRejectedKey: false
        ), .fail)
        XCTAssertEqual(AppAttestServerRejectionRecoveryPolicy.action(
            after: APIError.server(statusCode: 503, message: "temporarily unavailable"),
            operation: .deviceRegistration,
            mayRecoverRejectedKey: true
        ), .fail)
        XCTAssertEqual(AppAttestServerRejectionRecoveryPolicy.action(
            after: URLError(.timedOut),
            operation: .deviceRegistration,
            mayRecoverRejectedKey: true
        ), .fail)
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private actor AppAttestServiceDouble: AppAttestServicing {
    nonisolated let isSupported = true

    struct AttestationCall: Sendable {
        let keyID: String
        let hash: Data
    }

    private var remainingAttestationFailures: Int
    private(set) var attestationCalls: [AttestationCall] = []

    init(attestationServerUnavailableFailures: Int) {
        remainingAttestationFailures = attestationServerUnavailableFailures
    }

    func generateKey() async throws -> String {
        "generated-key"
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        attestationCalls.append(AttestationCall(keyID: keyID, hash: clientDataHash))
        if remainingAttestationFailures > 0 {
            remainingAttestationFailures -= 1
            throw NSError(
                domain: DCErrorDomain,
                code: DCError.serverUnavailable.rawValue
            )
        }
        return Data([0x01, 0x02, 0x03])
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        Data([0x04, 0x05, 0x06])
    }
}

private actor AppAttestDelayRecorder {
    private(set) var count = 0

    func record(_ duration: Duration) {
        count += 1
    }
}
