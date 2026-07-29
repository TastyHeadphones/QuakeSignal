import assert from "node:assert/strict";

const baseURL = process.argv[2] ?? process.env.QUAKESIGNAL_API_URL;
if (!baseURL) {
  console.error("Usage: node scripts/smoke-test.mjs https://<worker>.workers.dev");
  process.exit(2);
}

const health = await fetch(`${baseURL}/healthz`);
assert.equal(health.status, 200, "health endpoint must return 200");
const healthBody = await health.json();
assert.equal(healthBody.ok, true, "health response must report ok");
assert.equal(
  healthBody.mode,
  "notification-only",
  "health endpoint must identify the notification-only service",
);

const root = await fetch(baseURL);
assert.equal(root.status, 200, "service metadata must return 200");
const rootBody = await root.json();
assert.equal(rootBody.purpose, "APNs alert delivery only");
assert.equal(rootBody.earthquakeData, "Clients fetch directly from Wolfx");
assert.equal(rootBody.recent, undefined, "metadata must not advertise data APIs");
assert.equal(rootBody.live, undefined, "metadata must not advertise a live relay");

const recent = await fetch(`${baseURL}/v1/quakes/recent?limit=5`);
assert.equal(recent.status, 410, "recent data endpoint must stay disabled");

const detail = await fetch(`${baseURL}/v1/quakes/jma_eew%3Atest`);
assert.equal(detail.status, 410, "detail data endpoint must stay disabled");

const live = await fetch(`${baseURL}/v1/live`);
assert.equal(live.status, 410, "live relay endpoint must stay disabled");

const invalidRegistration = await fetch(`${baseURL}/v1/devices`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ token: "short" }),
});
assert.equal(
  invalidRegistration.status,
  400,
  "notification registration endpoint must validate input",
);

console.log(
  JSON.stringify(
    {
      ok: true,
      baseURL,
      upstreams: healthBody.upstreams,
      notificationRegistration: "validated",
      earthquakeDataEndpoints: "disabled",
    },
    null,
    2,
  ),
);

process.exit(0);
