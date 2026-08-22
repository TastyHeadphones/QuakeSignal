import assert from "node:assert/strict";
import {
  assertAppAttestPolicyMetadata,
  fetchWithoutRedirect,
  parseSmokeTestArguments,
} from "./smoke-test-policy.mjs";
import { LEGAL_PAGE_CONTRACTS } from "./legal-page-contract.mjs";

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

const root = await fetchWithoutRedirect(fetch, baseURL);
assert.equal(root.status, 200, "service metadata must return 200");
assert.equal(
  root.headers.get("cache-control"),
  "no-store",
  "service metadata must not be cached",
);
const rootBody = await root.json();
const appAttestPolicy = assertAppAttestPolicyMetadata(rootBody, {
  expectedAppAttestPolicyFingerprint,
  requiredAppAttestBundleVersion,
});
assert.equal(
  rootBody.purpose,
  "APNs alert delivery only",
  "metadata must identify the notification-only service",
);
assert.equal(rootBody.earthquakeData, "Clients fetch directly from Wolfx");
assert.equal(rootBody.recent, undefined, "metadata must not advertise data APIs");
assert.equal(rootBody.live, undefined, "metadata must not advertise a live relay");

for (const { path, title, effectiveDate, requiredText } of LEGAL_PAGE_CONTRACTS) {
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
  assert.ok(
    body.includes(`QuakeSignal · Effective ${effectiveDate}`),
    `${path} must publish its source-controlled effective date`,
  );
  for (const requiredFragment of requiredText) {
    assert.ok(
      body.includes(requiredFragment),
      `${path} must include the required platform/data statement: ${requiredFragment}`,
    );
  }
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
      metadata: "available",
      appAttest: "enforced",
      appAttestPolicy,
      earthquakeDataEndpoints: "disabled",
    },
    null,
    2,
  ),
);

process.exit(0);
