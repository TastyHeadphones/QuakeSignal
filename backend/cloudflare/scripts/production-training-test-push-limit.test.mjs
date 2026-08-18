import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
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

/** Preserve D1 batch order and change-count behavior under a real SQLite transaction. */
function localD1Adapter(databaseFile) {
  const sqlite = new DatabaseSync(databaseFile);
  const database = {
    prepare(sql) {
      return {
        sql,
        bindings: [],
        bind(...bindings) {
          return { sql, bindings };
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
            `claim-batch entry ${index} must be a prepared SQL statement`,
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
          // Keep the original SQL failure, which is more useful to diagnose.
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

function seedKey(sqlite, keyId, now) {
  sqlite
    .prepare(
      `INSERT INTO app_attest_keys (
        key_id, public_key_pem, sign_count, app_id, environment,
        receipt_base64, attested_at_utc
      ) VALUES (?, ?, 0, ?, 'production', ?, ?)`,
    )
    .run(
      keyId,
      `pem-${keyId}`,
      "5TT564H883.com.quakesignal.app",
      `receipt-${keyId}`,
      now,
    );
}

function seedProductionDevice(sqlite, token, keyId, now) {
  sqlite
    .prepare(
      `INSERT INTO devices (
        token, environment, sources, min_magnitude, critical_alerts_enabled,
        include_test_alerts, notify_at_night, app_attest_key_id, created_at, updated_at
      ) VALUES (?, 'production', '["jma_eew"]', 0, 0, 0, 1, ?, ?, ?)`,
    )
    .run(token, keyId, now, now);
}

function authorization(keyId, signCount, challengeId) {
  const challenge = {
    id: challengeId,
    keyId,
    wireKeyId: `wire-${keyId}`,
    challenge: `nonce-${challengeId}`,
    operation: "test-push",
    method: "POST",
    path: "/v1/devices/test",
    bodySha256: `body-${challengeId}`,
    requiredProof: "assertion",
  };
  return {
    mode: "attested",
    keyId,
    appRoute: {
      appIdentity: "5TT564H883.com.quakesignal.app",
      apnsTopic: "com.quakesignal.app",
      platform: "ios",
    },
    challenge,
    verification: {
      proofType: "assertion",
      signCount,
      metadata: null,
    },
  };
}

function seedChallenge(sqlite, challenge, now) {
  sqlite
    .prepare(
      `INSERT INTO app_attest_challenges (
        id, key_id, wire_key_id, operation, method, path, body_sha256,
        challenge, required_proof, environment, created_at_utc, expires_at_utc
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'production', ?, ?)`,
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
      now,
      "2099-01-01T00:00:00.000Z",
    );
}

test("production training push claims shared by immediate and delayed modes are atomic, key-bound, UTC-bounded, and token-free", async () => {
  const {
    completeAttestedProductionTrainingTestPushClaim,
    productionTrainingTestPushLimitResponse,
    productionTrainingTestPushRetentionCleanupStatement,
    productionTrainingTestPushWindow,
  } = await workerModule();
  const keyId = "training-test-key";
  const foreignKeyId = "foreign-training-test-key";
  const token = "production-training-test-token";
  const firstAttemptAt = new Date("2026-08-12T23:59:59.250Z");
  const sameDayAttemptAt = new Date("2026-08-12T23:59:59.750Z");
  const nextDayAttemptAt = new Date("2026-08-13T00:00:00.000Z");
  const stateDirectory = await mkdtemp(join(tmpdir(), "quakesignal-training-claim-"));
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
    const seed = new DatabaseSync(databaseFile);
    try {
      seedKey(seed, keyId, firstAttemptAt.toISOString());
      seedKey(seed, foreignKeyId, firstAttemptAt.toISOString());
      seedProductionDevice(seed, token, keyId, firstAttemptAt.toISOString());
      for (const [signCount, challengeId] of [
        [1, "training-claim-first"],
        [2, "training-claim-same-day"],
        [3, "training-claim-next-day"],
      ]) {
        seedChallenge(
          seed,
          authorization(keyId, signCount, challengeId).challenge,
          firstAttemptAt.toISOString(),
        );
      }
      seedChallenge(
        seed,
        authorization(foreignKeyId, 1, "training-claim-foreign").challenge,
        firstAttemptAt.toISOString(),
      );
    } finally {
      seed.close();
    }

    adapter = localD1Adapter(databaseFile);
    assert.deepEqual(productionTrainingTestPushWindow(firstAttemptAt), {
      utcDay: "2026-08-12",
      resetAtUtc: "2026-08-13T00:00:00.000Z",
      retryAfterSeconds: 1,
      expiresAtUtc: "2026-08-26T23:59:59.250Z",
    });

    const first = await completeAttestedProductionTrainingTestPushClaim(
      adapter.database,
      authorization(keyId, 1, "training-claim-first"),
      token,
      firstAttemptAt,
    );
    assert.equal(first.outcome, "claimed");

    const sameDay = await completeAttestedProductionTrainingTestPushClaim(
      adapter.database,
      authorization(keyId, 2, "training-claim-same-day"),
      token,
      sameDayAttemptAt,
    );
    assert.equal(
      sameDay.outcome,
      "already_claimed",
      "the second valid assertion is consumed but cannot dispatch another same-day production push",
    );
    const limited = productionTrainingTestPushLimitResponse(sameDay.window);
    assert.equal(limited.status, 429);
    assert.equal(limited.headers.get("cache-control"), "no-store");
    assert.equal(limited.headers.get("retry-after"), "1");
    assert.deepEqual(await limited.json(), {
      error: "production training test push limit reached; try again after the next UTC day begins",
      retryAtUtc: "2026-08-13T00:00:00.000Z",
    });

    assert.deepEqual(
      adapter.all(
        "SELECT sign_count FROM app_attest_keys WHERE key_id = ?",
        keyId,
      ),
      [{ sign_count: 2 }],
      "both proof attempts update the App Attest counter in their transactions",
    );
    assert.deepEqual(
      adapter.all(
        `SELECT id, consumed_at_utc FROM app_attest_challenges
         WHERE id IN ('training-claim-first', 'training-claim-same-day')
         ORDER BY id`,
      ),
      [
        { id: "training-claim-first", consumed_at_utc: firstAttemptAt.toISOString() },
        { id: "training-claim-same-day", consumed_at_utc: sameDayAttemptAt.toISOString() },
      ],
      "the counter, challenge consumption, and claim share each D1 transaction",
    );
    assert.deepEqual(
      adapter.all(
        "SELECT app_attest_key_id, utc_day FROM production_training_test_push_claims",
      ),
      [{ app_attest_key_id: keyId, utc_day: "2026-08-12" }],
    );
    assert.deepEqual(
      adapter
        .all("PRAGMA table_info(production_training_test_push_claims)")
        .map(({ name }) => name),
      ["app_attest_key_id", "utc_day", "claimed_at_utc", "expires_at_utc"],
      "the durable claim table contains no raw APNs token, proof, or request body",
    );

    const foreign = await completeAttestedProductionTrainingTestPushClaim(
      adapter.database,
      authorization(foreignKeyId, 1, "training-claim-foreign"),
      token,
      sameDayAttemptAt,
    );
    assert.equal(foreign.outcome, "conflict");
    assert.deepEqual(
      adapter.all(
        "SELECT consumed_at_utc FROM app_attest_challenges WHERE id = 'training-claim-foreign'",
      ),
      [{ consumed_at_utc: null }],
      "a key without the bound production registration cannot consume a claim or proof",
    );

    const nextDay = await completeAttestedProductionTrainingTestPushClaim(
      adapter.database,
      authorization(keyId, 3, "training-claim-next-day"),
      token,
      nextDayAttemptAt,
    );
    assert.equal(nextDay.outcome, "claimed");
    assert.deepEqual(
      adapter.all(
        `SELECT utc_day FROM production_training_test_push_claims
         WHERE app_attest_key_id = ? ORDER BY utc_day`,
        keyId,
      ),
      [{ utc_day: "2026-08-12" }, { utc_day: "2026-08-13" }],
      "a new UTC day, not the device locale, permits one new training push claim",
    );

    await adapter.database.batch([
      productionTrainingTestPushRetentionCleanupStatement(
        adapter.database,
        "2026-08-26T23:59:59.250Z",
      ),
    ]);
    assert.deepEqual(
      adapter.all(
        `SELECT utc_day FROM production_training_test_push_claims
         WHERE app_attest_key_id = ? ORDER BY utc_day`,
        keyId,
      ),
      [{ utc_day: "2026-08-13" }],
      "the expired claim is safely purged while the later bounded-retention claim remains",
    );
  } finally {
    adapter?.close();
    await rm(stateDirectory, { recursive: true, force: true });
  }
});
