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

test("health exposes a stable non-secret App Attest policy fingerprint without extra relay work", async () => {
  const {
    appAttestPolicyFingerprint,
    canonicalAppAttestPolicy,
    effectiveAppAttestPolicy,
    default: worker,
  } = await workerModule();
  const policyFormat = "quakesignal-app-attest-policy/v1";
  const policyEnvironment = {
    APP_ATTEST_ENFORCEMENT: "required",
    APP_ATTEST_APP_ID: "5TT564H883.com.quakesignal.app",
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
      "",
    ].join("\n"),
  );
  assert.equal(
    await appAttestPolicyFingerprint(effectivePolicy),
    "sha256:uM0AU36V0txDnHa_U1i2aEDxrCtB_FeR566slmklTbg",
  );
  assert.equal(
    await appAttestPolicyFingerprint(effectiveAppAttestPolicy({
      ...policyEnvironment,
      APP_ATTEST_ALLOWED_BUNDLE_VERSIONS: "1,2",
    })),
    "sha256:uM0AU36V0txDnHa_U1i2aEDxrCtB_FeR566slmklTbg",
    "version order and duplicates must not change the effective deployment fingerprint",
  );
  assert.notEqual(
    await appAttestPolicyFingerprint(effectiveAppAttestPolicy({
      ...policyEnvironment,
      APP_ATTEST_REQUIRE_RELEASE_METADATA: "true",
    })),
    "sha256:uM0AU36V0txDnHa_U1i2aEDxrCtB_FeR566slmklTbg",
    "a material App Attest policy change must alter the deployment fingerprint",
  );

  let relayRequests = 0;
  const response = await worker.fetch(
    new Request("https://quakesignal-api.example/healthz"),
    {
      ...policyEnvironment,
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
              assert.equal(
                new URL(typeof request === "string" ? request : request.url).pathname,
                "/status",
              );
              return Response.json({ ok: true, mode: "notification-only" });
            },
          };
        },
      },
    },
  );
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.equal(relayRequests, 1, "health must make only its one status request to the relay");
  const body = await response.json();
  assert.deepEqual(body.appAttestPolicy, {
    format: policyFormat,
    fingerprint: "sha256:uM0AU36V0txDnHa_U1i2aEDxrCtB_FeR566slmklTbg",
    allowedBundleVersions: ["1", "2"],
  });
});

