import assert from "node:assert/strict";
import test from "node:test";

import {
  APP_ATTEST_POLICY_FORMAT,
  REQUIRED_WOLFX_SOURCES,
  SMOKE_MAX_RESPONSE_BYTES,
  assertAppAttestPolicyHealth,
  assertReadyDeliveryHealth,
  assertReadyWolfxSourceHealth,
  fetchWithoutRedirect,
  parseSmokeTestArguments,
} from "./smoke-test-policy.mjs";

const fingerprint = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

function readySources(overrides = {}) {
  return Object.fromEntries(REQUIRED_WOLFX_SOURCES.map((source) => [
    source,
    { stale: false, transport: "websocket", ...(overrides[source] ?? {}) },
  ]));
}

function policyHealth(overrides = {}) {
  return {
    appAttestPolicy: {
      format: APP_ATTEST_POLICY_FORMAT,
      fingerprint,
      allowedBundleVersions: ["1", "2"],
      ...overrides,
    },
  };
}

test("parses paired release App Attest policy assertions", () => {
  assert.deepEqual(
    parseSmokeTestArguments([
      "https://quakesignal-api.hopeso.workers.dev",
      "--expected-app-attest-policy-fingerprint",
      fingerprint,
      "--required-app-attest-bundle-version",
      "2",
    ]),
    {
      baseURL: "https://quakesignal-api.hopeso.workers.dev",
      expectedAppAttestPolicyFingerprint: fingerprint,
      requiredAppAttestBundleVersion: "2",
    },
  );
});

test("uses the configured URL when no positional URL is supplied", () => {
  const result = parseSmokeTestArguments([], {
    QUAKESIGNAL_API_URL: "https://staging.example",
  });
  assert.equal(result.baseURL, "https://staging.example");
  assert.equal(result.expectedAppAttestPolicyFingerprint, undefined);
  assert.equal(result.requiredAppAttestBundleVersion, undefined);
});

test("release smoke refuses redirects from the configured Worker origin", async () => {
  const response = await fetchWithoutRedirect(
    async (_input, init) => {
      assert.equal(init.redirect, "error");
      return new Response(null, { status: 200 });
    },
    "https://quakesignal-api.hopeso.workers.dev/healthz",
  );
  assert.equal(response.status, 200);
});

test("release smoke aborts a request that exceeds its deadline", async () => {
  await assert.rejects(
    fetchWithoutRedirect(
      async (_input, init) => new Promise((_resolve, reject) => {
        init.signal.addEventListener("abort", () => reject(init.signal.reason), { once: true });
      }),
      "https://quakesignal-api.hopeso.workers.dev/healthz",
      {},
      { timeoutMs: 5 },
    ),
    /exceeded 5ms/i,
  );
});

test("release smoke rejects an oversized response body", async () => {
  await assert.rejects(
    fetchWithoutRedirect(
      async () => new Response(new Uint8Array(SMOKE_MAX_RESPONSE_BYTES + 1)),
      "https://quakesignal-api.hopeso.workers.dev/healthz",
    ),
    /response exceeded 1048576 bytes/i,
  );
});

test("rejects incomplete or malformed App Attest policy assertions", () => {
  assert.throws(
    () => parseSmokeTestArguments([
      "https://example.test",
      "--expected-app-attest-policy-fingerprint",
      fingerprint,
    ]),
    /must be supplied together/i,
  );
  assert.throws(
    () => parseSmokeTestArguments([
      "https://example.test",
      "--expected-app-attest-policy-fingerprint",
      "sha256:not-a-valid-digest",
      "--required-app-attest-bundle-version",
      "2",
    ]),
    /must be sha256/i,
  );
  assert.throws(
    () => parseSmokeTestArguments([
      "https://example.test",
      "--required-app-attest-bundle-version",
      "bad version",
    ]),
    /valid bundle version/i,
  );
});

test("validates the deployed App Attest fingerprint and required build", () => {
  const policy = assertAppAttestPolicyHealth(policyHealth(), {
    expectedAppAttestPolicyFingerprint: fingerprint,
    requiredAppAttestBundleVersion: "2",
  });
  assert.equal(policy.fingerprint, fingerprint);

  assert.throws(
    () => assertAppAttestPolicyHealth(policyHealth(), {
      expectedAppAttestPolicyFingerprint: "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      requiredAppAttestBundleVersion: "2",
    }),
    /reviewed contract/i,
  );
  assert.throws(
    () => assertAppAttestPolicyHealth(policyHealth({ allowedBundleVersions: ["1"] }), {
      expectedAppAttestPolicyFingerprint: fingerprint,
      requiredAppAttestBundleVersion: "2",
    }),
    /must allow build 2/i,
  );
});

test("rejects a malformed effective health allow-list", () => {
  assert.throws(
    () => assertAppAttestPolicyHealth(policyHealth({ allowedBundleVersions: ["2", "1"] })),
    /sorted, de-duplicated/i,
  );
  assert.throws(
    () => assertAppAttestPolicyHealth(policyHealth({ allowedBundleVersions: [] })),
    /non-empty/i,
  );
});

test("requires fresh approved JMA health while allowing diagnostic sources", () => {
  assert.doesNotThrow(() => assertReadyWolfxSourceHealth({ sources: readySources() }));
  assert.doesNotThrow(() => assertReadyWolfxSourceHealth({
    sources: { ...readySources(), cenc_eew: { stale: false, transport: "http-polling" } },
  }));
  const missing = readySources();
  delete missing.jma_eew;
  for (const sources of [
    {},
    missing,
    readySources({ jma_eew: { stale: true } }),
    readySources({ jma_eew: { transport: "unavailable" } }),
  ]) {
    assert.throws(
      () => assertReadyWolfxSourceHealth({ sources }),
      /two approved JMA sources/i,
    );
  }
});

test("requires explicit Boolean APNs readiness", () => {
  assert.doesNotThrow(() => assertReadyDeliveryHealth({ status: "ready", apnsConfigured: true }));
  for (const delivery of [
    { status: "ready" },
    { status: "ready", apnsConfigured: null },
    { status: "ready", apnsConfigured: "true" },
    { status: "degraded", apnsConfigured: true },
  ]) {
    assert.throws(() => assertReadyDeliveryHealth(delivery), /APNs readiness|APNs signing/i);
  }
});
