import assert from "node:assert/strict";
import test from "node:test";

import {
  HISTORICAL_APNS_ENVIRONMENT_INCIDENTS,
  classifyHistoricalIncidentTarget,
  disposeHistoricalApnsEnvironmentIncidents,
  dispositionSummary,
  parseDispositionArguments,
  allTargetsResolveStatement,
  verifyDispositionEnvironment,
  verifyDispositionManifest,
} from "./dispose-historical-apns-environment-incidents.mjs";

const fixedNow = new Date("2026-08-14T06:00:00.000Z");
const environment = {
  CLOUDFLARE_ACCOUNT_ID: HISTORICAL_APNS_ENVIRONMENT_INCIDENTS.accountId,
  CLOUDFLARE_D1_INCIDENT_DISPOSITION_API_TOKEN: "test-secret-token",
  GITHUB_ACTIONS: "true",
  GITHUB_REF: "refs/heads/main",
  GITHUB_REF_PROTECTED: "true",
};

function activeRow(target) {
  return {
    outbox_id: target.outboxId,
    expires_at_utc: target.expiresAtUtc,
    acknowledged_at_utc: target.acknowledgedAtUtc,
    terminal_reason: "expired",
    final_status: null,
    queue_lease_until_utc: null,
    outbox_delivery_id: "delivery-id",
    outbox_root_delivery_id: "root-delivery-id",
    outbox_event_ref: target.eventRef,
    outbox_event_serial: target.eventSerial,
    outbox_notification_reason: target.notificationReason,
    failure_status: "active",
    apns_status: 403,
    apns_reason: target.apnsReason,
    failure_delivery_id: "delivery-id",
    failure_root_delivery_id: "root-delivery-id",
    failure_event_ref: target.eventRef,
    failure_source_id: target.sourceId,
    failure_event_serial: target.eventSerial,
    failure_notification_reason: target.notificationReason,
    first_seen_utc: target.firstSeenUtc,
    last_seen_utc: target.lastSeenUtc,
    occurrences: target.occurrences,
    resolved_at_utc: null,
  };
}

function disposedRow(target) {
  return {
    ...activeRow(target),
    failure_status: "resolved",
    resolved_at_utc: "2026-08-14T04:00:00.000Z",
  };
}

function queryResult(rows, changes) {
  return {
    success: true,
    result: rows.map((row, index) => ({
      success: true,
      results: row ? [row] : [],
      meta: { changes: changes?.[index] ?? 0 },
    })),
  };
}

function createFetch({ initialRows, writeChanges = [], finalRows = initialRows }) {
  const calls = [];
  let readCount = 0;
  const fetchImpl = async (url, init) => {
    calls.push({ url, init });
    const body = JSON.parse(init.body);
    assert.ok(Array.isArray(body.batch));
    const isRead = body.batch[0].sql.includes("SELECT\n            o.id AS outbox_id");
    if (isRead) {
      const rows = readCount++ === 0 ? initialRows : finalRows;
      return { ok: true, json: async () => queryResult(rows) };
    }
    return {
      ok: true,
      json: async () => queryResult(body.batch.map(() => ({})), writeChanges),
    };
  };
  return { fetchImpl, calls };
}

test("argument and environment guards fail closed outside the protected workflow", () => {
  assert.deepEqual(parseDispositionArguments([]), { apply: false });
  assert.deepEqual(parseDispositionArguments(["--apply"]), { apply: true });
  assert.throws(() => parseDispositionArguments(["--dry-run"]), /Usage/);
  assert.throws(
    () => verifyDispositionEnvironment({ ...environment, GITHUB_REF: "refs/heads/codex/test" }, { apply: true }),
    /restricted to protected main/i,
  );
  assert.throws(
    () => verifyDispositionEnvironment({ ...environment, CLOUDFLARE_ACCOUNT_ID: "b".repeat(32) }),
    /refuses a non-production Cloudflare account/i,
  );
});

