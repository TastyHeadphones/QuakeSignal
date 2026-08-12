import {
  verifyAttestation,
} from "@bradford-tech/supabase-integrity-attest/attestation";
import { verifyAssertion } from "@bradford-tech/supabase-integrity-attest/assertion";

/**
 * App Attest protocol helpers shared by the Worker route layer.
 *
 * The certificate-chain, nonce, AAGUID, RP-ID hash, credential-ID, counter,
 * and ES256 verification lives in the pinned integrity-attest package. This
 * module deliberately owns QuakeSignal's request binding, one-time challenge
 * contract, bounded wire decoding, and Apple release metadata validation.
 */

const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });

export const APP_ATTEST_PROTOCOL_VERSION = "1";
export const APP_ATTEST_KEY_ID_HEADER = "x-quakesignal-app-attest-key-id";
export const APP_ATTEST_CHALLENGE_ID_HEADER =
  "x-quakesignal-app-attest-challenge-id";
export const APP_ATTEST_PROOF_TYPE_HEADER =
  "x-quakesignal-app-attest-proof-type";
export const APP_ATTEST_PROOF_HEADER = "x-quakesignal-app-attest-proof";
export const APP_ATTEST_VERSION_HEADER = "x-quakesignal-app-attest-version";
export const APP_ATTEST_DEVELOPMENT_BYPASS_HEADER =
  "x-quakesignal-app-attest-bypass";

export const APP_ATTEST_CHALLENGE_TTL_MS = 5 * 60_000;
// Apple's published production attestation sample is about 5.9 KiB raw. Keep
// room for certificate-chain variation without allowing an unbounded header.
export const MAX_APP_ATTEST_PROOF_BYTES = 16 * 1024;
export const MAX_APP_ATTEST_PROOF_ENCODED_LENGTH = 24 * 1024;

const MAX_APP_ATTEST_KEY_ID_LENGTH = 512;
const MAX_CBOR_DEPTH = 12;
const MAX_CBOR_COLLECTION_ITEMS = 64;
const APPLE_BUNDLE_VERSION_KEY = "apple_bundle_version_01";
const APPLE_VALIDATION_CATEGORY_KEY = "apple_validation_category_01";

export type AppAttestOperation =
  | "device-registration"
  | "device-deletion"
  | "test-push";

export type AppAttestProofType = "attestation" | "assertion";

/**
 * Apple uses separate App Attest AAGUIDs for development and release builds.
 * This is a verifier-side environment, deliberately distinct from the APNs
 * sandbox/production destination a device registration may select.
 */
export type AppAttestEnvironment = "development" | "production";

export interface CanonicalAppAttestKeyId {
  /** Stable, padded standard Base64 representation used as a D1 key. */
  keyId: string;
  /** Exact, header-safe representation signed by the client. */
  wireKeyId: string;
}

export interface AppAttestChallengeBinding {
  id: string;
  keyId: string;
  wireKeyId: string;
  challenge: string;
  operation: AppAttestOperation;
  method: string;
  path: string;
  bodySha256: string;
  requiredProof: AppAttestProofType;
  /** Stored server-side only; it is not a client-controlled challenge field. */
  environment?: AppAttestEnvironment;
}

export interface StoredAppAttestKey {
  keyId: string;
  publicKeyPem: string;
  signCount: number;
}

export interface AppAttestReleaseMetadata {
  validationCategory: number;
  bundleVersion: string;
}

export interface VerifiedAppAttestProof {
  proofType: AppAttestProofType;
  signCount: number;
  /** Present only when a newly attested key must be persisted. */
  publicKeyPem?: string;
  /** Receipt is retained only for future Apple receipt-risk refresh. */
  receiptBase64?: string;
  metadata: AppAttestReleaseMetadata | null;
}

export interface VerifyAppAttestProofInput {
  appId: string;
  /** Selects the Apple AAGUID and release-distribution metadata policy. */
  environment: AppAttestEnvironment;
  challenge: AppAttestChallengeBinding;
  headerKeyId: string;
  headerChallengeId: string;
  headerProofType: string | null;
  headerVersion: string | null;
  proof: string | null;
  existingKey?: StoredAppAttestKey | null;
  allowedBundleVersions: ReadonlySet<string>;
  requireReleaseMetadata: boolean;
}

