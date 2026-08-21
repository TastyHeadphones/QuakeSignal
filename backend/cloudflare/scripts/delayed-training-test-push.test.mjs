import assert from "node:assert/strict";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import test from "node:test";

import { build } from "esbuild";

import { LEGAL_PAGE_CONTRACTS } from "./legal-page-contract.mjs";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const cloudflareDirectory = resolve(scriptDirectory, "..");
const expectedDelaySeconds = 90;
const expectedMaximumLatenessSeconds = 30;
const iosAppRoute = {
  appIdentity: "5TT564H883.com.quakesignal.app",
  apnsTopic: "com.quakesignal.app",
  platform: "ios",
};
const publicRateEnvironment = {
  APP_ATTEST_CHALLENGE_RATE_LIMIT: {
    async limit() { return { success: true }; },
  },
  DEVICE_API_RATE_LIMIT: {
    async limit() { return { success: true }; },
  },
};
let workerModulePromise;

async function workerModule() {
  workerModulePromise ??= (async () => {
    const directory = await mkdtemp(join(tmpdir(), "quakesignal-delayed-training-"));
    const outfile = join(directory, "index.mjs");
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

function canonicalKey(byte = 1) {
  return Buffer.alloc(32, byte).toString("base64");
}

function schedulerState() {
  const records = new Map();
  const alarms = [];
  return {
    records,
    alarms,
    state: {
      storage: {
        async get(key) { return records.get(key); },
        async put(key, value) { records.set(key, structuredClone(value)); },
        async delete(key) { records.delete(key); },
        async setAlarm(time) { alarms.push(Number(time)); },
      },
    },
    job() {
      assert.equal(records.size, 1, "one private appointment should be retained");
      return structuredClone([...records.values()][0]);
    },
  };
}

function productionDeviceRow(keyId) {
  return {
    token: "0123456789abcdef".repeat(4),
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
    alert_sound: "system",
    app_attest_key_id: keyId,
    app_identity: iosAppRoute.appIdentity,
    apns_topic: iosAppRoute.apnsTopic,
    app_platform: iosAppRoute.platform,
    registration_revision: `training-${keyId.slice(0, 16)}`,
    created_at: "2026-08-13T00:00:00.000Z",
    updated_at: "2026-08-13T00:00:00.000Z",
  };
}

function baseEnvironment(firstDevice) {
  const queries = [];
  return {
    queries,
    env: {
      ENABLE_PRODUCTION_TEST_PUSH: "true",
      APNS_PRIVATE_KEY: "not-read-when-relay-returns-a-cached-token",
      APNS_KEY_ID: "ABCDEFGHIJ",
      APNS_TEAM_ID: "ABCDEFGHIJ",
      APNS_BUNDLE_ID: "com.quakesignal.app",
      DB: {
        prepare(sql) {
          return {
            bind(...bindings) {
              queries.push({ sql, bindings });
              return { async first() { return firstDevice(bindings[0]); } };
            },
          };
        },
      },
      RELAY: {
        idFromName() { return "global"; },
        get() {
          return {
            async fetch(request) {
              const url = new URL(request.url);
              if (url.pathname === "/apns/training") {
                const provider = await globalThis.fetch(
                  "https://api.push.apple.com/3/device/training-test",
                );
                let reason = null;
                if (!provider.ok) {
                  reason = (await provider.json().catch(() => null))?.reason ?? null;
                }
                return Response.json({
                  result: provider.ok
                    ? {
                        ok: true,
                        apnsId: null,
                        acceptedAtUtc: new Date().toISOString(),
                      }
                    : {
                        ok: false,
                        apnsId: null,
                        status: provider.status,
                        apnsReason: reason,
                      },
                });
              }
              return Response.json({ authorization: "cached.provider.jwt" });
            },
          };
        },
      },
    },
  };
}

async function schedule(scheduler, keyId) {
  const response = await scheduler.fetch(new Request("https://internal.example/schedule", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ appAttestKeyId: keyId }),
  }));
  assert.equal(response.status, 202);
  return response.json();
}

