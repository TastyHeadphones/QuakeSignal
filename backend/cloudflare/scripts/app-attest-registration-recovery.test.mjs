import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readdirSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";

import { build } from "esbuild";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const cloudflareDirectory = resolve(scriptDirectory, "..");
const wranglerEntrypoint = resolve(
  cloudflareDirectory,
  "node_modules/wrangler/bin/wrangler.js",
);

let workerModulePromise;

async function workerModule() {
  workerModulePromise ??= (async () => {
    const bundleDirectory = await mkdtemp(join(tmpdir(), "quakesignal-worker-test-"));
    const outfile = join(bundleDirectory, "index.mjs");
    await build({
      entryPoints: [resolve(cloudflareDirectory, "src/index.ts")],
      bundle: true,
      format: "esm",
      platform: "node",
      target: "es2022",
      outfile,
    });
    return import(pathToFileURL(outfile).href);
  })();
  return workerModulePromise;
}

function runWrangler(arguments_) {
  const result = spawnSync(
    process.execPath,
    [wranglerEntrypoint, ...arguments_],
    { cwd: cloudflareDirectory, encoding: "utf8" },
  );
  assert.equal(
    result.status,
    0,
    `wrangler ${arguments_.join(" ")} failed:\n${result.stderr}\n${result.stdout}`,
  );
}

function localD1File(stateDirectory) {
  const d1Directory = join(
    stateDirectory,
    "v3",
    "d1",
    "miniflare-D1DatabaseObject",
  );
  const databaseName = readdirSync(d1Directory).find((name) =>
    /^db.+\.sqlite$/.test(name),
  );
  assert.ok(databaseName, "local Wrangler migration should create a D1 SQLite file");
  return join(d1Directory, databaseName);
}

/**
 * Exercise the real registration transaction against a fresh local D1 file.
 * The small adapter deliberately preserves D1's prepare/batch shape and wraps
 * all statements in one SQLite transaction, including their change counts.
 */
function localD1Adapter(databaseFile) {
  const sqlite = new DatabaseSync(databaseFile);
  const database = {
    prepare(sql) {
      return {
        sql,
        bindings: [],
        bind(...bindings) {
          return {
            sql,
            bindings,
            async all() {
              return {
                results: sqlite.prepare(sql).all(...bindings),
              };
            },
            async first(column) {
              const row = sqlite.prepare(sql).get(...bindings);
              return typeof column === "string" ? row?.[column] : row;
            },
            async run() {
              const output = sqlite.prepare(sql).run(...bindings);
              return { meta: { changes: Number(output.changes) } };
            },
          };
        },
      };
    },
    async batch(statements) {
      sqlite.exec("BEGIN IMMEDIATE");
      try {
        const results = statements.map((statement, index) => {
          assert.equal(
            typeof statement.sql,
            "string",
            `registration-batch entry ${index} must be a prepared SQL statement`,
          );
          const output = sqlite.prepare(statement.sql).run(...statement.bindings);
          return { meta: { changes: Number(output.changes) } };
        });
        sqlite.exec("COMMIT");
        return results;
      } catch (error) {
        try {
          sqlite.exec("ROLLBACK");
        } catch {
          // The original statement error is more useful than a rollback error.
        }
        throw error;
      }
    },
  };
  return {
    database,
    prepare(sql) {
      return sqlite.prepare(sql);
    },
    all(sql, ...bindings) {
      return sqlite.prepare(sql).all(...bindings).map((row) => ({ ...row }));
    },
    run(sql, ...bindings) {
      return sqlite.prepare(sql).run(...bindings);
    },
    close() {
      sqlite.close();
    },
  };
}

function seedKey(sqlite, keyID, now) {
  sqlite
    .prepare(
      `INSERT INTO app_attest_keys (
        key_id, public_key_pem, sign_count, app_id, environment,
        receipt_base64, attested_at_utc
      ) VALUES (?, ?, 0, ?, 'production', ?, ?)`,
    )
    .run(keyID, `pem-${keyID}`, "5TT564H883.com.quakesignal.app", `receipt-${keyID}`, now);
}

