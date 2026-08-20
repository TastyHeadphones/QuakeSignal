import assert from "node:assert/strict";

import { LEGAL_PAGE_CONTRACTS } from "./legal-page-contract.mjs";

// This deliberately has no health/APNs assertion: it is meant for an isolated
// `wrangler dev --local` instance where only the request-validation boundary is
// under test. Start the Worker after applying the local D1 migrations, then run
// `node scripts/local-request-validation-test.mjs http://127.0.0.1:8787`.
const suppliedBaseURL =
  process.argv[2] ?? process.env.QUAKESIGNAL_LOCAL_API_URL;

if (!suppliedBaseURL) {
  console.error(
    "Usage: node scripts/local-request-validation-test.mjs http://127.0.0.1:8787",
  );
  process.exit(2);
}

const baseURL = new URL(suppliedBaseURL);
const devicesURL = new URL("/v1/devices", baseURL);

for (const { path, title, effectiveDate, requiredText } of LEGAL_PAGE_CONTRACTS) {
  const response = await fetch(new URL(path, baseURL));
  assert.equal(response.status, 200, `${path} must be available for App Store links`);
  assert.match(
    response.headers.get("content-type") ?? "",
    /^text\/html\b/i,
    `${path} must return an HTML legal page`,
  );
  const body = await response.text();
  assert.match(body, new RegExp(`<title>${title} · QuakeSignal</title>`));
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

async function assertNoStore(response, expectedStatus, message) {
  assert.equal(response.status, expectedStatus, message);
  assert.equal(
    response.headers.get("cache-control"),
    "no-store",
    `${message} response must not be cached`,
  );
}

const oversized = await fetch(devicesURL, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ token: "a".repeat(9 * 1024) }),
});
await assertNoStore(
  oversized,
  413,
  "content-length-delimited oversized JSON must be rejected before App Attest",
);

const encoder = new TextEncoder();
const chunkedOversized = await fetch(devicesURL, {
  method: "POST",
  headers: { "content-type": "application/json" },
  // Omit Content-Length: this exercises the bounded streaming body reader.
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
await assertNoStore(
  chunkedOversized,
  413,
  "chunked oversized JSON must be rejected before App Attest",
);

const malformed = await fetch(devicesURL, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: "{not-json",
});
await assertNoStore(
  malformed,
  400,
  "malformed JSON must be rejected before App Attest",
);

const unattestedKeyBoundDeletion = await fetch(devicesURL, {
  method: "DELETE",
  headers: { "content-type": "application/json" },
  body: "{}",
});
await assertNoStore(
  unattestedKeyBoundDeletion,
  400,
  "an empty deletion body without a valid App Attest proof must require a token",
);
const unattestedKeyBoundDeletionBody = await unattestedKeyBoundDeletion.json();
assert.equal(
  unattestedKeyBoundDeletionBody.error,
  "token is required",
  "unattested empty deletion must not select a subscription by key",
);

const developmentBypassKeyBoundDeletion = await fetch(devicesURL, {
  method: "DELETE",
  headers: {
    "content-type": "application/json",
    "x-quakesignal-app-attest-bypass": "development-unsupported",
  },
  body: "{}",
});
await assertNoStore(
  developmentBypassKeyBoundDeletion,
  400,
  "an empty deletion body with the development bypass must still require a token",
);
const developmentBypassKeyBoundDeletionBody =
  await developmentBypassKeyBoundDeletion.json();
assert.equal(
  developmentBypassKeyBoundDeletionBody.error,
  "token is required",
  "the development bypass must not select a subscription by key",
);

console.log(
  JSON.stringify(
    {
      ok: true,
      baseURL: baseURL.toString(),
      validation: [
        "content-length-cap",
        "streaming-cap",
        "malformed-json",
        "app-store-legal-pages",
        "unattested-key-bound-deletion",
        "development-bypass-key-bound-deletion",
      ],
    },
    null,
    2,
  ),
);
