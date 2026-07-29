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

const recent = await fetch(`${baseURL}/v1/quakes/recent?limit=5`);
assert.equal(recent.status, 200, "recent endpoint must return 200");
const events = await recent.json();
assert.ok(Array.isArray(events), "recent response must be an array");
assert.ok(events.length > 0, "production backend must contain live Wolfx events");
for (const event of events) {
  assert.equal(typeof event.id, "string");
  assert.equal(typeof event.sourceId, "string");
  assert.equal(typeof event.hypocenter, "string");
}

const detail = await fetch(
  `${baseURL}/v1/quakes/${encodeURIComponent(events[0].id)}`,
);
assert.equal(detail.status, 200, "detail endpoint must return 200");
const detailBody = await detail.json();
assert.equal(detailBody.event.id, events[0].id);
assert.ok(Array.isArray(detailBody.revisions));

const socketURL = new URL("/v1/live", baseURL);
socketURL.protocol = socketURL.protocol === "https:" ? "wss:" : "ws:";
await new Promise((resolve, reject) => {
  const socket = new WebSocket(socketURL);
  const timeout = setTimeout(() => {
    socket.close();
    reject(new Error("live WebSocket did not open within 10 seconds"));
  }, 10_000);
  socket.addEventListener("open", () => {
    clearTimeout(timeout);
    socket.close();
    resolve();
  });
  socket.addEventListener("error", () => {
    clearTimeout(timeout);
    reject(new Error("live WebSocket failed to connect"));
  });
});

console.log(
  JSON.stringify(
    {
      ok: true,
      baseURL,
      eventCount: events.length,
      sampleEvent: events[0].id,
      upstreams: healthBody.upstreams,
      liveWebSocket: "connected"
    },
    null,
    2,
  ),
);

// Node's built-in WebSocket can keep the event loop alive while the close
// handshake completes. This is a one-shot release check, so exit after every
// assertion and the connection test have succeeded.
process.exit(0);