test("the public route and handler cannot reach delayed scheduling without the original attested request and production flag", async () => {
  const { default: worker, handleDeviceTestPush } = await workerModule();
  const keyId = canonicalKey(9);
  const device = productionDeviceRow(keyId);
  const request = new Request("https://quakesignal-api.example/v1/devices/test", {
    method: "POST",
  });
  const payload = {
    body: { token: device.token, delivery: "delayed-training" },
    bytes: new TextEncoder().encode(JSON.stringify({
      token: device.token,
      delivery: "delayed-training",
    })),
  };

  let publicSchedulerAccesses = 0;
  const unauthenticated = await worker.fetch(
    new Request("https://quakesignal-api.example/v1/devices/test", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(payload.body),
    }),
    {
      APP_ATTEST_CHALLENGE_RATE_LIMIT: {
        async limit() { return { success: true }; },
      },
      DEVICE_API_RATE_LIMIT: { async limit() { return { success: true }; } },
      get DB() { throw new Error("missing App Attest headers must fail before D1"); },
      get TRAINING_PUSH_SCHEDULER() {
        publicSchedulerAccesses += 1;
        throw new Error("a public request must not obtain the private scheduler");
      },
    },
  );
  assert.equal(unauthenticated.status, 401);
  assert.equal(publicSchedulerAccesses, 0);

  let schedulerAccesses = 0;
  const guardedEnvironment = (enabled) => ({
    ENABLE_PRODUCTION_TEST_PUSH: enabled ? "true" : "false",
    APNS_PRIVATE_KEY: "configured-for-guard-test",
    APNS_KEY_ID: "ABCDEFGHIJ",
    APNS_TEAM_ID: "ABCDEFGHIJ",
    APNS_BUNDLE_ID: "com.quakesignal.app",
    DEVICE_MUTATION_RATE_LIMIT: { async limit() { return { success: true }; } },
    DB: {
      prepare() {
        return { bind() { return { async first() { return device; } }; } };
      },
    },
    get TRAINING_PUSH_SCHEDULER() {
      schedulerAccesses += 1;
      throw new Error("the scheduler must remain unreachable at this guard");
    },
  });

  const bypass = await handleDeviceTestPush(
    request,
    guardedEnvironment(true),
    payload,
    { mode: "development_bypass", keyId: null },
  );
  assert.equal(bypass.status, 403, "a development bypass cannot schedule production delivery");

  const disabled = await handleDeviceTestPush(
    request,
    guardedEnvironment(false),
    payload,
    { mode: "attested", keyId, environment: "production", appRoute: iosAppRoute },
  );
  assert.equal(disabled.status, 403, "the checked-in false production flag blocks scheduling");
  assert.equal(schedulerAccesses, 0);

  const immediateEnvironment = guardedEnvironment(false);
  delete immediateEnvironment.APNS_PRIVATE_KEY;
  const immediate = await handleDeviceTestPush(
    request,
    immediateEnvironment,
    {
      body: { token: device.token },
      bytes: new TextEncoder().encode(JSON.stringify({ token: device.token })),
    },
    { mode: "attested", keyId, environment: "production", appRoute: iosAppRoute },
  );
  assert.equal(
    immediate.status,
    503,
    "the ordinary production test passes the delayed flag guard and reaches APNs readiness",
  );
  assert.deepEqual(await immediate.json(), { error: "APNs credentials are not configured" });

  const internalRoute = await worker.fetch(
    new Request("https://quakesignal-api.example/schedule", { method: "POST" }),
    publicRateEnvironment,
  );
  assert.equal(internalRoute.status, 404, "the Worker has no public scheduler route");
});

test("ordinary production test alerts remain available while only delayed training requires the deploy flag", async () => {
  const { productionTestPushAllowed } = await workerModule();

  assert.equal(productionTestPushAllowed("false", "production", "immediate"), true);
  assert.equal(productionTestPushAllowed(undefined, "production", "immediate"), true);
  assert.equal(productionTestPushAllowed("false", "production", "delayed"), false);
  assert.equal(productionTestPushAllowed("true", "production", "delayed"), true);
  assert.equal(productionTestPushAllowed("false", "sandbox", "immediate"), true);
  assert.equal(productionTestPushAllowed("false", "sandbox", "delayed"), true);
});

