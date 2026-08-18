import CryptoKit
import DeviceCheck
import Foundation
import Security

/// The mutating device endpoints are high-value targets: an attacker who can
/// register a token can turn the alert service into a notification relay, and
/// an attacker who can delete one can silence a device. App Attest binds every
/// such request to a fresh, single-use server challenge.
///
/// Wire contract (version 1):
///
/// 1. The client asks `POST /v1/app-attest/challenge` for a challenge using
///    the key ID plus the exact operation/method/path/body digest it intends
///    to send.
/// 2. The Worker returns a random base64url `challenge`, its opaque
///    `challengeId`, and the proof type it expects for that key. The Worker,
///    not the client, remains authoritative for whether a key needs an
///    attestation or an assertion.
/// 3. This type signs the byte-exact `AppAttestWireFormat` below, then puts the
///    resulting Apple proof in the protected request headers. The Worker must
///    reconstruct those bytes, consume the one-time challenge, verify the
///    Apple proof and its monotonic counter, and atomically apply the request.
///
/// The opaque Apple key identifier is persistent application state rather than
/// a secret. It is only used to locate a Secure Enclave key; the private key
/// never leaves Apple's App Attest service.
actor AppAttestClient {
    static let shared = AppAttestClient()

    private let service: any AppAttestServicing
    private let session: URLSession
    private var keyStore: AppAttestKeyStoring
    private let policy: AppAttestClientPolicy
    private let proofRetrySleep: AppAttestRetrySleep
    private let protectedRequestSerialiser = AppAttestRequestSerialiser()

    init(
        session: URLSession = .shared,
        service: any AppAttestServicing = SystemAppAttestService.shared,
        keyStore: AppAttestKeyStoring = KeychainAppAttestKeyStore(),
        policy: AppAttestClientPolicy = .current,
        proofRetrySleep: @escaping AppAttestRetrySleep = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.session = session
        self.service = service
        self.keyStore = keyStore
        self.policy = policy
        self.proofRetrySleep = proofRetrySleep
    }

    /// Serializes every challenge → proof → HTTP request flow. App Attest
    /// assertions carry a monotonically increasing counter, so two proof
    /// requests must not be allowed to reach the Worker in a different order
    /// from the order in which Apple issued them.
    func performProtectedRequest(
        binding: AppAttestRequestBinding,
        body: Data
    ) async throws {
        await protectedRequestSerialiser.acquire()
        do {
            try await performProtectedRequestWhileSerialised(
                binding: binding,
                body: body,
                mayRecoverRejectedKey: true
            )
            await protectedRequestSerialiser.release()
        } catch {
            await protectedRequestSerialiser.release()
            throw error
        }
    }

    /// A 401 from a protected endpoint means the Worker rejected the App
    /// Attest identity before applying the requested mutation. This can
    /// happen after an app restore or when Apple can no longer usefully
    /// attest the locally cached key. Registration can safely replace the key
    /// and repeat its complete challenge -> proof -> request flow exactly
    /// once. A rejected test resets the key but returns control to Settings,
    /// which must register that new identity before retrying the test. Other
    /// HTTP/network failures remain ambiguous and are never replayed.
    private func performProtectedRequestWhileSerialised(
        binding: AppAttestRequestBinding,
        body: Data,
        mayRecoverRejectedKey: Bool
    ) async throws {
        let headers = try await attestationHeaders(for: binding, body: body)
        var request = URLRequest(url: BackendConfig.httpBaseURL.appending(path: binding.path))
        request.httpMethod = binding.method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await session.data(for: request)
        do {
            try APIClient.validate(response, data: data)
        } catch {
            switch AppAttestServerRejectionRecoveryPolicy.action(
                after: error,
                operation: binding.operation,
                mayRecoverRejectedKey: mayRecoverRejectedKey
            ) {
            case .fail:
                throw error
            case .replaceKeyAndFail:
                try removeStoredKeyID()
                throw AppAttestError.serverRejectedCredential
            case .replaceKeyAndRetry:
                try removeStoredKeyID()
                try await performProtectedRequestWhileSerialised(
                    binding: binding,
                    body: body,
                    mayRecoverRejectedKey: false
                )
            }
        }
    }

    /// Returns the headers that authenticate one device-API request. The body
    /// passed here is exactly the body later sent by `performProtectedRequest`;
    /// never re-encode it after hashing or an assertion will be rejected.
    private func attestationHeaders(
        for binding: AppAttestRequestBinding,
        body: Data
    ) async throws -> [String: String] {
        guard service.isSupported else {
            // Simulators and some older devices do not provide App Attest.
            // A bypass is deliberately possible only in an explicitly marked
            // Debug/development build. Production clients fail closed here.
            return try Self.unsupportedServiceHeaders(for: policy)
        }

        return try await headersWithSupportedService(
            for: binding,
            body: body,
            mayRotateKey: true
        )
    }

    private func headersWithSupportedService(
        for binding: AppAttestRequestBinding,
        body: Data,
        mayRotateKey: Bool
    ) async throws -> [String: String] {
        let keyID = try await keyIdentifier()
        let challenge = try await fetchChallenge(for: binding, body: body, keyID: keyID)
        let clientData = try AppAttestWireFormat.clientData(
            keyID: keyID,
            challenge: challenge,
            binding: binding,
            body: body
        )
        let clientDataHash = Data(SHA256.hash(data: clientData))

        do {
            let proof = try await AppAttestProofGenerator(
                service: service,
                sleep: proofRetrySleep
            ).proof(
                type: challenge.proofType,
                keyID: keyID,
                clientDataHash: clientDataHash
            )
            return [
                AppAttestHeader.version: AppAttestWireFormat.version,
                AppAttestHeader.keyID: keyID,
                AppAttestHeader.challengeID: challenge.id,
                AppAttestHeader.proofType: challenge.proofType.rawValue,
                AppAttestHeader.proof: proof.base64URLEncodedString(),
            ]
        } catch {
            // Apple requires a server-unavailable attestation to retry with the
            // same key and client-data hash. `AppAttestProofGenerator` performs
            // those bounded retries above. Any other proof failure means the
            // key must be discarded before one fresh enrollment attempt. This
            // also repairs an assertion key that the Secure Enclave can no
            // longer use even though the Worker still has its public record.
            guard mayRotateKey,
                  AppAttestProofRecoveryPolicy.action(
                      for: error,
                      proofType: challenge.proofType,
                      operation: binding.operation
                  ) == .replaceKey else {
                throw AppAttestError.proofGenerationFailed(underlying: error)
            }
            try removeStoredKeyID()
            return try await headersWithSupportedService(
                for: binding,
                body: body,
                mayRotateKey: false
            )
        }
    }

    private func keyIdentifier() async throws -> String {
        do {
            if let keyID = try keyStore.keyID(), AppAttestWireFormat.isValidOpaqueIdentifier(keyID) {
                return keyID
            }
            try keyStore.removeKeyID()
        } catch {
            throw AppAttestError.keyStorageFailed(underlying: error)
        }

        do {
            let keyID = try await service.generateKey()
            guard AppAttestWireFormat.isValidOpaqueIdentifier(keyID) else {
                throw AppAttestError.invalidKeyIdentifier
            }
            do {
                try keyStore.setKeyID(keyID)
            } catch {
                throw AppAttestError.keyStorageFailed(underlying: error)
            }
            return keyID
        } catch let error as AppAttestError {
            throw error
        } catch {
            throw AppAttestError.keyGenerationFailed(underlying: error)
        }
    }

    private func fetchChallenge(
        for binding: AppAttestRequestBinding,
        body: Data,
        keyID: String
    ) async throws -> AppAttestChallenge {
        let bodyHash = Data(SHA256.hash(data: body)).base64URLEncodedString()
        let payload = AppAttestChallengeRequest(
            version: AppAttestWireFormat.version,
            keyID: keyID,
            operation: binding.operation.rawValue,
            method: binding.method,
            path: binding.path,
            bodySHA256: bodyHash
        )

        var request = URLRequest(
            url: BackendConfig.httpBaseURL.appending(path: AppAttestEndpoint.challengePath)
        )
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")

        do {
            let (data, response) = try await session.data(for: request)
            try APIClient.validate(response, data: data)
            let challenge = try JSONDecoder().decode(AppAttestChallenge.self, from: data)
            guard AppAttestWireFormat.isValidOpaqueIdentifier(challenge.id),
                  challenge.challengeData != nil else {
                throw AppAttestError.invalidChallenge
            }
            return challenge
        } catch let error as AppAttestError {
            throw error
        } catch {
            throw AppAttestError.challengeRequestFailed(underlying: error)
        }
    }

    private func removeStoredKeyID() throws {
        do {
            try keyStore.removeKeyID()
        } catch {
            throw AppAttestError.keyStorageFailed(underlying: error)
        }
    }

    /// Kept separate from the DeviceCheck call so the fail-closed simulator
    /// policy remains unit-testable without trying to mock Apple's framework.
    static func unsupportedServiceHeaders(
        for policy: AppAttestClientPolicy
    ) throws -> [String: String] {
        guard policy.allowsUnsupportedServiceBypass else {
            throw AppAttestError.unsupportedInProduction
        }
        return [AppAttestHeader.developmentBypass: "development-unsupported"]
    }
}

