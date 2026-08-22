import { fileURLToPath } from "node:url";
import { resolve } from "node:path";
import {
  SMOKE_MAX_RESPONSE_BYTES,
  fetchWithoutRedirect,
} from "./smoke-test-policy.mjs";

const DEFAULT_TIMEOUT_MS = 180_000;
const DEFAULT_INTERVAL_MS = 5_000;

function metadataUrl(baseUrl) {
  const url = new URL(baseUrl);
  if (url.protocol !== "https:" || url.pathname !== "/" || url.search || url.hash) {
    throw new Error("Worker origin must be a bare HTTPS URL");
  }
  return new URL("/", url).toString();
}

function readinessSummary(response, body) {
  return {
    status: response.status,
    purpose: body?.purpose ?? null,
    policyFormat: body?.appAttestPolicy?.format ?? null,
    policyFingerprint: body?.appAttestPolicy?.fingerprint ?? null,
  };
}

function isReady(response, body) {
  return (
    response.status === 200 &&
    body?.purpose === "APNs alert delivery only" &&
    body?.earthquakeData === "Clients fetch directly from Wolfx" &&
    body?.appAttestPolicy?.format === "quakesignal-app-attest-policy/v2"
  );
}

async function probeMetadataWithinDeadline(fetchImpl, url, timeoutMs) {
  const response = await fetchWithoutRedirect(
    fetchImpl,
    url,
    {
      cache: "no-store",
    },
    {
      timeoutMs,
      maximumResponseBytes: SMOKE_MAX_RESPONSE_BYTES,
    },
  );
  let body = null;
  try {
    body = await response.json();
  } catch {
    // Keep polling through a rolling deployment / legacy response, but
    // include the HTTP status in the final failure summary.
  }
  return { response, body };
}

/**
 * Wait through a rolling deployment until the Worker metadata contract is
 * available. Alert-feed and delivery state remain private relay telemetry.
 */
export async function waitForWorkerReadiness(baseUrl, {
  timeoutMs = DEFAULT_TIMEOUT_MS,
  intervalMs = DEFAULT_INTERVAL_MS,
  fetchImpl = globalThis.fetch,
  now = Date.now,
  sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds)),
  onAttempt = () => {},
} = {}) {
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs <= 0) {
    throw new RangeError("timeoutMs must be a positive safe integer");
  }
  if (!Number.isSafeInteger(intervalMs) || intervalMs <= 0) {
    throw new RangeError("intervalMs must be a positive safe integer");
  }
  const url = metadataUrl(baseUrl);
  const deadline = now() + timeoutMs;
  let last = null;
  while (true) {
    const remainingBeforeAttempt = deadline - now();
    if (remainingBeforeAttempt <= 0) {
      throw new Error(`Worker readiness did not converge within ${timeoutMs}ms: ${JSON.stringify(last)}`);
    }
    try {
      const { response, body } = await probeMetadataWithinDeadline(
        fetchImpl,
        url,
        remainingBeforeAttempt,
      );
      last = readinessSummary(response, body);
      onAttempt(last);
      if (isReady(response, body)) return last;
    } catch (error) {
      last = { errorName: error instanceof Error ? error.name : "UnknownError" };
      onAttempt(last);
    }
    const remaining = deadline - now();
    if (remaining <= 0) {
      throw new Error(`Worker readiness did not converge within ${timeoutMs}ms: ${JSON.stringify(last)}`);
    }
    await sleep(Math.min(intervalMs, remaining));
  }
}

async function main() {
  const baseUrl = process.argv[2];
  if (!baseUrl) {
    throw new Error("Usage: node scripts/wait-for-worker-readiness.mjs https://worker.workers.dev");
  }
  const readiness = await waitForWorkerReadiness(baseUrl, {
    onAttempt: (attempt) => console.log(JSON.stringify({ outcome: "worker_readiness_probe", ...attempt })),
  });
  console.log(JSON.stringify({ outcome: "worker_ready", ...readiness }));
}

if (process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1])) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : "Worker readiness failed");
    process.exit(1);
  });
}