test("manifest is fixed, expired, and rejects broad or future target edits", () => {
  assert.equal(verifyDispositionManifest(HISTORICAL_APNS_ENVIRONMENT_INCIDENTS, fixedNow).targets.length, 5);
  assert.throws(
    () => verifyDispositionManifest({ ...HISTORICAL_APNS_ENVIRONMENT_INCIDENTS, targets: [] }, fixedNow),
    /fixed targets/i,
  );
  assert.throws(
    () => verifyDispositionManifest({
      ...HISTORICAL_APNS_ENVIRONMENT_INCIDENTS,
      targets: [{ ...HISTORICAL_APNS_ENVIRONMENT_INCIDENTS.targets[0], expiresAtUtc: "2030-01-01T00:00:00.000Z" }],
    }, fixedNow),
    /expired historical evidence/i,
  );
});

test("dry run reads only metadata and never issues a D1 write", async () => {
  const rows = HISTORICAL_APNS_ENVIRONMENT_INCIDENTS.targets.map(activeRow);
  const { fetchImpl, calls } = createFetch({ initialRows: rows });
  const result = await disposeHistoricalApnsEnvironmentIncidents(environment, {
    fetchImpl,
    now: fixedNow,
  });
  assert.deepEqual(result, {
    apply: false,
    states: ["ready", "ready", "ready", "ready", "ready"],
    initialStates: ["ready", "ready", "ready", "ready", "ready"],
    resolved: 0,
  });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].init.method, "POST");
  assert.equal(calls[0].init.redirect, "error");
  assert.equal(calls[0].init.cache, "no-store");
  assert.ok(calls[0].init.signal);
  assert.match(calls[0].url, /\/d1\/database\//);
  assert.equal(dispositionSummary(result), "APNs incident disposition dry run: would_resolve=5, already_resolved=0, targets=5.");
});

test("apply resolves only exact active provider failures after an expired-outbox fence", async () => {
  const initialRows = HISTORICAL_APNS_ENVIRONMENT_INCIDENTS.targets.map(activeRow);
  const finalRows = HISTORICAL_APNS_ENVIRONMENT_INCIDENTS.targets.map(disposedRow);
  const { fetchImpl, calls } = createFetch({
    initialRows,
    finalRows,
    writeChanges: [5],
  });
  const result = await disposeHistoricalApnsEnvironmentIncidents(environment, {
    apply: true,
    fetchImpl,
    now: fixedNow,
  });
  assert.equal(result.resolved, 5);
  assert.deepEqual(result.states, ["disposed", "disposed", "disposed", "disposed", "disposed"]);
  assert.equal(calls.length, 3);
  const write = JSON.parse(calls[1].init.body);
  assert.equal(write.batch.length, 1);
  const [statement] = write.batch;
  assert.doesNotMatch(statement.sql, /UPDATE\s+alert_delivery_outbox/i);
  assert.match(statement.sql, /SELECT COUNT\(\*\)/);
  assert.match(statement.sql, /terminal_reason = 'expired'/);
  assert.match(statement.sql, /final_status IS NULL/);
  assert.match(statement.sql, /queue_lease_until_utc IS NULL/);
  assert.match(statement.sql, /apns_status = 403/);
  assert.match(statement.sql, /resolved_at_utc IS NULL/);
  assert.match(statement.sql, /delivery_id = p\.delivery_id/);
  assert.equal(dispositionSummary(result), "APNs incident disposition completed: resolved=5, already_resolved=0, targets=5.");
});

test("state drift fails before any write and exposes no target or token in its error", async () => {
  const rows = HISTORICAL_APNS_ENVIRONMENT_INCIDENTS.targets.map(activeRow);
  rows[1] = { ...rows[1], occurrences: rows[1].occurrences + 1 };
  const { fetchImpl, calls } = createFetch({ initialRows: rows });
  await assert.rejects(
    disposeHistoricalApnsEnvironmentIncidents(environment, {
      apply: true,
      fetchImpl,
      now: fixedNow,
    }),
    (error) => {
      assert.match(error.message, /target state changed/i);
      assert.doesNotMatch(error.message, /test-secret-token/);
      assert.doesNotMatch(error.message, /a18e7dc5/i);
      return true;
    },
  );
  assert.equal(calls.length, 1);
});

