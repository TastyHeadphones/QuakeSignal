import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const CLOUDFLARE_API_BASE = "https://api.cloudflare.com/client/v4";
const INCIDENT_DISPOSITION_ACCOUNT_ID = "69c72916910ed7231abce32069d5257b";
const INCIDENT_DISPOSITION_DATABASE_ID = "834fba5c-0d99-4398-9565-18c6858eb2a8";
const INCIDENT_DISPOSITION_TOKEN_NAME =
  "CLOUDFLARE_D1_INCIDENT_DISPOSITION_API_TOKEN";

/**
 * This is deliberately a one-shot, fixed manifest rather than a general D1
 * administration CLI. Each row was independently read as metadata only after
 * its outbox had already reached the safe `expired` terminal state. No target
 * contains an APNs token, event JSON, or Queue message body.
 */
export const HISTORICAL_APNS_ENVIRONMENT_INCIDENTS = Object.freeze({
  accountId: INCIDENT_DISPOSITION_ACCOUNT_ID,
  databaseId: INCIDENT_DISPOSITION_DATABASE_ID,
  targets: Object.freeze([
    Object.freeze({
      outboxId: "6583b0d5-b27e-4b1a-a27e-dce014233e4a",
      expiresAtUtc: "2026-08-14T03:08:33.000Z",
      acknowledgedAtUtc: "2026-08-14T03:08:52.339Z",
      firstSeenUtc: "2026-08-14T02:38:50.060Z",
      lastSeenUtc: "2026-08-14T02:53:51.273Z",
      occurrences: 2,
      apnsReason: "BadEnvironmentKeyInToken",
      eventRef: "cq_eew:202608141038.0001",
      sourceId: "cq_eew",
      eventSerial: 1,
      notificationReason: "new",
    }),
    Object.freeze({
      outboxId: "a18e7dc5-9daf-4315-a608-e8aaf4125f75",
      expiresAtUtc: "2026-08-14T02:03:42.000Z",
      acknowledgedAtUtc: "2026-08-14T02:03:56.665Z",
      firstSeenUtc: "2026-08-14T01:33:53.697Z",
      lastSeenUtc: "2026-08-14T01:48:55.662Z",
      occurrences: 2,
      apnsReason: "BadEnvironmentKeyInToken",
      eventRef: "cq_eew:202608140933.0001",
      sourceId: "cq_eew",
      eventSerial: 1,
      notificationReason: "new",
    }),
    Object.freeze({
      outboxId: "db9797ff-dc78-403d-8335-652b03ce1836",
      expiresAtUtc: "2026-08-14T02:37:42.000Z",
      acknowledgedAtUtc: "2026-08-14T02:38:10.265Z",
      firstSeenUtc: "2026-08-14T01:38:05.233Z",
      lastSeenUtc: "2026-08-14T02:23:09.679Z",
      occurrences: 4,
      apnsReason: "BadEnvironmentKeyInToken",
      eventRef: "cenc_eqlist:CD.20260814093737.599",
      sourceId: "cenc_eqlist",
      eventSerial: 2,
      notificationReason: "report",
    }),
  ]),
});

const TARGET_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ACCOUNT_ID = /^[a-f0-9]{32}$/i;
const DATABASE_ID = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;

function fail(message) {
  throw new Error(message);
}

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function nonEmptyString(value) {
  return typeof value === "string" && value.trim() !== "";
}

function normalizeNow(now) {
  const date = now instanceof Date ? now : new Date(now ?? Date.now());
  if (!Number.isFinite(date.getTime())) {
    fail("APNs incident disposition requires a valid current time.");
  }
  return date;
}

export function parseDispositionArguments(argv = process.argv.slice(2)) {
  if (argv.length === 0) return { apply: false };
  if (argv.length === 1 && argv[0] === "--apply") return { apply: true };
  fail("Usage: node scripts/dispose-historical-apns-environment-incidents.mjs [--apply]");
}