test("legal pages disclose the platform boundaries and delayed scheduler behavior", async () => {
  const { default: worker } = await workerModule();
  let page = "";
  for (const contract of LEGAL_PAGE_CONTRACTS) {
    const response = await worker.fetch(
      new Request(`https://quakesignal-api.example${contract.path}`),
      publicRateEnvironment,
    );
    assert.equal(response.status, 200);
    const body = await response.text();
    assert.match(body, new RegExp(`<title>${contract.title} · QuakeSignal</title>`));
    assert.ok(body.includes(`QuakeSignal · Effective ${contract.effectiveDate}`));
    for (const requiredFragment of contract.requiredText) {
      assert.ok(body.includes(requiredFragment));
    }
    if (contract.path === "/privacy") page = body;
  }
  assert.match(
    page,
    /private scheduler record containing only that opaque App Attest key ID, a due time, and an at-most-once attempted state/i,
  );
  assert.match(
    page,
    /contains no APNs token, request body, proof, preferences, location, or earthquake payload/i,
  );
  assert.match(
    page,
    /deleted after its one scheduled attempt or cancellation; an alarm more than 30 seconds late is deleted without delivery/i,
  );
});

test("delayed training appointments use one fixed bounded server delay and retain no device token", async () => {
  const {
    TrainingPushScheduler,
    delayedTrainingTestPushDueAt,
  } = await workerModule();
  const now = Date.parse("2026-08-13T00:00:00.000Z");
  assert.equal(delayedTrainingTestPushDueAt(now) - now, expectedDelaySeconds * 1_000);
  assert.throws(() => delayedTrainingTestPushDueAt(Number.MAX_SAFE_INTEGER));

  const keyId = canonicalKey();
  const state = schedulerState();
  const { env } = baseEnvironment(() => null);
  const scheduler = new TrainingPushScheduler(state.state, env);
  const first = await schedule(scheduler, keyId);
  const job = state.job();
  assert.deepEqual(Object.keys(job).sort(), ["appAttestKeyId", "dueAtMs", "state"]);
  assert.equal(job.appAttestKeyId, keyId);
  assert.equal(job.state, "scheduled");
  assert.ok(job.dueAtMs - Date.now() <= 90_000 && job.dueAtMs - Date.now() > 89_000);
  assert.equal(JSON.stringify(job).includes("token"), false);

  const duplicate = await schedule(scheduler, keyId);
  assert.equal(duplicate.scheduledAtUtc, first.scheduledAtUtc);
  assert.equal(state.alarms.length, 1, "a duplicate internal schedule cannot extend the fixed test window");
});

test("a deleted or rebound App Attest registration cannot receive a previously scheduled training push", async () => {
  const { TrainingPushScheduler } = await workerModule();
  const keyId = canonicalKey(2);
  const state = schedulerState();
  const { env, queries } = baseEnvironment(() => null);
  const scheduler = new TrainingPushScheduler(state.state, env);
  await schedule(scheduler, keyId);
  const [storageKey, job] = [...state.records.entries()][0];
  state.records.set(storageKey, { ...job, dueAtMs: Date.now() - 1 });

  const originalFetch = globalThis.fetch;
  let apnsCalls = 0;
  globalThis.fetch = async () => {
    apnsCalls += 1;
    throw new Error("a deleted or rebound registration must not contact APNs");
  };
  try {
    await scheduler.alarm();
  } finally {
    globalThis.fetch = originalFetch;
  }
  assert.equal(apnsCalls, 0);
  assert.equal(queries.length, 1);
  assert.equal(queries[0].bindings[0], keyId, "execution rechecks the exact prior key ownership");
  assert.equal(state.records.size, 0, "a canceled appointment is removed rather than retried");
});

