import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";

// This is a local-only integration check for the App Attest assertion path.
// It seeds independently verified public keys in a temporary local D1 state,
// then makes a correctly signed assertion. It does not emulate or replace the
// Apple attestation ceremony; physical-device verification remains a release
// gate. Usage after migrations and `wrangler dev --local` are running:
//
// node scripts/local-attested-key-bound-deletion-test.mjs http://127.0.0.1:8787
const suppliedBaseURL =
  process.argv[2] ?? process.env.QUAKESIGNAL_LOCAL_API_URL;

if (!suppliedBaseURL) {
  console.error(
    "Usage: node scripts/local-attested-key-bound-deletion-test.mjs http://127.0.0.1:8787",
  );
  process.exit(2);
}

const baseURL = new URL(suppliedBaseURL);
if (!new Set(["127.0.0.1", "localhost", "::1"]).has(baseURL.hostname)) {
  throw new Error("This assertion fixture may run only against a local Wrangler URL.");
}
const localD1URL = new URL(
  "/cdn-cgi/local/explorer/api/d1/database/834fba5c-0d99-4398-9565-18c6858eb2a8/raw",
  baseURL,
);
const encoder = new TextEncoder();
const appID = "5TT564H883.com.quakesignal.app";

function base64URL(bytes) {
  return Buffer.from(bytes)
    .toString("base64")
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");
}

function base64URLBytes(value) {
  return new Uint8Array(
    Buffer.from(value.replaceAll("-", "+").replaceAll("_", "/"), "base64"),
  );
}

function sqlLiteral(value) {
  return `'${String(value).replaceAll("'", "''")}'`;
}

async function runLocalD1(command) {
  const response = await fetch(localD1URL, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ sql: command }),
  });
  const result = await response.json();
  if (!response.ok || result?.success !== true || !Array.isArray(result.result)) {
    throw new Error("Local Explorer rejected the D1 fixture command.");
  }
  return result.result;
}

async function queryRows(command) {
  const result = await runLocalD1(command);
  const first = result.at(0);
  assert.equal(first?.success, true, "local D1 query must succeed");
  assert.ok(Array.isArray(first.results?.columns), "local D1 query must return columns");
  assert.ok(Array.isArray(first.results?.rows), "local D1 query must return rows");
  return first.results.rows.map((row) =>
    Object.fromEntries(first.results.columns.map((name, index) => [name, row[index]])),
  );
}

async function sha256(value) {
  return new Uint8Array(await webcrypto.subtle.digest("SHA-256", value));
}

function publicKeyPEM(spki) {
  const base64 = Buffer.from(spki).toString("base64");
  return `-----BEGIN PUBLIC KEY-----\n${base64.match(/.{1,64}/g).join("\n")}\n-----END PUBLIC KEY-----\n`;
}

function rawSignatureToDER(raw) {
  assert.equal(raw.length, 64, "P-256 signatures must contain r and s");
  const encodeInteger = (component) => {
    let start = 0;
    while (start < component.length - 1 && component[start] === 0) start += 1;
    const value = component.slice(start);
    const needsPadding = (value[0] & 0x80) !== 0;
    const result = new Uint8Array(2 + value.length + (needsPadding ? 1 : 0));
    result[0] = 0x02;
    result[1] = value.length + (needsPadding ? 1 : 0);
    if (needsPadding) result[2] = 0;
    result.set(value, needsPadding ? 3 : 2);
    return result;
  };
  const r = encodeInteger(raw.slice(0, 32));
  const s = encodeInteger(raw.slice(32));
  const result = new Uint8Array(2 + r.length + s.length);
  result[0] = 0x30;
  result[1] = r.length + s.length;
  result.set(r, 2);
  result.set(s, 2 + r.length);
  return result;
}

function cborAssertion(authenticatorData, signature) {
  // Canonical two-member CBOR map: { authenticatorData: bytes, signature: bytes }.
  // Both byte strings are below 256 bytes in this fixture.
  const authDataKey = encoder.encode("authenticatorData");
  const signatureKey = encoder.encode("signature");
  const result = new Uint8Array(
    1 +
      1 + authDataKey.length + 2 + authenticatorData.length +
      1 + signatureKey.length + 2 + signature.length,
  );
  let offset = 0;
  result[offset] = 0xa2;
  offset += 1;
  result[offset] = 0x60 | authDataKey.length;
  offset += 1;
  result.set(authDataKey, offset);
  offset += authDataKey.length;
  result[offset] = 0x58;
  result[offset + 1] = authenticatorData.length;
  offset += 2;
  result.set(authenticatorData, offset);
  offset += authenticatorData.length;
  result[offset] = 0x60 | signatureKey.length;
  offset += 1;
  result.set(signatureKey, offset);
  offset += signatureKey.length;
  result[offset] = 0x58;
  result[offset + 1] = signature.length;
  offset += 2;
  result.set(signature, offset);
  return result;
}