export function verifyDispositionManifest(
  manifest = HISTORICAL_APNS_ENVIRONMENT_INCIDENTS,
  now = new Date(),
) {
  const current = normalizeNow(now);
  if (!isRecord(manifest) || !ACCOUNT_ID.test(manifest.accountId ?? "")) {
    fail("APNs incident disposition manifest has an invalid Cloudflare account.");
  }
  if (!DATABASE_ID.test(manifest.databaseId ?? "")) {
    fail("APNs incident disposition manifest has an invalid D1 database.");
  }
  if (!Array.isArray(manifest.targets) || manifest.targets.length === 0) {
    fail("APNs incident disposition manifest must contain fixed targets.");
  }

  const ids = new Set();
  for (const target of manifest.targets) {
    if (!isRecord(target) || !TARGET_ID.test(target.outboxId ?? "")) {
      fail("APNs incident disposition manifest has an invalid target.");
    }
    if (ids.has(target.outboxId)) {
      fail("APNs incident disposition manifest contains a duplicate target.");
    }
    ids.add(target.outboxId);
    if (
      !nonEmptyString(target.expiresAtUtc) ||
      !nonEmptyString(target.acknowledgedAtUtc) ||
      !nonEmptyString(target.firstSeenUtc) ||
      !nonEmptyString(target.lastSeenUtc) ||
      !nonEmptyString(target.apnsReason) ||
      !nonEmptyString(target.eventRef) ||
      !nonEmptyString(target.sourceId) ||
      !nonEmptyString(target.notificationReason) ||
      !Number.isSafeInteger(target.occurrences) ||
      target.occurrences < 1 ||
      !Number.isSafeInteger(target.eventSerial) ||
      target.eventSerial < 0
    ) {
      fail("APNs incident disposition manifest has incomplete target metadata.");
    }
    const expiresAt = Date.parse(target.expiresAtUtc);
    const acknowledgedAt = Date.parse(target.acknowledgedAtUtc);
    const firstSeenAt = Date.parse(target.firstSeenUtc);
    const lastSeenAt = Date.parse(target.lastSeenUtc);
    if (
      !Number.isFinite(expiresAt) ||
      !Number.isFinite(acknowledgedAt) ||
      !Number.isFinite(firstSeenAt) ||
      !Number.isFinite(lastSeenAt) ||
      firstSeenAt > lastSeenAt ||
      expiresAt >= current.getTime()
    ) {
      fail("APNs incident disposition manifest is not limited to expired historical evidence.");
    }
  }
  return manifest;
}

export function verifyDispositionEnvironment(
  environment = process.env,
  { apply = false, manifest = HISTORICAL_APNS_ENVIRONMENT_INCIDENTS } = {},
) {
  const missing = ["CLOUDFLARE_ACCOUNT_ID", INCIDENT_DISPOSITION_TOKEN_NAME]
    .filter((name) => !nonEmptyString(environment[name]));
  if (missing.length > 0) {
    fail("APNs incident disposition is missing protected Cloudflare configuration.");
  }
  if (environment.CLOUDFLARE_ACCOUNT_ID !== manifest.accountId) {
    fail("APNs incident disposition refuses a non-production Cloudflare account.");
  }
  if (
    apply &&
    (
      environment.GITHUB_ACTIONS !== "true" ||
      environment.GITHUB_REF !== "refs/heads/main" ||
      environment.GITHUB_REF_PROTECTED !== "true"
    )
  ) {
    fail("APNs incident disposition apply is restricted to protected main in GitHub Actions.");
  }
  return {
    accountId: manifest.accountId,
    databaseId: manifest.databaseId,
    token: environment[INCIDENT_DISPOSITION_TOKEN_NAME],
  };
}

export function incidentDispositionEndpoint({ accountId, databaseId }) {
  return `${CLOUDFLARE_API_BASE}/accounts/${accountId}/d1/database/${databaseId}/query`;
}

