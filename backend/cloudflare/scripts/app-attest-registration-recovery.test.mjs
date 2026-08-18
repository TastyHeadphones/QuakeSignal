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
    all(sql, ...bindings) {
      return sqlite.prepare(sql).all(...bindings).map((row) => ({ ...row }));
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

test("same-key APNs token rotation removes old delivery evidence atomically", async () => {
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
            disposition, first_seen_utc, last_seen_utc
          ) VALUES ('old-token-delivery', ?, 'jma_eew:old', 'jma_eew', 'new',
                    'quarantine', ?, ?)`,
        )
        .run(tokenHash, now, now);
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
      adapter.all("SELECT COUNT(*) AS count FROM alert_delivery_failures"),
      [{ count: 0 }],
      "an active failure for a retired token must not falsely degrade readiness",
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