async function createTestKey() {
  const keyPair = await webcrypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  );
  const keyIDBytes = webcrypto.getRandomValues(new Uint8Array(32));
  const wireKeyID = base64URL(keyIDBytes);
  return {
    keyPair,
    keyID: Buffer.from(keyIDBytes).toString("base64"),
    wireKeyID,
    publicKeyPEM: publicKeyPEM(await webcrypto.subtle.exportKey("spki", keyPair.publicKey)),
  };
}

async function seedVerifiedKey(key, token) {
  const now = new Date().toISOString();
  const keyValues = [
    sqlLiteral(key.keyID),
    sqlLiteral(key.publicKeyPEM),
    "0",
    sqlLiteral(appID),
    "'production'",
    "'local-test-receipt'",
    sqlLiteral(now),
  ].join(", ");
  const deviceStatement = token
    ? `INSERT INTO devices (
        token, environment, sources, min_magnitude, critical_alerts_enabled,
        include_test_alerts, notify_at_night, app_attest_key_id, created_at, updated_at
      ) VALUES (
        ${sqlLiteral(token)}, 'production', '["jma_eew"]', 0, 0, 0, 1,
        ${sqlLiteral(key.keyID)}, ${sqlLiteral(now)}, ${sqlLiteral(now)}
      );`
    : "";
  await runLocalD1(`
    INSERT INTO app_attest_keys (
      key_id, public_key_pem, sign_count, app_id, environment, receipt_base64, attested_at_utc
    ) VALUES (${keyValues});
    ${deviceStatement}
  `);
}

async function signedDeletionAssertion(key, signCount, deletionBody = "{}") {
  const bodySHA256 = base64URL(await sha256(encoder.encode(deletionBody)));
  const challengeResponse = await fetch(
    new URL("/v1/app-attest/challenge", baseURL),
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        version: "1",
        keyId: key.wireKeyID,
        operation: "device-deletion",
        method: "DELETE",
        path: "/v1/devices",
        bodySHA256,
      }),
    },
  );
  assert.equal(challengeResponse.status, 201, "challenge request must succeed");
  const challenge = await challengeResponse.json();
  assert.equal(challenge.proofType, "assertion", "seeded key must use an assertion");

  const fields = [
    ["version", encoder.encode("1")],
    ["key_id", encoder.encode(key.wireKeyID)],
    ["challenge_id", encoder.encode(challenge.challengeId)],
    ["challenge", base64URLBytes(challenge.challenge)],
    ["operation", encoder.encode("device-deletion")],
    ["method", encoder.encode("DELETE")],
    ["path", encoder.encode("/v1/devices")],
    ["body_sha256", base64URLBytes(bodySHA256)],
  ];
  const clientData = encoder.encode(
    `${fields.map(([name, value]) => `${name}=${base64URL(value)}`).join("\n")}\n`,
  );
  const authenticatorData = new Uint8Array(37);
  authenticatorData.set(await sha256(encoder.encode(appID)), 0);
  authenticatorData[32] = 0x01;
  new DataView(
    authenticatorData.buffer,
    authenticatorData.byteOffset + 33,
    4,
  ).setUint32(0, signCount, false);
  const nonceInput = new Uint8Array(authenticatorData.length + 32);
  nonceInput.set(authenticatorData, 0);
  nonceInput.set(await sha256(clientData), authenticatorData.length);
  const signature = new Uint8Array(
    await webcrypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      key.keyPair.privateKey,
      await sha256(nonceInput),
    ),
  );
  const proof = base64URL(
    cborAssertion(authenticatorData, rawSignatureToDER(signature)),
  );
  return { deletionBody, challenge, proof };
}

async function performAttestedKeyBoundDeletion(
  key,
  signCount,
  requestedDeletionBody = "{}",
) {
  const { deletionBody, challenge, proof } = await signedDeletionAssertion(
    key,
    signCount,
    requestedDeletionBody,
  );
  const response = await fetch(new URL("/v1/devices", baseURL), {
    method: "DELETE",
    headers: {
      "content-type": "application/json",
      "x-quakesignal-app-attest-version": "1",
      "x-quakesignal-app-attest-key-id": key.wireKeyID,
      "x-quakesignal-app-attest-challenge-id": challenge.challengeId,
      "x-quakesignal-app-attest-proof-type": "assertion",
      "x-quakesignal-app-attest-proof": proof,
    },
    body: deletionBody,
  });
  assert.equal(response.status, 204, "valid key-bound deletion must succeed");
  assert.equal(
    response.headers.get("cache-control"),
    "no-store",
    "key-bound deletion response must not be cached",
  );
}