protocol AppAttestServicing: AnyObject, Sendable {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data
}

private final class SystemAppAttestService: AppAttestServicing, @unchecked Sendable {
    static let shared = SystemAppAttestService()

    private let service = DCAppAttestService.shared

    var isSupported: Bool { service.isSupported }

    func generateKey() async throws -> String {
        try await service.generateKey()
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await service.attestKey(keyID, clientDataHash: clientDataHash)
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await service.generateAssertion(keyID, clientDataHash: clientDataHash)
    }
}

typealias AppAttestRetrySleep = @Sendable (Duration) async throws -> Void

enum AppAttestProofRecoveryAction: Equatable {
    case retrySameKey
    case replaceKey
    case fail
}

enum AppAttestProofRecoveryPolicy {
    static func action(
        for error: Error,
        proofType: AppAttestChallenge.ProofType,
        operation: AppAttestOperation
    ) -> AppAttestProofRecoveryAction {
        if error is CancellationError {
            return .fail
        }

        // Registration is the only operation that can safely hand ownership
        // to a replacement key. Rotating during deletion could discard the
        // sole credential capable of removing the existing registration;
        // rotating during a test would create a key that owns no device.
        guard operation == .deviceRegistration else { return .fail }

        let nsError = error as NSError
        if proofType == .attestation,
           nsError.domain == DCErrorDomain,
           nsError.code == DCError.serverUnavailable.rawValue {
            return .retrySameKey
        }
        return .replaceKey
    }
}

