import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { spawnSync } from "node:child_process";
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
  const batches = [];
  const logs = [];
  let acknowledged = 0;
  const originalConsoleError = console.error;
  const originalConsoleInfo = console.info;
  console.error = (entry) => logs.push({ level: "error", entry });
  console.info = (entry) => logs.push({ level: "info", entry });
  try {
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
            // Match the conditional D1 incident statement's real change
            // count. A stale terminal outbox produces no incident row and
            // must therefore exercise the discard log path, rather than a
            // fabricated incident-recorded result from this SQL capture fake.
            return statements.map((_, index) => ({
              meta: { changes: index === 1 ? incidentChanges : 1 },
            }));
          },
        },
        RELAY: {
          idFromName() {
            return "global";
          },
          get() {
            return {
              async fetch() {
                throw new Error("D1 success must not call the fallback relay");
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

function message(serial) {
  return {
    version: 1,
    outboxId: `outbox-${serial}`,
    deliveryId: `v1:jma_eew:example:${serial}:new`,
    rootDeliveryId: `v1:jma_eew:example:${serial}:new`,
    event: {
      id: "jma_eew:example",
      eventId: "example",
      sourceId: "jma_eew",
      serial,
      kind: "eew",
      originTimeUtc: "2026-08-12T00:00:00.000Z",
      reportTimeUtc: "2026-08-12T00:00:00.000Z",
    },
    reason: "new",
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

test("rejects an over-limit health probe before it can activate the global relay", async () => {
  const { default: worker } = await workerModule();
  let relayTouched = false;
  const response = await worker.fetch(
    new Request("https://quakesignal-api.example/healthz"),
    {
      DEVICE_API_RATE_LIMIT: {
        async limit() {
          return { success: false };
        },
      },
      RELAY: {
        idFromName() {
          relayTouched = true;
          throw new Error("an over-limit health request must not obtain a relay id");
        },
        get() {
          relayTouched = true;
          throw new Error("an over-limit health request must not obtain a relay stub");
        },
      },
    },
  );
  assert.equal(response.status, 429);
  assert.equal(relayTouched, false);
});

test("status probes preserve first boot but do not repeatedly run relay recovery", async () => {
  const { QuakeRelay } = await workerModule();
  const originalWebSocket = globalThis.WebSocket;
  const originalFetch = globalThis.fetch;
  let socketCreations = 0;
  let httpSeedRequests = 0;
  let d1Batches = 0;
  let alarmAt = Date.now() + 60_000;
  const values = new Map();
  class TestWebSocket {
    constructor() {
      socketCreations += 1;
      this.readyState = 1;
    }
    addEventListener() {}
    send() {}
  }
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
  globalThis.WebSocket = TestWebSocket;
  globalThis.fetch = async () => {
    httpSeedRequests += 1;
    throw new Error("a scheduled relay must not HTTP-seed for a status probe");
  };
  try {
    const relay = new QuakeRelay(
      { storage },
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
    assert.equal(socketCreations, 3, "one lightweight watcher bootstrap is enough");
  } finally {
    globalThis.WebSocket = originalWebSocket;
    globalThis.fetch = originalFetch;
  }
});

test("a first status probe still performs operational bootstrap when no alarm exists", async () => {
  const { QuakeRelay } = await workerModule();
  const originalWebSocket = globalThis.WebSocket;
  const originalFetch = globalThis.fetch;
  let alarmAt = null;
  let d1Batches = 0;
  let httpSeedRequests = 0;
  const values = new Map();
  class TestWebSocket {
    constructor() {
      this.readyState = 1;
    }
    addEventListener() {}
    send() {}
  }
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
  globalThis.WebSocket = TestWebSocket;
  globalThis.fetch = async () => {
    httpSeedRequests += 1;
    return new Response(null, { status: 503 });
  };
  try {
    const relay = new QuakeRelay(
      { storage },
      {
        DB: database,
        ALERT_DELIVERY_QUEUE: { async send() {} },
      },
    );
    await relay.fetch(new Request("https://relay.internal/status"));
    assert.ok(d1Batches > 0, "first status retains durable startup work");
    assert.ok(httpSeedRequests > 0, "first status retains upstream seed bootstrap");
    assert.notEqual(alarmAt, null, "first status schedules routine recovery");
  } finally {
    globalThis.WebSocket = originalWebSocket;
    globalThis.fetch = originalFetch;
  }
});

test("App Attest challenge quota is route-wide before D1 and ignores caller key rotation", async () => {
  const { default: worker } = await workerModule();
  const challengeKeys = [];
  let d1Touched = false;
  const environment = {
    DEVICE_API_RATE_LIMIT: {
      async limit() {
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
  const requestForKey = (keyId) => new Request(
    "https://quakesignal-api.example/v1/app-attest/challenge",
    {
      method: "POST",
      headers: { "content-type": "application/json" },
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
  const first = await worker.fetch(
    requestForKey(Buffer.alloc(32).toString("base64url")),
    environment,
  );
  const second = await worker.fetch(
    requestForKey(Buffer.alloc(32, 1).toString("base64url")),
    environment,
  );
  assert.equal(first.status, 429);
  assert.equal(second.status, 429);
  assert.equal(d1Touched, false);
  assert.equal(challengeKeys.length, 2);
  assert.equal(
    challengeKeys[0],
    challengeKeys[1],
    "the challenge limiter key must remain stable across untrusted key IDs",
  );
});

test("training pushes obtain APNs authorization from the relay cache and fail closed", async () => {
  const { handleDeviceTestPush } = await workerModule();
  const originalFetch = globalThis.fetch;
  const relayPaths = [];
  const apnsAuthorizations = [];
  const device = {
    token: "sandbox-training-device-token",
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
    created_at: "2026-08-12T00:00:00.000Z",
    updated_at: "2026-08-12T00:00:00.000Z",
  };
  const baseEnvironment = {
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
  const authorization = { mode: "development_bypass", keyId: null };
  globalThis.fetch = async (_url, init) => {
    apnsAuthorizations.push(new Headers(init.headers).get("authorization"));
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

test("calculates bounded reason-specific delivery deadlines", async () => {
  const { calculateAlertDeliveryExpiry } = await workerModule();
  const event = {
    originTimeUtc: "2026-08-12T00:00:00.000Z",
    reportTimeUtc: "2026-08-12T00:05:00.000Z",
  };
  assert.deepEqual(
    calculateAlertDeliveryExpiry(event, "new", "2026-08-12T00:10:00.000Z"),
    { expiresAtUtc: "2026-08-12T00:35:00.000Z", expiryPolicy: "eew_30m" },
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
    { expiresAtUtc: "2026-08-12T00:30:00.000Z", expiryPolicy: "eew_30m" },
  );
  assert.deepEqual(
    calculateAlertDeliveryExpiry(
      { originTimeUtc: "2026-08-12T03:00:00.000Z", reportTimeUtc: null },
      "new",
      "2026-08-12T00:10:00.000Z",
    ),
    { expiresAtUtc: "2026-08-12T00:40:00.000Z", expiryPolicy: "eew_30m" },
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
              assert.equal(
                new URL(request.url).pathname,
                "/dlq/persistence-fallback",
              );
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
        /SELECT \?, \?, \?, \?, \?, \?, \?, \?, 'active', \?, \?\s+WHERE \? IS NULL OR EXISTS \(/i,
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
         WHERE i.queue_message_id = '${genuineMessageId}'`,
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
         WHERE queue_message_id = '${genuineMessageId}'`,
        "--json",
      ])),
      [{ queue_attempts: 9, status: "active" }],
      "a duplicate genuine DLQ message must preserve and refresh its incident evidence",
    );
  } finally {
    await rm(stateDirectory, { recursive: true, force: true });
  }
});

test("D1 outbox insert atomically rejects an old revision after a higher serial commits", async () => {
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
  assert.match(staleCapture.captured.sql, /WHERE id = \? AND serial > \?/i);

  const freshCapture = capturedStatementDatabase();
  outboxInsertStatement(
    freshCapture.database,
    message(2),
    "fresh-dedupe",
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
      expires_at_utc: "2026-08-12T00:30:00.000Z",
      expiry_policy: "eew_30m",
    }]);
  } finally {
    await rm(stateDirectory, { recursive: true, force: true });
  }
});

test("D1 delivery serial fence terminalizes an already-pending lower revision", async () => {
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
    const rows = d1Results(runWrangler([
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
  } finally {
    await rm(stateDirectory, { recursive: true, force: true });
  }
});
