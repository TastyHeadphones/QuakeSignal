import assert from "node:assert/strict";
import test from "node:test";

import { waitForWorkerReadiness } from "./wait-for-worker-readiness.mjs";
import { SMOKE_MAX_RESPONSE_BYTES } from "./smoke-test-policy.mjs";

function metadata({
  status = 503,
  purpose = null,
  earthquakeData = null,
  policyFormat = null,
} = {}) {
  return new Response(JSON.stringify({
    purpose,
    earthquakeData,
    appAttestPolicy: { format: policyFormat },
  }), {
    status,
    headers: { "content-type": "application/json" },
  });
}

test("waits through a rolling deployment until service metadata is available", async () => {
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
        ? metadata()
        : metadata({
          status: 200,
          purpose: "APNs alert delivery only",
          earthquakeData: "Clients fetch directly from Wolfx",
          policyFormat: "quakesignal-app-attest-policy/v2",
        });
    },
  });
  assert.equal(requests, 2);
  assert.deepEqual(sleeps, [5_000]);
  assert.equal(result.policyFormat, "quakesignal-app-attest-policy/v2");
});

test("rejects an incomplete or superficial 200 metadata response", async () => {
  let clock = 0;
  await assert.rejects(
    waitForWorkerReadiness("https://example.workers.dev", {
      timeoutMs: 10,
      intervalMs: 10,
      now: () => clock,
      sleep: async (milliseconds) => { clock += milliseconds; },
      fetchImpl: async () => metadata({
        status: 200,
      }),
    }),
    /did not converge/,
  );
});

test("hard-bounds a metadata fetch that never settles at the overall deadline", async () => {
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