function seedChallenge(sqlite, challenge, now, environment = "production") {
  sqlite
    .prepare(
      `INSERT INTO app_attest_challenges (
        id, key_id, wire_key_id, operation, method, path, body_sha256,
        challenge, required_proof, environment, created_at_utc, expires_at_utc
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    )
    .run(
      challenge.id,
      challenge.keyId,
      challenge.wireKeyId,
      challenge.operation,
      challenge.method,
      challenge.path,
      challenge.bodySha256,
      challenge.challenge,
      challenge.requiredProof,
      environment,
      now,
      "2099-01-01T00:00:00.000Z",
    );
}

function registrationValues(
  token,
  now,
  environment = "production",
  alertSound = "system",
) {
  return {
    token,
    environment,
    locale: null,
    sources: '["jma_eew"]',
    minMagnitude: 0,
    alertSound,
    cityName: null,
    latitude: null,
    longitude: null,
    radiusKm: null,
    includeTestAlerts: 0,
    utcOffsetMinutes: null,
    notifyAtNight: 1,
    now,
  };
}

function authorization(
  keyId,
  proofType,
  environment = "production",
  appRoute = {
    appIdentity: "5TT564H883.com.quakesignal.app",
    apnsTopic: "com.quakesignal.app",
    platform: "ios",
  },
) {
  const challenge = {
    id: `challenge-${keyId}`,
    keyId,
    wireKeyId: `wire-${keyId}`,
    challenge: `nonce-${keyId}`,
    operation: "device-registration",
    method: "POST",
    path: "/v1/devices",
    bodySha256: `body-${keyId}`,
    requiredProof: proofType,
    environment,
  };
  return {
    mode: "attested",
    keyId,
    environment,
    challenge,
    appRoute,
    verification: proofType === "attestation"
      ? {
          proofType,
          publicKeyPem: `pem-${keyId}`,
          receiptBase64: `receipt-${keyId}`,
          signCount: 0,
          metadata: null,
        }
      : {
          proofType,
          signCount: 1,
          metadata: null,
        },
  };
}

test("attested registration persists the authenticated identity route, not a client topic", async () => {
  const { completeAttestedRegistration } = await workerModule();
  const keyId = "watch-route-app-attest-key";
  const token = "watch-route-apns-token";
  const now = "2026-08-19T00:00:00.000Z";
  const appRoute = {
    appIdentity: "5TT564H883.com.quakesignal.app.watchkitapp",
    apnsTopic: "com.quakesignal.app.watchkitapp",
    platform: "watchos",
  };
  const registrationAuthorization = authorization(
    keyId,
    "attestation",
    "production",
    appRoute,
  );
  const stateDirectory = await mkdtemp(join(tmpdir(), "quakesignal-app-route-"));
  let adapter;

  try {
    const localArguments = ["--local", "--persist-to", stateDirectory];
    runWrangler(["d1", "migrations", "apply", "quakesignal-production", ...localArguments]);
    const databaseFile = localD1File(stateDirectory);
    const seed = new DatabaseSync(databaseFile);
    try {
      seedChallenge(seed, registrationAuthorization.challenge, now);
    } finally {
      seed.close();
    }
    adapter = localD1Adapter(databaseFile);
    assert.equal(
      await completeAttestedRegistration(
        adapter.database,
        registrationAuthorization,
        registrationValues(token, now),
      ),
      "completed",
    );
    assert.deepEqual(
      adapter.all(
        `SELECT app_attest_key_id, app_identity, apns_topic, app_platform
         FROM devices WHERE token = ?`,
        token,
      ),
      [{
        app_attest_key_id: keyId,
        app_identity: appRoute.appIdentity,
        apns_topic: appRoute.apnsTopic,
        app_platform: appRoute.platform,
      }],
    );
    assert.deepEqual(
      adapter.all("SELECT app_id FROM app_attest_keys WHERE key_id = ?", keyId),
      [{ app_id: appRoute.appIdentity }],
      "the same cryptographically verified identity anchors the key and device route",
    );
  } finally {
    adapter?.close();
    await rm(stateDirectory, { recursive: true, force: true });
  }
});

test("complete attested registration safely recovers an exact token after key rotation", async () => {
  const { completeAttestedRegistration } = await workerModule();
  const token = "reinstall-recovery-token";
  const oldKey = "old-app-attest-key";
  const assertionKey = "asserting-app-attest-key";
  const freshKey = "fresh-app-attest-key";
  const tokenHash = createHash("sha256").update(token).digest("hex");
  const now = "2026-08-12T00:00:00.000Z";
  const stateDirectory = await mkdtemp(join(tmpdir(), "quakesignal-app-attest-recovery-"));
  let adapter;

  try {
    const localArguments = ["--local", "--persist-to", stateDirectory];
    runWrangler(["d1", "migrations", "apply", "quakesignal-production", ...localArguments]);
    const databaseFile = localD1File(stateDirectory);
    const seed = new DatabaseSync(databaseFile);
    try {
      seedKey(seed, oldKey, now);
      seedKey(seed, assertionKey, now);
      seed
        .prepare(
          `INSERT INTO devices (
            token, environment, sources, min_magnitude, critical_alerts_enabled,
            include_test_alerts, notify_at_night, app_attest_key_id, created_at, updated_at
          ) VALUES (?, 'production', '["jma_eew"]', 0, 0, 0, 1, ?, ?, ?)`,
        )
        .run(token, oldKey, now, now);
      seed
        .prepare(
          `INSERT INTO alert_lifecycle_recipients (
            event_ref, token_hash, app_attest_key_id,
            first_evidence_at_utc, last_evidence_at_utc
          ) VALUES ('jma_eew:pre-reinstall-warning', ?, ?, ?, ?)`,
        )
        .run(tokenHash, oldKey, now, now);
      seedChallenge(seed, authorization(assertionKey, "assertion").challenge, now);
      seedChallenge(seed, authorization(freshKey, "attestation").challenge, now);
    } finally {
      seed.close();
    }

    adapter = localD1Adapter(databaseFile);
    const values = registrationValues(token, now, "production", "japanese-voice");
    const assertionOutcome = await completeAttestedRegistration(
      adapter.database,
      authorization(assertionKey, "assertion"),
      values,
    );
    assert.equal(assertionOutcome, "conflict");
    assert.deepEqual(
      adapter.all("SELECT app_attest_key_id FROM devices WHERE token = ?", token),
      [{ app_attest_key_id: oldKey }],
      "an assertion must not transfer a token owned by another key",
    );

    const recoveryOutcome = await completeAttestedRegistration(
      adapter.database,
      authorization(freshKey, "attestation"),
      values,
    );
    assert.equal(recoveryOutcome, "completed");
    assert.deepEqual(
      adapter.all(
        "SELECT app_attest_key_id, alert_sound FROM devices WHERE token = ?",
        token,
      ),
      [{ app_attest_key_id: freshKey, alert_sound: "japanese-voice" }],
      "a fresh attestation must rebind the subscription and its validated sound",
    );
    assert.deepEqual(
      adapter.all("SELECT key_id FROM app_attest_keys ORDER BY key_id"),
      [{ key_id: freshKey }],
      "successful recovery must retire the now-orphaned old integrity key",
    );
    assert.deepEqual(
      adapter.all(
        `SELECT token_hash, app_attest_key_id
         FROM alert_lifecycle_recipients
         WHERE event_ref = 'jma_eew:pre-reinstall-warning'`,
      ),
      [{ token_hash: tokenHash, app_attest_key_id: freshKey }],
      "an exact-token rebind must rekey continuity before a later token rotation",
    );
    assert.deepEqual(
      adapter.all(
        "SELECT consumed_at_utc FROM app_attest_challenges WHERE id = ?",
        `challenge-${freshKey}`,
      ),
      [{ consumed_at_utc: now }],
      "the recovery proof must be consumed in the same transaction",
    );
  } finally {
    adapter?.close();
    await rm(stateDirectory, { recursive: true, force: true });
  }
});

test("post-2xx lifecycle recording prefers a fresh exact-token key and survives its later token rotation", async () => {
  const {
    completeAttestedRegistration,
    recordDeliveredDevices,
  } = await workerModule();
  const oldKey = "acceptance-race-old-key";
  const freshKey = "acceptance-race-fresh-key";
  const oldToken = "acceptance-race-token";
  const rotatedToken = "acceptance-race-rotated-token";
  const oldTokenHash = createHash("sha256").update(oldToken).digest("hex");
  const initialTime = "2026-08-12T00:00:00.000Z";
  const acceptedAt = "2026-08-12T00:00:01.000Z";
  const rebindTime = "2026-08-12T00:00:02.000Z";
  const rotationTime = "2026-08-12T00:00:03.000Z";
  const stateDirectory = await mkdtemp(join(tmpdir(), "quakesignal-lifecycle-key-race-"));
  let adapter;
  try {
    const localArguments = ["--local", "--persist-to", stateDirectory];
    runWrangler(["d1", "migrations", "apply", "quakesignal-production", ...localArguments]);
    const databaseFile = localD1File(stateDirectory);
    const rebindAuthorization = authorization(freshKey, "attestation");
    const rotateAuthorization = authorization(freshKey, "assertion");
    rotateAuthorization.challenge.id = `challenge-${freshKey}-rotation`;
    const seed = new DatabaseSync(databaseFile);
    try {
      seedKey(seed, oldKey, initialTime);
      seed.prepare(
        `INSERT INTO devices (
           token, environment, sources, min_magnitude, critical_alerts_enabled,
           include_test_alerts, notify_at_night, app_attest_key_id,
           created_at, updated_at
         ) VALUES (?, 'production', '["jma_eew"]', 0, 0, 0, 1, ?, ?, ?)`,
      ).run(oldToken, oldKey, initialTime, initialTime);
      seedChallenge(seed, rebindAuthorization.challenge, rebindTime);
    } finally {
      seed.close();
    }
    adapter = localD1Adapter(databaseFile);
    const sentRevision = adapter.all(
      "SELECT registration_revision FROM devices WHERE token = ?",
      oldToken,
    )[0].registration_revision;
    adapter.run(
      `INSERT INTO apns_registration_revision_fences (
         registration_revision, token_hash, app_attest_key_id,
         decision_id, decision_kind, blocks_lifecycle_replay, processed_at_utc
       ) VALUES (?, ?, ?, 'acceptance-race-continuity',
         'token_rotation', 0, ?)`,
      sentRevision,
      oldTokenHash,
      oldKey,
      initialTime,
    );
    assert.equal(
      await completeAttestedRegistration(
        adapter.database,
        rebindAuthorization,
        registrationValues(oldToken, rebindTime),
      ),
      "completed",
    );
    assert.deepEqual(
      adapter.all(
        `SELECT app_attest_key_id, blocks_lifecycle_replay
         FROM apns_registration_revision_fences
         WHERE registration_revision = ?`,
        sentRevision,
      ),
      [{ app_attest_key_id: freshKey, blocks_lifecycle_replay: 0 }],
      "fresh exact-token rebind carries the prior key's continuity-fence lineage",
    );
    await recordDeliveredDevices(
      adapter.database,
      "acceptance-race-delivery",
      "jma_eew:acceptance-race",
      "jma_eew",
      "new",
      [{
        token: oldToken,
        tokenHash: oldTokenHash,
        snapshotRegistrationRevision: sentRevision,
        snapshotAppAttestKeyId: oldKey,
        firstAcceptedAtUtc: acceptedAt,
        lastAcceptedAtUtc: acceptedAt,
      }],
    );
    assert.deepEqual(
      adapter.all(
        `SELECT app_attest_key_id, first_evidence_at_utc,
                last_evidence_at_utc
         FROM alert_lifecycle_recipients
         WHERE event_ref = 'jma_eew:acceptance-race'`,
      ),
      [{
        app_attest_key_id: freshKey,
        first_evidence_at_utc: acceptedAt,
        last_evidence_at_utc: acceptedAt,
      }],
      "D1 mapping must prefer the current exact-token key over the stale sent snapshot key",
    );
    await recordDeliveredDevices(
      adapter.database,
      "acceptance-race-delivery",
      "jma_eew:acceptance-race",
      "jma_eew",
      "updated",
      [{
        token: oldToken,
        tokenHash: oldTokenHash,
        snapshotRegistrationRevision: sentRevision,
        snapshotAppAttestKeyId: oldKey,
        firstAcceptedAtUtc: "2026-08-11T23:59:59.000Z",
        lastAcceptedAtUtc: "2026-08-12T00:00:04.000Z",
      }],
    );
    assert.deepEqual(
      adapter.all(
        `SELECT first_evidence_at_utc, last_evidence_at_utc
         FROM alert_lifecycle_recipients
         WHERE event_ref = 'jma_eew:acceptance-race'`,
      ),
      [{
        first_evidence_at_utc: "2026-08-11T23:59:59.000Z",
        last_evidence_at_utc: "2026-08-12T00:00:04.000Z",
      }],
      "idempotent replay keeps lifecycle acceptance bounds monotonic with MIN/MAX",
    );
    const rotationSeed = new DatabaseSync(databaseFile);
    try {
      seedChallenge(rotationSeed, rotateAuthorization.challenge, rotationTime);
    } finally {
      rotationSeed.close();
    }
    assert.equal(
      await completeAttestedRegistration(
        adapter.database,
        rotateAuthorization,
        registrationValues(rotatedToken, rotationTime),
      ),
      "completed",
    );
    assert.deepEqual(
      adapter.all("SELECT token, app_attest_key_id FROM devices"),
      [{ token: rotatedToken, app_attest_key_id: freshKey }],
    );
    assert.deepEqual(
      adapter.all(
        `SELECT token_hash, app_attest_key_id
         FROM alert_lifecycle_recipients
         WHERE event_ref = 'jma_eew:acceptance-race'`,
      ),
      [{ token_hash: oldTokenHash, app_attest_key_id: freshKey }],
      "the rekeyed lifecycle row remains matchable after ordinary token rotation",
    );
  } finally {
    adapter?.close();
    await rm(stateDirectory, { recursive: true, force: true });
  }
});

test("the post-2xx DO journal survives D1 failure but cannot cross rotation and explicit removal", async () => {
  const {
    QuakeRelay,
    completeAttestedKeyBoundDeletion,
  } = await workerModule();
  const token = "journal-explicit-delete-token";
  const rotatedToken = "journal-explicit-delete-rotated-token";
  const tokenHash = createHash("sha256").update(token).digest("hex");
  const oldKey = "journal-explicit-delete-key";
  const reincarnatedKey = "journal-explicit-delete-reincarnated-key";
  const now = "2026-08-12T00:00:00.000Z";
  const stateDirectory = await mkdtemp(join(tmpdir(), "quakesignal-apns-accept-journal-"));
  let adapter;
  try {
    const localArguments = ["--local", "--persist-to", stateDirectory];
    runWrangler(["d1", "migrations", "apply", "quakesignal-production", ...localArguments]);
    const databaseFile = localD1File(stateDirectory);
    const seed = new DatabaseSync(databaseFile);
    try {
      seedKey(seed, oldKey, now);
      seed.prepare(
        `INSERT INTO devices (
           token, environment, sources, min_magnitude, critical_alerts_enabled,
           include_test_alerts, notify_at_night, app_attest_key_id,
           created_at, updated_at
         ) VALUES (?, 'production', '["jma_eew"]', 0, 0, 0, 1, ?, ?, ?)`,
      ).run(token, oldKey, now, now);
    } finally {
      seed.close();
    }
    adapter = localD1Adapter(databaseFile);
    const sentRevision = adapter.all(
      "SELECT registration_revision FROM devices WHERE token = ?",
      token,
    )[0].registration_revision;
    let failD1 = true;
    const records = new Map();
    let alarmAt = null;
    const storage = {
      async getAlarm() {
        return alarmAt;
      },
      async setAlarm(value) {
        alarmAt = value;
      },
      async list({ prefix, limit }) {
        return new Map(
          [...records.entries()]
            .filter(([key]) => key.startsWith(prefix))
            .slice(0, limit),
        );
      },
      async transaction(callback) {
        return callback({
          async get(key) {
            return records.get(key);
          },
          async put(key, value) {
            records.set(key, value);
          },
          async delete(key) {
            records.delete(key);
          },
        });
      },
      async delete(key) {
        records.delete(key);
      },
    };
    const relay = new QuakeRelay(
      { storage },
      {
        DB: {
          prepare: adapter.database.prepare,
          async batch(statements) {
            if (failD1) throw new Error("simulated post-2xx D1 outage");
            return adapter.database.batch(statements);
          },
        },
      },
    );
    await assert.rejects(
      relay.persistApnsAcceptedBatch(
        "journal-explicit-delete-delivery",
        "jma_eew:journal-explicit-delete",
        "jma_eew",
        "new",
        [{
          device: {
            token,
            registrationRevision: sentRevision,
            appAttestKeyId: oldKey,
          },
          tokenHash,
          acceptedAtUtc: "2026-08-12T00:00:01.000Z",
        }],
      ),
      /simulated post-2xx D1 outage/,
    );
    assert.equal(records.size, 1, "known APNs acceptance stays durable across D1 failure");
    const journal = [...records.values()][0];
    assert.deepEqual(Object.keys(journal).sort(), [
      "createdAtUtc",
      "deliveries",
      "deliveryId",
      "eventRef",
      "reason",
      "sourceId",
      "version",
      "writeId",
    ]);
    assert.deepEqual(Object.keys(journal.deliveries[0]).sort(), [
      "firstAcceptedAtUtc",
      "lastAcceptedAtUtc",
      "snapshotAppAttestKeyId",
      "snapshotRegistrationRevision",
      "token",
      "tokenHash",
    ]);
    assert.equal(journal.deliveries[0].token, token,
      "the bounded journal deliberately retains the raw token needed for current-consent mapping");
    adapter.run(
      `INSERT INTO apns_registration_revision_fences (
         registration_revision, token_hash, app_attest_key_id,
         decision_id, decision_kind, blocks_lifecycle_replay, processed_at_utc
       ) VALUES (?, ?, ?, 'journal-token-rotation-decision',
         'token_rotation', 0, ?)`,
      sentRevision,
      tokenHash,
      oldKey,
      "2026-08-12T00:00:02.000Z",
    );
    adapter.run("DELETE FROM devices WHERE token = ?", token);
    adapter.run(
      `INSERT INTO devices (
         token, environment, sources, min_magnitude, critical_alerts_enabled,
         include_test_alerts, notify_at_night, app_attest_key_id,
         created_at, updated_at
       ) VALUES (?, 'production', '["jma_eew"]', 0, 0, 0, 1, ?, ?, ?)`,
      rotatedToken,
      oldKey,
      "2026-08-12T00:00:03.000Z",
      "2026-08-12T00:00:03.000Z",
    );
    const deletionAuthorization = authorization(oldKey, "assertion");
    deletionAuthorization.challenge.operation = "device-deletion";
    deletionAuthorization.challenge.method = "DELETE";
    deletionAuthorization.challenge.path = "/v1/devices";
    seedChallenge(
      adapter,
      deletionAuthorization.challenge,
      "2026-08-12T00:00:04.000Z",
    );
    assert.equal(
      await completeAttestedKeyBoundDeletion(
        adapter.database,
        deletionAuthorization,
      ),
      "completed",
    );
    assert.deepEqual(
      adapter.all(
        `SELECT decision_kind, blocks_lifecycle_replay
         FROM apns_registration_revision_fences
         WHERE registration_revision = ?`,
        sentRevision,
      ),
      [{ decision_kind: "explicit_removal", blocks_lifecycle_replay: 1 }],
      "explicit deletion upgrades every earlier rotation fence in the authenticated lineage",
    );
    seedKey(adapter, reincarnatedKey, "2026-08-12T00:00:05.000Z");
    adapter.run(
      `INSERT INTO devices (
         token, environment, sources, min_magnitude, critical_alerts_enabled,
         include_test_alerts, notify_at_night, app_attest_key_id,
         created_at, updated_at
       ) VALUES (?, 'production', '["jma_eew"]', 0, 0, 0, 1, ?, ?, ?)`,
      token,
      reincarnatedKey,
      "2026-08-12T00:00:05.000Z",
      "2026-08-12T00:00:05.000Z",
    );
    failD1 = false;
    await relay.reconcileApnsAcceptanceJournal();
    assert.equal(records.size, 0);
    assert.deepEqual(
      adapter.all("SELECT COUNT(*) AS count FROM notification_deliveries"),
      [{ count: 0 }],
    );
    assert.deepEqual(
      adapter.all("SELECT COUNT(*) AS count FROM alert_lifecycle_recipients"),
      [{ count: 0 }],
      "the lineage-wide blocking removal drops old acceptance instead of attaching it to the same-token reincarnation",
    );
  } finally {
    adapter?.close();
    await rm(stateDirectory, { recursive: true, force: true });
  }
});

test("a pre-send intent recovers the APNs-to-D1 crash window before a newer supersession", async () => {
  const { QuakeRelay } = await workerModule();
  const token = "b".repeat(64);
  const ineligibleToken = "c".repeat(64);
  const tokenHash = createHash("sha256").update(token).digest("hex");
  const ineligibleTokenHash = createHash("sha256")
    .update(ineligibleToken).digest("hex");
  const keyId = "pre-send-recovery-key";
  const ineligibleKeyId = "pre-send-ineligible-key";
  const now = "2026-08-22T00:00:00.000Z";
  const stateDirectory = await mkdtemp(join(tmpdir(), "quakesignal-pre-send-recovery-"));
  let adapter;
  const originalFetch = globalThis.fetch;
  try {
    const localArguments = ["--local", "--persist-to", stateDirectory];
    runWrangler(["d1", "migrations", "apply", "quakesignal-production", ...localArguments]);
    const databaseFile = localD1File(stateDirectory);
    const seed = new DatabaseSync(databaseFile);
    try {
      seedKey(seed, keyId, now);
      seedKey(seed, ineligibleKeyId, now);
      seed.prepare(
        `INSERT INTO devices (
           token, environment, sources, min_magnitude,
           critical_alerts_enabled, alert_sound, city_name, latitude,
           longitude, radius_km, include_test_alerts, utc_offset_minutes,
           notify_at_night, app_attest_key_id, created_at, updated_at
         ) VALUES (?, 'production', '["jma_eew"]', 0, 0, 'system', NULL,
           35, 139, 100, 0, NULL, 1, ?, ?, ?)`,
      ).run(token, keyId, now, now);
      seed.prepare(
        `INSERT INTO devices (
           token, environment, sources, min_magnitude,
           critical_alerts_enabled, alert_sound, city_name, latitude,
           longitude, radius_km, include_test_alerts, utc_offset_minutes,
           notify_at_night, app_attest_key_id, created_at, updated_at
         ) VALUES (?, 'production', '["jma_eew"]', 9, 0, 'system', NULL,
           35, 139, 100, 0, NULL, 1, ?, ?, ?)`,
      ).run(ineligibleToken, ineligibleKeyId, now, now);
    } finally {
      seed.close();
    }
    adapter = localD1Adapter(databaseFile);
    const registrationRevision = adapter.all(
      "SELECT registration_revision FROM devices WHERE token = ?",
      token,
    )[0].registration_revision;
    const ineligibleRegistrationRevision = adapter.all(
      "SELECT registration_revision FROM devices WHERE token = ?",
      ineligibleToken,
    )[0].registration_revision;
    const event = {
      id: "jma_eew:pre-send-recovery",
      eventId: "pre-send-recovery",
      sourceId: "jma_eew",
      serial: 1,
      kind: "eew",
      originTimeUtc: now,
      reportTimeUtc: now,
      hypocenter: "Recovery test",
      latitude: 35,
      longitude: 139,
      magnitude: 5,
      depth: 10,
      maxIntensity: "4",
      isWarn: true,
      isFinal: false,
      isCancel: false,
      isTraining: false,
      tsunami: null,
    };
    const message = {
      version: 1,
      outboxId: "pre-send-recovery-outbox",
      deliveryId: "v1:jma_eew:pre-send-recovery:1:new",
      rootDeliveryId: "v1:jma_eew:pre-send-recovery:1:new",
      event,
      reason: "new",
      expiresAtUtc: "2099-01-01T00:00:00.000Z",
      expiryPolicy: "eew_10m",
    };
    // Keep the exact outbox pending while the admitted intent owns recovery.
    adapter.run(
      `INSERT INTO alert_delivery_outbox (
         id, dedupe_key, delivery_id, root_delivery_id, event_ref,
         event_serial, notification_reason, event_json, created_at_utc,
         expires_at_utc, expiry_policy
       ) VALUES (?, 'pre-send-recovery-dedupe', ?, ?, ?, 1, 'new', ?, ?,
         ?, 'eew_10m')`,
      message.outboxId,
      message.deliveryId,
      message.rootDeliveryId,
      event.id,
      JSON.stringify(event),
      now,
      message.expiresAtUtc,
    );
    const records = new Map();
    let alarmAt = null;
    const relay = new QuakeRelay(
      {
        storage: {
          async getAlarm() { return alarmAt; },
          async setAlarm(value) { alarmAt = value; },
          async list({ prefix, limit }) {
            return new Map(
              [...records.entries()]
                .filter(([key]) => key.startsWith(prefix))
                .slice(0, limit),
            );
          },
          async transaction(callback) {
            return callback({
              async get(key) { return records.get(key); },
              async put(key, value) { records.set(key, value); },
              async delete(key) { records.delete(key); },
            });
          },
        },
      },
      {
        DB: adapter.database,
        APNS_PRIVATE_KEY: "configured-pre-send-recovery-key",
        APNS_KEY_ID: "ABCDEFGHIJ",
        APNS_TEAM_ID: "ABCDEFGHIJ",
        APNS_BUNDLE_ID: "com.quakesignal.app",
      },
    );
    relay.apnsAuthorization = async () => "cached.provider.jwt";
    const device = {
      token,
      environment: "production",
      locale: null,
      sources: ["jma_eew"],
      minMagnitude: 0,
      criticalAlertsEnabled: false,
      alertSound: "system",
      cityName: null,
      latitude: 35,
      longitude: 139,
      radiusKm: 100,
      includeTestAlerts: false,
      utcOffsetMinutes: null,
      notifyAtNight: true,
      appAttestKeyId: keyId,
      registrationRevision,
      appIdentity: "5TT564H883.com.quakesignal.app",
      apnsTopic: "com.quakesignal.app",
      platform: "ios",
      createdAt: now,
      updatedAt: now,
    };
    const ineligibleDevice = {
      ...device,
      token: ineligibleToken,
      minMagnitude: 9,
      appAttestKeyId: ineligibleKeyId,
      registrationRevision: ineligibleRegistrationRevision,
    };
    await relay.persistApnsDeliveryIntent(message, [
      { device, tokenHash },
      { device: ineligibleDevice, tokenHash: ineligibleTokenHash },
    ]);
    assert.equal(records.size, 1, "intent is durable before provider contact");
    for (const [storageKey, value] of records) {
      records.set(storageKey, {
        ...value,
        nextProviderAttemptAtUtc: new Date(Date.now() - 1).toISOString(),
      });
    }
    let apnsRequests = 0;
    globalThis.fetch = async () => {
      apnsRequests += 1;
      return new Response(null, { status: 200 });
    };
    await relay.reconcileApnsAcceptanceJournal();
    assert.equal(apnsRequests, 1, "recovery redispatches the still-eligible current route");
    assert.equal(records.size, 0, "intent clears only after D1 acceptance commits");
    assert.deepEqual(
      adapter.all("SELECT COUNT(*) AS count FROM notification_deliveries"),
      [{ count: 1 }],
    );
    assert.deepEqual(
      adapter.all(
        `SELECT token_hash, evidence_kind
         FROM alert_lifecycle_recipients ORDER BY token_hash`,
      ),
      [{ token_hash: tokenHash, evidence_kind: "apns_accepted" }],
      "a recipient excluded before provider admission must not gain false possible-contact lifecycle provenance",
    );
    const expiredEvent = {
      ...event,
      id: "jma_eew:pre-send-expired",
      eventId: "pre-send-expired",
      serial: 2,
    };
    const expiredMessage = {
      ...message,
      outboxId: "pre-send-expired-outbox",
      deliveryId: "v1:jma_eew:pre-send-expired:2:new",
      rootDeliveryId: "v1:jma_eew:pre-send-expired:2:new",
      event: expiredEvent,
      expiresAtUtc: "2026-08-21T00:00:00.000Z",
    };
    adapter.run(
      `INSERT INTO alert_delivery_outbox (
         id, dedupe_key, delivery_id, root_delivery_id, event_ref,
         event_serial, notification_reason, event_json, created_at_utc,
         expires_at_utc, expiry_policy
       ) VALUES (?, 'pre-send-expired-dedupe', ?, ?, ?, 2, 'new', ?, ?, ?,
         'eew_10m')`,
      expiredMessage.outboxId,
      expiredMessage.deliveryId,
      expiredMessage.rootDeliveryId,
      expiredEvent.id,
      JSON.stringify(expiredEvent),
      now,
      expiredMessage.expiresAtUtc,
    );
    await relay.persistApnsDeliveryIntent(expiredMessage, [{ device, tokenHash }]);
    await relay.reconcileApnsAcceptanceJournal();
    assert.equal(apnsRequests, 1, "expiry retires unknown work without another APNs request");
    assert.deepEqual(
      adapter.all(
        `SELECT evidence_kind FROM alert_lifecycle_recipients
         WHERE event_ref = ? AND token_hash = ?`,
        expiredEvent.id,
        tokenHash,
      ),
      [],
      "deadline expiry before any provider admission must not manufacture possible-contact lifecycle provenance",
    );
    const retryEvent = {
      ...event,
      id: "jma_eew:pre-send-backoff",
      eventId: "pre-send-backoff",
      serial: 3,
    };
    const retryMessage = {
      ...message,
      outboxId: "pre-send-backoff-outbox",
      deliveryId: "v1:jma_eew:pre-send-backoff:3:new",
      rootDeliveryId: "v1:jma_eew:pre-send-backoff:3:new",
      event: retryEvent,
    };
    adapter.run(
      `INSERT INTO alert_delivery_outbox (
         id, dedupe_key, delivery_id, root_delivery_id, event_ref,
         event_serial, notification_reason, event_json, created_at_utc,
         expires_at_utc, expiry_policy
       ) VALUES (?, 'pre-send-backoff-dedupe', ?, ?, ?, 3, 'new', ?, ?, ?,
         'eew_10m')`,
      retryMessage.outboxId,
      retryMessage.deliveryId,
      retryMessage.rootDeliveryId,
      retryEvent.id,
      JSON.stringify(retryEvent),
      now,
      retryMessage.expiresAtUtc,
    );
    await relay.persistApnsDeliveryIntent(retryMessage, [{ device, tokenHash }]);
    for (const [storageKey, value] of records) {
      records.set(storageKey, {
        ...value,
        nextProviderAttemptAtUtc: new Date(Date.now() - 1).toISOString(),
      });
    }
    let retryProviderRequests = 0;
    globalThis.fetch = async () => {
      retryProviderRequests += 1;
      return Response.json({ reason: "ServiceUnavailable" }, { status: 503 });
    };
    await relay.reconcileApnsAcceptanceJournal();
    const afterFirstRetry = [...records.values()][0];
    assert.equal(afterFirstRetry.providerAttempts, 1);
    await relay.reconcileApnsAcceptanceJournal();
    assert.equal(retryProviderRequests, 1, "unrelated reconciliation cannot burn the retry budget before its durable gate");
    assert.equal([...records.values()][0].providerAttempts, 1);
    for (const [storageKey, value] of records) {
      records.set(storageKey, {
        ...value,
        nextProviderAttemptAtUtc: new Date(Date.now() - 1).toISOString(),
      });
    }
    await relay.reconcileApnsAcceptanceJournal();
    assert.equal(retryProviderRequests, 2, "a due recovery reserves exactly one later provider contact");
    assert.equal([...records.values()][0].providerAttempts, 2);
    assert.ok(
      Date.parse([...records.values()][0].lastProviderAttemptAtUtc) >=
        Date.parse(afterFirstRetry.lastProviderAttemptAtUtc),
      "the latest reserved provider-contact timestamp advances conservative lifecycle retention",
    );
  } finally {
    globalThis.fetch = originalFetch;
    adapter?.close();
    await rm(stateDirectory, { recursive: true, force: true });
  }
});

test("same-key APNs token rotation preserves the stale-response fence", async () => {
  const { completeAttestedRegistration } = await workerModule();
  const keyId = "rotating-device-key";
  const oldToken = "old-apns-token-for-same-key";
  const newToken = "new-apns-token-for-same-key";
  const now = "2026-08-12T00:00:00.000Z";
  const stateDirectory = await mkdtemp(join(tmpdir(), "quakesignal-app-attest-token-rotation-"));
  let adapter;

  try {
    const localArguments = ["--local", "--persist-to", stateDirectory];
    runWrangler(["d1", "migrations", "apply", "quakesignal-production", ...localArguments]);
    const databaseFile = localD1File(stateDirectory);
    const tokenHash = createHash("sha256").update(oldToken).digest("hex");
    const registrationAuthorization = authorization(keyId, "assertion");
    const seed = new DatabaseSync(databaseFile);
    try {
      seedKey(seed, keyId, now);
      seed
        .prepare(
          `INSERT INTO devices (
            token, environment, sources, min_magnitude, critical_alerts_enabled,
            include_test_alerts, notify_at_night, app_attest_key_id, created_at, updated_at
          ) VALUES (?, 'production', '["jma_eew"]', 0, 0, 0, 1, ?, ?, ?)`,
        )
        .run(oldToken, keyId, now, now);
      seed
        .prepare(
          `INSERT INTO notification_deliveries (
            delivery_id, device_token, delivered_at_utc
          ) VALUES ('old-token-delivery', ?, ?)`,
        )
        .run(oldToken, now);
      seed
        .prepare(
          `INSERT INTO alert_delivery_failures (
            delivery_id, token_hash, event_ref, source_id, notification_reason,
            apns_status, apns_reason, disposition, status,
            first_seen_utc, last_seen_utc, resolved_at_utc,
            registration_revision
          ) VALUES
            ('old-token-delivery', ?, 'jma_eew:old', 'jma_eew', 'new',
             NULL, NULL, 'quarantine', 'active', ?, ?, NULL, NULL),
            ('old-token-processed-revision', ?, 'jma_eew:old', 'jma_eew', 'new',
             400, 'BadDeviceToken', 'quarantine', 'resolved', ?, ?, ?,
             'retired-token-processed-revision')`,
        )
        .run(tokenHash, now, now, tokenHash, now, now, now);
      seed
        .prepare(
          `INSERT INTO alert_lifecycle_recipients (
            event_ref, token_hash, app_attest_key_id,
            first_evidence_at_utc, last_evidence_at_utc
          ) VALUES ('jma_eew:active-before-token-rotation', ?, ?, ?, ?)`,
        )
        .run(tokenHash, keyId, now, now);
      seedChallenge(seed, registrationAuthorization.challenge, now);
    } finally {
      seed.close();
    }

    adapter = localD1Adapter(databaseFile);
    const outcome = await completeAttestedRegistration(
      adapter.database,
      registrationAuthorization,
      registrationValues(newToken, now),
    );
    assert.equal(outcome, "completed");
    assert.deepEqual(
      adapter.all("SELECT token, app_attest_key_id FROM devices"),
      [{ token: newToken, app_attest_key_id: keyId }],
      "the current key must keep only its refreshed APNs token",
    );
    assert.deepEqual(
      adapter.all("SELECT COUNT(*) AS count FROM notification_deliveries"),
      [{ count: 0 }],
      "deduplication evidence for the retired token must be removed",
    );
    assert.deepEqual(
      adapter.all(
        `SELECT delivery_id, status, registration_revision
         FROM alert_delivery_failures`,
      ),
      [
        {
          delivery_id: "old-token-processed-revision",
          status: "resolved",
          registration_revision: "retired-token-processed-revision",
        },
      ],
      "ordinary retired-token evidence is removed while its stale-response fence survives",
    );
    assert.deepEqual(
      adapter.all(
        `SELECT token_hash, app_attest_key_id
         FROM alert_lifecycle_recipients
         WHERE event_ref = 'jma_eew:active-before-token-rotation'`,
      ),
      [{ token_hash: tokenHash, app_attest_key_id: keyId }],
      "the opaque key must preserve terminal-alert continuity across token rotation",
    );
  } finally {
    adapter?.close();
    await rm(stateDirectory, { recursive: true, force: true });
  }
});

test("same-token authenticated renewal rehabilitates stale failure evidence", async () => {
  const { completeAttestedRegistration } = await workerModule();
  const keyId = "same-token-rehabilitation-key";
  const token = "same-token-rehabilitation-token";
  const tokenHash = createHash("sha256").update(token).digest("hex");
  const unrelatedTokenHash = createHash("sha256")
    .update("unrelated-rehabilitation-token")
    .digest("hex");
  const oldTime = "2026-08-11T00:00:00.000Z";
  const now = "2026-08-12T00:00:00.000Z";
  const stateDirectory = await mkdtemp(join(tmpdir(), "quakesignal-app-attest-rehabilitate-"));
  let adapter;

  try {
    const localArguments = ["--local", "--persist-to", stateDirectory];
    runWrangler(["d1", "migrations", "apply", "quakesignal-production", ...localArguments]);
    const databaseFile = localD1File(stateDirectory);
    const registrationAuthorization = authorization(keyId, "assertion");
    const seed = new DatabaseSync(databaseFile);
    try {
      seedKey(seed, keyId, oldTime);
      seed
        .prepare(
          `INSERT INTO devices (
            token, environment, sources, min_magnitude, critical_alerts_enabled,
            include_test_alerts, notify_at_night, app_attest_key_id, created_at, updated_at
          ) VALUES (?, 'production', '["jma_eew"]', 0, 0, 0, 1, ?, ?, ?)`,
        )
        .run(token, keyId, oldTime, oldTime);
      seed
        .prepare(
          `INSERT INTO alert_delivery_failures (
            delivery_id, token_hash, event_ref, source_id, notification_reason,
            apns_status, apns_reason, disposition, status,
            first_seen_utc, last_seen_utc, registration_revision
          ) VALUES
            (
              'stale-bad-token-delivery', ?, 'jma_eew:stale', 'jma_eew', 'new',
              400, 'BadDeviceToken', 'quarantine', 'active', ?, ?,
              'stale-sent-registration-revision'
            ),
            (
              'unrelated-bad-token-delivery', ?, 'jma_eew:unrelated', 'jma_eew', 'new',
              400, 'BadDeviceToken', 'quarantine', 'active', ?, ?,
              'unrelated-sent-registration-revision'
            )`,
        )
        .run(
          tokenHash,
          oldTime,
          oldTime,
          unrelatedTokenHash,
          oldTime,
          oldTime,
        );
      seedChallenge(seed, registrationAuthorization.challenge, now);
    } finally {
      seed.close();
    }

    adapter = localD1Adapter(databaseFile);
    assert.equal(
      await completeAttestedRegistration(
        adapter.database,
        registrationAuthorization,
        registrationValues(token, now),
      ),
      "completed",
    );
    assert.deepEqual(
      adapter.all("SELECT token, updated_at FROM devices"),
      [{ token, updated_at: now }],
      "the successful proof must refresh the same exact subscription",
    );
    assert.deepEqual(
      adapter.all(
        `SELECT delivery_id, token_hash, status, registration_revision
         FROM alert_delivery_failures ORDER BY delivery_id`,
      ),
      [
        {
          delivery_id: "stale-bad-token-delivery",
          token_hash: tokenHash,
          status: "resolved",
          registration_revision: "stale-sent-registration-revision",
        },
        {
          delivery_id: "unrelated-bad-token-delivery",
          token_hash: unrelatedTokenHash,
          status: "active",
          registration_revision: "unrelated-sent-registration-revision",
        },
      ],
      "renewal resolves only that token's health state while preserving its processed-revision fence",
    );
  } finally {
    adapter?.close();
    await rm(stateDirectory, { recursive: true, force: true });
  }
});

test("APNs response timestamps keep an earlier acceptance from clearing later BadDeviceToken evidence", async () => {
  const { recordDeliveredDevices } = await workerModule();
  const token = "accepted-recovery-token";
  const unrelatedToken = "unrelated-recovery-token";
  const tokenHash = createHash("sha256").update(token).digest("hex");
  const unrelatedTokenHash = createHash("sha256").update(unrelatedToken).digest("hex");
  const oldTime = "2026-08-11T00:00:00.000Z";
  const acceptedAt = "2026-08-12T00:00:00.000Z";
  const futureTime = "2099-08-13T00:00:00.000Z";
  const stateDirectory = await mkdtemp(join(tmpdir(), "quakesignal-apns-accept-recovery-"));
  let adapter;

  try {
    const localArguments = ["--local", "--persist-to", stateDirectory];
    runWrangler(["d1", "migrations", "apply", "quakesignal-production", ...localArguments]);
    const databaseFile = localD1File(stateDirectory);
    const seed = new DatabaseSync(databaseFile);
    try {
      seed.prepare(
        `INSERT INTO devices (
           token, environment, sources, min_magnitude,
           critical_alerts_enabled, include_test_alerts, notify_at_night,
           app_attest_key_id, app_identity, apns_topic, app_platform,
           registration_revision, created_at, updated_at
         ) VALUES (?, 'production', '["jma_eew"]', 0, 0, 0, 1,
           'accepted-recovery-key', '5TT564H883.com.quakesignal.app',
           'com.quakesignal.app', 'ios', 'accepted-snapshot-revision', ?, ?)`,
      ).run(token, oldTime, oldTime);
      seed
        .prepare(
          `INSERT INTO alert_delivery_failures (
            delivery_id, token_hash, event_ref, source_id, notification_reason,
            apns_status, apns_reason, disposition, status,
            first_seen_utc, last_seen_utc, registration_revision
          ) VALUES
            ('older-bad-token', ?, 'jma_eew:older', 'jma_eew', 'new',
             400, 'BadDeviceToken', 'quarantine', 'active', ?, ?,
             'older-registration-revision'),
            ('later-bad-token', ?, 'jma_eew:later', 'jma_eew', 'new',
             400, 'BadDeviceToken', 'quarantine', 'active', ?, ?,
             'future-clock-registration-revision'),
            ('unrelated-bad-token', ?, 'jma_eew:unrelated', 'jma_eew', 'new',
             400, 'BadDeviceToken', 'quarantine', 'active', ?, ?,
             'unrelated-registration-revision')`,
        )
        .run(
          tokenHash,
          oldTime,
          oldTime,
          tokenHash,
          futureTime,
          futureTime,
          unrelatedTokenHash,
          oldTime,
          oldTime,
        );
    } finally {
      seed.close();
    }

    adapter = localD1Adapter(databaseFile);
    await recordDeliveredDevices(
      adapter.database,
      "accepted-on-another-delivery",
      "jma_eew:accepted-recovery",
      "jma_eew",
      "new",
      [{
        token,
        tokenHash,
        snapshotRegistrationRevision: "accepted-snapshot-revision",
        snapshotAppAttestKeyId: "accepted-recovery-key",
        firstAcceptedAtUtc: acceptedAt,
        lastAcceptedAtUtc: acceptedAt,
      }],
    );
    assert.deepEqual(
      adapter.all(
        `SELECT delivery_id, status FROM alert_delivery_failures
         ORDER BY delivery_id`,
      ),
      [
        { delivery_id: "later-bad-token", status: "active" },
        { delivery_id: "older-bad-token", status: "resolved" },
        { delivery_id: "unrelated-bad-token", status: "active" },
      ],
      "only matching BadDeviceToken evidence observed no later than the APNs 2xx is resolved",
    );
    await adapter.database.batch([
      adapter.database
        .prepare(
          `INSERT INTO alert_delivery_failures (
            delivery_id, token_hash, event_ref, source_id, notification_reason,
            apns_status, apns_reason, disposition, status,
            first_seen_utc, last_seen_utc, registration_revision
          ) VALUES (
            'serialized-after-success', ?, 'jma_eew:after-success',
            'jma_eew', 'new', 400, 'BadDeviceToken', 'quarantine', 'active',
            ?, ?, 'after-success-registration-revision'
          )`,
        )
        .bind(tokenHash, oldTime, oldTime),
    ]);
    assert.deepEqual(
      adapter.all(
        `SELECT status FROM alert_delivery_failures
         WHERE delivery_id = 'serialized-after-success'`,
      ),
      [{ status: "active" }],
      "a quarantine serialized after the success remains active even with an older wall-clock timestamp",
    );
  } finally {
    adapter?.close();
    await rm(stateDirectory, { recursive: true, force: true });
  }
});

test("fallback BadDeviceToken evidence joins a newer same-token row before setting retention", async () => {
  const { recordDeliveryFailure } = await workerModule();
  const token = "fallback-retention-race-token";
  const tokenHash = createHash("sha256").update(token).digest("hex");
  const sentAt = "2026-08-12T00:00:00.000Z";
  const renewedAt = "2099-08-12T00:00:00.000Z";
  const stateDirectory = await mkdtemp(join(tmpdir(), "quakesignal-bad-token-fallback-retention-"));
  let adapter;
  try {
    const localArguments = ["--local", "--persist-to", stateDirectory];
    runWrangler(["d1", "migrations", "apply", "quakesignal-production", ...localArguments]);
    const databaseFile = localD1File(stateDirectory);
    const seed = new DatabaseSync(databaseFile);
    try {
      seed.prepare(
        `INSERT INTO devices (
           token, environment, sources, min_magnitude, critical_alerts_enabled,
           include_test_alerts, notify_at_night, created_at, updated_at
         ) VALUES (?, 'production', '["jma_eew"]', 0, 0, 0, 1, ?, ?)`,
      ).run(token, sentAt, renewedAt);
    } finally {
      seed.close();
    }
    adapter = localD1Adapter(databaseFile);
    await recordDeliveryFailure(
      adapter.database,
      "logical-fallback-delivery",
      { id: "jma_eew:fallback-retention-race", sourceId: "jma_eew" },
      "new",
      token,
      tokenHash,
      "sent-registration-revision",
      sentAt,
      { ok: false, apnsId: null, status: 400, apnsReason: "BadDeviceToken" },
      "retry",
    );
    assert.deepEqual(
      adapter.all(
        `SELECT delivery_id, origin_delivery_id, last_seen_utc,
                registration_revision
         FROM alert_delivery_failures`,
      ),
      [{
        delivery_id: "bad-device-token-revision:sent-registration-revision",
        origin_delivery_id: "logical-fallback-delivery",
        last_seen_utc: renewedAt,
        registration_revision: "sent-registration-revision",
      }],
      "a fallback insert serialized after renewal cannot expire before that current device row",
    );
  } finally {
    adapter?.close();
    await rm(stateDirectory, { recursive: true, force: true });
  }
});

test("a fresh App Attest key cannot claim a legacy registration with an empty delete", async () => {
  const { handleDeviceDeletion } = await workerModule();
  const response = await handleDeviceDeletion(
    new Request("https://quakesignal-api.hopeso.workers.dev/v1/devices", { method: "DELETE" }),
    /** The handler returns before reading any bindings for this unsafe shape. */
    {},
    { body: {}, bytes: new TextEncoder().encode("{}") },
    {
      mode: "attested",
      keyId: "fresh-key",
      appRoute: {
        appIdentity: "5TT564H883.com.quakesignal.app",
        apnsTopic: "com.quakesignal.app",
        platform: "ios",
      },
      verification: { proofType: "attestation" },
    },
  );
  assert.equal(response.status, 409);
  assert.equal(response.headers.get("cache-control"), "no-store");
});

test("key-bound deletion fences a renewal committed after its JS ownership pre-read", async () => {
  const { completeAttestedKeyBoundDeletion } = await workerModule();
  const keyId = "transaction-time-delete-fence-key";
  const token = "transaction-time-delete-fence-token";
  const now = "2026-08-12T00:00:00.000Z";
  const renewedRevision = "transaction-time-renewed-revision";
  const stateDirectory = await mkdtemp(join(tmpdir(), "quakesignal-delete-fence-race-"));
  let adapter;
  try {
    const localArguments = ["--local", "--persist-to", stateDirectory];
    runWrangler(["d1", "migrations", "apply", "quakesignal-production", ...localArguments]);
    const databaseFile = localD1File(stateDirectory);
    const deletionAuthorization = authorization(keyId, "assertion");
    deletionAuthorization.challenge.operation = "device-deletion";
    deletionAuthorization.challenge.method = "DELETE";
    deletionAuthorization.challenge.path = "/v1/devices";
    const seed = new DatabaseSync(databaseFile);
    try {
      seedKey(seed, keyId, now);
      seed.prepare(
        `INSERT INTO devices (
           token, environment, sources, min_magnitude,
           critical_alerts_enabled, include_test_alerts, notify_at_night,
           app_attest_key_id, created_at, updated_at
         ) VALUES (?, 'production', '["jma_eew"]', 0, 0, 0, 1, ?, ?, ?)`,
      ).run(token, keyId, now, now);
      seedChallenge(seed, deletionAuthorization.challenge, now);
    } finally {
      seed.close();
    }
    adapter = localD1Adapter(databaseFile);
    let injectedRenewal = false;
    const racingDatabase = {
      prepare: adapter.database.prepare,
      async batch(statements) {
        if (!injectedRenewal) {
          injectedRenewal = true;
          adapter.run(
            `UPDATE devices
             SET registration_revision = ?, updated_at = ?
             WHERE app_attest_key_id = ?`,
            renewedRevision,
            "2026-08-12T00:00:00.001Z",
            keyId,
          );
        }
        return adapter.database.batch(statements);
      },
    };
    assert.equal(
      await completeAttestedKeyBoundDeletion(
        racingDatabase,
        deletionAuthorization,
      ),
      "completed",
    );
    assert.deepEqual(adapter.all("SELECT COUNT(*) AS count FROM devices"), [{ count: 0 }]);
    assert.deepEqual(
      adapter.all(
        `SELECT decision_kind, blocks_lifecycle_replay
         FROM apns_registration_revision_fences
         WHERE registration_revision = ?`,
        renewedRevision,
      ),
      [{ decision_kind: "explicit_removal", blocks_lifecycle_replay: 1 }],
      "the transaction-time SELECT fences the revision actually removed",
    );
  } finally {
    adapter?.close();
    await rm(stateDirectory, { recursive: true, force: true });
  }
});

test("tokenless key-bound deletion removes same-token lifecycle provenance from an old key", async () => {
  const {
    completeAttestedKeyBoundDeletion,
    deactivateBadDeviceToken,
  } = await workerModule();
  const keyId = "current-key-bound-deletion-key";
  const oldKeyId = "old-lifecycle-provenance-key";
  const token = "key-bound-lifecycle-token";
  const tokenHash = createHash("sha256").update(token).digest("hex");
  const now = "2026-08-12T00:00:00.000Z";
  const stateDirectory = await mkdtemp(join(tmpdir(), "quakesignal-key-bound-lifecycle-"));
  let adapter;

  try {
    const localArguments = ["--local", "--persist-to", stateDirectory];
    runWrangler(["d1", "migrations", "apply", "quakesignal-production", ...localArguments]);
    const databaseFile = localD1File(stateDirectory);
    const deletionAuthorization = authorization(keyId, "assertion");
    deletionAuthorization.challenge.operation = "device-deletion";
    deletionAuthorization.challenge.method = "DELETE";
    deletionAuthorization.challenge.path = "/v1/devices";
    const seed = new DatabaseSync(databaseFile);
    try {
      seedKey(seed, keyId, now);
      seed
        .prepare(
          `INSERT INTO devices (
            token, environment, sources, min_magnitude, critical_alerts_enabled,
            include_test_alerts, notify_at_night, app_attest_key_id, created_at, updated_at
          ) VALUES (?, 'production', '["jma_eew"]', 0, 0, 0, 1, ?, ?, ?)`,
        )
        .run(token, keyId, now, now);
      seed
        .prepare(
          `INSERT INTO alert_lifecycle_recipients (
            event_ref, token_hash, app_attest_key_id,
            first_evidence_at_utc, last_evidence_at_utc
          ) VALUES ('jma_eew:old-key-provenance', ?, ?, ?, ?)`,
        )
        .run(tokenHash, oldKeyId, now, now);
      seedChallenge(seed, deletionAuthorization.challenge, now);
    } finally {
      seed.close();
    }

    adapter = localD1Adapter(databaseFile);
    const removedRevision = adapter.all(
      "SELECT registration_revision FROM devices WHERE token = ?",
      token,
    )[0].registration_revision;
    assert.equal(
      await completeAttestedKeyBoundDeletion(
        adapter.database,
        deletionAuthorization,
      ),
      "completed",
    );
    assert.deepEqual(adapter.all("SELECT COUNT(*) AS count FROM devices"), [{ count: 0 }]);
    assert.deepEqual(
      adapter.all("SELECT COUNT(*) AS count FROM alert_lifecycle_recipients"),
      [{ count: 0 }],
      "token-hash provenance must not survive a proved tokenless removal",
    );
    assert.deepEqual(
      adapter.all(
        `SELECT registration_revision, decision_kind, blocks_lifecycle_replay
         FROM apns_registration_revision_fences
         WHERE registration_revision = ?`,
        removedRevision,
      ),
      [{
        registration_revision: removedRevision,
        decision_kind: "explicit_removal",
        blocks_lifecycle_replay: 1,
      }],
      "explicit deletion must fence the removed revision before its row disappears",
    );
    adapter.run(
      `INSERT INTO devices (
         token, environment, sources, min_magnitude, critical_alerts_enabled,
         include_test_alerts, notify_at_night, created_at, updated_at
       ) VALUES (?, 'production', '["jma_eew"]', 0, 0, 0, 1, ?, ?)`,
      token,
      now,
      now,
    );
    const replacementRevision = adapter.all(
      "SELECT registration_revision FROM devices WHERE token = ?",
      token,
    )[0].registration_revision;
    assert.equal(
      await deactivateBadDeviceToken(
        adapter.database,
        { token, registrationRevision: removedRevision },
        { id: "jma_eew:old-response-after-delete", sourceId: "jma_eew" },
        "new",
        "old-response-after-explicit-delete",
      ),
      "not_found",
    );
    assert.deepEqual(
      adapter.all("SELECT registration_revision FROM devices WHERE token = ?", token),
      [{ registration_revision: replacementRevision }],
      "a delayed response for the deliberately removed revision cannot delete or quarantine its reincarnation",
    );
  } finally {
    adapter?.close();
    await rm(stateDirectory, { recursive: true, force: true });
  }
});

test("development App Attest verification is an exact, fail-closed opt-in", async () => {
  const {
    appAttestAllowedValidationCategories,
    appAttestVerificationEnvironment,
  } = await workerModule();

  assert.equal(
    appAttestVerificationEnvironment({
      APP_ATTEST_ENFORCEMENT: "development",
      APP_ATTEST_DEVELOPMENT_ENVIRONMENT: "true",
    }),
    "development",
  );
  for (const environment of [
    {
      APP_ATTEST_ENFORCEMENT: "required",
      APP_ATTEST_DEVELOPMENT_ENVIRONMENT: "true",
    },
    { APP_ATTEST_ENFORCEMENT: "development" },
    {
      APP_ATTEST_ENFORCEMENT: "development",
      APP_ATTEST_DEVELOPMENT_ENVIRONMENT: "TRUE",
    },
  ]) {
    assert.equal(
      appAttestVerificationEnvironment(environment),
      "production",
      "a non-exact setting must keep the production AAGUID verifier",
    );
  }
  assert.deepEqual(
    [...appAttestAllowedValidationCategories("development")],
    [3],
    "only a development verifier may accept Apple's category 3 metadata",
  );
  assert.deepEqual(
    [...appAttestAllowedValidationCategories("production")],
    [2, 4],
    "the release verifier must continue to allow only TestFlight/App Store metadata",
  );
});

test("a development verifier persists development App Attest key material", async () => {
  const { completeAttestedRegistration } = await workerModule();
  const keyId = "development-app-attest-key";
  const now = "2026-08-12T00:00:00.000Z";
  const stateDirectory = await mkdtemp(join(tmpdir(), "quakesignal-app-attest-development-"));
  let adapter;

  try {
    runWrangler([
      "d1",
      "migrations",
      "apply",
      "quakesignal-production",
      "--local",
      "--persist-to",
      stateDirectory,
    ]);
    const databaseFile = localD1File(stateDirectory);
    const developmentAuthorization = authorization(keyId, "attestation", "development");
    const seed = new DatabaseSync(databaseFile);
    try {
      seedChallenge(seed, developmentAuthorization.challenge, now, "development");
    } finally {
      seed.close();
    }

    adapter = localD1Adapter(databaseFile);
    const outcome = await completeAttestedRegistration(
      adapter.database,
      developmentAuthorization,
      registrationValues("development-debug-token", now, "sandbox"),
    );
    assert.equal(outcome, "completed");
    assert.deepEqual(
      adapter.all(
        "SELECT environment FROM app_attest_keys WHERE key_id = ?",
        keyId,
      ),
      [{ environment: "development" }],
      "a verified development AAGUID must never be persisted as production material",
    );
  } finally {
    adapter?.close();
    await rm(stateDirectory, { recursive: true, force: true });
  }
});

test("APNs registration environments are bound to verified App Attest environments", async () => {
  const {
    apnsDeviceEnvironmentForWorker,
    apnsEnvironmentForAppAttestEnvironment,
    apnsEnvironmentForAuthorizedDeviceMutation,
    completeAttestedRegistration,
  } = await workerModule();

  assert.equal(apnsEnvironmentForAppAttestEnvironment("development"), "sandbox");
  assert.equal(apnsEnvironmentForAppAttestEnvironment("production"), "production");
  assert.equal(
    apnsEnvironmentForAuthorizedDeviceMutation({ mode: "development_bypass" }),
    "sandbox",
    "a local-only bypass can never create a production APNs registration",
  );
  assert.equal(
    apnsDeviceEnvironmentForWorker({
      APP_ATTEST_ENFORCEMENT: "development",
      APP_ATTEST_DEVELOPMENT_ENVIRONMENT: "true",
    }),
    "sandbox",
  );
  assert.equal(
    apnsDeviceEnvironmentForWorker({ APP_ATTEST_ENFORCEMENT: "required" }),
    "production",
  );

  const now = "2026-08-14T00:00:00.000Z";
  const stateDirectory = await mkdtemp(join(tmpdir(), "quakesignal-app-attest-apns-environment-"));
  let adapter;

  try {
    runWrangler([
      "d1",
      "migrations",
      "apply",
      "quakesignal-production",
      "--local",
      "--persist-to",
      stateDirectory,
    ]);
    const databaseFile = localD1File(stateDirectory);
    const developmentAuthorization = authorization(
      "development-environment-key",
      "attestation",
      "development",
    );
    const productionAuthorization = authorization(
      "production-environment-key",
      "attestation",
      "production",
    );
    const seed = new DatabaseSync(databaseFile);
    try {
      seedChallenge(seed, developmentAuthorization.challenge, now, "development");
      seedChallenge(seed, productionAuthorization.challenge, now, "production");
    } finally {
      seed.close();
    }

    adapter = localD1Adapter(databaseFile);
    assert.equal(
      await completeAttestedRegistration(
        adapter.database,
        developmentAuthorization,
        registrationValues("development-proof-production-token", now, "production"),
      ),
      "conflict",
      "a development proof must not create a production APNs registration",
    );
    assert.equal(
      await completeAttestedRegistration(
        adapter.database,
        productionAuthorization,
        registrationValues("production-proof-sandbox-token", now, "sandbox"),
      ),
      "conflict",
      "a production proof must not create a sandbox APNs registration",
    );
    assert.deepEqual(
      adapter.all(
        "SELECT key_id, consumed_at_utc FROM app_attest_challenges ORDER BY key_id",
      ),
      [
        { key_id: "development-environment-key", consumed_at_utc: null },
        { key_id: "production-environment-key", consumed_at_utc: null },
      ],
      "a rejected cross-environment registration must not consume its challenge",
    );
    assert.deepEqual(
      adapter.all("SELECT key_id FROM app_attest_keys ORDER BY key_id"),
      [],
      "a rejected cross-environment registration must not persist integrity material",
    );
    assert.deepEqual(
      adapter.all("SELECT token FROM devices ORDER BY token"),
      [],
      "a rejected cross-environment registration must not persist an APNs token",
    );
  } finally {
    adapter?.close();
    await rm(stateDirectory, { recursive: true, force: true });
  }
});