export function targetReadStatement(target) {
  return {
    sql: `SELECT
            o.id AS outbox_id,
            o.expires_at_utc,
            o.acknowledged_at_utc,
            o.terminal_reason,
            o.final_status,
            o.queue_lease_until_utc,
            o.delivery_id AS outbox_delivery_id,
            o.root_delivery_id AS outbox_root_delivery_id,
            o.event_ref AS outbox_event_ref,
            o.event_serial AS outbox_event_serial,
            o.notification_reason AS outbox_notification_reason,
            p.status AS failure_status,
            p.apns_status,
            p.apns_reason,
            p.delivery_id AS failure_delivery_id,
            p.root_delivery_id AS failure_root_delivery_id,
            p.event_ref AS failure_event_ref,
            p.source_id AS failure_source_id,
            p.event_serial AS failure_event_serial,
            p.notification_reason AS failure_notification_reason,
            p.first_seen_utc,
            p.last_seen_utc,
            p.occurrences,
            p.resolved_at_utc
          FROM alert_delivery_outbox AS o
          LEFT JOIN alert_delivery_page_failures AS p ON p.outbox_id = o.id
          WHERE o.id = ?`,
    params: [target.outboxId],
  };
}

function targetActivePredicate(alias, target) {
  return {
    sql: `(${alias}.outbox_id = ?
            AND ${alias}.status = 'active'
            AND ${alias}.resolved_at_utc IS NULL
            AND ${alias}.apns_status = 403
            AND ${alias}.apns_reason = ?
            AND ${alias}.event_ref = ?
            AND ${alias}.source_id = ?
            AND ${alias}.event_serial = ?
            AND ${alias}.notification_reason = ?
            AND ${alias}.first_seen_utc = ?
            AND ${alias}.last_seen_utc = ?
            AND ${alias}.occurrences = ?
            AND EXISTS (
              SELECT 1 FROM alert_delivery_outbox
              WHERE id = ${alias}.outbox_id
                AND expires_at_utc = ?
                AND acknowledged_at_utc = ?
                AND terminal_reason = 'expired'
                AND final_status IS NULL
                AND queue_lease_until_utc IS NULL
                AND delivery_id = ${alias}.delivery_id
                AND root_delivery_id = ${alias}.root_delivery_id
                AND event_ref = ${alias}.event_ref
                AND event_serial = ${alias}.event_serial
                AND notification_reason = ${alias}.notification_reason
            ))`,
    params: [
      target.outboxId,
      target.apnsReason,
      target.eventRef,
      target.sourceId,
      target.eventSerial,
      target.notificationReason,
      target.firstSeenUtc,
      target.lastSeenUtc,
      target.occurrences,
      target.expiresAtUtc,
      target.acknowledgedAtUtc,
    ],
  };
}

function targetDisposedPredicate(alias, target) {
  const active = targetActivePredicate(alias, target);
  return {
    sql: active.sql
      .replace(`${alias}.status = 'active'`, `${alias}.status = 'resolved'`)
      .replace(`${alias}.resolved_at_utc IS NULL`, `${alias}.resolved_at_utc IS NOT NULL`),
    params: active.params,
  };
}

/**
 * This is one SQL statement, not one update per target. The inner count is an
 * all-target gate: if any approved record changed after preflight, the outer
 * UPDATE receives no rows. SQLite therefore cannot resolve a subset of this
 * manifest because another target raced the operator's apply request.
 */
export function allTargetsResolveStatement(
  readyTargets,
  disposedTargets = [],
  resolvedAtUtc,
) {
  if (!Array.isArray(readyTargets) || readyTargets.length === 0 || !Array.isArray(disposedTargets)) {
    fail("APNs incident disposition requires at least one approved target.");
  }
  const allTargets = [...readyTargets, ...disposedTargets];
  if (new Set(allTargets.map((target) => target.outboxId)).size !== allTargets.length) {
    fail("APNs incident disposition cannot resolve duplicate targets.");
  }
  const candidates = [
    ...readyTargets.map((target) => targetActivePredicate("candidate", target)),
    ...disposedTargets.map((target) => targetDisposedPredicate("candidate", target)),
  ];
  const rows = readyTargets.map((target) => targetActivePredicate("p", target));
  return {
    sql: `UPDATE alert_delivery_page_failures AS p
          SET status = 'resolved', resolved_at_utc = ?
          WHERE (
            SELECT COUNT(*)
            FROM alert_delivery_page_failures AS candidate
            WHERE ${candidates.map(({ sql }) => sql).join(" OR ")}
          ) = ?
            AND (${rows.map(({ sql }) => sql).join(" OR ")})`,
    params: [
      resolvedAtUtc,
      ...candidates.flatMap(({ params }) => params),
      allTargets.length,
      ...rows.flatMap(({ params }) => params),
    ],
  };
}

