/**
 * Independent, cron-only monitor for the consumerless terminal delivery DLQ.
 *
 * It reads only Queue aggregate metrics and, only when evidence is retained or
 * its own Queue probe fails, opens/updates one token-free GitHub issue. This
 * Worker cannot read Queue messages and has no D1, APNs, delivery, or
 * deployment binding.
 */

interface Env {
  // The monitor itself is deployed in a separate account; this identifies the
  // production or staging account whose Queue metrics it may read.
  CLOUDFLARE_TARGET_ACCOUNT_ID: string;
  CLOUDFLARE_MONITOR_API_TOKEN: string;
  GITHUB_APP_ID: string;
  GITHUB_APP_INSTALLATION_ID: string;
  // PKCS#8 RSA private-key PEM. Keep it as a Cloudflare Worker secret.
  GITHUB_APP_PRIVATE_KEY_PKCS8: string;
  // Opaque HTTPS endpoint of an external missed-heartbeat monitor. Keep the
  // complete URL secret because providers commonly encode its check token in
  // the path or query string.
  HEARTBEAT_PING_URL: string;
  MONITOR_TARGET: string;
}

interface QueueListResponse {
  result?: Array<{ queue_id?: unknown; queue_name?: unknown }>;
  result_info?: { total_pages?: unknown };
  success?: unknown;
}

interface QueueMetricsResponse {
  result?: {
    backlog_count?: unknown;
    oldest_message_timestamp_ms?: unknown;
  };
  success?: unknown;
}

interface GitHubInstallationTokenResponse {
  token?: unknown;
  permissions?: { issues?: unknown };
  repositories?: Array<{ id?: unknown }>;
}

interface GitHubIssue {
  number?: unknown;
  body?: unknown;
  pull_request?: unknown;
}

interface MonitorEvidence {
  queueName: string;
  backlogCount: number;
  oldestMessageTimestampMs: number;
  oldestMessageAgeSeconds: string;
  observedAt: string;
}

interface MonitorTarget {
  queueName: string;
  issueLabel: string;
  issueMarker: string;
  issueTitle: string;
  monitorFailureMarker: string;
  monitorFailureTitle: string;
  labelDescription: string;
}

type FetchImplementation = typeof fetch;

const CLOUDFLARE_API_BASE = "https://api.cloudflare.com/client/v4";
const GITHUB_API_BASE = "https://api.github.com";
const CLOUDFLARE_ACCOUNT_ID_MAX_LENGTH = 64;
const GITHUB_REPOSITORY_ID = 1302409647;
const GITHUB_REPOSITORY = "TastyHeadphones/QuakeSignal";
const MAX_QUEUE_PAGES = 20;
const MAX_RESPONSE_BYTES = 64 * 1024;
const REQUEST_TIMEOUT_MS = 10_000;
const MAX_APP_JWT_LIFETIME_SECONDS = 9 * 60;
const GITHUB_API_VERSION = "2026-03-10";

// Targets are deliberately enumerated in source rather than being arbitrary
// runtime URLs, Queue names, repositories, or issue markers. The staging
// target exists solely to rehearse a real escalation without putting test
// evidence in the production terminal Queue.
const MONITOR_TARGETS: Record<string, MonitorTarget> = {
  production: {
    queueName: "quakesignal-alert-delivery-dlq-fallback",
    issueLabel: "quakesignal-terminal-dlq-fallback",
    issueMarker: "<!-- quakesignal-terminal-dlq-fallback-monitor -->",
    issueTitle: "[Emergency] Recover terminal DLQ fallback backlog",
    monitorFailureMarker: "<!-- quakesignal-terminal-dlq-monitor-failure -->",
    monitorFailureTitle: "[Emergency] Terminal DLQ monitor probe failed",
    labelDescription: "Production terminal DLQ fallback recovery required",
  },
  staging: {
    queueName: "quakesignal-api-staging-alert-delivery-dlq-fallback",
    issueLabel: "quakesignal-staging-terminal-dlq-fallback",
    issueMarker: "<!-- quakesignal-staging-terminal-dlq-fallback-monitor -->",
    issueTitle: "[Test] Recover staging terminal DLQ fallback backlog",
    monitorFailureMarker: "<!-- quakesignal-staging-terminal-dlq-monitor-failure -->",
    monitorFailureTitle: "[Test] Staging terminal DLQ monitor probe failed",
    labelDescription: "Staging terminal DLQ fallback recovery test required",
  },
};