export class AppAttestValidationError extends Error {
  constructor(
    public readonly code:
      | "invalid_request"
      | "invalid_proof"
      | "wrong_proof_type"
      | "unknown_key"
      | "invalid_release_metadata",
  ) {
    super(code);
  }
}

interface CborHead {
  majorType: number;
  additional: number;
  value: number;
  end: number;
}

interface ParsedAssertionCbor {
  authenticatorData: Uint8Array;
  signature: Uint8Array;
}

function binaryString(bytes: Uint8Array): string {
  let result = "";
  for (const byte of bytes) result += String.fromCharCode(byte);
  return result;
}

function base64Url(bytes: Uint8Array): string {
  return btoa(binaryString(bytes))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");
}

function standardBase64(bytes: Uint8Array): string {
  return btoa(binaryString(bytes));
}

/**
 * Decode a canonical Base64/Base64URL value without accepting whitespace,
 * invalid padding, or a non-canonical low-bit representation.
 */
function decodeBase64Value(value: string): Uint8Array | null {
  if (value.length === 0 || value.length > MAX_APP_ATTEST_PROOF_ENCODED_LENGTH) {
    return null;
  }
  if (!/^[A-Za-z0-9+/_-]*={0,2}$/.test(value)) return null;
  const firstPadding = value.indexOf("=");
  if (firstPadding !== -1 && firstPadding < value.length - (value.endsWith("==") ? 2 : 1)) {
    return null;
  }
  const unpadded = value.replace(/=+$/, "");
  if (unpadded.length % 4 === 1) return null;
  const standard = unpadded.replaceAll("-", "+").replaceAll("_", "/");
  const padded = standard + "=".repeat((4 - (standard.length % 4)) % 4);
  try {
    const bytes = Uint8Array.from(atob(padded), (character) =>
      character.charCodeAt(0),
    );
    // Reject variants such as a non-zero unused Base64 bit or misleading
    // padding. Standard and URL-safe alphabets both normalize here.
    const suppliedCanonical = unpadded
      .replaceAll("+", "-")
      .replaceAll("/", "_");
    if (suppliedCanonical !== base64Url(bytes)) return null;
    return bytes;
  } catch {
    return null;
  }
}

function equalBytes(left: Uint8Array, right: Uint8Array): boolean {
  let difference = left.length ^ right.length;
  for (let index = 0; index < left.length && index < right.length; index += 1) {
    difference |= left[index] ^ right[index];
  }
  return difference === 0;
}

async function sha256(value: Uint8Array): Promise<Uint8Array> {
  // Copy into an ArrayBuffer-backed view for the current Workers type
  // definitions, which distinguish ArrayBuffer from SharedArrayBuffer.
  const copied = new Uint8Array(value);
  return new Uint8Array(await crypto.subtle.digest("SHA-256", copied));
}

export async function appAttestBodySha256(body: Uint8Array): Promise<string> {
  return base64Url(await sha256(body));
}

export function canonicalizeAppAttestKeyId(
  value: unknown,
): CanonicalAppAttestKeyId | null {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    value.length > MAX_APP_ATTEST_KEY_ID_LENGTH ||
    value.trim() !== value
  ) {
    return null;
  }
  const decoded = decodeBase64Value(value);
  if (!decoded || decoded.length !== 32) return null;
  return { keyId: standardBase64(decoded), wireKeyId: value };
}

export function isCanonicalSha256Base64Url(value: unknown): value is string {
  if (typeof value !== "string" || value.length !== 43) return false;
  const decoded = decodeBase64Value(value);
  return decoded?.length === 32 && base64Url(decoded) === value;
}

export function decodeAppAttestProof(value: string | null): Uint8Array | null {
  if (!value || value.length > MAX_APP_ATTEST_PROOF_ENCODED_LENGTH) return null;
  const decoded = decodeBase64Value(value);
  if (!decoded || decoded.length === 0 || decoded.length > MAX_APP_ATTEST_PROOF_BYTES) {
    return null;
  }
  // AppAttestClient emits unpadded Base64URL. Requiring that form avoids
  // equivalent header aliases for this high-value proof.
  return base64Url(decoded) === value ? decoded : null;
}

function ensureCborOffset(data: Uint8Array, offset: number): void {
  if (offset < 0 || offset >= data.length) {
    throw new AppAttestValidationError("invalid_proof");
  }
}

