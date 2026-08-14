import { fileURLToPath } from "node:url";
import { resolve } from "node:path";

const DEFAULT_TIMEOUT_MS = 180_000;
const DEFAULT_INTERVAL_MS = 5_000;

class WorkerReadinessProbeTimeoutError extends Error {
  constructor(timeoutMs) {
    super(`Worker readiness health probe exceeded its ${timeoutMs}ms deadline`);
    this.name = "WorkerReadinessProbeTimeoutError";
  }
}

function healthUrl(baseUrl) {
  const url = new URL(baseUrl);
  if (url.protocol !== "https:" || url.pathname !== "/" || url.search || url.hash) {
    throw new Error("Worker origin must be a bare HTTPS URL");
  }
  return new URL("/healthz", url).toString();
}

function readinessSummary(response, body) {
  return {
    status: response.status,
    ok: body?.ok === true,
    deliveryStatus: typeof body?.delivery?.status === "string"
      ? body.delivery.status
      : null,
    apnsConfigured: body?.delivery?.apnsConfigured === true,
    upstreamStatus: typeof body?.upstream?.status === "string"
      ? body.upstream.status
      : null,
    upstreamTransport: typeof body?.upstream?.transport === "string"
      ? body.upstream.transport
      : null,
    websocketStatus: typeof body?.upstream?.websocketStatus === "string"
      ? body.upstream.websocketStatus
      : null,
    staleSources: Array.isArray(body?.upstream?.staleSources)
      ? body.upstream.staleSources
      : null,
  };
}

function isReady(response, body) {
  return (
    response.status === 200 &&
    body?.ok === true &&
    body?.delivery?.status === "ready" &&
    body?.upstream?.status === "ready" &&
    Array.isArray(body?.upstream?.staleSources) &&
    body.upstream.staleSources.length === 0 &&
    ["websocket", "http-polling", "mixed"].includes(body?.upstream?.transport)
  );
}

async function probeHealthWithinDeadline(fetchImpl, url, timeoutMs) {
  const controller = new AbortController();
  let timeoutId;
  const timeout = new Promise((_, reject) => {
    timeoutId = setTimeout(() => {
      controller.abort();
      reject(new WorkerReadinessProbeTimeoutError(timeoutMs));
    }, timeoutMs);
  });
  const probe = (async () => {
    const response = await fetchImpl(url, {
      cache: "no-store",
      redirect: "error",
      signal: controller.signal,
    });
    let body = null;
    try {
      body = await response.json();
    } catch {
      // Keep polling through a rolling deployment / legacy response, but
      // include the HTTP status in the final failure summary.
    }
    return { response, body };
  })();

  try {
    return await Promise.race([probe, timeout]);
  } finally {
    clearTimeout(timeoutId);
  }
}

/**
 * Wait through the relay's intentional 90-second WebSocket-to-HTTP fallback
 * grace. A 200 is accepted only when the full delivery/upstream readiness
 * contract is healthy; a legacy/superficial 200 is never enough.
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
  const url = healthUrl(baseUrl);
  const deadline = now() + timeoutMs;
  let last = null;
  while (true) {
    const remainingBeforeAttempt = deadline - now();
    if (remainingBeforeAttempt <= 0) {
      throw new Error(`Worker readiness did not converge within ${timeoutMs}ms: ${JSON.stringify(last)}`);
    }
    try {
      const { response, body } = await probeHealthWithinDeadline(
        fetchImpl,
        url,
        remainingBeforeAttempt,
      );
      last = readinessSummary(response, body);
      onAttempt(last);
      if (isReady(response, body)) return last;
      if (body?.delivery?.apnsConfigured === false) {
        throw new Error("Worker reports APNs signing material is not configured");
      }
    } catch (error) {
      if (error instanceof Error && error.message === "Worker reports APNs signing material is not configured") {
        throw error;
      }
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