const ownedKey = await createTestKey();
const foreignKey = await createTestKey();
const idempotentKey = await createTestKey();
const rotatedTokenKey = await createTestKey();
const nonce = base64URL(webcrypto.getRandomValues(new Uint8Array(12)));
const ownedToken = Buffer.from(webcrypto.getRandomValues(new Uint8Array(32))).toString("hex");
const foreignToken = Buffer.from(webcrypto.getRandomValues(new Uint8Array(32))).toString("hex");
const priorRotatedToken = Buffer.from(webcrypto.getRandomValues(new Uint8Array(32))).toString("hex");
const currentRotatedToken = Buffer.from(webcrypto.getRandomValues(new Uint8Array(32))).toString("hex");
const ownedDeliveryID = `owned-delivery-${nonce}`;
const foreignDeliveryID = `foreign-delivery-${nonce}`;
const rotatedDeliveryID = `rotated-delivery-${nonce}`;
const now = new Date().toISOString();
const [ownedTokenHash, foreignTokenHash, priorRotatedTokenHash] = await Promise.all([
  sha256(encoder.encode(ownedToken)).then((value) => Buffer.from(value).toString("hex")),
  sha256(encoder.encode(foreignToken)).then((value) => Buffer.from(value).toString("hex")),
  sha256(encoder.encode(priorRotatedToken)).then((value) => Buffer.from(value).toString("hex")),
]);