function readCborHead(data: Uint8Array, offset: number): CborHead {
  ensureCborOffset(data, offset);
  const initial = data[offset];
  const majorType = initial >> 5;
  const additional = initial & 0x1f;
  if (additional < 24) {
    return { majorType, additional, value: additional, end: offset + 1 };
  }
  const width = additional === 24 ? 1 : additional === 25 ? 2 : additional === 26 ? 4 : additional === 27 ? 8 : 0;
  if (width === 0 || offset + 1 + width > data.length) {
    throw new AppAttestValidationError("invalid_proof");
  }
  let value = 0n;
  for (let index = 0; index < width; index += 1) {
    value = (value << 8n) | BigInt(data[offset + 1 + index]);
  }
  if (value > BigInt(Number.MAX_SAFE_INTEGER)) {
    throw new AppAttestValidationError("invalid_proof");
  }
  const numericValue = Number(value);
  // Apple emits canonical CBOR. Reject length encodings that could have used
  // a shorter form, so a proof has one structural representation.
  if (
    (additional === 24 && numericValue < 24) ||
    (additional === 25 && numericValue <= 0xff) ||
    (additional === 26 && numericValue <= 0xffff) ||
    (additional === 27 && numericValue <= 0xffffffff)
  ) {
    throw new AppAttestValidationError("invalid_proof");
  }
  return { majorType, additional, value: numericValue, end: offset + 1 + width };
}

function checkedEnd(data: Uint8Array, start: number, length: number): number {
  const end = start + length;
  if (!Number.isSafeInteger(end) || end > data.length) {
    throw new AppAttestValidationError("invalid_proof");
  }
  return end;
}

function readCborBytes(data: Uint8Array, offset: number): { value: Uint8Array; end: number } {
  const head = readCborHead(data, offset);
  if (head.majorType !== 2) throw new AppAttestValidationError("invalid_proof");
  const end = checkedEnd(data, head.end, head.value);
  return { value: data.slice(head.end, end), end };
}

function readCborText(data: Uint8Array, offset: number): { value: string; end: number } {
  const head = readCborHead(data, offset);
  if (head.majorType !== 3) throw new AppAttestValidationError("invalid_proof");
  const end = checkedEnd(data, head.end, head.value);
  try {
    return { value: decoder.decode(data.slice(head.end, end)), end };
  } catch {
    throw new AppAttestValidationError("invalid_proof");
  }
}

function skipCborItem(data: Uint8Array, offset: number, depth = 0): number {
  if (depth > MAX_CBOR_DEPTH) throw new AppAttestValidationError("invalid_proof");
  const head = readCborHead(data, offset);
  switch (head.majorType) {
    case 0:
    case 1:
      return head.end;
    case 2:
    case 3:
      return checkedEnd(data, head.end, head.value);
    case 4: {
      if (head.value > MAX_CBOR_COLLECTION_ITEMS) {
        throw new AppAttestValidationError("invalid_proof");
      }
      let position = head.end;
      for (let index = 0; index < head.value; index += 1) {
        position = skipCborItem(data, position, depth + 1);
      }
      return position;
    }
    case 5: {
      if (head.value > MAX_CBOR_COLLECTION_ITEMS) {
        throw new AppAttestValidationError("invalid_proof");
      }
      let position = head.end;
      for (let index = 0; index < head.value; index += 1) {
        position = skipCborItem(data, position, depth + 1);
        position = skipCborItem(data, position, depth + 1);
      }
      return position;
    }
    case 6:
      return skipCborItem(data, head.end, depth + 1);
    case 7:
      return head.end;
    default:
      throw new AppAttestValidationError("invalid_proof");
  }
}

function canonicalCborTextKey(value: string): Uint8Array {
  const bytes = encoder.encode(value);
  if (bytes.length >= 24) throw new AppAttestValidationError("invalid_proof");
  const result = new Uint8Array(1 + bytes.length);
  result[0] = 0x60 | bytes.length;
  result.set(bytes, 1);
  return result;
}

function startsWithBytes(
  data: Uint8Array,
  offset: number,
  prefix: Uint8Array,
): boolean {
  if (offset + prefix.length > data.length) return false;
  for (let index = 0; index < prefix.length; index += 1) {
    if (data[offset + index] !== prefix[index]) return false;
  }
  return true;
}

