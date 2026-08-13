import assert from "node:assert/strict";
import test from "node:test";

import { waitForWorkerReadiness } from "./wait-for-worker-readiness.mjs";

function health({
  status = 503,
  ok = false,
  apnsConfigured = true,
  deliveryStatus = "ready",
  upstreamStatus = "degraded",
  transport = "degraded",
  staleSources = ["jma_eew"],
} = {}) {
  return new Response(JSON.stringify({
    ok,
    delivery: { apnsConfigured, status: deliveryStatus },
    upstream: { status: upstreamStatus, transport, staleSources },
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