class MonitorError extends Error {
  constructor(
    message: string,
    readonly retryable: boolean,
  ) {
    super(message);
    this.name = "MonitorError";
  }
}

function permanent(message: string): MonitorError {
  return new MonitorError(message, false);
}

function retryable(message: string): MonitorError {
  return new MonitorError(message, true);
}

function requireNonEmpty(value: unknown, name: string): string {
  if (typeof value !== "string" || value.trim() === "") {
    throw permanent(`${name} is not configured`);
  }
  return value;
}

function requireDecimalIdentifier(value: unknown, name: string): string {
  const identifier = requireNonEmpty(value, name);
  if (!/^\d{1,20}$/.test(identifier)) {
    throw permanent(`${name} has an invalid format`);
  }
  return identifier;
}

function requireTargetAccountIdentifier(value: unknown): string {
  const accountId = requireNonEmpty(value, "CLOUDFLARE_TARGET_ACCOUNT_ID");
  if (!new RegExp(`^[A-Za-z0-9]{1,${CLOUDFLARE_ACCOUNT_ID_MAX_LENGTH}}$`).test(accountId)) {
    throw permanent("CLOUDFLARE_TARGET_ACCOUNT_ID has an invalid format");
  }
  return accountId;
}

function heartbeatPingUrl(value: unknown): URL {
  const raw = requireNonEmpty(value, "HEARTBEAT_PING_URL");
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw permanent("HEARTBEAT_PING_URL must be a valid HTTPS URL");
  }

  // The URL itself is an opaque secret. Restrict it to a direct HTTPS endpoint
  // without embedded credentials or fragments, and never include it in an
  // error or structured log.
  if (
    url.protocol !== "https:" ||
    url.hostname === "" ||
    url.username !== "" ||
    url.password !== "" ||
    url.hash !== ""
  ) {
    throw permanent("HEARTBEAT_PING_URL must be a direct HTTPS URL");
  }
  return url;
}

function monitorTarget(value: unknown): MonitorTarget {
  const name = requireNonEmpty(value, "MONITOR_TARGET");
  const target = MONITOR_TARGETS[name];
  if (!target) throw permanent("MONITOR_TARGET must be production or staging");
  return target;
}

function requireSafeInteger(value: unknown, name: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
    throw permanent(`${name} is invalid`);
  }
  return value;
}

function base64Url(value: Uint8Array | string): string {
  const bytes = typeof value === "string" ? new TextEncoder().encode(value) : value;
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
}

function decodeBase64(value: string): Uint8Array {
  const binary = atob(value.replace(/\s/g, ""));
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
  return bytes;
}

function privateKeyDer(pem: string): Uint8Array {
  const match = pem.trim().match(/^-----BEGIN PRIVATE KEY-----\s*([A-Za-z0-9+/=\s]+)-----END PRIVATE KEY-----$/u);
  if (!match) {
    throw permanent("GITHUB_APP_PRIVATE_KEY_PKCS8 must be an unencrypted PKCS#8 PEM");
  }

  try {
    return decodeBase64(match[1]);
  } catch {
    throw permanent("GITHUB_APP_PRIVATE_KEY_PKCS8 is not valid base64 PEM data");
  }
}