/**
 * Apple occasionally overstates the App Attest receipt CBOR length. The
 * pinned verifier intentionally repairs that one documented wire defect. We
 * mirror only the structural walk needed to reach the actual `authData`, and
 * still let the verifier validate every certificate/nonce invariant.
 */
function skipAppleReceipt(
  data: Uint8Array,
  offset: number,
  nextKeys: string[],
): number {
  const head = readCborHead(data, offset);
  if (head.majorType !== 2) throw new AppAttestValidationError("invalid_proof");
  const declaredEnd = head.end + head.value;
  const needles = nextKeys.map(canonicalCborTextKey);
  const validContinuation = (end: number): boolean => {
    if (end > data.length) return false;
    if (needles.length === 0) return end === data.length;
    return needles.some((needle) => startsWithBytes(data, end, needle));
  };
  if (validContinuation(declaredEnd)) return declaredEnd;
  if (needles.length === 0) return data.length;
  for (let end = Math.min(declaredEnd, data.length); end >= head.end; end -= 1) {
    if (needles.some((needle) => startsWithBytes(data, end, needle))) {
      return end;
    }
  }
  throw new AppAttestValidationError("invalid_proof");
}

function skipAppleAttestationStatement(
  data: Uint8Array,
  offset: number,
  keysAfterStatement: string[],
): number {
  const head = readCborHead(data, offset);
  if (head.majorType !== 5 || head.value !== 2) {
    throw new AppAttestValidationError("invalid_proof");
  }
  let position = head.end;
  let sawCertificates = false;
  let sawReceipt = false;
  for (let index = 0; index < 2; index += 1) {
    const key = readCborText(data, position);
    position = key.end;
    if (key.value === "x5c") {
      if (sawCertificates) throw new AppAttestValidationError("invalid_proof");
      sawCertificates = true;
      position = skipCborItem(data, position);
      continue;
    }
    if (key.value === "receipt") {
      if (sawReceipt) throw new AppAttestValidationError("invalid_proof");
      sawReceipt = true;
      // If x5c is still a sibling, it necessarily follows this byte string;
      // otherwise the next top-level attestation key must follow it.
      position = skipAppleReceipt(
        data,
        position,
        index === 0 ? ["x5c"] : keysAfterStatement,
      );
      continue;
    }
    throw new AppAttestValidationError("invalid_proof");
  }
  if (!sawCertificates || !sawReceipt) {
    throw new AppAttestValidationError("invalid_proof");
  }
  return position;
}

function attestationAuthenticatorData(data: Uint8Array): Uint8Array {
  const head = readCborHead(data, 0);
  if (head.majorType !== 5 || head.value !== 3) {
    throw new AppAttestValidationError("invalid_proof");
  }
  let position = head.end;
  let format: string | null = null;
  let authData: Uint8Array | null = null;
  const seen = new Set<string>();
  for (let index = 0; index < 3; index += 1) {
    const key = readCborText(data, position);
    position = key.end;
    if (seen.has(key.value)) throw new AppAttestValidationError("invalid_proof");
    seen.add(key.value);
    if (key.value === "fmt") {
      const value = readCborText(data, position);
      format = value.value;
      position = value.end;
      continue;
    }
    if (key.value === "authData") {
      const value = readCborBytes(data, position);
      authData = value.value;
      position = value.end;
      continue;
    }
    if (key.value === "attStmt") {
      const remaining = ["fmt", "authData"].filter(
        (name) => !seen.has(name),
      );
      position = skipAppleAttestationStatement(data, position, remaining);
      continue;
    }
    throw new AppAttestValidationError("invalid_proof");
  }
  if (
    position !== data.length ||
    format !== "apple-appattest" ||
    authData === null
  ) {
    throw new AppAttestValidationError("invalid_proof");
  }
  return authData;
}

/**
 * Apple currently appends release metadata after the COSE key even when the
 * WebAuthn ED flag is not set. We therefore examine the bounded trailing item
 * directly instead of relying on that flag. Older iOS releases can omit it.
 */