test("Cloudflare API failures are redacted and do not retry an incident request", async () => {
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push({ url, init });
    return {
      ok: false,
      json: async () => ({
        success: false,
        errors: [{ message: "test-secret-token raw-provider-error" }],
      }),
    };
  };
  await assert.rejects(
    disposeHistoricalApnsEnvironmentIncidents(environment, {
      fetchImpl,
      now: fixedNow,
    }),
    (error) => {
      assert.match(error.message, /request was rejected/i);
      assert.doesNotMatch(error.message, /test-secret-token|raw-provider-error/);
      return true;
    },
  );
  assert.equal(calls.length, 1);
});

test("a post-preflight target race makes the all-target CAS write zero rows", async () => {
  const initialRows = HISTORICAL_APNS_ENVIRONMENT_INCIDENTS.targets.map(activeRow);
  const { fetchImpl, calls } = createFetch({
    initialRows,
    writeChanges: [0],
  });
  await assert.rejects(
    disposeHistoricalApnsEnvironmentIncidents(environment, {
      apply: true,
      fetchImpl,
      now: fixedNow,
    }),
    /compare-and-set did not match every approved target/i,
  );
  assert.equal(calls.length, 2);
  const write = JSON.parse(calls[1].init.body);
  assert.equal(write.batch.length, 1);
  assert.match(write.batch[0].sql, /SELECT COUNT\(\*\)/);
});

test("an already disposed target remains part of the all-target race fence", async () => {
  const initialRows = HISTORICAL_APNS_ENVIRONMENT_INCIDENTS.targets.map(activeRow);
  initialRows[1] = disposedRow(HISTORICAL_APNS_ENVIRONMENT_INCIDENTS.targets[1]);
  const finalRows = HISTORICAL_APNS_ENVIRONMENT_INCIDENTS.targets.map(disposedRow);
  const { fetchImpl, calls } = createFetch({
    initialRows,
    finalRows,
    writeChanges: [4],
  });
  const result = await disposeHistoricalApnsEnvironmentIncidents(environment, {
    apply: true,
    fetchImpl,
    now: fixedNow,
  });
  assert.equal(result.resolved, 4);
  assert.deepEqual(result.initialStates, ["ready", "disposed", "ready", "ready", "ready"]);
  const write = JSON.parse(calls[1].init.body);
  assert.equal(write.batch.length, 1);
  assert.match(write.batch[0].sql, /candidate\.status = 'resolved'/);
  assert.match(write.batch[0].sql, /\) = \?/);
  assert.equal(write.batch[0].params.at(-1), HISTORICAL_APNS_ENVIRONMENT_INCIDENTS.targets.at(-1).acknowledgedAtUtc);
});

test("an already disposed target remains a read-only no-op", async () => {
  const rows = HISTORICAL_APNS_ENVIRONMENT_INCIDENTS.targets.map(disposedRow);
  const { fetchImpl, calls } = createFetch({ initialRows: rows });
  const result = await disposeHistoricalApnsEnvironmentIncidents(environment, {
    apply: true,
    fetchImpl,
    now: fixedNow,
  });
  assert.deepEqual(result, {
    apply: true,
    states: ["disposed", "disposed", "disposed", "disposed", "disposed"],
    initialStates: ["disposed", "disposed", "disposed", "disposed", "disposed"],
    resolved: 0,
  });
  assert.equal(calls.length, 1);
});

test("target comparison binds the page-failure row to the exact expired outbox", () => {
  const target = HISTORICAL_APNS_ENVIRONMENT_INCIDENTS.targets[0];
  assert.equal(classifyHistoricalIncidentTarget(target, activeRow(target)), "ready");
  assert.equal(
    classifyHistoricalIncidentTarget(target, { ...activeRow(target), queue_lease_until_utc: "2026-08-14T04:30:00.000Z" }),
    "mismatch",
  );
  const statement = allTargetsResolveStatement([target], [], fixedNow.toISOString());
  assert.equal(statement.params.at(-2), target.expiresAtUtc);
  assert.equal(statement.params.at(-1), target.acknowledgedAtUtc);
  assert.match(statement.sql, /acknowledged_at_utc = \?/);
});