async function createGitHubAppJwt(env: Env, nowMs: number): Promise<string> {
  const appId = requireDecimalIdentifier(env.GITHUB_APP_ID, "GITHUB_APP_ID");
  const issuedAt = Math.floor(nowMs / 1000) - 60;
  const header = base64Url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const payload = base64Url(JSON.stringify({
    iat: issuedAt,
    exp: issuedAt + MAX_APP_JWT_LIFETIME_SECONDS,
    iss: appId,
  }));
  const signingInput = `${header}.${payload}`;

  let key: CryptoKey;
  try {
    const pemDer = privateKeyDer(requireNonEmpty(env.GITHUB_APP_PRIVATE_KEY_PKCS8, "GITHUB_APP_PRIVATE_KEY_PKCS8"));
    const keyData = new ArrayBuffer(pemDer.byteLength);
    new Uint8Array(keyData).set(pemDer);
    key = await crypto.subtle.importKey(
      "pkcs8",
      keyData,
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["sign"],
    );
  } catch (error) {
    if (error instanceof MonitorError) throw error;
    throw permanent("GITHUB_APP_PRIVATE_KEY_PKCS8 could not be imported as an RSA PKCS#8 key");
  }

  const signature = new Uint8Array(await crypto.subtle.sign(
    { name: "RSASSA-PKCS1-v1_5" },
    key,
    new TextEncoder().encode(signingInput),
  ));
  return `${signingInput}.${base64Url(signature)}`;
}

async function fetchWithDeadline(
  fetchImplementation: FetchImplementation,
  input: RequestInfo | URL,
  init: RequestInit,
  purpose: string,
): Promise<Response> {
  const timeout = new AbortController();
  const timeoutId = setTimeout(() => timeout.abort(), REQUEST_TIMEOUT_MS);
  try {
    // Aggregate Queue metrics and GitHub issue state must never be served from
    // a Worker cache: an old zero response could hide retained evidence.
    return await fetchImplementation(input, { ...init, cache: "no-store", signal: timeout.signal });
  } catch {
    throw retryable(`${purpose} request failed or timed out`);
  } finally {
    clearTimeout(timeoutId);
  }
}

function statusRetryable(status: number): boolean {
  return status === 408 || status === 429 || status >= 500;
}

async function responseJson<T>(response: Response, purpose: string): Promise<T> {
  const contentLength = Number(response.headers.get("content-length"));
  if (Number.isFinite(contentLength) && contentLength > MAX_RESPONSE_BYTES) {
    await response.body?.cancel();
    throw retryable(`${purpose} response was too large`);
  }

  const body = await response.text();
  if (body.length > MAX_RESPONSE_BYTES) {
    throw retryable(`${purpose} response was too large`);
  }

  try {
    return JSON.parse(body) as T;
  } catch {
    throw retryable(`${purpose} response was not JSON`);
  }
}

async function cloudflareJson<T>(
  fetchImplementation: FetchImplementation,
  path: string,
  token: string,
): Promise<T> {
  const response = await fetchWithDeadline(
    fetchImplementation,
    `${CLOUDFLARE_API_BASE}${path}`,
    {
      headers: {
        Accept: "application/json",
        Authorization: `Bearer ${token}`,
      },
    },
    "Cloudflare Queue API",
  );
  if (!response.ok) {
    await response.body?.cancel();
    throw new MonitorError("Cloudflare Queue API returned an unexpected status", statusRetryable(response.status));
  }
  return responseJson<T>(response, "Cloudflare Queue API");
}

async function githubResponse(
  fetchImplementation: FetchImplementation,
  path: string,
  token: string,
  init: RequestInit = {},
): Promise<Response> {
  return fetchWithDeadline(
    fetchImplementation,
    `${GITHUB_API_BASE}${path}`,
    {
      ...init,
      headers: {
        Accept: "application/vnd.github+json",
        Authorization: `Bearer ${token}`,
        "X-GitHub-Api-Version": GITHUB_API_VERSION,
        ...(init.headers ?? {}),
      },
    },
    "GitHub API",
  );
}