enum AppAttestServerRejectionRecoveryAction: Equatable {
    case replaceKeyAndRetry
    case replaceKeyAndFail
    case fail
}

enum AppAttestServerRejectionRecoveryPolicy {
    static func action(
        after error: Error,
        operation: AppAttestOperation,
        mayRecoverRejectedKey: Bool
    ) -> AppAttestServerRejectionRecoveryAction {
        guard mayRecoverRejectedKey,
              let apiError = error as? APIError,
              apiError.statusCode == 401 else {
            return .fail
        }
        switch operation {
        case .deviceRegistration:
            // Registration is the ownership hand-off for a fresh key, and a
            // 401 guarantees the rejected attempt did not mutate the device.
            return .replaceKeyAndRetry
        case .testPush:
            // A fresh key cannot own a test-push request. Let Settings first
            // re-register the token, then issue the test exactly once.
            return .replaceKeyAndFail
        case .deviceDeletion:
            // Rotating here would discard the only key that may still own the
            // registration and would not make a deletion retry safer.
            return .fail
        }
    }
}

struct AppAttestProofGenerator: Sendable {
    private static let attestationRetryDelays: [Duration] = [
        .milliseconds(250),
        .milliseconds(750),
        .seconds(2),
    ]

    let service: any AppAttestServicing
    let sleep: AppAttestRetrySleep

    func proof(
        type: AppAttestChallenge.ProofType,
        keyID: String,
        clientDataHash: Data
    ) async throws -> Data {
        switch type {
        case .assertion:
            return try await service.generateAssertion(
                keyID,
                clientDataHash: clientDataHash
            )
        case .attestation:
            for retryDelay in Self.attestationRetryDelays {
                do {
                    return try await service.attestKey(
                        keyID,
                        clientDataHash: clientDataHash
                    )
                } catch {
                    guard AppAttestProofRecoveryPolicy.action(
                        for: error,
                        proofType: .attestation,
                        operation: .deviceRegistration
                    ) == .retrySameKey else {
                        throw error
                    }
                    try await sleep(retryDelay)
                }
            }
            return try await service.attestKey(
                keyID,
                clientDataHash: clientDataHash
            )
        }
    }
}