test("the final ownership lookup has no later preparation await before APNs", async () => {
  const { TrainingPushScheduler } = await workerModule();
  const keyId = canonicalKey(5);
  const state = schedulerState();
  let currentDevice = productionDeviceRow(keyId);
  const { env, queries } = baseEnvironment(() => currentDevice);
  const scheduler = new TrainingPushScheduler(state.state, env);
  await schedule(scheduler, keyId);
  const [storageKey, job] = [...state.records.entries()][0];
  state.records.set(storageKey, { ...job, dueAtMs: Date.now() - 1 });

  const originalDigest = crypto.subtle.digest;
  const originalFetch = globalThis.fetch;
  let notifyDigestStarted;
  const digestStarted = new Promise((resolve) => { notifyDigestStarted = resolve; });
  let releaseDigest;
  const digestRelease = new Promise((resolve) => { releaseDigest = resolve; });
  let apnsCalls = 0;
  crypto.subtle.digest = async (...arguments_) => {
    notifyDigestStarted();
    await digestRelease;
    return originalDigest.call(crypto.subtle, ...arguments_);
  };
  globalThis.fetch = async () => {
    apnsCalls += 1;
    return new Response(null, { status: 200 });
  };
  try {
    const alarm = scheduler.alarm();
    await digestStarted;
    // If collapse-ID preparation came after the D1 read, this simulated
    // deletion would be too late and APNs would still be contacted. The
    // scheduler must instead perform its key-ownership read after preparation.
    currentDevice = null;
    releaseDigest();
    await alarm;
  } finally {
    releaseDigest?.();
    crypto.subtle.digest = originalDigest;
    globalThis.fetch = originalFetch;
  }
  assert.equal(queries.length, 1);
  assert.equal(apnsCalls, 0);
});

test("a job that becomes late while authorization is pending is discarded before APNs", async () => {
  const {
    TrainingPushScheduler,
  } = await workerModule();
  const keyId = canonicalKey(6);
  const state = schedulerState();
  const { env } = baseEnvironment(() => productionDeviceRow(keyId));
  let authorizationStarted;
  const authorizationStartedPromise = new Promise((resolve) => {
    authorizationStarted = resolve;
  });
  let releaseAuthorization;
  const authorizationRelease = new Promise((resolve) => {
    releaseAuthorization = resolve;
  });
  env.RELAY = {
    idFromName() { return "global"; },
    get() {
      return {
        async fetch() {
          authorizationStarted();
          await authorizationRelease;
          return Response.json({ authorization: "cached.provider.jwt" });
        },
      };
    },
  };
  const scheduler = new TrainingPushScheduler(state.state, env);
  await schedule(scheduler, keyId);
  const [storageKey, job] = [...state.records.entries()][0];
  const startedAtMs = Date.parse("2026-08-13T00:00:00.000Z");
  state.records.set(storageKey, {
    ...job,
    dueAtMs: startedAtMs - (expectedMaximumLatenessSeconds * 1_000 - 1),
  });

  const originalNow = Date.now;
  const originalFetch = globalThis.fetch;
  let nowMs = startedAtMs;
  let apnsCalls = 0;
  Date.now = () => nowMs;
  globalThis.fetch = async () => {
    apnsCalls += 1;
    return new Response(null, { status: 200 });
  };
  try {
    const alarm = scheduler.alarm();
    await authorizationStartedPromise;
    nowMs += 2;
    releaseAuthorization();
    await alarm;
  } finally {
    releaseAuthorization?.();
    Date.now = originalNow;
    globalThis.fetch = originalFetch;
  }
  assert.equal(apnsCalls, 0);
  assert.equal(state.records.size, 0);
});