function queryResults(payload) {
  if (!isRecord(payload) || payload.success !== true || !Array.isArray(payload.result)) {
    fail("Cloudflare D1 returned an unreadable incident disposition response.");
  }
  if (
    payload.result.some(
      (result) => !isRecord(result) || result.success !== true || !isRecord(result.meta),
    )
  ) {
    fail("Cloudflare D1 did not complete every incident disposition statement.");
  }
  return payload.result;
}

/**
 * Calls only the documented D1 query endpoint. Errors intentionally omit API
 * response bodies, headers, target identifiers, and credentials.
 */
export async function queryD1(
  environment,
  body,
  { fetchImpl = fetch, manifest = HISTORICAL_APNS_ENVIRONMENT_INCIDENTS } = {},
) {
  const verified = verifyDispositionEnvironment(environment, { manifest });
  let response;
  try {
    response = await fetchImpl(incidentDispositionEndpoint(verified), {
      method: "POST",
      headers: {
        Authorization: `Bearer ${verified.token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(body),
      cache: "no-store",
      redirect: "error",
      signal: AbortSignal.timeout(10_000),
    });
  } catch {
    fail("Cloudflare D1 incident disposition request failed.");
  }

  if (!response.ok) {
    fail("Cloudflare D1 incident disposition request was rejected.");
  }
  try {
    return queryResults(await response.json());
  } catch (error) {
    if (error instanceof Error && error.message.startsWith("Cloudflare D1")) {
      throw error;
    }
    fail("Cloudflare D1 returned an unreadable incident disposition response.");
  }
}

function exactlyOneResultRow(result) {
  if (!Array.isArray(result.results) || result.results.length !== 1 || !isRecord(result.results[0])) {
    fail("APNs incident disposition target verification did not return exactly one metadata row.");
  }
  return result.results[0];
}

export function classifyHistoricalIncidentTarget(target, row) {
  if (!isRecord(row)) return "mismatch";
  const safeExpiredOutbox =
    row.outbox_id === target.outboxId &&
    row.expires_at_utc === target.expiresAtUtc &&
    row.acknowledged_at_utc === target.acknowledgedAtUtc &&
    row.terminal_reason === "expired" &&
    row.final_status === null &&
    row.queue_lease_until_utc === null;
  if (!safeExpiredOutbox) return "mismatch";

  const matchingFailure =
    row.apns_status === 403 &&
    row.apns_reason === target.apnsReason &&
    row.failure_event_ref === target.eventRef &&
    row.failure_source_id === target.sourceId &&
    row.failure_event_serial === target.eventSerial &&
    row.failure_notification_reason === target.notificationReason &&
    row.first_seen_utc === target.firstSeenUtc &&
    row.last_seen_utc === target.lastSeenUtc &&
    row.occurrences === target.occurrences;
  if (!matchingFailure) return "mismatch";
  if (
    row.outbox_delivery_id !== row.failure_delivery_id ||
    row.outbox_root_delivery_id !== row.failure_root_delivery_id ||
    row.outbox_event_ref !== row.failure_event_ref ||
    row.outbox_event_serial !== row.failure_event_serial ||
    row.outbox_notification_reason !== row.failure_notification_reason
  ) return "mismatch";
  if (row.failure_status === "active" && row.resolved_at_utc === null) return "ready";
  if (row.failure_status === "resolved" && nonEmptyString(row.resolved_at_utc)) return "disposed";
  return "mismatch";
}

export async function readHistoricalIncidentStates(
  environment,
  { fetchImpl = fetch, manifest = HISTORICAL_APNS_ENVIRONMENT_INCIDENTS } = {},
) {
  const results = await queryD1(
    environment,
    { batch: manifest.targets.map(targetReadStatement) },
    { fetchImpl, manifest },
  );
  if (results.length !== manifest.targets.length) {
    fail("APNs incident disposition target verification returned an unexpected result count.");
  }
  return results.map((result, index) =>
    classifyHistoricalIncidentTarget(
      manifest.targets[index],
      exactlyOneResultRow(result),
    ),
  );
}

function assertNoUnexpectedTargetState(states) {
  if (states.some((state) => state === "mismatch")) {
    fail("APNs incident disposition target state changed; no unverified record was modified.");
  }
}

function changedRowCount(result) {
  const changes = result?.meta?.changes;
  return typeof changes === "number" && Number.isSafeInteger(changes) ? changes : null;
}

export function dispositionSummary({
  apply,
  states,
  initialStates = states,
  resolved = 0,
}) {
  const ready = initialStates.filter((state) => state === "ready").length;
  const disposed = initialStates.filter((state) => state === "disposed").length;
  if (apply) {
    return `APNs incident disposition completed: resolved=${resolved}, already_resolved=${disposed}, targets=${states.length}.`;
  }
  return `APNs incident disposition dry run: would_resolve=${ready}, already_resolved=${disposed}, targets=${states.length}.`;
}

/**
 * Default path is read-only. `--apply` can only resolve this manifest's active
 * provider failures after an exact metadata read and an exact expired-outbox
 * CAS. It never touches device registrations, Queue messages, event payloads,
 * or a non-expired outbox.
 */
export async function disposeHistoricalApnsEnvironmentIncidents(
  environment = process.env,
  {
    apply = false,
    fetchImpl = fetch,
    manifest = HISTORICAL_APNS_ENVIRONMENT_INCIDENTS,
    now = new Date(),
  } = {},
) {
  const current = normalizeNow(now);
  verifyDispositionManifest(manifest, current);
  verifyDispositionEnvironment(environment, { apply, manifest });
  const states = await readHistoricalIncidentStates(environment, { fetchImpl, manifest });
  assertNoUnexpectedTargetState(states);
  const readyTargets = manifest.targets.filter((_, index) => states[index] === "ready");
  const disposedTargets = manifest.targets.filter((_, index) => states[index] === "disposed");

  if (!apply || readyTargets.length === 0) {
    return { apply, states, initialStates: states, resolved: 0 };
  }

  const results = await queryD1(
    environment,
    {
      batch: [
        allTargetsResolveStatement(
          readyTargets,
          disposedTargets,
          current.toISOString(),
        ),
      ],
    },
    { fetchImpl, manifest },
  );
  if (
    results.length !== 1 ||
    changedRowCount(results[0]) !== readyTargets.length
  ) {
    fail("APNs incident disposition compare-and-set did not match every approved target.");
  }

  const finalStates = await readHistoricalIncidentStates(environment, { fetchImpl, manifest });
  if (finalStates.some((state) => state !== "disposed")) {
    fail("APNs incident disposition postcondition did not confirm every approved target.");
  }
  return {
    apply,
    states: finalStates,
    initialStates: states,
    resolved: readyTargets.length,
  };
}

async function main() {
  try {
    const { apply } = parseDispositionArguments();
    const result = await disposeHistoricalApnsEnvironmentIncidents(process.env, { apply });
    console.log(dispositionSummary(result));
  } catch {
    // Keep workflow logs free of account IDs, D1 response bodies, API tokens,
    // and target identifiers even if an upstream service returns them.
    console.error("::error::APNs incident disposition did not complete; no unverified record was modified.");
    process.exitCode = 1;
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await main();
}
