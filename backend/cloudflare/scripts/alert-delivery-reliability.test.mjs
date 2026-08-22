import assert from "node:assert/strict";
import { mkdtemp, readFile, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { spawnSync } from "node:child_process";
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
    // Node keeps an imported ESM bundle open for this short test process. Do
    // not remove its directory before the module's tests finish.
    return import(pathToFileURL(outfile).href);
  })();
  return workerModulePromise;
}

async function sha256Hex(value) {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(value),
  );
  return Buffer.from(digest).toString("hex");
}

function mutableApnsDeviceDatabase(initialRow) {
  let currentRow = { ...initialRow };
  let appAttestKeyPresent = true;
  const badDeviceTokenQuarantines = new Set();
  const processedRegistrationRevisions = new Set();
  const batches = [];
  return {
    database: {
      prepare(sql) {
        const prepared = {
          sql,
          bindings: [],
          bind(...bindings) {
            return {
              sql,
              bindings,
              async all() {
                if (sql.includes("SELECT rowid AS cursor, * FROM devices")) {
                  return { results: currentRow === null ? [] : [{ ...currentRow }] };
                }
                if (
                  sql.includes("FROM notification_deliveries")
                ) return { results: [] };
                if (sql.includes("FROM alert_delivery_failures")) {
                  return {
                    results: [...badDeviceTokenQuarantines]
                      .filter((tokenHash) => bindings.includes(tokenHash))
                      .map((token_hash) => ({ token_hash })),
                  };
                }
                throw new Error(`unexpected APNs device query: ${sql}`);
              },
              async first() {
                if (sql.includes("SELECT updated_at FROM devices")) {
                  return currentRow === null
                    ? null
                    : { updated_at: currentRow.updated_at };
                }
                throw new Error(`unexpected APNs device lookup: ${sql}`);
              },
            };
          },
        };
        return prepared;
      },
      async batch(statements) {
        batches.push(statements);
        const claimedRegistrationRevisions = new Set();
        return statements.map(({ sql, bindings = [] }) => {
          let changes = 0;
          if (
            sql.includes("INSERT INTO apns_registration_revision_fences") &&
            sql.includes("VALUES (?, ?, ?, ?, 'bad_device_token'")
          ) {
            const registrationRevision = bindings[1];
            if (!processedRegistrationRevisions.has(registrationRevision)) {
              processedRegistrationRevisions.add(registrationRevision);
              claimedRegistrationRevisions.add(registrationRevision);
              changes = 1;
            }
          } else if (
            sql.includes("DELETE FROM alert_delivery_failures") &&
            sql.includes("registration_revision = ?")
          ) {
            const [tokenHash, token, registrationRevision] = bindings;
            if (
              currentRow !== null &&
              currentRow.token === token &&
              currentRow.registration_revision === registrationRevision
            ) {
              badDeviceTokenQuarantines.delete(tokenHash);
            }
          } else if (
            sql.includes("DELETE FROM devices") &&
            sql.includes("registration_revision = ?")
          ) {
            const [token, registrationRevision] = bindings;
            if (
              currentRow !== null &&
              currentRow.token === token &&
              currentRow.registration_revision === registrationRevision
            ) {
              currentRow = null;
              changes = 1;
            }
          } else if (
            sql.includes("INSERT INTO alert_delivery_failures") &&
            sql.includes("FROM devices") &&
            sql.includes("registration_revision <> ?")
          ) {
            const token = bindings.at(-4);
            const sentRegistrationRevision = bindings.at(-3);
            if (
              currentRow !== null &&
              currentRow.token === token &&
              currentRow.registration_revision !== sentRegistrationRevision &&
              claimedRegistrationRevisions.has(sentRegistrationRevision)
            ) {
              badDeviceTokenQuarantines.add(bindings[2]);
              changes = 1;
            }
          } else if (sql.includes("DELETE FROM app_attest_keys")) {
            if (currentRow === null && appAttestKeyPresent) {
              appAttestKeyPresent = false;
              changes = 1;
            }
          }
          return { meta: { changes } };
        });
      },
    },
    get currentRow() {
      return currentRow;
    },
    set currentRow(value) {
      currentRow = value === null ? null : { ...value };
    },
    get appAttestKeyPresent() {
      return appAttestKeyPresent;
    },
    get badDeviceTokenQuarantineCount() {
      return badDeviceTokenQuarantines.size;
    },
    authenticatedRenewal(updatedAt) {
      currentRow = currentRow === null
        ? null
        : {
            ...currentRow,
            updated_at: updatedAt,
            registration_revision: `renewed:${updatedAt}`,
          };
      badDeviceTokenQuarantines.clear();
    },
    batches,
  };
}

function sqlLiteral(value) {
  if (value === null || value === undefined) return "NULL";
  if (typeof value === "number") return String(value);
  return `'${String(value).replaceAll("'", "''")}'`;
}

function bindSql(statement, bindings) {
  let index = 0;
  const sql = statement.replaceAll("?", () => sqlLiteral(bindings[index++]));
  assert.equal(index, bindings.length, "every generated SQL placeholder must bind once");
  return sql;
}

function capturedStatementDatabase() {
  let captured;
  return {
    database: {
      prepare(sql) {
        return {
          bind(...bindings) {
            captured = { sql, bindings };
            return { sql, bindings };
          },
        };
      },
    },
    get captured() {
      assert.ok(captured, "the outbox insert statement should bind values");
      return captured;
    },
  };
}

async function captureDlqBatch(worker, queueNames, {
  serial,
  queueMessageId,
  attempts = 5,
  incidentChanges = 1,
}) {
  const { QuakeRelay } = await workerModule();
  const batches = [];
  const logs = [];
  let acknowledged = 0;
  const originalConsoleError = console.error;
  const originalConsoleInfo = console.info;
  console.error = (entry) => logs.push({ level: "error", entry });
  console.info = (entry) => logs.push({ level: "info", entry });
  try {
    const database = {
      prepare(sql) {
        return {
          bind(...bindings) {
            return { sql, bindings };
          },
        };
      },
      async batch(statements) {
        batches.push(statements);
        return statements.map((_, index) => ({
          meta: { changes: index === 1 ? incidentChanges : 1 },
        }));
      },
    };
    const relay = new QuakeRelay(
      {
        storage: {
          async list() {
            return new Map();
          },
        },
      },
      { DB: database },
    );
    await worker.queue(
      {
        queue: queueNames.ALERT_DELIVERY_DLQ_NAME,
        messages: [{
          id: queueMessageId,
          attempts,
          body: message(serial),
          ack() {
            acknowledged += 1;
          },
          retry() {
            throw new Error("a successful D1 batch must acknowledge the DLQ message");
          },
        }],
      },
      {
        ...queueNames,
        DB: database,
        RELAY: {
          idFromName() {
            return "global";
          },
          get() {
            return {
              async fetch(request) {
                return relay.fetch(request);
              },
            };
          },
        },
      },
    );
  } finally {
    console.error = originalConsoleError;
    console.info = originalConsoleInfo;
  }
  assert.equal(acknowledged, 1, "a terminal or recorded DLQ message is acknowledged");
  assert.equal(batches.length, 1, "the DLQ decision must use one D1 batch");
  return { statements: batches[0], logs };
}

function runD1Batch(statements, localArguments) {
  // Wrangler's local D1 shell deliberately rejects SQL BEGIN/COMMIT. Execute
  // the already-captured statements in their production order here; the Worker
  // assertion above proves production sends that order as one atomic D1 batch.
  const sql = statements
    .map((statement) => bindSql(statement.sql, statement.bindings))
    .join(";\n");
  return runWrangler([
    "d1",
    "execute",
    "quakesignal-production",
    ...localArguments,
    "--command",
    sql,
  ]);
}

function outboxInsertSql(serial, {
  acknowledgedAt = null,
  finalStatus = null,
  terminalReason = null,
} = {}) {
  const createdAt = "2026-08-12T00:10:00.000Z";
  return `INSERT INTO alert_delivery_outbox (
    id, dedupe_key, delivery_id, root_delivery_id, event_ref, event_serial,
    notification_reason, event_json, created_at_utc, next_enqueue_at_utc,
    expires_at_utc, expiry_policy, acknowledged_at_utc, final_status,
    terminal_reason
  ) VALUES (
    'outbox-${serial}', 'dlq-guard-${serial}',
    'v1:jma_eew:example:${serial}:new', 'v1:jma_eew:example:${serial}:new',
    'jma_eew:example', ${serial}, 'new', '{}', '${createdAt}', '${createdAt}',
    '2026-08-12T00:30:00.000Z', 'eew_30m', ${sqlLiteral(acknowledgedAt)},
    ${sqlLiteral(finalStatus)}, ${sqlLiteral(terminalReason)}
  )`;
}

function pageFailureInsertSql(serial) {
  const createdAt = "2026-08-12T00:10:00.000Z";
  return `INSERT INTO alert_delivery_page_failures (
    outbox_id, delivery_id, root_delivery_id, event_ref, source_id,
    event_serial, notification_reason, status, first_seen_utc, last_seen_utc
  ) VALUES (
    'outbox-${serial}', 'v1:jma_eew:example:${serial}:new',
    'v1:jma_eew:example:${serial}:new', 'jma_eew:example', 'jma_eew',
    ${serial}, 'new', 'active', '${createdAt}', '${createdAt}'
  )`;
}

function runWrangler(arguments_) {
  const result = spawnSync(
    process.execPath,
    [wranglerEntrypoint, ...arguments_],
    {
      cwd: cloudflareDirectory,
      encoding: "utf8",
    },
  );
  assert.equal(
    result.status,
    0,
    `wrangler ${arguments_.join(" ")} failed:\n${result.stderr}\n${result.stdout}`,
  );
  return result.stdout;
}

function d1Results(json) {
  const value = JSON.parse(json);
  assert.ok(Array.isArray(value) && value.length > 0, "D1 must return JSON results");
  return value[0].results;
}

function message(serial, reason = "new") {
  return {
    version: 1,
    outboxId: `outbox-${serial}`,
    deliveryId: `v1:jma_eew:example:${serial}:${reason}`,
    rootDeliveryId: `v1:jma_eew:example:${serial}:${reason}`,
    event: {
      id: "jma_eew:example",
      eventId: "example",
      sourceId: "jma_eew",
      serial,
      kind: "eew",
      originTimeUtc: "2026-08-12T00:00:00.000Z",
      reportTimeUtc: "2026-08-12T00:00:00.000Z",
      hypocenter: "Test Region",
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
    },
    reason,
    expiresAtUtc: "2026-08-12T00:30:00.000Z",
    expiryPolicy: "eew_30m",
  };
}

test("classifies provider/topic failures at page scope and keeps true device outcomes isolated", async () => {
  const { isPageLevelApnsFailure } = await workerModule();
  for (const apnsReason of [
    "InvalidProviderToken",
    "MissingProviderToken",
    "TopicDisallowed",
    "DeviceTokenNotForTopic",
    "PayloadTooLarge",
    "TooManyProviderTokenUpdates",
    "TransportError",
  ]) {
    assert.equal(
      isPageLevelApnsFailure({
        ok: false,
        apnsId: null,
        status: apnsReason === "TooManyProviderTokenUpdates" ? 429 : 403,
        apnsReason,
      }),
      true,
      `${apnsReason} must retain a page-level retry/DLQ incident`,
    );
  }
  assert.equal(
    isPageLevelApnsFailure({ ok: false, apnsId: null, status: 400, apnsReason: "BadDeviceToken" }),
    false,
  );
  assert.equal(
    isPageLevelApnsFailure({ ok: false, apnsId: null, status: 429, apnsReason: "TooManyRequests" }),
    false,
  );
  assert.equal(
    isPageLevelApnsFailure({
      ok: false,
      apnsId: null,
      status: 410,
      terminalUnregistration: true,
    }), false);
});

test("bounds hung APNs operations and clears the success timer", async () => {
  const {
    ApnsRequestTimeoutError,
    isPageLevelApnsFailure,
    withApnsRequestTimeout,
  } = await workerModule();
  let completedSignal;
  assert.equal(
    await withApnsRequestTimeout(async (signal) => {
      completedSignal = signal;
      return "delivered";
    }, 20),
    "delivered",
  );
  // If the success path leaked its timer, this signal would later abort.
  await new Promise((resolve) => setTimeout(resolve, 40));
  assert.equal(completedSignal.aborted, false);

  let timeoutSignal;
  await assert.rejects(
    withApnsRequestTimeout(
      (signal) => {
        timeoutSignal = signal;
        return new Promise(() => {});
      },
      5,
    ),
    (error) => error instanceof ApnsRequestTimeoutError,
  );
  assert.equal(timeoutSignal.aborted, true);
  assert.equal(
    isPageLevelApnsFailure({
      ok: false,
      apnsId: null,
      apnsReason: "TransportError",
    }),
    true,
    "a timed-out APNs request must follow the page retry/DLQ path",
  );
});

test("automatic production delivery skips sandbox and unfiltered registrations", async () => {
  const { dispatchPushPage } = await workerModule();
  const originalFetch = globalThis.fetch;
  const deviceRows = [
    {
      cursor: 1,
      token: "historical-sandbox-token",
      environment: "sandbox",
      locale: null,
      sources: '["jma_eew"]',
      min_magnitude: 0,
      critical_alerts_enabled: 0,
      city_name: null,
      latitude: null,
      longitude: null,
      radius_km: null,
      include_test_alerts: 1,
      utc_offset_minutes: null,
      notify_at_night: 1,
      created_at: "2026-08-14T00:00:00.000Z",
      updated_at: "2026-08-14T00:00:00.000Z",
    },
    {
      cursor: 2,
      token: "current-production-token",
      environment: "production",
      locale: null,
      sources: '["jma_eew"]',
      min_magnitude: 0,
      critical_alerts_enabled: 0,
      city_name: null,
      latitude: null,
      longitude: null,
      radius_km: null,
      include_test_alerts: 1,
      utc_offset_minutes: null,
      notify_at_night: 1,
      created_at: "2026-08-14T00:00:00.000Z",
      updated_at: "2026-08-14T00:00:00.000Z",
    },
    {
      cursor: 3,
      token: "nearby-production-token",
      environment: "production",
      locale: null,
      sources: '["jma_eew"]',
      min_magnitude: 0,
      critical_alerts_enabled: 0,
      city_name: "Test City",
      latitude: 35,
      longitude: 135,
      radius_km: 100,
      include_test_alerts: 1,
      utc_offset_minutes: null,
      notify_at_night: 1,
      created_at: "2026-08-14T00:00:00.000Z",
      updated_at: "2026-08-14T00:00:00.000Z",
    },
  ];
  const pageQueries = [];
  const deliveredBatches = [];
  const apnsUrls = [];
  const database = {
    prepare(sql) {
      return {
        bind(...bindings) {
          return {
            sql,
            bindings,
            async all() {
              if (sql.includes("SELECT rowid AS cursor, * FROM devices")) {
                pageQueries.push({ sql, bindings });
                const [afterCursor, environment] = bindings;
                return {
                  results: deviceRows.filter(
                    (row) => row.cursor > afterCursor && row.environment === environment,
                  ),
                };
              }
              if (
                sql.includes("FROM notification_deliveries") ||
                sql.includes("FROM alert_delivery_failures")
              ) {
                return { results: [] };
              }
              throw new Error(`unexpected automatic delivery query: ${sql}`);
            },
          };
        },
      };
    },
    async batch(statements) {
      deliveredBatches.push(statements);
      return statements.map(() => ({ meta: { changes: 1 } }));
    },
  };
  globalThis.fetch = async (url) => {
    apnsUrls.push(String(url));
    return new Response(null, { status: 200, headers: { "apns-id": "test-id" } });
  };

  try {
    const page = await dispatchPushPage(
      {
        APP_ATTEST_ENFORCEMENT: "required",
        DB: database,
        APNS_PRIVATE_KEY: "configured-for-page-filter-test",
        APNS_KEY_ID: "ABCDEFGHIJ",
        APNS_TEAM_ID: "ABCDEFGHIJ",
        APNS_BUNDLE_ID: "com.quakesignal.app",
      },
      {
        id: "jma_eew:automatic-filter-test",
        eventId: "automatic-filter-test",
        sourceId: "jma_eew",
        serial: 1,
        kind: "eew",
        originTimeUtc: "2026-08-14T00:00:00.000Z",
        reportTimeUtc: "2026-08-14T00:00:00.000Z",
        hypocenter: "Test Region",
        latitude: 35,
        longitude: 135,
        magnitude: 5.5,
        depth: 10,
        maxIntensity: "5-",
        isWarn: true,
        isFinal: false,
        isCancel: false,
        isTraining: false,
        tsunami: null,
        raw: null,
      },
      "new",
      "cached.provider.jwt",
      "automatic-filter-delivery",
    );

    assert.equal(page.nextAfterDeviceCursor, null);
    assert.equal(page.pageFailure, null);
    assert.equal(page.retryRequired, false);
    assert.equal(pageQueries.length, 1);
    assert.match(pageQueries[0].sql, /WHERE rowid > \? AND environment = \?/);
    assert.deepEqual(
      pageQueries[0].bindings,
      [0, "production", 1],
      "the production delivery page must filter before page-size pagination",
    );
    assert.deepEqual(apnsUrls, [
      "https://api.push.apple.com/3/device/nearby-production-token",
    ]);
    assert.equal(deliveredBatches.length, 1, "only the production delivery is recorded");
    const lifecycleUpsert = deliveredBatches[0].find(({ sql }) =>
      sql.includes("INSERT INTO alert_lifecycle_recipients")
    );
    assert.ok(lifecycleUpsert, "an APNs-accepted active warning records terminal continuity");
    assert.equal(
      lifecycleUpsert.bindings[1],
      await sha256Hex("nearby-production-token"),
    );
    assert.equal(lifecycleUpsert.bindings[5], null);
    assert.ok(lifecycleUpsert.bindings.includes("jma_eew:automatic-filter-test"));
    assert.equal(
      lifecycleUpsert.bindings.slice(0, 4).includes("nearby-production-token"),
      false,
      "the lifecycle table must never receive a raw APNs token",
    );
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("final and cancelled revisions preserve lifecycle across revised estimates but honor current source consent", async () => {
  const { dispatchPushPage } = await workerModule();
  const originalFetch = globalThis.fetch;
  const sameToken = "0011223344556677";
  const rotatedToken = "8899aabbccddeeff";
  const unrelatedToken = "1021324354657687";
  const continuityKey = "opaque-continuity-key";
  const rows = [
    {
      cursor: 1,
      token: sameToken,
      environment: "production",
      locale: null,
      sources: '["jma_eqlist"]',
      min_magnitude: 9,
      critical_alerts_enabled: 0,
      city_name: "Old selection",
      latitude: -30,
      longitude: -30,
      radius_km: 1,
      include_test_alerts: 0,
      utc_offset_minutes: null,
      notify_at_night: 1,
      app_attest_key_id: null,
      created_at: "2026-08-14T00:00:00.000Z",
      updated_at: "2026-08-14T00:00:00.000Z",
    },
    {
      cursor: 2,
      token: rotatedToken,
      environment: "production",
      locale: null,
      sources: '["jma_eew"]',
      min_magnitude: 9,
      critical_alerts_enabled: 0,
      city_name: "Rotated token",
      latitude: -30,
      longitude: -30,
      radius_km: 1,
      include_test_alerts: 0,
      utc_offset_minutes: null,
      notify_at_night: 1,
      app_attest_key_id: continuityKey,
      created_at: "2026-08-14T00:00:00.000Z",
      updated_at: "2026-08-14T00:05:00.000Z",
    },
    {
      cursor: 3,
      token: unrelatedToken,
      environment: "production",
      locale: null,
      sources: '["jma_eew"]',
      min_magnitude: 0,
      critical_alerts_enabled: 0,
      city_name: "Never warned",
      latitude: 35,
      longitude: 135,
      radius_km: 100,
      include_test_alerts: 1,
      utc_offset_minutes: null,
      notify_at_night: 1,
      app_attest_key_id: "unrelated-key",
      created_at: "2026-08-14T00:00:00.000Z",
      updated_at: "2026-08-14T00:00:00.000Z",
    },
  ];
  const sameTokenHash = await sha256Hex(sameToken);
  const requests = [];
  const recordedBatches = [];
  const database = {
    prepare(sql) {
      return {
        bind(...bindings) {
          return {
            sql,
            bindings,
            async all() {
              if (sql.includes("SELECT rowid AS cursor, * FROM devices")) {
                return { results: rows };
              }
              if (sql.includes("FROM alert_lifecycle_recipients")) {
                assert.equal(bindings[0], "jma_eew:lifecycle-continuity");
                assert.equal(
                  bindings.includes(sameTokenHash),
                  false,
                  "removing the EEW source must exclude the device before lifecycle lookup",
                );
                return {
                  results: [
                    {
                      token_hash: await sha256Hex("retired-apns-token"),
                      app_attest_key_id: continuityKey,
                    },
                  ],
                };
              }
              if (
                sql.includes("FROM notification_deliveries") ||
                sql.includes("FROM alert_delivery_failures")
              ) return { results: [] };
              throw new Error(`unexpected lifecycle query: ${sql}`);
            },
          };
        },
      };
    },
    async batch(statements) {
      recordedBatches.push(statements);
      return statements.map(() => ({ meta: { changes: 1 } }));
    },
  };
  globalThis.fetch = async (url) => {
    requests.push(String(url));
    return new Response(null, { status: 200 });
  };
  try {
    const environment = {
      APP_ATTEST_ENFORCEMENT: "required",
      DB: database,
      APNS_PRIVATE_KEY: "configured-lifecycle-test-key",
      APNS_KEY_ID: "ABCDEFGHIJ",
      APNS_TEAM_ID: "ABCDEFGHIJ",
      APNS_BUNDLE_ID: "com.quakesignal.app",
    };
    const terminalEvent = {
        id: "jma_eew:lifecycle-continuity",
        eventId: "lifecycle-continuity",
        sourceId: "jma_eew",
        serial: 9,
        kind: "eew",
        originTimeUtc: "2026-08-14T00:00:00.000Z",
        reportTimeUtc: "2026-08-14T00:10:00.000Z",
        hypocenter: "Revised far away",
        latitude: 60,
        longitude: 10,
        magnitude: 1,
        depth: 10,
        maxIntensity: "1",
        isWarn: false,
        isFinal: true,
        isCancel: false,
        isTraining: false,
        tsunami: null,
        raw: null,
    };
    for (const [reason, flags] of [
      ["final", { isFinal: true, isCancel: false }],
      ["cancelled", { isFinal: false, isCancel: true }],
    ]) {
      const page = await dispatchPushPage(
        environment,
        { ...terminalEvent, ...flags },
        reason,
        "cached.provider.jwt",
        `lifecycle-${reason}-delivery`,
      );
      assert.equal(page.retryRequired, false);
    }
    assert.deepEqual(requests, [
      `https://api.push.apple.com/3/device/${rotatedToken}`,
      `https://api.push.apple.com/3/device/${rotatedToken}`,
    ], "the opted-in rotated token receives closure despite downgraded magnitude/location; the source-removed token does not");
    assert.equal(recordedBatches.length, 2);
    assert.equal(
      recordedBatches.flat().some(({ sql }) =>
        sql.includes("INSERT INTO alert_lifecycle_recipients")
      ),
      false,
      "terminal delivery must not manufacture recipient eligibility",
    );
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("BadDeviceToken removes the exact invalid registration and stops future event fanout", async () => {
  const { deactivateBadDeviceToken, dispatchPushPage } = await workerModule();
  const originalFetch = globalThis.fetch;
  const originalConsoleWarn = console.warn;
  const token = "abcdef0123456789";
  const harness = mutableApnsDeviceDatabase({
    cursor: 1,
    token,
    environment: "production",
    locale: null,
    sources: '["jma_eew"]',
    min_magnitude: 0,
    critical_alerts_enabled: 0,
    alert_sound: "system",
    city_name: "Test City",
    latitude: 35,
    longitude: 135,
    radius_km: 100,
    include_test_alerts: 0,
    utc_offset_minutes: null,
    notify_at_night: 1,
    app_attest_key_id: "bad-token-key",
    registration_revision: "bad-token-sent-revision",
    created_at: "2026-08-20T00:00:00.000Z",
    updated_at: "2026-08-20T00:00:00.000Z",
  });
  const event = {
    id: "jma_eew:bad-device-token",
    eventId: "bad-device-token",
    sourceId: "jma_eew",
    serial: 1,
    kind: "eew",
    originTimeUtc: "2026-08-20T00:00:00.000Z",
    reportTimeUtc: "2026-08-20T00:00:00.000Z",
    hypocenter: "Test Region",
    latitude: 35,
    longitude: 135,
    magnitude: 5,
    depth: 10,
    maxIntensity: "4",
    isWarn: true,
    isFinal: false,
    isCancel: false,
    isTraining: false,
    tsunami: null,
    raw: null,
  };
  let apnsRequests = 0;
  const warnings = [];
  console.warn = (entry) => warnings.push(JSON.parse(String(entry)));
  globalThis.fetch = async () => {
    apnsRequests += 1;
    return Response.json(
      { reason: "BadDeviceToken" },
      { status: 400, headers: { "apns-id": "bad-token-response" } },
    );
  };
  const environment = {
    APP_ATTEST_ENFORCEMENT: "required",
    DB: harness.database,
    APNS_PRIVATE_KEY: "configured-bad-token-test-key",
    APNS_KEY_ID: "ABCDEFGHIJ",
    APNS_TEAM_ID: "ABCDEFGHIJ",
    APNS_BUNDLE_ID: "com.quakesignal.app",
  };
  try {
    const first = await dispatchPushPage(
      environment,
      event,
      "new",
      "cached.provider.jwt",
      "bad-token-delivery-1",
    );
    assert.equal(first.retryRequired, false, "Apple's terminal token response is not retried");
    assert.equal(first.pageFailure, null);
    assert.equal(harness.currentRow, null, "the exact invalid registration is removed");
    assert.equal(
      harness.appAttestKeyPresent,
      false,
      "orphan cleanup removes the verifier so the next client registration re-attests",
    );
    const cleanupStatements = harness.batches.flat();
    assert.ok(cleanupStatements.some(({ sql }) =>
      sql.includes("DELETE FROM devices") &&
      sql.includes("registration_revision = ?")
    ));
    assert.ok(cleanupStatements.some(({ sql }) =>
      sql.includes("DELETE FROM alert_delivery_failures") &&
      sql.includes("registration_revision = ?")
    ));
    assert.ok(
      cleanupStatements.some(({ sql }) =>
        sql.includes("INSERT OR IGNORE INTO apns_registration_revision_fences") &&
        sql.includes("'bad_device_token'") &&
        sql.includes("blocks_lifecycle_replay")
      ),
      "exact cleanup retains a dedicated processed-revision fence without degrading health",
    );
    assert.equal(harness.badDeviceTokenQuarantineCount, 0);
    assert.equal(warnings[0].deactivated, true);
    assert.equal(warnings[0].disposition, "terminal");

    const second = await dispatchPushPage(
      environment,
      { ...event, serial: 2, reportTimeUtc: "2026-08-20T00:01:00.000Z" },
      "updated",
      "cached.provider.jwt",
      "bad-token-delivery-2",
    );
    assert.equal(second.retryRequired, false);
    assert.equal(apnsRequests, 1, "a deleted bad token cannot re-enter later event fanout");

    harness.currentRow = {
      cursor: 2,
      token,
      environment: "production",
      locale: null,
      sources: '["jma_eew"]',
      min_magnitude: 0,
      critical_alerts_enabled: 0,
      alert_sound: "system",
      city_name: "Test City",
      latitude: 35,
      longitude: 135,
      radius_km: 100,
      include_test_alerts: 0,
      utc_offset_minutes: null,
      notify_at_night: 1,
      app_attest_key_id: "reincarnated-token-key",
      registration_revision: "reincarnated-registration-revision",
      created_at: "2026-08-20T00:00:00.000Z",
      updated_at: "2026-08-20T00:00:00.000Z",
    };
    const reincarnatedOutcome = await deactivateBadDeviceToken(
      harness.database,
      { token, registrationRevision: "reincarnated-registration-revision" },
      event,
      "new",
      "bad-token-delivery-1",
    );
    assert.equal(
      reincarnatedOutcome,
      "deleted",
      "the same deterministic delivery ID can independently process a second opaque revision",
    );
    harness.currentRow = {
      cursor: 3,
      token,
      environment: "production",
      locale: null,
      sources: '["jma_eew"]',
      min_magnitude: 0,
      critical_alerts_enabled: 0,
      alert_sound: "system",
      city_name: "Test City",
      latitude: 35,
      longitude: 135,
      radius_km: 100,
      include_test_alerts: 0,
      utc_offset_minutes: null,
      notify_at_night: 1,
      app_attest_key_id: "third-token-key",
      registration_revision: "third-registration-revision",
      created_at: "2026-08-20T00:00:00.000Z",
      updated_at: "2026-08-20T00:00:00.000Z",
    };
    const staleDuplicate = await deactivateBadDeviceToken(
      harness.database,
      { token, registrationRevision: "reincarnated-registration-revision" },
      event,
      "new",
      "bad-token-delivery-1",
    );
    assert.equal(staleDuplicate, "not_found");
    assert.equal(
      harness.currentRow.registration_revision,
      "third-registration-revision",
      "a second old response must not delete the re-registered row",
    );
    assert.equal(
      harness.badDeviceTokenQuarantineCount,
      0,
      "the processed-revision fence must not renew quarantine for a re-registered row",
    );
  } finally {
    globalThis.fetch = originalFetch;
    console.warn = originalConsoleWarn;
  }
});

test("production training terminal cleanup cannot quarantine a post-response renewal", async () => {
  const { applyTrainingTerminalApnsCleanup } = await workerModule();
  const token = "d".repeat(64);
  const sentRevision = "training-sent-r1";
  const harness = mutableApnsDeviceDatabase({
    cursor: 1,
    token,
    environment: "production",
    locale: null,
    sources: '["jma_eew"]',
    min_magnitude: 0,
    critical_alerts_enabled: 0,
    alert_sound: "system",
    city_name: null,
    latitude: null,
    longitude: null,
    radius_km: null,
    include_test_alerts: 1,
    utc_offset_minutes: null,
    notify_at_night: 1,
    app_attest_key_id: "training-r1-key",
    registration_revision: sentRevision,
    created_at: "2026-08-22T00:00:00.000Z",
    updated_at: "2026-08-22T00:00:00.000Z",
  });
  harness.currentRow = {
    ...harness.currentRow,
    app_attest_key_id: "training-r2-key",
    registration_revision: "training-renewed-r2",
    updated_at: "2026-08-22T00:00:01.000Z",
  };
  const cleaned = await applyTrainingTerminalApnsCleanup(
    harness.database,
    { token, registrationRevision: sentRevision },
    {
      ok: false,
      apnsId: "training-bdt",
      status: 400,
      apnsReason: "BadDeviceToken",
      terminalInvalidToken: true,
    },
  );
  assert.equal(cleaned.terminalResolved, true);
  assert.equal(cleaned.deactivated, false);
  assert.equal(cleaned.badDeviceTokenQuarantined, false);
  assert.equal(
    harness.currentRow.registration_revision,
    "training-renewed-r2",
    "cleanup is exact-revision only after the provider-response admission marker",
  );
  assert.equal(harness.badDeviceTokenQuarantineCount, 0,
    "a training rejection never upgrades the old renewal fence into cross-event quarantine");
});

test("a durable pre-send intent survives the APNs-2xx-to-D1 crash window", async () => {
  const { dispatchPushPage } = await workerModule();
  const token = "a".repeat(64);
  const row = {
    cursor: 1,
    token,
    environment: "production",
    locale: null,
    sources: '["jma_eew"]',
    min_magnitude: 0,
    critical_alerts_enabled: 0,
    alert_sound: "system",
    city_name: null,
    latitude: 35,
    longitude: 139,
    radius_km: 100,
    include_test_alerts: 0,
    utc_offset_minutes: null,
    notify_at_night: 1,
    app_attest_key_id: "pre-send-intent-key",
    registration_revision: "pre-send-intent-revision",
    app_identity: "5TT564H883.com.quakesignal.app",
    apns_topic: "com.quakesignal.app",
    app_platform: "ios",
    created_at: "2026-08-20T00:00:00.000Z",
    updated_at: "2026-08-20T00:00:00.000Z",
  };
  const database = {
    prepare(sql) {
      return {
        bind() {
          return {
            async all() {
              if (sql.includes("SELECT rowid AS cursor, * FROM devices")) {
                return { results: [row] };
              }
              return { results: [] };
            },
          };
        },
      };
    },
  };
  const order = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => {
    order.push("apns-accepted");
    return new Response(null, { status: 200 });
  };
  try {
    await assert.rejects(
      dispatchPushPage(
        {
          DB: database,
          APNS_PRIVATE_KEY: "configured-pre-send-intent-key",
          APNS_KEY_ID: "ABCDEFGHIJ",
          APNS_TEAM_ID: "ABCDEFGHIJ",
          APNS_BUNDLE_ID: "com.quakesignal.app",
        },
        message(1).event,
        "new",
        "cached.provider.jwt",
        "pre-send-intent-delivery",
        undefined,
        undefined,
        async () => {},
        async (deliveries) => {
          assert.deepEqual(deliveries.map(({ device }) => device.token), [token]);
          order.push("intent-durable");
          return { storageKey: "prepared", writeId: "write" };
        },
        async () => {},
        async (_intent, deliveries) => deliveries.map((delivery, originDeliveryIndex) => ({
          delivery,
          originDeliveryIndex,
          snapshotRegistrationRevision: delivery.device.registrationRevision,
        })),
        async () => {
          order.push("accepted-d1-attempt");
          throw new Error("simulated crash before accepted evidence commit");
        },
      ),
      /simulated crash before accepted evidence commit/,
    );
    assert.deepEqual(
      order,
      ["intent-durable", "apns-accepted", "accepted-d1-attempt"],
      "a crash after provider acceptance leaves the pre-send record for recovery",
    );
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("a peer APNs 2xx is journaled before BadDeviceToken D1 cleanup begins", async () => {
  const { dispatchPushPage } = await workerModule();
  const originalFetch = globalThis.fetch;
  const order = [];
  const row = (cursor, token) => ({
    cursor,
    token,
    environment: "production",
    locale: null,
    sources: '["jma_eew"]',
    min_magnitude: 0,
    critical_alerts_enabled: 0,
    alert_sound: "system",
    city_name: null,
    latitude: 35,
    longitude: 139,
    radius_km: 100,
    include_test_alerts: 0,
    utc_offset_minutes: null,
    notify_at_night: 1,
    app_attest_key_id: `key-${cursor}`,
    registration_revision: `revision-${cursor}`,
    app_identity: "5TT564H883.com.quakesignal.app",
    apns_topic: "com.quakesignal.app",
    app_platform: "ios",
    created_at: "2026-08-20T00:00:00.000Z",
    updated_at: "2026-08-20T00:00:00.000Z",
  });
  const rows = [row(1, "accepted-peer-token"), row(2, "bad-peer-token")];
  const database = {
    prepare(sql) {
      return {
        bind(...bindings) {
          return {
            sql,
            bindings,
            async all() {
              if (sql.includes("SELECT rowid AS cursor, * FROM devices")) {
                return { results: rows };
              }
              if (
                sql.includes("FROM notification_deliveries") ||
                sql.includes("FROM alert_delivery_failures")
              ) return { results: [] };
              throw new Error(`unexpected query: ${sql}`);
            },
            async run() {
              order.push("fallback-failure-record");
              return { meta: { changes: 1 } };
            },
          };
        },
      };
    },
    async batch() {
      order.push("bad-device-cleanup");
      throw new Error("simulated D1 cleanup outage");
    },
  };
  globalThis.fetch = async (request) =>
    String(typeof request === "string" ? request : request.url).includes("accepted-peer-token")
      ? new Response(null, { status: 200 })
      : Response.json({ reason: "BadDeviceToken" }, { status: 400 });
  try {
    const page = await dispatchPushPage(
      {
        DB: database,
        APNS_PRIVATE_KEY: "configured-peer-ordering-key",
        APNS_KEY_ID: "ABCDEFGHIJ",
        APNS_TEAM_ID: "ABCDEFGHIJ",
        APNS_BUNDLE_ID: "com.quakesignal.app",
      },
      message(1).event,
      "new",
      "cached.provider.jwt",
      "peer-ordering-delivery",
      undefined,
      undefined,
      async (accepted) => {
        assert.deepEqual(
          accepted.map(({ device }) => device.token),
          ["accepted-peer-token"],
        );
        order.push("acceptance-journal");
      },
    );
    assert.equal(page.retryRequired, true);
    assert.deepEqual(order, [
      "acceptance-journal",
      "bad-device-cleanup",
      "fallback-failure-record",
    ]);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("a post-2xx journal failure stops every later APNs batch", async () => {
  const { dispatchPushPage } = await workerModule();
  const originalFetch = globalThis.fetch;
  const rows = Array.from({ length: 3 }, (_, index) => ({
    cursor: index + 1,
    token: `journal-stop-token-${index + 1}`,
    environment: "production",
    locale: null,
    sources: '["jma_eew"]',
    min_magnitude: 0,
    critical_alerts_enabled: 0,
    alert_sound: "system",
    city_name: null,
    latitude: 35,
    longitude: 139,
    radius_km: 100,
    include_test_alerts: 0,
    utc_offset_minutes: null,
    notify_at_night: 1,
    app_attest_key_id: `journal-stop-key-${index + 1}`,
    registration_revision: `journal-stop-revision-${index + 1}`,
    app_identity: "5TT564H883.com.quakesignal.app",
    apns_topic: "com.quakesignal.app",
    app_platform: "ios",
    created_at: "2026-08-20T00:00:00.000Z",
    updated_at: "2026-08-20T00:00:00.000Z",
  }));
  const database = {
    prepare(sql) {
      return {
        bind() {
          return {
            async all() {
              if (sql.includes("SELECT rowid AS cursor, * FROM devices")) {
                return { results: rows };
              }
              return { results: [] };
            },
          };
        },
      };
    },
  };
  let requests = 0;
  globalThis.fetch = async () => {
    requests += 1;
    return new Response(null, { status: 200 });
  };
  try {
    await assert.rejects(
      dispatchPushPage(
        {
          DB: database,
          APNS_PRIVATE_KEY: "configured-journal-stop-key",
          APNS_KEY_ID: "ABCDEFGHIJ",
          APNS_TEAM_ID: "ABCDEFGHIJ",
          APNS_BUNDLE_ID: "com.quakesignal.app",
        },
        message(1).event,
        "new",
        "cached.provider.jwt",
        "journal-stop-delivery",
        undefined,
        undefined,
        async () => {
          throw new Error("simulated journal write failure");
        },
      ),
      /simulated journal write failure/,
    );
    assert.equal(
      requests,
      2,
      "only the already-settled two-recipient batch may reach APNs",
    );
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("BadDeviceToken revision fence preserves a same-millisecond in-flight authenticated refresh", async () => {
  const { dispatchPushPage } = await workerModule();
  const originalFetch = globalThis.fetch;
  const originalConsoleWarn = console.warn;
  const token = "fedcba9876543210";
  const harness = mutableApnsDeviceDatabase({
    cursor: 1,
    token,
    environment: "production",
    locale: null,
    sources: '["jma_eew"]',
    min_magnitude: 0,
    critical_alerts_enabled: 0,
    alert_sound: "system",
    city_name: "Test City",
    latitude: 35,
    longitude: 135,
    radius_km: 100,
    include_test_alerts: 0,
    utc_offset_minutes: null,
    notify_at_night: 1,
    app_attest_key_id: "refreshed-token-key",
    registration_revision: "refresh-race-sent-revision",
    created_at: "2026-08-20T00:00:00.000Z",
    updated_at: "2026-08-20T00:00:00.000Z",
  });
  const event = {
    id: "jma_eew:bad-token-refresh-race",
    eventId: "bad-token-refresh-race",
    sourceId: "jma_eew",
    serial: 1,
    kind: "eew",
    originTimeUtc: "2026-08-20T00:00:00.000Z",
    reportTimeUtc: "2026-08-20T00:00:00.000Z",
    hypocenter: "Test Region",
    latitude: 35,
    longitude: 135,
    magnitude: 5,
    depth: 10,
    maxIntensity: "4",
    isWarn: true,
    isFinal: false,
    isCancel: false,
    isTraining: false,
    tsunami: null,
    raw: null,
  };
  let apnsRequests = 0;
  const warnings = [];
  console.warn = (entry) => warnings.push(JSON.parse(String(entry)));
  globalThis.fetch = async () => {
    apnsRequests += 1;
    if (apnsRequests === 1) {
      harness.currentRow = {
        ...harness.currentRow,
        registration_revision: "refresh-race-inflight-revision",
      };
      return Response.json({ reason: "BadDeviceToken" }, { status: 400 });
    }
    return new Response(null, { status: 200 });
  };
  const environment = {
    APP_ATTEST_ENFORCEMENT: "required",
    DB: harness.database,
    APNS_PRIVATE_KEY: "configured-bad-token-race-key",
    APNS_KEY_ID: "ABCDEFGHIJ",
    APNS_TEAM_ID: "ABCDEFGHIJ",
    APNS_BUNDLE_ID: "com.quakesignal.app",
  };
  try {
    const first = await dispatchPushPage(
      environment,
      event,
      "new",
      "cached.provider.jwt",
      "bad-token-race-delivery-1",
    );
    assert.equal(first.retryRequired, false);
    assert.equal(
      harness.currentRow.updated_at,
      "2026-08-20T00:00:00.000Z",
      "same-millisecond registration timestamps must not affect D1 ordering",
    );
    assert.equal(
      harness.currentRow.registration_revision,
      "refresh-race-inflight-revision",
    );
    assert.equal(harness.appAttestKeyPresent, true);
    assert.equal(warnings[0].deactivated, false);
    assert.equal(warnings[0].disposition, "quarantine");
    assert.equal(harness.badDeviceTokenQuarantineCount, 1);
    const quarantineStatement = harness.batches.flat().find(({ sql }) =>
      sql.includes("INSERT INTO alert_delivery_failures") &&
      sql.includes("FROM devices")
    );
    assert.ok(quarantineStatement);
    assert.match(
      quarantineStatement.sql,
      /MAX\(\?, updated_at\)[\s\S]*MAX\(\?, updated_at\)/,
      "active quarantine retention cannot start before the preserved device refresh",
    );

    const second = await dispatchPushPage(
      environment,
      { ...event, serial: 2, reportTimeUtc: "2026-08-20T00:01:00.000Z" },
      "updated",
      "cached.provider.jwt",
      "bad-token-race-delivery-2",
    );
    assert.equal(second.retryRequired, false);
    assert.equal(
      apnsRequests,
      1,
      "a refresh that predates the APNs rejection must stay out of later-event fanout",
    );

    harness.authenticatedRenewal("2026-08-20T00:00:02.000Z");
    const third = await dispatchPushPage(
      environment,
      { ...event, serial: 3, reportTimeUtc: "2026-08-20T00:02:00.000Z" },
      "updated",
      "cached.provider.jwt",
      "bad-token-race-delivery-3",
    );
    assert.equal(third.retryRequired, false);
    assert.equal(
      apnsRequests,
      2,
      "a registration serialized after quarantine clears it before later fanout",
    );
  } finally {
    globalThis.fetch = originalFetch;
    console.warn = originalConsoleWarn;
  }
});

test("APNs 410 cleanup uses the sent revision after timestamp eligibility and preserves same-ms or skewed renewals", async () => {
  const { dispatchPushPage } = await workerModule();
  const originalFetch = globalThis.fetch;
  const invalidationTime = "2026-08-20T00:00:01.000Z";
  try {
    const unchanged = mutableApnsDeviceDatabase({
      cursor: 1,
      token: "unregistered-unchanged-revision",
      environment: "production",
      locale: null,
      sources: '["jma_eew"]',
      min_magnitude: 0,
      critical_alerts_enabled: 0,
      alert_sound: "system",
      city_name: null,
      latitude: 35,
      longitude: 139,
      radius_km: 100,
      include_test_alerts: 0,
      utc_offset_minutes: null,
      notify_at_night: 1,
      app_attest_key_id: "unregistered-revision-key",
      registration_revision: "unregistered-sent-revision",
      created_at: "2026-08-20T00:00:00.000Z",
      updated_at: "2026-08-20T00:00:00.000Z",
    });
    globalThis.fetch = async () => Response.json(
      {
        reason: "Unregistered",
        // Production accepts APNs' documented millisecond Unix timestamp.
        timestamp: Date.parse(invalidationTime),
      },
      { status: 410 },
    );
    const unchangedPage = await dispatchPushPage(
      {
        DB: unchanged.database,
        APNS_PRIVATE_KEY: "configured-unregistered-key",
        APNS_KEY_ID: "ABCDEFGHIJ",
        APNS_TEAM_ID: "ABCDEFGHIJ",
        APNS_BUNDLE_ID: "com.quakesignal.app",
      },
      message(1).event,
      "new",
      "cached.provider.jwt",
      "unregistered-unchanged",
    );
    assert.equal(unchangedPage.retryRequired, false);
    assert.equal(unchanged.currentRow, null, "the exact sent revision is removed");
    assert.ok(
      unchanged.batches.flat().some(({ sql, bindings = [] }) =>
        sql.includes("apns_registration_revision_fences") &&
        bindings.includes("apns_unregistration")
      ),
      "410 cleanup fences the exact sent revision before deletion",
    );

    for (const [label, refreshedAt] of [
      ["same millisecond", "2026-08-20T00:00:00.000Z"],
      ["skewed earlier", "2026-08-19T23:59:59.000Z"],
    ]) {
      const token = `unregistered-revision-${label.replaceAll(" ", "-")}`;
      const harness = mutableApnsDeviceDatabase({
        cursor: 1,
        token,
        environment: "production",
        locale: null,
        sources: '["jma_eew"]',
        min_magnitude: 0,
        critical_alerts_enabled: 0,
        alert_sound: "system",
        city_name: null,
        latitude: 35,
        longitude: 139,
        radius_km: 100,
        include_test_alerts: 0,
        utc_offset_minutes: null,
        notify_at_night: 1,
        app_attest_key_id: "unregistered-revision-key",
        registration_revision: "unregistered-sent-revision",
        created_at: "2026-08-20T00:00:00.000Z",
        updated_at: "2026-08-20T00:00:00.000Z",
      });
      globalThis.fetch = async () => {
        harness.currentRow = {
          ...harness.currentRow,
          registration_revision: `unregistered-renewed-${label}`,
          updated_at: refreshedAt,
        };
        return Response.json(
          {
            reason: "Unregistered",
            timestamp: Date.parse(invalidationTime),
          },
          { status: 410 },
        );
      };
      const page = await dispatchPushPage(
        {
          DB: harness.database,
          APNS_PRIVATE_KEY: "configured-unregistered-key",
          APNS_KEY_ID: "ABCDEFGHIJ",
          APNS_TEAM_ID: "ABCDEFGHIJ",
          APNS_BUNDLE_ID: "com.quakesignal.app",
        },
        message(1).event,
        "new",
        "cached.provider.jwt",
        `unregistered-${label}`,
      );
      assert.equal(page.retryRequired, false);
      assert.equal(
        harness.currentRow.registration_revision,
        `unregistered-renewed-${label}`,
        `${label} renewal must survive independently of its wall-clock value`,
      );
    }
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("active failure retention is pinned to at least the registration refresh clock", async () => {
  const { deliveryFailureLastSeenUtc } = await workerModule();
  assert.equal(
    deliveryFailureLastSeenUtc(
      "2026-08-20T00:00:00.000Z",
      "2026-08-20T00:00:01.000Z",
    ),
    "2026-08-20T00:00:01.000Z",
  );
  assert.equal(
    deliveryFailureLastSeenUtc(
      "2026-08-20T00:00:01.000Z",
      "2026-08-20T00:00:00.000Z",
    ),
    "2026-08-20T00:00:01.000Z",
  );
  assert.equal(
    deliveryFailureLastSeenUtc("2026-08-20T00:00:01.000Z", "malformed"),
    "2026-08-20T00:00:01.000Z",
  );
});

test("dispatches each authenticated app route with its stored allow-listed APNs topic", async () => {
  const { dispatchPushPage } = await workerModule();
  const originalFetch = globalThis.fetch;
  const iosIdentity = "5TT564H883.com.quakesignal.app";
  const watchIdentity = "5TT564H883.com.quakesignal.app.watchkitapp";
  const routes = [
    { appIdentity: iosIdentity, apnsTopic: "com.quakesignal.app", platform: "ios" },
    {
      appIdentity: watchIdentity,
      apnsTopic: "com.quakesignal.app.watchkitapp",
      platform: "watchos",
    },
  ];
  const baseRow = {
    environment: "production",
    locale: null,
    sources: '["jma_eew"]',
    min_magnitude: 0,
    critical_alerts_enabled: 0,
    alert_sound: "system",
    city_name: null,
    latitude: 35,
    longitude: 135,
    radius_km: 100,
    include_test_alerts: 1,
    utc_offset_minutes: null,
    notify_at_night: 1,
    created_at: "2026-08-19T00:00:00.000Z",
    updated_at: "2026-08-19T00:00:00.000Z",
  };
  const rows = routes.map((route, index) => ({
    ...baseRow,
    cursor: index + 1,
    token: `${route.platform}-token`,
    app_identity: route.appIdentity,
    apns_topic: route.apnsTopic,
    app_platform: route.platform,
  }));
  const deliveredBatches = [];
  const requests = [];
  const database = {
    prepare(sql) {
      return {
        bind(...bindings) {
          return {
            async all() {
              if (sql.includes("SELECT rowid AS cursor, * FROM devices")) {
                return { results: rows };
              }
              if (
                sql.includes("FROM notification_deliveries") ||
                sql.includes("FROM alert_delivery_failures")
              ) {
                return { results: [] };
              }
              throw new Error(`unexpected routed delivery query: ${sql}`);
            },
          };
        },
      };
    },
    async batch(statements) {
      deliveredBatches.push(statements);
      return statements.map(() => ({ meta: { changes: 1 } }));
    },
  };
  globalThis.fetch = async (url, init) => {
    requests.push({
      url: String(url),
      topic: init.headers["apns-topic"],
    });
    return new Response(null, { status: 200, headers: { "apns-id": "routed" } });
  };
  const event = {
    id: "jma_eew:routed",
    eventId: "routed",
    sourceId: "jma_eew",
    serial: 1,
    kind: "eew",
    originTimeUtc: "2026-08-19T00:00:00.000Z",
    reportTimeUtc: "2026-08-19T00:00:00.000Z",
    hypocenter: "Test Region",
    latitude: 35,
    longitude: 135,
    magnitude: 5.5,
    depth: 10,
    maxIntensity: "5-",
    isWarn: true,
    isFinal: false,
    isCancel: false,
    isTraining: false,
    tsunami: null,
    raw: null,
  };
  try {
    const page = await dispatchPushPage(
      {
        APP_ATTEST_ENFORCEMENT: "required",
        APP_ATTEST_APNS_ROUTES: JSON.stringify(routes),
        DB: database,
        APNS_PRIVATE_KEY: "configured-route-test-key",
        APNS_KEY_ID: "ABCDEFGHIJ",
        APNS_TEAM_ID: "ABCDEFGHIJ",
      },
      event,
      "new",
      "cached.provider.jwt",
      "authenticated-route-delivery",
    );
    assert.equal(page.pageFailure, null);
    assert.equal(page.retryRequired, false);
    assert.deepEqual(requests, [
      {
        url: "https://api.push.apple.com/3/device/ios-token",
        topic: "com.quakesignal.app",
      },
      {
        url: "https://api.push.apple.com/3/device/watchos-token",
        topic: "com.quakesignal.app.watchkitapp",
      },
    ]);
    assert.equal(
      deliveredBatches.length,
      2,
      "each authenticated APNs route owns its own durable acceptance batch",
    );
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("never sends a tampered stored topic and still completes another platform route", async () => {
  const { dispatchPushPage } = await workerModule();
  const originalFetch = globalThis.fetch;
  const iosRoute = {
    appIdentity: "5TT564H883.com.quakesignal.app",
    apnsTopic: "com.quakesignal.app",
    platform: "ios",
  };
  const common = {
    environment: "production",
    locale: null,
    sources: '["jma_eew"]',
    min_magnitude: 0,
    critical_alerts_enabled: 0,
    alert_sound: "system",
    city_name: null,
    latitude: 35,
    longitude: 135,
    radius_km: 100,
    include_test_alerts: 1,
    utc_offset_minutes: null,
    notify_at_night: 1,
    app_identity: iosRoute.appIdentity,
    app_platform: iosRoute.platform,
    created_at: "2026-08-19T00:00:00.000Z",
    updated_at: "2026-08-19T00:00:00.000Z",
  };
  const rows = [
    { ...common, cursor: 1, token: "tampered-token", apns_topic: "attacker.topic" },
    { ...common, cursor: 2, token: "valid-token", apns_topic: iosRoute.apnsTopic },
  ];
  const requests = [];
  const delivered = [];
  const database = {
    prepare(sql) {
      return {
        bind() {
          return {
            async all() {
              if (sql.includes("SELECT rowid AS cursor, * FROM devices")) {
                return { results: rows };
              }
              if (
                sql.includes("FROM notification_deliveries") ||
                sql.includes("FROM alert_delivery_failures")
              ) return { results: [] };
              throw new Error(`unexpected tampered-route query: ${sql}`);
            },
          };
        },
      };
    },
    async batch(statements) {
      delivered.push(statements);
      return statements.map(() => ({ meta: { changes: 1 } }));
    },
  };
  globalThis.fetch = async (url, init) => {
    requests.push({ url: String(url), topic: init.headers["apns-topic"] });
    return new Response(null, { status: 200 });
  };
  try {
    const page = await dispatchPushPage(
      {
        APP_ATTEST_ENFORCEMENT: "required",
        APP_ATTEST_APNS_ROUTES: JSON.stringify([iosRoute]),
        DB: database,
        APNS_PRIVATE_KEY: "configured-route-test-key",
        APNS_KEY_ID: "ABCDEFGHIJ",
        APNS_TEAM_ID: "ABCDEFGHIJ",
      },
      {
        id: "jma_eew:tampered-route",
        eventId: "tampered-route",
        sourceId: "jma_eew",
        serial: 1,
        kind: "eew",
        originTimeUtc: "2026-08-19T00:00:00.000Z",
        reportTimeUtc: "2026-08-19T00:00:00.000Z",
        hypocenter: "Test Region",
        latitude: 35,
        longitude: 135,
        magnitude: 5.5,
        depth: 10,
        maxIntensity: "5-",
        isWarn: true,
        isFinal: false,
        isCancel: false,
        isTraining: false,
        tsunami: null,
        raw: null,
      },
      "new",
      "cached.provider.jwt",
      "tampered-route-delivery",
    );
    assert.equal(page.retryRequired, true);
    assert.equal(page.pageFailure.apnsReason, "AppRouteNotAllowed");
    assert.deepEqual(requests, [{
      url: "https://api.push.apple.com/3/device/valid-token",
      topic: "com.quakesignal.app",
    }]);
    assert.equal(delivered.length, 1, "the valid route success remains durable");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("app identity routing is backward compatible, strict, and Watch-disabled by default", async () => {
  const {
    AppIdentityRouteConfigurationError,
    AppIdentityRouteNotAllowedError,
    authenticatedAppRouteForRequest,
    configuredAppIdentityRoutes,
  } = await workerModule();
  const iosIdentity = "5TT564H883.com.quakesignal.app";
  const watchIdentity = "5TT564H883.com.quakesignal.app.watchkitapp";
  const iosRoute = {
    appIdentity: iosIdentity,
    apnsTopic: "com.quakesignal.app",
    platform: "ios",
  };
  const watchRoute = {
    appIdentity: watchIdentity,
    apnsTopic: "com.quakesignal.app.watchkitapp",
    platform: "watchos",
  };

  assert.deepEqual(configuredAppIdentityRoutes({}), [iosRoute]);
  assert.deepEqual(
    authenticatedAppRouteForRequest({}, {}),
    iosRoute,
    "an existing iOS client can omit appIdentity",
  );
  assert.throws(
    () => authenticatedAppRouteForRequest({}, { appIdentity: watchIdentity }),
    (error) => error instanceof AppIdentityRouteNotAllowedError,
    "Watch is disabled unless its exact identity/topic route is configured",
  );

  const explicitEnvironment = {
    APP_ATTEST_APNS_ROUTES: JSON.stringify([watchRoute, iosRoute]),
  };
  assert.deepEqual(
    configuredAppIdentityRoutes(explicitEnvironment),
    [iosRoute, watchRoute],
    "route order is deterministic and not controlled by JSON order",
  );
  assert.deepEqual(
    authenticatedAppRouteForRequest(
      explicitEnvironment,
      { appIdentity: watchIdentity },
    ),
    watchRoute,
  );
  assert.throws(
    () => authenticatedAppRouteForRequest(
      explicitEnvironment,
      { appIdentity: watchIdentity },
      iosIdentity,
    ),
    (error) => error instanceof AppIdentityRouteNotAllowedError,
    "an existing App Attest key cannot switch its stored app identity",
  );
  assert.throws(
    () => authenticatedAppRouteForRequest({}, {}, watchIdentity),
    (error) => error instanceof AppIdentityRouteNotAllowedError,
    "removing Watch from the allow-list disables an existing Watch identity",
  );

  for (const configured of [
    "",
    "not-json",
    JSON.stringify([]),
    JSON.stringify([watchRoute]),
    JSON.stringify([iosRoute, iosRoute]),
    JSON.stringify([{ ...iosRoute, enabled: true }]),
    JSON.stringify([{ ...iosRoute, apnsTopic: "com.quakesignal.attacker" }]),
    JSON.stringify([{ ...iosRoute, platform: "carplay" }]),
  ]) {
    assert.throws(
      () => configuredAppIdentityRoutes({ APP_ATTEST_APNS_ROUTES: configured }),
      (error) => error instanceof AppIdentityRouteConfigurationError,
    );
  }
});

test("rejects an over-limit metadata probe before it can activate the global relay", async () => {
  const { default: worker } = await workerModule();
  let relayTouched = false;
  const response = await worker.fetch(
    new Request("https://quakesignal-api.example/"),
    {
      APP_ATTEST_CHALLENGE_RATE_LIMIT: {
        async limit() {
          return { success: false };
        },
      },
      RELAY: {
        idFromName() {
          relayTouched = true;
          throw new Error("an over-limit metadata request must not obtain a relay id");
        },
        get() {
          relayTouched = true;
          throw new Error("an over-limit metadata request must not obtain a relay stub");
        },
      },
    },
  );
  assert.equal(response.status, 429);
  assert.equal(relayTouched, false);
});

test("metadata exposes a stable non-secret App Attest policy fingerprint without relay work", async () => {
  const {
    AppIdentityRouteConfigurationError,
    appAttestPolicyFingerprint,
    canonicalAppAttestPolicy,
    effectiveAppAttestPolicy,
    default: worker,
  } = await workerModule();
  const policyFormat = "quakesignal-app-attest-policy/v2";
  const iosRoute = {
    appIdentity: "5TT564H883.com.quakesignal.app",
    apnsTopic: "com.quakesignal.app",
    platform: "ios",
  };
  const reviewedFingerprint = "sha256:paGI1JqZe4fM8agtkvI83In3vPpDliD3R7U57MQKomY";
  const policyEnvironment = {
    APP_ATTEST_ENFORCEMENT: "required",
    APP_ATTEST_APP_ID: "5TT564H883.com.quakesignal.app",
    APP_ATTEST_APNS_ROUTES: JSON.stringify([iosRoute]),
    APP_ATTEST_ALLOWED_BUNDLE_VERSIONS: "2, 1, 2, invalid!",
    APP_ATTEST_REQUIRE_RELEASE_METADATA: "false",
  };
  const effectivePolicy = effectiveAppAttestPolicy(policyEnvironment);
  assert.deepEqual(effectivePolicy.allowedBundleVersions, ["1", "2"]);
  assert.equal(
    canonicalAppAttestPolicy(effectivePolicy),
    [
      "app_id=5TT564H883.com.quakesignal.app",
      "protocol_version=1",
      "required=true",
      "development_bypass_allowed=false",
      "verification_environment=production",
      "require_release_metadata=false",
      "allowed_bundle_versions=1,2",
      'app_attest_apns_routes=[{"appIdentity":"5TT564H883.com.quakesignal.app","apnsTopic":"com.quakesignal.app","platform":"ios"}]',
      "",
    ].join("\n"),
  );
  assert.equal(
    await appAttestPolicyFingerprint(effectivePolicy),
    reviewedFingerprint,
  );
  assert.equal(
    await appAttestPolicyFingerprint(effectiveAppAttestPolicy({
      ...policyEnvironment,
      APP_ATTEST_ALLOWED_BUNDLE_VERSIONS: "1,2",
    })),
    reviewedFingerprint,
    "version order and duplicates must not change the effective deployment fingerprint",
  );
  assert.equal(
    await appAttestPolicyFingerprint(effectiveAppAttestPolicy({
      ...policyEnvironment,
      APP_ATTEST_APNS_ROUTES: '[{"platform":"ios","apnsTopic":"com.quakesignal.app","appIdentity":"5TT564H883.com.quakesignal.app"}]',
    })),
    reviewedFingerprint,
    "route JSON key order must not change the normalized deployment fingerprint",
  );
  assert.notEqual(
    await appAttestPolicyFingerprint(effectiveAppAttestPolicy({
      ...policyEnvironment,
      APP_ATTEST_REQUIRE_RELEASE_METADATA: "true",
    })),
    reviewedFingerprint,
    "a material App Attest policy change must alter the deployment fingerprint",
  );
  assert.notEqual(
    await appAttestPolicyFingerprint(effectiveAppAttestPolicy({
      ...policyEnvironment,
      APP_ATTEST_APNS_ROUTES: JSON.stringify([{ ...iosRoute, platform: "ipados" }]),
    })),
    reviewedFingerprint,
    "changing an authenticated APNs route must alter the deployment fingerprint",
  );
  assert.notEqual(
    await appAttestPolicyFingerprint(effectiveAppAttestPolicy({
      ...policyEnvironment,
      APP_ATTEST_APNS_ROUTES: JSON.stringify([
        iosRoute,
        {
          appIdentity: "5TT564H883.com.quakesignal.app.watchkitapp",
          apnsTopic: "com.quakesignal.app.watchkitapp",
          platform: "watchos",
        },
      ]),
    })),
    reviewedFingerprint,
    "adding an authenticated APNs route must alter the deployment fingerprint",
  );
  assert.throws(
    () => effectiveAppAttestPolicy({
      ...policyEnvironment,
      APP_ATTEST_APNS_ROUTES: JSON.stringify([
        { ...iosRoute, apnsTopic: "com.quakesignal.wrong" },
      ]),
    }),
    (error) => error instanceof AppIdentityRouteConfigurationError,
    "a wrong App Attest identity-to-topic route must fail policy construction",
  );

  let relayRequests = 0;
  const response = await worker.fetch(
    new Request("https://quakesignal-api.example/"),
    {
      ...policyEnvironment,
      APP_ATTEST_CHALLENGE_RATE_LIMIT: {
        async limit() {
          return { success: true };
        },
      },
      DEVICE_API_RATE_LIMIT: {
        async limit() {
          return { success: true };
        },
      },
      RELAY: {
        idFromName() {
          return "global";
        },
        get() {
          return {
            async fetch(request) {
              relayRequests += 1;
              throw new Error("metadata must not touch the relay");
            },
          };
        },
      },
    },
  );
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.equal(relayRequests, 0, "metadata must not make a relay request");
  const body = await response.json();
  assert.deepEqual(body.appAttestPolicy, {
    format: policyFormat,
    fingerprint: reviewedFingerprint,
    allowedBundleVersions: ["1", "2"],
  });
});

test("metadata remains available when private relay status is unavailable", async () => {
  const {
    appAttestPolicyFingerprint,
    effectiveAppAttestPolicy,
    default: worker,
  } = await workerModule();
  const policyFormat = "quakesignal-app-attest-policy/v2";
  const policyEnvironment = {
    APP_ATTEST_ENFORCEMENT: "required",
    APP_ATTEST_APP_ID: "5TT564H883.com.quakesignal.app",
    APP_ATTEST_APNS_ROUTES: '[{"appIdentity":"5TT564H883.com.quakesignal.app","apnsTopic":"com.quakesignal.app","platform":"ios"}]',
    APP_ATTEST_ALLOWED_BUNDLE_VERSIONS: "1,2",
    APP_ATTEST_REQUIRE_RELEASE_METADATA: "false",
  };
  const response = await worker.fetch(
    new Request("https://quakesignal-api.example/"),
    {
      ...policyEnvironment,
      APP_ATTEST_CHALLENGE_RATE_LIMIT: {
        async limit() {
          return { success: true };
        },
      },
      DEVICE_API_RATE_LIMIT: {
        async limit() {
          return { success: true };
        },
      },
      RELAY: {
        idFromName() {
          return "global";
        },
        get() {
          return {
            async fetch() {
              throw new Error("Durable Object free-tier write quota exhausted");
            },
          };
        },
      },
    },
  );
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("cache-control"), "no-store");
  const body = await response.json();
  assert.deepEqual(body.appAttestPolicy, {
    format: policyFormat,
    fingerprint: await appAttestPolicyFingerprint(
      effectiveAppAttestPolicy(policyEnvironment),
    ),
    allowedBundleVersions: ["1", "2"],
  });
});

test("status probes preserve first boot but do not repeatedly run relay recovery", async () => {
  const { QuakeRelay } = await workerModule();
  const originalFetch = globalThis.fetch;
  let upgradeRequests = 0;
  let httpSeedRequests = 0;
  let d1Batches = 0;
  let alarmAt = Date.now() + 60_000;
  const values = new Map();
  const storage = {
    async get(key) {
      return values.get(key);
    },
    async put(key, value) {
      values.set(key, value);
    },
    async list() {
      return new Map();
    },
    async getAlarm() {
      return alarmAt;
    },
    async setAlarm(value) {
      alarmAt = value;
    },
  };
  const state = {
    storage,
    waitUntil() {},
  };
  const database = {
    prepare() {
      return {
        bind() {
          return {
            async first() {
              return 0;
            },
            async all() {
              return { results: [] };
            },
            async run() {
              return { meta: { changes: 0 } };
            },
          };
        },
      };
    },
    async batch() {
      d1Batches += 1;
      throw new Error("a scheduled relay must not batch-recover for a status probe");
    },
  };
  globalThis.fetch = async (_url, init) => {
    if (new Headers(init?.headers).get("upgrade") === "websocket") {
      upgradeRequests += 1;
      throw new Error("a scheduled relay must not wait on an Upgrade in this test");
    }
    httpSeedRequests += 1;
    throw new Error("a scheduled relay must not HTTP-seed for a status probe");
  };
  try {
    const relay = new QuakeRelay(
      state,
      {
        DB: database,
        ALERT_DELIVERY_QUEUE: {
          async send() {
            throw new Error("status probes must not enqueue an outbox row");
          },
        },
      },
    );
    await relay.fetch(new Request("https://relay.internal/status"));
    await relay.fetch(new Request("https://relay.internal/status"));
    assert.equal(d1Batches, 0);
    assert.equal(httpSeedRequests, 0);
    assert.equal(upgradeRequests, 2, "one Upgrade attempt per JMA watcher is enough");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("a first status probe still performs operational bootstrap when no alarm exists", async () => {
  const { QuakeRelay } = await workerModule();
  const originalFetch = globalThis.fetch;
  let alarmAt = null;
  let d1Batches = 0;
  let upgradeRequests = 0;
  let httpSeedRequests = 0;
  const values = new Map();
  const storage = {
    async get(key) {
      return values.get(key);
    },
    async put(key, value) {
      values.set(key, value);
    },
    async list() {
      return new Map();
    },
    async getAlarm() {
      return alarmAt;
    },
    async setAlarm(value) {
      alarmAt = value;
    },
  };
  const state = {
    storage,
    waitUntil() {},
  };
  const database = {
    prepare() {
      return {
        bind() {
          return {
            async first() {
              return 0;
            },
            async all() {
              return { results: [] };
            },
            async run() {
              return { meta: { changes: 0 } };
            },
          };
        },
      };
    },
    async batch(statements) {
      d1Batches += 1;
      return statements.map(() => ({ meta: { changes: 0 } }));
    },
  };
  globalThis.fetch = async (_url, init) => {
    if (new Headers(init?.headers).get("upgrade") === "websocket") {
      upgradeRequests += 1;
      return { status: 503, webSocket: null, body: null };
    }
    httpSeedRequests += 1;
    return new Response(null, { status: 503 });
  };
  try {
    const relay = new QuakeRelay(
      state,
      {
        DB: database,
        ALERT_DELIVERY_QUEUE: { async send() {} },
      },
    );
    await relay.fetch(new Request("https://relay.internal/status"));
    assert.equal(
      d1Batches,
      0,
      "first status defers durable maintenance to the alarm",
    );
    assert.equal(
      httpSeedRequests,
      0,
      "the initial snapshot is deferred to its own immediate relay alarm",
    );
    assert.equal(upgradeRequests, 2, "first status opens one Upgrade per JMA route");
    assert.notEqual(alarmAt, null, "first status schedules routine recovery");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("activates one fetch-Upgraded Wolfx route only after accept", async () => {
  const { QuakeRelay } = await workerModule();
  const originalFetch = globalThis.fetch;
  const pending = new Set();
  const failures = [];
  const values = new Map();
  const alarms = [];
  const storage = {
    async get(key) {
      return values.get(key);
    },
    async put(key, value) {
      values.set(key, value);
    },
    async list() {
      return new Map();
    },
    async setAlarm(value) {
      alarms.push(value);
    },
  };
  const state = {
    storage,
    waitUntil(promise) {
      let tracked;
      tracked = Promise.resolve(promise)
        .catch((error) => failures.push(error))
        .finally(() => pending.delete(tracked));
      pending.add(tracked);
    },
  };
  const drain = async () => {
    for (let pass = 0; pass < 20 && pending.size > 0; pass += 1) {
      await Promise.all([...pending]);
    }
    assert.equal(pending.size, 0, "all relay background work should settle");
    assert.deepEqual(failures, [], "the Upgrade path must not hide background errors");
  };
  class UpgradeSocket {
    readyState = 1;
    accepted = false;
    sent = [];
    listeners = new Map();

    accept() {
      this.accepted = true;
    }

    addEventListener(type, listener) {
      this.listeners.set(type, listener);
    }

    send(message) {
      assert.equal(this.accepted, true, "Wolfx queries must follow accept()");
      this.sent.push(message);
    }

    close() {
      this.readyState = 3;
    }
  }
  const socket = new UpgradeSocket();
  const fetchCalls = [];
  let resolveUpgrade;
  globalThis.fetch = (url, init) => {
    fetchCalls.push({ url: String(url), init });
    return new Promise((resolve) => {
      resolveUpgrade = resolve;
    });
  };
  try {
    const relay = new QuakeRelay(state, {});
    // These private TypeScript methods remain callable in the bundled black-box
    // test. Calling twice exercises the real connectingRoutes guard.
    relay.connect("jma_eew");
    relay.connect("jma_eew");
    relay.connect("cenc_eqlist");
    assert.equal(fetchCalls.length, 1, "an in-flight route must not be duplicated");
    assert.equal(fetchCalls[0].url, "https://ws-api.wolfx.jp/jma_eew");
    assert.equal(
      new Headers(fetchCalls[0].init.headers).get("upgrade"),
      "websocket",
    );

    resolveUpgrade({ status: 101, webSocket: socket, body: null });
    await drain();

    assert.equal(socket.accepted, true);
    assert.deepEqual(socket.sent, ["query_jmaeew"]);
    assert.equal(
      relay.statuses.get("jma_eew"),
      "connecting",
      "the Upgrade alone is not valid upstream liveness",
    );
    assert.equal(relay.upstreams.get("jma_eew"), socket);
    assert.equal(relay.connectingRoutes.has("jma_eew"), false);
    assert.deepEqual(alarms, []);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("rejected and failed Upgrade handshakes cancel, log safely, and retry", async () => {
  const { QuakeRelay, upstreamReconnectDelayMs } = await workerModule();
  const originalFetch = globalThis.fetch;
  const originalConsoleWarn = console.warn;
  const pending = new Set();
  const failures = [];
  const alarms = [];
  const warnings = [];
  const values = new Map();
  const storage = {
    async get(key) {
      return values.get(key);
    },
    async put(key, value) {
      values.set(key, value);
    },
    async list() {
      return new Map();
    },
    async getAlarm() {
      return null;
    },
    async setAlarm(value) {
      alarms.push(value);
    },
  };
  const state = {
    storage,
    waitUntil(promise) {
      let tracked;
      tracked = Promise.resolve(promise)
        .catch((error) => failures.push(error))
        .finally(() => pending.delete(tracked));
      pending.add(tracked);
    },
  };
  const drain = async () => {
    for (let pass = 0; pass < 20 && pending.size > 0; pass += 1) {
      await Promise.all([...pending]);
    }
    assert.equal(pending.size, 0, "all retry scheduling should settle");
    assert.deepEqual(failures, [], "failure telemetry must not become an exception");
  };
  const body = {
    cancelled: 0,
    async cancel() {
      this.cancelled += 1;
    },
  };
  let mode = "rejected";
  globalThis.fetch = async () => {
    if (mode === "rejected") {
      return { status: 429, webSocket: null, body };
    }
    throw new TypeError("never copy this upstream transport text into logs");
  };
  console.warn = (entry) => warnings.push(entry);
  try {
    const relay = new QuakeRelay(state, {});
    const beforeRejected = Date.now();
    relay.connect("jma_eqlist");
    await drain();
    assert.equal(body.cancelled, 1, "a rejected Upgrade body must be released");
    assert.equal(relay.statuses.get("jma_eqlist"), "error");
    assert.equal(relay.connectingRoutes.has("jma_eqlist"), false);
    const rejected = JSON.parse(warnings.at(-1));
    assert.deepEqual(
      {
        outcome: rejected.outcome,
        route: rejected.route,
        httpStatus: rejected.httpStatus,
      },
      {
        outcome: "wolfx_upstream_upgrade_rejected",
        route: "jma_eqlist",
        httpStatus: 429,
      },
    );
    assert.ok(
      alarms.at(-1) >= beforeRejected + 4_000,
      "a rejected handshake gets a bounded first reconnect alarm",
    );
    assert.equal(values.get("upstream-reconnect-failures:jma_eqlist"), 1);

    const firstRetryDelayMs = rejected.retryDelayMs;
    relay.connect("jma_eqlist");
    await drain();
    const repeated = JSON.parse(warnings.at(-1));
    assert.equal(repeated.failureCount, 2);
    assert.equal(
      repeated.retryDelayMs,
      upstreamReconnectDelayMs(2, "jma_eqlist"),
    );
    assert.ok(
      repeated.retryDelayMs > firstRetryDelayMs,
      "a repeated rejection must not retry in a tight one-second loop",
    );
    assert.equal(values.get("upstream-reconnect-failures:jma_eqlist"), 2);

    mode = "throw";
    relay.connect("jma_eew");
    await drain();
    assert.equal(relay.statuses.get("jma_eew"), "error");
    assert.equal(relay.connectingRoutes.has("jma_eew"), false);
    const failed = JSON.parse(warnings.at(-1));
    assert.deepEqual(
      {
        outcome: failed.outcome,
        route: failed.route,
        errorName: failed.errorName,
      },
      {
        outcome: "wolfx_upstream_upgrade_error",
        route: "jma_eew",
        errorName: "TypeError",
      },
    );
    assert.equal(
      warnings.at(-1).includes("never copy this upstream transport text"),
      false,
      "upstream exception text must not enter Worker logs",
    );
  } finally {
    console.warn = originalConsoleWarn;
    globalThis.fetch = originalFetch;
  }
});

test("activates paced HTTP fallback for one sustained websocket route outage", async () => {
  const {
    QuakeRelay,
    isHttpFallbackSourceStale,
    isHttpRecoverySeedDue,
    mapWithMinimumSpacing,
  } = await workerModule();
  const now = Date.now();
  const values = new Map([
    ["initial-http-seed-complete", true],
    ["upstream-degraded-since-ms:jma_eqlist", now - 80_000],
  ]);
  const state = {
    storage: {
      async get(key) {
        return values.get(key);
      },
      async put(key, value) {
        values.set(key, value);
      },
      async delete(key) {
        values.delete(key);
      },
      async list({ prefix = "" } = {}) {
        return new Map([...values].filter(([key]) => key.startsWith(prefix)));
      },
      async transaction(callback) {
        return callback({
          get: this.get.bind(this),
          put: this.put.bind(this),
          delete: this.delete.bind(this),
        });
      },
    },
    waitUntil() {},
  };
  const relay = new QuakeRelay(state, {});
  for (const source of [
    "jma_eew",
    "sc_eew",
    "cenc_eew",
    "fj_eew",
    "cq_eew",
    "cenc_eqlist",
    "jma_eqlist",
  ]) {
    relay.statuses.set(source, source === "jma_eqlist" ? "error" : "open");
    relay.lastSuccessfulUpstreamMs.set(source, now);
  }

  assert.equal(
    await relay.shouldRunHttpRecoverySeed(),
    false,
    "a failed route inside its 90-second grace window keeps HTTP fallback off",
  );
  assert.equal(
    await relay.nextHttpFallbackAlarmAt(now),
    now + 10_000,
    "the fallback alarm targets the failed route's exact grace boundary",
  );
  values.set("upstream-degraded-since-ms:jma_eqlist", now - 100_000);
  assert.equal(
    await relay.nextHttpFallbackAlarmAt(now),
    now + 1,
    "a route already beyond grace receives an immediate bounded wake",
  );
  assert.equal(
    await relay.shouldRunHttpRecoverySeed(),
    true,
    "one route past the grace window activates alternate transport while the others stay healthy",
  );
  assert.equal(values.get("http-fallback-active"), true);
  values.set("http-fallback-next-sweep-at-ms", Date.now() + 60_000);
  assert.equal(
    await relay.shouldRunHttpRecoverySeed(),
    false,
    "the durable one-minute sweep interval prevents overlapping fallback requests",
  );

  assert.equal(isHttpRecoverySeedDue(now - 60_000, now), true);
  assert.equal(isHttpRecoverySeedDue(now - 59_999, now), false);
  assert.equal(isHttpFallbackSourceStale(now - 179_000, false, now), false);
  assert.equal(isHttpFallbackSourceStale(now - 181_000, false, now), true);
  assert.equal(isHttpFallbackSourceStale(now, true, now), true);

  let clock = 0;
  const starts = [];
  const sleeps = [];
  const results = await mapWithMinimumSpacing(
    ["first", "second", "third"],
    600,
    async (source) => {
      starts.push(clock);
      return source;
    },
    () => clock,
    async (milliseconds) => {
      sleeps.push(milliseconds);
      clock += milliseconds;
    },
  );
  assert.deepEqual(results, ["first", "second", "third"]);
  assert.deepEqual(starts, [0, 600, 1_200]);
  assert.deepEqual(sleeps, [600, 600]);
});

test("HTTP and Upgrade timeout guards reject even when transport ignores abort", async () => {
  const { withHttpSnapshotTimeout, withWolfxUpgradeTimeout } = await workerModule();
  const never = () => new Promise(() => {});
  await assert.rejects(
    withHttpSnapshotTimeout(never, 1),
    { name: "HttpSnapshotTimeoutError" },
  );
  await assert.rejects(
    withWolfxUpgradeTimeout(never, 1),
    { name: "WolfxUpgradeTimeoutError" },
  );
});

test("coalesces concurrent HTTP recovery sweeps without durable lease or cursor writes", async () => {
  const { QuakeRelay } = await workerModule();
  const values = new Map();
  const writes = [];
  const state = {
    storage: {
      async get(key) {
        return values.get(key);
      },
      async put(key, value) {
        writes.push(["put", key, value]);
        values.set(key, value);
      },
      async delete(key) {
        writes.push(["delete", key]);
        values.delete(key);
      },
      async list({ prefix = "" } = {}) {
        return new Map([...values].filter(([key]) => key.startsWith(prefix)));
      },
      async transaction(callback) {
        return callback({
          get: this.get.bind(this),
          put: this.put.bind(this),
          delete: this.delete.bind(this),
        });
      },
    },
    waitUntil() {},
  };
  const relay = new QuakeRelay(state, {});
  for (const source of [
    "jma_eew",
    "sc_eew",
    "cenc_eew",
    "fj_eew",
    "cq_eew",
    "cenc_eqlist",
    "jma_eqlist",
  ]) {
    relay.statuses.set(source, source === "jma_eqlist" ? "error" : "open");
    relay.lastSuccessfulUpstreamMs.set(source, Date.now());
  }
  let release;
  const gate = new Promise((resolve) => {
    release = resolve;
  });
  let markSourceStarted;
  const sourceStarted = new Promise((resolve) => {
    markSourceStarted = resolve;
  });
  let sourceCalls = 0;
  relay.seedHttpSource = async (source) => {
    sourceCalls += 1;
    assert.equal(source, "jma_eqlist");
    markSourceStarted();
    await gate;
    return { completed: true, snapshotWorkStarted: false };
  };
  const first = relay.seedFromHttp("recovery");
  const second = relay.seedFromHttp("recovery");
  await sourceStarted;
  assert.equal(sourceCalls, 1, "one relay instance must coalesce concurrent sweeps");
  assert.deepEqual(
    writes.map(([operation, key]) => [operation, key]),
    [["put", "http-fallback-next-sweep-at-ms"]],
    "the sweep itself persists only its one-minute cadence scalar",
  );
  assert.ok(
    writes[0][2] >= Date.now() + 59_000,
    "the cadence scalar prevents an evicted replacement from sweeping early",
  );
  assert.equal(
    [...values.keys()].some((key) =>
      key === "http-seed-source-cursor" || key === "last-http-seed-ms" ||
      key.includes("lease")
    ),
    false,
    "recovery does not churn a lease, source cursor, or initial-seed timestamp",
  );
  release();
  await Promise.all([first, second]);
  assert.equal(sourceCalls, 1);
});

test("a legacy sweep lease fences the low-write recovery scheduler during rolling deploy", async () => {
  const { QuakeRelay } = await workerModule();
  const now = Date.now();
  const legacyUntil = now + 60_000;
  const values = new Map([
    ["http-fallback-active", true],
    ["http-seed-lease-until-ms", { ownerId: "preceding-release", untilMs: legacyUntil }],
  ]);
  const state = {
    storage: {
      async get(key) { return values.get(key); },
      async list() { return new Map(); },
      async put() { throw new Error("must not claim while the legacy sweep owns it"); },
      async transaction(callback) {
        return callback({
          get: this.get.bind(this),
          put: this.put.bind(this),
        });
      },
    },
    waitUntil() {},
  };
  const relay = new QuakeRelay(state, {});
  for (const source of [
    "jma_eew", "sc_eew", "cenc_eew", "fj_eew", "cq_eew", "cenc_eqlist", "jma_eqlist",
  ]) relay.statuses.set(source, "error");
  let sourceCalls = 0;
  relay.seedHttpSource = async () => {
    sourceCalls += 1;
    return { completed: true, snapshotWorkStarted: false };
  };

  assert.equal(await relay.nextHttpFallbackAlarmAt(now), legacyUntil);
  assert.equal(await relay.nextDueHttpSeedMode(true), null);
  values.set("http-fallback-active", false);
  relay.pendingHttpSnapshotWorks = async () => [{
    source: "jma_eqlist",
    mode: "recovery",
  }];
  assert.equal(
    await relay.nextHttpFallbackAlarmAt(now),
    legacyUntil,
    "an old in-flight cursor also fences the new scheduler",
  );
  assert.equal(
    await relay.nextDueHttpSeedMode(false),
    null,
    "a pending cursor cannot bypass the rolling-deploy fence",
  );
  relay.pendingHttpSnapshotWorks = async () => [];
  values.set("initial-http-seed-complete", false);
  assert.equal(
    await relay.nextHttpFallbackAlarmAt(now),
    legacyUntil,
    "an old in-flight baseline seed also fences the new scheduler",
  );
  assert.equal(
    await relay.nextDueHttpSeedMode(false),
    null,
    "an initial seed cannot bypass the rolling-deploy fence",
  );
  let initialCalls = 0;
  relay.runInitialHttpSeed = async () => { initialCalls += 1; };
  await relay.runHttpSeed("initial");
  assert.equal(initialCalls, 0, "the executor also fences an initial seed");
  await relay.runHttpRecoverySweep();
  assert.equal(sourceCalls, 0, "the new relay must not overlap the old sweep");
});

test("rotates recovery sweep fairness in memory and treats a silent open socket as degraded", async () => {
  const { QuakeRelay } = await workerModule();
  const state = {
    storage: {
      async get() { return undefined; },
      async list() { return new Map(); },
    },
    waitUntil() {},
  };
  const relay = new QuakeRelay(state, {});
  const sources = ["jma_eew", "jma_eqlist"];
  for (const source of sources) relay.statuses.set(source, "error");

  assert.deepEqual(relay.recoverySweepSources(0), sources);
  assert.deepEqual(
    relay.recoverySweepSources(60_000),
    [...sources.slice(1), sources[0]],
    "each minute starts at the next source without a durable recovery cursor",
  );
  assert.deepEqual(
    relay.recoverySweepSources(2 * 60_000),
    sources,
    "the fair source order wraps after every source receives first position",
  );

  const staleSocket = { readyState: 1, close() {} };
  relay.upstreams.set("jma_eqlist", staleSocket);
  relay.statuses.set("jma_eqlist", "open");
  relay.lastSuccessfulUpstreamMs.set("jma_eqlist", Date.now() - 181_000);
  assert.equal(
    relay.routeIsOpen("jma_eqlist"),
    false,
    "a silent-but-open socket must not block degraded transport recovery",
  );
});

test("a due HTTP recovery sweep writes no polling rows and reserves the fallback turn", async () => {
  const { QuakeRelay } = await workerModule();
  const now = Date.now();
  const values = new Map([
    ["http-fallback-active", true],
  ]);
  const writes = [];
  let alarmAt = null;
  const state = {
    storage: {
      async get(key) {
        return values.get(key);
      },
      async put(key, value) {
        writes.push(["put", key, value]);
        values.set(key, value);
      },
      async delete(key) {
        writes.push(["delete", key]);
        values.delete(key);
      },
      async list({ prefix = "" } = {}) {
        return new Map([...values].filter(([key]) => key.startsWith(prefix)));
      },
      async transaction(callback) {
        return callback({
          get: this.get.bind(this),
          put: this.put.bind(this),
          delete: this.delete.bind(this),
        });
      },
      async getAlarm() { return alarmAt; },
      async setAlarm(value) {
        writes.push(["setAlarm", "alarm", value]);
        alarmAt = value;
      },
    },
    waitUntil() {},
  };
  const relay = new QuakeRelay(state, {});
  const maintenance = [];
  for (const source of [
    "jma_eew",
    "sc_eew",
    "cenc_eew",
    "fj_eew",
    "cq_eew",
    "cenc_eqlist",
    "jma_eqlist",
  ]) {
    relay.statuses.set(source, source === "jma_eqlist" ? "error" : "open");
    relay.lastSuccessfulUpstreamMs.set(source, now);
  }
  relay.reconcileDlqPersistenceFallbacks = async () => maintenance.push("dlq");
  relay.migrateLegacyPendingDeliveries = async () => maintenance.push("legacy");
  relay.drainPendingIngestJournal = async () => maintenance.push("journal");
  relay.flushAlertDeliveryOutbox = async (limit) => maintenance.push(`outbox:${limit}`);
  relay.purgeExpiredDevicesIfDue = async () => maintenance.push("purge");
  relay.ensureUpstreams = async () => {};
  const sources = [];
  relay.seedHttpSource = async (source) => {
    sources.push(source);
    return { completed: true, snapshotWorkStarted: false };
  };

  await relay.alarm();

  assert.deepEqual(sources, ["jma_eqlist"]);
  assert.deepEqual(
    maintenance,
    ["outbox:4"],
    "only a D1-safe four-row outbox handoff shares the fallback turn",
  );
  assert.deepEqual(
    writes.map(([operation, key]) => [operation, key]),
    [
      ["put", "http-fallback-next-sweep-at-ms"],
      ["setAlarm", "alarm"],
    ],
    "a steady fallback turn accounts for both its cadence marker and alarm row",
  );
  assert.ok(
    typeof alarmAt === "number" && alarmAt >= now + 59_000,
    "the next unchanged recovery sweep is scheduled about one minute later",
  );
});

test("a recovery sweep stops after the first changed snapshot starts durable work", async () => {
  const { QuakeRelay } = await workerModule();
  const values = new Map();
  const writes = [];
  const state = {
    storage: {
      async get(key) { return values.get(key); },
      async put(key, value) {
        writes.push([key, value]);
        values.set(key, value);
      },
      async list({ prefix = "" } = {}) {
        return new Map([...values].filter(([key]) => key.startsWith(prefix)));
      },
    },
    waitUntil() {},
  };
  const relay = new QuakeRelay(state, {});
  for (const source of [
    "jma_eew",
    "sc_eew",
    "cenc_eew",
    "fj_eew",
    "cq_eew",
    "cenc_eqlist",
    "jma_eqlist",
  ]) {
    relay.statuses.set(source, "error");
  }
  const attempted = [];
  relay.seedHttpSource = async (source) => {
    attempted.push(source);
    return { completed: true, snapshotWorkStarted: true };
  };

  await relay.runHttpRecoverySweep();

  assert.equal(
    attempted.length,
    1,
    "one alarm may start only one changed-snapshot D1 cursor",
  );
  assert.deepEqual(
    writes.map(([key]) => key),
    ["http-fallback-next-sweep-at-ms"],
    "the only recovery bookkeeping write is the next-sweep marker",
  );
});

test("an early alarm between recovery sweeps does not fall through to normal D1 maintenance", async () => {
  const { QuakeRelay } = await workerModule();
  const now = Date.now();
  const values = new Map([
    ["http-fallback-active", true],
    ["http-fallback-next-sweep-at-ms", now + 60_000],
  ]);
  const state = {
    storage: {
      async get(key) { return values.get(key); },
      async put(key, value) { values.set(key, value); },
      async delete(key) { values.delete(key); },
      async list() { return new Map(); },
      async getAlarm() { return null; },
      async setAlarm() {},
    },
    waitUntil() {},
  };
  const relay = new QuakeRelay(state, {});
  const calls = [];
  relay.ensureUpstreams = async () => calls.push("upstreams");
  relay.seedFromHttp = async () => calls.push("source");
  relay.reconcileDlqPersistenceFallbacks = async (limit) => calls.push(`dlq:${limit}`);
  relay.drainPendingIngestJournal = async (limit, outboxLimit) =>
    calls.push(`journal:${limit}:${outboxLimit}`);
  relay.flushAlertDeliveryOutbox = async (limit) => calls.push(`outbox:${limit}`);
  relay.scheduleRoutineRelayAlarm = async () => {};

  await relay.alarm();

  assert.deepEqual(
    calls,
    ["upstreams"],
    "a replacement relay honors the durable next-sweep time and avoids normal maintenance",
  );
});

test("partial fallback drains healthy-route live work between exclusive HTTP turns", async () => {
  const { QuakeRelay } = await workerModule();
  const originalNow = Date.now;
  const now = Date.parse("2026-08-19T00:00:00.000Z");
  const sources = [
    "jma_eew",
    "sc_eew",
    "cenc_eew",
    "fj_eew",
    "cq_eew",
    "cenc_eqlist",
    "jma_eqlist",
  ];

  try {
    Date.now = () => now;
    const values = new Map([
      ["http-fallback-active", true],
      ["http-fallback-next-sweep-at-ms", now + 60_000],
    ]);
    let alarmAt = null;
    const state = {
      storage: {
        async get(key) { return values.get(key); },
        async put(key, value) { values.set(key, value); },
        async delete(key) { values.delete(key); },
        async list() { return new Map(); },
        async getAlarm() { return alarmAt; },
        async setAlarm(value) { alarmAt = value; },
      },
      waitUntil() {},
    };
    const relay = new QuakeRelay(state, {});
    for (const source of sources) {
      relay.statuses.set(source, source === "jma_eqlist" ? "error" : "open");
      relay.lastSuccessfulUpstreamMs.set(source, now);
    }

    const calls = [];
    let liveWorkPending = true;
    relay.ensureUpstreams = async () => calls.push("upstreams");
    relay.seedFromHttp = async () => calls.push("http");
    relay.repairPendingLiveSnapshotSlots = async () => calls.push("repair");
    relay.hasAnyActiveLiveSnapshotWork = async () => liveWorkPending;
    relay.pendingLiveSnapshotWorks = async () =>
      liveWorkPending ? [["pending-live-snapshot:cenc_eqlist", { retryAtMs: now }]] : [];
    relay.drainPendingLiveSnapshotWorks = async () => {
      calls.push("live");
      liveWorkPending = false;
      return true;
    };

    await relay.alarm();

    assert.deepEqual(
      calls,
      ["upstreams", "repair", "live"],
      "healthy live work gets a separate bounded turn between HTTP sweeps",
    );
    assert.equal(
      alarmAt,
      now + 60_000,
      "completed live work leaves the next HTTP deadline instead of an immediate alarm spin",
    );
  } finally {
    Date.now = originalNow;
  }
});

test("partial fallback preserves HTTP failure and rolling-deploy fences", async () => {
  const { QuakeRelay } = await workerModule();
  const originalNow = Date.now;
  const now = Date.parse("2026-08-19T00:00:00.000Z");
  const sources = [
    "jma_eew",
    "sc_eew",
    "cenc_eew",
    "fj_eew",
    "cq_eew",
    "cenc_eqlist",
    "jma_eqlist",
  ];
  const scenarios = [
    ["http-fallback-retry-not-before-ms", now + 60_000],
    ["http-seed-lease-until-ms", { ownerId: "preceding-release", untilMs: now + 60_000 }],
  ];

  try {
    Date.now = () => now;
    for (const [fenceKey, fenceValue] of scenarios) {
      const values = new Map([
        ["http-fallback-active", true],
        ["http-fallback-next-sweep-at-ms", now + 60_000],
        [fenceKey, fenceValue],
      ]);
      let alarmAt = null;
      const state = {
        storage: {
          async get(key) { return values.get(key); },
          async put(key, value) { values.set(key, value); },
          async delete(key) { values.delete(key); },
          async list() { return new Map(); },
          async getAlarm() { return alarmAt; },
          async setAlarm(value) { alarmAt = value; },
        },
        waitUntil() {},
      };
      const relay = new QuakeRelay(state, {});
      for (const source of sources) {
        relay.statuses.set(source, source === "jma_eqlist" ? "error" : "open");
        relay.lastSuccessfulUpstreamMs.set(source, now);
      }
      const calls = [];
      relay.ensureUpstreams = async () => calls.push("upstreams");
      relay.seedFromHttp = async () => calls.push("http");
      relay.repairPendingLiveSnapshotSlots = async () => calls.push("repair");
      relay.pendingLiveSnapshotWorks = async () =>
        [["pending-live-snapshot:cenc_eqlist", { retryAtMs: now }]];

      await relay.alarm();

      assert.deepEqual(
        calls,
        ["upstreams"],
        `${fenceKey} keeps ordinary D1 work outside the protected turn`,
      );
      assert.equal(
        alarmAt,
        now + 60_000,
        "blocked live work aligns with the protected deadline instead of spinning at now + 1",
      );
    }
  } finally {
    Date.now = originalNow;
  }
});

test("full-outage fallback aligns blocked live work with the next HTTP sweep", async () => {
  const { QuakeRelay } = await workerModule();
  const originalNow = Date.now;
  const now = Date.parse("2026-08-19T00:00:00.000Z");
  const values = new Map([
    ["http-fallback-active", true],
    ["http-fallback-next-sweep-at-ms", now + 60_000],
  ]);
  let alarmAt = null;
  const state = {
    storage: {
      async get(key) { return values.get(key); },
      async put(key, value) { values.set(key, value); },
      async delete(key) { values.delete(key); },
      async list() { return new Map(); },
      async getAlarm() { return alarmAt; },
      async setAlarm(value) { alarmAt = value; },
    },
    waitUntil() {},
  };
  const relay = new QuakeRelay(state, {});
  for (const source of [
    "jma_eew",
    "sc_eew",
    "cenc_eew",
    "fj_eew",
    "cq_eew",
    "cenc_eqlist",
    "jma_eqlist",
  ]) relay.statuses.set(source, "error");
  const calls = [];
  relay.ensureUpstreams = async () => calls.push("upstreams");
  relay.pendingLiveSnapshotWorks = async () =>
    [["pending-live-snapshot:cenc_eqlist", { retryAtMs: now }]];
  relay.drainPendingLiveSnapshotWorks = async () => calls.push("live");

  try {
    Date.now = () => now;
    await relay.alarm();
    assert.deepEqual(calls, ["upstreams"]);
    assert.equal(
      alarmAt,
      now + 60_000,
      "a live cursor that cannot run during total outage does not force an immediate alarm loop",
    );
  } finally {
    Date.now = originalNow;
  }
});

test("pending HTTP cursor aligns blocked live work with its continuation", async () => {
  const { QuakeRelay } = await workerModule();
  const originalNow = Date.now;
  const now = Date.parse("2026-08-19T00:00:00.000Z");
  let alarmAt = null;
  const state = {
    storage: {
      async get() { return undefined; },
      async put() {},
      async delete() {},
      async list() { return new Map(); },
      async getAlarm() { return alarmAt; },
      async setAlarm(value) { alarmAt = value; },
    },
    waitUntil() {},
  };
  const relay = new QuakeRelay(state, {});
  relay.lastHttpSnapshotResumeStartedMs = now;
  relay.refreshHttpFallbackActive = async () => false;
  relay.pendingHttpSnapshotWorks = async () => [[
    "pending-http-snapshot:jma_eqlist",
    { mode: "recovery" },
  ]];
  relay.pendingLiveSnapshotWorks = async () =>
    [["pending-live-snapshot:cenc_eqlist", { retryAtMs: now }]];
  const calls = [];
  relay.ensureUpstreams = async () => calls.push("upstreams");
  relay.drainPendingLiveSnapshotWorks = async () => calls.push("live");

  try {
    Date.now = () => now;
    await relay.alarm();
    assert.deepEqual(calls, ["upstreams"]);
    assert.equal(
      alarmAt,
      now + 5_000,
      "the protected HTTP cursor deadline replaces an unserviceable immediate live wake",
    );
  } finally {
    Date.now = originalNow;
  }
});

test("an alarm repairs a malformed HTTP snapshot cursor without making status readers write", async () => {
  const { QuakeRelay } = await workerModule();
  const malformedKey = "pending-http-snapshot:jma_eqlist";
  const values = new Map([
    [malformedKey, { unexpected: "shape" }],
    ["initial-http-seed-complete", true],
  ]);
  const deletes = [];
  const state = {
    storage: {
      async get(key) { return values.get(key); },
      async list({ prefix = "" } = {}) {
        return new Map([...values].filter(([key]) => key.startsWith(prefix)));
      },
      async delete(key) {
        deletes.push(key);
        values.delete(key);
      },
      async getAlarm() { return null; },
      async setAlarm() {},
    },
    waitUntil() {},
  };
  const relay = new QuakeRelay(state, {});
  for (const source of [
    "jma_eew", "sc_eew", "cenc_eew", "fj_eew", "cq_eew", "cenc_eqlist", "jma_eqlist",
  ]) {
    relay.statuses.set(source, "open");
    relay.lastSuccessfulUpstreamMs.set(source, Date.now());
  }
  relay.reconcileDlqPersistenceFallbacks = async () => {};
  relay.migrateLegacyPendingDeliveries = async () => {};
  relay.drainPendingIngestJournal = async () => {};
  relay.flushAlertDeliveryOutbox = async () => {};
  relay.purgeExpiredDevicesIfDue = async () => {};
  relay.ensureUpstreams = async () => {};
  relay.scheduleRoutineRelayAlarm = async () => {};
  const originalConsoleError = console.error;
  console.error = () => {};
  try {
    await relay.alarm();
  } finally {
    console.error = originalConsoleError;
  }
  assert.deepEqual(deletes, [malformedKey]);
  assert.equal(values.has(malformedKey), false);
});

test("a fallible fallback outbox handoff defers without an automatic alarm retry", async () => {
  const { QuakeRelay } = await workerModule();
  const values = new Map([["http-fallback-active", true]]);
  const state = {
    storage: {
      async get(key) { return values.get(key); },
      async put(key, value) { values.set(key, value); },
      async delete(key) { values.delete(key); },
      async list() { return new Map(); },
      async getAlarm() { return null; },
      async setAlarm() {},
    },
    waitUntil() {},
  };
  const relay = new QuakeRelay(state, {});
  let reconnectAttempts = 0;
  relay.nextDueHttpSeedMode = async () => "recovery";
  relay.ensureUpstreams = async () => { reconnectAttempts += 1; };
  relay.seedFromHttp = async () => {};
  relay.flushAlertDeliveryOutbox = async () => {
    throw new Error("simulated D1 outbox failure");
  };
  relay.scheduleRoutineRelayAlarm = async () => {};

  await relay.alarm();
  assert.ok(reconnectAttempts >= 1);
  assert.ok(
    values.get("http-fallback-retry-not-before-ms") >= Date.now() + 59_000,
    "the fallback persists a one-minute retry and resolves the alarm handler",
  );
});

test("a pending recovery cursor resumes every five seconds and owns its D1 turn", async () => {
  const { QuakeRelay } = await workerModule();
  const originalNow = Date.now;
  let now = Date.parse("2026-08-13T00:00:00.000Z");
  const values = new Map([["http-fallback-active", true]]);
  const state = {
    storage: {
      async get(key) { return values.get(key); },
      async put(key, value) { values.set(key, value); },
      async delete(key) { values.delete(key); },
      async list() { return new Map(); },
      async getAlarm() { return null; },
      async setAlarm() {},
    },
    waitUntil() {},
  };
  const relay = new QuakeRelay(state, {});
  const work = { source: "jma_eqlist", mode: "recovery" };
  relay.pendingHttpSnapshotWorks = async () => [work];
  const calls = [];
  const maintenance = [];
  relay.ensureUpstreams = async () => calls.push("upstreams");
  relay.seedFromHttp = async (mode) => {
    calls.push(`source:${mode}`);
    relay.lastHttpSnapshotResumeStartedMs = Date.now();
  };
  relay.flushAlertDeliveryOutbox = async (limit) => calls.push(`outbox:${limit}`);
  relay.reconcileDlqPersistenceFallbacks = async () => maintenance.push("dlq");
  relay.migrateLegacyPendingDeliveries = async () => maintenance.push("legacy");
  relay.drainPendingIngestJournal = async () => maintenance.push("journal");
  relay.purgeExpiredDevicesIfDue = async () => maintenance.push("purge");
  relay.scheduleRoutineRelayAlarm = async () => {};

  try {
    Date.now = () => now;
    assert.equal(
      await relay.nextDueHttpSeedMode(true),
      "recovery",
      "a stored cursor retains its recovery notification semantics",
    );
    relay.lastHttpSnapshotResumeStartedMs = now;
    assert.equal(
      await relay.nextDueHttpSeedMode(true),
      null,
      "a cursor cannot be retried in a tight alarm loop",
    );
    assert.equal(
      await relay.nextHttpFallbackAlarmAt(now),
      now + 5_000,
      "a changed snapshot receives its bounded five-second continuation wakeup",
    );

    now += 5_000;
    await relay.alarm();
    assert.deepEqual(calls, ["upstreams", "source:recovery", "outbox:4", "upstreams"]);
    assert.deepEqual(
      maintenance,
      [],
      "pending snapshot work must not share a turn with routine D1 maintenance",
    );

    calls.length = 0;
    await relay.alarm();
    assert.deepEqual(
      calls,
      ["upstreams"],
      "an early alarm waits for the next five-second cursor window",
    );
  } finally {
    Date.now = originalNow;
  }
});

test("a successful cursor clears an expired retry marker before its five-second continuation", async () => {
  const { QuakeRelay } = await workerModule();
  const now = Date.now();
  const values = new Map([
    ["http-fallback-active", true],
    ["http-fallback-retry-not-before-ms", now - 1],
  ]);
  let alarmAt = null;
  const state = {
    storage: {
      async get(key) { return values.get(key); },
      async put(key, value) { values.set(key, value); },
      async delete(key) { values.delete(key); },
      async list() { return new Map(); },
      async getAlarm() { return alarmAt; },
      async setAlarm(value) { alarmAt = value; },
    },
    waitUntil() {},
  };
  const relay = new QuakeRelay(state, {});
  const maintenance = [];
  relay.pendingHttpSnapshotWorks = async () => [{
    source: "jma_eqlist",
    mode: "recovery",
  }];
  relay.ensureUpstreams = async () => {};
  relay.seedFromHttp = async () => {
    relay.lastHttpSnapshotResumeStartedMs = Date.now();
  };
  relay.flushAlertDeliveryOutbox = async () => {};
  relay.reconcileDlqPersistenceFallbacks = async () => maintenance.push("dlq");
  relay.migrateLegacyPendingDeliveries = async () => maintenance.push("legacy");
  relay.drainPendingIngestJournal = async () => maintenance.push("journal");
  relay.purgeExpiredDevicesIfDue = async () => maintenance.push("purge");

  const startedAt = Date.now();
  await relay.alarm();

  assert.equal(values.has("http-fallback-retry-not-before-ms"), false);
  assert.deepEqual(maintenance, []);
  assert.ok(
    typeof alarmAt === "number" && alarmAt >= startedAt + 4_000,
    "the next cursor slice stays on its five-second continuation cadence",
  );
});

test("a recovered WebSocket transport still defers a failing unfinished HTTP cursor", async () => {
  const { QuakeRelay } = await workerModule();
  const values = new Map();
  let alarmAt = null;
  const state = {
    storage: {
      async get(key) { return values.get(key); },
      async put(key, value) { values.set(key, value); },
      async delete(key) { values.delete(key); },
      async list() { return new Map(); },
      async getAlarm() { return alarmAt; },
      async setAlarm(value) { alarmAt = value; },
    },
    waitUntil() {},
  };
  const relay = new QuakeRelay(state, {});
  for (const source of [
    "jma_eew",
    "sc_eew",
    "cenc_eew",
    "fj_eew",
    "cq_eew",
    "cenc_eqlist",
    "jma_eqlist",
  ]) {
    relay.statuses.set(source, "open");
    relay.lastSuccessfulUpstreamMs.set(source, Date.now());
  }
  let reconnectAttempts = 0;
  let sourceAttempts = 0;
  let outboxAttempts = 0;
  relay.pendingHttpSnapshotWorks = async () => [{
    source: "jma_eqlist",
    mode: "recovery",
  }];
  relay.ensureUpstreams = async () => { reconnectAttempts += 1; };
  relay.seedFromHttp = async () => { sourceAttempts += 1; };
  relay.flushAlertDeliveryOutbox = async () => {
    outboxAttempts += 1;
    throw new Error("simulated recovered-cursor D1 failure");
  };

  await relay.alarm();
  assert.equal(sourceAttempts, 1);
  assert.equal(outboxAttempts, 1);
  assert.ok(
    values.get("http-fallback-retry-not-before-ms") >= Date.now() + 59_000,
  );

  await relay.alarm();
  assert.equal(sourceAttempts, 1, "retry window keeps the cursor out of automatic retry");
  assert.equal(outboxAttempts, 1);
  assert.equal(reconnectAttempts, 2, "the only permitted work during the retry window is reconnect maintenance");
  assert.ok(typeof alarmAt === "number" && alarmAt >= Date.now() + 59_000);
});

test("a D1 failure while persisting an HTTP cursor uses the durable fallback retry", async () => {
  const { QuakeRelay } = await workerModule();
  const values = new Map([
    ["http-fallback-active", true],
    ["pending-http-snapshot:jma_eqlist", {
      version: 1,
      source: "jma_eqlist",
      mode: "recovery",
      fingerprint: "d1-failure-cursor",
      events: [{
        id: "jma_eqlist:d1-failure",
        sourceId: "jma_eqlist",
        eventId: "d1-failure",
        serial: 1,
        kind: "report",
        originTimeUtc: "2026-08-13T03:00:00.000Z",
        reportTimeUtc: "2026-08-13T03:00:00.000Z",
        hypocenter: "Test coast",
        latitude: 35.1,
        longitude: 140.2,
        magnitude: 4.2,
        depth: 10,
        maxIntensity: null,
        isWarn: false,
        isFinal: true,
        isCancel: false,
        isTraining: false,
        tsunami: null,
      }],
      nextIndex: 0,
    }],
  ]);
  let alarmAt = null;
  const state = {
    storage: {
      async get(key) { return values.get(key); },
      async put(key, value) { values.set(key, value); },
      async delete(key) { values.delete(key); },
      async list({ prefix = "" } = {}) {
        return new Map([...values].filter(([key]) => key.startsWith(prefix)));
      },
      async transaction(callback) {
        return callback({
          get: this.get.bind(this),
          put: this.put.bind(this),
          delete: this.delete.bind(this),
        });
      },
      async getAlarm() { return alarmAt; },
      async setAlarm(value) { alarmAt = value; },
    },
    waitUntil() {},
  };
  let batchAttempts = 0;
  const relay = new QuakeRelay(state, {
    DB: {
      prepare() {
        return {
          bind() {
            return { async all() { return { results: [] }; } };
          },
        };
      },
      async batch() {
        batchAttempts += 1;
        throw new Error("simulated HTTP snapshot D1 batch failure");
      },
    },
  });
  let reconnectAttempts = 0;
  let outboxAttempts = 0;
  relay.ensureUpstreams = async () => { reconnectAttempts += 1; };
  relay.flushAlertDeliveryOutbox = async () => { outboxAttempts += 1; };

  await relay.alarm();
  assert.equal(batchAttempts, 1);
  assert.equal(outboxAttempts, 0, "failed persistence never reaches Queue handoff");
  assert.ok(values.get("http-fallback-retry-not-before-ms") >= Date.now() + 59_000);

  await relay.alarm();
  assert.equal(batchAttempts, 1, "retry window does not repeat the D1 cursor slice");
  assert.equal(outboxAttempts, 0);
  assert.equal(reconnectAttempts, 2);
});

test("a grace-boundary recovery selection enables the same durable retry protection", async () => {
  const { QuakeRelay } = await workerModule();
  const values = new Map();
  const state = {
    storage: {
      async get(key) { return values.get(key); },
      async put(key, value) { values.set(key, value); },
      async delete(key) { values.delete(key); },
      async list() { return new Map(); },
      async getAlarm() { return null; },
      async setAlarm() {},
    },
    waitUntil() {},
  };
  const relay = new QuakeRelay(state, {});
  let refreshCalls = 0;
  let sourceAttempts = 0;
  let outboxAttempts = 0;
  relay.refreshHttpFallbackActive = async () => ++refreshCalls > 1;
  relay.nextDueHttpSeedMode = async () => "recovery";
  relay.ensureUpstreams = async () => {};
  relay.seedFromHttp = async () => { sourceAttempts += 1; };
  relay.flushAlertDeliveryOutbox = async () => {
    outboxAttempts += 1;
    throw new Error("simulated grace-boundary D1 handoff failure");
  };
  relay.scheduleRoutineRelayAlarm = async () => {};

  await relay.alarm();
  assert.equal(sourceAttempts, 1);
  assert.equal(outboxAttempts, 1);
  assert.ok(values.get("http-fallback-retry-not-before-ms") >= Date.now() + 59_000);

  await relay.alarm();
  assert.equal(sourceAttempts, 1);
  assert.equal(outboxAttempts, 1);
});

test("a deferred fallback turn does not touch D1 again before its retry time", async () => {
  const { QuakeRelay } = await workerModule();
  const now = Date.now();
  const values = new Map([
    ["http-fallback-active", true],
    ["http-fallback-retry-not-before-ms", now + 5_000],
    ["last-http-seed-ms", now - 601],
  ]);
  let alarmAt = null;
  const state = {
    storage: {
      async get(key) { return values.get(key); },
      async put(key, value) { values.set(key, value); },
      async delete(key) { values.delete(key); },
      async list() { return new Map(); },
      async getAlarm() { return alarmAt; },
      async setAlarm(value) { alarmAt = value; },
    },
    waitUntil() {},
  };
  const relay = new QuakeRelay(state, {});
  let reconnectAttempts = 0;
  let sourceAttempts = 0;
  let outboxAttempts = 0;
  relay.ensureUpstreams = async () => { reconnectAttempts += 1; };
  relay.seedFromHttp = async () => { sourceAttempts += 1; };
  relay.flushAlertDeliveryOutbox = async () => {
    outboxAttempts += 1;
  };

  await relay.alarm();
  assert.equal(reconnectAttempts, 1);
  assert.equal(sourceAttempts, 0);
  assert.equal(outboxAttempts, 0);
  assert.ok(typeof alarmAt === "number" && alarmAt >= now + 4_000);
});

test("a cursor-free initial HTTP failure persists its five-minute retry timestamp", async () => {
  const { QuakeRelay } = await workerModule();
  const originalNow = Date.now;
  let now = Date.parse("2026-08-13T00:00:00.000Z");
  const values = new Map();
  const writes = [];
  for (const source of [
    "jma_eew",
    "sc_eew",
    "cenc_eew",
    "fj_eew",
    "cq_eew",
    "cenc_eqlist",
  ]) {
    values.set(`upstream-http-fingerprint:${source}`, "valid-fingerprint");
  }
  const state = {
    storage: {
      async get(key) { return values.get(key); },
      async put(key, value) {
        writes.push([key, value]);
        values.set(key, value);
      },
      async delete(key) { values.delete(key); },
      async list({ prefix = "" } = {}) {
        return new Map([...values].filter(([key]) => key.startsWith(prefix)));
      },
      async transaction(callback) {
        return callback({
          get: this.get.bind(this),
          put: this.put.bind(this),
          delete: this.delete.bind(this),
        });
      },
    },
    waitUntil() {},
  };
  const relay = new QuakeRelay(state, {});
  const attempts = [];
  relay.seedHttpSource = async (source, mode) => {
    attempts.push([source, mode]);
    return { completed: false, snapshotWorkStarted: false };
  };
  try {
    Date.now = () => now;
    await relay.runInitialHttpSeed();
    assert.deepEqual(attempts, [["jma_eqlist", "initial"]]);
    assert.equal(values.get("last-http-seed-ms"), now);
    assert.equal(
      writes.filter(([key]) => key === "last-http-seed-ms").length,
      1,
      "a cursor-free failure records exactly one baseline-attempt timestamp",
    );
    assert.equal(
      await relay.nextDueHttpSeedMode(false),
      null,
      "routine alarms cannot immediately repeat a failed baseline fetch",
    );
    now += 5 * 60_000 - 1;
    assert.equal(await relay.nextDueHttpSeedMode(false), null);
    now += 1;
    assert.equal(
      await relay.nextDueHttpSeedMode(false),
      "initial",
      "the same missing baseline source becomes eligible only after five minutes",
    );
  } finally {
    Date.now = originalNow;
  }
});

test("a cold Queue-facing relay defers its first HTTP baseline to the alarm", async () => {
  const { QuakeRelay } = await workerModule();
  const values = new Map();
  const state = {
    storage: {
      async get(key) {
        return values.get(key);
      },
      async put(key, value) {
        values.set(key, value);
      },
      async delete(key) {
        values.delete(key);
      },
      async list({ prefix = "" } = {}) {
        return new Map([...values].filter(([key]) => key.startsWith(prefix)));
      },
      async getAlarm() { return null; },
      async setAlarm() {},
    },
    waitUntil() {},
  };
  const relay = new QuakeRelay(state, {});
  const maintenance = [];
  relay.ensureUpstreams = async () => {};
  relay.reconcileDlqPersistenceFallbacks = async () => maintenance.push("dlq");
  relay.migrateLegacyPendingDeliveries = async () => maintenance.push("legacy");
  relay.drainPendingIngestJournal = async () => maintenance.push("journal");
  relay.flushAlertDeliveryOutbox = async () => maintenance.push("outbox");
  relay.purgeExpiredDevicesIfDue = async () => maintenance.push("purge");
  relay.scheduleRoutineRelayAlarm = async () => {};
  const modes = [];
  relay.seedFromHttp = async (mode) => modes.push(mode);

  const response = await relay.fetch(new Request("https://relay.internal/outbox/legacy", {
    method: "POST",
    body: "{}",
  }));

  assert.equal(response.status, 400);
  assert.deepEqual(modes, []);
  assert.deepEqual(
    maintenance,
    [],
    "the legacy upgrade endpoint leaves routine maintenance to the alarm",
  );
});

test("routine retention separates event, ordinary evidence, and active invalid-token cutoffs", async () => {
  const { QuakeRelay } = await workerModule();
  const batches = [];
  const stored = new Map();
  const state = {
    storage: {
      async getAlarm() { return null; },
      async setAlarm() {},
      async get(key) {
        return stored.get(key);
      },
      async put(key, value) {
        stored.set(key, value);
      },
    },
  };
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
      batches.push(statements);
      return statements.map(() => ({ meta: { changes: 0 } }));
    },
  };
  const relay = new QuakeRelay(state, { DB: database });
  const now = Date.parse("2026-08-20T12:00:00.000Z");
  const originalNow = Date.now;
  Date.now = () => now;
  try {
    await relay.purgeExpiredDevicesIfDue();
  } finally {
    Date.now = originalNow;
  }

  assert.equal(batches.length, 1, "retention uses one ordered D1 batch");
  const statements = batches[0];
  const revisionIndex = statements.findIndex(({ sql }) =>
    sql === "DELETE FROM event_revisions WHERE recorded_at_utc < ?"
  );
  const eventIndex = statements.findIndex(({ sql }) =>
    sql === "DELETE FROM events WHERE last_updated_utc < ?"
  );
  const lifecycleRetention = statements.find(({ sql }) =>
    sql.includes("DELETE FROM alert_lifecycle_recipients")
  );
  const staleDeviceFence = statements.find(({ sql }) =>
    sql.includes("INSERT INTO apns_registration_revision_fences") &&
    sql.includes("'stale_registration_retention'")
  );
  const fenceRetention = statements.find(({ sql }) =>
    sql.includes("DELETE FROM apns_registration_revision_fences")
  );
  const deviceDeletionIndex = statements.findIndex(({ sql }) =>
    sql.includes("DELETE FROM devices WHERE updated_at < ?")
  );
  const failureRetention = statements.find(({ sql }) =>
    sql.includes("DELETE FROM alert_delivery_failures")
  );
  const incidentRetention = statements.find(({ sql }) =>
    sql.includes("DELETE FROM alert_delivery_incidents")
  );
  const pageFailureRetention = statements.find(({ sql }) =>
    sql.includes("DELETE FROM alert_delivery_page_failures")
  );
  assert.ok(revisionIndex >= 0, "revision retention must be explicit and bounded");
  assert.ok(eventIndex > revisionIndex, "revisions must be pruned before events");
  // The sweep uses the disclosed 89-day eligibility cutoff. Public copy also
  // states that the next successful daily cleanup performs deletion and that
  // operational failures can delay it.
  const expectedCutoff = new Date(now - (89 * 24 * 60 * 60_000)).toISOString();
  const expectedDeviceCutoff = new Date(now - (90 * 24 * 60 * 60_000)).toISOString();
  const expectedDeliveryCutoff = new Date(now - (14 * 24 * 60 * 60_000)).toISOString();
  assert.deepEqual(statements[revisionIndex].bindings, [expectedCutoff]);
  assert.deepEqual(statements[eventIndex].bindings, [expectedCutoff]);
  assert.ok(staleDeviceFence, "stale revisions must be fenced before bulk deletion");
  assert.ok(
    statements.indexOf(staleDeviceFence) < deviceDeletionIndex,
    "the revision-only removal fence and device deletion share one ordered batch",
  );
  assert.deepEqual(
    staleDeviceFence.bindings,
    [new Date(now).toISOString(), expectedDeviceCutoff],
  );
  assert.match(staleDeviceFence.sql, /token_hash[\s\S]*SELECT registration_revision, NULL/);
  assert.match(staleDeviceFence.sql, /blocks_lifecycle_replay = 1/);
  assert.deepEqual(lifecycleRetention.bindings, [expectedDeliveryCutoff]);
  assert.match(lifecycleRetention.sql, /last_evidence_at_utc < \?/);
  assert.deepEqual(
    failureRetention.bindings,
    [expectedDeviceCutoff, expectedDeliveryCutoff],
  );
  assert.match(failureRetention.sql, /apns_reason = 'BadDeviceToken'/);
  assert.match(failureRetention.sql, /status = 'active'/);
  assert.deepEqual(fenceRetention.bindings, [expectedDeliveryCutoff]);
  for (const retention of [incidentRetention, pageFailureRetention]) {
    assert.deepEqual(retention.bindings, [expectedDeliveryCutoff]);
    assert.match(retention.sql, /status = 'resolved'/);
    assert.match(retention.sql, /resolved_at_utc IS NOT NULL/);
    assert.match(retention.sql, /resolved_at_utc < \?/);
    assert.doesNotMatch(
      retention.sql,
      /last_seen_utc < \?/,
      "active incidents must not age out before explicit resolution",
    );
  }
  assert.equal(
    stored.get("last-device-purge-ms"),
    now,
    "the shared daily cadence covers event retention",
  );
});

test("HTTP fallback ingests only structurally valid changed snapshots", async () => {
  const { QuakeRelay, isStructurallyValidHttpSnapshot } = await workerModule();
  const originalFetch = globalThis.fetch;
  const values = new Map();
  const state = {
    storage: {
      async get(key) {
        return values.get(key);
      },
      async put(key, value) {
        values.set(key, value);
      },
      async delete(key) {
        values.delete(key);
      },
      async list({ prefix = "" } = {}) {
        return new Map([...values].filter(([key]) => key.startsWith(prefix)));
      },
      async transaction(callback) {
        return callback({
          get: this.get.bind(this),
          put: this.put.bind(this),
          delete: this.delete.bind(this),
        });
      },
    },
    waitUntil() {},
  };
  const validSnapshot = jmaEewSnapshot();
  const normalizedValidSnapshot = normalizedJmaEewSnapshot(validSnapshot);
  assert.equal(
    isStructurallyValidHttpSnapshot(
      "jma_eew",
      validSnapshot,
      [normalizedValidSnapshot],
    ),
    true,
  );
  const {
    isSea: _isSea,
    isWarn: _isWarn,
    isFinal: _isFinal,
    isCancel: _isCancel,
    isTraining: _isTraining,
    isAssumption: _isAssumption,
    ...withoutDecisionBooleans
  } = validSnapshot;
  assert.equal(
    isStructurallyValidHttpSnapshot(
      "jma_eew",
      withoutDecisionBooleans,
      [normalizedJmaEewSnapshot(withoutDecisionBooleans)],
    ),
    false,
    "missing all raw decision booleans must not be normalized into false decisions",
  );
  for (const field of [
    "isSea",
    "isTraining",
    "isAssumption",
    "isWarn",
    "isFinal",
    "isCancel",
  ]) {
    const missing = { ...validSnapshot };
    delete missing[field];
    assert.equal(
      isStructurallyValidHttpSnapshot(
        "jma_eew",
        missing,
        [normalizedJmaEewSnapshot(missing)],
      ),
      false,
      `missing raw ${field} must fail closed`,
    );
    const coercedRawValue = field === "isWarn" ? 1 : "false";
    const coerced = { ...validSnapshot, [field]: coercedRawValue };
    assert.equal(
      isStructurallyValidHttpSnapshot(
        "jma_eew",
        coerced,
        [normalizedJmaEewSnapshot(coerced)],
      ),
      false,
      `non-Boolean raw ${field} must fail closed`,
    );
  }
  for (const [rawField, normalizedField] of [
    ["Depth", "depth"],
    ["MaxIntensity", "maxIntensity"],
  ]) {
    const missing = { ...validSnapshot };
    delete missing[rawField];
    assert.equal(
      isStructurallyValidHttpSnapshot(
        "jma_eew",
        missing,
        [normalizedJmaEewSnapshot(missing, { [normalizedField]: null })],
      ),
      false,
      `missing essential raw ${rawField} must fail closed`,
    );
  }
  for (const [field, mismatch] of [
    ["id", "jma_eew:20260813120001"],
    ["sourceId", "jma_eqlist"],
    ["eventId", "20260813120001"],
    ["serial", 2],
    ["kind", "report"],
    ["originTimeUtc", "2026-08-13T03:00:01.000Z"],
    ["reportTimeUtc", "2026-08-13T03:00:06.000Z"],
    ["hypocenter", "Other coast"],
    ["latitude", 35.2],
    ["longitude", 140.3],
    ["magnitude", 4.3],
    ["depth", 11],
    ["maxIntensity", "5-"],
    ["isWarn", false],
    ["isFinal", true],
    ["isCancel", true],
    ["isTraining", true],
    ["tsunami", "unexpected"],
    ["raw", { ...validSnapshot }],
  ]) {
    assert.equal(
      isStructurallyValidHttpSnapshot(
        "jma_eew",
        validSnapshot,
        [{ ...normalizedValidSnapshot, [field]: mismatch }],
      ),
      false,
      `normalized ${field} must exactly match its raw JMA field`,
    );
  }
  assert.equal(
    isStructurallyValidHttpSnapshot("jma_eew", { EventID: "x", Serial: 1 }, [{
      sourceId: "jma_eew",
      eventId: "x",
      serial: 1,
      originTimeUtc: "2026-08-13T03:00:00.000Z",
      reportTimeUtc: "2026-08-13T03:00:05.000Z",
      latitude: 35.1,
      longitude: 140.2,
      magnitude: 4.2,
      hypocenter: "Test coast",
    }]),
    false,
    "minimal EventID-shaped objects must not become alternate-transport proof",
  );
  assert.equal(
    isStructurallyValidHttpSnapshot("jma_eew", {}, []),
    false,
    "an empty or unnormalized response must never make the fallback healthy",
  );

  let responseBody = validSnapshot;
  const snapshotFetches = [];
  globalThis.fetch = async (_url, init) => {
    snapshotFetches.push(init);
    return Response.json(responseBody);
  };
  try {
    let batches = 0;
    const database = {
      prepare() {
        return {
          bind() {
            return {
              async all() {
                return { results: [] };
              },
            };
          },
        };
      },
      async batch(statements) {
        batches += 1;
        return statements.map(() => ({ meta: { changes: 1 } }));
      },
    };
    const relay = new QuakeRelay(state, { DB: database });
    relay.flushAlertDeliveryOutbox = async () => {};

    assert.deepEqual(
      await relay.seedHttpSource("jma_eew", "recovery"),
      { completed: true, snapshotWorkStarted: true },
    );
    assert.equal(batches, 1, "a changed snapshot commits in one bounded D1 batch");
    assert.equal(
      snapshotFetches[0].cache,
      "no-store",
      "a fresh HTTP readiness signal must bypass Worker edge caching",
    );
    assert.equal(
      typeof values.get("upstream-http-fingerprint:jma_eew"),
      "string",
      "a successful durable ingest records its exact snapshot fingerprint",
    );
    assert.equal(
      typeof values.get("upstream-last-http-success-ms:jma_eew"),
      "number",
    );

    assert.deepEqual(
      await relay.seedHttpSource("jma_eew", "recovery"),
      { completed: true, snapshotWorkStarted: false },
    );
    assert.equal(
      batches,
      1,
      "an unchanged HTTP snapshot must not repeat a D1/outbox ingest",
    );

    responseBody = {};
    assert.deepEqual(
      await relay.seedHttpSource("jma_eew", "recovery"),
      { completed: false, snapshotWorkStarted: false },
    );
    assert.equal(
      batches,
      1,
      "an invalid response must not reach the durable ingest path",
    );

    const rankedReport = jmaEqlistEntry(1);
    const soleNo50 = {
      md5: "50505050505050505050505050505050",
      No50: jmaEqlistEntry(50),
    };
    assert.equal(
      isStructurallyValidHttpSnapshot(
        "jma_eqlist",
        soleNo50,
        [normalizedJmaEqlistEntry(soleNo50.No50)],
      ),
      false,
      "a sole valid No50 entry must not masquerade as a complete ranked snapshot",
    );
    const gappedList = {
      md5: "13131313131313131313131313131313",
      No1: rankedReport,
      No3: jmaEqlistEntry(3),
    };
    assert.equal(
      isStructurallyValidHttpSnapshot(
        "jma_eqlist",
        gappedList,
        [
          normalizedJmaEqlistEntry(gappedList.No1),
          normalizedJmaEqlistEntry(gappedList.No3),
        ],
      ),
      false,
      "ranked snapshots must not skip an entry",
    );
    const contiguousList = {
      md5: "12121212121212121212121212121212",
      No1: rankedReport,
      No2: jmaEqlistEntry(2),
    };
    assert.equal(
      isStructurallyValidHttpSnapshot(
        "jma_eqlist",
        contiguousList,
        [
          normalizedJmaEqlistEntry(contiguousList.No1),
          normalizedJmaEqlistEntry(contiguousList.No2),
        ],
      ),
      true,
      "an exact No1...NoN ranked snapshot remains valid",
    );
    const malformedList = {
      md5: "51515151515151515151515151515151",
      No51: jmaEqlistEntry(50),
    };
    assert.equal(
      isStructurallyValidHttpSnapshot(
        "jma_eqlist",
        malformedList,
        [normalizedJmaEqlistEntry(malformedList.No51)],
      ),
      false,
      "No51 must be rejected before it can create unbounded D1/outbox work",
    );
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("upstream snapshots reject non-finite and out-of-range coordinates", async () => {
  const { isStructurallyValidHttpSnapshot } = await workerModule();
  const raw = jmaEewSnapshot({
    Latitude: 90,
    Longitude: 180,
  });
  const normalized = normalizedJmaEewSnapshot(raw);

  assert.equal(
    isStructurallyValidHttpSnapshot("jma_eew", raw, [normalized]),
    true,
    "inclusive WGS 84 boundaries remain valid",
  );

  for (const [label, rawMutation, normalizedMutation] of [
    ["raw latitude above 90", { Latitude: 90.000_001 }, {}],
    ["raw longitude below -180", { Longitude: -180.000_001 }, {}],
    ["normalized latitude above 90", {}, { latitude: 90.000_001 }],
    ["normalized longitude above 180", {}, { longitude: 180.000_001 }],
    ["non-finite normalized latitude", {}, { latitude: Number.POSITIVE_INFINITY }],
  ]) {
    const candidate = { ...raw, ...rawMutation };
    assert.equal(
      isStructurallyValidHttpSnapshot(
        "jma_eew",
        candidate,
        [normalizedJmaEewSnapshot(candidate, normalizedMutation)],
      ),
      false,
      label,
    );
  }

  const reportRaw = {
    md5: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    No1: jmaEqlistEntry(1, { longitude: "181" }),
  };
  assert.equal(
    isStructurallyValidHttpSnapshot(
      "jma_eqlist",
      reportRaw,
      [normalizedJmaEqlistEntry(reportRaw.No1)],
    ),
    false,
    "ranked report raw coordinates use the same range validation",
  );
  const validReportRaw = {
    md5: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    No1: jmaEqlistEntry(1),
  };
  assert.equal(
    isStructurallyValidHttpSnapshot(
      "jma_eqlist",
      validReportRaw,
      [normalizedJmaEqlistEntry(validReportRaw.No1, { longitude: 181 })],
    ),
    false,
    "ranked report normalized coordinates use the same range validation",
  );
});

test("JMA wire domains reject rollover and coercion while preserving documented boundaries", async () => {
  const { isStructurallyValidHttpSnapshot } = await workerModule();
  const validEew = (raw, normalizedOverrides = {}) =>
    isStructurallyValidHttpSnapshot(
      "jma_eew",
      raw,
      [normalizedJmaEewSnapshot(raw, normalizedOverrides)],
    );
  const validList = (entry, normalizedOverrides = {}, md5 = "cccccccccccccccccccccccccccccccc") => {
    const raw = { md5, No1: entry };
    return isStructurallyValidHttpSnapshot(
      "jma_eqlist",
      raw,
      [normalizedJmaEqlistEntry(entry, normalizedOverrides)],
    );
  };

  const lowBoundaryEew = jmaEewSnapshot({
    EventID: "20240229000000",
    OriginTime: "2024/02/29 00:00:00",
    AnnouncedTime: "2024/02/29 00:00:00",
    Magunitude: -2,
    Depth: 0,
    MaxIntensity: "0",
  });
  const highBoundaryEew = jmaEewSnapshot({
    Magunitude: 12,
    Depth: 1_000,
    MaxIntensity: "7",
  });
  assert.equal(validEew(lowBoundaryEew), true, "leap day and lower domains remain valid");
  assert.equal(validEew(highBoundaryEew), true, "upper documented safety domains remain valid");
  for (const intensity of ["0", "1", "2", "3", "4", "5-", "5+", "6-", "6+", "7"]) {
    const raw = jmaEewSnapshot({ MaxIntensity: intensity });
    assert.equal(validEew(raw), true, `JMA EEW intensity ${intensity} remains valid`);
  }

  for (const [label, mutation] of [
    ["rollover EventID", { EventID: "20260230000000" }],
    ["rollover origin", { OriginTime: "2026/02/30 12:00:00" }],
    ["rollover announcement", { AnnouncedTime: "2026/08/13 12:00:60" }],
    ["announcement before origin", { AnnouncedTime: "2026/08/13 11:59:59" }],
    ["string magnitude", { Magunitude: "4.2" }],
    ["magnitude below bound", { Magunitude: -2.01 }],
    ["magnitude above bound", { Magunitude: 12.01 }],
    ["negative depth", { Depth: -1 }],
    ["depth above bound", { Depth: 1_000.01 }],
    ["non-domain intensity", { MaxIntensity: "5" }],
  ]) {
    const raw = jmaEewSnapshot(mutation);
    assert.equal(validEew(raw), false, label);
  }

  const lowBoundaryEntry = jmaEqlistEntry(1, {
    EventID: "20240229000059",
    time: "2024/02/29 00:00",
    time_full: "2024/02/29 00:00:59",
    magnitude: "-2",
    shindo: "0",
    depth: "0km",
    latitude: "-90",
    longitude: "-180",
  });
  const highBoundaryEntry = jmaEqlistEntry(1, {
    magnitude: "12",
    shindo: "7",
    depth: "1000km",
    latitude: "90",
    longitude: "180",
  });
  assert.equal(validList(lowBoundaryEntry), true, "canonical lower list boundaries remain valid");
  assert.equal(validList(highBoundaryEntry), true, "canonical upper list boundaries remain valid");
  assert.equal(
    validList(jmaEqlistEntry(1, { EventID: "20260814090203" })),
    true,
    "a valid JMA origin EventID may precede or follow the report publication minute",
  );
  for (const intensity of ["0", "1", "2", "3", "4", "5-", "5+", "6-", "6+", "7"]) {
    const entry = jmaEqlistEntry(1, { shindo: intensity });
    assert.equal(validList(entry), true, `JMA report intensity ${intensity} remains valid`);
  }

  for (const [label, mutation, md5] of [
    ["rollover list EventID", { EventID: "20260230000000" }],
    ["rollover minute time", { EventID: "20260228090001", time: "2026/02/30 09:00", time_full: "2026/02/28 09:00:00" }],
    ["rollover full time", { time_full: "2026/08/14 09:00:60" }],
    ["time/full-time mismatch", { time_full: "2026/08/14 09:01:00" }],
    ["nonnumeric magnitude", { magnitude: "abc" }],
    ["noncanonical magnitude", { magnitude: "+4.2" }],
    ["noncanonical latitude", { latitude: " 35.1" }],
    ["noncanonical longitude", { longitude: "+140.2" }],
    ["sign-only depth", { depth: "+" }],
    ["fractional depth", { depth: "10.5km" }],
    ["leading-zero depth", { depth: "010km" }],
    ["depth above bound", { depth: "1001km" }],
    ["non-domain shindo", { shindo: "5" }],
    ["nonhex md5", {}, "not-a-canonical-md5"],
    ["uppercase md5", {}, "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"],
  ]) {
    const entry = jmaEqlistEntry(1, mutation);
    assert.equal(validList(entry, {}, md5), false, label);
  }

  const listEntry = jmaEqlistEntry(1);
  const normalizedListEntry = normalizedJmaEqlistEntry(listEntry);
  const listRaw = { md5: "dddddddddddddddddddddddddddddddd", No1: listEntry };
  for (const [field, mismatch] of [
    ["id", "jma_eqlist:20260814090002"],
    ["sourceId", "jma_eew"],
    ["eventId", "20260814090002"],
    ["serial", 2],
    ["kind", "eew"],
    ["originTimeUtc", "2026-08-14T00:00:01.000Z"],
    ["reportTimeUtc", "2026-08-14T00:00:01.000Z"],
    ["hypocenter", "Other coast"],
    ["latitude", 35.2],
    ["longitude", 140.3],
    ["magnitude", 4.3],
    ["depth", 11],
    ["maxIntensity", "3"],
    ["isWarn", true],
    ["isFinal", false],
    ["isCancel", true],
    ["isTraining", true],
    ["tsunami", "unexpected"],
    ["raw", { ...listEntry }],
  ]) {
    assert.equal(
      isStructurallyValidHttpSnapshot(
        "jma_eqlist",
        listRaw,
        [{ ...normalizedListEntry, [field]: mismatch }],
      ),
      false,
      `normalized list ${field} must match its exact raw-derived value`,
    );
  }
});

test("queued event validation requires strict numeric in-range coordinates", async () => {
  const {
    APNS_RELAY_DISABLED_SOURCES,
    APNS_RELAY_SOURCES,
    dispatchPushPage,
    isApnsRelaySource,
    isQueuedEvent,
  } = await workerModule();
  const event = message(1).event;
  assert.deepEqual(APNS_RELAY_SOURCES, ["jma_eew", "jma_eqlist"]);
  assert.equal(isApnsRelaySource("jma_eew"), true);
  assert.equal(isApnsRelaySource("jma_eqlist"), true);
  for (const sourceId of APNS_RELAY_DISABLED_SOURCES) {
    assert.equal(isApnsRelaySource(sourceId), false);
    assert.equal(
      isQueuedEvent({
        ...event,
        id: `${sourceId}:example`,
        sourceId,
        kind: sourceId.endsWith("eqlist") ? "report" : "eew",
      }),
      false,
      `${sourceId} cannot enter Queue delivery`,
    );
  }
  assert.equal(isQueuedEvent(event), true);
  assert.equal(isQueuedEvent({ ...event, latitude: "35" }), false);
  assert.equal(isQueuedEvent({ ...event, longitude: "139" }), false);
  assert.equal(isQueuedEvent({ ...event, latitude: 90.000_001 }), false);
  assert.equal(isQueuedEvent({ ...event, longitude: -180.000_001 }), false);
  assert.equal(isQueuedEvent({ ...event, id: "jma_eew:other" }), false);

  let databaseTouched = false;
  await assert.rejects(
    dispatchPushPage(
      {
        get DB() {
          databaseTouched = true;
          throw new Error("disabled delivery must stop before D1");
        },
      },
      { ...event, id: "cenc_eew:example", sourceId: "cenc_eew" },
      "new",
      "unused",
      "disabled-source-delivery",
    ),
    /source is not permitted/i,
  );
  assert.equal(databaseTouched, false);
});

test("disabled sources stop before live journaling or HTTP recovery I/O", async () => {
  const { QuakeRelay } = await workerModule();
  let storageTouched = false;
  let databaseTouched = false;
  let networkTouched = false;
  const originalFetch = globalThis.fetch;
  const originalConsoleError = console.error;
  const errors = [];
  globalThis.fetch = async () => {
    networkTouched = true;
    throw new Error("disabled recovery must not fetch");
  };
  console.error = (entry) => errors.push(JSON.parse(entry));
  try {
    const relay = new QuakeRelay(
      {
        storage: {
          get() { storageTouched = true; throw new Error("disabled ingest must not read storage"); },
          transaction() { storageTouched = true; throw new Error("disabled ingest must not write storage"); },
        },
        waitUntil() {},
      },
      {
        get DB() {
          databaseTouched = true;
          throw new Error("disabled ingest must not reach D1");
        },
      },
    );
    const blockedEvent = {
      ...message(1).event,
      id: "cenc_eew:example",
      sourceId: "cenc_eew",
    };
    await relay.enqueueLiveIngest(blockedEvent);
    assert.deepEqual(errors, [{
      sourceId: "cenc_eew",
      outcome: "disabled_source_live_ingest_rejected",
    }]);
    assert.deepEqual(
      await relay.seedHttpSource("cenc_eqlist", "recovery"),
      { completed: false, snapshotWorkStarted: false },
    );
    assert.equal(storageTouched, false);
    assert.equal(databaseTouched, false);
    assert.equal(networkTouched, false);
  } finally {
    console.error = originalConsoleError;
    globalThis.fetch = originalFetch;
  }
});

test("live point-event listeners reject out-of-range coordinates before liveness or ingest", async () => {
  const { QuakeRelay } = await workerModule();
  const pending = new Set();
  const backgroundErrors = [];
  const ingested = [];
  const liveness = [];
  const values = new Map();
  let alarmAt = null;
  const state = {
    storage: {
      async get(key) { return values.get(key); },
      async put(key, value) { values.set(key, value); },
      async list() { return new Map(); },
      async getAlarm() { return alarmAt; },
      async setAlarm(value) { alarmAt = value; },
    },
    waitUntil(promise) {
      let tracked;
      tracked = Promise.resolve(promise)
        .catch((error) => backgroundErrors.push(error))
        .finally(() => pending.delete(tracked));
      pending.add(tracked);
    },
  };
  class Socket {
    readyState = 1;
    closeCalls = 0;
    listeners = new Map();

    addEventListener(type, listener) {
      this.listeners.set(type, listener);
    }

    emit(type, event) {
      this.listeners.get(type)?.(event);
    }

    close() {
      this.closeCalls += 1;
      this.readyState = 3;
    }
  }
  const drain = async () => {
    for (let pass = 0; pass < 10 && pending.size > 0; pass += 1) {
      await Promise.all([...pending]);
    }
    assert.equal(pending.size, 0);
    assert.deepEqual(backgroundErrors, []);
  };
  const frame = jmaEewFrame();
  const relay = new QuakeRelay(state, {});
  relay.enqueueLiveIngest = async (event) => ingested.push(event);
  relay.recordUpstreamTransportLiveness = async (...arguments_) => liveness.push(arguments_);
  const socket = new Socket();
  relay.upstreams.set("jma_eew", socket);
  relay.readyUpstreamSockets.set("jma_eew", socket);
  relay.statuses.set("jma_eew", "open");
  relay.lastSuccessfulUpstreamMs.set("jma_eew", Date.now());
  relay.attachUpstreamSocketListeners("jma_eew", socket);

  const originalConsoleWarn = console.warn;
  try {
    console.warn = () => {};
    socket.emit("message", {
      data: JSON.stringify({ ...frame, Latitude: 90.000_001 }),
    });
    await drain();
    assert.deepEqual(ingested, [], "invalid live coordinates never reach durable ingest");
    assert.deepEqual(liveness, [], "invalid live coordinates never publish source liveness");
    assert.equal(socket.closeCalls, 1, "invalid data closes its current socket");
    assert.equal(relay.upstreams.has("jma_eew"), false);
    assert.equal(relay.readyUpstreamSockets.has("jma_eew"), false);
    assert.equal(relay.statuses.get("jma_eew"), "error");
    assert.equal(values.get("upstream-reconnect-failures:jma_eew"), 1);
    assert.ok(alarmAt > 0, "invalid data schedules a bounded reconnect");

    socket.emit("message", { data: JSON.stringify(wolfxHeartbeat()) });
    await drain();
    assert.deepEqual(
      liveness,
      [],
      "a buffered heartbeat from the rejected socket cannot restore liveness",
    );
    assert.equal(relay.statuses.get("jma_eew"), "error");

    const replacement = new Socket();
    relay.upstreams.set("jma_eew", replacement);
    relay.attachUpstreamSocketListeners("jma_eew", replacement);
    replacement.emit("message", { data: JSON.stringify(frame) });
    await drain();
    assert.equal(ingested.length, 1, "a valid live point event still reaches ingest");
    assert.equal(ingested[0].latitude, 35.1);
    assert.equal(liveness.length, 1, "valid point traffic records transport liveness");
  } finally {
    console.warn = originalConsoleWarn;
  }
});

test("non-text, malformed, missing, and unknown Wolfx frames each reconnect fail closed", async () => {
  const { QuakeRelay } = await workerModule();
  const originalConsoleWarn = console.warn;
  const values = new Map();
  const pending = new Set();
  const failures = [];
  let alarmAt = null;
  const state = {
    storage: {
      async get(key) { return values.get(key); },
      async put(key, value) { values.set(key, value); },
      async list() { return new Map(); },
      async getAlarm() { return alarmAt; },
      async setAlarm(value) { alarmAt = value; },
    },
    waitUntil(promise) {
      let tracked;
      tracked = Promise.resolve(promise)
        .catch((error) => failures.push(error))
        .finally(() => pending.delete(tracked));
      pending.add(tracked);
    },
  };
  class Socket {
    readyState = 1;
    closeCalls = 0;
    listeners = new Map();

    addEventListener(type, listener) {
      this.listeners.set(type, listener);
    }

    emit(type, event) {
      this.listeners.get(type)?.(event);
    }

    close() {
      this.closeCalls += 1;
      this.readyState = 3;
    }
  }
  const drain = async () => {
    for (let pass = 0; pass < 20 && pending.size > 0; pass += 1) {
      await Promise.all([...pending]);
    }
    assert.equal(pending.size, 0);
    assert.deepEqual(failures, []);
  };
  const frames = [
    { data: new Uint8Array([1]) },
    { data: "{" },
    { data: JSON.stringify({ EventID: "missing-route-type" }) },
    { data: JSON.stringify({ type: "unknown" }) },
    { data: JSON.stringify({ type: "jma_eew" }) },
    { data: JSON.stringify({ type: "heartbeat" }) },
    { data: JSON.stringify({ type: "pong" }) },
  ];
  const relay = new QuakeRelay(state, {});
  try {
    console.warn = () => {};
    for (const [index, frame] of frames.entries()) {
      const socket = new Socket();
      relay.upstreams.set("jma_eew", socket);
      relay.readyUpstreamSockets.set("jma_eew", socket);
      relay.statuses.set("jma_eew", "open");
      relay.lastSuccessfulUpstreamMs.set("jma_eew", Date.now());
      relay.attachUpstreamSocketListeners("jma_eew", socket);

      socket.emit("message", frame);
      await drain();

      assert.equal(socket.closeCalls, 1);
      assert.equal(relay.upstreams.has("jma_eew"), false);
      assert.equal(relay.readyUpstreamSockets.has("jma_eew"), false);
      assert.equal(relay.statuses.get("jma_eew"), "error");
      assert.equal(
        values.get("upstream-reconnect-failures:jma_eew"),
        index + 1,
        "each rejected current socket owns exactly one reconnect transition",
      );
    }
  } finally {
    console.warn = originalConsoleWarn;
  }
});

test("strict Wolfx wire domains reject before persistence and cannot regain readiness", async () => {
  const { QuakeRelay } = await workerModule();
  const originalConsoleWarn = console.warn;

  class Socket {
    readyState = 1;
    closeCalls = 0;
    listeners = new Map();

    addEventListener(type, listener) {
      this.listeners.set(type, listener);
    }

    emit(type, event) {
      this.listeners.get(type)?.(event);
    }

    close() {
      this.closeCalls += 1;
      this.readyState = 3;
    }
  }

  const createHarness = () => {
    const values = new Map();
    const pending = new Set();
    const failures = [];
    let alarmAt = null;
    const state = {
      storage: {
        async get(key) { return values.get(key); },
        async put(key, value) { values.set(key, value); },
        async delete(key) { values.delete(key); },
        async list() { return new Map(); },
        async getAlarm() { return alarmAt; },
        async setAlarm(value) { alarmAt = value; },
      },
      waitUntil(promise) {
        let tracked;
        tracked = Promise.resolve(promise)
          .catch((error) => failures.push(error))
          .finally(() => pending.delete(tracked));
        pending.add(tracked);
      },
    };
    const drain = async () => {
      for (let pass = 0; pass < 30 && pending.size > 0; pass += 1) {
        await Promise.all([...pending]);
      }
      assert.equal(pending.size, 0);
      assert.deepEqual(failures, []);
    };
    return { alarmAt: () => alarmAt, drain, state, values };
  };

  const listFrame = (entryMutation = {}, envelopeMutation = {}) => {
    const frame = jmaEqlistSnapshot(1);
    frame.No1 = { ...frame.No1, ...entryMutation };
    return { ...frame, ...envelopeMutation };
  };
  const withoutBooleans = jmaEewFrame();
  for (const field of [
    "isSea",
    "isTraining",
    "isAssumption",
    "isWarn",
    "isFinal",
    "isCancel",
  ]) delete withoutBooleans[field];
  const rejectedFrames = [
    ["string heartbeat version", "jma_eew", wolfxHeartbeat({ ver: "22" })],
    ["zero heartbeat version", "jma_eew", wolfxHeartbeat({ ver: 0 })],
    ["fractional heartbeat version", "jma_eew", wolfxHeartbeat({ ver: 22.5 })],
    ["oversized heartbeat version", "jma_eew", wolfxHeartbeat({ ver: 100_000_000 })],
    ["noncanonical heartbeat id", "jma_eew", wolfxHeartbeat({ id: "connection" })],
    ["leading-zero heartbeat id", "jma_eew", wolfxHeartbeat({ id: "02094581" })],
    ["oversized heartbeat id", "jma_eew", wolfxHeartbeat({ id: "1".repeat(21) })],
    ["numeric heartbeat id", "jma_eew", wolfxHeartbeat({ id: 2094581 })],
    ["noncanonical heartbeat timestamp", "jma_eew", wolfxHeartbeat({ timestamp: "01786665600000" })],
    ["short numeric heartbeat timestamp", "jma_eew", wolfxHeartbeat({ timestamp: 999_999_999_999 })],
    ["long numeric heartbeat timestamp", "jma_eew", wolfxHeartbeat({ timestamp: 10_000_000_000_000 })],
    ["fractional heartbeat timestamp", "jma_eew", wolfxHeartbeat({ timestamp: 1787241213884.5 })],
    ["object heartbeat timestamp", "jma_eew", wolfxHeartbeat({ timestamp: {} })],
    ["noncanonical pong timestamp", "jma_eew", wolfxPong({ timestamp: "now" })],
    ["rollover EEW EventID", "jma_eew", jmaEewFrame({ EventID: "20260230000000" })],
    ["rollover EEW origin", "jma_eew", jmaEewFrame({ OriginTime: "2026/02/30 12:00:00" })],
    ["coercible EEW magnitude", "jma_eew", jmaEewFrame({ Magunitude: "4.2" })],
    ["negative EEW depth", "jma_eew", jmaEewFrame({ Depth: -1 })],
    ["invalid EEW intensity", "jma_eew", jmaEewFrame({ MaxIntensity: "5" })],
    ["missing EEW booleans", "jma_eew", withoutBooleans],
    ["nonhex list md5", "jma_eqlist", listFrame({}, { md5: "invalid" })],
    ["rollover list time", "jma_eqlist", listFrame({ time_full: "2026/08/14 09:00:60" })],
    ["coercible list magnitude", "jma_eqlist", listFrame({ magnitude: "abc" })],
    ["sign-only list depth", "jma_eqlist", listFrame({ depth: "+" })],
    ["invalid list intensity", "jma_eqlist", listFrame({ shindo: "5" })],
    ["noncanonical list coordinate", "jma_eqlist", listFrame({ latitude: "+35.1" })],
  ];

  const rejectCase = async ([label, route, frame]) => {
    const harness = createHarness();
    const relay = new QuakeRelay(harness.state, {});
    const socket = new Socket();
    let persistenceCalls = 0;
    relay.enqueueLiveIngest = async () => { persistenceCalls += 1; };
    relay.enqueueLiveSnapshot = async () => { persistenceCalls += 1; };
    relay.upstreams.set(route, socket);
    relay.statuses.set(route, "connecting");
    relay.validatedUpstreamDataSockets.set(route, {
      socket,
      durableIntentRecorded: true,
    });
    relay.attachUpstreamSocketListeners(route, socket);

    socket.emit("message", { data: JSON.stringify(frame) });
    await harness.drain();
    // Model an older successful persistence completion resuming after the
    // invalid frame synchronously revoked this socket's candidate.
    await relay.markSourceSuccessfulAndPublishReadiness(route);

    assert.equal(persistenceCalls, 0, `${label} must stop before persistence`);
    assert.equal(socket.closeCalls, 1, `${label} must close its socket`);
    assert.equal(relay.upstreams.has(route), false, `${label} must detach its socket`);
    assert.equal(relay.validatedUpstreamDataSockets.has(route), false, `${label} must revoke its candidate`);
    assert.equal(relay.readyUpstreamSockets.has(route), false, `${label} must remain unready`);
    assert.equal(relay.routeIsOpen(route), false, `${label} must fail route readiness`);
    assert.equal(relay.statuses.get(route), "error", `${label} must retain error status`);
    assert.equal(harness.values.get(`upstream-reconnect-failures:${route}`), 1);
    assert.ok(harness.alarmAt() > 0, `${label} must schedule reconnect`);
  };

  const acceptDataCase = async (label, route, frame) => {
    const harness = createHarness();
    const relay = new QuakeRelay(harness.state, {});
    const socket = new Socket();
    let persistenceCalls = 0;
    const commit = async (source, readinessCandidate) => {
      persistenceCalls += 1;
      readinessCandidate.durableIntentRecorded = true;
      await relay.markSourceSuccessfulAndPublishReadiness(source);
    };
    relay.enqueueLiveIngest = async (_event, readinessCandidate) =>
      commit(route, readinessCandidate);
    relay.enqueueLiveSnapshot = async (_source, _events, readinessCandidate) =>
      commit(route, readinessCandidate);
    relay.upstreams.set(route, socket);
    relay.statuses.set(route, "connecting");
    relay.attachUpstreamSocketListeners(route, socket);

    socket.emit("message", { data: JSON.stringify(frame) });
    await harness.drain();

    assert.equal(persistenceCalls, 1, `${label} must cross simulated persistence once`);
    assert.equal(socket.closeCalls, 0, `${label} must keep its socket`);
    assert.equal(relay.readyUpstreamSockets.get(route), socket);
    assert.equal(relay.routeIsOpen(route), true, `${label} must become ready only after commit`);
    assert.equal(relay.statuses.get(route), "open");
  };

  try {
    console.warn = () => {};
    for (const rejectedFrame of rejectedFrames) await rejectCase(rejectedFrame);

    await acceptDataCase(
      "valid EEW leap/minimum boundary",
      "jma_eew",
      jmaEewFrame({
        EventID: "20240229000000",
        OriginTime: "2024/02/29 00:00:00",
        AnnouncedTime: "2024/02/29 00:00:00",
        Magunitude: -2,
        Depth: 0,
        MaxIntensity: "0",
      }),
    );
    await acceptDataCase(
      "valid list maximum boundary",
      "jma_eqlist",
      listFrame({
        magnitude: "12",
        depth: "1000km",
        shindo: "7",
        latitude: "90",
        longitude: "180",
      }),
    );

    for (const route of ["jma_eew", "jma_eqlist"]) {
      const controlHarness = createHarness();
      const controlRelay = new QuakeRelay(controlHarness.state, {});
      const controlSocket = new Socket();
      controlRelay.upstreams.set(route, controlSocket);
      controlRelay.statuses.set(route, "connecting");
      controlRelay.attachUpstreamSocketListeners(route, controlSocket);
      // Exact public frames observed on both JMA routes remain valid alongside
      // the documented UUID/string representation.
      controlSocket.emit("message", { data: JSON.stringify(wolfxHeartbeat()) });
      controlSocket.emit("message", { data: JSON.stringify(wolfxPong()) });
      controlSocket.emit("message", {
        data: JSON.stringify(wolfxHeartbeat({
          ver: 20260415,
          id: "123e4567-e89b-42d3-a456-426614174000",
          timestamp: "1787241213884",
        })),
      });
      controlSocket.emit("message", {
        data: JSON.stringify(wolfxPong({ timestamp: "1787241234570" })),
      });
      await controlHarness.drain();
      assert.equal(
        controlSocket.closeCalls,
        0,
        `${route} accepts documented and observed control representations`,
      );
      assert.equal(controlRelay.upstreams.get(route), controlSocket);
      assert.equal(controlRelay.routeIsOpen(route), false, "valid controls remain watchdog-only");
      assert.equal(controlRelay.readyUpstreamSockets.has(route), false);
    }
  } finally {
    console.warn = originalConsoleWarn;
  }
});

test("HTTP report lists resume in D1-safe slices and remain health-stale until complete", async () => {
  const { QuakeRelay } = await workerModule();
  const values = new Map();
  const now = Date.now();
  const state = {
    storage: {
      async get(key) {
        return values.get(key);
      },
      async put(key, value) {
        values.set(key, value);
      },
      async delete(key) {
        values.delete(key);
      },
      async list({ prefix = "" } = {}) {
        return new Map([...values].filter(([key]) => key.startsWith(prefix)));
      },
      async transaction(callback) {
        return callback({
          get: this.get.bind(this),
          put: this.put.bind(this),
          delete: this.delete.bind(this),
        });
      },
    },
    waitUntil() {},
  };
  const relay = new QuakeRelay(state, {
    APNS_PRIVATE_KEY: "test-key",
    APNS_KEY_ID: "test-key-id",
    APNS_TEAM_ID: "test-team-id",
    APNS_BUNDLE_ID: "com.quakesignal.app",
  });
  relay.apnsAuthorization = async () => "bearer cached-test";
  for (const source of [
    "jma_eew",
    "sc_eew",
    "cenc_eew",
    "fj_eew",
    "cq_eew",
    "cenc_eqlist",
    "jma_eqlist",
  ]) {
    relay.statuses.set(source, "open");
    relay.lastSuccessfulUpstreamMs.set(source, now);
  }
  const snapshots = Array.from({ length: 50 }, (_, index) => ({
    id: `jma_eqlist:bounded-${index + 1}`,
    sourceId: "jma_eqlist",
    eventId: `bounded-${index + 1}`,
    serial: 1,
    kind: "report",
    originTimeUtc: "2026-08-13T03:00:00.000Z",
    reportTimeUtc: "2026-08-13T03:00:00.000Z",
    hypocenter: "Test coast",
    latitude: 35.1,
    longitude: 140.2,
    magnitude: 4.2,
    depth: 10,
    maxIntensity: null,
    isWarn: false,
    isFinal: true,
    isCancel: false,
    isTraining: false,
    tsunami: null,
  }));
  const key = "pending-http-snapshot:jma_eqlist";
  values.set(key, {
    version: 1,
    source: "jma_eqlist",
    mode: "recovery",
    fingerprint: "bounded-fingerprint",
    events: snapshots,
    nextIndex: 0,
  });
  let readCalls = 0;
  let writeStatements = 0;
  relay.env.DB = {
    prepare() {
      return {
        bind() {
          return {
            async first() {
              return 0;
            },
            async all() {
              readCalls += 1;
              return { results: [] };
            },
          };
        },
      };
    },
    async batch(statements) {
      writeStatements += statements.length;
      return statements.map(() => ({ meta: { changes: 1 } }));
    },
  };
  relay.flushAlertDeliveryOutbox = async () => {};
  const before = await relay.statusResponse();
  assert.equal(before.status, 503, "a partial HTTP cursor cannot report ready");
  const beforeBody = await before.json();
  assert.equal(
    beforeBody.upstream.sources.jma_eqlist.pendingHttpSnapshot,
    true,
  );
  assert.equal(
    beforeBody.upstream.sources.jma_eqlist.stale,
    true,
    "a fresh WebSocket cannot hide a partly durable report list",
  );
  assert.equal(
    beforeBody.upstream.sources.jma_eqlist.transport,
    "websocket",
    "the source reports its live transport without claiming its cursor complete",
  );
  for (let slice = 0; slice < 6; slice += 1) {
    await relay.seedHttpSource("jma_eqlist", "initial");
  }
  const remaining = values.get(key);
  assert.equal(remaining.nextIndex, 48, "six slices persist exactly 48 reports");
  assert.equal(remaining.mode, "recovery", "resume never suppresses recovery semantics");
  assert.equal(readCalls, 6, "each slice makes one D1 prior-state read");
  assert.ok(writeStatements <= 6 * 24, "each D1 write batch remains bounded");
  await relay.seedHttpSource("jma_eqlist", "initial");
  assert.equal(values.has(key), false, "final slice commits the fingerprint and clears cursor");
  assert.equal(
    typeof values.get("upstream-http-fingerprint:jma_eqlist"),
    "string",
  );
});

test("routine alarms keep a bounded outbox hand-off budget before HTTP fallback", async () => {
  const { QuakeRelay } = await workerModule();
  const values = new Map([["last-device-purge-ms", Date.now()]]);
  const state = {
    storage: {
      async get(key) { return values.get(key); },
      async put(key, value) { values.set(key, value); },
      async delete(key) { values.delete(key); },
      async list() { return new Map(); },
      async getAlarm() { return null; },
      async setAlarm() {},
    },
    waitUntil() {},
  };
  const relay = new QuakeRelay(state, {});
  const calls = [];
  relay.reconcileDlqPersistenceFallbacks = async () => {};
  relay.migrateLegacyPendingDeliveries = async () => {};
  relay.drainPendingIngestJournal = async () => {};
  relay.flushAlertDeliveryOutbox = async (limit) => { calls.push(limit); };
  relay.purgeExpiredDevicesIfDue = async () => {};
  relay.refreshHttpFallbackActive = async () => false;
  relay.pendingHttpSnapshotSources = async () => [];
  relay.nextDueHttpSeedMode = async () => null;
  relay.seedFromHttp = async () => {};
  relay.ensureUpstreams = async () => {};
  relay.scheduleRoutineRelayAlarm = async () => {};
  await relay.alarm();
  assert.deepEqual(calls, [8], "routine alarm never claims 50 rows before fallback work");
});

test("health reports HTTP polling as ready only while every fallback source is fresh", async () => {
  const { QuakeRelay } = await workerModule();
  const now = Date.now();
  const values = new Map([["http-fallback-active", true]]);
  for (const source of [
    "jma_eew",
    "sc_eew",
    "cenc_eew",
    "fj_eew",
    "cq_eew",
    "cenc_eqlist",
    "jma_eqlist",
  ]) {
    values.set(`upstream-last-http-success-ms:${source}`, now);
  }
  const statement = {
    bind() {
      return this;
    },
    async first() {
      return 0;
    },
  };
  const state = {
    storage: {
      async get(key) {
        return values.get(key);
      },
      async list() {
        return new Map();
      },
    },
    waitUntil() {},
  };
  const relay = new QuakeRelay(state, {
    DB: { prepare: () => statement },
    APNS_PRIVATE_KEY: "test-key",
    APNS_KEY_ID: "test-key-id",
    APNS_TEAM_ID: "test-team-id",
    APNS_BUNDLE_ID: "com.quakesignal.app",
  });
  relay.apnsAuthorization = async () => "bearer cached-test";
  for (const source of [
    "jma_eew",
    "sc_eew",
    "cenc_eew",
    "fj_eew",
    "cq_eew",
    "cenc_eqlist",
    "jma_eqlist",
  ]) {
    relay.statuses.set(source, "error");
  }

  const healthy = await relay.statusResponse();
  assert.equal(healthy.status, 200);
  const healthyBody = await healthy.json();
  assert.equal(healthyBody.upstream.transport, "http-polling");
  assert.equal(healthyBody.upstream.websocketStatus, "degraded");
  assert.equal(healthyBody.upstream.sources.jma_eew.transport, "http-polling");

  values.set("upstream-last-http-success-ms:jma_eew", now - 181_000);
  const stale = await relay.statusResponse();
  assert.equal(stale.status, 503, "one stale fallback source fails readiness closed");
  const staleBody = await stale.json();
  assert.deepEqual(staleBody.upstream.staleSources, ["jma_eew"]);
});

test("health status reads the fallback marker without Durable Object writes", async () => {
  const { QuakeRelay } = await workerModule();
  const now = Date.now();
  const values = new Map([["http-fallback-active", true]]);
  let writeAttempts = 0;
  const statement = {
    bind() {
      return this;
    },
    async first() {
      return 0;
    },
  };
  const state = {
    storage: {
      async get(key) {
        return values.get(key);
      },
      async list() {
        return new Map();
      },
      async put() {
        writeAttempts += 1;
        throw new Error("Durable Object free-tier write quota exhausted");
      },
      async delete() {
        writeAttempts += 1;
        throw new Error("Durable Object free-tier write quota exhausted");
      },
    },
    waitUntil() {},
  };
  const relay = new QuakeRelay(state, {
    DB: { prepare: () => statement },
  });
  for (const source of [
    "jma_eew",
    "sc_eew",
    "cenc_eew",
    "fj_eew",
    "cq_eew",
    "cenc_eqlist",
    "jma_eqlist",
  ]) {
    relay.statuses.set(source, "open");
    relay.lastSuccessfulUpstreamMs.set(source, now);
  }

  for (const storedFallbackActive of [true, false]) {
    values.set("http-fallback-active", storedFallbackActive);
    const response = await relay.statusResponse();
    assert.equal(response.status, 503, "missing APNs stays fail-closed");
    const body = await response.json();
    assert.equal(body.ok, false);
    assert.equal(body.delivery.status, "not_configured");
    assert.equal(body.upstream.status, "ready");
    assert.equal(body.upstream.httpFallbackActive, storedFallbackActive);
  }
  assert.equal(writeAttempts, 0, "health must not refresh or clear a stored fallback marker");
});

test("serializes an opened route reset before its next close records backoff", async () => {
  const { QuakeRelay } = await workerModule();
  const originalConsoleWarn = console.warn;
  const values = new Map();
  let alarmAt = null;
  const state = {
    storage: {
      async get(key) {
        return values.get(key);
      },
      async put(key, value) {
        values.set(key, value);
      },
      async getAlarm() {
        return alarmAt;
      },
      async setAlarm(value) {
        alarmAt = value;
      },
    },
    waitUntil() {},
  };
  const relay = new QuakeRelay(state, {});
  console.warn = () => {};
  try {
    // These two operations model an immediate close after a route just became
    // usable. The queue must retain the close's failure state rather than
    // letting the older reset zero its persisted retry gate afterwards.
    await Promise.all([
      relay.resetUpstreamReconnectBackoff("jma_eew"),
      relay.scheduleUpstreamReconnect(
        "jma_eew",
        "wolfx_upstream_websocket_closed",
        { closeCode: 1006, wasClean: false, closeReasonPresent: false },
        "closed",
      ),
    ]);
    assert.equal(values.get("upstream-reconnect-failures:jma_eew"), 1);
    assert.ok(
      values.get("upstream-reconnect-not-before-ms:jma_eew") > Date.now(),
    );
    assert.ok(values.get("upstream-degraded-since-ms:jma_eew") > 0);
    assert.ok(alarmAt > Date.now());
  } finally {
    console.warn = originalConsoleWarn;
  }
});

test("a websocket listener owns recovery when send fails after an Upgrade", async () => {
  const { QuakeRelay } = await workerModule();
  const originalFetch = globalThis.fetch;
  const originalConsoleWarn = console.warn;
  const values = new Map();
  const warnings = [];
  const pending = new Set();
  const failures = [];
  let alarmAt = null;
  const state = {
    storage: {
      async get(key) {
        return values.get(key);
      },
      async put(key, value) {
        values.set(key, value);
      },
      async list() {
        return new Map();
      },
      async getAlarm() {
        return alarmAt;
      },
      async setAlarm(value) {
        alarmAt = value;
      },
    },
    waitUntil(promise) {
      let tracked;
      tracked = Promise.resolve(promise)
        .catch((error) => failures.push(error))
        .finally(() => pending.delete(tracked));
      pending.add(tracked);
    },
  };
  class SocketWithSendFailure {
    readyState = 1;
    listeners = new Map();

    accept() {}

    addEventListener(type, listener) {
      this.listeners.set(type, listener);
    }

    send() {
      this.listeners.get("error")?.({});
      throw new TypeError("send failure must not double-count reconnect state");
    }

    close() {
      this.readyState = 3;
    }
  }
  const socket = new SocketWithSendFailure();
  globalThis.fetch = async () => ({ status: 101, webSocket: socket, body: null });
  console.warn = (entry) => warnings.push(JSON.parse(entry));
  try {
    const relay = new QuakeRelay(state, {});
    relay.connect("jma_eqlist");
    for (let pass = 0; pass < 20 && pending.size > 0; pass += 1) {
      await Promise.all([...pending]);
    }
    assert.deepEqual(failures, []);
    assert.equal(values.get("upstream-reconnect-failures:jma_eqlist"), 1);
    assert.deepEqual(
      warnings.map((entry) => entry.outcome),
      ["wolfx_upstream_websocket_error"],
      "the listener's recovery owns an already-detached socket",
    );
    assert.ok(alarmAt > Date.now());
  } finally {
    console.warn = originalConsoleWarn;
    globalThis.fetch = originalFetch;
  }
});

test("an Upgrade without Wolfx traffic keeps exponential reconnect pacing", async () => {
  const { QuakeRelay, upstreamReconnectDelayMs } = await workerModule();
  const originalConsoleWarn = console.warn;
  const originalNow = Date.now;
  let now = Date.parse("2026-08-14T00:00:00.000Z");
  const values = new Map();
  const writes = [];
  const pending = new Set();
  const failures = [];
  let alarmAt = null;
  const state = {
    storage: {
      async get(key) {
        return values.get(key);
      },
      async put(key, value) {
        writes.push([key, value]);
        values.set(key, value);
      },
      async getAlarm() {
        return alarmAt;
      },
      async setAlarm(value) {
        writes.push(["alarm", value]);
        alarmAt = value;
      },
    },
    waitUntil(promise) {
      let tracked;
      tracked = Promise.resolve(promise)
        .catch((error) => failures.push(error))
        .finally(() => pending.delete(tracked));
      pending.add(tracked);
    },
  };
  class Socket {
    readyState = 1;
    listeners = new Map();

    accept() {}

    addEventListener(type, listener) {
      this.listeners.set(type, listener);
    }

    send() {}

    close() {
      this.readyState = 3;
    }

    emit(type, event) {
      this.listeners.get(type)?.(event);
    }
  }
  const relay = new QuakeRelay(state, {});
  const route = "jma_eqlist";
  const failureKey = `upstream-reconnect-failures:${route}`;
  const notBeforeKey = `upstream-reconnect-not-before-ms:${route}`;
  const freshnessKey = `upstream-last-success-ms:${route}`;
  const drain = async () => {
    for (let pass = 0; pass < 20 && pending.size > 0; pass += 1) {
      await Promise.all([...pending]);
    }
    assert.equal(pending.size, 0, "all listener recovery work settles");
  };
  try {
    Date.now = () => now;
    console.warn = () => {};
    for (let failureCount = 1; failureCount <= 8; failureCount += 1) {
      const socket = new Socket();
      relay.upstreams.set(route, socket);
      relay.attachUpstreamSocketListeners(route, socket);
      relay.activateUpstreamSocket(route, socket);
      assert.equal(
        relay.lastSuccessfulUpstreamMs.has(route),
        false,
        "a bare HTTP Upgrade must not publish upstream freshness",
      );
      assert.equal(
        relay.routeIsOpen(route),
        false,
        "a bare HTTP Upgrade must leave readiness fail-closed",
      );

      socket.emit("close", {
        code: 1006,
        wasClean: false,
        reason: "",
      });
      await drain();
      assert.equal(values.get(failureKey), failureCount);
      const reconnectAtMs = values.get(notBeforeKey);
      assert.equal(
        reconnectAtMs - now,
        upstreamReconnectDelayMs(failureCount, route),
        "each immediate close advances the persisted exponential backoff",
      );
      now = reconnectAtMs + 1;
    }

    assert.deepEqual(failures, []);
    assert.equal(
      writes.some(([, value]) => value === 0),
      false,
      "an Upgrade-then-close flap never clears persisted reconnect state",
    );
    const steadyRetryDelayMs = upstreamReconnectDelayMs(32, route);
    // Count the three persisted reconnect fields plus the alarm mutation,
    // even though an existing earlier alarm can make the real total smaller.
    const steadyWritesPerDay = Math.ceil(86_400_000 / steadyRetryDelayMs) * 4;
    assert.ok(
      steadyWritesPerDay < 100_000,
      `the capped retry budget is ${steadyWritesPerDay} rows/day for one failed route`,
    );
    assert.equal(
      writes.filter(([key]) => key === freshnessKey).length,
      0,
      "no freshness checkpoint is written without a valid Wolfx frame",
    );
  } finally {
    console.warn = originalConsoleWarn;
    Date.now = originalNow;
  }
});

test("heartbeat readiness starts only after a validated data commit and then remains watchdog-fresh", async () => {
  const { QuakeRelay } = await workerModule();
  const originalNow = Date.now;
  let now = Date.parse("2026-08-14T00:00:00.000Z");
  const values = new Map([
    ["upstream-reconnect-failures:jma_eqlist", 3],
    ["upstream-reconnect-not-before-ms:jma_eqlist", now + 20_000],
    ["upstream-degraded-since-ms:jma_eqlist", now - 10_000],
  ]);
  const writes = [];
  const pending = new Set();
  const state = {
    storage: {
      async get(key) {
        return values.get(key);
      },
      async list() {
        return new Map();
      },
      async put(key, value) {
        writes.push([key, value]);
        values.set(key, value);
      },
    },
    waitUntil(promise) {
      let tracked;
      tracked = Promise.resolve(promise).finally(() => pending.delete(tracked));
      pending.add(tracked);
    },
  };
  class Socket {
    readyState = 1;
    listeners = new Map();

    accept() {}

    addEventListener(type, listener) {
      this.listeners.set(type, listener);
    }

    send() {}

    emit(type, event) {
      this.listeners.get(type)?.(event);
    }
  }
  const route = "jma_eqlist";
  const socket = new Socket();
  const relay = new QuakeRelay(state, {});
  let releaseCommit;
  let announceCommitStarted;
  const commitGate = new Promise((resolve) => { releaseCommit = resolve; });
  const commitStarted = new Promise((resolve) => { announceCommitStarted = resolve; });
  relay.enqueueLiveSnapshot = async (source, _events, readinessCandidate) => {
    announceCommitStarted();
    await commitGate;
    // Existing live-snapshot tests exercise the real D1 cursor boundary. This
    // gate isolates the listener transition immediately before/after that
    // method's post-commit freshness call.
    readinessCandidate.durableIntentRecorded = true;
    await relay.markSourceSuccessfulAndPublishReadiness(source);
  };
  const drain = async () => {
    for (let pass = 0; pass < 20 && pending.size > 0; pass += 1) {
      await Promise.all([...pending]);
    }
    assert.equal(pending.size, 0, "all liveness work settles");
  };
  try {
    Date.now = () => now;
    relay.upstreams.set(route, socket);
    // A reconnect can retain a recent checkpoint from the preceding socket.
    // The next bare 101 must still not turn that historical timestamp into a
    // ready route before new Wolfx traffic arrives.
    relay.lastSuccessfulUpstreamMs.set(route, now - 1_000);
    relay.attachUpstreamSocketListeners(route, socket);
    relay.activateUpstreamSocket(route, socket);
    assert.equal(
      relay.routeIsOpen(route),
      false,
      "a replacement Upgrade cannot reuse the prior socket's freshness",
    );
    socket.emit("message", { data: JSON.stringify(wolfxHeartbeat()) });
    await drain();

    assert.equal(
      relay.lastSuccessfulUpstreamMs.get(route),
      now - 1_000,
      "an initial heartbeat cannot reuse freshness from the preceding socket",
    );
    assert.equal(relay.routeIsOpen(route), false);
    assert.equal(relay.statuses.get(route), "connecting");
    assert.equal(relay.readyUpstreamSockets.has(route), false);
    assert.equal(values.get(`upstream-reconnect-failures:${route}`), 3);
    assert.equal(
      values.get(`upstream-reconnect-not-before-ms:${route}`),
      now + 20_000,
      "an initial heartbeat is transport-only and cannot erase backoff",
    );

    socket.emit("message", { data: JSON.stringify(jmaEqlistSnapshot(1)) });
    await commitStarted;
    assert.equal(
      relay.routeIsOpen(route),
      false,
      "validated frame receipt alone cannot create readiness before commit",
    );
    assert.equal(relay.statuses.get(route), "connecting");
    assert.equal(relay.readyUpstreamSockets.has(route), false);
    await relay.markSourceSuccessfulAndPublishReadiness(route);
    assert.equal(
      relay.routeIsOpen(route),
      false,
      "an older journal completion cannot certify this newer unrecorded frame",
    );

    releaseCommit();
    await drain();
    assert.equal(relay.lastSuccessfulUpstreamMs.get(route), now);
    assert.equal(relay.routeIsOpen(route), true);
    assert.equal(relay.statuses.get(route), "open");
    assert.equal(relay.readyUpstreamSockets.get(route), socket);

    now += 60_000;
    socket.emit("message", { data: JSON.stringify(wolfxHeartbeat()) });
    await drain();

    assert.equal(values.get(`upstream-reconnect-failures:${route}`), 0);
    assert.equal(values.get(`upstream-reconnect-not-before-ms:${route}`), 0);
    assert.equal(values.get(`upstream-degraded-since-ms:${route}`), 0);
    assert.deepEqual(
      writes.filter(([key, value]) =>
        key.startsWith("upstream-reconnect-") && value === 0
      ).map(([key]) => key).sort(),
      [
        `upstream-reconnect-failures:${route}`,
        `upstream-reconnect-not-before-ms:${route}`,
      ],
      "only the stable liveness window can clear reconnect state",
    );
    assert.deepEqual(
      writes.filter(([key, value]) =>
        key === `upstream-degraded-since-ms:${route}` && value === 0
      ).map(([key]) => key),
      [`upstream-degraded-since-ms:${route}`],
    );
  } finally {
    Date.now = originalNow;
  }
});

test("a replacement socket cannot inherit committed readiness through a heartbeat", async () => {
  const { QuakeRelay } = await workerModule();
  const originalNow = Date.now;
  const startedAt = Date.parse("2026-08-14T00:00:00.000Z");
  let now = startedAt;
  const values = new Map();
  const pending = new Set();
  const failures = [];
  const state = {
    storage: {
      async get(key) { return values.get(key); },
      async put(key, value) { values.set(key, value); },
      async list() { return new Map(); },
    },
    waitUntil(promise) {
      let tracked;
      tracked = Promise.resolve(promise)
        .catch((error) => failures.push(error))
        .finally(() => pending.delete(tracked));
      pending.add(tracked);
    },
  };
  class Socket {
    readyState = 1;
    listeners = new Map();
    sent = [];

    addEventListener(type, listener) {
      this.listeners.set(type, listener);
    }

    send(value) {
      this.sent.push(value);
    }

    emit(type, event) {
      this.listeners.get(type)?.(event);
    }
  }
  const drain = async () => {
    for (let pass = 0; pass < 20 && pending.size > 0; pass += 1) {
      await Promise.all([...pending]);
    }
    assert.equal(pending.size, 0);
    assert.deepEqual(failures, []);
  };
  const route = "jma_eew";
  const oldSocket = new Socket();
  const replacement = new Socket();
  const relay = new QuakeRelay(state, {});
  try {
    Date.now = () => now;
    relay.upstreams.set(route, oldSocket);
    relay.activateUpstreamSocket(route, oldSocket);
    relay.validatedUpstreamDataSockets.set(route, {
      socket: oldSocket,
      durableIntentRecorded: true,
    });
    await relay.markSourceSuccessfulAndPublishReadiness(route);
    assert.equal(relay.routeIsOpen(route), true);

    relay.upstreams.set(route, replacement);
    relay.attachUpstreamSocketListeners(route, replacement);
    relay.activateUpstreamSocket(route, replacement);
    assert.equal(relay.routeIsOpen(route), false);
    assert.equal(relay.readyUpstreamSockets.has(route), false);
    assert.equal(relay.statuses.get(route), "connecting");

    now += 30_000;
    replacement.emit("message", { data: JSON.stringify(wolfxHeartbeat()) });
    await drain();
    assert.equal(
      relay.lastSuccessfulUpstreamMs.get(route),
      startedAt,
      "the replacement heartbeat cannot advance the prior committed timestamp",
    );
    assert.equal(relay.routeIsOpen(route), false);
    assert.equal(relay.readyUpstreamSockets.has(route), false);
    assert.equal(relay.statuses.get(route), "connecting");
  } finally {
    Date.now = originalNow;
  }
});

function normalizedWireNumber(value) {
  if (value === null || value === undefined || value === "") return null;
  const number = typeof value === "string"
    ? Number(value.replace(/[^\d.+-]/g, ""))
    : Number(value);
  return Number.isFinite(number) ? number : null;
}

function jmaJstIso(value) {
  const match = /^(\d{4})\/(\d{2})\/(\d{2}) (\d{2}):(\d{2})(?::(\d{2}))?$/.exec(value);
  assert.ok(match, `test fixture must use a JMA date-time: ${value}`);
  return new Date(
    Date.UTC(
      Number(match[1]),
      Number(match[2]) - 1,
      Number(match[3]),
      Number(match[4]) - 9,
      Number(match[5]),
      Number(match[6] ?? "0"),
    ),
  ).toISOString();
}

function jmaEewSnapshot(overrides = {}) {
  return {
    Title: "緊急地震速報（予報）",
    CodeType: "Ｍ、最大予測震度及び主要動到達予測時刻の緊急地震速報",
    Issue: { Source: "大阪", Status: "通常" },
    EventID: "20260813120000",
    Serial: 1,
    AnnouncedTime: "2026/08/13 12:00:05",
    OriginTime: "2026/08/13 12:00:00",
    Hypocenter: "Test coast",
    Latitude: 35.1,
    Longitude: 140.2,
    Magunitude: 4.2,
    Depth: 10,
    MaxIntensity: "4",
    Accuracy: { Epicenter: "test", Depth: "test", Magnitude: "test" },
    MaxIntChange: { String: "no change", Reason: "test" },
    WarnArea: [{
      Chiiki: "Test region",
      Shindo1: "4",
      Shindo2: "4",
      Time: "2026/08/13 12:00:10",
      Type: "Forecast",
      Arrive: false,
    }],
    isSea: true,
    isTraining: false,
    isAssumption: false,
    isWarn: true,
    isFinal: false,
    isCancel: false,
    OriginalText: "test",
    ...overrides,
  };
}

function jmaEewFrame(overrides = {}) {
  return { type: "jma_eew", ...jmaEewSnapshot(overrides) };
}

function normalizedJmaEewSnapshot(raw, overrides = {}) {
  return {
    id: `jma_eew:${raw.EventID}`,
    sourceId: "jma_eew",
    eventId: raw.EventID,
    serial: raw.Serial ?? 1,
    kind: "eew",
    originTimeUtc: jmaJstIso(raw.OriginTime),
    reportTimeUtc: jmaJstIso(raw.AnnouncedTime),
    hypocenter: raw.Hypocenter,
    latitude: normalizedWireNumber(raw.Latitude),
    longitude: normalizedWireNumber(raw.Longitude),
    magnitude: normalizedWireNumber(raw.Magunitude),
    depth: normalizedWireNumber(raw.Depth),
    maxIntensity: raw.MaxIntensity ?? null,
    isWarn: !!raw.isWarn,
    isFinal: !!raw.isFinal,
    isCancel: !!raw.isCancel,
    isTraining: !!raw.isTraining,
    tsunami: null,
    raw,
    ...overrides,
  };
}

function jmaEqlistEntry(index = 1, overrides = {}) {
  return {
    Title: "report",
    EventID: `202608140900${String(index).padStart(2, "0")}`,
    time: "2026/08/14 09:00",
    time_full: "2026/08/14 09:00:00",
    location: `Test coast ${index}`,
    magnitude: "4.2",
    shindo: "2",
    depth: "10km",
    latitude: "35.1",
    longitude: "140.2",
    info: "",
    ...overrides,
  };
}

function normalizedJmaEqlistEntry(raw, overrides = {}) {
  return {
    id: `jma_eqlist:${raw.EventID}`,
    sourceId: "jma_eqlist",
    eventId: raw.EventID,
    serial: 1,
    kind: "report",
    originTimeUtc: jmaJstIso(raw.time_full || raw.time),
    reportTimeUtc: jmaJstIso(raw.time_full || raw.time),
    hypocenter: raw.location,
    latitude: normalizedWireNumber(raw.latitude),
    longitude: normalizedWireNumber(raw.longitude),
    magnitude: normalizedWireNumber(raw.magnitude),
    depth: normalizedWireNumber(raw.depth),
    maxIntensity: raw.shindo || null,
    isWarn: false,
    isFinal: true,
    isCancel: false,
    isTraining: false,
    tsunami: raw.info || null,
    raw,
    ...overrides,
  };
}

function jmaEqlistVariantEventId(variant) {
  return `202608140900${String(50 + variant).padStart(2, "0")}`;
}

function jmaEqlistSnapshot(count = 50) {
  const snapshot = {
    type: "jma_eqlist",
    md5: "11111111111111111111111111111111",
  };
  for (let index = 1; index <= count; index += 1) {
    snapshot[`No${index}`] = jmaEqlistEntry(index);
  }
  return snapshot;
}

function distinctJmaEqlistSnapshot(variant, count = 50) {
  const snapshot = jmaEqlistSnapshot(count);
  snapshot.md5 = Number(variant).toString(16).padStart(32, "0");
  snapshot.No1 = {
    ...snapshot.No1,
    EventID: jmaEqlistVariantEventId(variant),
    location: `Variant coast ${variant}`,
  };
  return snapshot;
}

function storedLiveSnapshotWork(source, now) {
  return {
    version: 1,
    source,
    fingerprint: `stored-${source}-fingerprint`,
    events: [{
      id: `${source}:stored`,
      sourceId: source,
      eventId: "stored",
      serial: 1,
      kind: "report",
      originTimeUtc: "2026-08-14T00:00:00.000Z",
      reportTimeUtc: "2026-08-14T00:00:00.000Z",
      hypocenter: "Stored Region",
      latitude: 35,
      longitude: 139,
      magnitude: 4.2,
      depth: 10,
      maxIntensity: "2",
      isWarn: false,
      isFinal: true,
      isCancel: false,
      isTraining: false,
      tsunami: null,
    }],
    nextIndex: 0,
    createdAtMs: now,
    retryAtMs: now,
  };
}

function isLiveSnapshotStorageKey(key) {
  return typeof key === "string" && /^pending-live-snapshot(?:[:\-])/.test(key);
}

function isLiveSnapshotFingerprintStorageKey(key) {
  return typeof key === "string" && key.includes("live-snapshot-fingerprint");
}

function livePointEvent({ serial = 1, magnitude = 4.2 } = {}) {
  return {
    id: "jma_eew:resident-point-event",
    sourceId: "jma_eew",
    eventId: "resident-point-event",
    serial,
    kind: "eew",
    originTimeUtc: "2026-08-14T00:00:00.000Z",
    reportTimeUtc: "2026-08-14T00:00:00.000Z",
    hypocenter: "Test Region",
    latitude: 35,
    longitude: 139,
    magnitude,
    depth: 10,
    maxIntensity: "4",
    isWarn: true,
    isFinal: false,
    isCancel: false,
    isTraining: false,
    tsunami: null,
    raw: null,
  };
}

function wolfxHeartbeat(overrides = {}) {
  return {
    type: "heartbeat",
    ver: 22,
    id: "2094581",
    timestamp: 1787241213884,
    ...overrides,
  };
}

function wolfxPong(overrides = {}) {
  return {
    type: "pong",
    timestamp: 1787241234570,
    ...overrides,
  };
}

function isLivePointJournalKey(key) {
  return typeof key === "string" && key.startsWith("pending-ingest:");
}

function createLivePointEventHarness({
  failD1Batches = () => false,
  storedEventRow = null,
} = {}) {
  const values = new Map();
  const writes = [];
  let alarmAt = null;
  let d1BatchAttempts = 0;
  const d1Batches = [];
  const storage = {
    async get(key) {
      return values.get(key);
    },
    async put(key, value) {
      writes.push(["put", key, value]);
      values.set(key, value);
    },
    async delete(key) {
      writes.push(["delete", key]);
      values.delete(key);
    },
    async list({ prefix = "", limit = Infinity } = {}) {
      return new Map(
        [...values]
          .filter(([key]) => key.startsWith(prefix))
          .slice(0, limit),
      );
    },
    async transaction(callback) {
      return callback({
        get: storage.get,
        put: storage.put,
        delete: storage.delete,
      });
    },
    async getAlarm() {
      return alarmAt;
    },
    async setAlarm(value) {
      writes.push(["setAlarm", "alarm", value]);
      alarmAt = value;
    },
  };
  const database = {
    prepare(sql) {
      return {
        bind(...bindings) {
          return {
            sql,
            bindings,
            async first() {
              return storedEventRow;
            },
          };
        },
      };
    },
    async batch(statements) {
      d1BatchAttempts += 1;
      if (failD1Batches()) throw new Error("simulated live point-event D1 failure");
      d1Batches.push(statements);
      return statements.map(() => ({ meta: { changes: 1 } }));
    },
  };
  return {
    values,
    writes,
    state: { storage, waitUntil() {} },
    database,
    get d1BatchAttempts() {
      return d1BatchAttempts;
    },
    get d1Batches() {
      return d1Batches;
    },
  };
}

function createLiveSnapshotHarness({ failD1Batches = () => false } = {}) {
  const values = new Map();
  const writes = [];
  const pending = new Set();
  const backgroundErrors = [];
  let alarmAt = null;
  let d1BatchAttempts = 0;
  const d1Batches = [];
  const storage = {
    async get(key) {
      return values.get(key);
    },
    async put(key, value) {
      writes.push(["put", key, value]);
      values.set(key, value);
    },
    async delete(key) {
      writes.push(["delete", key]);
      values.delete(key);
    },
    async list({ prefix = "", limit = Infinity } = {}) {
      return new Map(
        [...values]
          .filter(([key]) => key.startsWith(prefix))
          .slice(0, limit),
      );
    },
    async transaction(callback) {
      return callback({
        get: storage.get,
        put: storage.put,
        delete: storage.delete,
      });
    },
    async getAlarm() {
      return alarmAt;
    },
    async setAlarm(value) {
      writes.push(["setAlarm", "alarm", value]);
      alarmAt = value;
    },
  };
  const state = {
    storage,
    waitUntil(promise) {
      let tracked;
      tracked = Promise.resolve(promise)
        .catch((error) => backgroundErrors.push(error))
        .finally(() => pending.delete(tracked));
      pending.add(tracked);
    },
  };
  const database = {
    prepare(sql) {
      return {
        bind(...bindings) {
          return {
            sql,
            bindings,
            async all() {
              return { results: [] };
            },
          };
        },
      };
    },
    async batch(statements) {
      d1BatchAttempts += 1;
      d1Batches.push(statements);
      if (failD1Batches()) {
        throw new Error("simulated live EQLIST D1 failure");
      }
      return statements.map(() => ({ meta: { changes: 1 } }));
    },
  };
  class Socket {
    readyState = 1;
    listeners = new Map();

    addEventListener(type, listener) {
      this.listeners.set(type, listener);
    }

    emit(type, event) {
      this.listeners.get(type)?.(event);
    }
  }

  return {
    values,
    writes,
    state,
    database,
    Socket,
    get d1BatchAttempts() {
      return d1BatchAttempts;
    },
    get d1Batches() {
      return d1Batches;
    },
    get alarmAt() {
      return alarmAt;
    },
    clearScheduledAlarm() {
      alarmAt = null;
    },
    pendingLiveSnapshots() {
      return [...values].filter(([key]) => isLiveSnapshotStorageKey(key));
    },
    committedLiveSnapshotFingerprints() {
      return [...values].filter(([key, value]) =>
        isLiveSnapshotFingerprintStorageKey(key) && typeof value === "string"
      );
    },
    async drainBackground() {
      for (let pass = 0; pass < 30 && pending.size > 0; pass += 1) {
        await Promise.all([...pending]);
      }
      assert.equal(pending.size, 0, "all live EQLIST WebSocket work settles");
      assert.deepEqual(backgroundErrors, [], "the listener must not hide a background error");
    },
  };
}

test("a resident relay skips exact committed point-event replays without suppressing a changed revision", async () => {
  const { QuakeRelay } = await workerModule();
  const harness = createLivePointEventHarness();
  const relay = new QuakeRelay(harness.state, { DB: harness.database });
  // The test exercises the real D1 event transaction but does not need Queue
  // hand-off behavior to prove Durable Object journal accounting.
  relay.flushAlertDeliveryOutbox = async () => {};
  const event = livePointEvent();
  const journalWrites = () => harness.writes.filter(([, key]) =>
    isLivePointJournalKey(key)
  );

  await relay.enqueueLiveIngest(event);
  assert.equal(harness.d1BatchAttempts, 1);
  assert.deepEqual(
    journalWrites().map(([operation]) => operation),
    ["put", "delete"],
    "a first point event crosses the durable journal before and after D1",
  );

  const writesAfterCommit = harness.writes.slice();
  await relay.enqueueLiveIngest({ ...event });
  assert.deepEqual(
    harness.writes,
    writesAfterCommit,
    "an exact post-D1 replay must not create a journal, alarm, or freshness write",
  );
  assert.equal(
    harness.d1BatchAttempts,
    1,
    "an exact post-D1 replay must not repeat D1 persistence",
  );

  await relay.enqueueLiveIngest({ ...event, magnitude: 5.1 });
  assert.equal(
    harness.d1BatchAttempts,
    2,
    "a changed same-serial revision must still reach D1",
  );
  assert.deepEqual(
    journalWrites().map(([operation]) => operation),
    ["put", "delete", "put", "delete"],
    "a genuine normalized change must receive fresh durable journal work",
  );
});

test("Worker persistence cannot reopen final or cancelled events on same or higher active serials", async () => {
  const { QuakeRelay } = await workerModule();

  for (const terminal of ["final", "cancelled"]) {
    const event = livePointEvent();
    const storedEventRow = {
      id: event.id,
      source_id: event.sourceId,
      event_id: event.eventId,
      serial: event.serial,
      kind: event.kind,
      origin_time_utc: event.originTimeUtc,
      report_time_utc: event.reportTimeUtc,
      hypocenter: event.hypocenter,
      latitude: event.latitude,
      longitude: event.longitude,
      magnitude: event.magnitude,
      depth: event.depth,
      max_intensity: event.maxIntensity,
      is_warn: 1,
      is_final: terminal === "final" ? 1 : 0,
      is_cancel: terminal === "cancelled" ? 1 : 0,
      is_training: 0,
      tsunami: null,
      raw_json: null,
    };
    const harness = createLivePointEventHarness({ storedEventRow });
    const relay = new QuakeRelay(harness.state, { DB: harness.database });
    relay.flushAlertDeliveryOutbox = async () => {};

    await relay.ingest(event, "live", null);
    assert.equal(
      harness.d1BatchAttempts,
      0,
      `a same-serial active replay after ${terminal} must be rejected before D1`,
    );

    await relay.ingest({ ...event, serial: event.serial + 1 }, "live", null);
    assert.equal(harness.d1BatchAttempts, 1);
    assert.equal(
      harness.d1Batches[0].length,
      2,
      `a higher active replay after ${terminal} may update data but cannot enqueue delivery`,
    );
    const eventBindings = harness.d1Batches[0][0].bindings;
    assert.equal(eventBindings[14], terminal === "final" ? 1 : 0);
    assert.equal(eventBindings[15], terminal === "cancelled" ? 1 : 0);
  }
});

test("a resident relay preserves a pending point event without duplicate journal writes or D1 retries", async () => {
  const { QuakeRelay } = await workerModule();
  const originalConsoleError = console.error;
  let failD1 = true;
  const harness = createLivePointEventHarness({ failD1Batches: () => failD1 });
  const relay = new QuakeRelay(harness.state, { DB: harness.database });
  relay.flushAlertDeliveryOutbox = async () => {};
  const event = livePointEvent();
  const journalKey = `pending-ingest:${event.sourceId}:${encodeURIComponent(event.id)}`;
  try {
    console.error = () => {};
    await relay.enqueueLiveIngest(event);
    assert.equal(harness.d1BatchAttempts, 1, "the first D1 attempt fails once");
    assert.ok(harness.values.has(journalKey), "the failed event remains durable");
    const writesBeforeReplay = harness.writes.slice();

    await relay.enqueueLiveIngest({ ...event });
    assert.deepEqual(
      harness.writes,
      writesBeforeReplay,
      "an exact pending replay must not rewrite its journal or schedule a new alarm",
    );
    assert.equal(
      harness.d1BatchAttempts,
      1,
      "an exact pending replay must wait for the original paced retry",
    );

    await relay.enqueueLiveIngest({ ...event, magnitude: 5.1 });
    assert.equal(
      harness.d1BatchAttempts,
      2,
      "a changed pending revision must not be mistaken for the exact replay",
    );
    assert.equal(
      harness.writes.filter(([operation, key]) =>
        operation === "put" && key === journalKey
      ).length,
      2,
      "a changed revision replaces the pending durable intent exactly once",
    );
  } finally {
    console.error = originalConsoleError;
    failD1 = false;
  }
});

test("the resident committed point-event replay cache is bounded", async () => {
  const { QuakeRelay } = await workerModule();
  const relay = new QuakeRelay({ storage: {}, waitUntil() {} }, {});
  for (let index = 0; index < 513; index += 1) {
    relay.rememberCommittedLiveEventFingerprint(String(index).padStart(64, "0"));
  }
  assert.equal(relay.committedLiveEventFingerprints.size, 512);
  assert.equal(
    relay.hasCommittedLiveEventFingerprint(String(0).padStart(64, "0")),
    false,
    "the least-recent fingerprint is evicted instead of retaining an unbounded map",
  );
});

test("a repeated unchanged 50-entry live JMA EQLIST does not recreate per-event journals or D1 work", async () => {
  const { QuakeRelay } = await workerModule();
  const originalNow = Date.now;
  let now = Date.parse("2026-08-14T00:00:00.000Z");
  const harness = createLiveSnapshotHarness();
  const relay = new QuakeRelay(harness.state, { DB: harness.database });
  const socket = new harness.Socket();
  const route = "jma_eqlist";
  const frame = jmaEqlistSnapshot();
  const pendingSnapshotWrites = () => harness.writes.filter(([, key]) =>
    isLiveSnapshotStorageKey(key)
  ).length;
  const perEventJournalWrites = () => harness.writes.filter(([, key]) =>
    typeof key === "string" && key.startsWith("pending-ingest:")
  ).length;
  try {
    Date.now = () => now;
    relay.upstreams.set(route, socket);
    relay.attachUpstreamSocketListeners(route, socket);
    socket.emit("message", { data: JSON.stringify(frame) });
    await harness.drainBackground();

    // The initial waitUntil drains one D1-safe slice. Alarms resume the
    // durable cursor; invoke that same internal alarm path with its due clock
    // to finish all fifty entries without broad relay maintenance.
    for (let pass = 0; pass < 12 && harness.pendingLiveSnapshots().length > 0; pass += 1) {
      now += 5_000;
      await relay.drainPendingLiveSnapshotWorks();
    }
    assert.equal(
      harness.pendingLiveSnapshots().length,
      0,
      "the completed list removes both its active cursor and any coalesced latest pointer",
    );
    assert.equal(
      harness.committedLiveSnapshotFingerprints().length,
      1,
      "only a fully durable list may publish its deduplication fingerprint",
    );
    assert.equal(
      perEventJournalWrites(),
      0,
      "a complete EQLIST frame must not fan out into fifty pending-ingest records",
    );
    assert.ok(harness.d1BatchAttempts >= 7, "fifty entries must use bounded D1 slices");

    const d1BeforeReplay = harness.d1BatchAttempts;
    const snapshotWritesBeforeReplay = pendingSnapshotWrites();
    const journalWritesBeforeReplay = perEventJournalWrites();
    socket.emit("message", { data: JSON.stringify(frame) });
    await harness.drainBackground();

    assert.equal(
      harness.d1BatchAttempts,
      d1BeforeReplay,
      "an unchanged fully committed EQLIST frame must not repeat D1 persistence",
    );
    assert.equal(
      pendingSnapshotWrites(),
      snapshotWritesBeforeReplay,
      "an unchanged fully committed EQLIST frame must not recreate live snapshot storage",
    );
    assert.equal(
      perEventJournalWrites(),
      journalWritesBeforeReplay,
      "replay must create zero new per-event pending ingest records",
    );
  } finally {
    Date.now = originalNow;
  }
});

test("a failed live JMA EQLIST slice keeps its durable cursor and withholds deduplication until retry succeeds", async () => {
  const { QuakeRelay } = await workerModule();
  const originalConsoleError = console.error;
  const originalNow = Date.now;
  let now = Date.parse("2026-08-14T00:00:00.000Z");
  let failD1 = true;
  const harness = createLiveSnapshotHarness({ failD1Batches: () => failD1 });
  const relay = new QuakeRelay(harness.state, { DB: harness.database });
  const socket = new harness.Socket();
  const route = "jma_eqlist";
  const frame = jmaEqlistSnapshot();
  const snapshotWrites = () => harness.writes.filter(([, key]) =>
    isLiveSnapshotStorageKey(key)
  ).length;
  try {
    Date.now = () => now;
    console.error = () => {};
    relay.upstreams.set(route, socket);
    relay.attachUpstreamSocketListeners(route, socket);
    socket.emit("message", { data: JSON.stringify(frame) });
    await harness.drainBackground();

    assert.equal(harness.d1BatchAttempts, 1, "the first bounded D1 slice was attempted once");
    assert.ok(
      harness.pendingLiveSnapshots().length > 0,
      "a D1 failure must retain a durable active snapshot or latest coalescing record",
    );
    assert.equal(
      harness.committedLiveSnapshotFingerprints().length,
      0,
      "a failed D1 slice must never publish a completed snapshot fingerprint",
    );
    const snapshotWritesBeforeDuplicate = snapshotWrites();
    socket.emit("message", { data: JSON.stringify(frame) });
    await harness.drainBackground();
    assert.equal(
      harness.d1BatchAttempts,
      1,
      "the retry deadline prevents a duplicate frame from immediately hammering failed D1",
    );
    assert.equal(
      snapshotWrites(),
      snapshotWritesBeforeDuplicate,
      "a duplicate frame during retry must share the existing durable snapshot work",
    );

    failD1 = false;
    for (let pass = 0; pass < 12 && harness.pendingLiveSnapshots().length > 0; pass += 1) {
      now += 60_000;
      await relay.drainPendingLiveSnapshotWorks();
    }
    assert.equal(
      harness.pendingLiveSnapshots().length,
      0,
      "the successful retry clears all durable snapshot work",
    );
    assert.equal(
      harness.committedLiveSnapshotFingerprints().length,
      1,
      "deduplication is committed only after all slices eventually succeed",
    );
    assert.ok(
      harness.d1BatchAttempts > 1,
      "the cursor retries D1 only after its durable retry deadline",
    );
  } finally {
    console.error = originalConsoleError;
    Date.now = originalNow;
  }
});

test("empty or malformed live EQLIST frames cannot publish source freshness", async () => {
  const { QuakeRelay } = await workerModule();
  const originalConsoleWarn = console.warn;
  const originalNow = Date.now;
  const now = Date.parse("2026-08-14T00:00:00.000Z");
  const route = "jma_eqlist";
  const freshnessKey = `upstream-last-success-ms:${route}`;
  const overloadKey = `live-snapshot-overload:${route}`;
  const staleCheckpoint = now - 181_000;
  const harness = createLiveSnapshotHarness();
  const relay = new QuakeRelay(harness.state, { DB: harness.database });
  const socket = new harness.Socket();
  try {
    Date.now = () => now;
    console.warn = () => {};
    harness.values.set(freshnessKey, staleCheckpoint);
    relay.statuses.set(route, "error");
    relay.lastSuccessfulUpstreamMs.set(route, staleCheckpoint);
    relay.upstreams.set(route, socket);
    relay.attachUpstreamSocketListeners(route, socket);

    for (const invalidFrame of [
      { type: route, md5: "empty-ranked-list" },
      { type: route, md5: "malformed-ranked-list", No1: {} },
    ]) {
      socket.emit("message", { data: JSON.stringify(invalidFrame) });
      await harness.drainBackground();
    }

    assert.equal(
      relay.lastSuccessfulUpstreamMs.get(route),
      staleCheckpoint,
      "an invalid ranked list must not refresh the in-memory success timestamp",
    );
    assert.equal(
      harness.values.get(freshnessKey),
      staleCheckpoint,
      "an invalid ranked list must not write a fresh durable checkpoint",
    );
    assert.equal(
      relay.statuses.get(route),
      "error",
      "an invalid ranked list must not turn the route open",
    );
    assert.ok(
      harness.values.has(overloadKey),
      "the first invalid list must create a durable fail-closed marker",
    );
    assert.equal(
      harness.writes.filter(([operation, key]) =>
        operation === "put" && key === overloadKey
      ).length,
      1,
      "repeated invalid frames must share the one fail-closed marker",
    );

    const response = await relay.statusResponse();
    const body = await response.json();
    assert.equal(body.upstream.sources[route].pendingLiveSnapshot, true);
    assert.equal(
      body.upstream.sources[route].stale,
      true,
      "the durable invalid-list marker must keep health failed closed",
    );
  } finally {
    console.warn = originalConsoleWarn;
    Date.now = originalNow;
  }
});

test("live snapshot active/latest source-key mismatches remain fail-closed", async () => {
  const { QuakeRelay } = await workerModule();
  const originalConsoleError = console.error;
  const originalNow = Date.now;
  const now = Date.parse("2026-08-14T00:00:00.000Z");
  const route = "jma_eqlist";
  const mismatchedSource = "cenc_eqlist";
  try {
    Date.now = () => now;
    console.error = () => {};
    for (const key of [
      `pending-live-snapshot:${route}`,
      `pending-live-snapshot-latest:${route}`,
    ]) {
      const harness = createLiveSnapshotHarness();
      const relay = new QuakeRelay(harness.state, { DB: harness.database });
      const socket = new harness.Socket();
      const mismatchedWork = storedLiveSnapshotWork(mismatchedSource, now);
      harness.values.set(key, mismatchedWork);
      harness.values.set(`upstream-last-success-ms:${route}`, now);
      relay.statuses.set(route, "open");
      relay.lastSuccessfulUpstreamMs.set(route, now);

      const before = await relay.statusResponse();
      const beforeBody = await before.json();
      assert.equal(
        beforeBody.upstream.sources[route].pendingLiveSnapshot,
        true,
        `${key} must remain a pending durability fence even when its value names another source`,
      );
      assert.equal(
        beforeBody.upstream.sources[route].stale,
        true,
        `${key} must keep health failed closed instead of trusting the old fresh checkpoint`,
      );

      relay.upstreams.set(route, socket);
      relay.attachUpstreamSocketListeners(route, socket);
      socket.emit("message", { data: JSON.stringify(jmaEqlistSnapshot(1)) });
      await harness.drainBackground();

      assert.equal(
        harness.values.get(key),
        mismatchedWork,
        "a valid incoming list must not overwrite source-mismatched durable intent",
      );
      assert.equal(
        harness.writes.filter(([operation, writeKey]) =>
          operation === "put" &&
          typeof writeKey === "string" &&
          (writeKey.startsWith("pending-live-snapshot:") ||
            writeKey.startsWith("pending-live-snapshot-latest:"))
        ).length,
        0,
        "a source-key mismatch must not create replacement snapshot work",
      );
    }
  } finally {
    console.error = originalConsoleError;
    Date.now = originalNow;
  }
});

test("a third distinct live list is durably retained before bounded source backpressure", async () => {
  const { QuakeRelay } = await workerModule();
  const originalConsoleError = console.error;
  const originalConsoleWarn = console.warn;
  const originalNow = Date.now;
  let now = Date.parse("2026-08-14T00:00:00.000Z");
  const route = "jma_eqlist";
  const overflowKey = `pending-live-snapshot-overflow:${route}`;
  const overloadKey = `live-snapshot-overload:${route}`;
  const harness = createLiveSnapshotHarness();
  const relay = new QuakeRelay(harness.state, { DB: harness.database });
  const socket = new harness.Socket();
  const liveSnapshotPutCount = () => harness.writes.filter(([operation, key]) =>
    operation === "put" &&
    typeof key === "string" &&
    (key.startsWith("pending-live-snapshot:") ||
      key.startsWith("pending-live-snapshot-latest:") ||
      key.startsWith("pending-live-snapshot-overflow:") ||
      key.startsWith("live-snapshot-overload:"))
  ).length;
  try {
    Date.now = () => now;
    console.error = () => {};
    console.warn = () => {};
    relay.upstreams.set(route, socket);
    relay.attachUpstreamSocketListeners(route, socket);

    for (const variant of [1, 2, 3]) {
      socket.emit("message", {
        data: JSON.stringify(distinctJmaEqlistSnapshot(variant)),
      });
      await harness.drainBackground();
    }

    assert.ok(
      harness.values.has(overloadKey),
      "the third distinct list must leave one durable overload marker",
    );
    const overflow = harness.values.get(overflowKey);
    assert.equal(
      overflow?.events?.[0]?.eventId,
      jmaEqlistVariantEventId(3),
      "the third accepted frame must be durable before the source is closed",
    );
    assert.equal(
      harness.writes.filter(([operation, key]) =>
        operation === "put" && key === overloadKey
      ).length,
      1,
      "the capacity signal is persisted exactly once",
    );
    const snapshotPutsAfterOverload = liveSnapshotPutCount();
    const d1BatchesAfterOverload = harness.d1BatchAttempts;

    for (const variant of [4, 5, 6]) {
      socket.emit("message", {
        data: JSON.stringify(distinctJmaEqlistSnapshot(variant)),
      });
      await harness.drainBackground();
    }

    assert.equal(
      liveSnapshotPutCount(),
      snapshotPutsAfterOverload,
      "later changed frames must not create any active/latest/overload snapshot writes",
    );
    assert.equal(
      harness.d1BatchAttempts,
      d1BatchesAfterOverload,
      "frames after backpressure must wait for the paced retained cursors",
    );
  } finally {
    console.error = originalConsoleError;
    console.warn = originalConsoleWarn;
    Date.now = originalNow;
  }
});

test("a failed live-list slice retains all three admitted snapshots until they commit in order", async () => {
  const { QuakeRelay } = await workerModule();
  const originalConsoleError = console.error;
  const originalConsoleWarn = console.warn;
  const originalNow = Date.now;
  let now = Date.parse("2026-08-14T00:00:00.000Z");
  let failD1 = true;
  const route = "jma_eqlist";
  const activeKey = `pending-live-snapshot:${route}`;
  const latestKey = `pending-live-snapshot-latest:${route}`;
  const overflowKey = `pending-live-snapshot-overflow:${route}`;
  const overloadKey = `live-snapshot-overload:${route}`;
  const harness = createLiveSnapshotHarness({ failD1Batches: () => failD1 });
  const relay = new QuakeRelay(harness.state, { DB: harness.database });
  const socket = new harness.Socket();
  try {
    Date.now = () => now;
    console.error = () => {};
    console.warn = () => {};
    relay.upstreams.set(route, socket);
    relay.attachUpstreamSocketListeners(route, socket);

    for (const variant of [1, 2, 3]) {
      socket.emit("message", {
        data: JSON.stringify(distinctJmaEqlistSnapshot(variant)),
      });
      await harness.drainBackground();
    }

    assert.equal(harness.d1BatchAttempts, 1, "only the first active slice reaches failed D1");
    assert.equal(
      harness.values.get(activeKey)?.events?.[0]?.eventId,
      jmaEqlistVariantEventId(1),
    );
    assert.equal(
      harness.values.get(latestKey)?.events?.[0]?.eventId,
      jmaEqlistVariantEventId(2),
    );
    assert.equal(
      harness.values.get(overflowKey)?.events?.[0]?.eventId,
      jmaEqlistVariantEventId(3),
    );
    assert.ok(harness.values.has(overloadKey), "overload remains a freshness fence");

    failD1 = false;
    for (let pass = 0; pass < 30 && harness.pendingLiveSnapshots().length > 0; pass += 1) {
      now += 60_000;
      await relay.drainPendingLiveSnapshotWorks();
    }

    assert.equal(
      harness.pendingLiveSnapshots().length,
      0,
      "every admitted list must drain before the source can accept a resync",
    );
    assert.ok(
      harness.values.has(overloadKey),
      "the marker stays until a later valid source resync proves freshness",
    );
    const persistedFirstEventIds = harness.d1Batches
      .flatMap((statements) => statements)
      .filter((statement) => statement.sql?.includes("INSERT INTO events"))
      .map((statement) => statement.bindings?.[2])
      .filter((eventId) => typeof eventId === "string");
    const first = persistedFirstEventIds.indexOf(jmaEqlistVariantEventId(1));
    const second = persistedFirstEventIds.indexOf(jmaEqlistVariantEventId(2));
    const third = persistedFirstEventIds.indexOf(jmaEqlistVariantEventId(3));
    assert.ok(first >= 0 && second > first && third > second);
  } finally {
    console.error = originalConsoleError;
    console.warn = originalConsoleWarn;
    Date.now = originalNow;
  }
});

test("the relay alarm repairs newer live-list slots left without an active cursor", async () => {
  const { QuakeRelay } = await workerModule();
  const originalNow = Date.now;
  const now = Date.parse("2026-08-14T00:00:00.000Z");
  const route = "jma_eqlist";
  const activeKey = `pending-live-snapshot:${route}`;
  const latestKey = `pending-live-snapshot-latest:${route}`;
  const overflowKey = `pending-live-snapshot-overflow:${route}`;
  const harness = createLiveSnapshotHarness();
  const relay = new QuakeRelay(harness.state, { DB: harness.database });
  const latest = {
    ...storedLiveSnapshotWork(route, now),
    fingerprint: "resume-latest",
    events: [{
      ...storedLiveSnapshotWork(route, now).events[0],
      id: `${route}:resume-latest`,
      eventId: "resume-latest",
    }],
    retryAtMs: now + 5_000,
  };
  const overflow = {
    ...storedLiveSnapshotWork(route, now + 1),
    fingerprint: "resume-overflow",
    events: [{
      ...storedLiveSnapshotWork(route, now + 1).events[0],
      id: `${route}:resume-overflow`,
      eventId: "resume-overflow",
    }],
    retryAtMs: now + 5_000,
  };
  try {
    Date.now = () => now;
    harness.values.set(latestKey, latest);
    harness.values.set(overflowKey, overflow);
    relay.refreshHttpFallbackActive = async () => false;
    relay.pendingHttpSnapshotWorks = async () => [];
    relay.nextDueHttpSeedMode = async () => null;
    relay.ensureUpstreams = async () => {};
    relay.reconcileDlqPersistenceFallbacks = async () => {};
    relay.migrateLegacyPendingDeliveries = async () => {};
    relay.drainPendingIngestJournal = async () => {};
    relay.flushAlertDeliveryOutbox = async () => {};
    relay.purgeExpiredDevicesIfDue = async () => {};
    relay.scheduleRoutineRelayAlarm = async () => {};

    await relay.alarm();

    assert.equal(harness.values.get(activeKey)?.fingerprint, "resume-latest");
    assert.equal(harness.values.get(latestKey)?.fingerprint, "resume-overflow");
    assert.equal(
      harness.values.has(overflowKey),
      false,
      "the alarm must atomically shift overflow behind the newly active cursor",
    );
  } finally {
    Date.now = originalNow;
  }
});

test("a marker-only live-list overload remains stale without starving ordinary maintenance", async () => {
  const { QuakeRelay } = await workerModule();
  const originalNow = Date.now;
  const now = Date.parse("2026-08-14T00:00:00.000Z");
  const route = "jma_eqlist";
  const harness = createLiveSnapshotHarness();
  const relay = new QuakeRelay(harness.state, { DB: harness.database });
  const maintenance = [];
  try {
    Date.now = () => now;
    harness.values.set(`live-snapshot-overload:${route}`, {
      version: 1,
      source: route,
      reason: "overload",
      observedAtMs: now,
    });
    relay.refreshHttpFallbackActive = async () => false;
    relay.pendingHttpSnapshotWorks = async () => [];
    relay.nextDueHttpSeedMode = async () => null;
    relay.ensureUpstreams = async () => {};
    relay.reconcileDlqPersistenceFallbacks = async () => maintenance.push("dlq");
    relay.migrateLegacyPendingDeliveries = async () => maintenance.push("legacy");
    relay.drainPendingIngestJournal = async () => maintenance.push("journal");
    relay.flushAlertDeliveryOutbox = async () => maintenance.push("outbox");
    relay.purgeExpiredDevicesIfDue = async () => maintenance.push("purge");
    relay.scheduleRoutineRelayAlarm = async () => {};

    await relay.alarm();

    assert.deepEqual(
      maintenance,
      ["purge"],
      "marker-only state must not block unrelated recovery or alert delivery",
    );
    assert.ok(harness.values.has(`live-snapshot-overload:${route}`));
  } finally {
    Date.now = originalNow;
  }
});

test("the early live-snapshot alarm is replaced by its five-second cursor retry", async () => {
  const { QuakeRelay } = await workerModule();
  const originalNow = Date.now;
  const startedAt = Date.parse("2026-08-14T00:00:00.000Z");
  let now = startedAt;
  const route = "jma_eqlist";
  const workKey = `pending-live-snapshot:${route}`;
  const harness = createLiveSnapshotHarness();
  const relay = new QuakeRelay(harness.state, { DB: harness.database });
  const socket = new harness.Socket();
  try {
    Date.now = () => now;
    // This test exercises only the live cursor scheduler, not the unrelated
    // first-run HTTP baseline. A real deployed relay will already have this
    // marker after that baseline completes.
    harness.values.set("initial-http-seed-complete", true);
    relay.ensureUpstreams = async () => {};
    relay.upstreams.set(route, socket);
    relay.attachUpstreamSocketListeners(route, socket);
    socket.emit("message", { data: JSON.stringify(jmaEqlistSnapshot()) });
    await harness.drainBackground();

    const work = harness.values.get(workKey);
    assert.equal(work.retryAtMs, startedAt + 5_000);
    assert.equal(
      harness.alarmAt,
      startedAt + 1,
      "creating the cursor requests the prompt first wakeup",
    );

    // Cloudflare returns null from getAlarm while the alarm handler itself is
    // running unless that handler has set a newer alarm. Model consumption of
    // the one-millisecond wakeup before invoking the relay alarm directly.
    now = startedAt + 1;
    harness.clearScheduledAlarm();
    await relay.alarm();

    assert.equal(
      harness.alarmAt,
      startedAt + 5_000,
      "the final scheduler must retain the durable cursor's exact retry time",
    );
    assert.notEqual(
      harness.alarmAt,
      now + 60_000,
      "the routine one-minute wakeup must not replace the pending cursor retry",
    );
  } finally {
    Date.now = originalNow;
  }
});

test("App Attest challenge quota is per-client before D1 and ignores caller key rotation", async () => {
  const { default: worker } = await workerModule();
  const challengeKeys = [];
  const logs = [];
  let routeCircuitCalls = 0;
  let d1Touched = false;
  const environment = {
    DEVICE_API_RATE_LIMIT: {
      async limit() {
        routeCircuitCalls += 1;
        return { success: true };
      },
    },
    APP_ATTEST_CHALLENGE_RATE_LIMIT: {
      async limit({ key }) {
        challengeKeys.push(key);
        return { success: false };
      },
    },
    get DB() {
      d1Touched = true;
      throw new Error("an over-limit challenge must not touch D1");
    },
  };
  const requestForKey = (keyId, clientIp) => new Request(
    "https://quakesignal-api.example/v1/app-attest/challenge",
    {
      method: "POST",
      headers: {
        "content-type": "application/json",
        ...(clientIp === undefined ? {} : { "cf-connecting-ip": clientIp }),
      },
      body: JSON.stringify({
        version: "1",
        keyId,
        operation: "device-registration",
        method: "POST",
        path: "/v1/devices",
        bodySHA256: Buffer.alloc(32).toString("base64url"),
      }),
    },
  );
  const originalConsoleError = console.error;
  console.error = (entry) => logs.push(String(entry));
  try {
    const responses = [];
    for (const request of [
        requestForKey(Buffer.alloc(32).toString("base64url"), "203.0.113.10"),
        requestForKey(Buffer.alloc(32, 1).toString("base64url"), "203.0.113.10"),
        requestForKey(Buffer.alloc(32, 2).toString("base64url"), "203.0.113.11"),
        requestForKey(Buffer.alloc(32, 3).toString("base64url")),
        requestForKey(Buffer.alloc(32, 4).toString("base64url")),
    ]) {
      responses.push(await worker.fetch(request, environment));
    }
    assert.deepEqual(responses.map(({ status }) => status), [429, 429, 429, 429, 429]);
  } finally {
    console.error = originalConsoleError;
  }
  assert.equal(d1Touched, false);
  assert.equal(routeCircuitCalls, 0, "blocked client requests must not consume shared capacity");
  assert.equal(challengeKeys.length, 5);
  assert.equal(challengeKeys[0], challengeKeys[1],
    "the client limiter key must remain stable across untrusted App Attest key IDs");
  assert.notEqual(challengeKeys[0], challengeKeys[2],
    "independent Cloudflare-authenticated client IPs need independent buckets");
  assert.equal(challengeKeys[3], challengeKeys[4],
    "missing headers must share one bounded fallback bucket");
  assert.ok(challengeKeys.every((key) => /^[0-9a-f]{64}$/.test(key)));
  const endpointKeys = [];
  const metadata = await worker.fetch(
    new Request("https://quakesignal-api.example/", {
      headers: { "cf-connecting-ip": "203.0.113.10" },
    }),
    {
      APP_ATTEST_CHALLENGE_RATE_LIMIT: {
        async limit({ key }) {
          endpointKeys.push(key);
          return { success: false };
        },
      },
    },
  );
  assert.equal(metadata.status, 429);
  assert.notEqual(
    endpointKeys[0],
    challengeKeys[0],
    "the same authenticated client IP must receive independent route-scoped keys",
  );
  assert.doesNotMatch(
    JSON.stringify({ challengeKeys, endpointKeys, logs }),
    /203\.0\.113\.(?:10|11)/,
    "neither limiter keys nor logs may expose a raw client IP",
  );
});

test("Cloudflare client IP rate-limit identity rejects malformed values and canonicalizes aliases", async () => {
  const { cloudflareAuthenticatedClientIp } = await workerModule();
  const request = (value) => new Request("https://quakesignal-api.example/", {
    headers: value === undefined ? {} : { "cf-connecting-ip": value },
  });
  assert.equal(cloudflareAuthenticatedClientIp(request("203.000.113.010")), "203.0.113.10");
  assert.equal(cloudflareAuthenticatedClientIp(request("2001:0DB8:0:0:0:0:0:7")), "2001:db8::7");
  assert.equal(cloudflareAuthenticatedClientIp(request("2001:db8::7")), "2001:db8::7");
  for (const malformed of [undefined, "A", "...", "::::", "256.0.0.1", "1.2.3", "2001:::7"]) {
    assert.equal(
      cloudflareAuthenticatedClientIp(request(malformed)),
      null,
      `${String(malformed)} must share the bounded malformed-header fallback`,
    );
  }
});

test("App Attest challenge client quota runs before the higher route-wide circuit breaker", async () => {
  const { default: worker } = await workerModule();
  const calls = [];
  let d1Touched = false;
  const response = await worker.fetch(
    new Request("https://quakesignal-api.example/v1/app-attest/challenge", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "cf-connecting-ip": "2001:db8::7",
      },
      body: "{}",
    }),
    {
      APP_ATTEST_CHALLENGE_RATE_LIMIT: {
        async limit({ key }) {
          calls.push({ limiter: "client", key });
          return { success: true };
        },
      },
      DEVICE_API_RATE_LIMIT: {
        async limit({ key }) {
          calls.push({ limiter: "route", key });
          return { success: false };
        },
      },
      get DB() {
        d1Touched = true;
        throw new Error("the route circuit breaker must run before D1");
      },
    },
  );
  assert.equal(response.status, 429);
  assert.equal(d1Touched, false);
  assert.deepEqual(calls.map(({ limiter }) => limiter), ["client", "route"]);
  assert.notEqual(calls[0].key, calls[1].key, "client and route counters are independent");

  const wrangler = await readFile(join(cloudflareDirectory, "wrangler.jsonc"), "utf8");
  assert.match(
    wrangler,
    /"name": "DEVICE_API_RATE_LIMIT"[\s\S]*?"limit": 300/,
  );
  assert.match(
    wrangler,
    /"name": "APP_ATTEST_CHALLENGE_RATE_LIMIT"[\s\S]*?"limit": 60/,
  );
});

test("public device mutations admit the client bucket before a shared route circuit breaker", async () => {
  const { default: worker } = await workerModule();
  const calls = [];
  const environment = {
    APP_ATTEST_ENFORCEMENT: "required",
    APP_ATTEST_CHALLENGE_RATE_LIMIT: {
      async limit({ key }) {
        calls.push({ limiter: "client", key });
        return { success: true };
      },
    },
    DEVICE_API_RATE_LIMIT: {
      async limit({ key }) {
        calls.push({ limiter: "route", key });
        return { success: true };
      },
    },
  };
  for (const clientIp of ["203.0.113.31", "203.0.113.32"]) {
    const response = await worker.fetch(
      new Request("https://quakesignal-api.example/v1/devices", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "cf-connecting-ip": clientIp,
        },
        body: "{}",
      }),
      environment,
    );
    assert.equal(response.status, 401);
  }
  assert.deepEqual(
    calls.map(({ limiter }) => limiter),
    ["client", "route", "client", "route"],
  );
  assert.notEqual(
    calls[0].key,
    calls[2].key,
    "independent clients retain independent 60/minute budgets",
  );
  assert.equal(
    calls[1].key,
    calls[3].key,
    "admitted distributed requests share the 300/minute route circuit breaker",
  );
  assert.notEqual(
    calls[0].key,
    calls[1].key,
    "the client and circuit keys remain domain-separated",
  );
});

test("every public branch is client-limited before its normalized route circuit", async () => {
  const { default: worker } = await workerModule();
  const calls = [];
  const environment = {
    APP_ATTEST_CHALLENGE_RATE_LIMIT: {
      async limit({ key }) {
        calls.push({ limiter: "client", key });
        return { success: true };
      },
    },
    DEVICE_API_RATE_LIMIT: {
      async limit({ key }) {
        calls.push({ limiter: "route", key });
        return { success: true };
      },
    },
  };
  const requests = [
    new Request("https://quakesignal-api.example/"),
    new Request("https://quakesignal-api.example/privacy"),
    new Request("https://quakesignal-api.example/terms"),
    new Request("https://quakesignal-api.example/support"),
    new Request("https://quakesignal-api.example/anything", { method: "OPTIONS" }),
    new Request("https://quakesignal-api.example/unmatched-one"),
    new Request("https://quakesignal-api.example/unmatched-two"),
  ];
  for (const request of requests) {
    const response = await worker.fetch(request, environment);
    assert.ok([200, 404, 405].includes(response.status));
  }
  assert.equal(calls.length, requests.length * 2);
  assert.deepEqual(
    calls.map(({ limiter }) => limiter),
    requests.flatMap(() => ["client", "route"]),
    "every branch enters the 60/client gate before the 300/route circuit",
  );
  assert.equal(
    calls.at(-3).key,
    calls.at(-1).key,
    "arbitrary 404 paths share one bounded normalized unmatched circuit",
  );
});

test("a missing server verifier requests fresh attestation after automatic token cleanup", async () => {
  const { default: worker } = await workerModule();
  const wireKeyId = Buffer.alloc(32, 7).toString("base64url");
  const storedKeyId = Buffer.alloc(32, 7).toString("base64");
  const prepared = [];
  const batches = [];
  const environment = {
    APP_ATTEST_ENFORCEMENT: "required",
    APP_ATTEST_CHALLENGE_RATE_LIMIT: {
      async limit() {
        return { success: true };
      },
    },
    DEVICE_API_RATE_LIMIT: {
      async limit() {
        return { success: true };
      },
    },
    DEVICE_MUTATION_RATE_LIMIT: {
      async limit() {
        return { success: true };
      },
    },
    DB: {
      prepare(sql) {
        return {
          bind(...bindings) {
            const statement = { sql, bindings };
            prepared.push(statement);
            return {
              ...statement,
              async first() {
                assert.match(sql, /SELECT key_id, app_id FROM app_attest_keys/);
                return null;
              },
            };
          },
        };
      },
      async batch(statements) {
        batches.push(statements);
        return statements.map(() => ({ meta: { changes: 1 } }));
      },
    },
  };

  const response = await worker.fetch(
    new Request("https://quakesignal-api.example/v1/app-attest/challenge", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "cf-connecting-ip": "203.0.113.25",
      },
      body: JSON.stringify({
        version: "1",
        keyId: wireKeyId,
        operation: "device-registration",
        method: "POST",
        path: "/v1/devices",
        bodySHA256: Buffer.alloc(32).toString("base64url"),
      }),
    }),
    environment,
  );

  assert.equal(response.status, 201);
  assert.equal((await response.json()).proofType, "attestation");
  assert.equal(
    prepared.find(({ sql }) => sql.includes("SELECT key_id, app_id"))?.bindings[0],
    storedKeyId,
  );
  const insertChallenge = batches.flat().find(({ sql }) =>
    sql.includes("INSERT INTO app_attest_challenges")
  );
  assert.ok(insertChallenge);
  assert.equal(insertChallenge.bindings[1], storedKeyId);
  assert.equal(insertChallenge.bindings[8], "attestation");
});

test("training pushes obtain APNs authorization from the relay cache and fail closed", async () => {
  const { handleDeviceTestPush } = await workerModule();
  const originalFetch = globalThis.fetch;
  const relayPaths = [];
  const apnsAuthorizations = [];
  const apnsSources = [];
  const device = {
    token: "abcdef0123456789".repeat(4),
    environment: "sandbox",
    locale: null,
    // Simulate a registration created before build 8. Its old selection must
    // never determine the source identity of a new training notification.
    sources: '["cenc_eew"]',
    min_magnitude: 0,
    critical_alerts_enabled: 0,
    city_name: null,
    latitude: null,
    longitude: null,
    radius_km: null,
    include_test_alerts: 1,
    utc_offset_minutes: null,
    notify_at_night: 1,
    created_at: "2026-08-12T00:00:00.000Z",
    updated_at: "2026-08-12T00:00:00.000Z",
  };
  const baseEnvironment = {
    // This regression exercises the explicitly isolated staging/sandbox
    // test-push path. Production must instead reject this stored token before
    // it obtains a relay authorization or sends APNs traffic.
    APP_ATTEST_ENFORCEMENT: "development",
    APP_ATTEST_DEVELOPMENT_ENVIRONMENT: "true",
    DB: {
      prepare() {
        return {
          bind() {
            return {
              async first() {
                return device;
              },
            };
          },
        };
      },
    },
    DEVICE_MUTATION_RATE_LIMIT: {
      async limit() {
        return { success: true };
      },
    },
    APNS_PRIVATE_KEY: "intentionally-not-parsed-when-relay-cache-is-used",
    APNS_KEY_ID: "ABCDEFGHIJ",
    APNS_TEAM_ID: "ABCDEFGHIJ",
    APNS_BUNDLE_ID: "com.quakesignal.app",
    RELAY: {
      idFromName() {
        return "global";
      },
      get() {
        return {
          async fetch(request) {
            relayPaths.push(new URL(request.url).pathname);
            return Response.json({ authorization: "cached.provider.jwt" });
          },
        };
      },
    },
  };
  const request = new Request("https://quakesignal-api.example/v1/devices/test", {
    method: "POST",
  });
  const payload = {
    body: { token: device.token },
    bytes: new TextEncoder().encode(JSON.stringify({ token: device.token })),
  };
  const authorization = {
    mode: "development_bypass",
    keyId: null,
    appRoute: {
      appIdentity: "5TT564H883.com.quakesignal.app",
      apnsTopic: "com.quakesignal.app",
      platform: "ios",
    },
  };
  globalThis.fetch = async (_url, init) => {
    apnsAuthorizations.push(new Headers(init.headers).get("authorization"));
    apnsSources.push(JSON.parse(init.body).sourceId);
    return new Response(null, { status: 200, headers: { "apns-id": "test-id" } });
  };
  try {
    const response = await handleDeviceTestPush(
      request,
      baseEnvironment,
      payload,
      authorization,
    );
    assert.equal(response.status, 200);
    assert.deepEqual(relayPaths, ["/apns/authorization"]);
    assert.deepEqual(apnsAuthorizations, ["bearer cached.provider.jwt"]);
    assert.deepEqual(apnsSources, ["jma_eew"]);

    const relayCallsBeforeMismatch = relayPaths.length;
    const apnsCallsBeforeMismatch = apnsAuthorizations.length;
    const mismatchedProductionResponse = await handleDeviceTestPush(
      request,
      {
        ...baseEnvironment,
        APP_ATTEST_ENFORCEMENT: "required",
        APP_ATTEST_DEVELOPMENT_ENVIRONMENT: undefined,
      },
      payload,
      { mode: "attested", keyId: "production-app-attest-key", environment: "production" },
    );
    assert.equal(
      mismatchedProductionResponse.status,
      403,
      "a production Worker must reject a historical sandbox registration before APNs",
    );
    assert.equal(relayPaths.length, relayCallsBeforeMismatch);
    assert.equal(apnsAuthorizations.length, apnsCallsBeforeMismatch);

    const failingResponse = await handleDeviceTestPush(
      request,
      {
        ...baseEnvironment,
        RELAY: {
          idFromName() {
            return "global";
          },
          get() {
            return { async fetch() { return new Response(null, { status: 503 }); } };
          },
        },
      },
      payload,
      authorization,
    );
    assert.equal(
      failingResponse.status,
      502,
      "a failed relay authorization must still fail the test push closed",
    );
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("an undrained live-ingest journal immediately makes its source stale", async () => {
  const { isUpstreamSourceStale } = await workerModule();
  const now = Date.parse("2026-08-12T00:10:00.000Z");
  assert.equal(isUpstreamSourceStale("open", now, false, now), false);
  assert.equal(
    isUpstreamSourceStale("closed", now, false, now),
    true,
    "a fresh HTTP seed cannot mask a closed live WebSocket route",
  );
  assert.equal(
    isUpstreamSourceStale("open", now, true, now),
    true,
    "a recent heartbeat cannot mask a durable event awaiting D1 ingestion",
  );
});

test("coalesces committed live freshness checkpoints without hiding pending ingest", async () => {
  const { QuakeRelay } = await workerModule();
  const originalNow = Date.now;
  let now = Date.parse("2026-08-13T00:00:00.000Z");
  const values = new Map();
  const writes = [];
  const state = {
    storage: {
      async get(key) { return values.get(key); },
      async put(key, value) {
        writes.push([key, value]);
        values.set(key, value);
      },
      async list({ prefix = "" } = {}) {
        return new Map([...values].filter(([key]) => key.startsWith(prefix)));
      },
    },
    waitUntil() {},
  };
  const upstreamKey = "upstream-last-success-ms:jma_eew";
  const httpKey = "upstream-last-http-success-ms:jma_eew";
  const relay = new QuakeRelay(state, {});
  try {
    Date.now = () => now;
    await Promise.all(
      Array.from({ length: 8 }, () => relay.markSourceSuccessful("jma_eew")),
    );
    assert.deepEqual(
      writes.filter(([key]) => key === upstreamKey),
      [[upstreamKey, now]],
      "concurrent committed-success signals write one initial checkpoint",
    );

    now += 30_000;
    const restartedRelay = new QuakeRelay(state, {});
    await restartedRelay.markSourceSuccessful("jma_eew");
    assert.equal(
      writes.filter(([key]) => key === upstreamKey).length,
      1,
      "a fresh durable checkpoint survives an eviction without another write",
    );
    assert.equal(
      restartedRelay.lastSuccessfulUpstreamMs.get("jma_eew"),
      now,
      "the new committed-success signal remains fresh in memory",
    );

    now += 30_000;
    await relay.markSourceSuccessful("jma_eew");
    assert.equal(
      writes.filter(([key]) => key === upstreamKey).length,
      2,
      "the WebSocket checkpoint is renewed once per minute",
    );

    const previousLiveSuccess = relay.lastSuccessfulUpstreamMs.get("jma_eew");
    values.set("pending-ingest:jma_eew:uncommitted", { event: "pending" });
    now += 60_000;
    await relay.markSourceSuccessful("jma_eew");
    assert.equal(
      writes.filter(([key]) => key === upstreamKey).length,
      2,
      "source success never overwrites the pending-ingest readiness fence",
    );
    assert.equal(
      relay.lastSuccessfulUpstreamMs.get("jma_eew"),
      previousLiveSuccess,
    );

    values.delete("pending-ingest:jma_eew:uncommitted");
    await relay.markHttpSourceSuccessful("jma_eew");
    now += 59_999;
    await relay.markHttpSourceSuccessful("jma_eew");
    now += 1;
    await relay.markHttpSourceSuccessful("jma_eew");
    assert.deepEqual(
      writes.filter(([key]) => key === httpKey),
      [
        [httpKey, Date.parse("2026-08-13T00:02:00.000Z")],
        [httpKey, Date.parse("2026-08-13T00:03:00.000Z")],
      ],
      "alternate HTTP freshness remains inside its stale window without every-poll writes",
    );
  } finally {
    Date.now = originalNow;
  }
});

test("failed freshness checkpoints do not publish in-memory success", async () => {
  const { QuakeRelay } = await workerModule();
  const originalNow = Date.now;
  let now = Date.parse("2026-08-13T00:00:00.000Z");
  let putAttempts = 0;
  const state = {
    storage: {
      async get() { return undefined; },
      async list() { return new Map(); },
      async put() {
        putAttempts += 1;
        throw new Error("Durable Object free-tier write quota exhausted");
      },
    },
    waitUntil() {},
  };
  const relay = new QuakeRelay(state, {});
  try {
    Date.now = () => now;
    await assert.rejects(
      () => relay.markSourceSuccessful("jma_eew"),
      /write quota exhausted/,
    );
    await relay.markSourceSuccessful("jma_eew");
    assert.equal(
      putAttempts,
      1,
      "a quota failure is retried at the checkpoint cadence, not every success signal",
    );
    assert.equal(relay.lastSuccessfulUpstreamMs.has("jma_eew"), false);

    now += 60_000;
    await assert.rejects(
      () => relay.markSourceSuccessful("jma_eew"),
      /write quota exhausted/,
    );
    assert.equal(putAttempts, 2);
  } finally {
    Date.now = originalNow;
  }
});

test("bounds HTTP seeding concurrency and preserves source order", async () => {
  const { mapWithConcurrency } = await workerModule();
  let active = 0;
  let peak = 0;
  const releases = [];
  const values = ["jma_eew", "sc_eew", "cenc_eew", "fj_eew", "cq_eew"];
  const promise = mapWithConcurrency(values, 2, async (source, index) => {
    active += 1;
    peak = Math.max(peak, active);
    await new Promise((resolve) => releases[index] = resolve);
    active -= 1;
    return `${index}:${source}`;
  });
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(peak, 2, "only two HTTP seeds may be in flight at once");
  for (let index = 0; index < values.length; index += 1) {
    releases[index]?.();
    await new Promise((resolve) => setImmediate(resolve));
  }
  assert.deepEqual(
    await promise,
    values.map((source, index) => `${index}:${source}`),
    "bounded completion must retain the original source ordering",
  );
  await assert.rejects(
    () => mapWithConcurrency([], 0, async () => null),
    /positive safe integer/,
  );
});

test("keeps a short websocket reconnect alarm ahead of routine relay work", async () => {
  const { preferredRelayAlarmAt } = await workerModule();
  const now = Date.parse("2026-08-12T00:10:00.000Z");
  assert.equal(preferredRelayAlarmAt(now + 1_000, now), now + 1_000);
  assert.equal(preferredRelayAlarmAt(null, now), now + 60_000);
  assert.equal(preferredRelayAlarmAt(now - 1, now), now + 60_000);
  assert.equal(preferredRelayAlarmAt(now + 60_000, now), now + 60_000);
});

test("notifies only genuine EEW warning transitions and meaningful lifecycle states", async () => {
  const { notificationReasonForEvent, reconcileEventRevision } = await workerModule();
  const event = {
    id: "jma_eew:transition-test",
    sourceId: "jma_eew",
    eventId: "transition-test",
    serial: 1,
    kind: "eew",
    originTimeUtc: "2026-08-19T00:00:00.000Z",
    reportTimeUtc: "2026-08-19T00:00:05.000Z",
    hypocenter: "Test Region",
    latitude: 35,
    longitude: 135,
    magnitude: 5.5,
    depth: 10,
    maxIntensity: "5-",
    isWarn: false,
    isFinal: false,
    isCancel: false,
    isTraining: false,
    tsunami: null,
    raw: null,
  };
  assert.equal(notificationReasonForEvent(event, null), null);
  assert.equal(
    notificationReasonForEvent({ ...event, serial: 2 }, event),
    null,
    "an informational EEW serial update must stay silent",
  );

  const warning = { ...event, isWarn: true };
  assert.equal(notificationReasonForEvent(warning, null), "new");
  assert.equal(
    notificationReasonForEvent(warning, event),
    "new",
    "a same-serial transition into warning state must notify",
  );
  assert.equal(
    notificationReasonForEvent({ ...warning, serial: 2 }, warning),
    "updated",
  );
  assert.equal(
    notificationReasonForEvent({ ...event, isFinal: true }, null),
    null,
  );
  assert.equal(
    notificationReasonForEvent({ ...warning, isFinal: true }, warning),
    "final",
  );
  assert.equal(
    notificationReasonForEvent({ ...event, isCancel: true }, null),
    null,
  );
  assert.equal(
    notificationReasonForEvent({ ...warning, isCancel: true }, warning),
    "cancelled",
  );

  const finalWarning = { ...warning, isFinal: true };
  assert.equal(
    reconcileEventRevision(warning, finalWarning),
    null,
    "a same-serial active replay cannot replace a final warning",
  );
  assert.equal(notificationReasonForEvent(warning, finalWarning), null);
  const higherAfterFinal = reconcileEventRevision(
    { ...warning, serial: warning.serial + 1 },
    finalWarning,
  );
  assert.equal(higherAfterFinal?.serial, warning.serial + 1);
  assert.equal(higherAfterFinal?.isFinal, true);
  assert.equal(notificationReasonForEvent(higherAfterFinal, finalWarning), null);

  const cancelledAfterFinal = {
    ...warning,
    serial: warning.serial + 1,
    isCancel: true,
  };
  const acceptedCancellation = reconcileEventRevision(
    cancelledAfterFinal,
    finalWarning,
  );
  assert.equal(acceptedCancellation?.isFinal, true);
  assert.equal(acceptedCancellation?.isCancel, true);
  assert.equal(
    notificationReasonForEvent(acceptedCancellation, finalWarning),
    "cancelled",
    "final to cancelled remains a valid terminal transition",
  );

  assert.equal(
    reconcileEventRevision(
      { ...warning, serial: cancelledAfterFinal.serial },
      acceptedCancellation,
    ),
    null,
    "a same-serial active replay cannot replace a cancellation",
  );
  const higherAfterCancellation = reconcileEventRevision(
    { ...warning, serial: cancelledAfterFinal.serial + 1 },
    acceptedCancellation,
  );
  assert.equal(higherAfterCancellation?.isCancel, true);
  assert.equal(
    notificationReasonForEvent(higherAfterCancellation, acceptedCancellation),
    null,
  );
});

test("builds bounded typed APNs snapshots and reserves custom Time Sensitive sound for fresh warnings", async () => {
  const { buildPushPayload } = await workerModule();
  const nowMs = Date.parse("2026-08-19T00:05:00.000Z");
  const warning = {
    id: "jma_eew:payload-test",
    sourceId: "jma_eew",
    eventId: "payload-test",
    serial: 7,
    kind: "eew",
    originTimeUtc: "2026-08-19T00:04:00.000Z",
    reportTimeUtc: "2026-08-19T00:04:30.000Z",
    hypocenter: "能登半島沖",
    latitude: 37.4,
    longitude: 137.2,
    magnitude: 6.1,
    depth: 12,
    maxIntensity: "6-",
    isWarn: true,
    isFinal: false,
    isCancel: false,
    isTraining: false,
    tsunami: "checking",
    raw: { mustNotLeak: true },
  };
  const expectedSnapshot = {
    sourceId: warning.sourceId,
    eventId: warning.eventId,
    serial: warning.serial,
    kind: warning.kind,
    originTimeUtc: warning.originTimeUtc,
    reportTimeUtc: warning.reportTimeUtc,
    hypocenter: warning.hypocenter,
    latitude: warning.latitude,
    longitude: warning.longitude,
    magnitude: warning.magnitude,
    depth: warning.depth,
    maxIntensity: warning.maxIntensity,
    isWarn: warning.isWarn,
    isFinal: warning.isFinal,
    isCancel: warning.isCancel,
    isTraining: warning.isTraining,
    tsunami: warning.tsunami,
  };
  for (const [alertSound, expectedFile] of [
    ["system", "default"],
    ["urgent-tone", "quakesignal_urgent.caf"],
    ["japanese-voice", "quakesignal_japanese_voice.caf"],
  ]) {
    const payload = buildPushPayload(warning, "new", alertSound, nowMs);
    assert.equal(payload.aps.sound, expectedFile);
    assert.equal(payload.aps["interruption-level"], "time-sensitive");
    assert.deepEqual(payload.event, expectedSnapshot);
    assert.deepEqual(JSON.parse(JSON.stringify(payload)).event, expectedSnapshot);
    assert.equal(payload.eventId, warning.eventId, "legacy payload fields remain available");
    assert.equal(payload.serial, warning.serial);
    assert.equal(payload.kind, warning.kind);
    assert.equal(payload.originTimeUtc, warning.originTimeUtc);
    assert.equal(payload.reportTimeUtc, warning.reportTimeUtc);
    assert.equal(payload.isWarn, warning.isWarn);
    assert.equal(payload.isFinal, warning.isFinal);
    assert.equal(payload.isCancel, warning.isCancel);
    assert.equal(payload.isTraining, warning.isTraining);
    assert.equal("raw" in payload.event, false);
  }

  const stale = buildPushPayload(
    warning,
    "new",
    "japanese-voice",
    Date.parse("2026-08-19T00:15:01.000Z"),
  );
  assert.equal(stale.aps.sound, "default");
  assert.equal(stale.aps["interruption-level"], "active");
  for (const [reason, lifecycle] of [
    ["final", { isFinal: true }],
    ["cancelled", { isCancel: true }],
    ["training", { isTraining: true }],
  ]) {
    const payload = buildPushPayload(
      { ...warning, ...lifecycle },
      reason,
      "urgent-tone",
      nowMs,
    );
    assert.equal(payload.aps.sound, "default");
    assert.equal(payload.aps["interruption-level"], "active");
  }

  const oversizedSource = {
    ...warning,
    eventId: "🫨".repeat(4_000),
    hypocenter: "震源地域".repeat(4_000),
    maxIntensity: "最大震度".repeat(4_000),
    tsunami: "津波調査中".repeat(4_000),
  };
  const bounded = buildPushPayload(
    oversizedSource,
    "new",
    "urgent-tone",
    nowMs,
  );
  assert.ok(
    new TextEncoder().encode(JSON.stringify(bounded)).byteLength <= 4_096,
    "the complete regular APNs payload must stay within 4 KB",
  );
});

test("accepts only exact alert-sound registration identifiers and defaults old clients to system", async () => {
  const {
    APNS_RELAY_DISABLED_SOURCES,
    APNS_RELAY_SOURCES,
    registrationStatement,
    validatedRegistrationValues,
  } = await workerModule();
  const registration = {
    token: "0123456789abcdef",
    latitude: 35,
    longitude: 135,
    radiusKm: 100,
  };
  const legacy = validatedRegistrationValues(registration);
  assert.equal(legacy.alertSound, "system");
  assert.deepEqual(JSON.parse(legacy.sources), ["jma_eew", "jma_eqlist"]);
  for (const invalidToken of [
    "0123456789abcde",
    "0123456789ABCDEf",
    "0123456789abcdeg",
    "01234567 89abcdef",
  ]) {
    const response = validatedRegistrationValues({
      ...registration,
      token: invalidToken,
    });
    assert.ok(response instanceof Response);
    assert.equal(
      response.status,
      400,
      "APNs tokens must use even-length canonical lowercase hexadecimal without assuming a fixed byte length",
    );
  }
  for (const missingLocation of [
    { token: registration.token },
    { ...registration, latitude: undefined },
    { ...registration, longitude: undefined },
    { ...registration, radiusKm: undefined },
  ]) {
    const response = validatedRegistrationValues(missingLocation);
    assert.ok(response instanceof Response);
    assert.equal(response.status, 400, "automatic registrations require a complete radius filter");
  }
  const jmaOnly = validatedRegistrationValues({
    ...registration,
    sources: ["jma_eew", "jma_eqlist"],
  });
  assert.ok(!(jmaOnly instanceof Response));
  assert.deepEqual(JSON.parse(jmaOnly.sources), APNS_RELAY_SOURCES);
  const registrationCapture = capturedStatementDatabase();
  registrationStatement(
    registrationCapture.database,
    jmaOnly,
    "registration-generation-key",
    {
      appIdentity: "5TT564H883.com.quakesignal.app",
      apnsTopic: "com.quakesignal.app",
      platform: "ios",
    },
  );
  assert.match(
    registrationCapture.captured.sql,
    /registration_revision = excluded\.registration_revision/,
    "every successful same-token UPSERT must replace the sent-snapshot identity",
  );
  assert.match(
    registrationCapture.captured.bindings[17],
    /^[0-9a-f]{8}-[0-9a-f]{4}-[45][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i,
  );
  const secondRegistrationCapture = capturedStatementDatabase();
  registrationStatement(
    secondRegistrationCapture.database,
    jmaOnly,
    "registration-generation-key",
    {
      appIdentity: "5TT564H883.com.quakesignal.app",
      apnsTopic: "com.quakesignal.app",
      platform: "ios",
    },
  );
  assert.notEqual(
    secondRegistrationCapture.captured.bindings[17],
    registrationCapture.captured.bindings[17],
    "a fresh row revision prevents delete-and-reinsert ABA reuse",
  );
  const noSources = validatedRegistrationValues({
    ...registration,
    sources: [],
  });
  assert.ok(noSources instanceof Response);
  assert.equal(noSources.status, 400, "a registration must select at least one source");
  for (const source of APNS_RELAY_DISABLED_SOURCES) {
    const response = validatedRegistrationValues({
      ...registration,
      sources: [source],
    });
    assert.ok(response instanceof Response);
    assert.equal(response.status, 400, `${source} must not be registered`);
  }
  for (const alertSound of ["system", "urgent-tone", "japanese-voice"]) {
    const values = validatedRegistrationValues({ ...registration, alertSound });
    assert.equal(values.alertSound, alertSound);
  }
  for (const alertSound of [null, "", "urgent", "Urgent-Tone", "japanese_voice", 1]) {
    const response = validatedRegistrationValues({ ...registration, alertSound });
    assert.ok(response instanceof Response);
    assert.equal(response.status, 400);
  }
  const selectedIdentity = validatedRegistrationValues({
    ...registration,
    appIdentity: "5TT564H883.com.quakesignal.app.watchkitapp",
  });
  assert.ok(!(selectedIdentity instanceof Response));
  assert.equal(
    Object.hasOwn(selectedIdentity, "apnsTopic"),
    false,
    "the client identity selector is not itself a persisted APNs route",
  );
  for (const injectedRoute of [
    { apnsTopic: "attacker.topic" },
    { apns_topic: "attacker.topic" },
    { topic: "attacker.topic" },
    { bundleId: "attacker.topic" },
    { bundleIdentifier: "attacker.topic" },
    { appPlatform: "watchos" },
    { app_platform: "watchos" },
    { platform: "watchos" },
  ]) {
    const response = validatedRegistrationValues({ ...registration, ...injectedRoute });
    assert.ok(response instanceof Response);
    assert.equal(response.status, 400, "a raw client route is never accepted");
  }
});

test("calculates bounded reason-specific delivery deadlines", async () => {
  const { calculateAlertDeliveryExpiry } = await workerModule();
  const event = {
    originTimeUtc: "2026-08-12T00:00:00.000Z",
    reportTimeUtc: "2026-08-12T00:05:00.000Z",
  };
  assert.deepEqual(
    calculateAlertDeliveryExpiry(event, "new", "2026-08-12T00:10:00.000Z"),
    { expiresAtUtc: "2026-08-12T00:15:00.000Z", expiryPolicy: "eew_10m" },
  );
  assert.deepEqual(
    calculateAlertDeliveryExpiry(event, "final", "2026-08-12T00:10:00.000Z"),
    { expiresAtUtc: "2026-08-12T01:05:00.000Z", expiryPolicy: "report_60m" },
  );
  assert.deepEqual(
    calculateAlertDeliveryExpiry(
      { originTimeUtc: null, reportTimeUtc: "not-a-date" },
      "training",
      "2026-08-12T00:10:00.000Z",
    ),
    { expiresAtUtc: "2026-08-12T00:40:00.000Z", expiryPolicy: "training_30m" },
  );
  assert.deepEqual(
    calculateAlertDeliveryExpiry(
      { originTimeUtc: "2026-08-12T00:00:00.000Z", reportTimeUtc: "not-a-date" },
      "new",
      "2026-08-12T00:10:00.000Z",
    ),
    { expiresAtUtc: "2026-08-12T00:10:00.000Z", expiryPolicy: "eew_10m" },
  );
  assert.deepEqual(
    calculateAlertDeliveryExpiry(
      { originTimeUtc: "2026-08-12T03:00:00.000Z", reportTimeUtc: null },
      "new",
      "2026-08-12T00:10:00.000Z",
    ),
    { expiresAtUtc: "2026-08-12T00:20:00.000Z", expiryPolicy: "eew_10m" },
  );
  assert.deepEqual(
    calculateAlertDeliveryExpiry(event, "cancelled", "2026-08-12T00:10:00.000Z"),
    { expiresAtUtc: "2026-08-12T01:05:00.000Z", expiryPolicy: "report_60m" },
  );
});

test("migration 0010 preserves outbox state while capping pending urgent work at ten minutes", async (t) => {
  const directory = await mkdtemp(join(tmpdir(), "quakesignal-migration-0010-"));
  const databasePath = join(directory, "migration.sqlite");
  const sqlite = new DatabaseSync(databasePath);
  t.after(async () => {
    sqlite.close();
    await rm(directory, { recursive: true, force: true });
  });

  const migrationEntries = await readdir(join(cloudflareDirectory, "migrations"));
  for (let version = 1; version <= 9; version += 1) {
    const filename = migrationEntries.find((entry) =>
      entry.startsWith(String(version).padStart(4, "0")),
    );
    assert.ok(filename, `migration ${version} must exist`);
    sqlite.exec(await readFile(join(cloudflareDirectory, "migrations", filename), "utf8"));
  }
  sqlite.exec(`
    INSERT INTO devices (
      token, environment, sources, min_magnitude, critical_alerts_enabled,
      include_test_alerts, notify_at_night, created_at, updated_at
    ) VALUES (
      'migration-device-token', 'production', '["jma_eew"]', 0, 0, 0, 1,
      '2026-08-19T00:00:00.000Z', '2026-08-19T00:00:00.000Z'
    );
    INSERT INTO alert_delivery_outbox (
      id, dedupe_key, delivery_id, root_delivery_id, event_ref, event_serial,
      notification_reason, event_json, created_at_utc, next_enqueue_at_utc,
      expires_at_utc, expiry_policy
    ) VALUES (
      'migration-outbox', 'migration-dedupe', 'migration-delivery',
      'migration-root', 'jma_eew:migration', 4, 'updated', '{}',
      '2026-08-19T00:00:00.000Z', '2026-08-19T00:00:00.000Z',
      '2026-08-19T00:30:00.000Z', 'eew_30m'
    );
  `);
  sqlite.exec(await readFile(
    join(
      cloudflareDirectory,
      "migrations/0010_alert_sound_and_urgent_eew_deadline.sql",
    ),
    "utf8",
  ));

  assert.deepEqual(
    {
      ...sqlite.prepare(
        "SELECT token, alert_sound FROM devices WHERE token = 'migration-device-token'",
      ).get(),
    },
    { token: "migration-device-token", alert_sound: "system" },
  );
  assert.deepEqual(
    {
      ...sqlite.prepare(
        `SELECT delivery_id, root_delivery_id, event_serial, expires_at_utc,
                expiry_policy
         FROM alert_delivery_outbox WHERE id = 'migration-outbox'`,
      ).get(),
    },
    {
      delivery_id: "migration-delivery",
      root_delivery_id: "migration-root",
      event_serial: 4,
      expires_at_utc: "2026-08-19T00:10:00.000Z",
      expiry_policy: "eew_10m",
    },
  );
  assert.deepEqual(
    sqlite.prepare(
      `SELECT name FROM sqlite_master
       WHERE type = 'index' AND name LIKE 'idx_alert_delivery_outbox_%'
       ORDER BY name`,
    ).all().map(({ name }) => name),
    [
      "idx_alert_delivery_outbox_leased_pending",
      "idx_alert_delivery_outbox_pending",
      "idx_alert_delivery_outbox_terminal_retention",
    ],
  );
  assert.throws(
    () => sqlite.exec(
      "UPDATE devices SET alert_sound = 'official-j-alert' WHERE token = 'migration-device-token'",
    ),
    /constraint/i,
  );
});

test("migration 0011 backfills the legacy iOS route and constrains platform metadata", async (t) => {
  const directory = await mkdtemp(join(tmpdir(), "quakesignal-migration-0011-"));
  const databasePath = join(directory, "migration.sqlite");
  const sqlite = new DatabaseSync(databasePath);
  t.after(async () => {
    sqlite.close();
    await rm(directory, { recursive: true, force: true });
  });

  const migrationEntries = await readdir(join(cloudflareDirectory, "migrations"));
  for (let version = 1; version <= 10; version += 1) {
    const filename = migrationEntries.find((entry) =>
      entry.startsWith(String(version).padStart(4, "0")),
    );
    assert.ok(filename, `migration ${version} must exist`);
    sqlite.exec(await readFile(join(cloudflareDirectory, "migrations", filename), "utf8"));
  }
  sqlite.exec(`
    INSERT INTO devices (
      token, environment, sources, min_magnitude, critical_alerts_enabled,
      include_test_alerts, notify_at_night, created_at, updated_at
    ) VALUES (
      'legacy-route-token', 'production', '["jma_eew"]', 0, 0, 0, 1,
      '2026-08-19T00:00:00.000Z', '2026-08-19T00:00:00.000Z'
    )
  `);
  sqlite.exec(await readFile(
    join(cloudflareDirectory, "migrations/0011_authenticated_app_routes.sql"),
    "utf8",
  ));

  assert.deepEqual(
    {
      ...sqlite.prepare(
        `SELECT app_identity, apns_topic, app_platform
         FROM devices WHERE token = 'legacy-route-token'`,
      ).get(),
    },
    {
      app_identity: "5TT564H883.com.quakesignal.app",
      apns_topic: "com.quakesignal.app",
      app_platform: "ios",
    },
  );
  sqlite.exec(`
    INSERT INTO devices (
      token, environment, sources, min_magnitude, critical_alerts_enabled,
      include_test_alerts, notify_at_night, app_identity, apns_topic,
      app_platform, created_at, updated_at
    ) VALUES (
      'watch-route-token', 'production', '["jma_eew"]', 0, 0, 0, 1,
      '5TT564H883.com.quakesignal.app.watchkitapp',
      'com.quakesignal.app.watchkitapp', 'watchos',
      '2026-08-19T00:00:00.000Z', '2026-08-19T00:00:00.000Z'
    )
  `);
  assert.throws(
    () => sqlite.exec(
      "UPDATE devices SET app_platform = 'carplay' WHERE token = 'legacy-route-token'",
    ),
    /constraint/i,
  );
  assert.throws(
    () => sqlite.exec(
      "UPDATE devices SET apns_topic = '' WHERE token = 'legacy-route-token'",
    ),
    /constraint/i,
  );
  assert.deepEqual(
    sqlite.prepare(
      `SELECT name FROM sqlite_master
       WHERE type = 'index' AND name = 'idx_devices_authenticated_app_route'`,
    ).all().map(({ name }) => name),
    ["idx_devices_authenticated_app_route"],
  );
});

test("migration 0012 indexes the bounded event-revision retention cutoff", async (t) => {
  const directory = await mkdtemp(join(tmpdir(), "quakesignal-migration-0012-"));
  const databasePath = join(directory, "migration.sqlite");
  const sqlite = new DatabaseSync(databasePath);
  t.after(async () => {
    sqlite.close();
    await rm(directory, { recursive: true, force: true });
  });

  const migrationEntries = await readdir(join(cloudflareDirectory, "migrations"));
  for (let version = 1; version <= 12; version += 1) {
    const filename = migrationEntries.find((entry) =>
      entry.startsWith(String(version).padStart(4, "0")),
    );
    assert.ok(filename, `migration ${version} must exist`);
    sqlite.exec(await readFile(join(cloudflareDirectory, "migrations", filename), "utf8"));
  }

  assert.deepEqual(
    sqlite.prepare(
      `SELECT name, sql FROM sqlite_master
       WHERE type = 'index' AND name = 'idx_revisions_recorded_at'`,
    ).all().map((row) => ({ ...row })),
    [{
      name: "idx_revisions_recorded_at",
      sql: "CREATE INDEX idx_revisions_recorded_at\n  ON event_revisions(recorded_at_utc)",
    }],
  );
});

test("migration 0013 adds revision fencing, pseudonymous lifecycle continuity, and resolution-based retention", async (t) => {
  const { terminalAlertLifecycleDevices } = await workerModule();
  const directory = await mkdtemp(join(tmpdir(), "quakesignal-migration-0013-"));
  const databasePath = join(directory, "migration.sqlite");
  const sqlite = new DatabaseSync(databasePath);
  t.after(async () => {
    sqlite.close();
    await rm(directory, { recursive: true, force: true });
  });

  const migrationEntries = await readdir(join(cloudflareDirectory, "migrations"));
  for (let version = 1; version <= 12; version += 1) {
    const filename = migrationEntries.find((entry) =>
      entry.startsWith(String(version).padStart(4, "0")),
    );
    assert.ok(filename, `migration ${version} must exist`);
    sqlite.exec(await readFile(join(cloudflareDirectory, "migrations", filename), "utf8"));
  }
  sqlite.exec(`
    INSERT INTO app_attest_keys (
      key_id, public_key_pem, sign_count, app_id, environment,
      receipt_base64, attested_at_utc
    ) VALUES
    (
      'empty-source-key', 'empty-source-pem', 1,
      '5TT564H883.com.quakesignal.app', 'production',
      'empty-source-receipt', '2026-08-01T00:00:00.000Z'
    ),
    (
      'valid-source-key', 'valid-source-pem', 1,
      '5TT564H883.com.quakesignal.app', 'production',
      'valid-source-receipt', '2026-08-01T00:00:00.000Z'
    );
    INSERT INTO app_attest_challenges (
      id, key_id, wire_key_id, operation, method, path, body_sha256,
      challenge, required_proof, environment, created_at_utc, expires_at_utc,
      consumed_at_utc
    ) VALUES (
      '00000000-0000-0000-0000-000000000013', 'empty-source-key',
      'empty-source-wire-key', 'device-registration', 'POST', '/v1/devices',
      'empty-source-body-hash', 'empty-source-challenge', 'assertion',
      'production', '2026-08-01T00:00:00.000Z', '2099-01-01T00:00:00.000Z',
      '2026-08-01T00:01:00.000Z'
    );
    INSERT INTO devices (
      token, environment, sources, min_magnitude, critical_alerts_enabled,
      include_test_alerts, notify_at_night, app_attest_key_id,
      created_at, updated_at
    ) VALUES
      ('empty-source-token', 'production', '[]', 0, 0, 0, 1,
       'empty-source-key', '2026-08-01T00:00:00.000Z',
       '2026-08-01T00:00:00.000Z'),
      ('valid-source-token', 'production', '["jma_eew"]', 0, 0, 0, 1,
       'valid-source-key', '2026-08-01T00:00:00.000Z',
       '2026-08-01T00:00:00.000Z'),
      ('malformed-source-token', 'production', 'not-json', 0, 0, 0, 1,
       NULL, '2026-08-01T00:00:00.000Z', '2026-08-01T00:00:00.000Z');
    INSERT INTO notification_deliveries (
      delivery_id, device_token, delivered_at_utc
    ) VALUES (
      'empty-source-delivery', 'empty-source-token',
      '2026-08-01T00:00:00.000Z'
    );
    INSERT INTO alert_delivery_failures (
      delivery_id, token_hash, event_ref, source_id, notification_reason,
      apns_status, apns_reason, disposition, first_seen_utc, last_seen_utc
    ) VALUES
      (
        'empty-source-delivery', '${"a".repeat(64)}', 'jma_eew:empty-source',
        'jma_eew', 'new', NULL, NULL, 'quarantine',
        '2026-08-01T00:00:00.000Z', '2026-08-01T00:00:00.000Z'
      ),
      (
        'legacy-bad-token-delivery', '${"b".repeat(64)}', 'jma_eew:legacy-bad',
        'jma_eew', 'new', 400, 'BadDeviceToken', 'quarantine',
        '2026-08-05T00:00:00.000Z', '2026-08-06T00:00:00.000Z'
      );
    INSERT INTO alert_delivery_incidents (
      queue_message_id, queue_attempts, status, first_seen_utc, last_seen_utc
    ) VALUES
      ('resolved-incident', 5, 'resolved',
       '2026-08-01T00:00:00.000Z', '2026-08-02T00:00:00.000Z'),
      ('active-incident', 5, 'active',
       '2026-08-01T00:00:00.000Z', '2026-08-02T00:00:00.000Z');
    INSERT INTO alert_delivery_page_failures (
      outbox_id, delivery_id, root_delivery_id, event_ref, source_id,
      event_serial, notification_reason, status, first_seen_utc, last_seen_utc
    ) VALUES
      ('resolved-page', 'resolved-delivery', 'resolved-root', 'jma_eew:resolved',
       'jma_eew', 1, 'new', 'resolved',
       '2026-08-03T00:00:00.000Z', '2026-08-04T00:00:00.000Z'),
      ('active-page', 'active-delivery', 'active-root', 'jma_eew:active',
       'jma_eew', 1, 'new', 'active',
       '2026-08-03T00:00:00.000Z', '2026-08-04T00:00:00.000Z');
  `);
  const migrationStartedAtMs = Date.now();
  sqlite.exec(await readFile(
    join(
      cloudflareDirectory,
      "migrations/0013_alert_lifecycle_and_incident_retention.sql",
    ),
    "utf8",
  ));
  const migrationFinishedAtMs = Date.now();

  const survivingDevices = sqlite.prepare(
    "SELECT token, registration_revision FROM devices ORDER BY token",
  ).all().map((row) => ({ ...row }));
  assert.deepEqual(
    survivingDevices.map(({ token }) => token),
    ["malformed-source-token", "valid-source-token"],
    "the guarded predicate deletes an explicit empty array without throwing on or widening malformed legacy JSON",
  );
  for (const { registration_revision: revision } of survivingDevices) {
    assert.match(revision, /^[0-9a-f]{32}$/);
  }
  assert.notEqual(
    survivingDevices[0].registration_revision,
    survivingDevices[1].registration_revision,
    "legacy registrations receive unique opaque revisions",
  );
  const revisionBeforeLegacyRefresh = survivingDevices[1].registration_revision;
  sqlite.exec(
    `UPDATE devices SET updated_at = updated_at
     WHERE token = 'valid-source-token'`,
  );
  assert.notEqual(
    sqlite.prepare(
      `SELECT registration_revision FROM devices
       WHERE token = 'valid-source-token'`,
    ).get().registration_revision,
    revisionBeforeLegacyRefresh,
    "a rolling pre-0013 UPSERT advances the revision even at the same timestamp",
  );
  const trainingFencedRevision = sqlite.prepare(
    `SELECT registration_revision FROM devices
     WHERE token = 'valid-source-token'`,
  ).get().registration_revision;
  sqlite.prepare(
    `INSERT INTO apns_provider_attempts (
       attempt_id, registration_revision, token_hash, event_ref, outbox_id,
       admitted_at_utc
     ) VALUES (?, ?, ?, ?, ?, ?)`,
  ).run(
    "training:migration-contract",
    trainingFencedRevision,
    "c".repeat(64),
    "jma_eew:training-contract",
    "training:migration-contract",
    "2026-08-22T00:00:00.000Z",
  );
  assert.throws(
    () => sqlite.exec(
      `UPDATE devices SET locale = 'ja'
       WHERE token = 'valid-source-token'`,
    ),
    /training APNs outcome/i,
    "a registration mutation cannot serialize through an unresolved production-training response",
  );
  sqlite.exec(
    `UPDATE apns_provider_attempts
     SET outcome_reconciled_at_utc = '2026-08-22T00:00:01.000Z'
     WHERE attempt_id = 'training:migration-contract';
     UPDATE devices SET locale = 'ja'
     WHERE token = 'valid-source-token';`,
  );
  assert.equal(
    sqlite.prepare(
      "SELECT COUNT(*) AS count FROM notification_deliveries",
    ).get().count,
    0,
    "raw-token delivery deduplication state is removed with the invalid row",
  );
  assert.equal(
    sqlite.prepare("SELECT COUNT(*) AS count FROM app_attest_keys").get().count,
    1,
    "only the invalid row's now-orphaned App Attest verifier is removed",
  );
  assert.equal(
    sqlite.prepare("SELECT COUNT(*) AS count FROM app_attest_challenges").get().count,
    0,
    "consumed challenges for the orphaned verifier are removed",
  );
  assert.equal(
    sqlite.prepare("SELECT COUNT(*) AS count FROM alert_delivery_failures").get().count,
    2,
    "one-way failure hashes cannot be safely joined during migration and retain their ordinary/resolved 14-day or active BadDeviceToken 90-day policy",
  );
  assert.deepEqual(
    sqlite.prepare("PRAGMA table_info(apns_provider_attempts)").all()
      .map(({ name }) => name),
    [
      "attempt_id",
      "registration_revision",
      "token_hash",
      "event_ref",
      "outbox_id",
      "admitted_at_utc",
      "outcome_reconciled_at_utc",
    ],
    "provider admission keeps a durable outcome marker across a DO-clear crash",
  );
  assert.deepEqual(
    sqlite.prepare(
      `SELECT name FROM sqlite_master
       WHERE type = 'trigger' AND name LIKE 'devices_block_training_apns_attempt_%'
       ORDER BY name`,
    ).all().map(({ name }) => name),
    [
      "devices_block_training_apns_attempt_delete",
      "devices_block_training_apns_attempt_update",
    ],
    "training provider admission fences both renewal and deletion until its exact response boundary",
  );
  assert.deepEqual(
    sqlite.prepare("PRAGMA table_info(alert_lifecycle_possible_attempts)").all()
      .map(({ name }) => name),
    [
      "attempt_id",
      "event_ref",
      "token_hash",
      "app_attest_key_id",
      "registration_revision",
      "evidence_at_utc",
    ],
    "possible-contact continuity is attempt-owned and stores no raw APNs token",
  );
  assert.deepEqual(
    sqlite.prepare("PRAGMA table_info(legacy_device_removal_tokens)").all()
      .map(({ name }) => name),
    [
      "token",
      "registration_revision",
      "app_attest_key_id",
      "decision_kind",
      "removed_at_utc",
    ],
    "SQL-only consent withdrawal has one explicit bounded raw-token handoff for Worker hashing",
  );
  assert.deepEqual(
    sqlite.prepare(
      `SELECT token, decision_kind FROM legacy_device_removal_tokens
       ORDER BY token`,
    ).all().map((row) => ({ ...row })),
    [{
      token: "empty-source-token",
      decision_kind: "empty_source_removal",
    }],
    "migration preserves only the removed token until the current Worker can hash and retire its unbound lifecycle lineage",
  );
  assert.deepEqual(
    sqlite.prepare(
      `SELECT delivery_id, status, resolved_at_utc
       FROM alert_delivery_failures
       WHERE apns_reason = 'BadDeviceToken'`,
    ).all().map((row) => ({ ...row })),
    [{
      delivery_id: "legacy-bad-token-delivery",
      status: "active",
      resolved_at_utc: null,
    }],
    "pre-rollout BadDeviceToken evidence remains a safe global block until authenticated recovery",
  );
  assert.ok(
    Date.parse(sqlite.prepare(
      `SELECT last_seen_utc FROM alert_delivery_failures
       WHERE delivery_id = 'legacy-bad-token-delivery'`,
    ).get().last_seen_utc) >= migrationStartedAtMs - 1_000,
    "legacy active BadDeviceToken retention restarts at rollout so it cannot expire before a currently retained device",
  );
  assert.deepEqual(
    sqlite.prepare(
      `SELECT token_hash, app_attest_key_id, decision_kind,
              blocks_lifecycle_replay
       FROM apns_registration_revision_fences
       ORDER BY decision_kind`,
    ).all().map((row) => ({ ...row })),
    [
      {
        token_hash: null,
        app_attest_key_id: "empty-source-key",
        decision_kind: "empty_source_removal",
        blocks_lifecycle_replay: 1,
      },
      {
        token_hash: null,
        app_attest_key_id: "valid-source-key",
        decision_kind: "registration_renewal",
        blocks_lifecycle_replay: 0,
      },
    ],
    "migration fences empty-source removal and retains the rolling refresh's retired revision as nonblocking continuity",
  );
  const rehabilitatedEventRef = "jma_eew:reopted-lifecycle";
  const rehabilitatedTokenHash = await sha256Hex("valid-source-token");
  sqlite.prepare(
    `INSERT INTO alert_lifecycle_recipients (
       event_ref, token_hash, app_attest_key_id, registration_revision,
       evidence_kind, first_evidence_at_utc, last_evidence_at_utc
     ) VALUES (?, ?, ?, ?, 'apns_accepted', ?, ?)`,
  ).run(
    rehabilitatedEventRef,
    rehabilitatedTokenHash,
    "valid-source-key",
    "removed-r1",
    "2026-08-22T00:00:02.000Z",
    "2026-08-22T00:00:02.000Z",
  );
  sqlite.prepare(
    `INSERT INTO apns_registration_revision_fences (
       registration_revision, token_hash, app_attest_key_id, decision_id,
       decision_kind, blocks_lifecycle_replay, processed_at_utc
     ) VALUES (?, ?, ?, ?, 'explicit_removal', 1, ?)`,
  ).run(
    "removed-r1",
    rehabilitatedTokenHash,
    "valid-source-key",
    "removed-r1-decision",
    "2026-08-22T00:00:01.000Z",
  );
  const d1 = {
    prepare(sql) {
      return {
        bind(...bindings) {
          return {
            async all() {
              return {
                results: sqlite.prepare(sql).all(...bindings)
                  .map((row) => ({ ...row })),
              };
            },
          };
        },
      };
    },
  };
  const currentDevice = {
    token: "valid-source-token",
    environment: "production",
    locale: "ja",
    sources: ["jma_eew"],
    minMagnitude: 0,
    criticalAlertsEnabled: false,
    alertSound: "system",
    cityName: null,
    latitude: null,
    longitude: null,
    radiusKm: null,
    includeTestAlerts: false,
    utcOffsetMinutes: null,
    notifyAtNight: true,
    appAttestKeyId: "valid-source-key",
    registrationRevision: trainingFencedRevision,
    appIdentity: "5TT564H883.com.quakesignal.app",
    apnsTopic: "com.quakesignal.app",
    platform: "ios",
    createdAt: "2026-08-01T00:00:00.000Z",
    updatedAt: "2026-08-01T00:00:00.000Z",
  };
  assert.equal(
    (await terminalAlertLifecycleDevices(
      d1,
      rehabilitatedEventRef,
      [currentDevice],
    )).length,
    1,
    "fresh accepted evidence after re-opt-in rehabilitates an older matching removal fence",
  );
  sqlite.exec(
    `UPDATE apns_registration_revision_fences
     SET processed_at_utc = '2026-08-22T00:00:03.000Z'
     WHERE registration_revision = 'removed-r1'`,
  );
  assert.equal(
    (await terminalAlertLifecycleDevices(
      d1,
      rehabilitatedEventRef,
      [currentDevice],
    )).length,
    0,
    "a consent fence causally later than the lifecycle evidence still blocks terminal replay",
  );
  const resolvedIncidentAt = sqlite.prepare(
    `SELECT resolved_at_utc FROM alert_delivery_incidents
     WHERE queue_message_id = 'resolved-incident'`,
  ).get().resolved_at_utc;
  const resolvedPageAt = sqlite.prepare(
    `SELECT resolved_at_utc FROM alert_delivery_page_failures
     WHERE outbox_id = 'resolved-page'`,
  ).get().resolved_at_utc;
  for (const migrationResolvedAt of [resolvedIncidentAt, resolvedPageAt]) {
    assert.match(migrationResolvedAt, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/);
    assert.ok(Date.parse(migrationResolvedAt) >= migrationStartedAtMs - 1_000);
    assert.ok(Date.parse(migrationResolvedAt) <= migrationFinishedAtMs + 1_000);
  }
  assert.deepEqual(
    sqlite.prepare(
      `SELECT queue_message_id, resolved_at_utc
       FROM alert_delivery_incidents ORDER BY queue_message_id`,
    ).all().map((row) => ({ ...row })),
    [
      { queue_message_id: "active-incident", resolved_at_utc: null },
      {
        queue_message_id: "resolved-incident",
        resolved_at_utc: resolvedIncidentAt,
      },
    ],
  );
  assert.deepEqual(
    sqlite.prepare(
      `SELECT outbox_id, resolved_at_utc
       FROM alert_delivery_page_failures ORDER BY outbox_id`,
    ).all().map((row) => ({ ...row })),
    [
      { outbox_id: "active-page", resolved_at_utc: null },
      { outbox_id: "resolved-page", resolved_at_utc: resolvedPageAt },
    ],
  );
  assert.deepEqual(
    sqlite.prepare("PRAGMA table_info(alert_lifecycle_recipients)").all()
      .map(({ name }) => name),
    [
      "event_ref",
      "token_hash",
      "app_attest_key_id",
      "registration_revision",
      "evidence_kind",
      "first_evidence_at_utc",
      "last_evidence_at_utc",
    ],
    "lifecycle storage must contain a hash/key pseudonym and no raw APNs token",
  );
  assert.ok(
    sqlite.prepare("PRAGMA table_info(notification_deliveries)").all()
      .some(({ name }) => name === "lifecycle_reconciled"),
    "old-Worker APNs acceptances must remain explicitly pending lifecycle reconciliation",
  );
  assert.ok(
    sqlite.prepare("PRAGMA table_info(alert_delivery_failures)").all()
      .some(({ name }) => name === "registration_revision"),
    "processed invalidation fences store the opaque sent revision, never the raw token",
  );
  assert.ok(
    sqlite.prepare("PRAGMA table_info(alert_delivery_failures)").all()
      .some(({ name }) => name === "origin_delivery_id"),
    "revision-scoped BadDeviceToken rows retain their logical delivery ID separately",
  );
  assert.deepEqual(
    sqlite.prepare("PRAGMA table_info(apns_registration_revision_fences)").all()
      .map(({ name }) => name),
    [
      "registration_revision",
      "token_hash",
      "app_attest_key_id",
      "decision_id",
      "decision_kind",
      "blocks_lifecycle_replay",
      "processed_at_utc",
    ],
  );
  assert.deepEqual(
    sqlite.prepare(
      `SELECT name FROM sqlite_master
       WHERE type = 'trigger' AND name IN (
         'alert_failures_reject_legacy_bdt_insert',
         'alert_failures_reject_legacy_bdt_update',
         'devices_reject_unbound_legacy_update',
         'devices_registration_revision_legacy_insert',
         'devices_registration_revision_legacy_update',
         'devices_require_revision_fence',
         'devices_empty_sources_legacy_insert',
         'devices_empty_sources_legacy_update'
       ) ORDER BY name`,
    ).all().map(({ name }) => name),
    [
      "alert_failures_reject_legacy_bdt_insert",
      "alert_failures_reject_legacy_bdt_update",
      "devices_empty_sources_legacy_insert",
      "devices_empty_sources_legacy_update",
      "devices_registration_revision_legacy_insert",
      "devices_registration_revision_legacy_update",
      "devices_reject_unbound_legacy_update",
      "devices_require_revision_fence",
    ],
    "rolling old-Worker writes must advance bound revisions, reject unowned invalid-token evidence/unbound renewal/unfenced deletes, and remediate exact empty-source opt-outs",
  );
  assert.deepEqual(
    sqlite.prepare(
      `SELECT name FROM sqlite_master
       WHERE type = 'index' AND name IN (
         'idx_alert_lifecycle_recipients_key',
         'idx_alert_lifecycle_recipients_retention',
         'idx_alert_delivery_failures_registration_revision',
         'idx_alert_delivery_failures_token_hash',
         'idx_alert_delivery_incidents_resolved_retention',
         'idx_alert_delivery_page_failures_resolved_retention',
         'idx_apns_registration_revision_fences_key',
         'idx_apns_registration_revision_fences_retention',
         'idx_apns_registration_revision_fences_token_hash',
         'idx_devices_registration_revision'
       ) ORDER BY name`,
    ).all().map(({ name }) => name),
    [
      "idx_alert_delivery_failures_registration_revision",
      "idx_alert_delivery_failures_token_hash",
      "idx_alert_delivery_incidents_resolved_retention",
      "idx_alert_delivery_page_failures_resolved_retention",
      "idx_alert_lifecycle_recipients_key",
      "idx_alert_lifecycle_recipients_retention",
      "idx_apns_registration_revision_fences_key",
      "idx_apns_registration_revision_fences_retention",
      "idx_apns_registration_revision_fences_token_hash",
      "idx_devices_registration_revision",
    ],
  );
  const legacyDeletedRevision = sqlite.prepare(
    `SELECT registration_revision FROM devices
     WHERE token = 'malformed-source-token'`,
  ).get().registration_revision;
  assert.throws(
    () => sqlite.exec("DELETE FROM devices WHERE token = 'malformed-source-token'"),
    /device revision fence required/,
    "a rolling old-Worker timestamp/key delete fails closed instead of erasing a revision it never observed",
  );
  assert.equal(
    sqlite.prepare(
      `SELECT registration_revision FROM devices
       WHERE token = 'malformed-source-token'`,
    ).get().registration_revision,
    legacyDeletedRevision,
    "the unfenced legacy delete leaves the renewed row intact",
  );
  sqlite.prepare(
    `INSERT INTO apns_registration_revision_fences (
       registration_revision, token_hash, app_attest_key_id,
       decision_id, decision_kind, blocks_lifecycle_replay, processed_at_utc
     ) VALUES (?, NULL, NULL, 'fixture-explicit-delete',
       'explicit_removal', 1, '2026-08-22T00:00:00.000Z')`,
  ).run(legacyDeletedRevision);
  sqlite.exec("DELETE FROM devices WHERE token = 'malformed-source-token'");
  sqlite.exec(`
    INSERT INTO devices (
      token, environment, sources, min_magnitude, critical_alerts_enabled,
      include_test_alerts, notify_at_night, created_at, updated_at
    ) VALUES (
      'malformed-source-token', 'production', '["jma_eew"]', 0, 0, 0, 1,
      '2026-08-22T00:00:00.000Z', '2026-08-22T00:00:00.000Z'
    );
  `);
  assert.notEqual(
    sqlite.prepare(
      `SELECT registration_revision FROM devices
       WHERE token = 'malformed-source-token'`,
    ).get().registration_revision,
    legacyDeletedRevision,
    "same-token re-registration cannot reuse the deletion-fenced revision",
  );
  assert.throws(
    () => sqlite.exec(
      `UPDATE devices SET updated_at = updated_at
       WHERE token = 'malformed-source-token'`,
    ),
    /unbound legacy registration renewal requires current worker/,
    "a rolling old Worker cannot create an unlinkable unbound renewal revision",
  );
  sqlite.exec(
    `UPDATE devices SET sources = '[]', updated_at = updated_at
     WHERE token = 'malformed-source-token'`,
  );
  assert.equal(
    sqlite.prepare(
      `SELECT COUNT(*) AS count FROM devices
       WHERE token = 'malformed-source-token'`,
    ).get().count,
    0,
    "the unbound rolling-worker guard exempts exact empty-source consent withdrawal so deletion still wins",
  );
  assert.throws(
    () => sqlite.exec(`
      INSERT INTO alert_delivery_failures (
        delivery_id, token_hash, event_ref, source_id, notification_reason,
        apns_status, apns_reason, disposition, first_seen_utc, last_seen_utc
      ) VALUES (
        'rolling-old-bdt', '${"c".repeat(64)}', 'jma_eew:rolling-old-bdt',
        'jma_eew', 'new', 400, 'BadDeviceToken', 'quarantine',
        '2025-01-01T00:00:00.000Z', '2025-01-01T00:00:00.000Z'
      );
    `),
    /legacy BadDeviceToken evidence requires current worker/,
    "a rolling old Worker cannot create unowned invalid-token evidence after the one-shot retention pin",
  );
  const pinnedLegacyBadDeviceAt = sqlite.prepare(
    `SELECT last_seen_utc FROM alert_delivery_failures
     WHERE delivery_id = 'legacy-bad-token-delivery'`,
  ).get().last_seen_utc;
  sqlite.exec(
    `UPDATE devices SET updated_at = '2098-01-01T00:00:00.000Z'
     WHERE token = 'valid-source-token'`,
  );
  assert.equal(
    sqlite.prepare(
      `SELECT last_seen_utc FROM alert_delivery_failures
       WHERE delivery_id = 'legacy-bad-token-delivery'`,
    ).get().last_seen_utc,
    pinnedLegacyBadDeviceAt,
    "an unrelated current registration cannot retain an abandoned legacy invalid-token hash indefinitely",
  );
  sqlite.exec(
    `UPDATE devices SET sources = '[]', updated_at = updated_at
     WHERE token = 'valid-source-token'`,
  );
  assert.equal(
    sqlite.prepare(
      "SELECT COUNT(*) AS count FROM devices WHERE token = 'valid-source-token'",
    ).get().count,
    0,
    "a post-migration old-Worker empty-source UPSERT is deleted immediately",
  );
  sqlite.exec(`
    INSERT INTO devices (
      token, environment, sources, min_magnitude, critical_alerts_enabled,
      include_test_alerts, notify_at_night, created_at, updated_at
    ) VALUES (
      'post-migration-empty-token', 'production', '[]', 0, 0, 0, 1,
      '2026-08-22T00:00:00.000Z', '2026-08-22T00:00:00.000Z'
    );
  `);
  assert.equal(
    sqlite.prepare(
      `SELECT COUNT(*) AS count FROM devices
       WHERE token = 'post-migration-empty-token'`,
    ).get().count,
    0,
    "a post-migration old-Worker empty-source INSERT is remediated too",
  );
});

test("uses one validated Queue-name triplet and preserves legacy defaults", async () => {
  const {
    default: worker,
    resolveAlertDeliveryQueueNames,
  } = await workerModule();
  assert.deepEqual(resolveAlertDeliveryQueueNames({}), {
    primary: "quakesignal-alert-delivery",
    deadLetter: "quakesignal-alert-delivery-dlq",
    persistenceFallback: "quakesignal-alert-delivery-dlq-fallback",
  });

  const stagingQueueNames = {
    ALERT_DELIVERY_QUEUE_NAME: "quakesignal-alert-delivery-staging",
    ALERT_DELIVERY_DLQ_NAME: "quakesignal-alert-delivery-staging-dlq",
    ALERT_DELIVERY_DLQ_FALLBACK_NAME:
      "quakesignal-alert-delivery-staging-dlq-fallback",
  };
  assert.deepEqual(resolveAlertDeliveryQueueNames(stagingQueueNames), {
    primary: stagingQueueNames.ALERT_DELIVERY_QUEUE_NAME,
    deadLetter: stagingQueueNames.ALERT_DELIVERY_DLQ_NAME,
    persistenceFallback: stagingQueueNames.ALERT_DELIVERY_DLQ_FALLBACK_NAME,
  });
  assert.throws(
    () => resolveAlertDeliveryQueueNames({
      ALERT_DELIVERY_QUEUE_NAME: stagingQueueNames.ALERT_DELIVERY_QUEUE_NAME,
    }),
    /must either all be unset or all name the configured queues/,
  );
  assert.throws(
    () => resolveAlertDeliveryQueueNames({
      ALERT_DELIVERY_QUEUE_NAME: "",
      ALERT_DELIVERY_DLQ_NAME: stagingQueueNames.ALERT_DELIVERY_DLQ_NAME,
      ALERT_DELIVERY_DLQ_FALLBACK_NAME:
        stagingQueueNames.ALERT_DELIVERY_DLQ_FALLBACK_NAME,
    }),
    /1–63 character Cloudflare Queue name/,
  );
  assert.throws(
    () => resolveAlertDeliveryQueueNames({
      ALERT_DELIVERY_QUEUE_NAME: "queue_name-with-an-underscore",
      ALERT_DELIVERY_DLQ_NAME: stagingQueueNames.ALERT_DELIVERY_DLQ_NAME,
      ALERT_DELIVERY_DLQ_FALLBACK_NAME:
        stagingQueueNames.ALERT_DELIVERY_DLQ_FALLBACK_NAME,
    }),
    /ASCII letters, digits, and internal dashes/,
  );
  assert.throws(
    () => resolveAlertDeliveryQueueNames({
      ALERT_DELIVERY_QUEUE_NAME: "q".repeat(64),
      ALERT_DELIVERY_DLQ_NAME: stagingQueueNames.ALERT_DELIVERY_DLQ_NAME,
      ALERT_DELIVERY_DLQ_FALLBACK_NAME:
        stagingQueueNames.ALERT_DELIVERY_DLQ_FALLBACK_NAME,
    }),
    /1–63 character Cloudflare Queue name/,
  );
  assert.throws(
    () => resolveAlertDeliveryQueueNames({
      ALERT_DELIVERY_QUEUE_NAME: "same-queue",
      ALERT_DELIVERY_DLQ_NAME: "same-queue",
      ALERT_DELIVERY_DLQ_FALLBACK_NAME:
        stagingQueueNames.ALERT_DELIVERY_DLQ_FALLBACK_NAME,
    }),
    /must name different queues/,
  );
  assert.throws(
    () => resolveAlertDeliveryQueueNames({
      ALERT_DELIVERY_QUEUE_NAME: stagingQueueNames.ALERT_DELIVERY_QUEUE_NAME,
      ALERT_DELIVERY_DLQ_NAME: stagingQueueNames.ALERT_DELIVERY_DLQ_NAME,
      ALERT_DELIVERY_DLQ_FALLBACK_NAME:
        stagingQueueNames.ALERT_DELIVERY_DLQ_NAME,
    }),
    /must name different queues/,
  );

  const relayRequests = [];
  let acknowledged = 0;
  await worker.queue(
    {
      queue: stagingQueueNames.ALERT_DELIVERY_QUEUE_NAME,
      messages: [{
        id: "staging-delivery-message",
        attempts: 1,
        body: message(1),
        ack() {
          acknowledged += 1;
        },
        retry() {
          throw new Error("a valid configured primary Queue must not retry");
        },
      }],
    },
    {
      ...stagingQueueNames,
      RELAY: {
        idFromName() {
          return "global";
        },
        get() {
          return {
            async fetch(request) {
              relayRequests.push(new URL(request.url).pathname);
              return new Response(null, { status: 204 });
            },
          };
        },
      },
    },
  );
  assert.equal(acknowledged, 1);
  assert.deepEqual(relayRequests, ["/deliver", "/outbox/ack"]);
});

test("terminalizes pre-build-8 non-JMA Queue work without reaching APNs", async () => {
  const { QuakeRelay, default: worker } = await workerModule();
  const blocked = {
    ...message(9),
    event: {
      ...message(9).event,
      id: "cenc_eew:example",
      sourceId: "cenc_eew",
    },
  };

  const batches = [];
  const relay = new QuakeRelay(
    {
      storage: {
        async list() {
          return new Map();
        },
      },
      waitUntil() {},
    },
    {
      DB: {
        prepare(sql) {
          return {
            bind(...bindings) {
              return { sql, bindings };
            },
          };
        },
        async batch(statements) {
          batches.push(statements);
          return statements.map((_, index) => ({
            meta: { changes: index === 0 ? 1 : 0 },
          }));
        },
      },
    },
  );
  const rejected = await relay.fetch(
    new Request("https://relay.internal/outbox/source-policy/reject", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ outboxId: blocked.outboxId }),
    }),
  );
  assert.equal(rejected.status, 200);
  assert.equal(batches.length, 1);
  assert.match(batches[0][0].sql, /terminal_reason = COALESCE\(terminal_reason, 'superseded'\)/);
  assert.match(
    batches[0][0].sql,
    /substr\(event_ref, 1, instr\(event_ref, ':'\) - 1\) IN/,
    "the authoritative rollover predicate extracts an exact source ID",
  );
  for (const source of ["sc_eew", "cenc_eew", "fj_eew", "cq_eew", "cenc_eqlist"]) {
    assert.match(batches[0][0].sql, new RegExp(`'${source}'`));
  }
  assert.doesNotMatch(batches[0][0].sql, /'jma_(?:eew|eqlist)'/);

  const relayPaths = [];
  let acknowledged = 0;
  let retried = 0;
  await worker.queue(
    {
      queue: "quakesignal-alert-delivery",
      messages: [{
        id: "legacy-cenc-queue-copy",
        attempts: 1,
        body: blocked,
        ack() { acknowledged += 1; },
        retry() { retried += 1; },
      }],
    },
    {
      RELAY: {
        idFromName() { return "global"; },
        get() {
          return {
            async fetch(request) {
              relayPaths.push(new URL(request.url).pathname);
              return Response.json({ ok: true });
            },
          };
        },
      },
    },
  );
  assert.deepEqual(relayPaths, ["/outbox/source-policy/reject"]);
  assert.equal(acknowledged, 1);
  assert.equal(retried, 0);
});

test("D1-unavailable DLQ persistence is acknowledged only after token-free Durable Object fallback", async () => {
  const {
    default: worker,
    deliveryReadinessStatus,
  } = await workerModule();
  const queueNames = {
    ALERT_DELIVERY_QUEUE_NAME: "quakesignal-alert-delivery-staging",
    ALERT_DELIVERY_DLQ_NAME: "quakesignal-alert-delivery-staging-dlq",
    ALERT_DELIVERY_DLQ_FALLBACK_NAME:
      "quakesignal-alert-delivery-staging-dlq-fallback",
  };
  const fallbackBodies = [];
  const relayPaths = [];
  let acknowledged = 0;
  let retried = 0;
  const failingD1 = {
    prepare() {
      return { bind() { return {}; } };
    },
    async batch() {
      throw new Error("D1 unavailable");
    },
  };
  await worker.queue(
    {
      queue: queueNames.ALERT_DELIVERY_DLQ_NAME,
      messages: [{
        id: "dlq-message-1",
        attempts: 7,
        body: {
          ...message(7),
          event: { ...message(7).event, raw: { never: "persist" } },
        },
        ack() {
          acknowledged += 1;
        },
        retry() {
          retried += 1;
        },
      }],
    },
    {
      ...queueNames,
      DB: failingD1,
      RELAY: {
        idFromName() {
          return "global";
        },
        get() {
          return {
            async fetch(request) {
              const pathname = new URL(request.url).pathname;
              relayPaths.push(pathname);
              if (pathname === "/dlq/finalize") {
                return Response.json({ error: "D1 unavailable" }, { status: 503 });
              }
              assert.equal(pathname, "/dlq/persistence-fallback");
              fallbackBodies.push(await request.json());
              return new Response(null, { status: 204 });
            },
          };
        },
      },
    },
  );
  assert.equal(acknowledged, 1, "a durable fallback permits DLQ acknowledgement");
  assert.equal(retried, 0);
  assert.deepEqual(relayPaths, ["/dlq/finalize", "/dlq/persistence-fallback"]);
  assert.deepEqual(fallbackBodies, [{
    queueMessageId: "dlq-message-1",
    queueAttempts: 7,
    deliveryId: "v1:jma_eew:example:7:new",
    rootDeliveryId: "v1:jma_eew:example:7:new",
    eventId: "example",
    sourceId: "jma_eew",
    eventSerial: 7,
    notificationReason: "new",
    outboxId: "outbox-7",
  }]);
  assert.equal("event" in fallbackBodies[0], false);
  assert.equal("raw" in fallbackBodies[0], false);

  const baselineReadiness = {
    apnsConfigured: true,
    activeDlqIncidents: 0,
    pendingDlqPersistenceFallbacks: false,
    pendingApnsAcceptanceBatches: 0,
    activePageFailures: 0,
    activeQuarantinedFailures: 0,
    activeRetryFailures: 0,
    pendingOutboxRows: 0,
    staleOutboxRows: 0,
  };
  assert.equal(deliveryReadinessStatus(baselineReadiness), "ready");
  assert.equal(
    deliveryReadinessStatus({
      ...baselineReadiness,
      pendingDlqPersistenceFallbacks: true,
    }),
    "degraded",
    "a real Durable Object fallback marker must degrade readiness",
  );
  assert.equal(
    deliveryReadinessStatus({
      ...baselineReadiness,
      pendingDlqPersistenceFallbacks: null,
    }),
    "degraded",
    "an unreadable fallback marker store must fail readiness closed",
  );
  assert.equal(
    deliveryReadinessStatus({
      ...baselineReadiness,
      pendingApnsAcceptanceBatches: 1,
    }),
    "degraded",
    "a durable post-2xx batch waiting for D1 must degrade readiness",
  );
  assert.equal(
    deliveryReadinessStatus({
      ...baselineReadiness,
      pendingApnsAcceptanceBatches: null,
    }),
    "degraded",
    "an unreadable acceptance journal must fail readiness closed",
  );
});

test("DLQ message remains retriable if both D1 and its Durable Object fallback fail", async () => {
  const { default: worker } = await workerModule();
  const queueNames = {
    ALERT_DELIVERY_QUEUE_NAME: "quakesignal-alert-delivery-staging",
    ALERT_DELIVERY_DLQ_NAME: "quakesignal-alert-delivery-staging-dlq",
    ALERT_DELIVERY_DLQ_FALLBACK_NAME:
      "quakesignal-alert-delivery-staging-dlq-fallback",
  };
  let acknowledged = 0;
  const retryDelays = [];
  await worker.queue(
    {
      queue: queueNames.ALERT_DELIVERY_DLQ_NAME,
      messages: [{
        id: "dlq-message-unavailable",
        attempts: 3,
        body: message(3),
        ack() {
          acknowledged += 1;
        },
        retry(options) {
          retryDelays.push(options.delaySeconds);
        },
      }],
    },
    {
      ...queueNames,
      DB: {
        prepare() {
          return { bind() { return {}; } };
        },
        async batch() {
          throw new Error("D1 unavailable");
        },
      },
      RELAY: {
        idFromName() {
          return "global";
        },
        get() {
          return {
            async fetch() {
              throw new Error("Durable Object unavailable");
            },
          };
        },
      },
    },
  );
  assert.equal(acknowledged, 0, "the message must not disappear before terminal Queue fallback");
  assert.deepEqual(retryDelays, [240]);
});

test("Durable Object fallback persists and replays only sanitized DLQ evidence", async () => {
  const { QuakeRelay } = await workerModule();
  const records = new Map();
  let alarmAt = null;
  const storage = {
    async getAlarm() {
      return alarmAt;
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
  };
  const d1Batches = [];
  const relay = new QuakeRelay(
    { storage },
    {
      DB: {
        prepare(sql) {
          return {
            bind(...bindings) {
              return { sql, bindings };
            },
          };
        },
        async batch(statements) {
          d1Batches.push(statements);
        },
      },
    },
  );
  const evidence = {
    queueMessageId: "dlq-recovery-1",
    queueAttempts: 8,
    deliveryId: "v1:jma_eew:example:8:new",
    rootDeliveryId: "v1:jma_eew:example:8:new",
    eventId: "example",
    sourceId: "jma_eew",
    eventSerial: 8,
    notificationReason: "new",
    outboxId: "outbox-8",
  };
  const response = await relay.fetch(
    new Request("https://relay.internal/dlq/persistence-fallback", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(evidence),
    }),
  );
  assert.equal(response.status, 200);
  assert.ok(alarmAt !== null, "the fallback schedules bounded recovery");
  assert.equal(records.size, 1);
  const stored = [...records.values()][0];
  assert.deepEqual(stored.evidence, evidence);
  assert.equal("event" in stored.evidence, false);
  assert.equal("raw" in stored.evidence, false);

  // Private TypeScript methods remain callable in this black-box bundled test;
  // this verifies the real recovery transaction rather than a duplicate model.
  await relay.reconcileDlqPersistenceFallbacks();
  assert.equal(records.size, 0, "marker clears only after the D1 batch resolves");
  assert.equal(d1Batches.length, 1);
  assert.equal(d1Batches[0].length, 3, "incident, terminal outbox, and page-failure resolution commit together");
});

test("malformed APNs acceptance journal state is preserved and fails closed", async () => {
  const { QuakeRelay } = await workerModule();
  const key = `apns-acceptance:v1:${"a".repeat(64)}`;
  const records = new Map([[key, { version: 1, malformed: true }]]);
  let alarmAt = null;
  const relay = new QuakeRelay(
    {
      storage: {
        async list({ prefix, limit }) {
          return new Map(
            [...records.entries()]
              .filter(([candidate]) => candidate.startsWith(prefix))
              .slice(0, limit),
          );
        },
        async getAlarm() {
          return alarmAt;
        },
        async setAlarm(value) {
          alarmAt = value;
        },
        async delete(candidate) {
          records.delete(candidate);
        },
      },
    },
    { DB: {} },
  );
  const originalConsoleError = console.error;
  console.error = () => {};
  try {
    await assert.rejects(
      relay.reconcileApnsAcceptanceJournal(),
      /journal record is invalid/,
    );
  } finally {
    console.error = originalConsoleError;
  }
  assert.equal(records.has(key), true,
    "malformed known-acceptance state must remain for operator repair");
  assert.ok(alarmAt !== null, "malformed state retains a bounded retry signal");
  records.clear();
  records.set(key, {
    version: 1,
    writeId: "integrity-mismatch-write",
    deliveryId: "integrity-mismatch-delivery",
    eventRef: "jma_eew:integrity-mismatch",
    sourceId: "jma_eew",
    reason: "new",
    createdAtUtc: new Date().toISOString(),
    deliveries: [{
      token: "integrity-mismatch-token",
      tokenHash: "b".repeat(64),
      snapshotRegistrationRevision: "integrity-mismatch-revision",
      snapshotAppAttestKeyId: null,
      firstAcceptedAtUtc: "2026-08-12T00:00:00.000Z",
      lastAcceptedAtUtc: "2026-08-12T00:00:00.000Z",
    }],
  });
  console.error = () => {};
  try {
    await assert.rejects(
      relay.reconcileApnsAcceptanceJournal(),
      /integrity check failed/,
    );
  } finally {
    console.error = originalConsoleError;
  }
  assert.equal(records.has(key), true,
    "a mismatched raw-token hash or stable storage key must never replay or disappear");
});

test("the global APNs lane durably admits work before delivery and terminal decisions", async () => {
  const { QuakeRelay } = await workerModule();
  const records = new Map(
    Array.from({ length: 128 }, (_, index) => [
      `apns-acceptance:v1:${String(index).padStart(64, "0")}`,
      { reserved: true },
    ]),
  );
  const relay = new QuakeRelay(
    {
      storage: {
        async list({ prefix, limit }) {
          return new Map(
            [...records.entries()]
              .filter(([key]) => key.startsWith(prefix))
              .slice(0, limit),
          );
        },
      },
    },
    { DB: {} },
  );
  await assert.rejects(
    relay.ensureApnsAcceptanceJournalCapacity(),
    /capacity is exhausted/,
  );

  const order = [];
  let releaseFirst;
  const firstBlocked = new Promise((resolve) => {
    releaseFirst = resolve;
  });
  const first = relay.serializeApnsDelivery(async () => {
    order.push("first-start");
    await firstBlocked;
    order.push("first-end");
  });
  const second = relay.serializeApnsDelivery(async () => {
    order.push("second-start");
  });
  await Promise.resolve();
  assert.deepEqual(order, ["first-start"]);
  releaseFirst();
  await Promise.all([first, second]);
  assert.deepEqual(order, ["first-start", "first-end", "second-start"]);

  const source = await readFile(
    join(cloudflareDirectory, "src/index.ts"),
    "utf8",
  );
  assert.match(
    source,
    /const preparedIntent = prepareApnsBatch[\s\S]*?await prepareApnsBatch\(deliveries\)[\s\S]*?sendPushRequest/,
    "dispatch must await its durable pre-send intent before the first APNs request",
  );
  assert.match(
    source,
    /persistApnsDeliveryIntent\(message, deliveries\)[\s\S]*?reconcileObservedApnsDeliveryIntentBatch/,
    "the production lane must retain the exact prepared intent through durable outcome handling",
  );
  assert.match(
    source,
    /APNS_ACCEPTANCE_JOURNAL_MAX_RECORD_BYTES = 64 \* 1_024[\s\S]*?isBoundedApnsJournalRecord\(record\)/,
    "intent admission must bound each record's encoded size as well as count",
  );
  assert.match(
    source,
    /recoverApnsDeliveryIntent[\s\S]*?currentDevicesForApnsIntent[\s\S]*?sendPushRequest/,
    "startup and alarm reconciliation must redispatch admitted work from current consent",
  );
  assert.match(
    source,
    /\/dlq\/finalize[\s\S]*?serializeApnsDelivery[\s\S]*?reconcileApnsAcceptanceJournal[\s\S]*?persistDlqIncidentAndFinalizeOutbox/,
    "DLQ terminalization must reconcile acceptances inside the same lane",
  );
  assert.match(
    source,
    /\/outbox\/source-policy\/reject[\s\S]*?serializeApnsDelivery[\s\S]*?reconcileApnsAcceptanceJournal[\s\S]*?supersedeOutboxForSourcePolicy/,
    "source-policy supersession must share the acceptance lane",
  );
  assert.match(
    source,
    /\/outbox\/ack[\s\S]*?serializeApnsDelivery[\s\S]*?reconcileApnsAcceptanceJournal[\s\S]*?finalizeOutbox/,
    "Queue acknowledgement must share the acceptance lane",
  );
  assert.match(
    source,
    /async alarm\(\)[\s\S]*?serializeApnsDelivery[\s\S]*?reconcileApnsAcceptanceJournal[\s\S]*?reconcileDlqPersistenceFallbacks/,
    "alarm fallback finalization must recheck acceptances inside the shared lane",
  );
  assert.match(
    source,
    /private async ensureStarted[\s\S]*?await this\.ensureUpstreams\(\)[\s\S]*?scheduleRoutineRelayAlarm/,
    "startup must leave bounded D1 recovery to the alarm-owned maintenance lane",
  );
  assert.match(
    source,
    /originDeliveryIndex: number[\s\S]*?value\.deliveries\[recipient\.originDeliveryIndex\]/,
    "each observed subset carries an immutable original-recipient identity instead of re-deriving one by token/key first-match",
  );
  assert.match(
    source,
    /const intentStillPending = await completeApnsBatch[\s\S]*?if \(intentStillPending\)[\s\S]*?retryRequired = true/,
    "a strict final-admission subset keeps its Queue page retrying until every durable origin is resolved",
  );
  assert.match(
    source,
    /fence\.processed_at_utc >= lifecycle\.last_evidence_at_utc/,
    "a historical removal fence cannot suppress later APNs-accepted evidence after a fresh opt-in",
  );
  assert.match(
    source,
    /attempt_id LIKE 'training:%'[\s\S]*?admitted_at_utc <= \?/,
    "alarm/startup maintenance releases a crashed short-lived training admission after its safety window",
  );
});

test("a strict final-admission subset keeps the Queue page pending", async () => {
  const { dispatchPushPage } = await workerModule();
  const rows = [1, 2].map((cursor) => ({
    cursor,
    token: String(cursor).repeat(64),
    environment: "production",
    locale: null,
    sources: '["jma_eew"]',
    min_magnitude: 0,
    critical_alerts_enabled: 0,
    alert_sound: "system",
    city_name: null,
    latitude: 35,
    longitude: 135,
    radius_km: 100,
    include_test_alerts: 1,
    utc_offset_minutes: null,
    notify_at_night: 1,
    app_attest_key_id: `subset-key-${cursor}`,
    app_identity: "5TT564H883.com.quakesignal.app",
    apns_topic: "com.quakesignal.app",
    app_platform: "ios",
    registration_revision: `subset-revision-${cursor}`,
    created_at: "2026-08-22T00:00:00.000Z",
    updated_at: "2026-08-22T00:00:00.000Z",
  }));
  const database = {
    prepare(sql) {
      return {
        bind() {
          return {
            async all() {
              if (sql.includes("SELECT rowid AS cursor, * FROM devices")) {
                // Deliberately model a rolling two-recipient prepared record;
                // production's current page size is one, while recovery still
                // accepts bounded records written by the immediately prior code.
                return { results: rows };
              }
              if (
                sql.includes("FROM notification_deliveries") ||
                sql.includes("FROM alert_delivery_failures")
              ) return { results: [] };
              throw new Error(`unexpected strict-subset query: ${sql}`);
            },
          };
        },
      };
    },
  };
  const event = {
    id: "jma_eew:strict-subset",
    sourceId: "jma_eew",
    eventId: "strict-subset",
    serial: 1,
    kind: "eew",
    originTimeUtc: "2026-08-22T00:00:00.000Z",
    reportTimeUtc: "2026-08-22T00:00:00.000Z",
    hypocenter: "Test Region",
    latitude: 35,
    longitude: 135,
    magnitude: 5.5,
    depth: 10,
    maxIntensity: "5-",
    isWarn: true,
    isFinal: false,
    isCancel: false,
    isTraining: false,
    tsunami: null,
    raw: null,
  };
  const originalFetch = globalThis.fetch;
  let contacts = 0;
  let observedOrigins = [];
  globalThis.fetch = async () => {
    contacts += 1;
    return new Response(null, { status: 200 });
  };
  try {
    const page = await dispatchPushPage(
      {
        APP_ATTEST_ENFORCEMENT: "required",
        DB: database,
        APNS_PRIVATE_KEY: "configured",
        APNS_KEY_ID: "ABCDEFGHIJ",
        APNS_TEAM_ID: "ABCDEFGHIJ",
        APNS_BUNDLE_ID: "com.quakesignal.app",
      },
      event,
      "new",
      "cached.provider.jwt",
      "strict-subset-delivery",
      undefined,
      undefined,
      undefined,
      async () => ({ storageKey: "strict-subset", writeId: "write" }),
      async (_intent, _observedAtUtc, deliveries) => {
        observedOrigins = deliveries.map(({ originDeliveryIndex }) =>
          originDeliveryIndex
        );
      },
      async (_intent, deliveries) => [{
        delivery: deliveries[0],
        originDeliveryIndex: 0,
        snapshotRegistrationRevision:
          deliveries[0].device.registrationRevision,
      }],
      async () => true,
    );
    assert.equal(contacts, 1, "only the transaction-time admitted subset contacts APNs");
    assert.deepEqual(observedOrigins, [0], "the provider result retains its exact original recipient identity");
    assert.equal(
      page.retryRequired,
      true,
      "an uncontacted durable origin prevents the Queue page from returning an ackable success",
    );
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("observed intent integrity binds each contacted alias to its original index", async () => {
  const { QuakeRelay } = await workerModule();
  const records = new Map();
  let alarmAt = null;
  const storage = {
    async list({ prefix, limit }) {
      return new Map([...records].filter(([key]) => key.startsWith(prefix)).slice(0, limit));
    },
    async get(key) { return records.get(key); },
    async put(key, value) { records.set(key, structuredClone(value)); },
    async delete(key) { records.delete(key); },
    async getAlarm() { return alarmAt; },
    async setAlarm(value) { alarmAt = Number(value); },
    async transaction(operation) { return operation(this); },
  };
  const db = {
    prepare(sql) {
      return {
        bind() {
          return {
            async run() { return { meta: { changes: 0 } }; },
            async first() { return null; },
          };
        },
      };
    },
  };
  const relay = new QuakeRelay({ storage }, { DB: db });
  const event = {
    id: "jma_eew:origin-index",
    sourceId: "jma_eew",
    eventId: "origin-index",
    serial: 1,
    kind: "eew",
    originTimeUtc: "2026-08-22T00:00:00.000Z",
    reportTimeUtc: "2026-08-22T00:00:00.000Z",
    hypocenter: "Test Region",
    latitude: 35,
    longitude: 135,
    magnitude: 5.5,
    depth: 10,
    maxIntensity: "5-",
    isWarn: true,
    isFinal: false,
    isCancel: false,
    isTraining: false,
    tsunami: null,
  };
  const device = (suffix) => ({
    token: suffix.repeat(64),
    environment: "production",
    locale: null,
    sources: ["jma_eew"],
    minMagnitude: 0,
    criticalAlertsEnabled: false,
    alertSound: "system",
    cityName: null,
    latitude: null,
    longitude: null,
    radiusKm: null,
    includeTestAlerts: true,
    utcOffsetMinutes: null,
    notifyAtNight: true,
    appAttestKeyId: `origin-key-${suffix}`,
    registrationRevision: `origin-revision-${suffix}`,
    appIdentity: "5TT564H883.com.quakesignal.app",
    apnsTopic: "com.quakesignal.app",
    platform: "ios",
    createdAt: "2026-08-22T00:00:00.000Z",
    updatedAt: "2026-08-22T00:00:00.000Z",
  });
  const deliveries = await Promise.all(["a", "b"].map(async (suffix) => ({
    device: device(suffix),
    tokenHash: await sha256Hex(suffix.repeat(64)),
  })));
  const handle = await relay.persistApnsDeliveryIntent(
    {
      version: 1,
      outboxId: "origin-index-outbox",
      deliveryId: "origin-index-delivery",
      rootDeliveryId: "origin-index-delivery",
      event,
      reason: "new",
      expiresAtUtc: "2099-01-01T00:00:00.000Z",
      expiryPolicy: "eew_10m",
    },
    deliveries,
  );
  const record = records.get(handle.storageKey);
  const observedAtUtc = "2026-08-22T00:00:01.000Z";
  records.set(handle.storageKey, {
    ...record,
    providerAttempts: 1,
    lastProviderAttemptAtUtc: observedAtUtc,
    nextProviderAttemptAtUtc: observedAtUtc,
    lifecycleEvidencePreparedAtUtc: observedAtUtc,
    unobservedAttemptReconciled: false,
    observedBatch: {
      observedAtUtc,
      deliveries: [{
        delivery: deliveries[0],
        originDeliveryIndex: 0,
        // Valid-shaped but deliberately points at the other original. A
        // token/key first-match implementation could accept this corruption.
        snapshotRegistrationRevision:
          deliveries[1].device.registrationRevision,
      }],
      results: [{ ok: true, apnsId: null, acceptedAtUtc: observedAtUtc }],
    },
  });
  const originalError = console.error;
  console.error = () => {};
  try {
    await assert.rejects(
      relay.reconcileApnsAcceptanceJournal(),
      /integrity check failed/,
    );
  } finally {
    console.error = originalError;
  }
  assert.equal(records.has(handle.storageKey), true,
    "a mismatched origin index/revision pair remains preserved for operator repair");
});

test("an exhausted origin cannot hot-loop ahead of an independently deferred recipient", async () => {
  const { QuakeRelay } = await workerModule();
  const relay = new QuakeRelay({ storage: {} }, { DB: {} });
  const now = Date.parse("2026-08-22T00:00:00.000Z");
  const deferredAt = now + 60 * 60_000;
  const mapped = (revision, originDeliveryIndex) => ({
    delivery: {
      device: { registrationRevision: revision },
      tokenHash: revision.padEnd(64, "0").slice(0, 64),
    },
    originDeliveryIndex,
    snapshotRegistrationRevision: revision,
  });
  const record = {
    writeId: "exhausted-origin-write",
    providerAttempts: 6,
    recipientProviderAttempts: { exhausted: 6, deferred: 1 },
    recipientRetryNotBeforeUtc: {
      deferred: new Date(deferredAt).toISOString(),
    },
    nextProviderAttemptAtUtc: new Date(now).toISOString(),
    observedBatch: null,
    lifecycleEvidencePreparedAtUtc: null,
    lastProviderAttemptAtUtc: new Date(now).toISOString(),
    unobservedAttemptReconciled: true,
    message: { expiresAtUtc: "2099-01-01T00:00:00.000Z" },
  };
  relay.reconcileObservedApnsDeliveryIntentBatch = async () => record;
  relay.currentDevicesForApnsIntent = async () => ({
    sourceConsenting: [mapped("exhausted", 0), mapped("deferred", 1)],
    redispatch: [mapped("exhausted", 0), mapped("deferred", 1)],
  });
  relay.expireOutboxIfDue = async () => "pending";
  let terminalized = false;
  relay.terminalizeExhaustedApnsDeliveryIntent = async () => {
    terminalized = true;
  };
  let scheduledAt = null;
  relay.scheduleRelayAlarm = async (value) => {
    scheduledAt = value;
  };
  const originalNow = Date.now;
  Date.now = () => now;
  try {
    await relay.recoverApnsDeliveryIntent("intent-key", record);
  } finally {
    Date.now = originalNow;
  }
  assert.equal(terminalized, false,
    "one exhausted recipient cannot terminalize an independently retryable peer");
  assert.equal(scheduledAt, deferredAt,
    "the alarm is scheduled from non-exhausted recipient deadlines only");
});

test("DLQ terminal guard ignores stale terminal outboxes but retains canonical DLQ evidence", async () => {
  const { default: worker } = await workerModule();
  const queueNames = {
    ALERT_DELIVERY_QUEUE_NAME: "quakesignal-alert-delivery-staging",
    ALERT_DELIVERY_DLQ_NAME: "quakesignal-alert-delivery-staging-dlq",
    ALERT_DELIVERY_DLQ_FALLBACK_NAME:
      "quakesignal-alert-delivery-staging-dlq-fallback",
  };
  const stateDirectory = await mkdtemp(join(tmpdir(), "quakesignal-dlq-guard-"));
  try {
    const localArguments = ["--local", "--persist-to", stateDirectory];
    runWrangler(["d1", "migrations", "apply", "quakesignal-production", ...localArguments]);

    for (const {
      serial,
      finalStatus,
      terminalReason,
    } of [
      { serial: 20, finalStatus: "delivered", terminalReason: "delivered" },
      { serial: 21, finalStatus: null, terminalReason: "expired" },
      { serial: 22, finalStatus: null, terminalReason: "superseded" },
    ]) {
      const queueMessageId = `dlq-stale-${terminalReason}`;
      const { statements, logs } = await captureDlqBatch(worker, queueNames, {
        serial,
        queueMessageId,
        incidentChanges: 0,
      });
      assert.equal(statements.length, 3);
      assert.deepEqual(
        logs.map(({ level, entry }) => ({ level, ...JSON.parse(entry) })),
        [{
          level: "info",
          queueMessageId,
          queueAttempt: 5,
          outboxId: `outbox-${serial}`,
          outcome: "alert_delivery_dlq_terminal_outbox_discarded",
        }],
        "a stale terminal Queue copy must not be logged as a newly recorded DLQ incident",
      );
      assert.match(
        statements[0].sql,
        /WHERE id = \?\s+AND acknowledged_at_utc IS NULL\s+AND final_status IS NULL\s+AND terminal_reason IS NULL/i,
        "only an active outbox may be terminalized as a DLQ outcome",
      );
      assert.match(
        statements[1].sql,
        /SELECT (?:\?,\s*){8,}'active',\s*\?,\s*\?\s+WHERE \? IS NULL OR EXISTS \(/i,
        "the incident write must be conditional inside the same D1 batch",
      );
      assert.match(
        statements[1].sql,
        /acknowledged_at_utc IS NOT NULL\s+AND terminal_reason = 'dlq'/i,
        "only the canonical DLQ terminal state may create or update an incident",
      );
      assert.match(
        statements[2].sql,
        /terminal_reason = 'dlq'/i,
        "stale evidence must not resolve a page failure after another terminal outcome",
      );

      runWrangler([
        "d1",
        "execute",
        "quakesignal-production",
        ...localArguments,
        "--command",
        outboxInsertSql(serial, {
          acknowledgedAt: "2026-08-12T00:12:00.000Z",
          finalStatus,
          terminalReason,
        }),
      ]);
      runWrangler([
        "d1",
        "execute",
        "quakesignal-production",
        ...localArguments,
        "--command",
        pageFailureInsertSql(serial),
      ]);
      runD1Batch(statements, localArguments);

      assert.deepEqual(
        d1Results(runWrangler([
          "d1",
          "execute",
          "quakesignal-production",
          ...localArguments,
          "--command",
          `SELECT COUNT(*) AS count FROM alert_delivery_incidents
           WHERE queue_message_id = '${queueMessageId}'`,
          "--json",
        ])),
        [{ count: 0 }],
        `${terminalReason} must not manufacture an active DLQ incident`,
      );
      assert.deepEqual(
        d1Results(runWrangler([
          "d1",
          "execute",
          "quakesignal-production",
          ...localArguments,
          "--command",
          `SELECT o.final_status, o.terminal_reason, p.status AS page_status
           FROM alert_delivery_outbox o
           JOIN alert_delivery_page_failures p ON p.outbox_id = o.id
           WHERE o.id = 'outbox-${serial}'`,
          "--json",
        ])),
        [{
          final_status: finalStatus,
          terminal_reason: terminalReason,
          page_status: "active",
        }],
        "the stale copy cannot alter its existing terminal decision or provider evidence",
      );
    }

    const genuineSerial = 23;
    const genuineMessageId = "dlq-genuine";
    const { statements: genuineStatements, logs: genuineLogs } = await captureDlqBatch(worker, queueNames, {
      serial: genuineSerial,
      queueMessageId: genuineMessageId,
      attempts: 5,
    });
    assert.deepEqual(
      genuineLogs.map(({ level, entry }) => ({ level, ...JSON.parse(entry) })),
      [{
        level: "error",
        queueMessageId: genuineMessageId,
        queueAttempt: 5,
        deliveryId: "v1:jma_eew:example:23:new",
        eventId: "example",
        sourceId: "jma_eew",
        notificationReason: "new",
        outcome: "alert_delivery_dlq_incident_recorded",
      }],
      "a current DLQ message must retain its high-severity incident-recorded signal",
    );
    runWrangler([
      "d1",
      "execute",
      "quakesignal-production",
      ...localArguments,
      "--command",
      outboxInsertSql(genuineSerial),
    ]);
    runWrangler([
      "d1",
      "execute",
      "quakesignal-production",
      ...localArguments,
      "--command",
      pageFailureInsertSql(genuineSerial),
    ]);
    runD1Batch(genuineStatements, localArguments);
    assert.deepEqual(
      d1Results(runWrangler([
        "d1",
        "execute",
        "quakesignal-production",
        ...localArguments,
        "--command",
        `SELECT i.queue_attempts, i.status, o.final_status, o.terminal_reason,
                p.status AS page_status
         FROM alert_delivery_incidents i
         JOIN alert_delivery_outbox o ON o.id = 'outbox-${genuineSerial}'
         JOIN alert_delivery_page_failures p ON p.outbox_id = o.id
         WHERE i.queue_message_id = 'outbox:outbox-${genuineSerial}'`,
        "--json",
      ])),
      [{
        queue_attempts: 5,
        status: "active",
        final_status: "dlq",
        terminal_reason: "dlq",
        page_status: "resolved",
      }],
      "a current DLQ message must still produce durable incident evidence",
    );

    // A duplicate of a real DLQ outcome remains evidence: it may update the
    // observed Queue attempt count, but it cannot be mistaken for the stale
    // delivered/expired/superseded cases above.
    const { statements: duplicateGenuineStatements } =
      await captureDlqBatch(worker, queueNames, {
        serial: genuineSerial,
        queueMessageId: genuineMessageId,
        attempts: 9,
      });
    runD1Batch(
      duplicateGenuineStatements,
      localArguments,
    );
    assert.deepEqual(
      d1Results(runWrangler([
        "d1",
        "execute",
        "quakesignal-production",
        ...localArguments,
        "--command",
        `SELECT queue_attempts, status FROM alert_delivery_incidents
         WHERE queue_message_id = 'outbox:outbox-${genuineSerial}'`,
        "--json",
      ])),
      [{ queue_attempts: 9, status: "active" }],
      "a duplicate genuine DLQ message must preserve and refresh its incident evidence",
    );
  } finally {
    await rm(stateDirectory, { recursive: true, force: true });
  }
});

test("D1 outbox insert atomically rejects superseded serials and lifecycle reasons", async () => {
  const { outboxInsertStatement } = await workerModule();
  const createdAt = "2026-08-12T00:10:00.000Z";
  const staleCapture = capturedStatementDatabase();
  outboxInsertStatement(
    staleCapture.database,
    message(1),
    "stale-dedupe",
    createdAt,
  );
  assert.match(staleCapture.captured.sql, /WHERE NOT EXISTS/i);
  assert.match(staleCapture.captured.sql, /serial > \?/i);
  assert.match(staleCapture.captured.sql, /is_cancel = 1/i);
  assert.match(staleCapture.captured.sql, /is_final = 1/i);

  const freshCapture = capturedStatementDatabase();
  outboxInsertStatement(
    freshCapture.database,
    message(2),
    "fresh-dedupe",
    createdAt,
  );
  const finalCapture = capturedStatementDatabase();
  outboxInsertStatement(
    finalCapture.database,
    message(2, "final"),
    "final-dedupe",
    createdAt,
  );
  const cancelledCapture = capturedStatementDatabase();
  outboxInsertStatement(
    cancelledCapture.database,
    message(2, "cancelled"),
    "cancelled-dedupe",
    createdAt,
  );

  const stateDirectory = await mkdtemp(join(tmpdir(), "quakesignal-d1-test-"));
  try {
    const localArguments = ["--local", "--persist-to", stateDirectory];
    runWrangler(["d1", "migrations", "apply", "quakesignal-production", ...localArguments]);
    runWrangler([
      "d1",
      "execute",
      "quakesignal-production",
      ...localArguments,
      "--command",
      `INSERT INTO events (
        id, source_id, event_id, serial, kind, first_seen_utc, last_updated_utc
      ) VALUES (
        'jma_eew:example', 'jma_eew', 'example', 2, 'eew',
        '${createdAt}', '${createdAt}'
      )`,
    ]);
    runWrangler([
      "d1",
      "execute",
      "quakesignal-production",
      ...localArguments,
      "--command",
      bindSql(staleCapture.captured.sql, staleCapture.captured.bindings),
    ]);
    let rows = d1Results(runWrangler([
      "d1",
      "execute",
      "quakesignal-production",
      ...localArguments,
      "--command",
      "SELECT COUNT(*) AS count FROM alert_delivery_outbox",
      "--json",
    ]));
    assert.equal(rows[0].count, 0, "serial 1 must not enqueue after serial 2");

    runWrangler([
      "d1",
      "execute",
      "quakesignal-production",
      ...localArguments,
      "--command",
      bindSql(freshCapture.captured.sql, freshCapture.captured.bindings),
    ]);
    rows = d1Results(runWrangler([
      "d1",
      "execute",
      "quakesignal-production",
      ...localArguments,
      "--command",
      "SELECT event_serial, expires_at_utc, expiry_policy FROM alert_delivery_outbox",
      "--json",
    ]));
    assert.deepEqual(rows, [{
      event_serial: 2,
      expires_at_utc: "2026-08-12T00:10:00.000Z",
      expiry_policy: "eew_10m",
    }]);

    runWrangler([
      "d1",
      "execute",
      "quakesignal-production",
      ...localArguments,
      "--command",
      "DELETE FROM alert_delivery_outbox; UPDATE events SET is_final = 1",
    ]);
    runWrangler([
      "d1",
      "execute",
      "quakesignal-production",
      ...localArguments,
      "--command",
      bindSql(freshCapture.captured.sql, freshCapture.captured.bindings),
    ]);
    rows = d1Results(runWrangler([
      "d1",
      "execute",
      "quakesignal-production",
      ...localArguments,
      "--command",
      "SELECT COUNT(*) AS count FROM alert_delivery_outbox",
      "--json",
    ]));
    assert.equal(rows[0].count, 0, "same-serial active work must not enqueue after final");

    runWrangler([
      "d1",
      "execute",
      "quakesignal-production",
      ...localArguments,
      "--command",
      bindSql(finalCapture.captured.sql, finalCapture.captured.bindings),
    ]);
    rows = d1Results(runWrangler([
      "d1",
      "execute",
      "quakesignal-production",
      ...localArguments,
      "--command",
      "SELECT notification_reason FROM alert_delivery_outbox",
      "--json",
    ]));
    assert.deepEqual(rows, [{ notification_reason: "final" }]);

    runWrangler([
      "d1",
      "execute",
      "quakesignal-production",
      ...localArguments,
      "--command",
      "DELETE FROM alert_delivery_outbox; UPDATE events SET is_cancel = 1",
    ]);
    runWrangler([
      "d1",
      "execute",
      "quakesignal-production",
      ...localArguments,
      "--command",
      bindSql(finalCapture.captured.sql, finalCapture.captured.bindings),
    ]);
    rows = d1Results(runWrangler([
      "d1",
      "execute",
      "quakesignal-production",
      ...localArguments,
      "--command",
      "SELECT COUNT(*) AS count FROM alert_delivery_outbox",
      "--json",
    ]));
    assert.equal(rows[0].count, 0, "final work must not enqueue after cancellation");

    runWrangler([
      "d1",
      "execute",
      "quakesignal-production",
      ...localArguments,
      "--command",
      bindSql(cancelledCapture.captured.sql, cancelledCapture.captured.bindings),
    ]);
    rows = d1Results(runWrangler([
      "d1",
      "execute",
      "quakesignal-production",
      ...localArguments,
      "--command",
      "SELECT notification_reason FROM alert_delivery_outbox",
      "--json",
    ]));
    assert.deepEqual(rows, [{ notification_reason: "cancelled" }]);
  } finally {
    await rm(stateDirectory, { recursive: true, force: true });
  }
});

test("D1 delivery fence terminalizes lower serials and same-serial active work", async () => {
  const { supersedeOutboxIfNewerRevisionStatement } = await workerModule();
  const createdAt = "2026-08-12T00:10:00.000Z";
  const supersedeCapture = capturedStatementDatabase();
  supersedeOutboxIfNewerRevisionStatement(
    supersedeCapture.database,
    "outbox-pending-serial-1",
    createdAt,
  );
  assert.match(
    supersedeCapture.captured.sql,
    /events\.serial > alert_delivery_outbox\.event_serial/i,
  );
  assert.match(supersedeCapture.captured.sql, /events\.is_final = 1/i);
  assert.match(supersedeCapture.captured.sql, /events\.is_cancel = 1/i);

  const stateDirectory = await mkdtemp(join(tmpdir(), "quakesignal-d1-test-"));
  try {
    const localArguments = ["--local", "--persist-to", stateDirectory];
    runWrangler(["d1", "migrations", "apply", "quakesignal-production", ...localArguments]);
    runWrangler([
      "d1",
      "execute",
      "quakesignal-production",
      ...localArguments,
      "--command",
      `INSERT INTO events (
        id, source_id, event_id, serial, kind, first_seen_utc, last_updated_utc
      ) VALUES (
        'jma_eew:example', 'jma_eew', 'example', 2, 'eew',
        '${createdAt}', '${createdAt}'
      )`,
    ]);
    // This represents a page that was inserted while serial 1 was current and
    // was still in Queues when serial 2 committed.
    runWrangler([
      "d1",
      "execute",
      "quakesignal-production",
      ...localArguments,
      "--command",
      `INSERT INTO alert_delivery_outbox (
        id, dedupe_key, delivery_id, root_delivery_id, event_ref, event_serial,
        notification_reason, event_json, created_at_utc, next_enqueue_at_utc,
        expires_at_utc, expiry_policy
      ) VALUES (
        'outbox-pending-serial-1', 'pending-serial-1',
        'v1:jma_eew:example:1:new', 'v1:jma_eew:example:1:new',
        'jma_eew:example', 1, 'new', '{}', '${createdAt}', '${createdAt}',
        '2026-08-12T00:30:00.000Z', 'eew_30m'
      )`,
    ]);
    runWrangler([
      "d1",
      "execute",
      "quakesignal-production",
      ...localArguments,
      "--command",
      bindSql(supersedeCapture.captured.sql, supersedeCapture.captured.bindings),
    ]);
    let rows = d1Results(runWrangler([
      "d1",
      "execute",
      "quakesignal-production",
      ...localArguments,
      "--command",
      `SELECT event_serial, acknowledged_at_utc IS NOT NULL AS terminalized,
              terminal_reason, final_status
       FROM alert_delivery_outbox`,
      "--json",
    ]));
    assert.deepEqual(rows, [{
      event_serial: 1,
      terminalized: 1,
      terminal_reason: "superseded",
      final_status: null,
    }]);

    const sameSerialFinalCapture = capturedStatementDatabase();
    supersedeOutboxIfNewerRevisionStatement(
      sameSerialFinalCapture.database,
      "outbox-pending-same-serial-active",
      createdAt,
    );
    runWrangler([
      "d1",
      "execute",
      "quakesignal-production",
      ...localArguments,
      "--command",
      `UPDATE events SET is_final = 1;
       INSERT INTO alert_delivery_outbox (
         id, dedupe_key, delivery_id, root_delivery_id, event_ref, event_serial,
         notification_reason, event_json, created_at_utc, next_enqueue_at_utc,
         expires_at_utc, expiry_policy
       ) VALUES (
         'outbox-pending-same-serial-active', 'pending-same-serial-active',
         'v1:jma_eew:example:2:new', 'v1:jma_eew:example:2:new',
         'jma_eew:example', 2, 'new', '{}', '${createdAt}', '${createdAt}',
         '2026-08-12T00:30:00.000Z', 'eew_30m'
       )`,
    ]);
    runWrangler([
      "d1",
      "execute",
      "quakesignal-production",
      ...localArguments,
      "--command",
      bindSql(
        sameSerialFinalCapture.captured.sql,
        sameSerialFinalCapture.captured.bindings,
      ),
    ]);
    rows = d1Results(runWrangler([
      "d1",
      "execute",
      "quakesignal-production",
      ...localArguments,
      "--command",
      `SELECT acknowledged_at_utc IS NOT NULL AS terminalized, terminal_reason
       FROM alert_delivery_outbox
       WHERE id = 'outbox-pending-same-serial-active'`,
      "--json",
    ]));
    assert.deepEqual(rows, [{ terminalized: 1, terminal_reason: "superseded" }]);

    const sameSerialCancelCapture = capturedStatementDatabase();
    supersedeOutboxIfNewerRevisionStatement(
      sameSerialCancelCapture.database,
      "outbox-pending-same-serial-final",
      createdAt,
    );
    runWrangler([
      "d1",
      "execute",
      "quakesignal-production",
      ...localArguments,
      "--command",
      `UPDATE events SET is_cancel = 1;
       INSERT INTO alert_delivery_outbox (
         id, dedupe_key, delivery_id, root_delivery_id, event_ref, event_serial,
         notification_reason, event_json, created_at_utc, next_enqueue_at_utc,
         expires_at_utc, expiry_policy
       ) VALUES (
         'outbox-pending-same-serial-final', 'pending-same-serial-final',
         'v1:jma_eew:example:2:final', 'v1:jma_eew:example:2:final',
         'jma_eew:example', 2, 'final', '{}', '${createdAt}', '${createdAt}',
         '2026-08-12T00:30:00.000Z', 'eew_30m'
       )`,
    ]);
    runWrangler([
      "d1",
      "execute",
      "quakesignal-production",
      ...localArguments,
      "--command",
      bindSql(
        sameSerialCancelCapture.captured.sql,
        sameSerialCancelCapture.captured.bindings,
      ),
    ]);
    rows = d1Results(runWrangler([
      "d1",
      "execute",
      "quakesignal-production",
      ...localArguments,
      "--command",
      `SELECT acknowledged_at_utc IS NOT NULL AS terminalized, terminal_reason
       FROM alert_delivery_outbox
       WHERE id = 'outbox-pending-same-serial-final'`,
      "--json",
    ]));
    assert.deepEqual(rows, [{ terminalized: 1, terminal_reason: "superseded" }]);
  } finally {
    await rm(stateDirectory, { recursive: true, force: true });
  }
});