function parseAppleReleaseMetadata(
  data: Uint8Array,
  offset: number,
): AppAttestReleaseMetadata | null {
  if (offset === data.length) return null;
  const head = readCborHead(data, offset);
  if (head.majorType !== 5 || head.value !== 2) {
    throw new AppAttestValidationError("invalid_release_metadata");
  }
  let position = head.end;
  let bundleVersion: string | null = null;
  let validationCategory: number | null = null;
  const seen = new Set<string>();
  for (let index = 0; index < head.value; index += 1) {
    const key = readCborText(data, position);
    position = key.end;
    if (seen.has(key.value)) {
      throw new AppAttestValidationError("invalid_release_metadata");
    }
    seen.add(key.value);
    if (key.value === APPLE_BUNDLE_VERSION_KEY) {
      const value = readCborText(data, position);
      position = value.end;
      if (value.value.length === 0 || value.value.length > 120) {
        throw new AppAttestValidationError("invalid_release_metadata");
      }
      bundleVersion = value.value;
      continue;
    }
    if (key.value === APPLE_VALIDATION_CATEGORY_KEY) {
      const valueHead = readCborHead(data, position);
      if (valueHead.majorType === 0) {
        validationCategory = valueHead.value;
        position = valueHead.end;
        continue;
      }
      if (valueHead.majorType === 2 && valueHead.value === 4) {
        const end = checkedEnd(data, valueHead.end, valueHead.value);
        validationCategory = new DataView(
          data.buffer,
          data.byteOffset + valueHead.end,
          4,
        ).getUint32(0, true);
        position = end;
        continue;
      }
      throw new AppAttestValidationError("invalid_release_metadata");
    }
    // Avoid accepting a future/unknown metadata attribute as though this were
    // the Apple release map we checked. A protocol change needs an explicit
    // review rather than a permissive fallback.
    throw new AppAttestValidationError("invalid_release_metadata");
  }
  if (
    position !== data.length ||
    bundleVersion === null ||
    validationCategory === null
  ) {
    throw new AppAttestValidationError("invalid_release_metadata");
  }
  return { validationCategory, bundleVersion };
}

function parseAttestationReleaseMetadata(authData: Uint8Array): AppAttestReleaseMetadata | null {
  if (authData.length < 55 || (authData[32] & 0x40) === 0) {
    throw new AppAttestValidationError("invalid_proof");
  }
  const credentialLength = new DataView(
    authData.buffer,
    authData.byteOffset + 53,
    2,
  ).getUint16(0, false);
  const coseOffset = checkedEnd(authData, 55, credentialLength);
  if (coseOffset === authData.length) {
    throw new AppAttestValidationError("invalid_proof");
  }
  const extensionsOffset = skipCborItem(authData, coseOffset);
  return parseAppleReleaseMetadata(authData, extensionsOffset);
}

function decodeAssertionCbor(data: Uint8Array): ParsedAssertionCbor {
  const head = readCborHead(data, 0);
  if (head.majorType !== 5 || head.value !== 2) {
    throw new AppAttestValidationError("invalid_proof");
  }
  let position = head.end;
  let authenticatorData: Uint8Array | null = null;
  let signature: Uint8Array | null = null;
  const seen = new Set<string>();
  for (let index = 0; index < head.value; index += 1) {
    const key = readCborText(data, position);
    position = key.end;
    if (seen.has(key.value)) throw new AppAttestValidationError("invalid_proof");
    seen.add(key.value);
    if (key.value === "authenticatorData") {
      const value = readCborBytes(data, position);
      authenticatorData = value.value;
      position = value.end;
      continue;
    }
    if (key.value === "signature") {
      const value = readCborBytes(data, position);
      signature = value.value;
      position = value.end;
      continue;
    }
    throw new AppAttestValidationError("invalid_proof");
  }
  if (!authenticatorData || !signature || position !== data.length) {
    throw new AppAttestValidationError("invalid_proof");
  }
  return { authenticatorData, signature };
}

function parseAssertionReleaseMetadata(authData: Uint8Array): AppAttestReleaseMetadata | null {
  if (authData.length < 37) throw new AppAttestValidationError("invalid_proof");
  return parseAppleReleaseMetadata(authData, 37);
}

export function appAttestAllowedValidationCategories(
  environment: AppAttestEnvironment,
): ReadonlySet<number> {
  // Apple category 3 is development only. It must never become acceptable on
  // a release verifier merely because a deployment variable is present.
  return environment === "development" ? new Set([3]) : new Set([2, 4]);
}