/// A small async mutex used only to preserve App Attest counter ordering. The
/// lock deliberately stays held across network awaits: another protected call
/// must not obtain an assertion until the preceding request has reached a
/// terminal client result.
private actor AppAttestRequestSerialiser {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard let next = waiters.first else {
            isHeld = false
            return
        }
        waiters.removeFirst()
        // Keep `isHeld` true while ownership transfers directly to `next`.
        next.resume()
    }
}

/// Build policy is intentionally fail-closed. An Info.plist value alone never
/// enables a bypass in a non-Debug binary, even if someone copies a development
/// plist into an archive.
enum AppAttestClientPolicy: Sendable, Equatable {
    case development
    case production

    static var current: Self {
        #if DEBUG
        let configuredMode = Bundle.main.object(
            forInfoDictionaryKey: "QUAKESIGNAL_APP_ATTEST_MODE"
        ) as? String
        return configuredMode == "development" ? .development : .production
        #else
        .production
        #endif
    }

    var allowsUnsupportedServiceBypass: Bool {
        self == .development
    }
}

enum AppAttestOperation: String, Sendable {
    case deviceRegistration = "device-registration"
    case deviceDeletion = "device-deletion"
    case testPush = "test-push"
}

struct AppAttestRequestBinding: Sendable, Equatable {
    let operation: AppAttestOperation
    let method: String
    let path: String

    init(operation: AppAttestOperation, method: String, path: String) {
        precondition(method == method.uppercased(), "App Attest methods must be canonical uppercase")
        precondition(path.hasPrefix("/") && !path.contains("?"), "App Attest paths must be canonical")
        self.operation = operation
        self.method = method
        self.path = path
    }
}

private enum AppAttestEndpoint {
    static let challengePath = "/v1/app-attest/challenge"
}

private enum AppAttestHeader {
    static let version = "X-QuakeSignal-App-Attest-Version"
    static let keyID = "X-QuakeSignal-App-Attest-Key-Id"
    static let challengeID = "X-QuakeSignal-App-Attest-Challenge-Id"
    static let proofType = "X-QuakeSignal-App-Attest-Proof-Type"
    static let proof = "X-QuakeSignal-App-Attest-Proof"
    static let developmentBypass = "X-QuakeSignal-App-Attest-Bypass"
}

private struct AppAttestChallengeRequest: Encodable {
    let version: String
    let keyID: String
    let operation: String
    let method: String
    let path: String
    let bodySHA256: String

    enum CodingKeys: String, CodingKey {
        case version
        case keyID = "keyId"
        case operation
        case method
        case path
        case bodySHA256
    }
}

struct AppAttestChallenge: Decodable, Sendable {
    enum ProofType: String, Decodable, Sendable {
        case attestation
        case assertion
    }

    let id: String
    let challenge: String
    let proofType: ProofType

    enum CodingKeys: String, CodingKey {
        case id = "challengeId"
        case challenge
        case proofType
    }

    var challengeData: Data? {
        guard let data = Data(base64URLEncoded: challenge),
              (16...512).contains(data.count) else {
            return nil
        }
        return data
    }
}

protocol AppAttestKeyStoring: Sendable {
    func keyID() throws -> String?
    func setKeyID(_ keyID: String) throws
    func removeKeyID() throws
}

/// Only Apple's App Attest service can use the private key, but its opaque ID
/// must survive launches. Keep it in a non-migrating Keychain item rather than
/// preferences: a restored backup must not make a new device claim an old
/// Secure Enclave key. `ThisDeviceOnly` also matches App Attest's device-bound
/// security model.
private final class KeychainAppAttestKeyStore: AppAttestKeyStoring, @unchecked Sendable {
    private static let service = "com.quakesignal.app.app-attest"
    private static let account = "key-id-v1"