test("a scheduler alarm that is late beyond the bounded test window cancels without contacting APNs", async () => {
  const { TrainingPushScheduler } = await workerModule();
  const keyId = canonicalKey(4);
  const state = schedulerState();
  const { env } = baseEnvironment(() => productionDeviceRow(keyId));
  const scheduler = new TrainingPushScheduler(state.state, env);
  await schedule(scheduler, keyId);
  const [storageKey, job] = [...state.records.entries()][0];
  state.records.set(storageKey, { ...job, dueAtMs: Date.now() - 31_000 });

  const originalFetch = globalThis.fetch;
  let apnsCalls = 0;
  globalThis.fetch = async () => { apnsCalls += 1; return new Response(null, { status: 200 }); };
  try {
    await scheduler.alarm();
  } finally {
    globalThis.fetch = originalFetch;
  }
  assert.equal(apnsCalls, 0);
  assert.equal(state.records.size, 0);
});

test("a rejected APNs response is one attempted delayed delivery and never retries or logs token data", async () => {
  const { TrainingPushScheduler } = await workerModule();
  const keyId = canonicalKey(3);
  const state = schedulerState();
  const { env } = baseEnvironment((queriedKeyId) =>
    queriedKeyId === keyId ? productionDeviceRow(keyId) : null,
  );
  const scheduler = new TrainingPushScheduler(state.state, env);
  await schedule(scheduler, keyId);
  const [storageKey, job] = [...state.records.entries()][0];
  state.records.set(storageKey, { ...job, dueAtMs: Date.now() - 1 });

  const originalFetch = globalThis.fetch;
  const originalWarn = console.warn;
  const originalError = console.error;
  let apnsCalls = 0;
  const logs = [];
  globalThis.fetch = async () => {
    apnsCalls += 1;
    return new Response(JSON.stringify({ reason: "BadDeviceToken" }), { status: 400 });
  };
  console.warn = (entry) => logs.push(entry);
  console.error = (entry) => logs.push(entry);
  try {
    await scheduler.alarm();
    await scheduler.alarm();
  } finally {
    globalThis.fetch = originalFetch;
    console.warn = originalWarn;
    console.error = originalError;
  }
  assert.equal(apnsCalls, 1, "a non-2xx APNs result is not treated as a success or retried");
  assert.deepEqual(logs, [], "the delayed test path emits no token or request-data logs");
  assert.equal(state.records.size, 0);
});

test("production relay fences the exact training revision across APNs and bounds crash recovery", async () => {
  const source = await import("node:fs/promises").then(({ readFile }) =>
    readFile(join(cloudflareDirectory, "src/index.ts"), "utf8")
  );
  const migration = await import("node:fs/promises").then(({ readFile }) =>
    readFile(
      join(
        cloudflareDirectory,
        "migrations/0013_alert_lifecycle_and_incident_retention.sql",
      ),
      "utf8",
    )
  );
  assert.match(
    source,
    /trainingAttemptId = `training:\$\{crypto\.randomUUID\(\)\}`[\s\S]*?INSERT INTO apns_provider_attempts[\s\S]*?RETURNING registration_revision[\s\S]*?sendPushRequest/,
    "the exact training registration is admitted in D1 as the final awaited boundary before APNs",
  );
  assert.match(
    source,
    /sendPushRequest\([\s\S]*?outcome_reconciled_at_utc = COALESCE[\s\S]*?applyTrainingTerminalApnsCleanup\(\s*this\.env\.DB,\s*finalDevice/,
    "provider settlement precedes exact-revision cleanup so a later renewal is never quarantined by an old training response",
  );
  assert.match(
    source,
    /DELETE FROM apns_provider_attempts[\s\S]*?admitted_at_utc < \?[\s\S]*?outcome_reconciled_at_utc IS NOT NULL/,
    "resolved training provider-attempt fences share the bounded 14-day admission-retention cleanup",
  );
  assert.match(
    source,
    /TRAINING_APNS_ATTEMPT_RECOVERY_MS = 60_000[\s\S]*?attempt_id LIKE 'training:%'[\s\S]*?outcome_reconciled_at_utc = admitted_at_utc/,
    "a crash after APNs cannot leave the synthetic training mutation fence active indefinitely",
  );
  assert.match(
    migration,
    /devices_block_training_apns_attempt_update[\s\S]*?devices_block_training_apns_attempt_delete/,
    "renewal and deletion both serialize after the training response marker",
  );
});
