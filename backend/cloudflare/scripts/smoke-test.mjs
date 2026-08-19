import assert from "node:assert/strict";
import {
  assertAppAttestPolicyHealth,
  assertReadyDeliveryHealth,
  assertReadyWolfxSourceHealth,
  fetchWithoutRedirect,
  parseSmokeTestArguments,
} from "./smoke-test-policy.mjs";

let smokeArguments;
try {
  smokeArguments = parseSmokeTestArguments();
} catch (error) {
  console.error(error instanceof Error ? error.message : "Cloudflare smoke-test arguments are invalid");
  process.exit(2);
}

const {
  baseURL,
  expectedAppAttestPolicyFingerprint,
  requiredAppAttestBundleVersion,
} = smokeArguments;

const health = await fetchWithoutRedirect(fetch, `${baseURL}/healthz`);
assert.equal(health.status, 200, "health endpoint must return 200");
assert.equal(
  health.headers.get("cache-control"),
  "no-store",
  "health endpoint must not be cached",
);
const healthBody = await health.json();
assert.equal(healthBody.ok, true, "health response must report ok");
const appAttestPolicy = assertAppAttestPolicyHealth(healthBody, {
  expectedAppAttestPolicyFingerprint,
  requiredAppAttestBundleVersion,
});
assert.equal(
  healthBody.mode,
  "notification-only",
  "health endpoint must identify the notification-only service",
);
assert.equal(
  healthBody.delivery?.activeDlqIncidents,
  0,
  "production health must have no active alert-delivery DLQ incidents",
);
assert.notEqual(
  healthBody.delivery?.status,
  "degraded",
  "delivery health must not be degraded",
);
assertReadyDeliveryHealth(healthBody.delivery);
assert.equal(
  healthBody.upstream?.status,
  "ready",
  "production health must not pass with a stale or closed required source",
);
assert.deepEqual(
  healthBody.upstream?.staleSources,
  [],
  "production health must not have stale required sources",
);
assert.ok(
  ["websocket", "http-polling", "mixed"].includes(healthBody.upstream?.transport),
  "production health must report an allowed aggregate Wolfx transport",
);
assertReadyWolfxSourceHealth(healthBody.upstream);

const root = await fetchWithoutRedirect(fetch, baseURL);
assert.equal(root.status, 200, "service metadata must return 200");
const rootBody = await root.json();
assert.equal(rootBody.purpose, "APNs alert delivery only");
assert.equal(rootBody.earthquakeData, "Clients fetch directly from Wolfx");
assert.equal(rootBody.recent, undefined, "metadata must not advertise data APIs");
assert.equal(rootBody.live, undefined, "metadata must not advertise a live relay");

for (const [path, title] of [
  ["/privacy", "Privacy Policy"],
  ["/support", "Support"],
  ["/terms", "Terms of Use"],
]) {
  const response = await fetchWithoutRedirect(fetch, `${baseURL}${path}`);
  assert.equal(response.status, 200, `${path} must be an App Store-ready HTTPS page`);
  assert.match(
    response.headers.get("content-type") ?? "",
    /^text\/html\b/i,
    `${path} must return HTML rather than a Worker error document`,
  );
  const body = await response.text();
  assert.match(body, new RegExp(`<title>${title} · QuakeSignal</title>`));
  assert.match(body, /QuakeSignal/);
}

const recent = await fetchWithoutRedirect(fetch, `${baseURL}/v1/quakes/recent?limit=5`);
assert.equal(recent.status, 410, "recent data endpoint must stay disabled");

const detail = await fetchWithoutRedirect(fetch, `${baseURL}/v1/quakes/jma_eew%3Atest`);
assert.equal(detail.status, 410, "detail data endpoint must stay disabled");

const live = await fetchWithoutRedirect(fetch, `${baseURL}/v1/live`);
assert.equal(live.status, 410, "live relay endpoint must stay disabled");

// Use a syntactically valid token for integrity-boundary probes. Otherwise a
// request correctly stops at public input validation (400) before it reaches
// the App Attest authorization guard that this smoke test is meant to prove.
const unattestedDeviceToken = "a".repeat(64);

const invalidRegistration = await fetchWithoutRedirect(fetch, `${baseURL}/v1/devices`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ token: unattestedDeviceToken }),
});
assert.equal(
  invalidRegistration.status,
  401,
  "production device registration must require App Attest before mutation",
);
assert.equal(
  invalidRegistration.headers.get("cache-control"),
  "no-store",
  "device registration responses must not be cached",
);

const oversizedRegistration = await fetchWithoutRedirect(fetch, `${baseURL}/v1/devices`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ token: "a".repeat(9 * 1024) }),
});
assert.equal(
  oversizedRegistration.status,
  413,
  "device registration must reject oversized JSON before buffering it",
);
assert.equal(
  oversizedRegistration.headers.get("cache-control"),
  "no-store",
  "oversized device registration responses must not be cached",
);

const encoder = new TextEncoder();
const chunkedOversizedRegistration = await fetchWithoutRedirect(fetch, `${baseURL}/v1/devices`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  // Deliberately omit Content-Length so the Worker must enforce its streaming
  // body cap rather than relying only on a client-supplied header.
  body: new ReadableStream({
    start(controller) {
      controller.enqueue(encoder.encode('{"token":"'));
      controller.enqueue(encoder.encode("b".repeat(9 * 1024)));
      controller.enqueue(encoder.encode('"}'));
      controller.close();
    },
  }),
  duplex: "half",
});
assert.equal(
  chunkedOversizedRegistration.status,
  413,
  "device registration must enforce its body limit for chunked requests",
);

const invalidDeletion = await fetchWithoutRedirect(fetch, `${baseURL}/v1/devices`, {
  method: "DELETE",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ token: unattestedDeviceToken }),
});
assert.equal(
  invalidDeletion.status,
  401,
  "production device deletion must require App Attest before mutation",
);
assert.equal(
  invalidDeletion.headers.get("cache-control"),
  "no-store",
  "device deletion responses must not be cached",
);

const invalidTestPush = await fetchWithoutRedirect(fetch, `${baseURL}/v1/devices/test`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ token: unattestedDeviceToken }),
});
assert.equal(
  invalidTestPush.status,
  401,
  "production test-push must require App Attest before mutation",
);
assert.equal(
  invalidTestPush.headers.get("cache-control"), "no-store");

const malformedChallenge = await fetchWithoutRedirect(fetch, `${baseURL}/v1/app-attest/challenge`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ version: "1" }),
});
assert.equal(
  malformedChallenge.status,
  400,
  "App Attest challenge endpoint must validate its exact request binding",
);
assert.equal(malformedChallenge.headers.get("cache-control"), "no-store");

const rejectedDevelopmentBypass = await fetchWithoutRedirect(fetch, `${baseURL}/v1/devices`, {
  method: "POST",
  headers: {
    "content-type": "application/json",
    "x-quakesignal-app-attest-bypass": "development-unsupported",
  },
  body: JSON.stringify({ token: "a".repeat(64), environment: "sandbox" }),
});
assert.equal(
  rejectedDevelopmentBypass.status,
  401,
  "production Worker must never honor the development App Attest bypass",
);

console.log(
  JSON.stringify(
    {
      ok: true,
      baseURL,
      upstreams: healthBody.upstreams,
      appAttest: "enforced",
      appAttestPolicy,
      earthquakeDataEndpoints: "disabled",
    },
    null,
    2,
  ),
);

process.exit(0);
