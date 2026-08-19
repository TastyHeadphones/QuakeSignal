import assert from "node:assert/strict";
import test from "node:test";

import { waitForWorkerReadiness } from "./wait-for-worker-readiness.mjs";
import { REQUIRED_WOLFX_SOURCES, SMOKE_MAX_RESPONSE_BYTES } from "./smoke-test-policy.mjs";

function readySources(overrides = {}) {
  return Object.fromEntries(REQUIRED_WOLFX_SOURCES.map((source) => [
    source,
    { stale: false, transport: "http-polling", ...(overrides[source] ?? {}) },
  ]));
}

function health({
  status = 503,
  ok = false,
  apnsConfigured = true,
  deliveryStatus = "ready",
  upstreamStatus = "degraded",
  transport = "degraded",
  staleSources = ["jma_eew"],
  sources = readySources(),
} = {}) {
  return new Response(JSON.stringify({
    ok,
    delivery: { apnsConfigured, status: deliveryStatus },
    upstream: { status: upstreamStatus, transport, staleSources, sources },
  }), {
    status,
    headers: { "content-type": "application/json" },
  });
}

test("waits through degraded websocket startup and accepts fresh HTTP fallback", async () => {
  let clock = 0;
  let requests = 0;
  const sleeps = [];
  const result = await waitForWorkerReadiness("https://example.workers.dev", {
    timeoutMs: 180_000,
    intervalMs: 5_000,
    now: () => clock,
    sleep: async (milliseconds) => {
      sleeps.push(milliseconds);
      clock += milliseconds;
    },
    fetchImpl: async (_url, init) => {
      requests += 1;
      assert.equal(init.cache, "no-store");
      assert.equal(init.redirect, "error");
      return requests === 1
        ? health()
        : health({
          status: 200,
          ok: true,
          upstreamStatus: "ready",
          transport: "http-polling",
          staleSources: [],
        });
    },
  });
  assert.equal(requests, 2);
  assert.deepEqual(sleeps, [5_000]);
  assert.equal(result.upstreamTransport, "http-polling");
  assert.equal(result.websocketStatus, null);
});

test("fails immediately when APNs configuration is missing", async () => {
  await assert.rejects(
    waitForWorkerReadiness("https://example.workers.dev", {
      fetchImpl: async () => health({ apnsConfigured: false, deliveryStatus: "not_configured" }),
      sleep: async () => assert.fail("missing APNs must not wait for timeout"),
    }),
    /APNs signing material is not configured/,
  );
});

test("does not accept missing or non-Boolean APNs readiness", async () => {
  for (const apnsConfigured of [null, "true", 1]) {
    let clock = 0;
    await assert.rejects(
      waitForWorkerReadiness("https://example.workers.dev", {
        timeoutMs: 10,
        intervalMs: 10,
        now: () => clock,
        sleep: async (milliseconds) => { clock += milliseconds; },
        fetchImpl: async () => health({
          status: 200,
          ok: true,
          apnsConfigured,
          upstreamStatus: "ready",
          transport: "websocket",
          staleSources: [],
        }),
      }),
      /did not converge/,
    );
  }
});

test("requires the exact fresh seven-source Wolfx inventory", async () => {
  const missingSource = readySources();
  delete missingSource.jma_eew;
  const mutations = [
    {},
    missingSource,
    readySources({ jma_eew: { stale: true } }),
    readySources({ jma_eew: { transport: "unavailable" } }),
  ];
  for (const sources of mutations) {
    let clock = 0;
    await assert.rejects(
      waitForWorkerReadiness("https://example.workers.dev", {
        timeoutMs: 10,
        intervalMs: 10,
        now: () => clock,
        sleep: async (milliseconds) => { clock += milliseconds; },
        fetchImpl: async () => health({
          status: 200,
          ok: true,
          upstreamStatus: "ready",
          transport: "mixed",
          staleSources: [],
          sources,
        }),
      }),
      /did not converge/,
    );
  }
});

test("rejects an incomplete or superficial 200 readiness response", async () => {
  let clock = 0;
  await assert.rejects(
    waitForWorkerReadiness("https://example.workers.dev", {
      timeoutMs: 10,
      intervalMs: 10,
      now: () => clock,
      sleep: async (milliseconds) => { clock += milliseconds; },
      fetchImpl: async () => health({
        status: 200,
        ok: true,
        upstreamStatus: "ready",
        transport: "websocket",
        staleSources: ["jma_eew"],
      }),
    }),
    /did not converge/,
  );
});

test("hard-bounds a health fetch that never settles at the overall deadline", async () => {
  let signal;
  let guardTimeout;
  const readiness = waitForWorkerReadiness("https://example.workers.dev", {
    timeoutMs: 20,
    intervalMs: 1,
    fetchImpl: (_url, init) => {
      signal = init.signal;
      return new Promise(() => {});
    },
  });

  try {
    await Promise.race([
      assert.rejects(readiness, /did not converge within 20ms/),
      new Promise((_, reject) => {
        guardTimeout = setTimeout(
          () => reject(new Error("readiness fetch was not bounded by the overall deadline")),
          500,
        );
      }),
    ]);
  } finally {
    clearTimeout(guardTimeout);
  }

  assert.equal(signal?.aborted, true);
});

test("rejects an oversized readiness response before parsing it", async () => {
  let clock = 0;
  const oversized = `${" ".repeat(SMOKE_MAX_RESPONSE_BYTES)}${JSON.stringify({
    ok: true,
    delivery: { status: "not_configured", apnsConfigured: false },
  })}`;
  await assert.rejects(
    waitForWorkerReadiness("https://example.workers.dev", {
      timeoutMs: 10,
      intervalMs: 10,
      now: () => clock,
      sleep: async (milliseconds) => { clock += milliseconds; },
      fetchImpl: async () => new Response(oversized, { status: 200 }),
    }),
    /did not converge/i,
  );
});