function validateCloudflareSuccess(value: unknown, purpose: string): void {
  if (!value || typeof value !== "object" || (value as { success?: unknown }).success !== true) {
    throw retryable(`${purpose} response was invalid`);
  }
}

async function terminalQueueId(
  env: Env,
  target: MonitorTarget,
  fetchImplementation: FetchImplementation,
): Promise<string> {
  const accountId = requireTargetAccountIdentifier(env.CLOUDFLARE_TARGET_ACCOUNT_ID);
  const token = requireNonEmpty(env.CLOUDFLARE_MONITOR_API_TOKEN, "CLOUDFLARE_MONITOR_API_TOKEN");
  const queueIds: string[] = [];
  let page = 1;
  let totalPages = 1;

  while (page <= totalPages) {
    if (page > MAX_QUEUE_PAGES) throw permanent("Cloudflare Queue pagination exceeded the monitor limit");
    const payload = await cloudflareJson<QueueListResponse>(
      fetchImplementation,
      `/accounts/${accountId}/queues?page=${page}&per_page=100`,
      token,
    );
    validateCloudflareSuccess(payload, "Cloudflare Queue list");
    if (!Array.isArray(payload.result)) throw retryable("Cloudflare Queue list result was invalid");

    for (const queue of payload.result) {
      if (queue?.queue_name === target.queueName && typeof queue.queue_id === "string" && /^[A-Za-z0-9]{1,64}$/.test(queue.queue_id)) {
        queueIds.push(queue.queue_id);
      }
    }

    const reportedPages = payload.result_info?.total_pages ?? 1;
    if (
      typeof reportedPages !== "number" ||
      !Number.isSafeInteger(reportedPages) ||
      reportedPages < 1 ||
      reportedPages > MAX_QUEUE_PAGES
    ) {
      throw retryable("Cloudflare Queue list pagination was invalid");
    }
    totalPages = reportedPages;
    page += 1;
  }

  if (queueIds.length !== 1) {
    throw permanent("Expected exactly one terminal fallback Queue");
  }
  return queueIds[0];
}

async function terminalEvidence(
  env: Env,
  target: MonitorTarget,
  observedAtMs: number,
  fetchImplementation: FetchImplementation,
): Promise<MonitorEvidence> {
  const accountId = requireTargetAccountIdentifier(env.CLOUDFLARE_TARGET_ACCOUNT_ID);
  const token = requireNonEmpty(env.CLOUDFLARE_MONITOR_API_TOKEN, "CLOUDFLARE_MONITOR_API_TOKEN");
  const queueId = await terminalQueueId(env, target, fetchImplementation);
  const payload = await cloudflareJson<QueueMetricsResponse>(
    fetchImplementation,
    `/accounts/${accountId}/queues/${queueId}/metrics`,
    token,
  );
  validateCloudflareSuccess(payload, "Cloudflare Queue metrics");
  const backlogCount = requireSafeInteger(payload.result?.backlog_count, "Cloudflare Queue backlog count");
  const oldestMessageTimestampMs = requireSafeInteger(
    payload.result?.oldest_message_timestamp_ms,
    "Cloudflare Queue oldest message timestamp",
  );
  const oldestMessageAgeSeconds = oldestMessageTimestampMs === 0
    ? "unknown"
    : oldestMessageTimestampMs <= observedAtMs
      ? String(Math.floor((observedAtMs - oldestMessageTimestampMs) / 1000))
      : "clock-skew-or-future";

  return {
    queueName: target.queueName,
    backlogCount,
    oldestMessageTimestampMs,
    oldestMessageAgeSeconds,
    observedAt: new Date(observedAtMs).toISOString(),
  };
}

function hasEvidence(evidence: MonitorEvidence): boolean {
  return evidence.backlogCount > 0 || evidence.oldestMessageTimestampMs > 0;
}