    func keyID() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let keyID = String(data: data, encoding: .utf8) else {
                throw AppAttestKeyStoreError.invalidStoredValue
            }
            return keyID
        case errSecItemNotFound:
            return nil
        default:
            throw AppAttestKeyStoreError.unexpectedStatus(status)
        }
    }

    func setKeyID(_ keyID: String) throws {
        let data = Data(keyID.utf8)
        let update = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insert = baseQuery
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let insertStatus = SecItemAdd(insert as CFDictionary, nil)
            guard insertStatus == errSecSuccess else {
                throw AppAttestKeyStoreError.unexpectedStatus(insertStatus)
            }
        default:
            throw AppAttestKeyStoreError.unexpectedStatus(updateStatus)
        }
    }

    func removeKeyID() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppAttestKeyStoreError.unexpectedStatus(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
    }
}

private enum AppAttestKeyStoreError: LocalizedError {
    case invalidStoredValue
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidStoredValue:
            "The saved app integrity key identifier is invalid."
        case .unexpectedStatus:
            "The app integrity key could not be read from secure storage."
        }
    }
}

enum AppAttestWireFormat {
    /// The server and client must treat this literal as a protocol version;
    /// changing the layout requires a new version, never a best-effort parser.
    static let version = "1"

    /// Returns the exact UTF-8 bytes that are SHA-256 hashed before calling
    /// `attestKey` or `generateAssertion`. Every dynamic value is encoded as
    /// unpadded base64url to make line boundaries unambiguous. The trailing LF
    /// is deliberate and is part of the signed data.
    static func clientData(
        keyID: String,
        challenge: AppAttestChallenge,
        binding: AppAttestRequestBinding,
        body: Data
    ) throws -> Data {
        guard isValidOpaqueIdentifier(keyID), isValidOpaqueIdentifier(challenge.id),
              let challengeData = challenge.challengeData else {
            throw AppAttestError.invalidChallenge
        }

        let bodyHash = Data(SHA256.hash(data: body))
        let fields = [
            "version": Data(version.utf8),
            "key_id": Data(keyID.utf8),
            "challenge_id": Data(challenge.id.utf8),
            "challenge": challengeData,
            "operation": Data(binding.operation.rawValue.utf8),
            "method": Data(binding.method.utf8),
            "path": Data(binding.path.utf8),
            "body_sha256": bodyHash,
        ]
        // Keep the order explicit — dictionaries are intentionally not used as
        // a transport representation despite their current insertion order.
        let orderedNames = [
            "version",
            "key_id",
            "challenge_id",
            "challenge",
            "operation",
            "method",
            "path",
            "body_sha256",
        ]
        let lines = orderedNames.map { name in
            "\(name)=\(fields[name]!.base64URLEncodedString())"
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    static func isValidOpaqueIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 512 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            // Header-safe printable ASCII. Apple currently gives a base64-like
            // identifier, but it remains opaque to this client.
            (0x21...0x7E).contains(scalar.value)
        }
    }
}

enum AppAttestError: LocalizedError {
    case unsupportedInProduction
    case serverRejectedCredential
    case invalidKeyIdentifier
    case invalidChallenge
    case keyGenerationFailed(underlying: Error)
    case keyStorageFailed(underlying: Error)
    case challengeRequestFailed(underlying: Error)
    case proofGenerationFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .unsupportedInProduction:
            "This device cannot verify this alert subscription. Try a supported physical device."
        case .serverRejectedCredential:
            "The saved app integrity credential was rejected and has been reset. Please try again."
        case .invalidKeyIdentifier, .invalidChallenge:
            "The app integrity check returned invalid data. Please try again."
        case .keyGenerationFailed:
            "The app integrity key could not be created. Please try again."
        case .keyStorageFailed:
            "The app integrity key could not be saved securely. Please try again."
        case .challengeRequestFailed:
            "The app integrity challenge could not be retrieved. Check your connection and try again."
        case .proofGenerationFailed:
            "The app integrity check could not be completed. Please try again."
        }
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded value: String) {
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({ scalar in
                  (0x41...0x5A).contains(scalar.value) ||
                      (0x61...0x7A).contains(scalar.value) ||
                      (0x30...0x39).contains(scalar.value) ||
                      scalar == "-" || scalar == "_"
              }) else {
            return nil
        }

        let standard = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = String(repeating: "=", count: (4 - standard.count % 4) % 4)
        self.init(base64Encoded: standard + padding)
    }
}