function validateReleaseMetadata(
  metadata: AppAttestReleaseMetadata | null,
  allowedBundleVersions: ReadonlySet<string>,
  requireReleaseMetadata: boolean,
  environment: AppAttestEnvironment,
): void {
  // iOS 17–26 App Attest proofs legitimately omit these iOS 27-era fields.
  // When present, however, they are a strict release identity assertion.
  if (!metadata) {
    if (requireReleaseMetadata) {
      throw new AppAttestValidationError("invalid_release_metadata");
    }
    return;
  }
  // 2 = TestFlight and 4 = App Store. Category 3 is admitted only by a
  // verifier that is explicitly configured for the isolated development
  // environment. Unknown/Enterprise categories always fail closed.
  if (
    !appAttestAllowedValidationCategories(environment).has(
      metadata.validationCategory,
    ) ||
    !allowedBundleVersions.has(metadata.bundleVersion)
  ) {
    throw new AppAttestValidationError("invalid_release_metadata");
  }
}

function clientData(binding: AppAttestChallengeBinding): Uint8Array {
  const challenge = decodeBase64Value(binding.challenge);
  if (!challenge || challenge.length !== 32) {
    throw new AppAttestValidationError("invalid_request");
  }
  const fields: Array<[string, Uint8Array]> = [
    ["version", encoder.encode(APP_ATTEST_PROTOCOL_VERSION)],
    ["key_id", encoder.encode(binding.wireKeyId)],
    ["challenge_id", encoder.encode(binding.id)],
    ["challenge", challenge],
    ["operation", encoder.encode(binding.operation)],
    ["method", encoder.encode(binding.method)],
    ["path", encoder.encode(binding.path)],
    ["body_sha256", decodeBase64Value(binding.bodySha256) ?? new Uint8Array()],
  ];
  if (fields.at(-1)?.[1].length !== 32) {
    throw new AppAttestValidationError("invalid_request");
  }
  return encoder.encode(
    fields.map(([name, value]) => `${name}=${base64Url(value)}`).join("\n") + "\n",
  );
}

function normalizeVerificationError(error: unknown): AppAttestValidationError {
  if (error instanceof AppAttestValidationError) return error;
  return new AppAttestValidationError("invalid_proof");
}

export async function verifyAppAttestProof(
  input: VerifyAppAttestProofInput,
): Promise<VerifiedAppAttestProof> {
  try {
    const headerKey = canonicalizeAppAttestKeyId(input.headerKeyId);
    const proof = decodeAppAttestProof(input.proof);
    if (
      !headerKey ||
      !proof ||
      input.headerVersion !== APP_ATTEST_PROTOCOL_VERSION ||
      input.headerChallengeId !== input.challenge.id ||
      input.headerKeyId !== input.challenge.wireKeyId ||
      headerKey.keyId !== input.challenge.keyId ||
      input.headerProofType !== input.challenge.requiredProof
    ) {
      throw new AppAttestValidationError("invalid_request");
    }

    const signedClientData = clientData(input.challenge);
    if (input.challenge.requiredProof === "attestation") {
      if (input.existingKey) throw new AppAttestValidationError("wrong_proof_type");
      const metadata = parseAttestationReleaseMetadata(
        attestationAuthenticatorData(proof),
      );
      validateReleaseMetadata(
        metadata,
        input.allowedBundleVersions,
        input.requireReleaseMetadata,
        input.environment,
      );
      const result = await verifyAttestation(
        {
          appId: input.appId,
          developmentEnv: input.environment === "development",
        },
        input.challenge.keyId,
        await sha256(signedClientData),
        proof,
      );
      return {
        proofType: "attestation",
        signCount: result.signCount,
        publicKeyPem: result.publicKeyPem,
        receiptBase64: base64Url(result.receipt),
        metadata,
      };
    }

    if (!input.existingKey) throw new AppAttestValidationError("unknown_key");
    const decoded = decodeAssertionCbor(proof);
    const metadata = parseAssertionReleaseMetadata(decoded.authenticatorData);
    validateReleaseMetadata(
      metadata,
      input.allowedBundleVersions,
      input.requireReleaseMetadata,
      input.environment,
    );
    const result = await verifyAssertion(
      { appId: input.appId },
      proof,
      signedClientData,
      input.existingKey.publicKeyPem,
      input.existingKey.signCount,
    );
    return { proofType: "assertion", signCount: result.signCount, metadata };
  } catch (error) {
    throw normalizeVerificationError(error);
  }
}

/** Constant-time comparison retained for focused unit tests and consumers. */
export function appAttestEqualBytes(left: Uint8Array, right: Uint8Array): boolean {
  return equalBytes(left, right);
}