async function installationToken(
  env: Env,
  nowMs: number,
  fetchImplementation: FetchImplementation,
): Promise<string> {
  const installationId = requireDecimalIdentifier(env.GITHUB_APP_INSTALLATION_ID, "GITHUB_APP_INSTALLATION_ID");
  const jwt = await createGitHubAppJwt(env, nowMs);
  const response = await githubResponse(
    fetchImplementation,
    `/app/installations/${installationId}/access_tokens`,
    jwt,
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        repository_ids: [GITHUB_REPOSITORY_ID],
        permissions: { issues: "write" },
      }),
    },
  );
  if (response.status !== 201) {
    await response.body?.cancel();
    throw new MonitorError("GitHub installation-token request was rejected", statusRetryable(response.status));
  }
  const payload = await responseJson<GitHubInstallationTokenResponse>(response, "GitHub installation-token");
  if (
    typeof payload.token !== "string" ||
    payload.token.length < 20 ||
    payload.token.length > 4096 ||
    payload.permissions?.issues !== "write" ||
    !Array.isArray(payload.repositories) ||
    payload.repositories.length !== 1 ||
    payload.repositories[0]?.id !== GITHUB_REPOSITORY_ID
  ) {
    throw permanent("GitHub installation token was not limited to Issues write on QuakeSignal");
  }
  return payload.token;
}

async function githubJson<T>(
  fetchImplementation: FetchImplementation,
  path: string,
  token: string,
): Promise<{ status: number; payload: T | null }> {
  const response = await githubResponse(fetchImplementation, path, token);
  if (response.status === 404) {
    await response.body?.cancel();
    return { status: 404, payload: null };
  }
  if (!response.ok) {
    await response.body?.cancel();
    throw new MonitorError("GitHub issue API request was rejected", statusRetryable(response.status));
  }
  return { status: response.status, payload: await responseJson<T>(response, "GitHub issue API") };
}

