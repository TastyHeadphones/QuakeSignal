import assert from "node:assert/strict";
import { generateKeyPairSync, verify } from "node:crypto";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import test from "node:test";

import { build } from "esbuild";

const directory = dirname(fileURLToPath(import.meta.url));
const workerDirectory = resolve(directory, "..");
const observedAt = Date.parse("2026-08-13T09:30:00.000Z");
const repositoryId = 1302409647;
let modulePromise;

async function workerModule() {
  modulePromise ??= (async () => {
    const outputDirectory = await mkdtemp(join(tmpdir(), "quakesignal-terminal-dlq-monitor-"));
    const outfile = join(outputDirectory, "index.mjs");
    await build({
      entryPoints: [resolve(workerDirectory, "src/index.ts")],
      bundle: true,
      format: "esm",
      platform: "node",
      target: "es2022",
      outfile,
    });
    return import(pathToFileURL(outfile).href);
  })();
  return modulePromise;
}

const { privateKey, publicKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
const privateKeyPem = privateKey.export({ type: "pkcs8", format: "pem" });

function baseEnvironment() {
  return {
    CLOUDFLARE_TARGET_ACCOUNT_ID: "69c72916910ed7231abce32069d5257b",
    CLOUDFLARE_MONITOR_API_TOKEN: "queue-read-token-not-logged",
    GITHUB_APP_ID: "1234567",
    GITHUB_APP_INSTALLATION_ID: "7654321",
    GITHUB_APP_PRIVATE_KEY_PKCS8: privateKeyPem,
    MONITOR_TARGET: "production",
  };
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function decodePart(part) {
  const padded = `${part.replaceAll("-", "+").replaceAll("_", "/")}${"=".repeat((4 - part.length % 4) % 4)}`;
  return Buffer.from(padded, "base64");
}

function queueList() {
  return {
    success: true,
    result: [{ queue_id: "terminalqueueid", queue_name: "quakesignal-alert-delivery-dlq-fallback" }],
    result_info: { total_pages: 1 },
  };
}

function installationToken() {
  return {
    token: "github-installation-token-not-logged-1234567890",
    permissions: { issues: "write" },
    repositories: [{ id: repositoryId }],
  };
}

test("empty terminal Queue uses only aggregate metrics after validating the GitHub App scope", async () => {
  const { runTerminalDlqMonitor } = await workerModule();
  const calls = [];
  const fetch = async (input, init = {}) => {
    calls.push({ url: String(input), init });
    if (String(input).endsWith("/app/installations/7654321/access_tokens")) return json(installationToken(), 201);
    if (String(input).includes("/queues?page=1")) return json(queueList());
    if (String(input).endsWith("/queues/terminalqueueid/metrics")) {
      return json({ success: true, result: { backlog_count: 0, oldest_message_timestamp_ms: 0 } });
    }
    throw new Error(`unexpected request ${input}`);
  };

  await runTerminalDlqMonitor(baseEnvironment(), observedAt, fetch);

  assert.equal(calls.length, 3);
  assert.ok(calls.slice(1).every((call) => call.url.startsWith("https://api.cloudflare.com/client/v4/")));
  assert.equal(calls[1].init.headers.Authorization, "Bearer queue-read-token-not-logged");
  assert.equal(calls[0].init.cache, "no-store");
});

test("terminal evidence is escalated through a repository-scoped Issues-only installation token", async () => {
  const { runTerminalDlqMonitor } = await workerModule();
  const calls = [];
  const fetch = async (input, init = {}) => {
    const url = String(input);
    calls.push({ url, init });
    if (url.includes("/queues?page=1")) return json(queueList());
    if (url.endsWith("/queues/terminalqueueid/metrics")) {
      return json({ success: true, result: { backlog_count: 2, oldest_message_timestamp_ms: observedAt - 12_000 } });
    }
    if (url.endsWith("/app/installations/7654321/access_tokens")) return json(installationToken(), 201);
    if (url.endsWith("/labels/quakesignal-terminal-dlq-fallback")) return json({ name: "quakesignal-terminal-dlq-fallback" });
    if (url.includes("/issues?state=open")) return json([]);
    if (url.endsWith("/issues") && init.method === "POST") return json({ number: 123 }, 201);
    throw new Error(`unexpected request ${url}`);
  };

  await runTerminalDlqMonitor(baseEnvironment(), observedAt, fetch);

  const tokenCall = calls.find((call) => call.url.endsWith("/app/installations/7654321/access_tokens"));
  assert.ok(tokenCall);
  assert.deepEqual(JSON.parse(tokenCall.init.body), {
    repository_ids: [repositoryId],
    permissions: { issues: "write" },
  });
  const jwt = tokenCall.init.headers.Authorization.slice("Bearer ".length);
  const [encodedHeader, encodedPayload, encodedSignature] = jwt.split(".");
  assert.deepEqual(JSON.parse(decodePart(encodedHeader)), { alg: "RS256", typ: "JWT" });
  assert.deepEqual(JSON.parse(decodePart(encodedPayload)), {
    iat: Math.floor(observedAt / 1000) - 60,
    exp: Math.floor(observedAt / 1000) - 60 + 540,
    iss: "1234567",
  });
  assert.equal(verify("RSA-SHA256", Buffer.from(`${encodedHeader}.${encodedPayload}`), publicKey, decodePart(encodedSignature)), true);

  const issueCall = calls.find((call) => call.url.endsWith("/issues") && call.init.method === "POST");
  assert.ok(issueCall);
  assert.equal(issueCall.init.headers.Authorization, `Bearer ${installationToken().token}`);
  const issue = JSON.parse(issueCall.init.body);
  assert.equal(issue.title, "[Emergency] Recover terminal DLQ fallback backlog");
  assert.deepEqual(issue.labels, ["quakesignal-terminal-dlq-fallback"]);
  assert.match(issue.body, /Backlog count: `2`/);
  assert.match(issue.body, /Oldest message age \(seconds\): `12`/);
  assert.doesNotMatch(issue.body, /queue-read-token-not-logged|github-installation-token-not-logged|terminalqueueid/);
});

test("a failed Queue probe calls noRetry and creates a separate token-free monitor-failure issue when GitHub remains available", async () => {
  const { scheduledMonitor } = await workerModule();
  const calls = [];
  let noRetryCalls = 0;
  const controller = {
    scheduledTime: observedAt,
    cron: "*/5 * * * *",
    noRetry() { noRetryCalls += 1; },
  };
  const fetch = async (input, init = {}) => {
    const url = String(input);
    calls.push({ url, init });
    if (url.includes("/queues?page=1")) return new Response(null, { status: 403 });
    if (url.endsWith("/app/installations/7654321/access_tokens")) return json(installationToken(), 201);
    if (url.endsWith("/labels/quakesignal-terminal-dlq-fallback")) return json({ name: "quakesignal-terminal-dlq-fallback" });
    if (url.includes("/issues?state=open")) return json([]);
    if (url.endsWith("/issues") && init.method === "POST") return json({ number: 124 }, 201);
    throw new Error(`unexpected request ${url}`);
  };

  await assert.rejects(() => scheduledMonitor(controller, baseEnvironment(), fetch, () => observedAt), /unexpected status/);
  assert.equal(noRetryCalls, 1);
  const failureIssue = calls.find((call) => call.url.endsWith("/issues") && call.init.method === "POST");
  assert.ok(failureIssue);
  const payload = JSON.parse(failureIssue.init.body);
  assert.equal(payload.title, "[Emergency] Terminal DLQ monitor probe failed");
  assert.match(payload.body, /terminal-dlq-monitor-failure/);
  assert.doesNotMatch(payload.body, /queue-read-token-not-logged|github-installation-token-not-logged/);
});

test("the defensive Fetch handler exposes no monitor data", async () => {
  const { default: worker } = await workerModule();
  const response = await worker.fetch(new Request("https://example.invalid/anything"), baseEnvironment());
  assert.equal(response.status, 404);
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.equal(await response.text(), "");
});

test("a delayed Cron uses invocation time, not its stale scheduled timestamp, for the GitHub App JWT", async () => {
  const { scheduledMonitor } = await workerModule();
  const invocationTime = observedAt + 60 * 60 * 1000;
  let jwt;
  const controller = {
    scheduledTime: observedAt,
    cron: "*/5 * * * *",
    noRetry() { throw new Error("delayed normal invocation must not call noRetry"); },
  };
  const fetch = async (input, init = {}) => {
    const url = String(input);
    if (url.endsWith("/app/installations/7654321/access_tokens")) {
      jwt = init.headers.Authorization.slice("Bearer ".length);
      return json(installationToken(), 201);
    }
    if (url.includes("/queues?page=1")) return json(queueList());
    if (url.endsWith("/queues/terminalqueueid/metrics")) {
      return json({ success: true, result: { backlog_count: 0, oldest_message_timestamp_ms: 0 } });
    }
    throw new Error(`unexpected request ${url}`);
  };

  await scheduledMonitor(controller, baseEnvironment(), fetch, () => invocationTime);

  const [, encodedPayload] = jwt.split(".");
  assert.equal(JSON.parse(decodePart(encodedPayload)).iat, Math.floor(invocationTime / 1000) - 60);
});

test("the staging target uses a fixed isolated Queue and a distinct test issue label", async () => {
  const { runTerminalDlqMonitor } = await workerModule();
  const calls = [];
  const fetch = async (input, init = {}) => {
    const url = String(input);
    calls.push({ url, init });
    if (url.endsWith("/app/installations/7654321/access_tokens")) return json(installationToken(), 201);
    if (url.includes("/queues?page=1")) {
      return json({
        success: true,
        result: [{ queue_id: "stagingqueueid", queue_name: "quakesignal-api-staging-alert-delivery-dlq-fallback" }],
        result_info: { total_pages: 1 },
      });
    }
    if (url.endsWith("/queues/stagingqueueid/metrics")) {
      return json({ success: true, result: { backlog_count: 1, oldest_message_timestamp_ms: observedAt - 1000 } });
    }
    if (url.endsWith("/labels/quakesignal-staging-terminal-dlq-fallback")) return json({ name: "quakesignal-staging-terminal-dlq-fallback" });
    if (url.includes("/issues?state=open")) return json([]);
    if (url.endsWith("/issues") && init.method === "POST") return json({ number: 125 }, 201);
    throw new Error(`unexpected request ${url}`);
  };
  await runTerminalDlqMonitor({ ...baseEnvironment(), MONITOR_TARGET: "staging" }, observedAt, fetch);
  const issueCall = calls.find((call) => call.url.endsWith("/issues") && call.init.method === "POST");
  assert.ok(issueCall);
  assert.deepEqual(JSON.parse(issueCall.init.body).labels, ["quakesignal-staging-terminal-dlq-fallback"]);
});

test("an invalid monitor target fails closed without making a provider request", async () => {
  const { scheduledMonitor } = await workerModule();
  let noRetryCalls = 0;
  const controller = {
    scheduledTime: observedAt,
    cron: "*/5 * * * *",
    noRetry() { noRetryCalls += 1; },
  };
  await assert.rejects(
    () => scheduledMonitor(controller, { ...baseEnvironment(), MONITOR_TARGET: "untrusted" }, async () => {
      throw new Error("must not call fetch");
    }, () => observedAt),
    /MONITOR_TARGET must be production or staging/,
  );
  assert.equal(noRetryCalls, 1);
});

test("a GitHub installation token with any additional repository is rejected before Queue access", async () => {
  const { runTerminalDlqMonitor } = await workerModule();
  let queueRequest = false;
  await assert.rejects(
    () => runTerminalDlqMonitor(baseEnvironment(), observedAt, async (input) => {
      const url = String(input);
      if (url.endsWith("/app/installations/7654321/access_tokens")) {
        return json({
          ...installationToken(),
          repositories: [{ id: repositoryId }, { id: 999999999 }],
        }, 201);
      }
      if (url.includes("/queues")) queueRequest = true;
      throw new Error(`unexpected request ${url}`);
    }),
    /not limited to Issues write on QuakeSignal/,
  );
  assert.equal(queueRequest, false);
});