try {
  await seedVerifiedKey(ownedKey, ownedToken);
  await seedVerifiedKey(foreignKey, foreignToken);
  await seedVerifiedKey(rotatedTokenKey, priorRotatedToken);
  // A verified orphan key represents the idempotent no-subscription state
  // before routine cleanup has run.
  await seedVerifiedKey(idempotentKey, null);
  await runLocalD1(`
    INSERT INTO notification_deliveries (delivery_id, device_token, delivered_at_utc)
    VALUES (${sqlLiteral(ownedDeliveryID)}, ${sqlLiteral(ownedToken)}, ${sqlLiteral(now)});
    INSERT INTO notification_deliveries (delivery_id, device_token, delivered_at_utc)
    VALUES (${sqlLiteral(foreignDeliveryID)}, ${sqlLiteral(foreignToken)}, ${sqlLiteral(now)});
    INSERT INTO notification_deliveries (delivery_id, device_token, delivered_at_utc)
    VALUES (${sqlLiteral(rotatedDeliveryID)}, ${sqlLiteral(priorRotatedToken)}, ${sqlLiteral(now)});
    INSERT INTO alert_delivery_failures (
      delivery_id, token_hash, event_ref, source_id, notification_reason,
      disposition, first_seen_utc, last_seen_utc
    ) VALUES (
      ${sqlLiteral(ownedDeliveryID)}, ${sqlLiteral(ownedTokenHash)}, 'local-test', 'jma_eew',
      'new', 'quarantine', ${sqlLiteral(now)}, ${sqlLiteral(now)}
    );
    INSERT INTO alert_delivery_failures (
      delivery_id, token_hash, event_ref, source_id, notification_reason,
      disposition, first_seen_utc, last_seen_utc
    ) VALUES (
      ${sqlLiteral(foreignDeliveryID)}, ${sqlLiteral(foreignTokenHash)}, 'local-test', 'jma_eew',
      'new', 'quarantine', ${sqlLiteral(now)}, ${sqlLiteral(now)}
    );
    INSERT INTO alert_delivery_failures (
      delivery_id, token_hash, event_ref, source_id, notification_reason,
      disposition, first_seen_utc, last_seen_utc
    ) VALUES (
      ${sqlLiteral(rotatedDeliveryID)}, ${sqlLiteral(priorRotatedTokenHash)}, 'local-test', 'jma_eew',
      'new', 'quarantine', ${sqlLiteral(now)}, ${sqlLiteral(now)}
    );
  `);

  await performAttestedKeyBoundDeletion(idempotentKey, 1);
  const idempotenceRows = await queryRows(
    `SELECT COUNT(*) AS remaining_idempotent_key FROM app_attest_keys WHERE key_id = ${sqlLiteral(idempotentKey.keyID)};`,
  );
  assert.deepEqual(
    idempotenceRows,
    [{ remaining_idempotent_key: 0 }],
    "a valid key with no current subscription must still receive the idempotent success state",
  );

  // APNs can rotate the token before Root has synchronized it to the Worker.
  // Removing with the new in-memory token must still remove the existing
  // subscription for this App Attest key rather than leaving the old token
  // registered after the client disables itself.
  await performAttestedKeyBoundDeletion(
    rotatedTokenKey,
    1,
    JSON.stringify({ token: currentRotatedToken }),
  );
  const rotationRows = await queryRows(`
    SELECT
      (SELECT COUNT(*) FROM devices WHERE token = ${sqlLiteral(priorRotatedToken)}) AS prior_devices,
      (SELECT COUNT(*) FROM notification_deliveries WHERE device_token = ${sqlLiteral(priorRotatedToken)}) AS prior_deliveries,
      (SELECT COUNT(*) FROM alert_delivery_failures WHERE token_hash = ${sqlLiteral(priorRotatedTokenHash)}) AS prior_failures,
      (SELECT COUNT(*) FROM app_attest_keys WHERE key_id = ${sqlLiteral(rotatedTokenKey.keyID)}) AS rotated_keys;
  `);
  assert.deepEqual(rotationRows, [{
    prior_devices: 0,
    prior_deliveries: 0,
    prior_failures: 0,
    rotated_keys: 0,
  }], "token-specific deletion must also remove the prior subscription owned by that key");

  await performAttestedKeyBoundDeletion(ownedKey, 1);
  const deletionRows = await queryRows(`
    SELECT
      (SELECT COUNT(*) FROM devices WHERE token = ${sqlLiteral(ownedToken)}) AS owned_devices,
      (SELECT COUNT(*) FROM notification_deliveries WHERE device_token = ${sqlLiteral(ownedToken)}) AS owned_deliveries,
      (SELECT COUNT(*) FROM alert_delivery_failures WHERE token_hash = ${sqlLiteral(ownedTokenHash)}) AS owned_failures,
      (SELECT COUNT(*) FROM app_attest_keys WHERE key_id = ${sqlLiteral(ownedKey.keyID)}) AS owned_keys,
      (SELECT COUNT(*) FROM devices WHERE token = ${sqlLiteral(foreignToken)}) AS foreign_devices,
      (SELECT COUNT(*) FROM notification_deliveries WHERE device_token = ${sqlLiteral(foreignToken)}) AS foreign_deliveries,
      (SELECT COUNT(*) FROM alert_delivery_failures WHERE token_hash = ${sqlLiteral(foreignTokenHash)}) AS foreign_failures,
      (SELECT COUNT(*) FROM app_attest_keys WHERE key_id = ${sqlLiteral(foreignKey.keyID)}) AS foreign_keys;
  `);
  assert.deepEqual(deletionRows, [{
    owned_devices: 0,
    owned_deliveries: 0,
    owned_failures: 0,
    owned_keys: 0,
    foreign_devices: 1,
    foreign_deliveries: 1,
    foreign_failures: 1,
    foreign_keys: 1,
  }], "key-bound deletion must remove only the owning key's records");

  console.log(
    JSON.stringify(
      {
        ok: true,
        baseURL: baseURL.toString(),
        assertions: [
          "valid-attested-empty-delete",
          "own-delivery-failure-cleanup",
          "cross-key-preservation",
          "idempotent-no-current-subscription",
          "token-rotation-removes-prior-key-owned-subscription",
        ],
      },
      null,
      2,
    ),
  );
} finally {
  // This script explicitly targets a disposable local state directory. Remove
  // only the exact random fixture records so repeated local runs stay clean.
  await runLocalD1(`
    DELETE FROM alert_delivery_failures
    WHERE delivery_id IN (${sqlLiteral(ownedDeliveryID)}, ${sqlLiteral(foreignDeliveryID)}, ${sqlLiteral(rotatedDeliveryID)});
    DELETE FROM notification_deliveries
    WHERE delivery_id IN (${sqlLiteral(ownedDeliveryID)}, ${sqlLiteral(foreignDeliveryID)}, ${sqlLiteral(rotatedDeliveryID)});
    DELETE FROM devices WHERE token IN (${sqlLiteral(ownedToken)}, ${sqlLiteral(foreignToken)}, ${sqlLiteral(priorRotatedToken)});
    DELETE FROM app_attest_challenges
    WHERE key_id IN (${sqlLiteral(ownedKey.keyID)}, ${sqlLiteral(foreignKey.keyID)}, ${sqlLiteral(idempotentKey.keyID)}, ${sqlLiteral(rotatedTokenKey.keyID)});
    DELETE FROM app_attest_keys
    WHERE key_id IN (${sqlLiteral(ownedKey.keyID)}, ${sqlLiteral(foreignKey.keyID)}, ${sqlLiteral(idempotentKey.keyID)}, ${sqlLiteral(rotatedTokenKey.keyID)});
  `);
}