test("health returns a no-store structured 503 when the relay status call fails", async () => {
  const {
    appAttestPolicyFingerprint,
    effectiveAppAttestPolicy,
    default: worker,
  } = await workerModule();
  const policyFormat = "quakesignal-app-attest-policy/v1";
  const policyEnvironment = {
    APP_ATTEST_ENFORCEMENT: "required",
    APP_ATTEST_APP_ID: "5TT564H883.com.quakesignal.app",
    APP_ATTEST_ALLOWED_BUNDLE_VERSIONS: "1,2",
    APP_ATTEST_REQUIRE_RELEASE_METADATA: "false",
  };
  const response = await worker.fetch(
    new Request("https://quakesignal-api.example/healthz"),
    {
      ...policyEnvironment,
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
  assert.equal(response.status, 503);
  assert.equal(response.headers.get("cache-control"), "no-store");
  const body = await response.json();
  assert.equal(body.ok, false);
  assert.equal(body.delivery.status, "degraded");
  assert.equal(body.delivery.apnsConfigured, null);
  assert.equal(body.upstream.status, "degraded");
  assert.equal(body.upstream.staleSources.length, 7);
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
    assert.equal(upgradeRequests, 3, "one Upgrade attempt per watcher is enough");
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
    assert.ok(d1Batches > 0, "first status retains durable startup work");
    assert.equal(
      httpSeedRequests,
      0,
      "the initial snapshot is deferred to its own immediate relay alarm",
    );
    assert.equal(upgradeRequests, 3, "first status opens one Upgrade per route");
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
    relay.connect("all_eew");
    relay.connect("all_eew");
    assert.equal(fetchCalls.length, 1, "an in-flight route must not be duplicated");
    assert.equal(fetchCalls[0].url, "https://ws-api.wolfx.jp/all_eew");
    assert.equal(
      new Headers(fetchCalls[0].init.headers).get("upgrade"),
      "websocket",
    );

    resolveUpgrade({ status: 101, webSocket: socket, body: null });
    await drain();

    assert.equal(socket.accepted, true);
    assert.deepEqual(socket.sent, [
      "query_jmaeew",
      "query_sceew",
      "query_cenceew",
      "query_fjeew",
      "query_cqeew",
    ]);
    assert.equal(
      relay.statuses.get("jma_eew"),
      "connecting",
      "the Upgrade alone is not valid upstream liveness",
    );
    assert.equal(relay.upstreams.get("all_eew"), socket);
    assert.equal(relay.connectingRoutes.has("all_eew"), false);
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
    relay.connect("cenc_eqlist");
    await drain();
    assert.equal(relay.statuses.get("cenc_eqlist"), "error");
    assert.equal(relay.connectingRoutes.has("cenc_eqlist"), false);
    const failed = JSON.parse(warnings.at(-1));
    assert.deepEqual(
      {
        outcome: failed.outcome,
        route: failed.route,
        errorName: failed.errorName,
      },
      {
        outcome: "wolfx_upstream_upgrade_error",
        route: "cenc_eqlist",
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

test("activates paced HTTP fallback only after every websocket route has sustained outage", async () => {
  const {
    QuakeRelay,
    isHttpFallbackSourceStale,
    isHttpRecoverySeedDue,
    mapWithMinimumSpacing,
  } = await workerModule();
  const now = Date.now();
  const values = new Map([
    ["upstream-degraded-since-ms:all_eew", now - 100_000],
    ["upstream-degraded-since-ms:cenc_eqlist", now - 80_000],
    ["upstream-degraded-since-ms:jma_eqlist", now - 100_000],
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

  assert.equal(
    await relay.shouldRunHttpRecoverySeed(),
    false,
    "one route inside its 90-second grace window keeps HTTP fallback off",
  );
  values.set("upstream-degraded-since-ms:cenc_eqlist", now - 100_000);
  assert.equal(
    await relay.shouldRunHttpRecoverySeed(),
    true,
    "all three routes past the grace window activate alternate transport",
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
  const sources = [
    "jma_eew",
    "sc_eew",
    "cenc_eew",
    "fj_eew",
    "cq_eew",
    "cenc_eqlist",
    "jma_eqlist",
  ];
  for (const source of sources) relay.statuses.set(source, "error");

  assert.deepEqual(relay.recoverySweepSources(0), sources);
  assert.deepEqual(
    relay.recoverySweepSources(60_000),
    [...sources.slice(1), sources[0]],
    "each minute starts at the next source without a durable recovery cursor",
  );
  assert.deepEqual(
    relay.recoverySweepSources(7 * 60_000),
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
  assert.deepEqual(maintenance, ["dlq", "legacy", "journal", "outbox", "purge"]);
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
  const validSnapshot = {
    EventID: "http-snapshot-1",
    Serial: 1,
    AnnouncedTime: "2026/08/13 12:00:05",
    OriginTime: "2026/08/13 12:00:00",
    Hypocenter: "Test coast",
    Latitude: 35.1,
    Longitude: 140.2,
    Magunitude: 4.2,
  };
  assert.equal(
    isStructurallyValidHttpSnapshot("jma_eew", validSnapshot, [{
      sourceId: "jma_eew",
      eventId: "http-snapshot-1",
      serial: 1,
      originTimeUtc: "2026-08-13T03:00:00.000Z",
      reportTimeUtc: "2026-08-13T03:00:05.000Z",
      latitude: 35.1,
      longitude: 140.2,
      magnitude: 4.2,
      hypocenter: "Test coast",
    }]),
    true,
  );
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

    const malformedList = {
      md5: "not-a-real-list",
      No51: {
        Title: "report",
        EventID: "too-many",
        time: "2026/08/13 12:00",
        time_full: "2026/08/13 12:00:00",
        location: "Test coast",
        magnitude: "4.2",
        shindo: "2",
        depth: "10km",
        latitude: "35.1",
        longitude: "140.2",
        info: "",
      },
    };
    assert.equal(
      isStructurallyValidHttpSnapshot("jma_eqlist", malformedList, [{
        sourceId: "jma_eqlist",
        eventId: "too-many",
        serial: 1,
        originTimeUtc: "2026-08-13T03:00:00.000Z",
        reportTimeUtc: "2026-08-13T03:00:00.000Z",
        latitude: 35.1,
        longitude: 140.2,
        magnitude: 4.2,
        hypocenter: "Test coast",
      }]),
      false,
      "No51 must be rejected before it can create unbounded D1/outbox work",
    );
  } finally {
    globalThis.fetch = originalFetch;
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
      relay.resetUpstreamReconnectBackoff("all_eew"),
      relay.scheduleUpstreamReconnect(
        "all_eew",
        "wolfx_upstream_websocket_closed",
        { closeCode: 1006, wasClean: false, closeReasonPresent: false },
        "closed",
      ),
    ]);
    assert.equal(values.get("upstream-reconnect-failures:all_eew"), 1);
    assert.ok(
      values.get("upstream-reconnect-not-before-ms:all_eew") > Date.now(),
    );
    assert.ok(values.get("upstream-degraded-since-ms:all_eew") > 0);
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
    relay.connect("cenc_eqlist");
    for (let pass = 0; pass < 20 && pending.size > 0; pass += 1) {
      await Promise.all([...pending]);
    }
    assert.deepEqual(failures, []);
    assert.equal(values.get("upstream-reconnect-failures:cenc_eqlist"), 1);
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

test("valid Wolfx liveness publishes freshness before resetting stable reconnect state", async () => {
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
    socket.emit("message", { data: JSON.stringify({ type: "heartbeat" }) });
    await drain();

    assert.equal(relay.lastSuccessfulUpstreamMs.get(route), now);
    assert.equal(relay.routeIsOpen(route), true);
    assert.equal(values.get(`upstream-reconnect-failures:${route}`), 3);
    assert.equal(
      values.get(`upstream-reconnect-not-before-ms:${route}`),
      now + 20_000,
      "the first valid frame proves freshness but does not erase backoff",
    );

    now += 60_000;
    socket.emit("message", { data: JSON.stringify({ type: "heartbeat" }) });
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

function jmaEqlistSnapshot(count = 50) {
  const snapshot = {
    type: "jma_eqlist",
    md5: "live-jma-eqlist-snapshot-v1",
  };
  for (let index = 1; index <= count; index += 1) {
    snapshot[`No${index}`] = {
      Title: "report",
      EventID: `live-jma-eqlist-${index}`,
      time: "2026/08/14 09:00",
      time_full: "2026/08/14 09:00:00",
      location: `Test coast ${index}`,
      magnitude: "4.2",
      shindo: "2",
      depth: "10km",
      latitude: "35.1",
      longitude: "140.2",
      info: "",
    };
  }
  return snapshot;
}

function distinctJmaEqlistSnapshot(variant, count = 50) {
  const snapshot = jmaEqlistSnapshot(count);
  snapshot.md5 = `live-jma-eqlist-snapshot-${variant}`;
  snapshot.No1 = {
    ...snapshot.No1,
    EventID: `live-jma-eqlist-variant-${variant}`,
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

function isLivePointJournalKey(key) {
  return typeof key === "string" && key.startsWith("pending-ingest:");
}

function createLivePointEventHarness({ failD1Batches = () => false } = {}) {
  const values = new Map();
  const writes = [];
  let alarmAt = null;
  let d1BatchAttempts = 0;
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
              return null;
            },
          };
        },
      };
    },
    async batch(statements) {
      d1BatchAttempts += 1;
      if (failD1Batches()) throw new Error("simulated live point-event D1 failure");
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
  };
}

function createLiveSnapshotHarness({ failD1Batches = () => false } = {}) {
  const values = new Map();
  const writes = [];
  const pending = new Set();
  const backgroundErrors = [];
  let alarmAt = null;
  let d1BatchAttempts = 0;
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

test("a third distinct live list records one overload marker without later snapshot-write churn", async () => {
  const { QuakeRelay } = await workerModule();
  const originalConsoleError = console.error;
  const originalConsoleWarn = console.warn;
  const originalNow = Date.now;
  let now = Date.parse("2026-08-14T00:00:00.000Z");
  const route = "jma_eqlist";
  const overloadKey = `live-snapshot-overload:${route}`;
  const harness = createLiveSnapshotHarness();
  const relay = new QuakeRelay(harness.state, { DB: harness.database });
  const socket = new harness.Socket();
  const liveSnapshotPutCount = () => harness.writes.filter(([operation, key]) =>
    operation === "put" &&
    typeof key === "string" &&
    (key.startsWith("pending-live-snapshot:") ||
      key.startsWith("pending-live-snapshot-latest:") ||
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
      "an overloaded source must wait for its paced cursor instead of starting more D1 slices",
    );
  } finally {
    console.error = originalConsoleError;
    console.warn = originalConsoleWarn;
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

test("coalesces live freshness checkpoints without hiding pending ingest", async () => {
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
      "concurrent heartbeats commit one initial checkpoint",
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
      "the new live heartbeat remains fresh in memory",
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
      "a heartbeat never overwrites the pending-ingest readiness fence",
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
      "a quota failure is retried at the checkpoint cadence, not every heartbeat",
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