async function githubMutation(
  fetchImplementation: FetchImplementation,
  method: "POST" | "PATCH",
  path: string,
  token: string,
  body: unknown,
): Promise<void> {
  const response = await githubResponse(fetchImplementation, path, token, {
    method,
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!response.ok) {
    await response.body?.cancel();
    throw new MonitorError("GitHub issue API request was rejected", statusRetryable(response.status));
  }
  await response.body?.cancel();
}

function issueBody(evidence: MonitorEvidence, target: MonitorTarget): string {
  return `${target.issueMarker}
## Terminal fallback backlog detected

The independent production monitor found retained work in the intentionally
consumerless terminal Queue. This is an urgent recovery event: the normal DLQ
could not persist an incident in either D1 or the Durable Object fallback.

- Queue: \`${evidence.queueName}\`
- Backlog count: \`${evidence.backlogCount}\`
- Oldest message timestamp (ms): \`${evidence.oldestMessageTimestampMs}\`
- Oldest message age (seconds): \`${evidence.oldestMessageAgeSeconds}\`
- Observed (UTC): \`${evidence.observedAt}\`

Only aggregate metrics are published here. Do **not** paste Queue message
contents, device data, APNs credentials, Cloudflare tokens, or API responses
into this issue.

## Required recovery

1. Page the designated production responder and follow
   \`docs/CLOUDFLARE_PRODUCTION.md#terminal-dlq-fallback-recovery\`.
2. Preserve the terminal Queue: do not attach a Worker consumer, purge it, or
   acknowledge messages before D1 and the Durable Object are demonstrably
   healthy.
3. Investigate and restore the D1/Durable Object failure. Perform any manual
   replay only with the approved break-glass Queue procedure.
4. Verify the Queue metrics return to zero, record the incident outcome, and
   manually close this issue only after the retained evidence is safely
   recovered or deliberately dispositioned.
`;
}

function monitorFailureBody(observedAtMs: number, target: MonitorTarget): string {
  return `${target.monitorFailureMarker}
## Terminal DLQ monitor failed

The independent Cloudflare Cron monitor could not complete a required
Queue/GitHub monitor cycle or its external heartbeat check-in. This is a
monitoring incident: the terminal fallback Queue may contain retained evidence
that has not been observed.

- Observed (UTC): \`${new Date(observedAtMs).toISOString()}\`

No Queue messages, API response bodies, device data, tokens, or credentials
are included. Restore the monitor, manually run the reviewed GitHub monitor,
and follow \`docs/CLOUDFLARE_PRODUCTION.md#terminal-dlq-fallback-recovery\`.
`;
}

async function ensureLabel(
  fetchImplementation: FetchImplementation,
  token: string,
  target: MonitorTarget,
): Promise<void> {
  const labelPath = `/repos/${GITHUB_REPOSITORY}/labels/${target.issueLabel}`;
  const result = await githubJson<unknown>(fetchImplementation, labelPath, token);
  if (result.status === 404) {
    await githubMutation(fetchImplementation, "POST", `/repos/${GITHUB_REPOSITORY}/labels`, token, {
      name: target.issueLabel,
      color: "B60205",
      description: target.labelDescription,
    });
  }
}

async function openOrUpdateIssue(
  fetchImplementation: FetchImplementation,
  token: string,
  target: MonitorTarget,
  marker: string,
  title: string,
  body: string,
): Promise<"opened" | "updated"> {
  await ensureLabel(fetchImplementation, token, target);
  const listed = await githubJson<GitHubIssue[]>(
    fetchImplementation,
    `/repos/${GITHUB_REPOSITORY}/issues?state=open&labels=${encodeURIComponent(target.issueLabel)}&per_page=100`,
    token,
  );
  if (!Array.isArray(listed.payload)) throw retryable("GitHub issue list response was invalid");
  const matchingIssueNumbers = listed.payload
    .flatMap((issue) => (
      !issue.pull_request &&
      typeof issue.body === "string" &&
      issue.body.includes(marker) &&
      typeof issue.number === "number" &&
      Number.isSafeInteger(issue.number) &&
      issue.number > 0
        ? [issue.number]
        : []
    ))
    .sort((first, second) => first - second);
  const payload = { title, body, labels: [target.issueLabel] };
  if (matchingIssueNumbers.length === 0) {
    await githubMutation(fetchImplementation, "POST", `/repos/${GITHUB_REPOSITORY}/issues`, token, payload);
    return "opened";
  }
  await githubMutation(
    fetchImplementation,
    "PATCH",
    `/repos/${GITHUB_REPOSITORY}/issues/${matchingIssueNumbers[0]}`,
    token,
    payload,
  );
  return "updated";
}

async function reportMonitorFailure(
  env: Env,
  target: MonitorTarget,
  observedAtMs: number,
  fetchImplementation: FetchImplementation,
): Promise<void> {
  const token = await installationToken(env, observedAtMs, fetchImplementation);
  const outcome = await openOrUpdateIssue(
    fetchImplementation,
    token,
    target,
    target.monitorFailureMarker,
    target.monitorFailureTitle,
    monitorFailureBody(observedAtMs, target),
  );
  console.error(JSON.stringify({
    event: "terminal_dlq_monitor_probe_failed",
    issueOutcome: outcome,
    observedAt: new Date(observedAtMs).toISOString(),
  }));
}

async function pingHeartbeat(
  url: URL,
  fetchImplementation: FetchImplementation,
): Promise<void> {
  const response = await fetchWithDeadline(
    fetchImplementation,
    url,
    {
      method: "GET",
      // A heartbeat URL often contains an opaque check token. Do not send it
      // to a redirect destination if its operator changes routing.
      redirect: "error",
    },
    "heartbeat ping",
  );
  try {
    if (!response.ok) {
      throw new MonitorError(
        "heartbeat ping returned an unexpected status",
        statusRetryable(response.status),
      );
    }
  } finally {
    // The response has no useful data and may be unbounded. Never read or log
    // it; cancel it before this Cron invocation completes.
    await response.body?.cancel();
  }
}

async function runTerminalDlqMonitor(
  env: Env,
  observedAtMs: number,
  fetchImplementation: FetchImplementation = fetch,
): Promise<void> {
  const target = monitorTarget(env.MONITOR_TARGET);
  // Validate the App credential and its exact repository/Issues scope on every
  // run, including an empty Queue. A revoked App must not remain invisible
  // until a production incident needs it.
  const token = await installationToken(env, observedAtMs, fetchImplementation);
  const evidence = await terminalEvidence(env, target, observedAtMs, fetchImplementation);
  if (!hasEvidence(evidence)) {
    console.log(JSON.stringify({
      event: "terminal_dlq_monitor_completed",
      alert: false,
      observedAt: evidence.observedAt,
    }));
    return;
  }

  const issueOutcome = await openOrUpdateIssue(
    fetchImplementation,
    token,
    target,
    target.issueMarker,
    target.issueTitle,
    issueBody(evidence, target),
  );
  console.error(JSON.stringify({
    event: "terminal_dlq_monitor_alert",
    issueOutcome,
    backlogCount: evidence.backlogCount,
    oldestMessageTimestampMs: evidence.oldestMessageTimestampMs,
    observedAt: evidence.observedAt,
  }));
}

async function scheduledMonitor(
  controller: ScheduledController,
  env: Env,
  fetchImplementation: FetchImplementation = fetch,
  now: () => number = Date.now,
): Promise<void> {
  // Cron delivery may be delayed. GitHub App JWT issuance must use the real
  // current wall clock, not the nominal scheduled timestamp, or its ten-minute
  // maximum lifetime can already have elapsed by the time this handler runs.
  const observedAtMs = now();
  let target: MonitorTarget | undefined;
  try {
    target = monitorTarget(env.MONITOR_TARGET);
    await runTerminalDlqMonitor(env, observedAtMs, fetchImplementation);
    // A successful heartbeat means the full Queue/GitHub monitor path ran,
    // not merely that the scheduled handler started.
    await pingHeartbeat(heartbeatPingUrl(env.HEARTBEAT_PING_URL), fetchImplementation);
  } catch (error) {
    const monitorError = error instanceof MonitorError ? error : retryable("Terminal DLQ monitor failed unexpectedly");
    if (!monitorError.retryable) controller.noRetry();

    // If the Queue probe failed but GitHub authentication still works, open a
    // distinct token-free issue so a monitor outage is not silently mistaken
    // for an empty terminal Queue. Never replace the original error with a
    // report failure: Cron event history and structured logs remain useful.
    try {
      if (target) await reportMonitorFailure(env, target, observedAtMs, fetchImplementation);
    } catch {
      // Deliberately do not log error text: it can originate from a provider.
      console.error(JSON.stringify({
        event: "terminal_dlq_monitor_failure_issue_unavailable",
        observedAt: new Date(observedAtMs).toISOString(),
      }));
    }

    console.error(JSON.stringify({
      event: "terminal_dlq_monitor_failed",
      retryable: monitorError.retryable,
      observedAt: new Date(observedAtMs).toISOString(),
    }));
    throw monitorError;
  }
}

const worker: ExportedHandler<Env> = {
  async fetch() {
    return new Response(null, {
      status: 404,
      headers: { "cache-control": "no-store" },
    });
  },

  async scheduled(controller, env) {
    await scheduledMonitor(controller, env);
  },
};

// Function exports are intentionally limited to testable procedures. The
// deployed module's only event handler is the default ExportedHandler above.
export { runTerminalDlqMonitor, scheduledMonitor };
export default worker;
