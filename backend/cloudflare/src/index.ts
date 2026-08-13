import {
  extractEqlistEntries,
  normalizeCencCqEew,
  normalizeCencEqlistEntry,
  normalizeJmaEew,
  normalizeJmaEqlistEntry,
  normalizeScFjEew,
} from "../../src/alerts/normalize";
import type {
  DeviceRecord,
  NormalizedEvent,
  NotifyReason,
} from "../../src/types/domain";
import {
  ALL_WOLFX_SOURCES,
  isHeartbeat,
  isPong,
  type CencCqEewMessage,
  type CencEqlistEntry,
  type JmaEewMessage,
  type JmaEqlistEntry,
  type ScFjEewMessage,
  type WolfxEqlistMessage,
  type WolfxSourceId,
} from "../../src/types/wolfx";
import {
  APP_ATTEST_CHALLENGE_ID_HEADER,
  APP_ATTEST_CHALLENGE_TTL_MS,
  APP_ATTEST_DEVELOPMENT_BYPASS_HEADER,
  APP_ATTEST_KEY_ID_HEADER,
  APP_ATTEST_PROOF_HEADER,
  APP_ATTEST_PROOF_TYPE_HEADER,
  APP_ATTEST_PROTOCOL_VERSION,
  APP_ATTEST_VERSION_HEADER,
  AppAttestValidationError,
  appAttestBodySha256,
  canonicalizeAppAttestKeyId,
  isCanonicalSha256Base64Url,
  type AppAttestChallengeBinding,
  type AppAttestEnvironment,
  type AppAttestOperation,
  type AppAttestProofType,
  type StoredAppAttestKey,
  verifyAppAttestProof,
} from "./app-attest";

// Kept as a named export for focused local policy tests. The Worker itself
// always calls `verifyAppAttestProof`, which applies this same policy.
export { appAttestAllowedValidationCategories } from "./app-attest";

/**
 * Queue names are explicit non-secret Worker variables so an isolated staging
 * Worker can consume only its own queues. They intentionally remain optional
 * here to support an already-deployed legacy Worker that has neither variable.
 */
export interface AlertDeliveryQueueNameEnvironment {
  ALERT_DELIVERY_QUEUE_NAME?: string;
  ALERT_DELIVERY_DLQ_NAME?: string;
  /**
   * Terminal evidence queue for a DLQ message whose D1 incident write keeps
   * failing. This queue intentionally has no consumer; Cloudflare Queue
   * metrics must be monitored externally so an operator can intervene before
   * its bounded Queue retention ends. `/healthz` reports only the preceding
   * Durable Object fallback marker, never inferred Queue depth.
   */
  ALERT_DELIVERY_DLQ_FALLBACK_NAME?: string;
}

interface Env extends AlertDeliveryQueueNameEnvironment {
  DB: D1Database;
  RELAY: DurableObjectNamespace;
  /**
   * A deliberately narrow per-App-Attest-key scheduler. It stores no APNs
   * token and gives an internal TestFlight tester time to background, lock, or
   * terminate the app before one reviewed training notification is attempted.
   */
  TRAINING_PUSH_SCHEDULER: DurableObjectNamespace;
  ALERT_DELIVERY_QUEUE: Queue<AlertDeliveryMessage>;
  DEVICE_API_RATE_LIMIT: RateLimit;
  DEVICE_MUTATION_RATE_LIMIT: RateLimit;
  /**
   * A route-wide pre-attestation budget. Its key never contains caller input,
   * so rotating a proposed App Attest key cannot create a fresh quota.
   */
  APP_ATTEST_CHALLENGE_RATE_LIMIT: RateLimit;
  APNS_PRIVATE_KEY?: string;
  APNS_KEY_ID?: string;
  APNS_TEAM_ID?: string;
  APNS_BUNDLE_ID?: string;
  ENABLE_PRODUCTION_TEST_PUSH?: string;
  /** Always `required` in the checked-in production Worker configuration. */
  APP_ATTEST_ENFORCEMENT?: string;
  /** Kept unset in production; may only enable an isolated local dev Worker. */
  APP_ATTEST_DEVELOPMENT_BYPASS?: string;
  /**
   * Accept Apple development AAGUIDs only alongside `APP_ATTEST_ENFORCEMENT`
   * set exactly to `development`. A production deployment treats this flag as
   * absent even if it is set by mistake.
   */
  APP_ATTEST_DEVELOPMENT_ENVIRONMENT?: string;
  APP_ATTEST_APP_ID?: string;
  APP_ATTEST_ALLOWED_BUNDLE_VERSIONS?: string;
  APP_ATTEST_REQUIRE_RELEASE_METADATA?: string;
}

interface EventRow {
  id: string;
  source_id: WolfxSourceId;
  event_id: string;
  serial: number;
  kind: "eew" | "report";
  origin_time_utc: string | null;
  report_time_utc: string | null;
  hypocenter: string | null;
  latitude: number | null;
  longitude: number | null;
  magnitude: number | null;
  depth: number | null;
  max_intensity: string | null;
  is_warn: number;
  is_final: number;
  is_cancel: number;
  is_training: number;
  tsunami: string | null;
  raw_json: string | null;
}

interface DeviceRow {
  cursor?: number;
  token: string;
  environment: "sandbox" | "production";
  locale: string | null;
  sources: string;
  min_magnitude: number;
  critical_alerts_enabled: number;
  city_name: string | null;
  latitude: number | null;
  longitude: number | null;
  radius_km: number | null;
  include_test_alerts: number;
  utc_offset_minutes: number | null;
  notify_at_night: number;
  app_attest_key_id?: string | null;
  created_at: string;
  updated_at: string;
}

const HTTP_BASE = "https://api.wolfx.jp";
const EEW_SOURCES: WolfxSourceId[] = [
  "jma_eew",
  "sc_eew",
  "cenc_eew",
  "fj_eew",
  "cq_eew",
];
const UPSTREAM_ROUTES = ["all_eew", "cenc_eqlist", "jma_eqlist"] as const;
type UpstreamRoute = (typeof UPSTREAM_ROUTES)[number];
const SOURCE_LABEL: Record<string, string> = {
  jma_eew: "JMA",
  sc_eew: "Sichuan EQA",
  cenc_eew: "CENC",
  fj_eew: "Fujian EQA",
  cq_eew: "Chongqing EQA",
  cenc_eqlist: "CENC",
  jma_eqlist: "JMA",
};
const LOC_KEYS: Record<NotifyReason, { title: string; body: string }> = {
  new: { title: "eew.push.new.title", body: "eew.push.new.body" },
  updated: {
    title: "eew.push.updated.title",
    body: "eew.push.updated.body",
  },
  final: { title: "eew.push.final.title", body: "eew.push.final.body" },
  cancelled: {
    title: "eew.push.cancelled.title",
    body: "eew.push.cancelled.body",
  },
  report: {
    title: "quake.push.report.title",
    body: "quake.push.report.body",
  },
  training: {
    title: "eew.push.training.title",
    body: "eew.push.training.body",
  },
};

const APNS_MAX_CONCURRENT_DELIVERIES = 2;
// Keep one queue message comfortably below Workers' subrequest limits: a page
// has at most 20 APNs requests plus a small, fixed number of D1 operations.
const DEVICE_DELIVERY_PAGE_SIZE = 20;
const DEVICE_REGISTRATION_MAX_AGE_MS = 90 * 24 * 60 * 60_000;
const DELIVERY_DEDUP_RETENTION_MS = 14 * 24 * 60 * 60_000;
// A production training-push claim stores no APNs token or proof. Retain it
// only long enough for operational review and bounded cleanup after its UTC
// day has ended.
const PRODUCTION_TRAINING_TEST_PUSH_CLAIM_RETENTION_MS = 14 * 24 * 60 * 60_000;
// A fixed server-side delay prevents a client from choosing an arbitrary
// background job time. Ninety seconds is enough for a person to leave the
// foreground and lock or terminate the TestFlight app, while remaining a
// narrowly bounded, single-purpose operation.
const DELAYED_TRAINING_TEST_PUSH_DELAY_SECONDS = 90;
const DELAYED_TRAINING_TEST_PUSH_DELAY_MS =
  DELAYED_TRAINING_TEST_PUSH_DELAY_SECONDS * 1_000;
// An alarm can wake late after an infrastructure interruption. Cancel rather
// than deliver a stale training alert long after the tester left the app.
const DELAYED_TRAINING_TEST_PUSH_MAX_LATE_SECONDS = 30;
const DELAYED_TRAINING_TEST_PUSH_MAX_LATE_MS =
  DELAYED_TRAINING_TEST_PUSH_MAX_LATE_SECONDS * 1_000;
const DELAYED_TRAINING_TEST_PUSH_STORAGE_KEY =
  "delayed-training-test-push:v1";
const TRAINING_TEST_EVENT_ID = "test:0";
const DEVICE_PURGE_INTERVAL_MS = 24 * 60 * 60_000;
// Kept only long enough to import records written by the pre-D1 outbox
// implementation. New work is always persisted in D1 with its event write.
const LEGACY_PENDING_DELIVERY_PREFIX = "pending-delivery:";
const LAST_DEVICE_PURGE_KEY = "last-device-purge-ms";
const INITIAL_HTTP_SEED_COMPLETE_KEY = "initial-http-seed-complete";
const UPSTREAM_LAST_SUCCESS_PREFIX = "upstream-last-success-ms:";
const UPSTREAM_LAST_HTTP_SUCCESS_PREFIX = "upstream-last-http-success-ms:";
const UPSTREAM_HTTP_FINGERPRINT_PREFIX = "upstream-http-fingerprint:";
const PENDING_HTTP_SNAPSHOT_PREFIX = "pending-http-snapshot:";
// Initial baseline snapshots advance one source at a time, so their cursor is
// durable. Recovery instead uses a single next-sweep deadline; persisting a
// source cursor for every poll would exhaust the Durable Objects Free write
// allowance during a prolonged upstream outage.
const HTTP_SEED_SOURCE_CURSOR_KEY = "http-seed-source-cursor";
const UPSTREAM_RECONNECT_FAILURE_PREFIX = "upstream-reconnect-failures:";
const UPSTREAM_RECONNECT_NOT_BEFORE_PREFIX = "upstream-reconnect-not-before-ms:";
const UPSTREAM_DEGRADED_SINCE_PREFIX = "upstream-degraded-since-ms:";
// This timestamp paces the one-source initial baseline only. Recovery timing
// has its own once-per-sweep deadline, rather than a write per source poll.
const LAST_HTTP_SEED_MS_KEY = "last-http-seed-ms";
const HTTP_FALLBACK_ACTIVE_KEY = "http-fallback-active";
// Pre-sweep revisions used these records as ownership leases. New code never
// mutates them, but reads them during a rolling deploy so an old in-flight
// fallback turn can finish before the low-write cadence takes over.
const LEGACY_HTTP_SEED_LEASE_UNTIL_KEY = "http-seed-lease-until-ms";
const HTTP_SEED_LEASE_V2_KEY = "http-seed-lease-v2";
// Recovery is intentionally paced by one small durable scalar rather than a
// per-request lease/cursor. Keeping the next sweep time across eviction makes
// the one-minute Free-tier budget a hard cadence rather than a best effort.
const HTTP_FALLBACK_NEXT_SWEEP_AT_KEY = "http-fallback-next-sweep-at-ms";
// A journal entry is persisted before live WebSocket work touches D1. It
// survives a Durable Object restart and lets the next alarm retry a failed
// event write without pretending the upstream is healthy.
const PENDING_INGEST_PREFIX = "pending-ingest:";
const PENDING_INGEST_RETRY_DELAY_MS = 5_000;
// If a DLQ message cannot be written to D1, its sanitized incident evidence is
// first kept in global Durable Object storage. This prefix is deliberately
// separate from live-ingest journaling so recovery can finalize the outbox
// before any ordinary Queue replay.
const DLQ_PERSISTENCE_FALLBACK_PREFIX = "dlq-persistence-fallback:";
const DLQ_PERSISTENCE_FALLBACK_REPLAY_BATCH_SIZE = 50;
const OUTBOX_REPLAY_BATCH_SIZE = 50;
// A normal relay alarm also reconciles journals and runs fallback ingestion.
// Limiting routine Queue hand-off to eight rows leaves headroom below the
// Workers Free 50-internal-subrequest budget: each row needs a claim, Queue
// send, and hand-off write, plus the one outbox select. Follow-up alarms
// continue the ordered durable outbox without loss.
const ROUTINE_OUTBOX_FLUSH_BATCH_SIZE = 8;
// Claiming a row before Queue.send prevents concurrent relay requests from
// producing a fan-out storm. If a process dies before the Queue accepts the
// message, this short lease makes the hand-off recoverable.
const OUTBOX_ENQUEUE_CLAIM_LEASE_MS = 5 * 60_000;
// Once Queue.send has accepted a message, Queues owns bounded retries and DLQ
// routing. Keep the outbox quiet longer than the bounded primary and DLQ retry
// schedules; the DLQ consumer terminally finalizes the row, while this lease
// remains a last-resort recovery path if a Queue hand-off is lost before
// consumer delivery.
const OUTBOX_QUEUE_LEASE_MS = 72 * 60 * 60_000;
const OUTBOX_ENQUEUE_FAILURE_RETRY_MS = 60_000;
const OUTBOX_STALE_AFTER_MS = 2 * 60 * 60_000;
const UPSTREAM_STALE_AFTER_MS = 3 * 60_000;
// A live WebSocket relay can receive frequent heartbeats for seven sources.
// Checkpoint their already-confirmed freshness at most once a minute: the
// active Durable Object retains the exact in-memory timestamp, while the
// durable checkpoint remains comfortably inside the three-minute stale window
// after an eviction. This avoids consuming the Durable Objects Free daily
// write allowance merely by observing healthy upstream heartbeats.
const UPSTREAM_FRESHNESS_CHECKPOINT_INTERVAL_MS = 60_000;
const ROUTINE_RELAY_ALARM_DELAY_MS = 60_000;
// A Worker-origin 503 must not turn one upstream rejection into a tight
// reconnect/HTTP-seed loop. The first retry remains prompt for a transient
// transport blip; subsequent attempts back off per route and are persisted
// across Durable Object eviction.
const UPSTREAM_RECONNECT_INITIAL_DELAY_MS = 5_000;
const UPSTREAM_RECONNECT_MAX_DELAY_MS = 5 * 60_000;
const UPSTREAM_UPGRADE_TIMEOUT_MS = 10_000;
const HTTP_RECOVERY_SEED_GRACE_MS = 90_000;
// Wolfx does not publish a formal request quota for these feeds. During a
// sustained WebSocket outage, the relay makes one complete HTTP sweep per
// minute, starting individual source requests at least 600ms apart. This is
// intentionally an emergency, degraded transport—not client polling—and keeps
// alarm/storage writes well below the Durable Objects Free daily limit.
const HTTP_FALLBACK_SWEEP_INTERVAL_MS = 60_000;
const HTTP_FALLBACK_SOURCE_SPACING_MS = 600;
const HTTP_FALLBACK_FAILURE_RETRY_MS = 60_000;
// A changed report list is durable work, not ordinary polling. Resume its
// bounded D1 slices quickly enough to finish a 50-entry list inside the
// three-minute freshness window, while still avoiding a tight alarm loop.
const HTTP_SNAPSHOT_RESUME_INTERVAL_MS = 5_000;
// Initial snapshots give a new relay a durable baseline. They are intentionally
// retried much more slowly than the active emergency fallback: a partially
// unavailable HTTP feed must not turn ordinary startup into permanent polling
// while the preferred WebSocket transport is healthy.
const INITIAL_HTTP_SEED_RETRY_INTERVAL_MS = 5 * 60_000;
const HTTP_FALLBACK_RESPONSE_TIMEOUT_MS = 8_000;
const HTTP_FALLBACK_MAX_SNAPSHOT_BYTES = 256 * 1024;
// A complete sweep normally takes about 4.2s and is started once per minute.
// Three minutes allows scheduling jitter and one failed sweep while still
// failing closed promptly if HTTP recovery stops producing valid snapshots.
const HTTP_FALLBACK_STALE_AFTER_MS = 3 * 60_000;
// Persist HTTP freshness at most once per minute. That is comfortably inside
// the three-minute stale window and avoids a storage write for every unchanged
// source response in an otherwise healthy emergency sweep.
const HTTP_FRESHNESS_CHECKPOINT_INTERVAL_MS = 60_000;
const MAX_HTTP_SNAPSHOT_EVENTS = 50;
// A list snapshot can contain all fifty ranked reports. Keep a single Durable
// Object turn well below D1 Free's 50-query/subrequest budget even when a new
// report creates an outbox row and Queue hand-off. The remaining verified
// snapshot is durable DO work and resumes on the next paced alarm.
const HTTP_SNAPSHOT_INGEST_BATCH_SIZE = 8;
// A fallback-only alarm may hand off four pre-existing rows even if its one
// HTTP source is unchanged. Together with the worst eight-event snapshot
// slice this remains below the D1 Free per-invocation statement budget.
const HTTP_FALLBACK_OUTBOX_FLUSH_BATCH_SIZE = 4;
// A failed recovery slice must not escape `alarm()`: Durable Objects retry an
// uncaught alarm automatically, which can be sooner than our source cadence.
// Persist a short deferral so both the scheduler and any unexpected alarm
// delivery respect one bounded D1 retry pace.
const HTTP_FALLBACK_RETRY_NOT_BEFORE_KEY =
  "http-fallback-retry-not-before-ms";
// HTTP recovery must not turn a historical snapshot into a notification
// replay. It is only allowed to surface a fresh event/revision that arrived
// while a WebSocket route was unavailable.
const HTTP_RECOVERY_MAX_EVENT_AGE_MS = 10 * 60_000;
// This is only a Worker-side blast-radius limit. Edge rate limiting and App
// Attest verification remain mandatory external launch controls.
const MAX_DEVICE_REQUEST_BYTES = 8 * 1024;
const MAX_DEVICE_TOKEN_LENGTH = 512;
const MAX_DEVICE_TEXT_LENGTH = 120;
const DEVICE_RATE_LIMIT_WINDOW_SECONDS = 60;
const APP_ATTEST_APP_ID = "5TT564H883.com.quakesignal.app";
const APP_ATTEST_DEVELOPMENT_BYPASS_VALUE = "development-unsupported";
// APNs provider tokens are valid for up to one hour and Apple asks providers
// not to refresh them more often than every 20 minutes. This is an in-memory
// optimization only; a Durable Object restart simply creates one new token.
const APNS_JWT_CACHE_MAX_AGE_MS = 45 * 60_000;
const APNS_EXPIRATION_IMMEDIATE = "0";
// A hung provider connection must not consume one of the relay's deliberately
// small APNs concurrency slots indefinitely. The surrounding Queue retry path
// turns this into a durable page-level incident and bounded retry.
const APNS_REQUEST_TIMEOUT_MS = 20_000;
// Apple asks providers to wait at least 15 minutes before retrying a 5XX APNs
// response. Use the same conservative floor for 429 responses so a single
// throttled subscription cannot turn into a provider-side retry loop.
const APNS_TRANSIENT_RETRY_DELAY_SECONDS = 15 * 60;
const DEFAULT_QUEUE_RETRY_DELAY_SECONDS = 60;
const MAX_QUEUE_RETRY_DELAY_SECONDS = 24 * 60 * 60;
const DELIVERY_RETRY_DELAY_HEADER = "x-quakesignal-retry-delay-seconds";
const DEFAULT_ALERT_DELIVERY_QUEUE_NAME = "quakesignal-alert-delivery";
const DEFAULT_ALERT_DELIVERY_DLQ_NAME = "quakesignal-alert-delivery-dlq";
// The terminal evidence queue deliberately has no consumer. Cloudflare keeps
// messages in a consumerless DLQ for its bounded retention period; its Queue
// metrics are monitored externally. `/healthz` reports only the preceding
// Durable Object persistence marker, not Queue depth.
const DEFAULT_ALERT_DELIVERY_DLQ_FALLBACK_NAME =
  "quakesignal-alert-delivery-dlq-fallback";
// Cloudflare Queue names are 1–63 ASCII alphanumeric characters or dashes,
// and must start and end with an alphanumeric character.
const CLOUDFLARE_QUEUE_NAME_PATTERN = /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$/;
// Emergency alerts lose operational value quickly. Bound both their event
// timestamp lifetime and any source clock skew by the outbox creation time.
// Keep a real retry window after APNs' documented 15-minute 5XX retry floor.
// APNs still receives expiration=0, so this only bounds Worker/Queue work and
// never asks Apple to retain a stale emergency notification for an offline
// device.
const EEW_DELIVERY_TTL_MS = 30 * 60_000;
const REPORT_DELIVERY_TTL_MS = 60 * 60_000;

interface ApnsDeliveryResult {
  ok: boolean;
  apnsId: string | null;
  status?: number;
  apnsReason?: string | null;
  invalidationTimestampMs?: number | null;
  retryAfterSeconds?: number | null;
  /** An APNs 410/Unregistered response is the only deletion signal. */
  terminalUnregistration?: boolean;
  /** Never delete on a malformed 410 response without its safety timestamp. */
  unregistrationTimestampMissing?: boolean;
  /** A newer local registration superseded APNs' invalidation timestamp. */
  terminalResolved?: boolean;
  deactivated?: boolean;
}

interface PreparedDelivery {
  device: DeviceRecord;
  tokenHash: string;
}

/** A JSON-safe event snapshot. Raw upstream payloads never enter Queues. */
type QueuedEvent = Omit<NormalizedEvent, "raw">;

interface AlertDeliveryMessage {
  version: 1;
  /** Durable D1 outbox record that owns this Queue hand-off. */
  outboxId: string;
  deliveryId: string;
  /** Stable across every page of the same event revision. */
  rootDeliveryId: string;
  event: QueuedEvent;
  reason: NotifyReason;
  /** A persisted deadline prevents old emergency work from reaching APNs. */
  expiresAtUtc?: string;
  /** Human-readable policy recorded with the outbox row for incident review. */
  expiryPolicy?: AlertDeliveryExpiryPolicy;
  /** SQLite rowid cursor, deliberately not an APNs device token. */
  afterDeviceCursor?: number;
}

/**
 * Token-free subset of a DLQ message that is sufficient to create the D1
 * incident and terminalize its outbox row after D1 recovers. It intentionally
 * excludes the event snapshot/body, which is not needed for incident recovery.
 */
interface DlqIncidentEvidence {
  queueMessageId: string;
  queueAttempts: number;
  deliveryId: string | null;
  rootDeliveryId: string | null;
  eventId: string | null;
  sourceId: string | null;
  eventSerial: number | null;
  notificationReason: NotifyReason | null;
  outboxId: string | null;
}

/** Durable Object record retained until its D1 incident transaction commits. */
interface DlqPersistenceFallbackRecord {
  evidence: DlqIncidentEvidence;
  writeId: string;
  firstSeenUtc: string;
  lastSeenUtc: string;
}

type LegacyAlertDeliveryMessage = Omit<AlertDeliveryMessage, "outboxId">;

interface AlertOutboxRow {
  id: string;
  dedupe_key: string;
  delivery_id: string;
  root_delivery_id: string;
  event_ref: string;
  event_serial: number;
  event_json: string;
  notification_reason: NotifyReason;
  after_device_cursor: number | null;
  created_at_utc: string;
  expires_at_utc: string | null;
  expiry_policy: AlertDeliveryExpiryPolicy | null;
  terminal_reason: "delivered" | "dlq" | "expired" | "superseded" | null;
  acknowledged_at_utc: string | null;
  last_enqueued_at_utc: string | null;
  next_enqueue_at_utc: string | null;
  queue_lease_until_utc: string | null;
  final_status: "delivered" | "dlq" | null;
  enqueue_attempts: number;
}

interface OutboxDeliveryState {
  acknowledged_at_utc: string | null;
  created_at_utc: string;
  expires_at_utc: string | null;
  expiry_policy: AlertDeliveryExpiryPolicy | null;
  event_json: string;
  notification_reason: NotifyReason;
}

type AlertDeliveryExpiryPolicy =
  | "eew_30m"
  | "report_60m"
  | "training_30m"
  | "legacy_created_at";

type ApnsFailureDisposition =
  | "terminal"
  | "retry"
  | "quarantine"
  | "page_retry";

interface PendingIngestRecord {
  event: QueuedEvent;
  writeId: string;
}

/**
 * A validated HTTP snapshot can contain up to fifty ranked earthquake
 * reports. Persist its normalized, token-free work cursor in the relay so one
 * alarm invocation never tries to make all of the corresponding D1 calls.
 * `fingerprint` fences an older in-flight relay turn from advancing or
 * clearing a cursor that a later retry has already moved.
 */
interface PendingHttpSnapshotWork {
  version: 1;
  source: WolfxSourceId;
  mode: "initial" | "recovery";
  fingerprint: string;
  events: QueuedEvent[];
  nextIndex: number;
}

/**
 * Internal detail for a single HTTP source attempt. `snapshotWorkStarted`
 * lets the recovery sweep stop after the first D1-backed change, preserving
 * the whole-alarm D1 budget while unchanged sources remain cheap to poll.
 */
interface HttpSeedOutcome {
  completed: boolean;
  snapshotWorkStarted: boolean;
}

interface HttpSeedLease {
  ownerId: string;
  untilMs: number;
}

type DurableKeyValueStore = Pick<
  DurableObjectStorage,
  "get" | "put" | "delete"
>;

class MissingApnsConfigurationError extends Error {
  constructor() {
    super("APNs credentials are not configured");
  }
}

export class HttpSnapshotTimeoutError extends Error {
  constructor() {
    super("Wolfx HTTP snapshot timed out");
    this.name = "HttpSnapshotTimeoutError";
  }
}

export class HttpSnapshotBodyTooLargeError extends Error {
  constructor() {
    super("Wolfx HTTP snapshot exceeds the relay size limit");
    this.name = "HttpSnapshotBodyTooLargeError";
  }
}

export class WolfxUpgradeTimeoutError extends Error {
  constructor() {
    super("Wolfx WebSocket Upgrade timed out");
    this.name = "WolfxUpgradeTimeoutError";
  }
}

/** Internal sentinel: a bounded recovery turn has claimed its one D1 slice. */
class HttpRecoverySweepWorkStarted extends Error {}

/**
 * Bound the alternate transport so one stalled response cannot consume the
 * relay's single polling lane indefinitely. The timeout wins even when a
 * transport ignores abort; aborting also releases a normal fetch/body stream.
 */
export async function withHttpSnapshotTimeout<T>(
  operation: (signal: AbortSignal) => Promise<T>,
  timeoutMs = HTTP_FALLBACK_RESPONSE_TIMEOUT_MS,
): Promise<T> {
  const controller = new AbortController();
  let timeoutId: number | null = null;
  const timeout = new Promise<never>((_resolve, reject) => {
    timeoutId = setTimeout(() => {
      const error = new HttpSnapshotTimeoutError();
      // Reject first so a fetch/body reader that ignores abort cannot retain
      // the relay's sole polling lane indefinitely.
      reject(error);
      controller.abort(error);
    }, timeoutMs);
  });
  try {
    return await Promise.race([operation(controller.signal), timeout]);
  } finally {
    clearTimeout(timeoutId);
  }
}

/** Bound an outbound Upgrade so a black-holed connection becomes degraded. */
export async function withWolfxUpgradeTimeout<T>(
  operation: (signal: AbortSignal) => Promise<T>,
  timeoutMs = UPSTREAM_UPGRADE_TIMEOUT_MS,
): Promise<T> {
  const controller = new AbortController();
  let timeoutId: number | null = null;
  const timeout = new Promise<never>((_resolve, reject) => {
    timeoutId = setTimeout(() => {
      const error = new WolfxUpgradeTimeoutError();
      reject(error);
      controller.abort(error);
    }, timeoutMs);
  });
  try {
    return await Promise.race([operation(controller.signal), timeout]);
  } finally {
    clearTimeout(timeoutId);
  }
}

/** Read one trusted-format JSON snapshot without buffering an unlimited body. */
export async function readBoundedHttpSnapshotJson(
  response: Response,
  maxBytes = HTTP_FALLBACK_MAX_SNAPSHOT_BYTES,
): Promise<unknown> {
  const declaredLength = Number(response.headers.get("content-length"));
  if (Number.isFinite(declaredLength) && declaredLength > maxBytes) {
    await response.body?.cancel();
    throw new HttpSnapshotBodyTooLargeError();
  }
  if (!response.body) throw new SyntaxError("Wolfx HTTP snapshot has no body");
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (!value) continue;
      total += value.byteLength;
      if (total > maxBytes) {
        await reader.cancel();
        throw new HttpSnapshotBodyTooLargeError();
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return JSON.parse(new TextDecoder().decode(bytes));
}

export interface DeliveryReadinessInput {
  apnsConfigured: boolean;
  activeDlqIncidents: number | null;
  /**
   * A true value means the DLQ consumer could not write D1 but did durably
   * preserve sanitized incident evidence in Durable Object storage. It stays
   * set until the relay atomically replays the record into D1.
   */
  pendingDlqPersistenceFallbacks: boolean | null;
  activePageFailures: number | null;
  activeQuarantinedFailures: number | null;
  activeRetryFailures: number | null;
  pendingOutboxRows: number | null;
  staleOutboxRows: number | null;
}

interface DeliveryHealth extends DeliveryReadinessInput {
  status: "ready" | "not_configured" | "degraded";
}

/**
 * Keep the readiness policy pure so a durable DLQ-persistence fallback marker
 * cannot be accidentally treated as an informational metric. An unreadable
 * marker store is also degraded: otherwise an outage in the only D1-independent
 * evidence path could look healthy precisely when operators need to intervene.
 */
export function deliveryReadinessStatus(
  input: DeliveryReadinessInput,
): DeliveryHealth["status"] {
  if (
    input.activeDlqIncidents === null ||
    input.activeDlqIncidents > 0 ||
    input.pendingDlqPersistenceFallbacks === null ||
    input.pendingDlqPersistenceFallbacks ||
    input.activePageFailures === null ||
    input.activePageFailures > 0 ||
    input.activeQuarantinedFailures === null ||
    input.activeQuarantinedFailures > 0 ||
    input.activeRetryFailures === null ||
    input.activeRetryFailures > 0 ||
    input.pendingOutboxRows === null ||
    input.staleOutboxRows === null ||
    input.staleOutboxRows > 0
  ) {
    return "degraded";
  }
  return input.apnsConfigured ? "ready" : "not_configured";
}

function json(
  value: unknown,
  status = 200,
  headers: Record<string, string> = {},
): Response {
  return Response.json(value, {
    status,
    headers,
  });
}

function noStoreHeaders(headers: Record<string, string> = {}): Record<string, string> {
  return { "cache-control": "no-store", ...headers };
}

export interface ProductionTrainingTestPushWindow {
  /** ISO calendar day in UTC; this, not the client clock, scopes the claim. */
  utcDay: string;
  /** The first instant where a new production training-push claim is valid. */
  resetAtUtc: string;
  /** HTTP Retry-After value rounded up to the next UTC-day boundary. */
  retryAfterSeconds: number;
  /** Bounded operational retention for the token-free D1 claim record. */
  expiresAtUtc: string;
}

/**
 * Derive the production training-push limit entirely from Worker time. A
 * client cannot move the UTC-day boundary by supplying its own timestamp.
 */
export function productionTrainingTestPushWindow(
  now = new Date(),
): ProductionTrainingTestPushWindow {
  const nowMs = now.getTime();
  if (!Number.isFinite(nowMs)) {
    throw new TypeError("production training push requires a valid current time");
  }
  const startOfDayMs = Date.UTC(
    now.getUTCFullYear(),
    now.getUTCMonth(),
    now.getUTCDate(),
  );
  const nextDayMs = startOfDayMs + 24 * 60 * 60_000;
  return {
    utcDay: new Date(startOfDayMs).toISOString().slice(0, 10),
    resetAtUtc: new Date(nextDayMs).toISOString(),
    retryAfterSeconds: Math.max(1, Math.ceil((nextDayMs - nowMs) / 1_000)),
    expiresAtUtc: new Date(
      nowMs + PRODUCTION_TRAINING_TEST_PUSH_CLAIM_RETENTION_MS,
    ).toISOString(),
  };
}

export function productionTrainingTestPushLimitResponse(
  window: ProductionTrainingTestPushWindow,
): Response {
  return json(
    {
      error: "production training test push limit reached; try again after the next UTC day begins",
      retryAtUtc: window.resetAtUtc,
    },
    429,
    noStoreHeaders({ "retry-after": String(window.retryAfterSeconds) }),
  );
}

export interface AlertDeliveryQueueNames {
  /** Name of the Queue that receives transactional-outbox delivery pages. */
  primary: string;
  /** Name of the Queue that records terminal delivery incidents. */
  deadLetter: string;
  /**
   * Consumerless terminal evidence Queue used only when the DLQ consumer
   * cannot commit its sanitized D1 incident after its bounded retry budget.
   */
  persistenceFallback: string;
}

function validatedAlertDeliveryQueueName(
  value: unknown,
  variableName:
    | "ALERT_DELIVERY_QUEUE_NAME"
    | "ALERT_DELIVERY_DLQ_NAME"
    | "ALERT_DELIVERY_DLQ_FALLBACK_NAME",
): string {
  if (
    typeof value !== "string" ||
    !CLOUDFLARE_QUEUE_NAME_PATTERN.test(value)
  ) {
    throw new TypeError(
      `${variableName} must be a 1–63 character Cloudflare Queue name containing only ASCII letters, digits, and internal dashes`,
    );
  }
  return value;
}

/**
 * Resolve the Queue names delivered by Cloudflare's `MessageBatch.queue`.
 *
 * A Worker installed before these variables existed can leave all three unset
 * and retains the established production names. Any named environment that
 * overrides one must override all three: silently combining a staging primary
 * Queue with a production DLQ or terminal evidence Queue could acknowledge or
 * strand evidence in the wrong service.
 */
export function resolveAlertDeliveryQueueNames(
  env: Readonly<AlertDeliveryQueueNameEnvironment>,
): AlertDeliveryQueueNames {
  const primaryOverride = env.ALERT_DELIVERY_QUEUE_NAME;
  const deadLetterOverride = env.ALERT_DELIVERY_DLQ_NAME;
  const persistenceFallbackOverride = env.ALERT_DELIVERY_DLQ_FALLBACK_NAME;
  if (
    primaryOverride === undefined &&
    deadLetterOverride === undefined &&
    persistenceFallbackOverride === undefined
  ) {
    return {
      primary: DEFAULT_ALERT_DELIVERY_QUEUE_NAME,
      deadLetter: DEFAULT_ALERT_DELIVERY_DLQ_NAME,
      persistenceFallback: DEFAULT_ALERT_DELIVERY_DLQ_FALLBACK_NAME,
    };
  }
  if (
    primaryOverride === undefined ||
    deadLetterOverride === undefined ||
    persistenceFallbackOverride === undefined
  ) {
    throw new TypeError(
      "ALERT_DELIVERY_QUEUE_NAME, ALERT_DELIVERY_DLQ_NAME, and ALERT_DELIVERY_DLQ_FALLBACK_NAME must either all be unset or all name the configured queues",
    );
  }

  const primary = validatedAlertDeliveryQueueName(
    primaryOverride,
    "ALERT_DELIVERY_QUEUE_NAME",
  );
  const deadLetter = validatedAlertDeliveryQueueName(
    deadLetterOverride,
    "ALERT_DELIVERY_DLQ_NAME",
  );
  const persistenceFallback = validatedAlertDeliveryQueueName(
    persistenceFallbackOverride,
    "ALERT_DELIVERY_DLQ_FALLBACK_NAME",
  );
  if (new Set([primary, deadLetter, persistenceFallback]).size !== 3) {
    throw new TypeError(
      "ALERT_DELIVERY_QUEUE_NAME, ALERT_DELIVERY_DLQ_NAME, and ALERT_DELIVERY_DLQ_FALLBACK_NAME must name different queues",
    );
  }
  return { primary, deadLetter, persistenceFallback };
}

function isNotifyReason(value: unknown): value is NotifyReason {
  return typeof value === "string" && Object.hasOwn(LOC_KEYS, value);
}

function isAlertDeliveryExpiryPolicy(
  value: unknown,
): value is AlertDeliveryExpiryPolicy {
  return (
    value === "eew_30m" ||
    value === "report_60m" ||
    value === "training_30m" ||
    value === "legacy_created_at"
  );
}

function expiryPolicyForReason(
  reason: NotifyReason,
): { policy: AlertDeliveryExpiryPolicy; ttlMs: number } {
  switch (reason) {
    case "report":
    case "final":
      return { policy: "report_60m", ttlMs: REPORT_DELIVERY_TTL_MS };
    case "training":
      return { policy: "training_30m", ttlMs: EEW_DELIVERY_TTL_MS };
    case "new":
    case "updated":
    case "cancelled":
      return { policy: "eew_30m", ttlMs: EEW_DELIVERY_TTL_MS };
  }
}

/**
 * Calculate a deadline from the event's own time while preventing a malformed
 * or future-skewed source timestamp from extending delivery beyond the same
 * bounded lifetime after the durable outbox row was created.
 */
export function calculateAlertDeliveryExpiry(
  event: Pick<QueuedEvent, "reportTimeUtc" | "originTimeUtc">,
  reason: NotifyReason,
  createdAtUtc: string,
): { expiresAtUtc: string; expiryPolicy: AlertDeliveryExpiryPolicy } {
  const { policy, ttlMs } = expiryPolicyForReason(reason);
  const parsedCreatedAt = Date.parse(createdAtUtc);
  const createdAtMs = Number.isFinite(parsedCreatedAt)
    ? parsedCreatedAt
    : Date.now();
  // Prefer the report timestamp, but retain a valid origin timestamp when an
  // upstream payload carries a malformed report field. Only when neither is a
  // usable ISO date do we fall back to the durable creation-time cap.
  const parsedEventTime = [event.reportTimeUtc, event.originTimeUtc]
    .map((timestamp) => timestamp === null ? Number.NaN : Date.parse(timestamp))
    .find(Number.isFinite) ?? Number.NaN;
  // The created-at bound is deliberate: a source clock far in the future must
  // never keep a stale notification retrying after it has stopped being useful.
  const expiresAtMs = Number.isFinite(parsedEventTime)
    ? Math.min(parsedEventTime + ttlMs, createdAtMs + ttlMs)
    : createdAtMs + ttlMs;
  return { expiresAtUtc: new Date(expiresAtMs).toISOString(), expiryPolicy: policy };
}

/**
 * A current socket heartbeat is not enough to call the source ready: a live
 * event that has reached Durable Object storage but not D1 still has an
 * uncommitted alert decision. Keep readiness failed until that journal drains.
 */
export function isUpstreamSourceStale(
  status: string,
  lastSuccessMs: number | undefined,
  hasPendingLiveIngest: boolean,
  now = Date.now(),
): boolean {
  return (
    hasPendingLiveIngest ||
    status !== "open" ||
    !lastSuccessMs ||
    now - lastSuccessMs > UPSTREAM_STALE_AFTER_MS
  );
}

/**
 * Keep a close/error-triggered reconnect ahead of the routine relay alarm.
 * A startup seed can take long enough for an upstream socket to fail while it
 * is running, so a blind one-minute replacement would unnecessarily extend a
 * known alert-ingestion outage.
 */
export function preferredRelayAlarmAt(
  requestedAlarmAt: number | null,
  now = Date.now(),
): number {
  const routineAlarmAt = now + ROUTINE_RELAY_ALARM_DELAY_MS;
  return (
    typeof requestedAlarmAt === "number" &&
    Number.isFinite(requestedAlarmAt) &&
    requestedAlarmAt > now &&
    requestedAlarmAt < routineAlarmAt
  )
    ? requestedAlarmAt
    : routineAlarmAt;
}

/**
 * Compute a bounded, deterministic per-route reconnect delay. A stable jitter
 * prevents the three Wolfx routes from retrying in lockstep without making
 * outages non-reproducible in logs or tests.
 */
export function upstreamReconnectDelayMs(
  consecutiveFailures: number,
  route: string,
): number {
  const failures = Number.isSafeInteger(consecutiveFailures) &&
      consecutiveFailures > 0
    ? consecutiveFailures
    : 1;
  const unjittered = Math.min(
    UPSTREAM_RECONNECT_MAX_DELAY_MS,
    UPSTREAM_RECONNECT_INITIAL_DELAY_MS * 2 ** Math.min(failures - 1, 16),
  );
  let hash = 0;
  for (const character of route) {
    hash = (Math.imul(hash, 31) + character.charCodeAt(0)) >>> 0;
  }
  // ±20%, in one-tenth-percent increments. Round so alarm timestamps remain
  // integer milliseconds.
  const jitter = 0.8 + (hash % 401) / 1_000;
  return Math.min(
    UPSTREAM_RECONNECT_MAX_DELAY_MS,
    Math.round(unjittered * jitter),
  );
}

/**
 * Determine whether a complete alternate-transport sweep is due. The active
 * relay owns this cadence through its durable alarm; callers can also use it
 * with an in-memory timestamp when testing the one-minute policy.
 */
export function isHttpRecoverySeedDue(
  lastSeedMs: number | undefined,
  now = Date.now(),
): boolean {
  return (
    typeof lastSeedMs !== "number" ||
    !Number.isFinite(lastSeedMs) ||
    lastSeedMs > now ||
    now - lastSeedMs >= HTTP_FALLBACK_SWEEP_INTERVAL_MS
  );
}

function isInitialHttpSeedDue(
  lastSeedMs: number | undefined,
  now = Date.now(),
): boolean {
  return (
    typeof lastSeedMs !== "number" ||
    !Number.isFinite(lastSeedMs) ||
    lastSeedMs > now ||
    now - lastSeedMs >= INITIAL_HTTP_SEED_RETRY_INTERVAL_MS
  );
}

/**
 * HTTP success is a separate transport signal. It is useful only when a
 * valid snapshot has completed ingestion and no live event for the source is
 * waiting for its durable D1 write.
 */
export function isHttpFallbackSourceStale(
  lastHttpSuccessMs: number | undefined,
  hasPendingLiveIngest: boolean,
  now = Date.now(),
): boolean {
  return (
    hasPendingLiveIngest ||
    typeof lastHttpSuccessMs !== "number" ||
    !Number.isFinite(lastHttpSuccessMs) ||
    lastHttpSuccessMs > now ||
    now - lastHttpSuccessMs > HTTP_FALLBACK_STALE_AFTER_MS
  );
}

/**
 * Serialize alternate-transport requests so their start times are at least
 * `minimumSpacingMs` apart. The injected clock/sleeper make the policy easy
 * to test without making the test suite wait for a real HTTP sweep.
 */
export async function mapWithMinimumSpacing<T, Result>(
  values: readonly T[],
  minimumSpacingMs: number,
  mapper: (value: T, index: number) => Promise<Result>,
  now: () => number = Date.now,
  sleep: (milliseconds: number) => Promise<void> = (milliseconds) =>
    new Promise((resolve) => setTimeout(resolve, milliseconds)),
): Promise<Result[]> {
  if (!Number.isSafeInteger(minimumSpacingMs) || minimumSpacingMs < 0) {
    throw new RangeError("minimum spacing must be a non-negative safe integer");
  }
  const results: Result[] = [];
  let previousStartedAt: number | null = null;
  for (let index = 0; index < values.length; index += 1) {
    if (previousStartedAt !== null) {
      const waitMs = Math.max(0, minimumSpacingMs - (now() - previousStartedAt));
      if (waitMs > 0) await sleep(waitMs);
    }
    previousStartedAt = now();
    results.push(await mapper(values[index], index));
  }
  return results;
}

/**
 * Bound setup-time upstream work so the three long-lived watcher connections
 * retain room under the Workers/Durable Objects simultaneous-connection limit.
 * Results preserve source order, which keeps initial-seed completion policy
 * deterministic without starting every source request at once.
 */
export async function mapWithConcurrency<T, Result>(
  values: readonly T[],
  concurrency: number,
  mapper: (value: T, index: number) => Promise<Result>,
): Promise<Result[]> {
  if (!Number.isSafeInteger(concurrency) || concurrency < 1) {
    throw new RangeError("concurrency must be a positive safe integer");
  }
  const results = new Array<Result>(values.length);
  let nextIndex = 0;
  const workers = Array.from(
    { length: Math.min(concurrency, values.length) },
    async () => {
      while (nextIndex < values.length) {
        const index = nextIndex;
        nextIndex += 1;
        results[index] = await mapper(values[index], index);
      }
    },
  );
  await Promise.all(workers);
  return results;
}

function messageExpiry(
  message: Pick<AlertDeliveryMessage, "event" | "reason" | "expiresAtUtc" | "expiryPolicy">,
  createdAtUtc: string,
): { expiresAtUtc: string; expiryPolicy: AlertDeliveryExpiryPolicy } {
  if (
    typeof message.expiresAtUtc === "string" &&
    Number.isFinite(Date.parse(message.expiresAtUtc)) &&
    isAlertDeliveryExpiryPolicy(message.expiryPolicy)
  ) {
    return {
      expiresAtUtc: message.expiresAtUtc,
      expiryPolicy: message.expiryPolicy,
    };
  }
  return calculateAlertDeliveryExpiry(message.event, message.reason, createdAtUtc);
}

function isQueuedEvent(value: unknown): value is QueuedEvent {
  if (!value || typeof value !== "object") return false;
  const event = value as Partial<QueuedEvent>;
  return (
    typeof event.id === "string" &&
    typeof event.eventId === "string" &&
    typeof event.sourceId === "string" &&
    (ALL_WOLFX_SOURCES as string[]).includes(event.sourceId) &&
    typeof event.serial === "number" &&
    (event.kind === "eew" || event.kind === "report")
  );
}

function isPendingHttpSnapshotWork(
  value: unknown,
): value is PendingHttpSnapshotWork {
  if (!value || typeof value !== "object") return false;
  const work = value as Partial<PendingHttpSnapshotWork>;
  return (
    work.version === 1 &&
    typeof work.source === "string" &&
    (ALL_WOLFX_SOURCES as string[]).includes(work.source) &&
    (work.mode === "initial" || work.mode === "recovery") &&
    typeof work.fingerprint === "string" &&
    work.fingerprint.length > 0 &&
    Array.isArray(work.events) &&
    work.events.length > 0 &&
    work.events.length <= MAX_HTTP_SNAPSHOT_EVENTS &&
    work.events.every((event) => isQueuedEvent(event) && event.sourceId === work.source) &&
    typeof work.nextIndex === "number" &&
    Number.isSafeInteger(work.nextIndex) &&
    work.nextIndex >= 0 &&
    work.nextIndex <= work.events.length
  );
}

function httpSnapshotWorkStorageKey(source: WolfxSourceId): string {
  return `${PENDING_HTTP_SNAPSHOT_PREFIX}${source}`;
}

function legacyHttpSeedLeaseUntil(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value) && value > 0) {
    return value;
  }
  if (!value || typeof value !== "object") return null;
  const lease = value as Partial<HttpSeedLease>;
  return typeof lease.ownerId === "string" &&
      lease.ownerId.length > 0 &&
      typeof lease.untilMs === "number" &&
      Number.isFinite(lease.untilMs) &&
      lease.untilMs > 0
    ? lease.untilMs
    : null;
}

function snapshotEvent(event: NormalizedEvent): QueuedEvent {
  const { raw: _raw, ...queued } = event;
  return queued;
}

function isPendingIngestRecord(value: unknown): value is PendingIngestRecord {
  if (!value || typeof value !== "object") return false;
  const record = value as Partial<PendingIngestRecord>;
  return (
    typeof record.writeId === "string" &&
    record.writeId.length > 0 &&
    isQueuedEvent(record.event)
  );
}

function isAlertDeliveryMessage(value: unknown): value is AlertDeliveryMessage {
  if (!value || typeof value !== "object") return false;
  const message = value as Partial<AlertDeliveryMessage>;
  return (
    message.version === 1 &&
    typeof message.outboxId === "string" &&
    message.outboxId.length > 0 &&
    typeof message.deliveryId === "string" &&
    typeof message.rootDeliveryId === "string" &&
    isQueuedEvent(message.event) &&
    isNotifyReason(message.reason) &&
    (message.expiresAtUtc === undefined ||
      (typeof message.expiresAtUtc === "string" &&
        Number.isFinite(Date.parse(message.expiresAtUtc)))) &&
    (message.expiryPolicy === undefined ||
      isAlertDeliveryExpiryPolicy(message.expiryPolicy)) &&
    (message.afterDeviceCursor === undefined ||
      (typeof message.afterDeviceCursor === "number" &&
        Number.isSafeInteger(message.afterDeviceCursor) &&
        message.afterDeviceCursor >= 0))
  );
}

/** Accept only for one-way migration of messages queued before outboxId. */
function isLegacyAlertDeliveryMessage(
  value: unknown,
): value is LegacyAlertDeliveryMessage {
  if (!value || typeof value !== "object") return false;
  const message = value as Partial<LegacyAlertDeliveryMessage>;
  return (
    message.version === 1 &&
    typeof message.deliveryId === "string" &&
    typeof message.rootDeliveryId === "string" &&
    isQueuedEvent(message.event) &&
    isNotifyReason(message.reason) &&
    (message.expiresAtUtc === undefined ||
      (typeof message.expiresAtUtc === "string" &&
        Number.isFinite(Date.parse(message.expiresAtUtc)))) &&
    (message.expiryPolicy === undefined ||
      isAlertDeliveryExpiryPolicy(message.expiryPolicy)) &&
    (message.afterDeviceCursor === undefined ||
      (typeof message.afterDeviceCursor === "number" &&
        Number.isSafeInteger(message.afterDeviceCursor) &&
        message.afterDeviceCursor >= 0))
  );
}

function upgradeLegacyAlertDeliveryMessage(
  message: LegacyAlertDeliveryMessage,
): AlertDeliveryMessage {
  return {
    ...message,
    outboxId: crypto.randomUUID(),
  };
}

function createAlertDeliveryMessage(
  event: NormalizedEvent,
  reason: NotifyReason,
  afterDeviceCursor?: number,
  rootDeliveryId?: string,
  expiresAtUtc?: string,
  expiryPolicy?: AlertDeliveryExpiryPolicy,
): AlertDeliveryMessage {
  const { raw: _raw, ...eventSnapshot } = event;
  const deliveryId = `v1:${event.id}:${event.serial}:${reason}`;
  const expiry = messageExpiry(
    { event: eventSnapshot, reason, expiresAtUtc, expiryPolicy },
    new Date().toISOString(),
  );
  return {
    version: 1,
    outboxId: crypto.randomUUID(),
    // Serial distinguishes repeated EEW updates for the same event.
    deliveryId:
      afterDeviceCursor === undefined
        ? deliveryId
        : `${deliveryId}:page:${afterDeviceCursor}`,
    rootDeliveryId: rootDeliveryId ?? deliveryId,
    event: eventSnapshot,
    reason,
    ...expiry,
    ...(afterDeviceCursor === undefined ? {} : { afterDeviceCursor }),
  };
}

function eventFromDeliveryMessage(
  message: AlertDeliveryMessage,
): NormalizedEvent {
  return { ...message.event, raw: null };
}

function retryDelaySeconds(attempts: number): number {
  return Math.min(30 * 2 ** Math.min(attempts, 6), 30 * 60);
}

function retryDelaySecondsFromRelay(
  response: Response,
  attempts: number,
): number {
  const header = response.headers.get(DELIVERY_RETRY_DELAY_HEADER);
  if (header && /^\d+$/.test(header)) {
    const delay = Number(header);
    if (Number.isSafeInteger(delay) && delay > 0) {
      return Math.min(delay, MAX_QUEUE_RETRY_DELAY_SECONDS);
    }
  }
  return retryDelaySeconds(attempts);
}

/**
 * Derive the minimum incident record from a Queue message. Do not persist the
 * message body itself to the D1-independent fallback: even valid Queue bodies
 * include a normalized event snapshot that recovery does not need.
 */
function dlqIncidentEvidence(
  message: Pick<Message<unknown>, "id" | "attempts" | "body">,
): DlqIncidentEvidence {
  const queuedMessage = isAlertDeliveryMessage(message.body)
    ? message.body
    : null;
  return {
    queueMessageId: message.id,
    queueAttempts: message.attempts,
    deliveryId: queuedMessage?.deliveryId ?? null,
    rootDeliveryId: queuedMessage?.rootDeliveryId ?? null,
    eventId: queuedMessage?.event.eventId ?? null,
    sourceId: queuedMessage?.event.sourceId ?? null,
    eventSerial: queuedMessage?.event.serial ?? null,
    notificationReason: queuedMessage?.reason ?? null,
    outboxId: queuedMessage?.outboxId ?? null,
  };
}

function isNullableString(value: unknown): value is string | null {
  return value === null || typeof value === "string";
}

function isDlqIncidentEvidence(value: unknown): value is DlqIncidentEvidence {
  if (!value || typeof value !== "object") return false;
  const evidence = value as Partial<DlqIncidentEvidence>;
  return (
    typeof evidence.queueMessageId === "string" &&
    evidence.queueMessageId.length > 0 &&
    typeof evidence.queueAttempts === "number" &&
    Number.isSafeInteger(evidence.queueAttempts) &&
    evidence.queueAttempts > 0 &&
    isNullableString(evidence.deliveryId) &&
    isNullableString(evidence.rootDeliveryId) &&
    isNullableString(evidence.eventId) &&
    isNullableString(evidence.sourceId) &&
    (evidence.eventSerial === null ||
      (typeof evidence.eventSerial === "number" &&
        Number.isSafeInteger(evidence.eventSerial))) &&
    (evidence.notificationReason === null ||
      isNotifyReason(evidence.notificationReason)) &&
    isNullableString(evidence.outboxId)
  );
}

function isDlqPersistenceFallbackRecord(
  value: unknown,
): value is DlqPersistenceFallbackRecord {
  if (!value || typeof value !== "object") return false;
  const record = value as Partial<DlqPersistenceFallbackRecord>;
  return (
    isDlqIncidentEvidence(record.evidence) &&
    typeof record.writeId === "string" &&
    record.writeId.length > 0 &&
    typeof record.firstSeenUtc === "string" &&
    Number.isFinite(Date.parse(record.firstSeenUtc)) &&
    typeof record.lastSeenUtc === "string" &&
    Number.isFinite(Date.parse(record.lastSeenUtc))
  );
}

function dlqPersistenceFallbackStorageKey(queueMessageId: string): string {
  return `${DLQ_PERSISTENCE_FALLBACK_PREFIX}${encodeURIComponent(queueMessageId)}`;
}

function dlqIncidentStatement(
  db: D1Database,
  evidence: DlqIncidentEvidence,
  now: string,
): D1PreparedStatement {
  return db
    .prepare(
      `INSERT INTO alert_delivery_incidents (
        queue_message_id, delivery_id, root_delivery_id, event_id, source_id,
        event_serial, notification_reason, queue_attempts, status,
        first_seen_utc, last_seen_utc
      ) SELECT ?, ?, ?, ?, ?, ?, ?, ?, 'active', ?, ?
      WHERE ? IS NULL OR EXISTS (
        SELECT 1 FROM alert_delivery_outbox
        WHERE id = ?
          AND acknowledged_at_utc IS NOT NULL
          AND terminal_reason = 'dlq'
      )
      ON CONFLICT(queue_message_id) DO UPDATE SET
        queue_attempts = MAX(
          alert_delivery_incidents.queue_attempts,
          excluded.queue_attempts
        ),
        last_seen_utc = excluded.last_seen_utc`,
    )
    .bind(
      evidence.queueMessageId,
      evidence.deliveryId,
      evidence.rootDeliveryId,
      evidence.eventId,
      evidence.sourceId,
      evidence.eventSerial,
      evidence.notificationReason,
      evidence.queueAttempts,
      now,
      now,
      // A legacy DLQ message has no outbox ownership record, so retain its
      // token-free evidence. Current Queue messages may create or update an
      // incident only after this batch has terminalized their owned row as a
      // DLQ outcome; an old delivered/expired/superseded copy is a no-op.
      evidence.outboxId,
      evidence.outboxId,
    );
}

/**
 * A DLQ record and terminal outbox state must commit together. D1 runs a batch
 * sequentially in one transaction: first turn a still-live owned row into a
 * DLQ terminal state, then insert/upsert the incident only if that canonical
 * state exists. Consequently an at-least-once stale DLQ copy cannot create an
 * active incident after a successful delivery, expiry, or supersession.
 *
 * If D1 is unavailable, caller-owned Durable Object storage first retains this
 * token-free evidence; if it succeeds, a lease expiry can never resurrect the
 * failed primary message.
 */
async function persistDlqIncidentAndFinalizeOutbox(
  env: Env,
  evidence: DlqIncidentEvidence,
): Promise<boolean> {
  const now = new Date().toISOString();
  const statements: D1PreparedStatement[] = [];
  let incidentStatementIndex: number;
  if (evidence.outboxId !== null) {
    statements.push(
      env.DB
        .prepare(
          `UPDATE alert_delivery_outbox
           SET acknowledged_at_utc = COALESCE(acknowledged_at_utc, ?),
               final_status = COALESCE(final_status, 'dlq'),
               terminal_reason = COALESCE(terminal_reason, 'dlq'),
               queue_lease_until_utc = NULL
           WHERE id = ?
             AND acknowledged_at_utc IS NULL
             AND final_status IS NULL
             AND terminal_reason IS NULL`,
        )
        .bind(now, evidence.outboxId),
    );
    incidentStatementIndex = statements.length;
    statements.push(dlqIncidentStatement(env.DB, evidence, now));
    // The DLQ incident is the durable terminal health signal. Resolve its
    // transient page-failure counterpart in the same transaction so health
    // remains degraded for one clear, actionable reason rather than two. The
    // canonical DLQ predicate also prevents an old Queue copy from resolving
    // a still-actionable provider failure after another terminal outcome.
    statements.push(
      env.DB
        .prepare(
          `UPDATE alert_delivery_page_failures
           SET status = 'resolved', resolved_at_utc = ?
           WHERE outbox_id = ?
             AND status = 'active'
             AND EXISTS (
               SELECT 1 FROM alert_delivery_outbox
               WHERE id = ?
                 AND acknowledged_at_utc IS NOT NULL
                 AND terminal_reason = 'dlq'
             )`,
        )
        .bind(now, evidence.outboxId, evidence.outboxId),
    );
  } else {
    incidentStatementIndex = statements.length;
    statements.push(dlqIncidentStatement(env.DB, evidence, now));
  }
  const results = await env.DB.batch(statements);
  // `meta.changes` is zero only when an owned outbox was already terminal (or
  // no longer exists). The caller still acknowledges that stale Queue copy:
  // retrying it cannot make the already-final delivery more durable.
  return (results?.[incidentStatementIndex]?.meta.changes ?? 0) > 0;
}

function legalPage(
  title: string,
  summary: string,
  sections: Array<{ heading: string; body: string }>,
): Response {
  const content = sections
    .map(
      ({ heading, body }) =>
        `<section><h2>${heading}</h2><p>${body}</p></section>`,
    )
    .join("");
  return new Response(
    `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>${title} · QuakeSignal</title>
  <style>
    :root{color-scheme:light dark;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
    body{margin:0;background:#f2f2f7;color:#1c1c1e}
    main{max-width:720px;margin:0 auto;padding:64px 24px}
    header,section{background:#fff;border-radius:20px;padding:24px;margin:0 0 16px}
    .mark{display:inline-grid;place-items:center;width:48px;height:48px;border-radius:14px;background:#0e63c4;color:#fff;font-size:24px}
    h1{font-size:34px;margin:20px 0 8px}h2{font-size:19px}p{line-height:1.6;color:#54545a}
    a{color:#0e63c4}.meta{font-size:13px;color:#8e8e93}
    @media(prefers-color-scheme:dark){body{background:#000;color:#f2f2f7}header,section{background:#1c1c1e}p{color:#c7c7cc}}
  </style>
</head>
<body><main>
  <header><span class="mark">⌁</span><h1>${title}</h1><p>${summary}</p><p class="meta">QuakeSignal · Effective 12 August 2026</p></header>
  ${content}
  <section><h2>Contact</h2><p>For privacy, safety, or support questions, open an issue in the <a href="https://github.com/TastyHeadphones/QuakeSignal/issues">QuakeSignal GitHub repository</a>.</p></section>
</main></body></html>`,
    {
      headers: {
        "content-type": "text/html; charset=utf-8",
        "cache-control": "public, max-age=3600",
      },
    },
  );
}

function rowToEvent(row: EventRow): NormalizedEvent {
  return {
    id: row.id,
    sourceId: row.source_id,
    eventId: row.event_id,
    serial: row.serial,
    kind: row.kind,
    originTimeUtc: row.origin_time_utc,
    reportTimeUtc: row.report_time_utc,
    hypocenter: row.hypocenter ?? "",
    latitude: row.latitude,
    longitude: row.longitude,
    magnitude: row.magnitude,
    depth: row.depth,
    maxIntensity: row.max_intensity,
    isWarn: !!row.is_warn,
    isFinal: !!row.is_final,
    isCancel: !!row.is_cancel,
    isTraining: !!row.is_training,
    tsunami: row.tsunami,
    raw: row.raw_json ? JSON.parse(row.raw_json) : null,
  };
}

function rowToDevice(row: DeviceRow): DeviceRecord {
  return {
    token: row.token,
    environment: row.environment,
    locale: row.locale,
    sources: JSON.parse(row.sources) as WolfxSourceId[],
    minMagnitude: row.min_magnitude,
    // Critical Alerts are not approved for this public bundle. Keep legacy
    // storage readable, but never let a saved or forged preference enable it.
    criticalAlertsEnabled: false,
    cityName: row.city_name,
    latitude: row.latitude,
    longitude: row.longitude,
    radiusKm: row.radius_km,
    includeTestAlerts: !!row.include_test_alerts,
    utcOffsetMinutes: row.utc_offset_minutes,
    notifyAtNight: !!row.notify_at_night,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function normalizeMessages(
  sourceId: WolfxSourceId,
  message: unknown,
): NormalizedEvent[] {
  if (
    isHeartbeat(message) ||
    isPong(message) ||
    !message ||
    typeof message !== "object"
  ) {
    return [];
  }

  switch (sourceId) {
    case "jma_eew":
      return "EventID" in message
        ? [normalizeJmaEew(message as JmaEewMessage)]
        : [];
    case "sc_eew":
    case "fj_eew":
      return "EventID" in message
        ? [normalizeScFjEew(message as ScFjEewMessage, sourceId)]
        : [];
    case "cenc_eew":
    case "cq_eew":
      return "EventID" in message
        ? [normalizeCencCqEew(message as CencCqEewMessage, sourceId)]
        : [];
    case "cenc_eqlist":
      return extractEqlistEntries<CencEqlistEntry>(
        message as WolfxEqlistMessage,
      ).map(({ entry }) => normalizeCencEqlistEntry(entry));
    case "jma_eqlist":
      return extractEqlistEntries<JmaEqlistEntry>(
        message as WolfxEqlistMessage,
      ).map(({ entry }) => normalizeJmaEqlistEntry(entry));
  }
}

function isFiniteNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value);
}

function isNonEmptyText(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

function isNormalizableCoordinate(value: unknown): boolean {
  const number = typeof value === "string" ? Number(value) : value;
  return typeof number === "number" && Number.isFinite(number);
}

function hasValidNormalizedEventTimes(
  events: readonly NormalizedEvent[],
): boolean {
  return events.every((event) =>
    typeof event.originTimeUtc === "string" &&
    Number.isFinite(Date.parse(event.originTimeUtc)) &&
    typeof event.reportTimeUtc === "string" &&
    Number.isFinite(Date.parse(event.reportTimeUtc)) &&
    Number.isFinite(event.latitude) &&
    Number.isFinite(event.longitude) &&
    Number.isFinite(event.magnitude) &&
    typeof event.hypocenter === "string" &&
    event.hypocenter.trim().length > 0
  );
}

function isStructurallyValidEqlistEntry(
  sourceId: "cenc_eqlist" | "jma_eqlist",
  entry: unknown,
): boolean {
  if (!entry || typeof entry !== "object" || Array.isArray(entry)) return false;
  const value = entry as Record<string, unknown>;
  if (
    !isNonEmptyText(value.EventID) ||
    !isNonEmptyText(value.time) ||
    !isNonEmptyText(value.location) ||
    !isNonEmptyText(value.magnitude) ||
    !isNonEmptyText(value.latitude) ||
    !isNonEmptyText(value.longitude) ||
    !isNormalizableCoordinate(value.latitude) ||
    !isNormalizableCoordinate(value.longitude)
  ) {
    return false;
  }
  if (sourceId === "cenc_eqlist") {
    return (
      (value.type === "automatic" || value.type === "reviewed") &&
      isNonEmptyText(value.ReportTime) &&
      isNonEmptyText(value.placeName) &&
      isNonEmptyText(value.depth) &&
      isNonEmptyText(value.intensity)
    );
  }
  return (
    isNonEmptyText(value.Title) &&
    isNonEmptyText(value.time_full) &&
    isNonEmptyText(value.shindo) &&
    isNonEmptyText(value.depth) &&
    typeof value.info === "string"
  );
}

function isStructurallyValidEqlistSnapshot(
  sourceId: "cenc_eqlist" | "jma_eqlist",
  message: Record<string, unknown>,
  normalizedEvents: readonly NormalizedEvent[],
): boolean {
  if (!isNonEmptyText(message.md5) || normalizedEvents.length === 0) return false;
  const entries = extractEqlistEntries(message as WolfxEqlistMessage);
  const rankedKeys = Object.keys(message).filter((key) => key.startsWith("No"));
  if (
    entries.length !== normalizedEvents.length ||
    entries.length > MAX_HTTP_SNAPSHOT_EVENTS ||
    rankedKeys.length !== entries.length ||
    rankedKeys.some((key) => !/^No(?:[1-9]|[1-4]\d|50)$/.test(key)) ||
    entries.some(({ rank, entry }) =>
      !Number.isSafeInteger(rank) ||
      rank < 1 ||
      rank > MAX_HTTP_SNAPSHOT_EVENTS ||
      !isStructurallyValidEqlistEntry(sourceId, entry)
    )
  ) {
    return false;
  }
  return hasValidNormalizedEventTimes(normalizedEvents);
}

/**
 * A successful HTTP status alone is not enough to make alert transport ready.
 * Require the documented per-source shape and at least one normalized event.
 * Wolfx's current earthquake feeds retain their latest report rather than
 * publishing a documented empty/idle object, so an empty object fails closed.
 */
export function isStructurallyValidHttpSnapshot(
  sourceId: WolfxSourceId,
  message: unknown,
  normalizedEvents: readonly NormalizedEvent[],
): boolean {
  if (!message || typeof message !== "object" || Array.isArray(message)) {
    return false;
  }
  if (
    normalizedEvents.length === 0 ||
    new Set(normalizedEvents.map((event) => event.id)).size !== normalizedEvents.length ||
    normalizedEvents.some((event) =>
      event.sourceId !== sourceId ||
      typeof event.eventId !== "string" ||
      event.eventId.length === 0 ||
      !Number.isSafeInteger(event.serial) ||
      event.serial < 0
    )
  ) {
    return false;
  }

  if (EEW_SOURCES.includes(sourceId)) {
    if (normalizedEvents.length !== 1 || !hasValidNormalizedEventTimes(normalizedEvents)) {
      return false;
    }
    const value = message as Record<string, unknown>;
    const base =
      isNonEmptyText(value.EventID) &&
      isNonEmptyText(value.OriginTime) &&
      isFiniteNumber(value.Latitude) &&
      isFiniteNumber(value.Longitude);
    if (!base) return false;
    switch (sourceId) {
      case "jma_eew":
        return (
          Number.isSafeInteger(value.Serial) &&
          (value.Serial as number) >= 0 &&
          isNonEmptyText(value.AnnouncedTime) &&
          isNonEmptyText(value.Hypocenter) &&
          isFiniteNumber(value.Magunitude)
        );
      case "sc_eew":
      case "fj_eew":
        return (
          Number.isSafeInteger(value.ReportNum) &&
          (value.ReportNum as number) >= 0 &&
          isNonEmptyText(value.ReportTime) &&
          isNonEmptyText(value.HypoCenter) &&
          isFiniteNumber(value.Magunitude)
        );
      case "cenc_eew":
      case "cq_eew":
        return (
          Number.isSafeInteger(value.ReportNum) &&
          (value.ReportNum as number) >= 0 &&
          isNonEmptyText(value.ReportTime) &&
          isNonEmptyText(value.HypoCenter) &&
          isFiniteNumber(value.Magnitude)
        );
    }
  }

  if (sourceId !== "cenc_eqlist" && sourceId !== "jma_eqlist") return false;
  return isStructurallyValidEqlistSnapshot(
    sourceId,
    message as Record<string, unknown>,
    normalizedEvents,
  );
}

async function httpSnapshotFingerprint(message: unknown): Promise<string> {
  // `Response.json()` has already limited this to JSON-compatible data. A
  // fingerprint is persisted only after every normalized event has committed,
  // so a D1 failure cannot suppress a later retry of the same snapshot.
  return await sha256Hex(JSON.stringify(message));
}

function sourceFromMessage(message: unknown): WolfxSourceId | null {
  if (!message || typeof message !== "object" || !("type" in message)) {
    return null;
  }
  const type = (message as { type?: unknown }).type;
  return typeof type === "string" &&
    EEW_SOURCES.includes(type as WolfxSourceId)
    ? (type as WolfxSourceId)
    : null;
}

function determineReason(
  event: NormalizedEvent,
  previous: NormalizedEvent | null,
): NotifyReason | null {
  if (event.isTraining) return previous === null ? "training" : null;
  if (event.kind === "report") return previous === null ? "report" : null;
  if (event.isCancel) return previous?.isCancel ? null : "cancelled";
  if (previous === null) return "new";
  if (event.isFinal && !previous.isFinal) return "final";
  if (event.serial > previous.serial) return "updated";
  return null;
}

function isRecentHttpRecoveryEvent(event: NormalizedEvent): boolean {
  const timestamp = event.reportTimeUtc ?? event.originTimeUtc;
  if (!timestamp) return false;
  const eventMs = Date.parse(timestamp);
  if (Number.isNaN(eventMs)) return false;
  const ageMs = Date.now() - eventMs;
  // Allow modest source clock skew, but never replay an old HTTP history.
  return ageMs >= -60_000 && ageMs <= HTTP_RECOVERY_MAX_EVENT_AGE_MS;
}

async function getEvent(
  db: D1Database,
  id: string,
): Promise<NormalizedEvent | null> {
  const row = await db
    .prepare("SELECT * FROM events WHERE id = ?")
    .bind(id)
    .first<EventRow>();
  return row ? rowToEvent(row) : null;
}

function eventUpsertStatement(
  db: D1Database,
  event: NormalizedEvent,
  now: string,
): D1PreparedStatement {
  return db
    .prepare(
      `INSERT INTO events (
        id, source_id, event_id, serial, kind, origin_time_utc,
        report_time_utc, hypocenter, latitude, longitude, magnitude, depth,
        max_intensity, is_warn, is_final, is_cancel, is_training, tsunami,
        raw_json, first_seen_utc, last_updated_utc
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        serial = excluded.serial,
        origin_time_utc = excluded.origin_time_utc,
        report_time_utc = excluded.report_time_utc,
        hypocenter = excluded.hypocenter,
        latitude = excluded.latitude,
        longitude = excluded.longitude,
        magnitude = excluded.magnitude,
        depth = excluded.depth,
        max_intensity = excluded.max_intensity,
        is_warn = excluded.is_warn,
        is_final = excluded.is_final,
        is_cancel = excluded.is_cancel,
        is_training = excluded.is_training,
        tsunami = excluded.tsunami,
        raw_json = excluded.raw_json,
        last_updated_utc = excluded.last_updated_utc
      WHERE excluded.serial >= events.serial`,
    )
    .bind(
      event.id,
      event.sourceId,
      event.eventId,
      event.serial,
      event.kind,
      event.originTimeUtc,
      event.reportTimeUtc,
      event.hypocenter,
      event.latitude,
      event.longitude,
      event.magnitude,
      event.depth,
      event.maxIntensity,
      event.isWarn ? 1 : 0,
      event.isFinal ? 1 : 0,
      event.isCancel ? 1 : 0,
      event.isTraining ? 1 : 0,
      event.tsunami,
      null,
      now,
      now,
    );
}

export function outboxInsertStatement(
  db: D1Database,
  message: AlertDeliveryMessage,
  dedupeKey: string,
  now: string,
  nextEnqueueAtUtc = now,
): D1PreparedStatement {
  const expiry = messageExpiry(message, now);
  return db
    .prepare(
      `INSERT OR IGNORE INTO alert_delivery_outbox (
        id, dedupe_key, delivery_id, root_delivery_id, event_ref,
        event_serial, notification_reason, after_device_cursor, event_json,
        created_at_utc, next_enqueue_at_utc, expires_at_utc, expiry_policy
      ) SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
      WHERE NOT EXISTS (
        SELECT 1 FROM events
        WHERE id = ? AND serial > ?
      )`,
    )
    .bind(
      message.outboxId,
      dedupeKey,
      message.deliveryId,
      message.rootDeliveryId,
      message.event.id,
      message.event.serial,
      message.reason,
      message.afterDeviceCursor ?? null,
      JSON.stringify(message.event),
      now,
      nextEnqueueAtUtc,
      expiry.expiresAtUtc,
      expiry.expiryPolicy,
      // This runs after the guarded event upsert in the same D1 batch. A
      // concurrent newer revision can therefore make an old insert a no-op
      // rather than resurrecting stale emergency work.
      message.event.id,
      message.event.serial,
    );
}

/**
 * Terminalize one queued page only when D1 already contains a newer committed
 * revision of its event. This correlated update is the delivery-time serial
 * fence: a delayed Queue copy cannot send an old EEW revision after the newer
 * revision is durable.
 */
export function supersedeOutboxIfNewerRevisionStatement(
  db: D1Database,
  outboxId: string,
  now: string,
): D1PreparedStatement {
  return db
    .prepare(
      `UPDATE alert_delivery_outbox
       SET acknowledged_at_utc = COALESCE(acknowledged_at_utc, ?),
           terminal_reason = COALESCE(terminal_reason, 'superseded'),
           queue_lease_until_utc = NULL
       WHERE id = ?
         AND acknowledged_at_utc IS NULL
         AND final_status IS NULL
         AND EXISTS (
           SELECT 1 FROM events
           WHERE events.id = alert_delivery_outbox.event_ref
             AND events.serial > alert_delivery_outbox.event_serial
         )`,
    )
    .bind(now, outboxId);
}

/**
 * Once a newer event revision commits, retire every still-pending older page
 * in the same D1 batch. The delivery-time fence above protects Queue copies
 * that were already handed off before this transaction committed.
 */
function supersedeOlderOutboxRowsForEventStatement(
  db: D1Database,
  eventId: string,
  now: string,
): D1PreparedStatement {
  return db
    .prepare(
      `UPDATE alert_delivery_outbox
       SET acknowledged_at_utc = COALESCE(acknowledged_at_utc, ?),
           terminal_reason = COALESCE(terminal_reason, 'superseded'),
           queue_lease_until_utc = NULL
       WHERE event_ref = ?
         AND acknowledged_at_utc IS NULL
         AND final_status IS NULL
         AND EXISTS (
           SELECT 1 FROM events
           WHERE events.id = alert_delivery_outbox.event_ref
             AND events.serial > alert_delivery_outbox.event_serial
         )`,
    )
    .bind(now, eventId);
}

/**
 * Store an event revision and its initial Queue hand-off in the same D1
 * transaction. A crash can therefore leave either neither record or an
 * outbox record that is replayed until the Queue consumer acknowledges it;
 * it cannot leave a deduplicated event with no durable delivery work.
 */
async function persistEventAndOutbox(
  db: D1Database,
  event: NormalizedEvent,
  createMessage: (previous: NormalizedEvent | null) => AlertDeliveryMessage | null,
): Promise<{
  previous: NormalizedEvent | null;
  message: AlertDeliveryMessage | null;
}> {
  const previous = await getEvent(db, event.id);
  const message = createMessage(previous);
  const now = new Date().toISOString();
  const statements = [
    eventUpsertStatement(db, event, now),
    // Keep this after the guarded event upsert: D1 executes the batch in order
    // transactionally, so a newly committed revision retires its older pages
    // before this transaction is visible to a Queue consumer.
    supersedeOlderOutboxRowsForEventStatement(db, event.id, now),
  ];
  if (message) {
    // deliveryId is deterministic for an event revision/reason, so an
    // at-least-once upstream update reuses the same logical hand-off.
    statements.push(outboxInsertStatement(db, message, message.deliveryId, now));
  }
  await db.batch(statements);
  return { previous, message };
}

/**
 * Persist a small, already-validated HTTP snapshot slice with two D1 binding
 * calls: one read of the prior revisions and one atomic write batch. This is
 * intentionally separate from the live WebSocket path, whose one-event
 * journal gives tighter failure isolation. The HTTP alternate transport may
 * contain fifty report entries, so issuing a get+batch per entry would exceed
 * the Workers Free D1 invocation budget.
 */
async function persistHttpSnapshotEvents(
  db: D1Database,
  snapshots: readonly QueuedEvent[],
  mode: "initial" | "recovery",
): Promise<void> {
  if (snapshots.length === 0) return;
  if (snapshots.length > HTTP_SNAPSHOT_INGEST_BATCH_SIZE) {
    throw new RangeError("HTTP snapshot persistence slice exceeds its D1-safe bound");
  }
  const ids = snapshots.map((event) => event.id);
  if (new Set(ids).size !== ids.length) {
    throw new TypeError("HTTP snapshot persistence slice contains duplicate event IDs");
  }
  const placeholders = ids.map(() => "?").join(", ");
  const existing = await db
    .prepare(`SELECT * FROM events WHERE id IN (${placeholders})`)
    .bind(...ids)
    .all<EventRow>();
  const previousById = new Map(
    existing.results.map((row) => [row.id, rowToEvent(row)]),
  );
  const now = new Date().toISOString();
  const statements: D1PreparedStatement[] = [];
  for (const snapshot of snapshots) {
    const event: NormalizedEvent = { ...snapshot, raw: null };
    const previous = previousById.get(event.id) ?? null;
    const reason = determineReason(event, previous);
    const message =
      reason === null ||
        mode === "initial" ||
        (mode === "recovery" && !isRecentHttpRecoveryEvent(event))
        ? null
        : createAlertDeliveryMessage(event, reason);
    statements.push(
      eventUpsertStatement(db, event, now),
      supersedeOlderOutboxRowsForEventStatement(db, event.id, now),
    );
    if (message) {
      statements.push(outboxInsertStatement(db, message, message.deliveryId, now));
    }
  }
  await db.batch(statements);
}

async function appendOutbox(
  db: D1Database,
  message: AlertDeliveryMessage,
  dedupeKey: string,
  nextEnqueueAtUtc?: string,
): Promise<void> {
  const now = new Date().toISOString();
  await outboxInsertStatement(
    db,
    message,
    dedupeKey,
    now,
    nextEnqueueAtUtc ?? now,
  ).run();
}

function outboxRowToMessage(row: AlertOutboxRow): AlertDeliveryMessage | null {
  try {
    const event: unknown = JSON.parse(row.event_json);
    if (!isQueuedEvent(event) || !isNotifyReason(row.notification_reason)) {
      return null;
    }
    const expiry = messageExpiry(
      {
        event,
        reason: row.notification_reason,
        expiresAtUtc: row.expires_at_utc ?? undefined,
        expiryPolicy: row.expiry_policy ?? undefined,
      },
      row.created_at_utc,
    );
    const message: AlertDeliveryMessage = {
      version: 1,
      outboxId: row.id,
      deliveryId: row.delivery_id,
      rootDeliveryId: row.root_delivery_id,
      event,
      reason: row.notification_reason,
      ...expiry,
      ...(row.after_device_cursor === null
        ? {}
        : { afterDeviceCursor: row.after_device_cursor }),
    };
    return isAlertDeliveryMessage(message) ? message : null;
  } catch {
    return null;
  }
}

function isValidSources(value: unknown): value is WolfxSourceId[] {
  return (
    Array.isArray(value) &&
    value.length <= ALL_WOLFX_SOURCES.length &&
    new Set(value).size === value.length &&
    value.every(
      (source) =>
        typeof source === "string" &&
        (ALL_WOLFX_SOURCES as string[]).includes(source),
    )
  );
}

function haversineDistanceKm(
  lat1: number,
  lon1: number,
  lat2: number,
  lon2: number,
): number {
  const radians = (degrees: number) => (degrees * Math.PI) / 180;
  const dLat = radians(lat2 - lat1);
  const dLon = radians(lon2 - lon1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(radians(lat1)) *
      Math.cos(radians(lat2)) *
      Math.sin(dLon / 2) ** 2;
  return 6371 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

function isQuietHours(offsetMinutes: number): boolean {
  const local = new Date(Date.now() + offsetMinutes * 60_000);
  const hour = local.getUTCHours();
  return hour >= 22 || hour < 7;
}

function shouldNotify(
  device: DeviceRecord,
  event: NormalizedEvent,
  reason: NotifyReason,
): boolean {
  if (!device.sources.includes(event.sourceId)) return false;
  if (event.isTraining && !device.includeTestAlerts) return false;
  if ((event.magnitude ?? 0) < device.minMagnitude) return false;
  if (
    reason === "report" &&
    !device.notifyAtNight &&
    device.utcOffsetMinutes != null &&
    isQuietHours(device.utcOffsetMinutes)
  ) {
    return false;
  }
  if (
    device.radiusKm != null &&
    device.latitude != null &&
    device.longitude != null
  ) {
    if (event.latitude == null || event.longitude == null) return false;
    return (
      haversineDistanceKm(
        device.latitude,
        device.longitude,
        event.latitude,
        event.longitude,
      ) <= device.radiusKm
    );
  }
  return true;
}

function base64URL(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary)
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");
}

function utf8Base64URL(value: string): string {
  return base64URL(new TextEncoder().encode(value));
}

function hasApnsConfiguration(env: Env): boolean {
  return Boolean(
    env.APNS_PRIVATE_KEY &&
      env.APNS_KEY_ID &&
      env.APNS_TEAM_ID &&
      env.APNS_BUNDLE_ID,
  );
}

function requireApnsConfiguration(env: Env): void {
  if (!hasApnsConfiguration(env)) throw new MissingApnsConfigurationError();
}

async function createApnsJWT(env: Env): Promise<string> {
  requireApnsConfiguration(env);
  const privateKey = env.APNS_PRIVATE_KEY;
  const keyId = env.APNS_KEY_ID;
  const teamId = env.APNS_TEAM_ID;
  if (!privateKey || !keyId || !teamId) throw new MissingApnsConfigurationError();
  const keyBytes = Uint8Array.from(
    atob(
      privateKey.replace(/-----BEGIN PRIVATE KEY-----/, "")
        .replace(/-----END PRIVATE KEY-----/, "")
        .replace(/\s/g, ""),
    ),
    (character) => character.charCodeAt(0),
  );
  const key = await crypto.subtle.importKey(
    "pkcs8",
    keyBytes,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const header = utf8Base64URL(
    JSON.stringify({ alg: "ES256", kid: keyId }),
  );
  const claims = utf8Base64URL(
    JSON.stringify({
      iss: teamId,
      iat: Math.floor(Date.now() / 1000),
    }),
  );
  const unsigned = `${header}.${claims}`;
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(unsigned),
  );
  return `${unsigned}.${base64URL(new Uint8Array(signature))}`;
}

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(value),
  );
  return Array.from(new Uint8Array(digest), (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
}

async function apnsCollapseID(event: Pick<NormalizedEvent, "id">): Promise<string> {
  // A hash keeps the header bounded (APNs allows at most 64 bytes) while
  // producing the same identifier for new, update, final, and cancel states.
  return `quake-${(await sha256Hex(event.id)).slice(0, 56)}`;
}

async function tokenHash(token: string): Promise<string> {
  // Device tokens are never written to logs. Their SHA-256 hash is enough to
  // correlate one delivery failure with a registration record during support.
  return await sha256Hex(token);
}

interface ApnsErrorDetails {
  reason: string | null;
  invalidationTimestampMs: number | null;
}

async function apnsErrorDetails(response: Response): Promise<ApnsErrorDetails> {
  try {
    const body: unknown = await response.json();
    if (!body || typeof body !== "object") {
      return { reason: null, invalidationTimestampMs: null };
    }
    const reason = (body as { reason?: unknown }).reason;
    // APNs reason names are short ASCII identifiers. Do not log arbitrary
    // response content in case an intermediary ever returns an unexpected body.
    const safeReason = typeof reason === "string" && /^[A-Za-z]+$/.test(reason)
      ? reason
      : null;
    const timestamp = (body as { timestamp?: unknown }).timestamp;
    // APNs supplies a millisecond Unix timestamp for 410 responses. Retain
    // only a plausible numeric value so a malformed upstream body cannot
    // affect subscription deletion.
    const invalidationTimestampMs =
      typeof timestamp === "number" &&
      Number.isSafeInteger(timestamp) &&
      timestamp > 946684800000 &&
      timestamp <= Date.now() + 24 * 60 * 60_000
        ? timestamp
        : null;
    return { reason: safeReason, invalidationTimestampMs };
  } catch {
    return { reason: null, invalidationTimestampMs: null };
  }
}

function retryAfterSeconds(response: Response): number | null {
  const value = response.headers.get("retry-after")?.trim();
  if (!value) return null;
  if (/^\d+$/.test(value)) {
    return Math.min(Number(value), MAX_QUEUE_RETRY_DELAY_SECONDS);
  }
  const retryAtMs = Date.parse(value);
  if (Number.isNaN(retryAtMs)) return null;
  return Math.min(
    Math.max(0, Math.ceil((retryAtMs - Date.now()) / 1_000)),
    MAX_QUEUE_RETRY_DELAY_SECONDS,
  );
}

type DeviceDeletionOutcome =
  | "deleted"
  | "not_found"
  | "newer_registration"
  | "not_deleted";

/**
 * Delete the device and its delivery-deduplication records in one D1
 * transaction. Callers that react to APNs must pass a validated 410 timestamp
 * so a refreshed registration cannot be deleted by an old response.
 */
async function deleteDeviceRegistration(
  db: D1Database,
  token: string,
  invalidationTimestampMs?: number | null,
): Promise<DeviceDeletionOutcome> {
  const invalidationCutoff =
    invalidationTimestampMs === null || invalidationTimestampMs === undefined
      ? null
      : new Date(invalidationTimestampMs).toISOString();
  const deviceCondition = invalidationCutoff
    ? "token = ? AND updated_at <= ?"
    : "token = ?";
  const deviceBindings = invalidationCutoff
    ? [token, invalidationCutoff]
    : [token];
  const hashedToken = await tokenHash(token);
  const results = await db.batch([
    db
      .prepare(
        `DELETE FROM notification_deliveries
         WHERE device_token IN (
           SELECT token FROM devices WHERE ${deviceCondition}
         )`,
      )
      .bind(...deviceBindings),
    db
      .prepare("DELETE FROM alert_delivery_failures WHERE token_hash = ?")
      .bind(hashedToken),
    db.prepare(`DELETE FROM devices WHERE ${deviceCondition}`).bind(...deviceBindings),
    ...appAttestRetentionCleanupStatements(db, new Date().toISOString()),
  ]);
  if ((results[2]?.meta.changes ?? 0) > 0) return "deleted";

  const current = await db
    .prepare("SELECT updated_at FROM devices WHERE token = ?")
    .bind(token)
    .first<{ updated_at: string }>();
  if (!current) return "not_found";
  if (
    invalidationTimestampMs !== null &&
    invalidationTimestampMs !== undefined &&
    Date.parse(current.updated_at) > invalidationTimestampMs
  ) {
    return "newer_registration";
  }
  // A conditional APNs deletion that leaves an older matching record must be
  // retried. Treating it as complete could retain an invalid subscription.
  return invalidationCutoff ? "not_deleted" : "not_found";
}

async function deactivateDevice(
  db: D1Database,
  token: string,
  invalidationTimestampMs: number,
): Promise<boolean> {
  try {
    const outcome = await deleteDeviceRegistration(
      db,
      token,
      invalidationTimestampMs,
    );
    return outcome !== "not_deleted";
  } catch {
    return false;
  }
}

function buildPushPayload(
  event: NormalizedEvent,
  reason: NotifyReason,
): Record<string, unknown> {
  const keys = LOC_KEYS[reason];
  const sourceLabel = SOURCE_LABEL[event.sourceId] ?? event.sourceId;
  return {
    aps: {
      alert: {
        "title-loc-key": keys.title,
        "title-loc-args": [sourceLabel],
        "loc-key": keys.body,
        "loc-args": [
          event.hypocenter || sourceLabel,
          event.magnitude?.toFixed(1) ?? "--",
          event.maxIntensity ?? "--",
        ],
      },
      // This bundle does not hold Apple's Critical Alerts entitlement.
      sound: "default",
      "interruption-level":
        reason === "training"
          ? "active"
          : "time-sensitive",
      "relevance-score":
        reason === "cancelled" || reason === "training" ? 0.3 : 1,
      category: reason === "training" ? "EEW_TRAINING" : "EEW_ALERT",
    },
    eventId: event.eventId,
    sourceId: event.sourceId,
    kind: event.kind,
    reason,
    magnitude: event.magnitude,
    maxIntensity: event.maxIntensity,
    latitude: event.latitude,
    longitude: event.longitude,
    originTimeUtc: event.originTimeUtc,
  };
}

export class ApnsRequestTimeoutError extends Error {
  constructor() {
    super("APNs request timed out");
    this.name = "ApnsRequestTimeoutError";
  }
}

/**
 * Bound an APNs operation even if the underlying transport fails to settle
 * promptly after abort. The explicit `finally` clears the timer on ordinary
 * success/failure; the timeout aborts the fetch and wins the race as a normal
 * rejected delivery, which `dispatchPushPage` handles as a page-level retry.
 */
export async function withApnsRequestTimeout<T>(
  operation: (signal: AbortSignal) => Promise<T>,
  timeoutMs = APNS_REQUEST_TIMEOUT_MS,
): Promise<T> {
  const controller = new AbortController();
  let timeoutId: number | null = null;
  const timeout = new Promise<never>((_resolve, reject) => {
    timeoutId = setTimeout(() => {
      const error = new ApnsRequestTimeoutError();
      // Reject first so the operation has a deterministic timeout outcome;
      // aborting then releases the underlying APNs fetch/socket promptly.
      reject(error);
      controller.abort(error);
    }, timeoutMs);
  });
  try {
    return await Promise.race([operation(controller.signal), timeout]);
  } finally {
    clearTimeout(timeoutId);
  }
}

async function sendPush(
  env: Env,
  device: DeviceRecord,
  event: NormalizedEvent,
  reason: NotifyReason,
  authorization: string,
  collapseId: string,
): Promise<ApnsDeliveryResult> {
  requireApnsConfiguration(env);
  const bundleId = env.APNS_BUNDLE_ID;
  if (!bundleId) throw new MissingApnsConfigurationError();
  const host =
    device.environment === "sandbox"
      ? "api.sandbox.push.apple.com"
      : "api.push.apple.com";
  const response = await withApnsRequestTimeout((signal) =>
    fetch(`https://${host}/3/device/${encodeURIComponent(device.token)}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${authorization}`,
        "apns-topic": bundleId,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-expiration": APNS_EXPIRATION_IMMEDIATE,
        "apns-collapse-id": collapseId,
        "apns-id": crypto.randomUUID(),
        "content-type": "application/json",
      },
      body: JSON.stringify(buildPushPayload(event, reason)),
      signal,
    }),
  );
  const apnsId = response.headers.get("apns-id");
  if (response.ok) {
    return { ok: true, apnsId };
  }

  const { reason: apnsReason, invalidationTimestampMs } =
    await apnsErrorDetails(response);
  // Apple includes the timestamp only for an HTTP 410 response. Never delete
  // based on a reason string alone or a malformed/missing timestamp: it could
  // erase a registration refreshed after APNs invalidated the old token.
  const unregistrationTimestampMissing =
    response.status === 410 && invalidationTimestampMs === null;
  const terminalUnregistration =
    response.status === 410 && !unregistrationTimestampMissing;
  const registeredAfterInvalidation =
    terminalUnregistration &&
    !Number.isNaN(Date.parse(device.updatedAt)) &&
    Date.parse(device.updatedAt) > (invalidationTimestampMs as number);
  const deactivated =
    terminalUnregistration && !registeredAfterInvalidation
      ? await deactivateDevice(
          env.DB,
          device.token,
          invalidationTimestampMs as number,
        )
      : false;
  return {
    ok: false,
    apnsId,
    status: response.status,
    apnsReason,
    invalidationTimestampMs,
    retryAfterSeconds: retryAfterSeconds(response),
    terminalUnregistration,
    unregistrationTimestampMissing,
    terminalResolved: terminalUnregistration &&
      (registeredAfterInvalidation || deactivated),
    deactivated,
  };
}

/**
 * Obtain a provider token only from the global relay. The relay is the single
 * owner of the APNs JWT cache, so a burst of sandbox or approved production
 * training pushes cannot mint a fresh token for every request.
 */
export async function cachedApnsAuthorizationFromRelay(env: Env): Promise<string> {
  const relay = env.RELAY.get(env.RELAY.idFromName("global"));
  const response = await relay.fetch(
    new Request("https://relay.internal/apns/authorization"),
  );
  if (!response.ok) {
    throw new Error(`Relay APNs authorization returned HTTP ${response.status}`);
  }
  let body: unknown;
  try {
    body = await response.json();
  } catch {
    throw new Error("Relay APNs authorization response was invalid");
  }
  const authorization = body && typeof body === "object" && "authorization" in body
    ? (body as { authorization?: unknown }).authorization
    : null;
  // JWT provider tokens are compact, ASCII strings. Bound the value before it
  // reaches an HTTP header even though the source is an internal DO binding.
  if (
    typeof authorization !== "string" ||
    authorization.length === 0 ||
    authorization.length > 4_096 ||
    /[^A-Za-z0-9._-]/.test(authorization)
  ) {
    throw new Error("Relay APNs authorization response was invalid");
  }
  return authorization;
}

function logApnsFailure(
  event: NormalizedEvent,
  reason: NotifyReason,
  tokenHashValue: string,
  result: ApnsDeliveryResult,
  disposition?: ApnsFailureDisposition,
): void {
  console.warn(
    JSON.stringify({
      eventId: event.eventId,
      sourceId: event.sourceId,
      notificationReason: reason,
      tokenHash: tokenHashValue,
      outcome: "apns_delivery_failed",
      apnsId: result.apnsId,
      apnsStatus: result.status,
      apnsReason: result.apnsReason ?? undefined,
      deactivated: result.deactivated ?? false,
      disposition,
    }),
  );
}

function logApnsException(
  event: NormalizedEvent,
  reason: NotifyReason,
  tokenHashValue: string,
  error: unknown,
): void {
  console.error(
    JSON.stringify({
      eventId: event.eventId,
      sourceId: event.sourceId,
      notificationReason: reason,
      tokenHash: tokenHashValue,
      outcome: "apns_delivery_exception",
      errorName: error instanceof Error ? error.name : "UnknownError",
    }),
  );
}

function logApnsPageFailure(
  event: NormalizedEvent,
  reason: NotifyReason,
  outboxId: string,
  result: ApnsDeliveryResult,
): void {
  // Intentionally omit a token hash: this failure applies to the provider
  // request/page, not to one recipient's subscription.
  console.error(
    JSON.stringify({
      outboxId,
      eventId: event.eventId,
      sourceId: event.sourceId,
      notificationReason: reason,
      outcome: "apns_provider_page_failure",
      apnsId: result.apnsId,
      apnsStatus: result.status,
      apnsReason: result.apnsReason ?? undefined,
    }),
  );
}

/**
 * APNs only identifies a few nonterminal outcomes as genuinely recipient
 * scoped. Everything else is treated as provider/topic/payload infrastructure
 * trouble so a bad APNs key or topic cannot quietly quarantine every device.
 *
 * `DeviceTokenNotForTopic` is intentionally page-level here. This service has
 * one configured APNs topic, so it is indistinguishable from an APNS_BUNDLE_ID
 * or entitlement mismatch without an operator investigation. The bounded
 * Queue-to-DLQ path preserves that evidence instead of suppressing recipients.
 */
export function isPageLevelApnsFailure(result: ApnsDeliveryResult): boolean {
  if (result.terminalUnregistration || result.unregistrationTimestampMissing) {
    return false;
  }
  if (result.status === 410) return false;
  // APNs documents this 429 separately from per-device TooManyRequests: it
  // means the provider is churning JWTs too aggressively, so it belongs to
  // the page/provider incident path.
  if (result.apnsReason === "TooManyProviderTokenUpdates") return true;
  if (result.status === 429 || result.apnsReason === "TooManyRequests") {
    return false;
  }
  return result.apnsReason !== "BadDeviceToken";
}

function apnsFailureDisposition(
  result: ApnsDeliveryResult,
): ApnsFailureDisposition {
  // A 410 without Apple's invalidation timestamp is intentionally fail-safe:
  // preserve the registration and stop this delivery pending operator/client
  // review, rather than risking deletion of a freshly rotated token.
  if (result.unregistrationTimestampMissing) return "quarantine";

  // APNs 410/Unregistered is the only safe deletion signal. If D1 cleanup
  // failed, retry it rather than treating the recipient as complete.
  if (result.terminalUnregistration) {
    return result.terminalResolved ? "terminal" : "retry";
  }

  if (isPageLevelApnsFailure(result)) return "page_retry";

  // APNs documents 429 as a per-device-token throttle. Preserve successful
  // recipients and retry only this page's undelivered device on the next
  // bounded Queue attempt.
  if (
    result.status === 429 ||
    result.apnsReason === "TooManyRequests"
  ) {
    return "retry";
  }

  // Topic, payload, and non-terminal token failures (for example 400
  // BadDeviceToken or a 403) are durable incident evidence, but retrying a
  // whole page would suppress all later recipients. Keep the subscription for
  // a later client refresh and quarantine only this delivery attempt.
  return "quarantine";
}

function apnsRetryDelaySeconds(result: ApnsDeliveryResult): number {
  if (isPageLevelApnsFailure(result)) {
    // A freshly generated JWT can resolve ExpiredProviderToken; all other
    // provider/topic/configuration states need an operator change and should
    // not spin the Queue consumer while they are being investigated.
    if (result.apnsReason === "ExpiredProviderToken") {
      return DEFAULT_QUEUE_RETRY_DELAY_SECONDS;
    }
    return Math.min(
      MAX_QUEUE_RETRY_DELAY_SECONDS,
      Math.max(
        APNS_TRANSIENT_RETRY_DELAY_SECONDS,
        result.retryAfterSeconds ?? 0,
      ),
    );
  }
  if (
    result.status === 429 ||
    (result.status !== undefined && result.status >= 500)
  ) {
    return Math.min(
      MAX_QUEUE_RETRY_DELAY_SECONDS,
      Math.max(
        APNS_TRANSIENT_RETRY_DELAY_SECONDS,
        result.retryAfterSeconds ?? 0,
      ),
    );
  }
  // Provider-token refresh and transport/configuration failures must never
  // immediately spin a Queue consumer either.
  return DEFAULT_QUEUE_RETRY_DELAY_SECONDS;
}

async function recordDeliveryFailure(
  db: D1Database,
  deliveryId: string,
  event: NormalizedEvent,
  reason: NotifyReason,
  tokenHashValue: string,
  result: ApnsDeliveryResult,
  disposition: Exclude<ApnsFailureDisposition, "terminal" | "page_retry">,
): Promise<void> {
  const now = new Date().toISOString();
  await db
    .prepare(
      `INSERT INTO alert_delivery_failures (
        delivery_id, token_hash, event_ref, source_id, notification_reason,
        apns_status, apns_reason, disposition, first_seen_utc, last_seen_utc
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(delivery_id, token_hash) DO UPDATE SET
        apns_status = excluded.apns_status,
        apns_reason = excluded.apns_reason,
        disposition = excluded.disposition,
        status = 'active',
        resolved_at_utc = NULL,
        last_seen_utc = excluded.last_seen_utc,
        occurrences = alert_delivery_failures.occurrences + 1`,
    )
    .bind(
      deliveryId,
      tokenHashValue,
      event.id,
      event.sourceId,
      reason,
      result.status ?? null,
      result.apnsReason ?? null,
      disposition,
      now,
      now,
    )
    .run();
}

async function recordPageDeliveryFailure(
  db: D1Database,
  outboxId: string,
  message: AlertDeliveryMessage,
  result: ApnsDeliveryResult,
): Promise<void> {
  const now = new Date().toISOString();
  await db
    .prepare(
      `INSERT INTO alert_delivery_page_failures (
        outbox_id, delivery_id, root_delivery_id, event_ref, source_id,
        event_serial, notification_reason, apns_status, apns_reason,
        first_seen_utc, last_seen_utc
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(outbox_id) DO UPDATE SET
        apns_status = excluded.apns_status,
        apns_reason = excluded.apns_reason,
        status = 'active',
        resolved_at_utc = NULL,
        last_seen_utc = excluded.last_seen_utc,
        occurrences = alert_delivery_page_failures.occurrences + 1`,
    )
    .bind(
      outboxId,
      message.deliveryId,
      message.rootDeliveryId,
      message.event.id,
      message.event.sourceId,
      message.event.serial,
      message.reason,
      result.status ?? null,
      result.apnsReason ?? null,
      now,
      now,
    )
    .run();
}

async function resolvePageDeliveryFailure(
  db: D1Database,
  outboxId: string,
): Promise<void> {
  await db
    .prepare(
      `UPDATE alert_delivery_page_failures
       SET status = 'resolved', resolved_at_utc = ?
       WHERE outbox_id = ? AND status = 'active'`,
    )
    .bind(new Date().toISOString(), outboxId)
    .run();
}

async function deliveredDeviceTokens(
  db: D1Database,
  deliveryId: string,
  tokens: string[],
): Promise<Set<string>> {
  if (tokens.length === 0) return new Set();
  const placeholders = tokens.map(() => "?").join(", ");
  const result = await db
    .prepare(
      `SELECT device_token FROM notification_deliveries
       WHERE delivery_id = ? AND device_token IN (${placeholders})`,
    )
    .bind(deliveryId, ...tokens)
    .all<{ device_token: string }>();
  return new Set(result.results.map((row) => row.device_token));
}

async function quarantinedDeviceTokens(
  db: D1Database,
  deliveryId: string,
  tokens: string[],
): Promise<Set<string>> {
  if (tokens.length === 0) return new Set();
  const tokenHashes = await Promise.all(tokens.map(tokenHash));
  const placeholders = tokenHashes.map(() => "?").join(", ");
  const result = await db
    .prepare(
      `SELECT token_hash FROM alert_delivery_failures
       WHERE delivery_id = ? AND status = 'active' AND disposition = 'quarantine'
         AND token_hash IN (${placeholders})`,
    )
    .bind(deliveryId, ...tokenHashes)
    .all<{ token_hash: string }>();
  const quarantinedHashes = new Set(result.results.map((row) => row.token_hash));
  return new Set(
    tokens.filter((token, index) => quarantinedHashes.has(tokenHashes[index])),
  );
}

async function recordDeliveredDevices(
  db: D1Database,
  deliveryId: string,
  tokens: string[],
): Promise<void> {
  if (tokens.length === 0) return;
  const deliveredAt = new Date().toISOString();
  const tokenHashes = await Promise.all(tokens.map(tokenHash));
  await db.batch(
    [
      ...tokens.map((token) =>
        db
          .prepare(
            `INSERT OR IGNORE INTO notification_deliveries
             (delivery_id, device_token, delivered_at_utc)
             VALUES (?, ?, ?)`,
          )
          .bind(deliveryId, token, deliveredAt),
      ),
      ...tokenHashes.map((tokenHashValue) =>
        db
          .prepare(
            `UPDATE alert_delivery_failures
             SET status = 'resolved', resolved_at_utc = ?
             WHERE delivery_id = ? AND token_hash = ? AND status = 'active'`,
          )
          .bind(deliveredAt, deliveryId, tokenHashValue),
      ),
    ],
  );
}

interface DeliveryPageResult {
  nextAfterDeviceCursor: number | null;
  retryRequired: boolean;
  retryDelaySeconds: number;
  invalidateApnsJwt: boolean;
  /** Provider/topic/payload failure for the whole page, never one token. */
  pageFailure: ApnsDeliveryResult | null;
  /** An expiry or newer serial stopped the page before later APNs batches. */
  terminalState: OutboxDeliveryGateState | null;
}

type OutboxDeliveryGateState =
  | "pending"
  | "acknowledged"
  | "expired"
  | "superseded"
  | "missing";

async function dispatchPushPage(
  env: Env,
  event: NormalizedEvent,
  reason: NotifyReason,
  authorization: string,
  deliveryId: string,
  afterDeviceCursor?: number,
  beforeApnsBatch?: () => Promise<OutboxDeliveryGateState>,
): Promise<DeliveryPageResult> {
  const rows = await env.DB
    .prepare(
      `SELECT rowid AS cursor, * FROM devices
       WHERE rowid > ?
       ORDER BY rowid ASC
       LIMIT ?`,
    )
    .bind(afterDeviceCursor ?? 0, DEVICE_DELIVERY_PAGE_SIZE)
    .all<DeviceRow>();
  const page = rows.results;
  const nextAfterDeviceCursor =
    page.length === DEVICE_DELIVERY_PAGE_SIZE
      ? (page.at(-1)?.cursor ?? null)
      : null;
  const devices = page
    .map(rowToDevice)
    .filter((device) => shouldNotify(device, event, reason));
  const alreadyDelivered = await deliveredDeviceTokens(
    env.DB,
    deliveryId,
    devices.map((device) => device.token),
  );
  const quarantined = await quarantinedDeviceTokens(
    env.DB,
    deliveryId,
    devices.map((device) => device.token),
  );
  const pendingDevices = devices.filter(
    (device) => !alreadyDelivered.has(device.token) && !quarantined.has(device.token),
  );
  const collapseId = await apnsCollapseID(event);
  const successfulTokens: string[] = [];
  let retryRequired = false;
  let retryDelaySeconds = DEFAULT_QUEUE_RETRY_DELAY_SECONDS;
  let invalidateApnsJwt = false;
  let pageFailure: ApnsDeliveryResult | null = null;
  let terminalState: OutboxDeliveryGateState | null = null;

  for (
    let start = 0;
    start < pendingDevices.length;
    start += APNS_MAX_CONCURRENT_DELIVERIES
  ) {
    // Re-check immediately before every small APNs batch. The initial relay
    // gate handles the common case; this closes the window where a newer event
    // revision commits while the current page is reading/filtering devices.
    const gateState = beforeApnsBatch ? await beforeApnsBatch() : "pending";
    if (gateState !== "pending") {
      terminalState = gateState;
      break;
    }
    const batch = pendingDevices.slice(
      start,
      start + APNS_MAX_CONCURRENT_DELIVERIES,
    );
    const deliveries: PreparedDelivery[] = await Promise.all(
      batch.map(async (device) => ({
        device,
        tokenHash: await tokenHash(device.token),
      })),
    );
    const results = await Promise.allSettled(
      deliveries.map(({ device }) =>
        sendPush(env, device, event, reason, authorization, collapseId),
      ),
    );

    // A provider transport/auth/topic/payload failure is not evidence that any
    // recipient is bad. Stop before later batches and retry this exact outbox
    // page through the bounded Queue/DLQ lifecycle. Parallel successes remain
    // durable; every other failure in this small batch is intentionally not
    // quarantined because the page-level incident explains it better.
    const providerResult = results.find(
      (result) =>
        result.status === "rejected" ||
        (!result.value.ok && isPageLevelApnsFailure(result.value)),
    );
    if (providerResult) {
      for (const [index, result] of results.entries()) {
        if (result.status === "fulfilled" && result.value.ok) {
          successfulTokens.push(deliveries[index].device.token);
        }
      }
      const failure: ApnsDeliveryResult = providerResult.status === "rejected"
        ? { ok: false, apnsId: null, apnsReason: "TransportError" }
        : providerResult.value;
      pageFailure ??= failure;
      retryRequired = true;
      retryDelaySeconds = Math.max(
        retryDelaySeconds,
        apnsRetryDelaySeconds(failure),
      );
      invalidateApnsJwt ||= failure.apnsReason === "ExpiredProviderToken";
      break;
    }

    for (const [index, result] of results.entries()) {
      const delivery = deliveries[index];
      if (result.status === "fulfilled") {
        if (result.value.ok) {
          successfulTokens.push(delivery.device.token);
        } else {
          const disposition = apnsFailureDisposition(result.value);
          logApnsFailure(
            event,
            reason,
            delivery.tokenHash,
            result.value,
            disposition,
          );
          if (disposition === "retry") {
            retryRequired = true;
            retryDelaySeconds = Math.max(
              retryDelaySeconds,
              apnsRetryDelaySeconds(result.value),
            );
            invalidateApnsJwt ||= result.value.apnsReason === "ExpiredProviderToken";
            await recordDeliveryFailure(
              env.DB,
              deliveryId,
              event,
              reason,
              delivery.tokenHash,
              result.value,
              "retry",
            );
          } else if (disposition === "quarantine") {
            await recordDeliveryFailure(
              env.DB,
              deliveryId,
              event,
              reason,
              delivery.tokenHash,
              result.value,
              "quarantine",
            );
          }
        }
      } else {
        // Rejections were handled as page-level failures above. This branch is
        // retained for type exhaustiveness if the classifier is tightened in a
        // future release.
        logApnsException(event, reason, delivery.tokenHash, result.reason);
        retryRequired = true;
        retryDelaySeconds = Math.max(
          retryDelaySeconds,
          APNS_TRANSIENT_RETRY_DELAY_SECONDS,
        );
        await recordDeliveryFailure(
          env.DB,
          deliveryId,
          event,
          reason,
          delivery.tokenHash,
          {
            ok: false,
            apnsId: null,
            apnsReason: "TransportError",
          },
          "retry",
        );
      }
    }
  }

  // Record only confirmed APNs successes. If recording fails, the queue will
  // retry and APNs collapse IDs make the small duplicate window safe.
  await recordDeliveredDevices(env.DB, deliveryId, successfulTokens);
  return {
    nextAfterDeviceCursor,
    retryRequired,
    retryDelaySeconds,
    invalidateApnsJwt,
    pageFailure,
    terminalState,
  };
}

function productionTestPushAllowed(env: Env, device: DeviceRecord): boolean {
  return (
    device.environment !== "production" ||
    env.ENABLE_PRODUCTION_TEST_PUSH === "true"
  );
}

export class QuakeRelay {
  private readonly state: DurableObjectState;
  private readonly env: Env;
  private readonly upstreams = new Map<UpstreamRoute, WebSocket>();
  // An Upgrade fetch does not produce a WebSocket until its asynchronous
  // handshake completes. Keep the attempt separately from `upstreams` so two
  // overlapping status/alarm invocations cannot start duplicate connections
  // for the same Wolfx route.
  private readonly connectingRoutes = new Set<UpstreamRoute>();
  private readonly statuses = new Map<WolfxSourceId, string>();
  private readonly lastSuccessfulUpstreamMs = new Map<WolfxSourceId, number>();
  private readonly lastSuccessfulHttpPollMs = new Map<WolfxSourceId, number>();
  // These maps are a per-instance cache of successfully committed durable
  // freshness checkpoints. They are populated from storage on the first
  // heartbeat after an eviction, so a restart never fabricates a checkpoint.
  private readonly lastPersistedUpstreamSuccessMs = new Map<WolfxSourceId, number>();
  private readonly lastPersistedHttpSuccessMs = new Map<WolfxSourceId, number>();
  // A failed write must not publish fresh in-memory evidence, but retrying it
  // for every heartbeat would create an error storm after a storage quota is
  // exhausted. Bound failed retries to the same checkpoint cadence.
  private readonly lastUpstreamCheckpointAttemptMs = new Map<WolfxSourceId, number>();
  private readonly lastHttpCheckpointAttemptMs = new Map<WolfxSourceId, number>();
  // Resuming a durable changed-snapshot cursor is paced in memory. A restart
  // may cause one early retry, but never a steady sub-minute polling loop;
  // the cursor itself remains the durable fail-closed fence.
  private lastHttpSnapshotResumeStartedMs: number | null = null;
  // WebSocket message handlers use waitUntil and may overlap while awaiting
  // storage. Serialize one source/transport freshness update so a burst of
  // heartbeats cannot all observe the same old checkpoint and write it again.
  private readonly freshnessUpdates = new Map<string, Promise<void>>();
  private httpSeedInFlight: Promise<void> | null = null;
  private pendingIngestDrain: Promise<void> | null = null;
  /**
   * A status probe must not repeatedly run the complete outbox/reconciliation
   * startup path. Keep the lightweight instance bootstrap single-flight; an
   * alarm owns routine recovery after the first attempt.
   */
  private statusStartup: Promise<void> | null = null;
  private statusInitialized = false;
  private apnsJwtCache: { authorization: string; issuedAtMs: number } | null =
    null;
  private apnsJwtRefresh: Promise<string> | null = null;
  // A Durable Object has one alarm. Serialize every non-journal alarm decision
  // so a concurrent routine write cannot overwrite a faster reconnect wakeup
  // (or vice versa) between storage.getAlarm() and storage.setAlarm().
  private relayAlarmWrite: Promise<void> = Promise.resolve();

  constructor(state: DurableObjectState, env: Env) {
    this.state = state;
    this.env = env;
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (
      url.pathname === "/dlq/persistence-fallback" &&
      request.method === "POST"
    ) {
      // This is deliberately before `ensureStarted()`: the endpoint is called
      // precisely when D1 may be unavailable, while Durable Object storage is
      // the independent durability boundary for the sanitized incident record.
      return this.recordDlqPersistenceFallback(request);
    }

    if (
      url.pathname === "/apns/authorization" &&
      request.method === "GET"
    ) {
      // This endpoint is reachable only through the internal Durable Object
      // binding. Keep training-push authentication on the same 45-minute
      // provider-token cache as alert delivery without starting the upstream
      // watcher or outbox machinery for a user-initiated test notification.
      try {
        return Response.json({ authorization: await this.apnsAuthorization() });
      } catch (error) {
        console.error(
          JSON.stringify({
            outcome: "relay_apns_authorization_unavailable",
            errorName: error instanceof Error ? error.name : "UnknownError",
          }),
        );
        return Response.json(
          { error: "APNs authorization is temporarily unavailable" },
          { status: 503 },
        );
      }
    }

    if (url.pathname === "/status") {
      try {
        await this.ensureStatusStarted();
      } catch (error) {
        // `/healthz` must still return a structured degraded response when
        // start-up work (usually D1 recovery) fails. The status reader has its
        // own guarded D1 queries and a direct Durable Object fallback marker.
        console.error(
          JSON.stringify({
            outcome: "relay_status_startup_retry",
            errorName: error instanceof Error ? error.name : "UnknownError",
          }),
        );
      }
      return this.statusResponse();
    }
    await this.ensureStarted();
    if (url.pathname === "/deliver" && request.method === "POST") {
      let body: unknown;
      try {
        body = await request.json();
      } catch {
        return Response.json({ error: "invalid queue message" }, { status: 400 });
      }
      if (!isAlertDeliveryMessage(body)) {
        return Response.json({ error: "invalid queue message" }, { status: 400 });
      }
      return this.deliverQueuedPage(body);
    }
    if (url.pathname === "/outbox/ack" && request.method === "POST") {
      let body: unknown;
      try {
        body = await request.json();
      } catch {
        return Response.json({ error: "invalid outbox acknowledgement" }, { status: 400 });
      }
      const outboxId =
        body && typeof body === "object" && "outboxId" in body
          ? (body as { outboxId?: unknown }).outboxId
          : null;
      if (typeof outboxId !== "string" || outboxId.length === 0) {
        return Response.json({ error: "invalid outbox acknowledgement" }, { status: 400 });
      }
      const acknowledged = await this.finalizeOutbox(outboxId, "delivered");
      // An old Queue message can outlive terminal-outbox retention. Its relay
      // path already proved that no APNs work remains safe; acknowledge that
      // Queue copy instead of retrying it into a misleading DLQ incident.
      return Response.json({ ok: true, alreadyMissing: !acknowledged });
    }
    if (url.pathname === "/outbox/legacy" && request.method === "POST") {
      let body: unknown;
      try {
        body = await request.json();
      } catch {
        return Response.json({ error: "invalid legacy queue message" }, { status: 400 });
      }
      if (!isLegacyAlertDeliveryMessage(body)) {
        return Response.json({ error: "invalid legacy queue message" }, { status: 400 });
      }
      const upgraded = upgradeLegacyAlertDeliveryMessage(body);
      await appendOutbox(this.env.DB, upgraded, upgraded.deliveryId);
      await this.flushAlertDeliveryOutbox(ROUTINE_OUTBOX_FLUSH_BATCH_SIZE);
      return Response.json({ ok: true });
    }
    return Response.json({ error: "not found" }, { status: 404 });
  }

  /**
   * Preserve the first-request operational bootstrap, but never let every
   * `/healthz` probe flush the outbox, replay D1 fallbacks, or seed upstream
   * HTTP. When an alarm already exists (including after a failed initial
   * attempt), that alarm is the sole routine-recovery owner.
   */
  private async ensureStatusStarted(): Promise<void> {
    if (this.statusInitialized) return;
    if (this.statusStartup) return this.statusStartup;

    const startup = (async () => {
      // A fresh Durable Object instance needs its in-memory watcher sockets,
      // but a persisted alarm means the expensive durable work is already
      // scheduled and must not be repeated by a health probe.
      // Read the durable alarm before starting an asynchronous Upgrade. A
      // rejected handshake can schedule its short retry before this method
      // otherwise gets to read storage, but that must not suppress the first
      // HTTP seed for a genuinely uninitialized relay.
      const alarm = await this.state.storage.getAlarm();
      await this.ensureUpstreams();
      if (alarm === null) {
        try {
          await this.ensureStarted(alarm);
        } catch (error) {
          // A failed first start used to make every health probe retry D1
          // immediately. Leave a bounded alarm retry behind before reporting
          // the structured degraded status instead.
          try {
            await this.scheduleRelayAlarm(
              Date.now() + PENDING_INGEST_RETRY_DELAY_MS,
            );
          } catch (alarmError) {
            console.error(
              JSON.stringify({
                outcome: "relay_status_startup_alarm_schedule_failed",
                errorName: alarmError instanceof Error
                  ? alarmError.name
                  : "UnknownError",
              }),
            );
          }
          throw error;
        }
      }
      this.statusInitialized = true;
    })().finally(() => {
      if (this.statusStartup === startup) this.statusStartup = null;
    });
    this.statusStartup = startup;
    return startup;
  }

  async alarm(): Promise<void> {
    try {
      const fallbackActive = await this.refreshHttpFallbackActive();
      const pendingHttpSnapshot =
        // Only the alarm may repair malformed public snapshot cursors. Status
        // readers intentionally leave them untouched and fail closed, but an
        // invalid key must not leave a healthy recovered relay permanently
        // degraded after its WebSockets reopen.
        (await this.pendingHttpSnapshotWorks(true)).length > 0;
      const httpSnapshotTurnProtected = fallbackActive || pendingHttpSnapshot;
      if (
        httpSnapshotTurnProtected &&
        !await this.httpFallbackTurnIsDue(Date.now())
      ) {
        // Keep reconnect maintenance alive while a failed fallback slice is
        // waiting for its durable retry time, but do not fall through to
        // ordinary D1 maintenance or another HTTP source attempt.
        await this.ensureUpstreams();
        return;
      }
      // HTTP recovery has a strict whole-invocation D1 budget. It must own an
      // alarm by itself: an eight-event snapshot slice can use one prior-state
      // read plus up to 24 sequential batch statements, followed by at most a
      // four-row hand-off. Do not combine that work with ordinary purge,
      // journal, DLQ, or outbox maintenance in the same Worker invocation.
      const httpSeedMode = await this.nextDueHttpSeedMode(fallbackActive);
      if (httpSeedMode !== null) {
        // A recovery mode or an unfinished cursor owns the whole alarm turn.
        // The fallback state was sampled immediately before selection, and a
        // stored cursor remains durability-critical even after sockets recover.
        const effectiveHttpSnapshotProtection =
          httpSnapshotTurnProtected || httpSeedMode === "recovery";
        // Reconnect work is independent of D1 and must run before a fallible
        // hand-off. A D1 outage must never turn the alternate transport into
        // a loop that stops attempting to restore the preferred WebSockets.
        await this.ensureUpstreams();
        try {
          await this.seedFromHttp(httpSeedMode);
          // A prolonged alternate transport must still drain pages created by
          // a previous recovery slice (or ordinary traffic before the
          // outage). This deliberately small hand-off shares the fallback
          // turn's budget; it is not contingent on the current HTTP source
          // changing. DLQ/journal reconciliation remains ordinary relay work:
          // serial D1 maintenance here would steal the low-latency fallback
          // poll from an active emergency transport.
          await this.flushAlertDeliveryOutbox(
            HTTP_FALLBACK_OUTBOX_FLUSH_BATCH_SIZE,
          );
          if (effectiveHttpSnapshotProtection) {
            // A successful protected slice must clear a stale deferral,
            // otherwise the final scheduler can request an immediate wake
            // that falls through to ordinary D1 maintenance before the next
            // paced source slice.
            await this.clearHttpFallbackDeferral();
          }
        } catch (error) {
          // A stored cursor keeps its original mode, but it remains
          // durability-critical after WebSockets recover too. Do not let an
          // incomplete cursor return to Durable Object automatic alarm retries
          // merely because the active HTTP transport flag has cleared.
          if (
            !effectiveHttpSnapshotProtection &&
            (await this.pendingHttpSnapshotSources()).length === 0
          ) throw error;
          await this.deferHttpFallbackTurn(error);
          return;
        }
        await this.ensureUpstreams();
        return;
      }
      if (httpSnapshotTurnProtected) {
        // An early reconnect/journal alarm can arrive between paced recovery
        // sweeps. Keep attempting the preferred sockets, but do not let it
        // fall through to ordinary D1/outbox maintenance: the alternate
        // transport owns this relay turn until it is healthy again.
        await this.ensureUpstreams();
        return;
      }
      // Recover a D1-persistence fallback before ordinary outbox replay. If
      // D1 has recovered, this atomically terminalizes the original outbox row
      // first, so its expired lease cannot resurrect a failed alert page.
      await this.reconcileDlqPersistenceFallbacks();
      await this.migrateLegacyPendingDeliveries();
      await this.drainPendingIngestJournal();
      await this.flushAlertDeliveryOutbox(ROUTINE_OUTBOX_FLUSH_BATCH_SIZE);
      await this.purgeExpiredDevicesIfDue();
      await this.ensureUpstreams();
    } finally {
      // Preserve a short journal-retry alarm requested during this run rather
      // than accidentally replacing it with the routine one-minute wakeup.
      await this.scheduleRoutineRelayAlarm();
    }
  }

  private async ensureStarted(
    alarmAtStart?: number | null,
  ): Promise<void> {
    // Capture this before starting the asynchronous WebSocket Upgrade. See
    // `ensureStatusStarted`: a fast rejected handshake must not make the
    // initial snapshot seed disappear behind its reconnect alarm.
    const alarm = alarmAtStart === undefined
      ? await this.state.storage.getAlarm()
      : alarmAtStart;
    await this.ensureUpstreams();
    // Baseline HTTP seeding always belongs to the relay alarm, never to a
    // caller's `/deliver` or acknowledgement invocation. A Queue delivery can
    // have its own sizable D1 page, so mixing an eight-event snapshot slice
    // here would violate the whole-invocation D1 budget. With no existing
    // alarm, `scheduleRoutineRelayAlarm()` below requests the immediate
    // baseline wakeup instead.
    // This must precede every path that can enqueue an outbox row. A recovered
    // D1 incident write is the terminal decision for the original page.
    await this.reconcileDlqPersistenceFallbacks();
    await this.migrateLegacyPendingDeliveries();
    await this.drainPendingIngestJournal();
    await this.flushAlertDeliveryOutbox(ROUTINE_OUTBOX_FLUSH_BATCH_SIZE);
    await this.purgeExpiredDevicesIfDue();
    if (alarm === null) await this.scheduleRoutineRelayAlarm();
  }

  /**
   * Store only already-sanitized DLQ evidence in Durable Object SQLite. The
   * endpoint intentionally bypasses `ensureStarted()` because it is invoked
   * precisely during a D1 outage. The Queue consumer acknowledges only after
   * this storage transaction and alarm request both complete.
   */
  private async recordDlqPersistenceFallback(
    request: Request,
  ): Promise<Response> {
    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return Response.json(
        { error: "invalid DLQ persistence fallback evidence" },
        { status: 400 },
      );
    }
    if (!isDlqIncidentEvidence(body)) {
      return Response.json(
        { error: "invalid DLQ persistence fallback evidence" },
        { status: 400 },
      );
    }

    const evidence = body;
    const now = new Date().toISOString();
    const key = dlqPersistenceFallbackStorageKey(evidence.queueMessageId);
    await this.state.storage.transaction(async (transaction) => {
      const current = await transaction.get<unknown>(key);
      const existing = isDlqPersistenceFallbackRecord(current) ? current : null;
      const record: DlqPersistenceFallbackRecord = {
        // Duplicate Queue delivery may carry a larger attempt count. Retain
        // the maximum so the final D1 incident accurately reports the effort
        // spent before the fallback became durable.
        evidence: {
          ...evidence,
          queueAttempts: Math.max(
            evidence.queueAttempts,
            existing?.evidence.queueAttempts ?? 0,
          ),
        },
        writeId: crypto.randomUUID(),
        firstSeenUtc: existing?.firstSeenUtc ?? now,
        lastSeenUtc: now,
      };
      await transaction.put(key, record);
    });
    // Ensure recovery attempts continue even when the fallback endpoint was
    // the relay's first interaction and no routine alarm exists yet.
    await this.scheduleRelayAlarm(Date.now() + PENDING_INGEST_RETRY_DELAY_MS);
    return Response.json({ ok: true });
  }

  /**
   * Replay a bounded number of D1-independent fallback records. Delete a
   * marker only after the D1 batch commits and only when no concurrent Queue
   * retry replaced it with a newer writeId.
   */
  private async reconcileDlqPersistenceFallbacks(
    limit = DLQ_PERSISTENCE_FALLBACK_REPLAY_BATCH_SIZE,
  ): Promise<void> {
    if (!Number.isSafeInteger(limit) || limit < 1 ||
      limit > DLQ_PERSISTENCE_FALLBACK_REPLAY_BATCH_SIZE) {
      throw new RangeError("DLQ fallback replay limit must be a positive bounded safe integer");
    }
    const pending = await this.state.storage.list<unknown>({
      prefix: DLQ_PERSISTENCE_FALLBACK_PREFIX,
      limit,
    });
    for (const [key, value] of pending) {
      if (!isDlqPersistenceFallbackRecord(value)) {
        // Preserve an unreadable record and leave readiness degraded. Deleting
        // it would recreate the silent-loss failure this fallback prevents.
        console.error(
          JSON.stringify({
            fallbackKey: key,
            outcome: "invalid_alert_delivery_dlq_persistence_fallback",
          }),
        );
        continue;
      }
      try {
        await persistDlqIncidentAndFinalizeOutbox(this.env, value.evidence);
      } catch (error) {
        console.error(
          JSON.stringify({
            queueMessageId: value.evidence.queueMessageId,
            outcome: "alert_delivery_dlq_persistence_fallback_d1_retry",
            errorName: error instanceof Error ? error.name : "UnknownError",
          }),
        );
        await this.scheduleRelayAlarm(
          Date.now() + PENDING_INGEST_RETRY_DELAY_MS,
        );
        return;
      }
      await this.state.storage.transaction(async (transaction) => {
        const current = await transaction.get<unknown>(key);
        if (
          isDlqPersistenceFallbackRecord(current) &&
          current.writeId === value.writeId
        ) {
          await transaction.delete(key);
        }
      });
    }
  }

  private async migrateLegacyPendingDeliveries(): Promise<void> {
    const pending = await this.state.storage.list<unknown>({
      prefix: LEGACY_PENDING_DELIVERY_PREFIX,
      limit: OUTBOX_REPLAY_BATCH_SIZE,
    });
    for (const [key, value] of pending) {
      const legacy = value as Partial<LegacyAlertDeliveryMessage>;
      const message =
        isAlertDeliveryMessage(value)
          ? value
          : isLegacyAlertDeliveryMessage(legacy)
            ? upgradeLegacyAlertDeliveryMessage(legacy)
            : null;
      if (!message) {
        // Do not delete an unreadable legacy record: surfacing it repeatedly
        // is safer than silently losing a historical hand-off.
        console.error(JSON.stringify({ outcome: "invalid_legacy_outbox_record" }));
        continue;
      }
      await appendOutbox(this.env.DB, message, message.deliveryId);
      await this.state.storage.delete(key);
    }
  }

  /**
   * Persist live events before D1 ingestion. There is one coalescing journal
   * key per source/event so a burst of revisions retains the highest serial;
   * `writeId` prevents a drain of an older snapshot from deleting a newer one.
   */
  private async enqueueLiveIngest(event: NormalizedEvent): Promise<void> {
    const { raw: _raw, ...snapshot } = event;
    const key = `${PENDING_INGEST_PREFIX}${event.sourceId}:${encodeURIComponent(event.id)}`;
    const record: PendingIngestRecord = {
      event: snapshot,
      writeId: crypto.randomUUID(),
    };
    try {
      await this.state.storage.transaction(async (transaction) => {
        const current = await transaction.get<PendingIngestRecord>(key);
        // A stale WebSocket frame must never overwrite an already-journaled
        // higher serial while the D1 write is waiting to retry.
        if (
          !isPendingIngestRecord(current) ||
          record.event.serial >= current.event.serial
        ) {
          await transaction.put(key, record);
        }
      });
      await this.drainPendingIngestJournal();
    } catch (error) {
      console.error(
        JSON.stringify({
          eventId: event.eventId,
          sourceId: event.sourceId,
          outcome: "live_ingest_journal_retry",
          errorName: error instanceof Error ? error.name : "UnknownError",
        }),
      );
      await this.scheduleRelayAlarm(Date.now() + PENDING_INGEST_RETRY_DELAY_MS);
    }
  }

  private drainPendingIngestJournal(
    maxEntries: number | null = null,
    outboxFlushLimit: number | null = ROUTINE_OUTBOX_FLUSH_BATCH_SIZE,
  ): Promise<void> {
    if (
      maxEntries !== null &&
      (!Number.isSafeInteger(maxEntries) || maxEntries < 1 ||
        maxEntries > OUTBOX_REPLAY_BATCH_SIZE)
    ) {
      throw new RangeError("live-ingest drain limit must be null or a positive bounded safe integer");
    }
    if (
      outboxFlushLimit !== null &&
      (!Number.isSafeInteger(outboxFlushLimit) || outboxFlushLimit < 1 ||
        outboxFlushLimit > OUTBOX_REPLAY_BATCH_SIZE)
    ) {
      throw new RangeError("live-ingest outbox limit must be null or a positive bounded safe integer");
    }
    if (this.pendingIngestDrain) return this.pendingIngestDrain;
    const drain = this.runPendingIngestJournal(
      maxEntries,
      outboxFlushLimit,
    ).finally(() => {
      if (this.pendingIngestDrain === drain) {
        this.pendingIngestDrain = null;
      }
    });
    this.pendingIngestDrain = drain;
    return drain;
  }

  private async runPendingIngestJournal(
    maxEntries: number | null,
    outboxFlushLimit: number | null,
  ): Promise<void> {
    let remaining = maxEntries;
    while (true) {
      if (remaining !== null && remaining <= 0) return;
      const limit = remaining === null
        ? OUTBOX_REPLAY_BATCH_SIZE
        : Math.min(remaining, OUTBOX_REPLAY_BATCH_SIZE);
      const pending = await this.state.storage.list<unknown>({
        prefix: PENDING_INGEST_PREFIX,
        limit,
      });
      if (pending.size === 0) return;

      for (const [key, value] of pending) {
        if (!isPendingIngestRecord(value)) {
          // Do not silently drop an unreadable durable event. It is safer to
          // retain the journal record, hold health stale, and require repair
          // than to claim an upstream event was safely persisted.
          console.error(
            JSON.stringify({
              journalKey: key,
              outcome: "invalid_live_ingest_journal_record",
            }),
          );
          await this.scheduleRelayAlarm(
            Date.now() + PENDING_INGEST_RETRY_DELAY_MS,
          );
          return;
        }
        try {
          await this.ingest(
            { ...value.event, raw: null },
            "live",
            outboxFlushLimit,
          );
          await this.state.storage.transaction(async (transaction) => {
            const current = await transaction.get<PendingIngestRecord>(key);
            // A newer record arrived while D1 committed the old one. Leave it
            // for the next loop; only the exact drained write may be removed.
            if (isPendingIngestRecord(current) && current.writeId === value.writeId) {
              await transaction.delete(key);
            }
          });
          // Freshness follows the durable D1/outbox transaction—not merely a
          // live WebSocket frame—so readiness exposes ingestion failures.
          await this.markSourceSuccessful(value.event.sourceId);
          if (remaining !== null) remaining -= 1;
        } catch (error) {
          console.error(
            JSON.stringify({
              eventId: value.event.eventId,
              sourceId: value.event.sourceId,
              outcome: "live_ingest_d1_retry",
              errorName: error instanceof Error ? error.name : "UnknownError",
            }),
          );
          await this.scheduleRelayAlarm(
            Date.now() + PENDING_INGEST_RETRY_DELAY_MS,
          );
          return;
        }
      }
    }
  }

  /**
   * D1 is the source of truth until a Queue consumer finalizes the row. A
   * conditional D1 claim prevents concurrent DO fetches, alarms, and health
   * checks from enqueueing the same alert fan-out globally. Queue acceptance
   * and the follow-up D1 write cannot be atomic, so a process crash can still
   * produce an at-least-once replay after the short claim lease; device-level
   * deduplication and APNs collapse IDs make that narrow recovery safe.
   */
  private async flushAlertDeliveryOutbox(
    limit = ROUTINE_OUTBOX_FLUSH_BATCH_SIZE,
  ): Promise<void> {
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > OUTBOX_REPLAY_BATCH_SIZE) {
      throw new RangeError("outbox flush limit must be a positive bounded safe integer");
    }
    const now = new Date().toISOString();
    const rows = await this.env.DB
      .prepare(
        `SELECT id, dedupe_key, delivery_id, root_delivery_id, event_ref,
                event_serial, event_json, notification_reason,
                after_device_cursor, created_at_utc, expires_at_utc,
                expiry_policy, terminal_reason, acknowledged_at_utc,
                last_enqueued_at_utc, next_enqueue_at_utc,
                queue_lease_until_utc, final_status, enqueue_attempts
         FROM alert_delivery_outbox
         WHERE acknowledged_at_utc IS NULL
           AND final_status IS NULL
           AND COALESCE(next_enqueue_at_utc, created_at_utc) <= ?
           AND (queue_lease_until_utc IS NULL OR queue_lease_until_utc <= ?)
         ORDER BY created_at_utc ASC
         LIMIT ?`,
      )
      .bind(now, now, limit)
      .all<AlertOutboxRow>();
    for (const row of rows.results) {
      const message = outboxRowToMessage(row);
      if (!message) {
        console.error(
          JSON.stringify({
            outboxId: row.id,
            outcome: "invalid_alert_outbox_record_pending",
          }),
        );
        continue;
      }
      const claimed = await this.claimOutboxForEnqueue(row.id);
      if (!claimed) continue;
      try {
        await this.env.ALERT_DELIVERY_QUEUE.send(message, {
          contentType: "json",
        });
        await this.commitOutboxQueueHandoff(row.id);
      } catch (error) {
        await this.releaseOutboxEnqueueClaim(row.id);
        console.error(
          JSON.stringify({
            outboxId: row.id,
            eventId: message.event.eventId,
            sourceId: message.event.sourceId,
            notificationReason: message.reason,
            outcome: "alert_queue_outbox_enqueue_failed",
            errorName: error instanceof Error ? error.name : "UnknownError",
          }),
        );
      }
    }
  }

  private async claimOutboxForEnqueue(outboxId: string): Promise<boolean> {
    const nowMs = Date.now();
    const now = new Date(nowMs).toISOString();
    const claimExpiresAt = new Date(
      nowMs + OUTBOX_ENQUEUE_CLAIM_LEASE_MS,
    ).toISOString();
    const result = await this.env.DB
      .prepare(
        `UPDATE alert_delivery_outbox
         SET queue_lease_until_utc = ?,
             last_enqueued_at_utc = ?,
             enqueue_attempts = enqueue_attempts + 1
         WHERE id = ?
           AND acknowledged_at_utc IS NULL
           AND final_status IS NULL
           AND COALESCE(next_enqueue_at_utc, created_at_utc) <= ?
           AND (queue_lease_until_utc IS NULL OR queue_lease_until_utc <= ?)`,
      )
      .bind(claimExpiresAt, now, outboxId, now, now)
      .run();
    return (result.meta.changes ?? 0) > 0;
  }

  private async commitOutboxQueueHandoff(outboxId: string): Promise<void> {
    const nowMs = Date.now();
    const sentLeaseExpiresAt = new Date(
      nowMs + OUTBOX_QUEUE_LEASE_MS,
    ).toISOString();
    await this.env.DB
      .prepare(
        `UPDATE alert_delivery_outbox
         SET queue_lease_until_utc = ?, next_enqueue_at_utc = ?
         WHERE id = ? AND acknowledged_at_utc IS NULL AND final_status IS NULL`,
      )
      .bind(sentLeaseExpiresAt, sentLeaseExpiresAt, outboxId)
      .run();
  }

  private async releaseOutboxEnqueueClaim(outboxId: string): Promise<void> {
    const retryAt = new Date(
      Date.now() + OUTBOX_ENQUEUE_FAILURE_RETRY_MS,
    ).toISOString();
    await this.env.DB
      .prepare(
        `UPDATE alert_delivery_outbox
         SET queue_lease_until_utc = NULL, next_enqueue_at_utc = ?
         WHERE id = ? AND acknowledged_at_utc IS NULL AND final_status IS NULL`,
      )
      .bind(retryAt, outboxId)
      .run();
  }

  /**
   * Finalize an obsolete page before it can make an APNs request. The database
   * row, rather than a Queue body, is authoritative for the deadline so an
   * at-least-once/replayed message cannot extend its own lifetime.
   */
  private async expireOutboxIfDue(
    message: AlertDeliveryMessage,
  ): Promise<OutboxDeliveryGateState> {
    // First enforce current-event ordering atomically in D1. Do this before
    // inspecting the Queue body or expiry: the outbox row and events table are
    // authoritative, and a delayed lower revision must never reach APNs after
    // a higher revision has committed.
    const now = new Date().toISOString();
    const superseded = await supersedeOutboxIfNewerRevisionStatement(
      this.env.DB,
      message.outboxId,
      now,
    ).run();
    if ((superseded.meta.changes ?? 0) > 0) return "superseded";
    const row = await this.env.DB
      .prepare(
        `SELECT acknowledged_at_utc, created_at_utc, expires_at_utc,
                expiry_policy, event_json, notification_reason
         FROM alert_delivery_outbox WHERE id = ?`,
      )
      .bind(message.outboxId)
      .first<OutboxDeliveryState>();
    if (!row) return "missing";
    if (row.acknowledged_at_utc !== null) return "acknowledged";

    let storedEvent: QueuedEvent | null = null;
    try {
      const parsed: unknown = JSON.parse(row.event_json);
      storedEvent = isQueuedEvent(parsed) ? parsed : null;
    } catch {
      storedEvent = null;
    }
    // An unreadable historical row is never safe to deliver. Give it the
    // creation-time fallback deadline, which is immediately overdue on any
    // normal replay, rather than trusting a Queue payload supplied elsewhere.
    const expiry = storedEvent && isNotifyReason(row.notification_reason)
      ? messageExpiry(
          {
            event: storedEvent,
            reason: row.notification_reason,
            expiresAtUtc: row.expires_at_utc ?? undefined,
            expiryPolicy: row.expiry_policy ?? undefined,
          },
          row.created_at_utc,
        )
      : {
          expiresAtUtc: row.created_at_utc,
          expiryPolicy: "legacy_created_at" as const,
        };
    const expiresAtMs = Date.parse(expiry.expiresAtUtc);
    // Carry the authoritative stored/derived deadline into a legacy Queue
    // body so any child page created below inherits it rather than resetting
    // the urgency window at the time of the replay.
    message.expiresAtUtc = expiry.expiresAtUtc;
    message.expiryPolicy = expiry.expiryPolicy;

    // Persist a derived fallback for pre-0008 rows before using it, so every
    // later page/replay observes the same deadline.
    if (row.expires_at_utc === null || row.expiry_policy === null) {
      await this.env.DB
        .prepare(
          `UPDATE alert_delivery_outbox
           SET expires_at_utc = COALESCE(expires_at_utc, ?),
               expiry_policy = COALESCE(expiry_policy, ?)
           WHERE id = ? AND acknowledged_at_utc IS NULL`,
        )
        .bind(expiry.expiresAtUtc, expiry.expiryPolicy, message.outboxId)
        .run();
    }
    if (!Number.isFinite(expiresAtMs) || expiresAtMs > Date.now()) {
      return "pending";
    }
    const result = await this.env.DB
      .prepare(
        `UPDATE alert_delivery_outbox
         SET acknowledged_at_utc = COALESCE(acknowledged_at_utc, ?),
             terminal_reason = COALESCE(terminal_reason, 'expired'),
             queue_lease_until_utc = NULL
         WHERE id = ? AND acknowledged_at_utc IS NULL`,
      )
      .bind(now, message.outboxId)
      .run();
    return (result.meta.changes ?? 0) > 0 ? "expired" : "acknowledged";
  }

  private async finalizeOutbox(
    outboxId: string,
    finalStatus: "delivered",
  ): Promise<boolean> {
    const result = await this.env.DB
      .prepare(
        `UPDATE alert_delivery_outbox
         SET acknowledged_at_utc = COALESCE(acknowledged_at_utc, ?),
             final_status = CASE
               WHEN terminal_reason IN ('expired', 'superseded') THEN final_status
               ELSE COALESCE(final_status, ?)
             END,
             terminal_reason = COALESCE(terminal_reason, ?),
             queue_lease_until_utc = NULL
         WHERE id = ?`,
      )
      .bind(new Date().toISOString(), finalStatus, finalStatus, outboxId)
      .run();
    return (result.meta.changes ?? 0) > 0;
  }

  private async purgeExpiredDevicesIfDue(): Promise<void> {
    const lastPurge = await this.state.storage.get<number>(LAST_DEVICE_PURGE_KEY);
    if (lastPurge && Date.now() - lastPurge < DEVICE_PURGE_INTERVAL_MS) return;

    const deviceCutoff = new Date(
      Date.now() - DEVICE_REGISTRATION_MAX_AGE_MS,
    ).toISOString();
    const deliveryCutoff = new Date(
      Date.now() - DELIVERY_DEDUP_RETENTION_MS,
    ).toISOString();
    await this.env.DB.batch([
      this.env.DB
        .prepare(
          `DELETE FROM notification_deliveries
           WHERE device_token IN (
             SELECT token FROM devices WHERE updated_at < ?
           )`,
        )
        .bind(deviceCutoff),
      this.env.DB
        .prepare("DELETE FROM notification_deliveries WHERE delivered_at_utc < ?")
        .bind(deliveryCutoff),
      this.env.DB
        .prepare(
          `DELETE FROM alert_delivery_failures
           WHERE last_seen_utc < ?`,
        )
        .bind(deliveryCutoff),
      // Resolved provider-page evidence and terminal outbox payload snapshots
      // have the same short operational retention as delivery deduplication.
      // Active page failures are deliberately retained: a deadline may expire
      // an old EEW page before a human fixes the APNs provider configuration.
      this.env.DB
        .prepare(
          `DELETE FROM alert_delivery_page_failures
           WHERE status = 'resolved' AND last_seen_utc < ?`,
        )
        .bind(deliveryCutoff),
      this.env.DB
        .prepare(
          `DELETE FROM alert_delivery_outbox
           WHERE acknowledged_at_utc IS NOT NULL
             AND terminal_reason IS NOT NULL
             AND acknowledged_at_utc < ?`,
        )
        .bind(deliveryCutoff),
      this.env.DB
        .prepare("DELETE FROM devices WHERE updated_at < ?")
        .bind(deviceCutoff),
      ...appAttestRetentionCleanupStatements(
        this.env.DB,
        new Date().toISOString(),
      ),
    ]);
    await this.state.storage.put(LAST_DEVICE_PURGE_KEY, Date.now());
  }

  private async deliverQueuedPage(
    message: AlertDeliveryMessage,
  ): Promise<Response> {
    try {
      const expiryState = await this.expireOutboxIfDue(message);
      if (expiryState === "acknowledged") {
        return Response.json({ ok: true, alreadyAcknowledged: true });
      }
      if (expiryState === "expired") {
        console.info(
          JSON.stringify({
            outboxId: message.outboxId,
            eventId: message.event.eventId,
            sourceId: message.event.sourceId,
            notificationReason: message.reason,
            outcome: "alert_delivery_expired_before_apns",
          }),
        );
        return Response.json({ ok: true, expired: true });
      }
      if (expiryState === "superseded") {
        console.info(
          JSON.stringify({
            outboxId: message.outboxId,
            eventId: message.event.eventId,
            sourceId: message.event.sourceId,
            notificationReason: message.reason,
            outcome: "alert_delivery_superseded_before_apns",
          }),
        );
        return Response.json({ ok: true, superseded: true });
      }
      if (expiryState === "missing") {
        // A terminal row may have passed the retention window while an old
        // Queue copy was delayed. It is already unsafe to deliver, so finish
        // the stale Queue message without manufacturing a false DLQ incident.
        console.warn(
          JSON.stringify({
            outboxId: message.outboxId,
            outcome: "alert_delivery_outbox_missing_discarded",
          }),
        );
        return Response.json({ ok: true, outboxMissing: true });
      }
      const event = eventFromDeliveryMessage(message);
      const authorization = await this.apnsAuthorization();
      const page = await dispatchPushPage(
        this.env,
        event,
        message.reason,
        authorization,
        message.deliveryId,
        message.afterDeviceCursor,
        () => this.expireOutboxIfDue(message),
      );
      if (page.terminalState !== null) {
        const outcome = page.terminalState === "superseded"
          ? "alert_delivery_superseded_during_page"
          : "alert_delivery_terminal_before_next_apns_batch";
        console.info(
          JSON.stringify({
            outboxId: message.outboxId,
            eventId: message.event.eventId,
            sourceId: message.event.sourceId,
            notificationReason: message.reason,
            outcome,
            terminalState: page.terminalState,
          }),
        );
        return Response.json({ ok: true, terminalState: page.terminalState });
      }
      if (page.pageFailure) {
        logApnsPageFailure(event, message.reason, message.outboxId, page.pageFailure);
        await recordPageDeliveryFailure(
          this.env.DB,
          message.outboxId,
          message,
          page.pageFailure,
        );
      } else {
        // A successful/non-provider retry proves the page-level provider
        // incident cleared even if one recipient still needs its own retry.
        await resolvePageDeliveryFailure(this.env.DB, message.outboxId);
      }
      if (page.pageFailure === null && page.nextAfterDeviceCursor !== null) {
        const nextPage = createAlertDeliveryMessage(
          event,
          message.reason,
          page.nextAfterDeviceCursor,
          message.rootDeliveryId,
          message.expiresAtUtc,
          message.expiryPolicy,
        );
        await appendOutbox(this.env.DB, nextPage, nextPage.deliveryId);
      }
      if (page.retryRequired) {
        if (page.invalidateApnsJwt) this.apnsJwtCache = null;
        // Do not create an unbounded chain of retry-outbox children. Returning
        // a retry response lets the primary Queue apply its configured five
        // bounded attempts to this same leased outbox row. Confirmed devices
        // and quarantined permanent failures are skipped on the next attempt.
        await this.flushAlertDeliveryOutbox();
        return Response.json(
          { error: "delivery retry required" },
          {
            status: 503,
            headers: {
              [DELIVERY_RETRY_DELAY_HEADER]: String(page.retryDelaySeconds),
            },
          },
        );
      }
      await this.flushAlertDeliveryOutbox();
      return Response.json({ ok: true });
    } catch (error) {
      const pageFailure: ApnsDeliveryResult = {
        ok: false,
        apnsId: null,
        apnsReason:
          error instanceof MissingApnsConfigurationError
            ? "MissingApnsConfiguration"
            : "DeliveryException",
      };
      console.warn(
        JSON.stringify({
          eventId: message.event.eventId,
          sourceId: message.event.sourceId,
          notificationReason: message.reason,
          outcome:
            error instanceof MissingApnsConfigurationError
              ? "alert_delivery_apns_not_configured_retry"
              : "alert_delivery_page_retry",
          errorName: error instanceof Error ? error.name : "UnknownError",
        }),
      );
      try {
        logApnsPageFailure(
          eventFromDeliveryMessage(message),
          message.reason,
          message.outboxId,
          pageFailure,
        );
        await recordPageDeliveryFailure(
          this.env.DB,
          message.outboxId,
          message,
          pageFailure,
        );
      } catch (recordError) {
        // A D1 outage must not turn a delivery exception into a successful
        // Queue acknowledgement. The 503 below still preserves bounded retry.
        console.error(
          JSON.stringify({
            outboxId: message.outboxId,
            outcome: "alert_delivery_page_failure_record_retry",
            errorName: recordError instanceof Error
              ? recordError.name
              : "UnknownError",
          }),
        );
      }
      return Response.json(
        { error: "delivery retry required" },
        {
          status: 503,
          headers: {
            [DELIVERY_RETRY_DELAY_HEADER]: String(
              apnsRetryDelaySeconds(pageFailure),
            ),
          },
        },
      );
    }
  }

  private async ensureUpstreams(): Promise<void> {
    const now = Date.now();
    for (const route of UPSTREAM_ROUTES) {
      const current = this.upstreams.get(route);
      // A transport can remain nominally open while heartbeats/data stop.
      // Treat a stale route as a failed route: close it, persist degradation,
      // and let the same bounded reconnect/fallback policy recover it.
      if (current?.readyState === 1 && !this.routeIsOpen(route)) {
        this.upstreams.delete(route);
        try {
          current.close(1011);
        } catch {
          // The stale socket may already be closing; the durable recovery
          // request below remains the authoritative state transition.
        }
        await this.scheduleUpstreamReconnect(
          route,
          "wolfx_upstream_websocket_stale",
          {},
          "closed",
        );
        continue;
      }
      if (
        this.connectingRoutes.has(route) ||
        (current && (current.readyState === 0 || current.readyState === 1))
      ) {
        continue;
      }
      const notBefore = await this.state.storage.get<number>(
        `${UPSTREAM_RECONNECT_NOT_BEFORE_PREFIX}${route}`,
      );
      if (typeof notBefore === "number" && Number.isFinite(notBefore) && notBefore > now) {
        // Preserve strict readiness while respecting a persisted backoff after
        // an upstream-side rejection. The routine alarm still owns D1/outbox
        // maintenance, but this route must not create another handshake yet.
        this.setRouteStatus(route, "error");
        continue;
      }
      this.connect(route);
    }
  }

  private routeIsOpen(route: UpstreamRoute): boolean {
    const sources: WolfxSourceId[] =
      route === "all_eew" ? EEW_SOURCES : [route];
    const now = Date.now();
    return sources.every((source) => !isUpstreamSourceStale(
      this.statuses.get(source) ?? "connecting",
      this.lastSuccessfulUpstreamMs.get(source),
      false,
      now,
    ));
  }

  private allRoutesOpen(): boolean {
    return UPSTREAM_ROUTES.every((route) => this.routeIsOpen(route));
  }

  private async allRoutesHaveBeenDegradedForGrace(now: number): Promise<boolean> {
    if (UPSTREAM_ROUTES.some((route) => this.routeIsOpen(route))) return false;
    const degradedSince = await Promise.all(
      UPSTREAM_ROUTES.map((route) =>
        this.state.storage.get<number>(
          `${UPSTREAM_DEGRADED_SINCE_PREFIX}${route}`,
        )
      ),
    );
    return degradedSince.every(
      (degradedAt) =>
        typeof degradedAt === "number" &&
        Number.isFinite(degradedAt) &&
        degradedAt > 0 &&
        degradedAt <= now - HTTP_RECOVERY_SEED_GRACE_MS,
    );
  }

  /**
   * Enter the HTTP alternate transport only after every live WebSocket route
   * has remained down through the grace period. Once active, retain it during
   * partial socket recovery so one still-broken source cannot make health
   * optimistic; remove it only after all routes are demonstrably open again.
   */
  private async refreshHttpFallbackActive(): Promise<boolean> {
    const current = await this.readHttpFallbackActive();
    if (this.allRoutesOpen()) {
      if (current) await this.state.storage.put(HTTP_FALLBACK_ACTIVE_KEY, false);
      // A partially durable HTTP report list remains health-stale even after
      // WebSockets recover. Preserve its retry pacing until it completes.
      if ((await this.pendingHttpSnapshotSources()).length === 0) {
        await this.clearHttpFallbackDeferral();
      }
      return false;
    }
    if (current === true) return true;
    if (!await this.allRoutesHaveBeenDegradedForGrace(Date.now())) return false;
    await this.state.storage.put(HTTP_FALLBACK_ACTIVE_KEY, true);
    return true;
  }

  /**
   * Return only the persisted alternate-transport state. Unlike
   * `refreshHttpFallbackActive`, this method never clears or activates the
   * marker, so `/healthz` remains safe to serve when Durable Object writes are
   * temporarily unavailable.
   */
  private async readHttpFallbackActive(): Promise<boolean> {
    return (await this.state.storage.get<boolean>(HTTP_FALLBACK_ACTIVE_KEY)) === true;
  }

  private async httpFallbackTurnIsDue(now: number): Promise<boolean> {
    const notBefore = await this.state.storage.get<number>(
      HTTP_FALLBACK_RETRY_NOT_BEFORE_KEY,
    );
    return !(
      typeof notBefore === "number" &&
      Number.isFinite(notBefore) &&
      notBefore > now
    );
  }

  private async deferHttpFallbackTurn(error: unknown): Promise<void> {
    await this.state.storage.put(
      HTTP_FALLBACK_RETRY_NOT_BEFORE_KEY,
      Date.now() + HTTP_FALLBACK_FAILURE_RETRY_MS,
    );
    console.warn(
      JSON.stringify({
        outcome: "wolfx_http_fallback_turn_deferred",
        errorName: error instanceof Error ? error.name : "UnknownError",
      }),
    );
  }

  /**
   * Delete only a real persisted deferral. A blind delete is still a billed
   * Durable Object row write, so the common successful fallback path must not
   * spend one every sweep merely to clear an absent key.
   */
  private async clearHttpFallbackDeferral(): Promise<void> {
    const notBefore = await this.state.storage.get<number>(
      HTTP_FALLBACK_RETRY_NOT_BEFORE_KEY,
    );
    if (typeof notBefore === "number" && Number.isFinite(notBefore)) {
      await this.state.storage.delete(HTTP_FALLBACK_RETRY_NOT_BEFORE_KEY);
    }
  }

  /**
   * Older deployed revisions may still be finishing one HTTP sweep under
   * either legacy lease shape. Read the records only as a rolling-deploy
   * fence—new code never extends, clears, or otherwise mutates them.
   */
  private async legacyHttpSeedFenceUntil(): Promise<number> {
    const [legacyLease, cursorLease] = await Promise.all([
      this.state.storage.get<unknown>(LEGACY_HTTP_SEED_LEASE_UNTIL_KEY),
      this.state.storage.get<unknown>(HTTP_SEED_LEASE_V2_KEY),
    ]);
    return Math.max(
      legacyHttpSeedLeaseUntil(legacyLease) ?? 0,
      legacyHttpSeedLeaseUntil(cursorLease) ?? 0,
    );
  }

  /**
   * Wake at the exact alternate-transport activation boundary rather than
   * waiting for a later 60-second maintenance alarm. A currently active
   * fallback owns the next paced source request.
   */
  private async nextHttpFallbackAlarmAt(now: number): Promise<number | null> {
    const active = await this.state.storage.get<boolean>(HTTP_FALLBACK_ACTIVE_KEY);
    const pendingWorks = await this.pendingHttpSnapshotWorks();
    if (active === true || pendingWorks.length > 0) {
      const legacyFenceAt = await this.legacyHttpSeedFenceUntil();
      if (legacyFenceAt > now) return legacyFenceAt;
      const notBefore = await this.state.storage.get<number>(
        HTTP_FALLBACK_RETRY_NOT_BEFORE_KEY,
      );
      if (
        typeof notBefore === "number" &&
        Number.isFinite(notBefore) &&
        notBefore > now
      ) {
        return notBefore;
      }
    }
    if (pendingWorks.length > 0) {
      // A changed snapshot remains health-stale until its final cursor commits.
      // Resume its bounded D1 slices quickly enough to complete a 50-entry
      // report list before HTTP freshness goes stale. This is exceptional
      // changed-data work, not the unchanged-source polling cadence.
      const lastResumeAt = this.lastHttpSnapshotResumeStartedMs;
      return typeof lastResumeAt !== "number" ||
          !Number.isFinite(lastResumeAt) ||
          lastResumeAt > now ||
          now - lastResumeAt >= HTTP_SNAPSHOT_RESUME_INTERVAL_MS
        ? now + 1
        : lastResumeAt + HTTP_SNAPSHOT_RESUME_INTERVAL_MS;
    }
    if (active === true) {
      const legacyFenceAt = await this.legacyHttpSeedFenceUntil();
      if (legacyFenceAt > now) return legacyFenceAt;
      const nextSweepAt = await this.state.storage.get<number>(
        HTTP_FALLBACK_NEXT_SWEEP_AT_KEY,
      );
      return typeof nextSweepAt !== "number" ||
          !Number.isFinite(nextSweepAt) ||
          nextSweepAt <= now
        ? now + 1
        : nextSweepAt;
    }
    const initialSeedComplete = await this.state.storage.get<boolean>(
      INITIAL_HTTP_SEED_COMPLETE_KEY,
    );
    if (!initialSeedComplete) {
      const legacyFenceAt = await this.legacyHttpSeedFenceUntil();
      if (legacyFenceAt > now) return legacyFenceAt;
      const lastSeedMs = await this.state.storage.get<number>(LAST_HTTP_SEED_MS_KEY);
      if (isInitialHttpSeedDue(lastSeedMs, now)) return now + 1;
    }
    if (UPSTREAM_ROUTES.some((route) => this.routeIsOpen(route))) return null;
    const degradedSince = await Promise.all(
      UPSTREAM_ROUTES.map((route) =>
        this.state.storage.get<number>(
          `${UPSTREAM_DEGRADED_SINCE_PREFIX}${route}`,
        )
      ),
    );
    if (
      degradedSince.some(
        (degradedAt) =>
          typeof degradedAt !== "number" ||
          !Number.isFinite(degradedAt) ||
          degradedAt <= 0,
      )
    ) {
      return null;
    }
    const activationAt = Math.max(...(degradedSince as number[])) +
      HTTP_RECOVERY_SEED_GRACE_MS;
    return activationAt > now ? activationAt : now + 1;
  }

  private async nextUpstreamReconnectAlarmAt(now: number): Promise<number | null> {
    const candidates = await Promise.all(
      UPSTREAM_ROUTES.map((route) =>
        this.state.storage.get<number>(
          `${UPSTREAM_RECONNECT_NOT_BEFORE_PREFIX}${route}`,
        )
      ),
    );
    const upcoming = candidates.filter(
      (value): value is number =>
        typeof value === "number" && Number.isFinite(value) && value > now,
    );
    return upcoming.length > 0 ? Math.min(...upcoming) : null;
  }

  private async shouldRunHttpRecoverySeed(): Promise<boolean> {
    const now = Date.now();
    if (!await this.refreshHttpFallbackActive()) return false;
    if (await this.legacyHttpSeedFenceUntil() > now) return false;
    const nextSweepAt = await this.state.storage.get<number>(
      HTTP_FALLBACK_NEXT_SWEEP_AT_KEY,
    );
    return typeof nextSweepAt !== "number" ||
      !Number.isFinite(nextSweepAt) ||
      nextSweepAt <= now;
  }

  private async nextHttpSeedSource(
    candidates: readonly WolfxSourceId[],
  ): Promise<WolfxSourceId | null> {
    if (candidates.length === 0) return null;
    const storedIndex = await this.state.storage.get<number>(
      HTTP_SEED_SOURCE_CURSOR_KEY,
    );
    const start = typeof storedIndex === "number" &&
        Number.isSafeInteger(storedIndex) && storedIndex >= 0
      ? storedIndex % ALL_WOLFX_SOURCES.length
      : 0;
    for (let offset = 0; offset < ALL_WOLFX_SOURCES.length; offset += 1) {
      const index = (start + offset) % ALL_WOLFX_SOURCES.length;
      const candidate = ALL_WOLFX_SOURCES[index];
      if (candidates.includes(candidate)) return candidate;
    }
    return null;
  }

  private async advanceHttpSeedSource(
    source: WolfxSourceId,
  ): Promise<boolean> {
    const index = ALL_WOLFX_SOURCES.indexOf(source);
    const next = (index + 1) % ALL_WOLFX_SOURCES.length;
    const storage = this.state.storage;
    const advance = async (target: DurableKeyValueStore): Promise<boolean> => {
      await target.put(HTTP_SEED_SOURCE_CURSOR_KEY, next);
      return true;
    };
    if (typeof storage.transaction !== "function") return advance(storage);
    return storage.transaction((transaction) => advance(transaction));
  }

  /**
   * Select an alarm-owned HTTP mode. Recovery may inspect every unchanged
   * degraded source in its once-per-minute sweep, but stops after the first
   * changed snapshot claims durable D1 work; that work cannot share a turn
   * with ordinary relay maintenance.
   */
  private async nextDueHttpSeedMode(
    fallbackActive: boolean,
  ): Promise<"initial" | "recovery" | null> {
    const now = Date.now();
    const lastSeedMs = await this.state.storage.get<number>(LAST_HTTP_SEED_MS_KEY);
    const pendingWork = (await this.pendingHttpSnapshotWorks())[0];
    if (pendingWork) {
      if (await this.legacyHttpSeedFenceUntil() > now) return null;
      const lastResumeAt = this.lastHttpSnapshotResumeStartedMs;
      return typeof lastResumeAt !== "number" ||
          !Number.isFinite(lastResumeAt) ||
          lastResumeAt > now ||
          now - lastResumeAt >= HTTP_SNAPSHOT_RESUME_INTERVAL_MS
        ? pendingWork.mode
        : null;
    }
    if (fallbackActive) {
      if (!await this.httpFallbackTurnIsDue(now)) return null;
      if (await this.legacyHttpSeedFenceUntil() > now) return null;
      const nextSweepAt = await this.state.storage.get<number>(
        HTTP_FALLBACK_NEXT_SWEEP_AT_KEY,
      );
      return typeof nextSweepAt !== "number" ||
          !Number.isFinite(nextSweepAt) ||
          nextSweepAt <= now
        ? "recovery"
        : null;
    }
    const initialSeedComplete = await this.state.storage.get<boolean>(
      INITIAL_HTTP_SEED_COMPLETE_KEY,
    );
    if (initialSeedComplete) return null;
    if (await this.legacyHttpSeedFenceUntil() > now) return null;
    return isInitialHttpSeedDue(lastSeedMs, now) ? "initial" : null;
  }

  private sourcesNeedingHttpRecovery(now = Date.now()): WolfxSourceId[] {
    return ALL_WOLFX_SOURCES.filter(
      (source) => isUpstreamSourceStale(
        this.statuses.get(source) ?? "connecting",
        this.lastSuccessfulUpstreamMs.get(source),
        false,
        now,
      ),
    );
  }

  /**
   * Rotate the emergency sweep from a time-derived offset. This costs no
   * durable write and prevents a frequently changing early source from always
   * consuming the one changed-snapshot D1 slice before later sources are
   * sampled.
   */
  private recoverySweepSources(startedAtMs: number): WolfxSourceId[] {
    const candidates = this.sourcesNeedingHttpRecovery(startedAtMs);
    if (candidates.length === 0) return [];
    const offset = Math.floor(startedAtMs / HTTP_FALLBACK_SWEEP_INTERVAL_MS) %
      candidates.length;
    return Array.from({ length: candidates.length }, (_, index) =>
      candidates[(offset + index) % candidates.length]
    );
  }

  private async statusResponse(): Promise<Response> {
    let activeDlqIncidents: number | null;
    let activePageFailures: number | null;
    let activeQuarantinedFailures: number | null;
    let activeRetryFailures: number | null;
    let pendingOutboxRows: number | null;
    let staleOutboxRows: number | null;
    let pendingDlqPersistenceFallbacks: boolean | null;
    try {
      activeDlqIncidents =
        (await this.env.DB
          .prepare(
            "SELECT COUNT(*) AS active_count FROM alert_delivery_incidents WHERE status = 'active'",
          )
          .first<number>("active_count")) ?? 0;
    } catch {
      activeDlqIncidents = null;
    }
    try {
      activePageFailures =
        (await this.env.DB
          .prepare(
            "SELECT COUNT(*) AS active_count FROM alert_delivery_page_failures WHERE status = 'active'",
          )
          .first<number>("active_count")) ?? 0;
    } catch {
      activePageFailures = null;
    }
    try {
      activeQuarantinedFailures =
        (await this.env.DB
          .prepare(
            `SELECT COUNT(*) AS active_count FROM alert_delivery_failures
             WHERE status = 'active' AND disposition = 'quarantine'`,
          )
          .first<number>("active_count")) ?? 0;
    } catch {
      activeQuarantinedFailures = null;
    }
    try {
      activeRetryFailures =
        (await this.env.DB
          .prepare(
            `SELECT COUNT(*) AS active_count FROM alert_delivery_failures
             WHERE status = 'active' AND disposition = 'retry'`,
          )
          .first<number>("active_count")) ?? 0;
    } catch {
      activeRetryFailures = null;
    }
    try {
      const outboxCounts = await this.env.DB
        .prepare(
          `SELECT COUNT(*) AS pending_count,
                  SUM(CASE WHEN created_at_utc <= ? THEN 1 ELSE 0 END) AS stale_count
           FROM alert_delivery_outbox
           WHERE acknowledged_at_utc IS NULL AND final_status IS NULL`,
        )
        .bind(
          new Date(Date.now() - OUTBOX_STALE_AFTER_MS).toISOString(),
        )
        .first<{ pending_count: number; stale_count: number | null }>();
      pendingOutboxRows = outboxCounts?.pending_count ?? 0;
      staleOutboxRows = outboxCounts?.stale_count ?? 0;
    } catch {
      pendingOutboxRows = null;
      staleOutboxRows = null;
    }
    try {
      const pendingFallback = await this.state.storage.list({
        prefix: DLQ_PERSISTENCE_FALLBACK_PREFIX,
        limit: 1,
      });
      pendingDlqPersistenceFallbacks = pendingFallback.size > 0;
    } catch {
      // Do not claim a ready delivery path if the D1-independent evidence
      // store cannot be inspected. This is a real Durable Object storage
      // signal, not an inference from Queue depth.
      pendingDlqPersistenceFallbacks = null;
    }
    let apnsConfigured = false;
    if (hasApnsConfiguration(this.env)) {
      try {
        // This validates the key material locally without turning `/healthz`
        // into an APNs network probe. APNs response failures are represented by
        // active retry/quarantine rows once a delivery is attempted.
        await this.apnsAuthorization();
        apnsConfigured = true;
      } catch {
        apnsConfigured = false;
      }
    }
    const delivery: DeliveryHealth = {
      apnsConfigured,
      activeDlqIncidents,
      pendingDlqPersistenceFallbacks,
      activePageFailures,
      activeQuarantinedFailures,
      activeRetryFailures,
      pendingOutboxRows,
      staleOutboxRows,
      status: deliveryReadinessStatus({
        apnsConfigured,
        activeDlqIncidents,
        pendingDlqPersistenceFallbacks,
        activePageFailures,
        activeQuarantinedFailures,
        activeRetryFailures,
        pendingOutboxRows,
        staleOutboxRows,
      }),
    };
    const now = Date.now();
    // This status calculation is read-only. The alarm owns changes to this
    // marker; in particular, a Durable Object write-quota failure must leave
    // `/healthz` able to return a structured, fail-closed response rather
    // than turning a status probe into an exception.
    const httpFallbackActive = await this.readHttpFallbackActive();
    const sourceHealth = await Promise.all(
      ALL_WOLFX_SOURCES.map(async (source) => {
        const [persisted, persistedHttp, pendingJournal, pendingHttpWork] = await Promise.all([
          this.state.storage.get<number>(
            `${UPSTREAM_LAST_SUCCESS_PREFIX}${source}`,
          ),
          this.state.storage.get<number>(
            `${UPSTREAM_LAST_HTTP_SUCCESS_PREFIX}${source}`,
          ),
          this.state.storage.list({
            prefix: `${PENDING_INGEST_PREFIX}${source}:`,
            limit: 1,
          }),
          this.state.storage.get<unknown>(httpSnapshotWorkStorageKey(source)),
        ]);
        const lastWebSocketSuccessMs = this.lastSuccessfulUpstreamMs.get(source) ??
          persisted;
        const lastHttpSuccessMs = this.lastSuccessfulHttpPollMs.get(source) ??
          persistedHttp;
        const status = this.statuses.get(source) ?? "connecting";
        const hasPendingLiveIngest = pendingJournal.size > 0;
        // A malformed cursor is still an unfinished durability signal. Fail
        // closed until an alarm clears/rebuilds it; never let a prior fresh
        // HTTP timestamp hide corrupt alternate-transport work.
        const hasPendingHttpSnapshot = pendingHttpWork !== undefined;
        const websocketStale = isUpstreamSourceStale(
          status,
          lastWebSocketSuccessMs,
          hasPendingLiveIngest,
          now,
        );
        const httpStale = isHttpFallbackSourceStale(
          lastHttpSuccessMs,
          hasPendingLiveIngest || hasPendingHttpSnapshot,
          now,
        );
        const transport = !websocketStale
          ? "websocket"
          : httpFallbackActive && !httpStale
            ? "http-polling"
            : "unavailable";
        const lastSuccessMs = transport === "http-polling"
          ? lastHttpSuccessMs
          : lastWebSocketSuccessMs;
        return {
          source,
          status,
          transport,
          lastSuccessUtc: lastSuccessMs
            ? new Date(lastSuccessMs).toISOString()
            : null,
          lastWebSocketSuccessUtc: lastWebSocketSuccessMs
            ? new Date(lastWebSocketSuccessMs).toISOString()
            : null,
          lastHttpSuccessUtc: lastHttpSuccessMs
            ? new Date(lastHttpSuccessMs).toISOString()
            : null,
          pendingLiveIngest: hasPendingLiveIngest,
          pendingHttpSnapshot: hasPendingHttpSnapshot,
          websocketStale,
          httpStale,
          // A partially persisted HTTP snapshot is deliberately not ready
          // even when WebSocket traffic has recovered: otherwise /healthz
          // could declare success before the alternate transport's durable
          // cursor has finished committing its bounded event slices.
          stale: transport === "unavailable" || hasPendingHttpSnapshot,
        };
      }),
    );
    const staleSources = sourceHealth
      .filter((source) => source.stale)
      .map((source) => source.source);
    const pendingIngestSources = sourceHealth
      .filter((source) => source.pendingLiveIngest || source.pendingHttpSnapshot)
      .map((source) => source.source);
    const websocketStatus = sourceHealth.every((source) => !source.websocketStale)
      ? "ready"
      : "degraded";
    const activeTransports = new Set(sourceHealth.map((source) => source.transport));
    const transport = staleSources.length > 0
      ? "degraded"
      : activeTransports.size === 1 && activeTransports.has("websocket")
        ? "websocket"
        : activeTransports.size === 1 && activeTransports.has("http-polling")
          ? "http-polling"
          : "mixed";
    const upstream = {
      status: staleSources.length === 0 ? "ready" : "degraded",
      transport,
      websocketStatus,
      httpFallbackActive,
      staleSources,
      pendingIngestSources,
      sources: Object.fromEntries(
        sourceHealth.map((source) => [
          source.source,
          {
            status: source.status,
            transport: source.transport,
            lastSuccessUtc: source.lastSuccessUtc,
            lastWebSocketSuccessUtc: source.lastWebSocketSuccessUtc,
            lastHttpSuccessUtc: source.lastHttpSuccessUtc,
            pendingLiveIngest: source.pendingLiveIngest,
            pendingHttpSnapshot: source.pendingHttpSnapshot,
            websocketStale: source.websocketStale,
            httpStale: source.httpStale,
            stale: source.stale,
          },
        ]),
      ),
    };
    // A notification service with a stale/closed upstream route or missing
    // APNs authentication must fail health checks; this is intentionally a
    // readiness signal, not a superficial process liveness probe.
    const healthy = delivery.status === "ready" && upstream.status === "ready";
    return Response.json(
      {
        ok: healthy,
        mode: "notification-only",
        upstreams: Object.fromEntries(
          sourceHealth.map((source) => [source.source, source.status]),
        ),
        upstream,
        delivery,
      },
      { status: healthy ? 200 : 503 },
    );
  }

  private connect(route: UpstreamRoute): void {
    if (this.connectingRoutes.has(route)) return;
    this.setRouteStatus(route, "connecting");
    this.connectingRoutes.add(route);
    // `fetch(... Upgrade)` is the documented alternative client path for
    // Workers. It gives us a response status for a rejected Wolfx handshake,
    // unlike the constructor's generic `error` event, while still retaining a
    // standard WebSocket after a successful Upgrade.
    this.state.waitUntil(this.connectWithUpgrade(route));
  }

  private serializeRelayAlarm<T>(
    operation: () => Promise<T>,
  ): Promise<T> {
    const queued = this.relayAlarmWrite.then(operation, operation);
    // Retain a usable serial queue even if a storage write fails. The caller
    // continues to receive its own error so operational failure is not hidden.
    this.relayAlarmWrite = queued.then(
      () => undefined,
      () => undefined,
    );
    return queued;
  }

  private scheduleRelayAlarm(requestedAtMs: number): Promise<void> {
    return this.serializeRelayAlarm(async () => {
      const now = Date.now();
      const requested =
        Number.isFinite(requestedAtMs) && requestedAtMs > now
          ? requestedAtMs
          : now + PENDING_INGEST_RETRY_DELAY_MS;
      const existing = await this.state.storage.getAlarm();
      if (
        typeof existing === "number" &&
        Number.isFinite(existing) &&
        existing > now &&
        existing <= requested
      ) return;
      await this.state.storage.setAlarm(requested);
    });
  }

  private scheduleRoutineRelayAlarm(): Promise<void> {
    return this.serializeRelayAlarm(async () => {
      const now = Date.now();
      const existing = await this.state.storage.getAlarm();
      const routineAlarmAt = preferredRelayAlarmAt(null, now);
      const [fallbackAlarmAt, reconnectAlarmAt] = await Promise.all([
        this.nextHttpFallbackAlarmAt(now),
        this.nextUpstreamReconnectAlarmAt(now),
      ]);
      const requestedAlarmAt = Math.min(
        routineAlarmAt,
        ...(fallbackAlarmAt === null ? [] : [fallbackAlarmAt]),
        ...(reconnectAlarmAt === null ? [] : [reconnectAlarmAt]),
      );
      if (
        typeof existing === "number" &&
        Number.isFinite(existing) &&
        existing > now &&
        existing <= requestedAlarmAt
      ) return;
      await this.state.storage.setAlarm(requestedAlarmAt);
    });
  }

  private async connectWithUpgrade(route: UpstreamRoute): Promise<void> {
    let socket: WebSocket | null = null;
    try {
      const response = await withWolfxUpgradeTimeout((signal) =>
        fetch(`https://ws-api.wolfx.jp/${route}`, {
          signal,
          headers: { Upgrade: "websocket" },
        })
      );
      socket = response.webSocket;
      if (!socket) {
        // An unsuccessful Upgrade can carry an arbitrary upstream body. We do
        // not retain or log it; cancel it promptly and record only status.
        try {
          await response.body?.cancel();
        } catch {
          // The rejected handshake remains authoritative even if the upstream
          // body has already been closed by the runtime.
        }
        await this.scheduleUpstreamReconnect(route, "wolfx_upstream_upgrade_rejected", {
          httpStatus: Number.isSafeInteger(response.status)
            ? response.status
            : null,
        });
        return;
      }

      // The fetch promise resolves after the HTTP Upgrade, so there is no
      // constructor-style `open` event to use as the activation boundary.
      // Store and subscribe before accept() so a very fast close/error cannot
      // be lost, then explicitly mark ready and issue the Wolfx snapshots.
      this.upstreams.set(route, socket);
      this.attachUpstreamSocketListeners(route, socket);
      socket.accept();
      if (this.upstreams.get(route) !== socket) {
        return;
      }
      this.activateUpstreamSocket(route, socket);
    } catch (error) {
      const ownsRecovery = socket === null || this.upstreams.get(route) === socket;
      if (socket && ownsRecovery) {
        this.upstreams.delete(route);
        try {
          socket.close(1011);
        } catch {
          // A failed accept/send can already have closed the socket. The
          // scheduled reconnect below remains the authoritative recovery.
        }
      }
      // A synchronous close/error listener can already have removed this
      // socket and queued its own reconnect. In that case it is the sole
      // recovery owner; incrementing again would skip a backoff step.
      if (ownsRecovery) {
        await this.scheduleUpstreamReconnect(route, "wolfx_upstream_upgrade_error", {
          errorName: error instanceof Error ? error.name : "UnknownError",
        });
      }
    } finally {
      this.connectingRoutes.delete(route);
    }
  }

  private scheduleUpstreamReconnect(
    route: UpstreamRoute,
    outcome:
      | "wolfx_upstream_upgrade_rejected"
      | "wolfx_upstream_upgrade_error"
      | "wolfx_upstream_websocket_closed"
      | "wolfx_upstream_websocket_error"
      | "wolfx_upstream_websocket_stale",
    detail: Record<string, unknown>,
    status: "closed" | "error" = "error",
  ): Promise<void> {
    return this.serializeRelayAlarm(async () => {
      const now = Date.now();
      const failureKey = `${UPSTREAM_RECONNECT_FAILURE_PREFIX}${route}`;
      const currentFailures = await this.state.storage.get<number>(failureKey);
      const failureCount =
        typeof currentFailures === "number" &&
        Number.isSafeInteger(currentFailures) &&
        currentFailures > 0
          ? Math.min(currentFailures + 1, 32)
          : 1;
      const retryDelayMs = upstreamReconnectDelayMs(failureCount, route);
      const reconnectAtMs = now + retryDelayMs;
      await this.state.storage.put(failureKey, failureCount);
      await this.state.storage.put(
        `${UPSTREAM_RECONNECT_NOT_BEFORE_PREFIX}${route}`,
        reconnectAtMs,
      );
      const degradedSinceKey = `${UPSTREAM_DEGRADED_SINCE_PREFIX}${route}`;
      const degradedSinceMs = await this.state.storage.get<number>(
        degradedSinceKey,
      );
      if (
        typeof degradedSinceMs !== "number" ||
        !Number.isFinite(degradedSinceMs) ||
        degradedSinceMs <= 0 ||
        degradedSinceMs > now
      ) {
        await this.state.storage.put(degradedSinceKey, now);
      }
      console.warn(
        JSON.stringify({
          outcome,
          route,
          ...detail,
          failureCount,
          retryDelayMs,
          reconnectAtUtc: new Date(reconnectAtMs).toISOString(),
        }),
      );
      this.setRouteStatus(route, status);
      // A route-level not-before still prevents another handshake if routine
      // maintenance fires first. The serialized alarm decision preserves the
      // earliest actual wakeup across concurrent route failures.
      const requestedAlarmAt = await this.state.storage.getAlarm();
      if (
        typeof requestedAlarmAt === "number" &&
        Number.isFinite(requestedAlarmAt) &&
        requestedAlarmAt > now &&
        requestedAlarmAt <= reconnectAtMs
      ) return;
      await this.state.storage.setAlarm(reconnectAtMs);
    });
  }

  private resetUpstreamReconnectBackoff(
    route: UpstreamRoute,
  ): Promise<void> {
    return this.serializeRelayAlarm(async () => {
      // Keep an existing fixed key set instead of deleting it so a post-success
      // socket event cannot race a stale absence check. If a route has never
      // failed, absence already means zero and does not need three new writes.
      const keys = [
        `${UPSTREAM_RECONNECT_FAILURE_PREFIX}${route}`,
        `${UPSTREAM_RECONNECT_NOT_BEFORE_PREFIX}${route}`,
        `${UPSTREAM_DEGRADED_SINCE_PREFIX}${route}`,
      ];
      const current = await Promise.all(keys.map((key) => this.state.storage.get<number>(key)));
      await Promise.all(
        keys.flatMap((key, index) => current[index] === undefined || current[index] === 0
          ? []
          : [this.state.storage.put(key, 0)]),
      );
    });
  }

  private activateUpstreamSocket(route: UpstreamRoute, socket: WebSocket): void {
    this.setRouteStatus(route, "open");
    this.state.waitUntil(this.markRouteSuccessful(route));
    this.state.waitUntil(this.resetUpstreamReconnectBackoff(route));
    const queries =
      route === "all_eew"
        ? [
            "query_jmaeew",
            "query_sceew",
            "query_cenceew",
            "query_fjeew",
            "query_cqeew",
          ]
        : route === "cenc_eqlist"
          ? ["query_cenceqlist"]
          : ["query_jmaeqlist"];
    for (const query of queries) socket.send(query);
  }

  private attachUpstreamSocketListeners(
    route: UpstreamRoute,
    socket: WebSocket,
  ): void {
    socket.addEventListener("message", (event) => {
      if (typeof event.data !== "string") return;
      try {
        const message: unknown = JSON.parse(event.data);
        if (isHeartbeat(message) || isPong(message)) {
          this.state.waitUntil(this.markRouteSuccessful(route));
          return;
        }
        const source =
          route === "all_eew"
            ? sourceFromMessage(message)
            : route;
        if (!source) return;
        const normalizedEvents = normalizeMessages(source, message);
        if (normalizedEvents.length === 0) {
          // A valid non-event frame still proves the WebSocket route is alive.
          this.state.waitUntil(this.markSourceSuccessful(source));
          return;
        }
        for (const normalized of normalizedEvents) {
          // The journal persists first and marks freshness only after the D1
          // event/outbox transaction commits. Multiple revisions are safely
          // coalesced and serialized by the Durable Object drain.
          this.state.waitUntil(this.enqueueLiveIngest(normalized));
        }
      } catch (error) {
        console.warn(`Unable to handle ${route} message`, error);
      }
    });
    socket.addEventListener("close", (event) => {
      // A replaced socket must not erase the status or reconnect request for a
      // newer healthy connection to the same route.
      if (this.upstreams.get(route) !== socket) return;
      // Close reasons are upstream-controlled text, so expose only bounded,
      // operationally useful metadata in the structured log.
      this.upstreams.delete(route);
      this.state.waitUntil(
        this.scheduleUpstreamReconnect(
          route,
          "wolfx_upstream_websocket_closed",
          {
            closeCode: Number.isSafeInteger(event.code) ? event.code : null,
            wasClean: event.wasClean === true,
            closeReasonPresent:
              typeof event.reason === "string" && event.reason.length > 0,
          },
          "closed",
        ),
      );
    });
    socket.addEventListener("error", () => {
      if (this.upstreams.get(route) !== socket) return;
      // ErrorEvent details can include transport text; route + planned recovery
      // are sufficient for the operator without copying upstream content.
      // Some runtimes emit `error` before (or, exceptionally, without) a
      // matching `close`. Drop and close this socket proactively so the next
      // short alarm always establishes a replacement rather than retaining a
      // broken entry in the route map.
      this.upstreams.delete(route);
      try {
        socket.close(1011);
      } catch {
        // The socket may already be closed; its state is no longer retained.
      }
      this.state.waitUntil(
        this.scheduleUpstreamReconnect(
          route,
          "wolfx_upstream_websocket_error",
          {},
        ),
      );
    });
  }

  private setRouteStatus(route: UpstreamRoute, status: string): void {
    const sources: WolfxSourceId[] =
      route === "all_eew" ? EEW_SOURCES : [route];
    for (const source of sources) this.statuses.set(source, status);
  }

  private async markRouteSuccessful(route: UpstreamRoute): Promise<void> {
    const sources: WolfxSourceId[] =
      route === "all_eew" ? EEW_SOURCES : [route];
    await Promise.all(sources.map((source) => this.markSourceSuccessful(source)));
  }

  private serializeFreshnessUpdate(
    key: string,
    operation: () => Promise<void>,
  ): Promise<void> {
    const previous = this.freshnessUpdates.get(key) ?? Promise.resolve();
    const update = previous.then(operation, operation);
    this.freshnessUpdates.set(key, update);
    // Keep an error from one heartbeat from blocking later evidence. The
    // caller still receives the same rejection through `update` so failed
    // persistence remains fail-closed rather than being silently swallowed.
    void update.then(
      () => {
        if (this.freshnessUpdates.get(key) === update) {
          this.freshnessUpdates.delete(key);
        }
      },
      () => {
        if (this.freshnessUpdates.get(key) === update) {
          this.freshnessUpdates.delete(key);
        }
      },
    );
    return update;
  }

  private async checkpointFreshness(
    source: WolfxSourceId,
    storageKey: string,
    checkpoints: Map<WolfxSourceId, number>,
    attempts: Map<WolfxSourceId, number>,
    intervalMs: number,
    now: number,
  ): Promise<boolean> {
    let checkpoint = checkpoints.get(source);
    if (checkpoint === undefined) {
      const persisted = await this.state.storage.get<number>(storageKey);
      if (typeof persisted === "number" && Number.isFinite(persisted)) {
        checkpoint = persisted;
        checkpoints.set(source, persisted);
      }
    }
    if (
      typeof checkpoint === "number" &&
      Number.isFinite(checkpoint) &&
      checkpoint <= now &&
      now - checkpoint < intervalMs
    ) {
      return true;
    }
    const lastAttempt = attempts.get(source);
    if (
      typeof lastAttempt === "number" &&
      Number.isFinite(lastAttempt) &&
      lastAttempt <= now &&
      now - lastAttempt < intervalMs
    ) {
      return false;
    }
    attempts.set(source, now);
    await this.state.storage.put(storageKey, now);
    // Do not update this cache until storage confirms the write. A failed
    // checkpoint must not make the active relay look fresh after eviction.
    checkpoints.set(source, now);
    return true;
  }

  private markSourceSuccessful(source: WolfxSourceId): Promise<void> {
    return this.serializeFreshnessUpdate(`websocket:${source}`, async () => {
      const pendingForSource = await this.state.storage.list({
        prefix: `${PENDING_INGEST_PREFIX}${source}:`,
        limit: 1,
      });
      // A heartbeat can prove that a socket is open, but not that its preceding
      // event was durably committed. Leave readiness stale until the journal for
      // this source drains successfully.
      if (pendingForSource.size > 0) return;
      const now = Date.now();
      const checkpointAvailable = await this.checkpointFreshness(
        source,
        `${UPSTREAM_LAST_SUCCESS_PREFIX}${source}`,
        this.lastPersistedUpstreamSuccessMs,
        this.lastUpstreamCheckpointAttemptMs,
        UPSTREAM_FRESHNESS_CHECKPOINT_INTERVAL_MS,
        now,
      );
      if (checkpointAvailable) this.lastSuccessfulUpstreamMs.set(source, now);
    });
  }

  private markHttpSourceSuccessful(source: WolfxSourceId): Promise<void> {
    return this.serializeFreshnessUpdate(`http:${source}`, async () => {
      const pendingForSource = await this.state.storage.list({
        prefix: `${PENDING_INGEST_PREFIX}${source}:`,
        limit: 1,
      });
      // Do not let an HTTP response cover up a WebSocket event that reached the
      // relay but has not crossed the D1 durability boundary yet.
      if (pendingForSource.size > 0) return;
      const now = Date.now();
      const checkpointAvailable = await this.checkpointFreshness(
        source,
        `${UPSTREAM_LAST_HTTP_SUCCESS_PREFIX}${source}`,
        this.lastPersistedHttpSuccessMs,
        this.lastHttpCheckpointAttemptMs,
        HTTP_FRESHNESS_CHECKPOINT_INTERVAL_MS,
        now,
      );
      // Status intentionally trusts the in-memory value first. Publish it only
      // after durable storage succeeds, otherwise an evicted/failed write could
      // make this instance claim a fresh alternate transport it cannot recover.
      if (checkpointAvailable) this.lastSuccessfulHttpPollMs.set(source, now);
    });
  }

  private async seedHttpSource(
    source: WolfxSourceId,
    mode: "initial" | "recovery",
  ): Promise<HttpSeedOutcome> {
    const workKey = httpSnapshotWorkStorageKey(source);
    const storedWorkValue = await this.state.storage.get<unknown>(workKey);
    const storedWork = isPendingHttpSnapshotWork(storedWorkValue)
      ? storedWorkValue
      : null;
    // Finish a durable, validated cursor before fetching another snapshot.
    // This gives one 50-entry report list a bounded ~5s continuation window
    // rather than replacing it mid-transaction, and keeps its recovery
    // notification semantics intact across alarm invocations/eviction. D1 and
    // Durable Object storage failures intentionally propagate to `alarm()`:
    // swallowing them would turn a pending cursor into a rapid retry loop.
    if (storedWork) {
      return {
        completed: await this.persistHttpSnapshotWork(workKey, storedWork),
        snapshotWorkStarted: true,
      };
    }

    let message: unknown;
    try {
      message = await withHttpSnapshotTimeout(async (signal) => {
        const response = await fetch(`${HTTP_BASE}/${source}.json`, {
          signal,
          // Snapshot freshness is the alternate transport's readiness proof.
          // Never let an edge-cached historical Wolfx response refresh it.
          cache: "no-store",
        });
        if (!response.ok) {
          await response.body?.cancel();
          throw new Error(`Wolfx snapshot HTTP ${response.status}`);
        }
        return await readBoundedHttpSnapshotJson(response);
      });
    } catch (error) {
      // Never include raw upstream bodies or error messages in logs. The
      // source and error type are enough to diagnose a degraded transport.
      console.warn(
        JSON.stringify({
          outcome: "wolfx_http_snapshot_unavailable",
          source,
          errorName: error instanceof Error ? error.name : "UnknownError",
        }),
      );
      return { completed: false, snapshotWorkStarted: false };
    }

    let normalizedEvents: NormalizedEvent[];
    try {
      normalizedEvents = normalizeMessages(source, message);
      if (!isStructurallyValidHttpSnapshot(source, message, normalizedEvents)) {
        console.warn(
          JSON.stringify({
            outcome: "wolfx_http_snapshot_invalid",
            source,
          }),
        );
        return { completed: false, snapshotWorkStarted: false };
      }
    } catch (error) {
      // Treat malformed source data as unavailable, but deliberately keep
      // durable persistence outside this catch so D1 errors reach the bounded
      // fallback deferral path.
      console.warn(
        JSON.stringify({
          outcome: "wolfx_http_snapshot_invalid",
          source,
          errorName: error instanceof Error ? error.name : "UnknownError",
        }),
      );
      return { completed: false, snapshotWorkStarted: false };
    }

    const fingerprint = await httpSnapshotFingerprint(message);
    const storedFingerprint = await this.state.storage.get<string>(
      `${UPSTREAM_HTTP_FINGERPRINT_PREFIX}${source}`,
    );
    if (storedFingerprint === fingerprint) {
      await this.markHttpSourceSuccessful(source);
      return { completed: true, snapshotWorkStarted: false };
    }

    const work: PendingHttpSnapshotWork = {
      version: 1,
      source,
      mode,
      fingerprint,
      events: normalizedEvents.map(snapshotEvent),
      nextIndex: 0,
    };
    await this.state.storage.put(workKey, work);
    return {
      completed: await this.persistHttpSnapshotWork(workKey, work),
      snapshotWorkStarted: true,
    };
  }

  private async persistHttpSnapshotWork(
    workKey: string,
    work: PendingHttpSnapshotWork,
  ): Promise<boolean> {
    const start = work.nextIndex;
    const end = Math.min(
      work.events.length,
      start + HTTP_SNAPSHOT_INGEST_BATCH_SIZE,
    );
    await persistHttpSnapshotEvents(
      this.env.DB,
      work.events.slice(start, end),
      work.mode,
    );
    const advanced = await this.advanceHttpSnapshotWork(workKey, work, end);
    if (!advanced) return false;
    if (end < work.events.length) return false;
    await this.markHttpSourceSuccessful(work.source);
    return true;
  }

  /**
   * Advance a verified snapshot cursor only if this is still the current
   * fingerprint/cursor. A later relay turn can resume or repair a partial job
   * while D1 I/O is in flight; it must win rather than being overwritten by
   * the older work after that call resolves.
   */
  private async advanceHttpSnapshotWork(
    workKey: string,
    work: PendingHttpSnapshotWork,
    nextIndex: number,
  ): Promise<boolean> {
    const storage = this.state.storage;
    const advance = async (target: DurableKeyValueStore): Promise<boolean> => {
      const current = await target.get<unknown>(workKey);
      if (
        !isPendingHttpSnapshotWork(current) ||
        current.fingerprint !== work.fingerprint ||
        current.nextIndex !== work.nextIndex
      ) {
        return false;
      }
      if (nextIndex < work.events.length) {
        await target.put(workKey, { ...work, nextIndex });
      } else {
        await target.put(
          `${UPSTREAM_HTTP_FINGERPRINT_PREFIX}${work.source}`,
          work.fingerprint,
        );
        await target.delete(workKey);
      }
      return true;
    };
    if (typeof storage.transaction !== "function") return advance(storage);
    return storage.transaction((transaction) => advance(transaction));
  }

  private async seedFromHttp(mode: "initial" | "recovery"): Promise<void> {
    if (this.httpSeedInFlight) return this.httpSeedInFlight;
    const seed = this.runHttpSeed(mode).finally(() => {
      if (this.httpSeedInFlight === seed) this.httpSeedInFlight = null;
    });
    this.httpSeedInFlight = seed;
    return seed;
  }

  /**
   * Initial baseline work is a low-frequency, durable cursor: it may span
   * alarms and has no urgent notification semantics. The ordinary relay alarm
   * serializes it, so no per-attempt lease is needed.
   */
  private async pendingHttpSnapshotWorks(
    repairInvalid = false,
  ): Promise<PendingHttpSnapshotWork[]> {
    const pending = await this.state.storage.list<unknown>({
      prefix: PENDING_HTTP_SNAPSHOT_PREFIX,
      limit: ALL_WOLFX_SOURCES.length,
    });
    const works: PendingHttpSnapshotWork[] = [];
    for (const [key, value] of pending) {
      if (
        !isPendingHttpSnapshotWork(value) ||
        key !== httpSnapshotWorkStorageKey(value.source)
      ) {
        // Status readers must stay write-free when storage capacity is under
        // pressure. Alarm-owned recovery may repair malformed public snapshot
        // cursors before beginning a new seed instead.
        console.error(JSON.stringify({ outcome: "invalid_wolfx_http_snapshot_work" }));
        if (repairInvalid) await this.state.storage.delete(key);
        continue;
      }
      works.push(value);
    }
    return works;
  }

  private async pendingHttpSnapshotSources(): Promise<WolfxSourceId[]> {
    return [
      ...new Set((await this.pendingHttpSnapshotWorks()).map((work) => work.source)),
    ];
  }

  private async runHttpSeed(mode: "initial" | "recovery"): Promise<void> {
    // A preceding deployed revision can still own either an initial fetch or
    // a persisted cursor. Read the legacy lease before all execution paths so
    // a rollout never overlaps its external fetch/D1 work.
    if (await this.legacyHttpSeedFenceUntil() > Date.now()) return;
    // A stored cursor defines its own mode. A recovery cursor must never flow
    // through initial baseline bookkeeping (source cursor/timestamp), which
    // would both change its notification semantics and add avoidable writes.
    const pendingWork = (await this.pendingHttpSnapshotWorks(true))[0];
    if (pendingWork) {
      await this.resumeHttpSnapshotWork(pendingWork);
      return;
    }
    if (mode === "recovery") {
      await this.runHttpRecoverySweep();
    } else {
      await this.runInitialHttpSeed();
    }
  }

  private async resumeHttpSnapshotWork(
    work: PendingHttpSnapshotWork,
  ): Promise<void> {
    const outcome = await this.seedHttpSource(work.source, work.mode);
    if (!outcome.completed) {
      // Start the continuation interval after the bounded D1 slice finishes,
      // not before it begins. A slow slice must not immediately trigger the
      // next one and turn changed data into an alarm burst.
      this.lastHttpSnapshotResumeStartedMs = Date.now();
      return;
    }
    const stillPending = (await this.pendingHttpSnapshotSources()).includes(work.source);
    if (stillPending) {
      this.lastHttpSnapshotResumeStartedMs = Date.now();
      return;
    }
    if (work.mode === "initial") {
      await this.advanceHttpSeedSource(work.source);
      await this.markInitialHttpSeedComplete();
      await this.state.storage.put(LAST_HTTP_SEED_MS_KEY, Date.now());
    }
  }

  private async initialHttpSeedIsComplete(): Promise<boolean> {
    if ((await this.pendingHttpSnapshotSources()).length > 0) return false;
    const fingerprints = await Promise.all(
      ALL_WOLFX_SOURCES.map((source) =>
        this.state.storage.get<string>(
          `${UPSTREAM_HTTP_FINGERPRINT_PREFIX}${source}`,
        )
      ),
    );
    return fingerprints.every(
      (fingerprint) => typeof fingerprint === "string" && fingerprint.length > 0,
    );
  }

  private async runInitialHttpSeed(): Promise<void> {
    const missingSources = (await Promise.all(
      ALL_WOLFX_SOURCES.map(async (candidate) => ({
        candidate,
        fingerprint: await this.state.storage.get<string>(
          `${UPSTREAM_HTTP_FINGERPRINT_PREFIX}${candidate}`,
        ),
      })),
    )).filter(({ fingerprint }) =>
      typeof fingerprint !== "string" || fingerprint.length === 0
    ).map(({ candidate }) => candidate);
    const source = await this.nextHttpSeedSource(missingSources);
    if (source === null) {
      await this.markInitialHttpSeedComplete();
      return;
    }
    const outcome = await this.seedHttpSource(source, "initial");
    if (!outcome.completed && !outcome.snapshotWorkStarted) {
      // A cursor-free fetch or validation failure has no durable work to
      // resume. Record the attempt so ordinary startup retries this source on
      // its five-minute cadence rather than rearming the relay alarm every
      // second until the feed recovers. Yield to the next missing source too:
      // one unavailable feed must not starve every other durable baseline.
      await this.advanceHttpSeedSource(source);
      await this.state.storage.put(LAST_HTTP_SEED_MS_KEY, Date.now());
      return;
    }
    if (outcome.snapshotWorkStarted && !outcome.completed) {
      this.lastHttpSnapshotResumeStartedMs = Date.now();
    }
    if (outcome.completed) {
      const stillPending = (await this.pendingHttpSnapshotSources()).includes(source);
      if (!stillPending) {
        await this.advanceHttpSeedSource(source);
        await this.markInitialHttpSeedComplete();
        // Baseline work is intentionally infrequent. This timestamp is not
        // used by active recovery, which has its own durable next-sweep time.
        await this.state.storage.put(LAST_HTTP_SEED_MS_KEY, Date.now());
      }
    }
  }

  private async markInitialHttpSeedComplete(): Promise<void> {
    if (!await this.initialHttpSeedIsComplete()) return;
    if (await this.state.storage.get<boolean>(INITIAL_HTTP_SEED_COMPLETE_KEY) !== true) {
      await this.state.storage.put(INITIAL_HTTP_SEED_COMPLETE_KEY, true);
    }
  }

  /**
   * Make a single bounded, low-rate alternate transport sweep. The sweep is
   * serialized in memory by `httpSeedInFlight`; the alarm owns its cadence.
   * It deliberately writes no lease/cursor/source-timing key for unchanged
   * sources—only one durable next-sweep deadline for the entire minute.
   * If a changed report begins durable D1 work, stop immediately so that one
   * alarm still has a bounded D1 budget; its cursor resumes on the next turn.
   */
  private async claimHttpRecoverySweep(now: number): Promise<boolean> {
    const storage = this.state.storage;
    const claim = async (target: DurableKeyValueStore): Promise<boolean> => {
      const [nextSweepAt, legacyLease, cursorLease] = await Promise.all([
        target.get<number>(HTTP_FALLBACK_NEXT_SWEEP_AT_KEY),
        target.get<unknown>(LEGACY_HTTP_SEED_LEASE_UNTIL_KEY),
        target.get<unknown>(HTTP_SEED_LEASE_V2_KEY),
      ]);
      if (
        typeof nextSweepAt === "number" &&
        Number.isFinite(nextSweepAt) &&
        nextSweepAt > now
      ) return false;
      const legacyFenceAt = Math.max(
        legacyHttpSeedLeaseUntil(legacyLease) ?? 0,
        legacyHttpSeedLeaseUntil(cursorLease) ?? 0,
      );
      if (legacyFenceAt > now) return false;
      await target.put(
        HTTP_FALLBACK_NEXT_SWEEP_AT_KEY,
        now + HTTP_FALLBACK_SWEEP_INTERVAL_MS,
      );
      return true;
    };
    if (typeof storage.transaction !== "function") return claim(storage);
    return storage.transaction((transaction) => claim(transaction));
  }

  private async runHttpRecoverySweep(): Promise<void> {
    const startedAtMs = Date.now();
    // Persist one small next-sweep scalar before external I/O. Unlike the old
    // lease/cursor/last-seed churn, this is one bounded row per minute and
    // survives eviction or an unrelated reconnect alarm, so a restarted relay
    // cannot re-run a full seven-source sweep immediately. Claim it
    // transactionally so a replaced/overlapping relay turn cannot duplicate a
    // sweep after both observe the same expired deadline.
    if (!await this.claimHttpRecoverySweep(startedAtMs)) return;
    const sources = this.recoverySweepSources(startedAtMs);
    await mapWithMinimumSpacing(
      sources,
      HTTP_FALLBACK_SOURCE_SPACING_MS,
      async (source) => {
        const outcome = await this.seedHttpSource(source, "recovery");
        // A changed response writes a durable cursor before doing D1 work.
        // Do not begin another changed source in this alarm invocation.
        if (outcome.snapshotWorkStarted) {
          if (!outcome.completed) {
            this.lastHttpSnapshotResumeStartedMs = Date.now();
          }
          throw new HttpRecoverySweepWorkStarted();
        }
        return outcome;
      },
    ).catch((error: unknown) => {
      if (error instanceof HttpRecoverySweepWorkStarted) return;
      throw error;
    });
  }

  private async ingest(
    event: NormalizedEvent,
    mode: "live" | "initial" | "recovery",
    outboxFlushLimit: number | null = ROUTINE_OUTBOX_FLUSH_BATCH_SIZE,
  ): Promise<void> {
    const { message } = await persistEventAndOutbox(
      this.env.DB,
      event,
      (previous) => {
        const reason = determineReason(event, previous);
        if (!reason || mode === "initial") return null;
        if (mode === "recovery" && !isRecentHttpRecoveryEvent(event)) {
          return null;
        }
        return createAlertDeliveryMessage(event, reason);
      },
    );
    // The D1 transaction above is the durability boundary. A failed Queue
    // send leaves this row pending for the next alarm instead of losing a
    // future duplicate to event deduplication.
    if (message && outboxFlushLimit !== null) {
      await this.flushAlertDeliveryOutbox(outboxFlushLimit);
    }
  }

  private async apnsAuthorization(): Promise<string> {
    requireApnsConfiguration(this.env);

    const now = Date.now();
    if (
      this.apnsJwtCache &&
      now - this.apnsJwtCache.issuedAtMs < APNS_JWT_CACHE_MAX_AGE_MS
    ) {
      return this.apnsJwtCache.authorization;
    }
    if (this.apnsJwtRefresh) return this.apnsJwtRefresh;

    const refresh = createApnsJWT(this.env)
      .then((authorization) => {
        this.apnsJwtCache = { authorization, issuedAtMs: Date.now() };
        return authorization;
      })
      .finally(() => {
        this.apnsJwtRefresh = null;
      });
    this.apnsJwtRefresh = refresh;
    return refresh;
  }
}

interface DelayedTrainingTestPushJob {
  appAttestKeyId: string;
  dueAtMs: number;
  state: "scheduled" | "attempted";
}

function isDelayedTrainingTestPushJob(
  value: unknown,
): value is DelayedTrainingTestPushJob {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const candidate = value as Record<string, unknown>;
  const key = canonicalizeAppAttestKeyId(candidate.appAttestKeyId);
  return key?.keyId === candidate.appAttestKeyId &&
    typeof candidate.dueAtMs === "number" &&
    Number.isSafeInteger(candidate.dueAtMs) && candidate.dueAtMs > 0 &&
    (candidate.state === "scheduled" || candidate.state === "attempted") &&
    Object.keys(candidate).length === 3;
}

export function delayedTrainingTestPushDueAt(nowMs = Date.now()): number {
  if (!Number.isSafeInteger(nowMs) || nowMs > Number.MAX_SAFE_INTEGER - DELAYED_TRAINING_TEST_PUSH_DELAY_MS) {
    throw new RangeError("delayed training test requires a valid current time");
  }
  return nowMs + DELAYED_TRAINING_TEST_PUSH_DELAY_MS;
}

function trainingTestEvent(device: DeviceRecord, now = new Date().toISOString()): NormalizedEvent {
  return {
    id: TRAINING_TEST_EVENT_ID, sourceId: device.sources[0] ?? "jma_eew", eventId: "TEST-EVENT",
    serial: 1, kind: "eew", originTimeUtc: now, reportTimeUtc: now,
    hypocenter: "Test Region", latitude: 35, longitude: 135, magnitude: 5.5,
    depth: 10, maxIntensity: "5-", isWarn: true, isFinal: false,
    isCancel: false, isTraining: true, tsunami: null, raw: null,
  };
}

/**
 * One private DO per canonical App Attest key. Its only persisted state is a
 * 90-second appointment and an at-most-once marker; it never stores an APNs
 * token, proof, request body, preferences, or earthquake payload.
 */
export class TrainingPushScheduler {
  constructor(
    private readonly state: DurableObjectState,
    private readonly env: Env,
  ) {}

  async fetch(request: Request): Promise<Response> {
    if (new URL(request.url).pathname !== "/schedule" || request.method !== "POST") {
      return json({ error: "not found" }, 404, noStoreHeaders());
    }
    let body: unknown;
    try { body = await request.json(); } catch { return json({ error: "invalid delayed training test request" }, 400, noStoreHeaders()); }
    const candidate = body && typeof body === "object" && !Array.isArray(body)
      ? body as Record<string, unknown> : null;
    const key = canonicalizeAppAttestKeyId(candidate?.appAttestKeyId);
    if (!candidate || !key || Object.keys(candidate).length !== 1 || !Object.hasOwn(candidate, "appAttestKeyId") || key.keyId !== candidate.appAttestKeyId) {
      return json({ error: "invalid delayed training test request" }, 400, noStoreHeaders());
    }
    try {
      return json({ scheduledAtUtc: await this.schedule(key.keyId) }, 202, noStoreHeaders());
    } catch {
      return json({ error: "delayed training test is temporarily unavailable" }, 503, noStoreHeaders());
    }
  }

  async alarm(): Promise<void> {
    const job = await this.state.storage.get<unknown>(DELAYED_TRAINING_TEST_PUSH_STORAGE_KEY);
    if (!isDelayedTrainingTestPushJob(job)) {
      if (job !== undefined) await this.state.storage.delete(DELAYED_TRAINING_TEST_PUSH_STORAGE_KEY);
      return;
    }
    if (job.state === "attempted") {
      await this.state.storage.delete(DELAYED_TRAINING_TEST_PUSH_STORAGE_KEY);
      return;
    }
    if (Date.now() < job.dueAtMs) {
      await this.state.storage.setAlarm(job.dueAtMs);
      return;
    }
    if (Date.now() > job.dueAtMs + DELAYED_TRAINING_TEST_PUSH_MAX_LATE_MS) {
      // A delayed alarm is not a reason to surprise a tester with an old
      // notification. The accepted D1 daily claim remains consumed.
      await this.state.storage.delete(DELAYED_TRAINING_TEST_PUSH_STORAGE_KEY);
      return;
    }
    // Durable Object alarms are at-least-once. Cross this persistent boundary
    // before any D1, relay, or APNs I/O so retries cannot deliver twice.
    await this.state.storage.put(DELAYED_TRAINING_TEST_PUSH_STORAGE_KEY, { ...job, state: "attempted" } satisfies DelayedTrainingTestPushJob);
    try {
      // Obtain the cached provider authorization before the final ownership
      // lookup. That lookup therefore occurs immediately before the APNs
      // request and sees a deletion or key rebind that happened while the
      // scheduler was waiting on the relay.
      const [apnsAuthorization, collapseId] = await Promise.all([
        cachedApnsAuthorizationFromRelay(this.env),
        // Do every asynchronous preparation before the final ownership
        // lookup. Once that D1 query returns a current registration, this DO
        // immediately begins the APNs request without another await point at
        // which a deletion/rebind event could interleave.
        apnsCollapseID({ id: TRAINING_TEST_EVENT_ID }),
      ]);
      const row = await this.env.DB.prepare(
        `SELECT * FROM devices WHERE app_attest_key_id = ? AND environment = 'production' LIMIT 1`,
      ).bind(job.appAttestKeyId).first<DeviceRow>();
      if (!row) return; // deleted or rebound after scheduling
      // Authorization and the ownership lookup can each wait on an external
      // service. Recheck the short training window after both have completed,
      // immediately before beginning APNs, so a job that became stale while
      // waiting is discarded rather than delivered late.
      if (Date.now() > job.dueAtMs + DELAYED_TRAINING_TEST_PUSH_MAX_LATE_MS) return;
      const device = rowToDevice(row);
      // Disabling the reviewed deploy-time flag cancels any appointment that
      // has not run yet. No background retry follows an APNs failure.
      if (!productionTestPushAllowed(this.env, device) || !hasApnsConfiguration(this.env)) return;
      const event = trainingTestEvent(device);
      const result = await sendPush(
        this.env,
        device,
        event,
        "training",
        apnsAuthorization,
        collapseId,
      );
      if (!result.ok) return;
    } catch {
      // Deliberately log nothing: identifiers and APNs request data are not
      // operational evidence for this one-off controlled test.
    } finally {
      await this.state.storage.delete(DELAYED_TRAINING_TEST_PUSH_STORAGE_KEY);
    }
  }

  private async schedule(appAttestKeyId: string): Promise<string> {
    const existing = await this.state.storage.get<unknown>(DELAYED_TRAINING_TEST_PUSH_STORAGE_KEY);
    if (isDelayedTrainingTestPushJob(existing) && existing.state === "scheduled") {
      return new Date(existing.dueAtMs).toISOString();
    }
    if (existing !== undefined) await this.state.storage.delete(DELAYED_TRAINING_TEST_PUSH_STORAGE_KEY);
    const dueAtMs = delayedTrainingTestPushDueAt();
    await this.state.storage.put(DELAYED_TRAINING_TEST_PUSH_STORAGE_KEY, {
      appAttestKeyId, dueAtMs, state: "scheduled",
    } satisfies DelayedTrainingTestPushJob);
    try {
      await this.state.storage.setAlarm(dueAtMs);
    } catch (error) {
      await this.state.storage.delete(DELAYED_TRAINING_TEST_PUSH_STORAGE_KEY);
      throw error;
    }
    return new Date(dueAtMs).toISOString();
  }
}

export async function scheduleDelayedTrainingTestPush(env: Env, appAttestKeyId: string): Promise<string> {
  const name = `v1:${await appAttestBodySha256(new TextEncoder().encode(appAttestKeyId))}`;
  const scheduler = env.TRAINING_PUSH_SCHEDULER.get(
    env.TRAINING_PUSH_SCHEDULER.idFromName(name),
  );
  const response = await scheduler.fetch(new Request("https://training-push.internal/schedule", {
    method: "POST", headers: { "content-type": "application/json" },
    // The private scheduler receives the canonical key only, never an APNs
    // token, proof, request body, preferences, or real earthquake data.
    body: JSON.stringify({ appAttestKeyId }),
  }));
  if (!response.ok) throw new Error("delayed training test scheduler rejected request");
  const body: unknown = await response.json().catch(() => null);
  const scheduledAtUtc = body && typeof body === "object" && !Array.isArray(body)
    ? (body as { scheduledAtUtc?: unknown }).scheduledAtUtc : null;
  if (typeof scheduledAtUtc !== "string" || !Number.isFinite(Date.parse(scheduledAtUtc))) {
    throw new Error("delayed training test scheduler response was invalid");
  }
  return scheduledAtUtc;
}

type DeviceRateLimitActorKind =
  | "app_attest_key"
  | "device_token"
  | "unattributed";

interface DeviceRateLimitActor {
  kind: DeviceRateLimitActorKind;
  value: string;
}

function deviceRateLimitResponse(): Response {
  return json(
    { error: "too many device API requests; retry later" },
    429,
    noStoreHeaders({
      "retry-after": String(DEVICE_RATE_LIMIT_WINDOW_SECONDS),
    }),
  );
}

function appAttestKeyIdFromRequest(request: Request): string | null {
  // The rate limiter uses a canonical decoded key ID, so standard-vs-URL-safe
  // Base64 aliases cannot create independent mutation budgets. The exact wire
  // representation remains challenge-bound by the proof verifier below.
  return canonicalizeAppAttestKeyId(
    request.headers.get(APP_ATTEST_KEY_ID_HEADER),
  )?.keyId ?? null;
}

function deviceRateLimitActors(
  request: Request,
  token?: unknown,
  explicitAppAttestKeyId?: string,
): DeviceRateLimitActor[] {
  // An attested key is the strongest stable app-instance identifier. Keep an
  // APNs-token key too when both are present: an unverified client must not be
  // able to evade a token's limit simply by rotating a header. Never use an IP
  // address: mobile networks and privacy relays can share one, and no raw actor
  // value is ever logged or used as a limiter key.
  const actors: DeviceRateLimitActor[] = [];
  const appAttestKeyId = explicitAppAttestKeyId ?? appAttestKeyIdFromRequest(request);
  if (appAttestKeyId !== null) {
    actors.push({ kind: "app_attest_key", value: appAttestKeyId });
  }
  if (
    typeof token === "string" &&
    token.length > 0 &&
    token.length <= MAX_DEVICE_TOKEN_LENGTH &&
    token.trim() === token
  ) {
    actors.push({ kind: "device_token", value: token });
  }
  if (actors.length > 0) return actors;
  // A route-level limiter still bounds malformed and pre-attestation requests.
  // This is intentionally not an IP-derived identity.
  return [{ kind: "unattributed", value: "unattributed" }];
}

async function deviceRateLimitKey(
  scope: "endpoint" | "actor",
  route: string,
  actor?: DeviceRateLimitActor,
): Promise<string> {
  // Hashing removes APNs/App Attest identifiers before they leave request
  // handling. JSON framing makes the route/actor tuple unambiguous.
  return sha256Hex(
    JSON.stringify(
      actor === undefined
        ? ["quakesignal-device-rate-limit", scope, route]
        : ["quakesignal-device-rate-limit", scope, route, actor.value],
    ),
  );
}

function logDeviceRateLimitOutcome(
  outcome:
    | "device_api_rate_limited"
    | "device_api_rate_limit_unavailable"
    | "app_attest_challenge_rate_limited"
    | "app_attest_challenge_rate_limit_unavailable",
  route: string,
  actorKinds?: DeviceRateLimitActorKind[],
  error?: unknown,
): void {
  console.error(
    JSON.stringify({
      outcome,
      route,
      ...(actorKinds === undefined ? {} : { actorKinds }),
      ...(error === undefined
        ? {}
        : { errorName: error instanceof Error ? error.name : "UnknownError" }),
    }),
  );
}

async function enforceDeviceEndpointRateLimit(
  env: Env,
  route: string,
): Promise<Response | null> {
  try {
    const outcome = await env.DEVICE_API_RATE_LIMIT.limit({
      key: await deviceRateLimitKey("endpoint", route),
    });
    if (outcome.success) return null;
    logDeviceRateLimitOutcome("device_api_rate_limited", route);
  } catch (error) {
    // Public routes fail closed if the binding is unavailable. Treat this the
    // same as a quota response so callers do not learn internal state.
    logDeviceRateLimitOutcome(
      "device_api_rate_limit_unavailable",
      route,
      undefined,
      error,
    );
  }
  return deviceRateLimitResponse();
}

/**
 * New App Attest keys have no durable actor identity yet, so the ordinary
 * per-key mutation budget cannot protect challenge issuance by itself. Use a
 * dedicated native binding with a stable, route-only key before parsing a body
 * or touching D1. Cloudflare applies a Workers rate-limit binding per edge
 * location, which is why this remains an explicitly scoped low-cost quota
 * rather than claiming to be a global WAF.
 */
async function enforceAppAttestChallengeRateLimit(
  env: Env,
): Promise<Response | null> {
  const route = "POST /v1/app-attest/challenge";
  try {
    const outcome = await env.APP_ATTEST_CHALLENGE_RATE_LIMIT.limit({
      key: await deviceRateLimitKey("endpoint", route),
    });
    if (outcome.success) return null;
    logDeviceRateLimitOutcome("app_attest_challenge_rate_limited", route);
  } catch (error) {
    logDeviceRateLimitOutcome(
      "app_attest_challenge_rate_limit_unavailable",
      route,
      undefined,
      error,
    );
  }
  return deviceRateLimitResponse();
}

async function enforceDeviceMutationRateLimit(
  request: Request,
  env: Env,
  route: string,
  token?: unknown,
  explicitAppAttestKeyId?: string,
): Promise<Response | null> {
  const actors = deviceRateLimitActors(
    request,
    token,
    explicitAppAttestKeyId,
  );
  try {
    const outcomes = await Promise.all(
      actors.map(async (actor) => ({
        actor,
        outcome: await env.DEVICE_MUTATION_RATE_LIMIT.limit({
          key: await deviceRateLimitKey("actor", route, actor),
        }),
      })),
    );
    if (outcomes.every(({ outcome }) => outcome.success)) return null;
    logDeviceRateLimitOutcome(
      "device_api_rate_limited",
      route,
      actors.map(({ kind }) => kind),
    );
  } catch (error) {
    // This is intentionally fail-closed for registration, deletion, test
    // delivery, and future App Attest mutations.
    logDeviceRateLimitOutcome(
      "device_api_rate_limit_unavailable",
      route,
      actors.map(({ kind }) => kind),
      error,
    );
  }
  return deviceRateLimitResponse();
}

function appAttestRateLimitRoute(request: Request, pathname: string): string {
  // Never use an arbitrary URL path as a log field. Known App Attest routes
  // keep independent budgets; every other reserved path shares a safe label.
  const method = request.method === "POST" ? "POST" : "OTHER";
  if (pathname === "/v1/app-attest/challenge") {
    return `${method} /v1/app-attest/challenge`;
  }
  return `${method} /v1/app-attest/*`;
}

interface DeviceRequestPayload {
  body: Record<string, unknown>;
  /** Exact UTF-8 bytes covered by an App Attest challenge/proof. */
  bytes: Uint8Array;
}

async function deviceRequestBody(
  request: Request,
): Promise<DeviceRequestPayload | Response> {
  const contentLength = request.headers.get("content-length");
  if (contentLength !== null) {
    if (!/^\d+$/.test(contentLength)) {
      return json({ error: "invalid content length" }, 400, noStoreHeaders());
    }
    const length = Number(contentLength);
    if (length > MAX_DEVICE_REQUEST_BYTES) {
      return json({ error: "request body is too large" }, 413, noStoreHeaders());
    }
  }
  const reader = request.body?.getReader();
  const chunks: Uint8Array[] = [];
  let totalBytes = 0;
  try {
    if (reader) {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        if (!value) continue;
        // For chunked requests, reject before retaining any byte over the
        // application limit. This avoids request.text() buffering an
        // unbounded client-controlled payload in Worker memory.
        if (value.byteLength > MAX_DEVICE_REQUEST_BYTES - totalBytes) {
          try {
            await reader.cancel("device request body limit exceeded");
          } catch {
            // The over-limit condition is authoritative even if a disconnected
            // client makes stream cancellation fail.
          }
          return json({ error: "request body is too large" }, 413, noStoreHeaders());
        }
        chunks.push(value);
        totalBytes += value.byteLength;
      }
    }
  } catch {
    return json({ error: "invalid JSON body" }, 400, noStoreHeaders());
  } finally {
    reader?.releaseLock();
  }
  const bytes = new Uint8Array(totalBytes);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  let raw: string;
  try {
    raw = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    return json({ error: "invalid JSON body" }, 400, noStoreHeaders());
  }
  try {
    const body: unknown = JSON.parse(raw);
    if (!body || typeof body !== "object" || Array.isArray(body)) {
      return json({ error: "JSON body must be an object" }, 400, noStoreHeaders());
    }
    return { body: body as Record<string, unknown>, bytes };
  } catch {
    return json({ error: "invalid JSON body" }, 400, noStoreHeaders());
  }
}

function isDeviceRequestPayload(
  value: DeviceRequestPayload | Response,
): value is DeviceRequestPayload {
  // A Response itself exposes both a `body` stream and a `bytes()` method.
  // Checking property names therefore misclassifies validation failures (for
  // example an oversized body) as a parsed payload and sends them through the
  // App Attest path. This union is produced only by `deviceRequestBody`, so
  // distinguish its concrete error variant directly.
  return !(value instanceof Response);
}

function isValidDeviceToken(value: unknown): value is string {
  return (
    typeof value === "string" &&
    value.length >= 10 &&
    value.length <= MAX_DEVICE_TOKEN_LENGTH &&
    value.trim() === value
  );
}

function isOptionalBoundedString(value: unknown, maxLength: number): boolean {
  return value === undefined || (typeof value === "string" && value.length <= maxLength);
}

function isOptionalFiniteNumber(
  value: unknown,
  minimum: number,
  maximum: number,
): boolean {
  return (
    value === undefined ||
    (typeof value === "number" &&
      Number.isFinite(value) &&
      value >= minimum &&
      value <= maximum)
  );
}

function isOptionalBoolean(value: unknown): boolean {
  return value === undefined || typeof value === "boolean";
}

interface AppAttestChallengeRow {
  id: string;
  key_id: string;
  wire_key_id: string;
  operation: AppAttestOperation;
  method: string;
  path: string;
  body_sha256: string;
  challenge: string;
  required_proof: AppAttestProofType;
  environment: AppAttestEnvironment;
  expires_at_utc: string;
  consumed_at_utc: string | null;
}

interface AppAttestKeyRow {
  key_id: string;
  public_key_pem: string;
  sign_count: number;
}

interface AttestedDeviceMutation {
  mode: "attested";
  keyId: string;
  /** The verified Apple AAGUID environment, never client supplied. */
  environment: AppAttestEnvironment;
  challenge: AppAttestChallengeBinding;
  verification: Awaited<ReturnType<typeof verifyAppAttestProof>>;
}

interface DevelopmentBypassDeviceMutation {
  mode: "development_bypass";
  keyId: null;
}

type AuthorizedDeviceMutation =
  | AttestedDeviceMutation
  | DevelopmentBypassDeviceMutation;

interface DeviceRegistrationValues {
  token: string;
  environment: "sandbox" | "production";
  locale: string | null;
  sources: string;
  minMagnitude: number;
  cityName: string | null;
  latitude: number | null;
  longitude: number | null;
  radiusKm: number | null;
  includeTestAlerts: number;
  utcOffsetMinutes: number | null;
  notifyAtNight: number;
  now: string;
}

function appAttestFailureResponse(): Response {
  // Do not distinguish an expired challenge, wrong key, invalid certificate,
  // replay, or counter race to a network caller. The client simply requests a
  // fresh challenge and retries a user-initiated action.
  return json(
    { error: "app integrity verification failed" },
    401,
    noStoreHeaders(),
  );
}

function appAttestConflictResponse(): Response {
  return json(
    { error: "app integrity request was already used; retry" },
    409,
    noStoreHeaders(),
  );
}

function appAttestRequired(env: Env): boolean {
  // Fail closed by default. A local-only worker can deliberately set
  // `disabled`; checked-in production configuration always uses `required`.
  return env.APP_ATTEST_ENFORCEMENT !== "disabled";
}

function appAttestDevelopmentBypassAllowed(env: Env): boolean {
  return (
    env.APP_ATTEST_ENFORCEMENT === "development" &&
    env.APP_ATTEST_DEVELOPMENT_BYPASS === "true"
  );
}

/**
 * Development App Attest credentials are accepted only by an intentionally
 * marked development verifier. Treat every other combination as production,
 * including a mistakenly set development flag on a release Worker.
 */
export function appAttestVerificationEnvironment(
  env: {
    APP_ATTEST_ENFORCEMENT?: string;
    APP_ATTEST_DEVELOPMENT_ENVIRONMENT?: string;
  },
): AppAttestEnvironment {
  return env.APP_ATTEST_ENFORCEMENT === "development" &&
      env.APP_ATTEST_DEVELOPMENT_ENVIRONMENT === "true"
    ? "development"
    : "production";
}

function appAttestAllowedBundleVersions(env: Env): Set<string> {
  const configured = env.APP_ATTEST_ALLOWED_BUNDLE_VERSIONS ?? "1";
  return new Set(
    configured
      .split(",")
      .map((value) => value.trim())
      .filter((value) => /^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$/.test(value)),
  );
}

function appAttestExpectedBinding(
  operation: AppAttestOperation,
): { method: string; path: string } {
  switch (operation) {
    case "device-registration":
      return { method: "POST", path: "/v1/devices" };
    case "device-deletion":
      return { method: "DELETE", path: "/v1/devices" };
    case "test-push":
      return { method: "POST", path: "/v1/devices/test" };
  }
}

function isExpectedAppAttestBinding(
  operation: unknown,
  method: unknown,
  path: unknown,
): operation is AppAttestOperation {
  if (
    operation !== "device-registration" &&
    operation !== "device-deletion" &&
    operation !== "test-push"
  ) {
    return false;
  }
  const expected = appAttestExpectedBinding(operation);
  return method === expected.method && path === expected.path;
}

function isStrictAppAttestChallengeId(value: unknown): value is string {
  // IDs are Worker-generated UUIDs, so accepting arbitrary client text here
  // gains nothing and makes the D1 lookup/rate surface needlessly broad.
  return (
    typeof value === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
      value,
    )
  );
}

function appAttestChallengeEnvironment(
  challenge: AppAttestChallengeBinding,
): AppAttestEnvironment {
  // The runtime always supplies this from the D1 row. Keep the production
  // default for older focused transaction-test fixtures rather than allowing
  // an omitted value to widen a deployment into development mode.
  return challenge.environment === "development" ? "development" : "production";
}

function appAttestMutationEnvironment(
  authorization: AttestedDeviceMutation,
): AppAttestEnvironment {
  return authorization.environment === "development" ? "development" : "production";
}

function challengeMatchesNow(
  challenge: AppAttestChallengeBinding,
  now: string,
): { sql: string; bindings: unknown[] } {
  return {
    sql: `id = ? AND key_id = ? AND wire_key_id = ? AND environment = ? AND operation = ?
      AND method = ? AND path = ? AND body_sha256 = ? AND challenge = ?
      AND required_proof = ? AND consumed_at_utc IS NULL AND expires_at_utc > ?`,
    bindings: [
      challenge.id,
      challenge.keyId,
      challenge.wireKeyId,
      appAttestChallengeEnvironment(challenge),
      challenge.operation,
      challenge.method,
      challenge.path,
      challenge.bodySha256,
      challenge.challenge,
      challenge.requiredProof,
      now,
    ],
  };
}

function challengeConsumedNowCondition(
  challengeId: string,
  consumedAt: string,
): { sql: string; bindings: unknown[] } {
  return {
    sql: `EXISTS (
      SELECT 1 FROM app_attest_challenges
      WHERE id = ? AND consumed_at_utc = ?
    )`,
    bindings: [challengeId, consumedAt],
  };
}

/**
 * Assertions prove continuity of a known key, so they may update only an
 * unbound or same-key subscription. A freshly verified production
 * attestation is the one safe recovery path after an app reinstall/Keychain
 * reset: Apple proves a new signed app instance and the caller possesses the
 * exact APNs token. That can atomically replace a *single* old key binding for
 * this token, while still refusing any ambiguous/multi-row claim.
 */
export function registrationOwnershipCondition(
  token: string,
  keyId: string,
  proofType: AppAttestProofType,
): { sql: string; bindings: unknown[] } {
  if (proofType === "attestation") {
    return {
      // `devices.token` is the primary key, so an exact APNs token can have
      // at most one existing owner. Apple explicitly permits a new App Attest
      // key after reinstall or device restore. A fresh production attestation
      // plus possession of that exact token is therefore the narrowly scoped
      // recovery proof that can replace its old key binding. Assertions never
      // take this branch and remain strictly key-bound below.
      sql: "1 = 1",
      bindings: [],
    };
  }
  return {
    sql: `NOT EXISTS (
      SELECT 1 FROM devices
      WHERE token = ?
        AND app_attest_key_id IS NOT NULL
        AND app_attest_key_id <> ?
    )`,
    bindings: [token, keyId],
  };
}

/**
 * For deletion, a valid app instance may remove a legacy unbound record, but
 * never a record which a different App Attest key currently owns.
 */
function deletionOwnershipCondition(
  token: string,
  keyId: string,
): { sql: string; bindings: unknown[] } {
  return {
    sql: `NOT EXISTS (
      SELECT 1 FROM devices
      WHERE token = ?
        AND app_attest_key_id IS NOT NULL
        AND app_attest_key_id <> ?
    )`,
    bindings: [token, keyId],
  };
}

export function productionTrainingTestPushRetentionCleanupStatement(
  db: D1Database,
  now: string,
): D1PreparedStatement {
  return db
    .prepare(
      "DELETE FROM production_training_test_push_claims WHERE expires_at_utc <= ?",
    )
    .bind(now);
}

/**
 * App Attest data is useful only while it protects an active subscription.
 * Keep a short-lived challenge until it expires, then remove key material as
 * soon as no device registration refers to it. A token-free daily training
 * claim is retained for a short, fixed operational window and is deleted by
 * the same bounded cleanup path. Callers append these after their device
 * deletion/purge statement in the same D1 batch.
 */
function appAttestRetentionCleanupStatements(
  db: D1Database,
  now: string,
): D1PreparedStatement[] {
  return [
    db
      .prepare("DELETE FROM app_attest_challenges WHERE expires_at_utc <= ?")
      .bind(now),
    productionTrainingTestPushRetentionCleanupStatement(db, now),
    db.prepare(
      `DELETE FROM app_attest_keys
       WHERE NOT EXISTS (
         SELECT 1 FROM devices
         WHERE devices.app_attest_key_id = app_attest_keys.key_id
       )`,
    ),
    db.prepare(
      `DELETE FROM app_attest_challenges
       WHERE consumed_at_utc IS NOT NULL
         AND NOT EXISTS (
         SELECT 1 FROM app_attest_keys
         WHERE app_attest_keys.key_id = app_attest_challenges.key_id
       )`,
    ),
  ];
}

function registrationValues(body: Record<string, unknown>): DeviceRegistrationValues {
  const sources = body.sources === undefined ? ALL_WOLFX_SOURCES : body.sources;
  return {
    token: body.token as string,
    environment: body.environment === "sandbox" ? "sandbox" : "production",
    locale: typeof body.locale === "string" ? body.locale : null,
    sources: JSON.stringify(sources),
    minMagnitude: typeof body.minMagnitude === "number" ? body.minMagnitude : 0,
    cityName: typeof body.cityName === "string" ? body.cityName : null,
    latitude: typeof body.latitude === "number" ? body.latitude : null,
    longitude: typeof body.longitude === "number" ? body.longitude : null,
    radiusKm: typeof body.radiusKm === "number" ? body.radiusKm : null,
    includeTestAlerts: body.includeTestAlerts === true ? 1 : 0,
    utcOffsetMinutes:
      typeof body.utcOffsetMinutes === "number" ? body.utcOffsetMinutes : null,
    notifyAtNight: body.notifyAtNight === false ? 0 : 1,
    now: new Date().toISOString(),
  };
}

export function registrationStatement(
  db: D1Database,
  values: DeviceRegistrationValues,
  appAttestKeyId: string | null,
  guardSql = "1 = 1",
  guardBindings: unknown[] = [],
  allowAttestedTokenRebind = false,
): D1PreparedStatement {
  return db
    .prepare(
      `INSERT INTO devices (
        token, environment, locale, sources, min_magnitude,
        critical_alerts_enabled, city_name, latitude, longitude, radius_km,
        include_test_alerts, utc_offset_minutes, notify_at_night,
        app_attest_key_id, created_at, updated_at
      ) SELECT ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
      WHERE ${guardSql}
      ON CONFLICT(token) DO UPDATE SET
        environment = excluded.environment,
        locale = excluded.locale,
        sources = excluded.sources,
        min_magnitude = excluded.min_magnitude,
        critical_alerts_enabled = 0,
        city_name = excluded.city_name,
        latitude = excluded.latitude,
        longitude = excluded.longitude,
        radius_km = excluded.radius_km,
        include_test_alerts = excluded.include_test_alerts,
        utc_offset_minutes = excluded.utc_offset_minutes,
        notify_at_night = excluded.notify_at_night,
        app_attest_key_id = excluded.app_attest_key_id,
        updated_at = excluded.updated_at
      WHERE devices.app_attest_key_id IS NULL
        OR devices.app_attest_key_id = excluded.app_attest_key_id
        OR ? = 1`,
    )
    .bind(
      values.token,
      values.environment,
      values.locale,
      values.sources,
      values.minMagnitude,
      values.cityName,
      values.latitude,
      values.longitude,
      values.radiusKm,
      values.includeTestAlerts,
      values.utcOffsetMinutes,
      values.notifyAtNight,
      appAttestKeyId,
      values.now,
      values.now,
      ...guardBindings,
      allowAttestedTokenRebind ? 1 : 0,
    );
}

async function authorizeAppAttestMutation(
  request: Request,
  payload: DeviceRequestPayload,
  env: Env,
  operation: AppAttestOperation,
): Promise<AuthorizedDeviceMutation | Response> {
  if (!appAttestRequired(env)) {
    return { mode: "development_bypass", keyId: null };
  }
  if (
    request.headers.get(APP_ATTEST_DEVELOPMENT_BYPASS_HEADER) ===
    APP_ATTEST_DEVELOPMENT_BYPASS_VALUE
  ) {
    return appAttestDevelopmentBypassAllowed(env)
      ? { mode: "development_bypass", keyId: null }
      : appAttestFailureResponse();
  }

  const verificationEnvironment = appAttestVerificationEnvironment(env);
  const wireKeyId = request.headers.get(APP_ATTEST_KEY_ID_HEADER);
  const normalizedKey = canonicalizeAppAttestKeyId(wireKeyId);
  const challengeId = request.headers.get(APP_ATTEST_CHALLENGE_ID_HEADER);
  if (!normalizedKey || !wireKeyId || !isStrictAppAttestChallengeId(challengeId)) {
    return appAttestFailureResponse();
  }

  try {
    const challengeRow = await env.DB
      .prepare(
        `SELECT id, key_id, wire_key_id, operation, method, path, body_sha256,
          challenge, required_proof, environment, expires_at_utc, consumed_at_utc
         FROM app_attest_challenges WHERE id = ? AND environment = ?`,
      )
      .bind(challengeId, verificationEnvironment)
      .first<AppAttestChallengeRow>();
    if (!challengeRow || challengeRow.consumed_at_utc !== null) {
      return appAttestFailureResponse();
    }
    const expected = appAttestExpectedBinding(operation);
    if (
      challengeRow.key_id !== normalizedKey.keyId ||
      challengeRow.wire_key_id !== wireKeyId ||
      challengeRow.environment !== verificationEnvironment ||
      challengeRow.operation !== operation ||
      challengeRow.method !== expected.method ||
      challengeRow.path !== expected.path ||
      Date.parse(challengeRow.expires_at_utc) <= Date.now() ||
      challengeRow.body_sha256 !== (await appAttestBodySha256(payload.bytes))
    ) {
      return appAttestFailureResponse();
    }
    const challenge: AppAttestChallengeBinding = {
      id: challengeRow.id,
      keyId: challengeRow.key_id,
      wireKeyId: challengeRow.wire_key_id,
      challenge: challengeRow.challenge,
      operation: challengeRow.operation,
      method: challengeRow.method,
      path: challengeRow.path,
      bodySha256: challengeRow.body_sha256,
      requiredProof: challengeRow.required_proof,
      environment: challengeRow.environment,
    };
    const existingRow = await env.DB
      .prepare(
        `SELECT key_id, public_key_pem, sign_count FROM app_attest_keys
         WHERE key_id = ? AND environment = ? AND revoked_at_utc IS NULL`,
      )
      .bind(challenge.keyId, verificationEnvironment)
      .first<AppAttestKeyRow>();
    const existingKey: StoredAppAttestKey | null = existingRow
      ? {
          keyId: existingRow.key_id,
          publicKeyPem: existingRow.public_key_pem,
          signCount: existingRow.sign_count,
        }
      : null;
    const verification = await verifyAppAttestProof({
      appId: env.APP_ATTEST_APP_ID ?? APP_ATTEST_APP_ID,
      environment: verificationEnvironment,
      challenge,
      headerKeyId: wireKeyId,
      headerChallengeId: challengeId,
      headerProofType: request.headers.get(APP_ATTEST_PROOF_TYPE_HEADER),
      headerVersion: request.headers.get(APP_ATTEST_VERSION_HEADER),
      proof: request.headers.get(APP_ATTEST_PROOF_HEADER),
      existingKey,
      allowedBundleVersions: appAttestAllowedBundleVersions(env),
      requireReleaseMetadata: env.APP_ATTEST_REQUIRE_RELEASE_METADATA === "true",
    });
    return {
      mode: "attested",
      keyId: challenge.keyId,
      environment: verificationEnvironment,
      challenge,
      verification,
    };
  } catch (error) {
    console.warn(
      JSON.stringify({
        outcome: "app_attest_verification_failed",
        code:
          error instanceof AppAttestValidationError ? error.code : "internal",
      }),
    );
    return appAttestFailureResponse();
  }
}

export async function completeAttestedRegistration(
  db: D1Database,
  authorization: AttestedDeviceMutation,
  values: DeviceRegistrationValues,
): Promise<"completed" | "conflict"> {
  const now = values.now;
  const matching = challengeMatchesNow(authorization.challenge, now);
  const consumed = challengeConsumedNowCondition(authorization.challenge.id, now);
  const verification = authorization.verification;
  const metadata = verification.metadata;
  const appAttestEnvironment = appAttestMutationEnvironment(authorization);
  const ownership = registrationOwnershipCondition(
    values.token,
    authorization.keyId,
    verification.proofType,
  );
  const commonStatements: D1PreparedStatement[] = [];

  if (verification.proofType === "attestation") {
    if (!verification.publicKeyPem || !verification.receiptBase64) {
      return "conflict";
    }
    commonStatements.push(
      db
        .prepare(
          `INSERT INTO app_attest_keys (
            key_id, public_key_pem, sign_count, app_id, environment,
            validation_category, bundle_version, receipt_base64, attested_at_utc
          ) SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?
          WHERE NOT EXISTS (SELECT 1 FROM app_attest_keys WHERE key_id = ?)
            AND EXISTS (SELECT 1 FROM app_attest_challenges WHERE ${matching.sql})
            AND ${ownership.sql}`,
        )
        .bind(
          authorization.keyId,
          verification.publicKeyPem,
          verification.signCount,
          APP_ATTEST_APP_ID,
          appAttestEnvironment,
          metadata?.validationCategory ?? null,
          metadata?.bundleVersion ?? null,
          verification.receiptBase64,
          now,
          authorization.keyId,
          ...matching.bindings,
          ...ownership.bindings,
        ),
      db
        .prepare(
          `UPDATE app_attest_challenges SET consumed_at_utc = ?
           WHERE ${matching.sql}
             AND ${ownership.sql}
             AND EXISTS (
               SELECT 1 FROM app_attest_keys
               WHERE key_id = ? AND environment = ? AND sign_count = ? AND revoked_at_utc IS NULL
             )`,
        )
        .bind(
          now,
          ...matching.bindings,
          ...ownership.bindings,
          authorization.keyId,
          appAttestEnvironment,
          verification.signCount,
        ),
    );
  } else {
    commonStatements.push(
      db
        .prepare(
          `UPDATE app_attest_keys
           SET sign_count = ?, last_asserted_at_utc = ?,
               validation_category = COALESCE(?, validation_category),
               bundle_version = COALESCE(?, bundle_version)
           WHERE key_id = ? AND environment = ? AND sign_count < ? AND revoked_at_utc IS NULL
             AND EXISTS (SELECT 1 FROM app_attest_challenges WHERE ${matching.sql})
             AND ${ownership.sql}`,
        )
        .bind(
          verification.signCount,
          now,
          metadata?.validationCategory ?? null,
          metadata?.bundleVersion ?? null,
          authorization.keyId,
          appAttestEnvironment,
          verification.signCount,
          ...matching.bindings,
          ...ownership.bindings,
        ),
      db
        .prepare(
          `UPDATE app_attest_challenges SET consumed_at_utc = ?
           WHERE ${matching.sql}
             AND ${ownership.sql}
             AND EXISTS (
               SELECT 1 FROM app_attest_keys
               WHERE key_id = ? AND environment = ? AND sign_count = ? AND revoked_at_utc IS NULL
             )`,
        )
        .bind(
          now,
          ...matching.bindings,
          ...ownership.bindings,
          authorization.keyId,
          appAttestEnvironment,
          verification.signCount,
        ),
    );
  }

  // One integrity key protects exactly one active APNs subscription. Clear a
  // prior token only after the challenge has been consumed *and* the target
  // token passed the ownership condition above. This ordering makes a failed
  // cross-key claim a harmless conflict instead of silently unsubscribing the
  // key's existing device.
  // A key can keep its integrity identity while APNs rotates its device token.
  // Remove any prior subscription's token-hashed failure evidence in the same
  // guarded transaction as its device row. Leaving an active failure behind
  // would make readiness stay degraded for a subscription that no longer
  // exists, and would retain its hash longer than operationally necessary.
  const priorDevices = await db
    .prepare(
      `SELECT token FROM devices
       WHERE app_attest_key_id = ? AND token <> ?`,
    )
    .bind(authorization.keyId, values.token)
    .all<{ token: string }>();
  const priorDeviceFailureRecords = await Promise.all(
    priorDevices.results.map(async ({ token }) => ({
      token,
      tokenHash: await tokenHash(token),
    })),
  );

  const priorTokenCleanup = [
    db
      .prepare(
        `DELETE FROM notification_deliveries
         WHERE device_token IN (
           SELECT token FROM devices
           WHERE app_attest_key_id = ? AND token <> ?
             AND ${consumed.sql} AND ${ownership.sql}
         )`,
      )
      .bind(
        authorization.keyId,
        values.token,
        ...consumed.bindings,
        ...ownership.bindings,
      ),
    ...priorDeviceFailureRecords.map(({ token, tokenHash: hashedToken }) =>
      db
        .prepare(
          `DELETE FROM alert_delivery_failures
           WHERE token_hash = ? AND EXISTS (
             SELECT 1 FROM devices
             WHERE token = ? AND app_attest_key_id = ? AND token <> ?
               AND ${consumed.sql} AND ${ownership.sql}
           )`,
        )
        .bind(
          hashedToken,
          token,
          authorization.keyId,
          values.token,
          ...consumed.bindings,
          ...ownership.bindings,
        ),
    ),
    db
      .prepare(
        `DELETE FROM devices
         WHERE app_attest_key_id = ? AND token <> ?
           AND ${consumed.sql} AND ${ownership.sql}`,
      )
      .bind(
        authorization.keyId,
        values.token,
        ...consumed.bindings,
        ...ownership.bindings,
      ),
  ];
  const registrationIndex = commonStatements.length + priorTokenCleanup.length;

  const results = await db.batch([
    ...commonStatements,
    ...priorTokenCleanup,
    registrationStatement(
      db,
      values,
      authorization.keyId,
      consumed.sql,
      consumed.bindings,
      verification.proofType === "attestation",
    ),
    ...appAttestRetentionCleanupStatements(db, now),
  ]);
  const coreCompleted =
    (results[0]?.meta.changes ?? 0) === 1 &&
    (results[1]?.meta.changes ?? 0) === 1;
  const registered = (results[registrationIndex]?.meta.changes ?? 0) === 1;
  return coreCompleted && registered ? "completed" : "conflict";
}

async function completeAttestedAuthorization(
  db: D1Database,
  authorization: AttestedDeviceMutation,
  actionStatements: (
    consumed: { sql: string; bindings: unknown[] },
  ) => D1PreparedStatement[] = () => [],
  eligibility: { sql: string; bindings: unknown[] } = {
    sql: "1 = 1",
    bindings: [],
  },
): Promise<"completed" | "conflict"> {
  const now = new Date().toISOString();
  const matching = challengeMatchesNow(authorization.challenge, now);
  const consumed = challengeConsumedNowCondition(authorization.challenge.id, now);
  const verification = authorization.verification;
  const metadata = verification.metadata;
  const appAttestEnvironment = appAttestMutationEnvironment(authorization);
  if (verification.proofType === "attestation") {
    if (!verification.publicKeyPem || !verification.receiptBase64) {
      return "conflict";
    }
    const results = await db.batch([
      db
        .prepare(
          `INSERT INTO app_attest_keys (
            key_id, public_key_pem, sign_count, app_id, environment,
            validation_category, bundle_version, receipt_base64, attested_at_utc
          ) SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?
          WHERE NOT EXISTS (SELECT 1 FROM app_attest_keys WHERE key_id = ?)
            AND EXISTS (SELECT 1 FROM app_attest_challenges WHERE ${matching.sql})
            AND ${eligibility.sql}`,
        )
        .bind(
          authorization.keyId,
          verification.publicKeyPem,
          verification.signCount,
          APP_ATTEST_APP_ID,
          appAttestEnvironment,
          metadata?.validationCategory ?? null,
          metadata?.bundleVersion ?? null,
          verification.receiptBase64,
          now,
          authorization.keyId,
          ...matching.bindings,
          ...eligibility.bindings,
        ),
      db
        .prepare(
          `UPDATE app_attest_challenges SET consumed_at_utc = ?
           WHERE ${matching.sql}
             AND ${eligibility.sql}
             AND EXISTS (
               SELECT 1 FROM app_attest_keys
               WHERE key_id = ? AND environment = ? AND sign_count = ? AND revoked_at_utc IS NULL
             )`,
        )
      .bind(
        now,
        ...matching.bindings,
        ...eligibility.bindings,
        authorization.keyId,
        appAttestEnvironment,
        verification.signCount,
      ),
      ...actionStatements(consumed),
    ]);
    return (results[0]?.meta.changes ?? 0) === 1 &&
      (results[1]?.meta.changes ?? 0) === 1
      ? "completed"
      : "conflict";
  }

  const results = await db.batch([
    db
      .prepare(
        `UPDATE app_attest_keys
         SET sign_count = ?, last_asserted_at_utc = ?,
             validation_category = COALESCE(?, validation_category),
             bundle_version = COALESCE(?, bundle_version)
         WHERE key_id = ? AND environment = ? AND sign_count < ? AND revoked_at_utc IS NULL
           AND EXISTS (SELECT 1 FROM app_attest_challenges WHERE ${matching.sql})
           AND ${eligibility.sql}`,
      )
      .bind(
        verification.signCount,
        now,
        metadata?.validationCategory ?? null,
        metadata?.bundleVersion ?? null,
        authorization.keyId,
        appAttestEnvironment,
        verification.signCount,
        ...matching.bindings,
        ...eligibility.bindings,
      ),
    db
      .prepare(
        `UPDATE app_attest_challenges SET consumed_at_utc = ?
         WHERE ${matching.sql}
           AND ${eligibility.sql}
           AND EXISTS (
             SELECT 1 FROM app_attest_keys
             WHERE key_id = ? AND environment = ? AND sign_count = ? AND revoked_at_utc IS NULL
           )`,
      )
      .bind(
        now,
        ...matching.bindings,
        ...eligibility.bindings,
        authorization.keyId,
        appAttestEnvironment,
        verification.signCount,
      ),
    ...actionStatements(consumed),
  ]);
  return (results[0]?.meta.changes ?? 0) === 1 &&
    (results[1]?.meta.changes ?? 0) === 1
    ? "completed"
    : "conflict";
}

async function handleAppAttestChallenge(
  request: Request,
  env: Env,
): Promise<Response> {
  const payload = await deviceRequestBody(request);
  if (!isDeviceRequestPayload(payload)) return payload;
  const body = payload.body;
  const wireKeyId = body.keyId;
  const key = canonicalizeAppAttestKeyId(wireKeyId);
  if (
    body.version !== APP_ATTEST_PROTOCOL_VERSION ||
    !key ||
    typeof wireKeyId !== "string" ||
    !isExpectedAppAttestBinding(body.operation, body.method, body.path) ||
    !isCanonicalSha256Base64Url(body.bodySHA256) ||
    Object.keys(body).some(
      (name) =>
        !["version", "keyId", "operation", "method", "path", "bodySHA256"].includes(
          name,
        ),
    )
  ) {
    return json({ error: "invalid app integrity challenge" }, 400, noStoreHeaders());
  }
  const mutationRateLimitResponse = await enforceDeviceMutationRateLimit(
    request,
    env,
    "POST /v1/app-attest/challenge",
    undefined,
    key.keyId,
  );
  if (mutationRateLimitResponse) return mutationRateLimitResponse;
  const verificationEnvironment = appAttestVerificationEnvironment(env);
  const existing = await env.DB
    .prepare(
      `SELECT key_id FROM app_attest_keys
       WHERE key_id = ? AND environment = ? AND revoked_at_utc IS NULL`,
    )
    .bind(key.keyId, verificationEnvironment)
    .first<{ key_id: string }>();
  if (body.operation === "test-push" && !existing) {
    // A training push can never bootstrap an integrity key. A deletion may:
    // this lets an upgraded client remove or rebind a legacy/pre-reset record
    // when it proves possession of the exact APNs token. An empty deletion
    // from that fresh key is refused later by the mutation handler.
    return appAttestFailureResponse();
  }
  const now = new Date();
  const challengeBytes = crypto.getRandomValues(new Uint8Array(32));
  const challengeId = crypto.randomUUID();
  const proofType: AppAttestProofType = existing ? "assertion" : "attestation";
  const expiresAt = new Date(now.getTime() + APP_ATTEST_CHALLENGE_TTL_MS).toISOString();
  await env.DB.batch([
    // One active challenge per key keeps an iOS retry from leaving a pile of
    // valid signed mutation opportunities. The iOS client serializes its own
    // proof flow, and a stale request naturally receives a fresh challenge.
    env.DB
      .prepare(
        `DELETE FROM app_attest_challenges
         WHERE key_id = ? AND environment = ? AND consumed_at_utc IS NULL`,
      )
      .bind(key.keyId, verificationEnvironment),
    env.DB
      .prepare(
        `DELETE FROM app_attest_challenges WHERE expires_at_utc <= ?`,
      )
      .bind(now.toISOString()),
    env.DB
      .prepare(
        `INSERT INTO app_attest_challenges (
          id, key_id, wire_key_id, operation, method, path, body_sha256,
          challenge, required_proof, environment, created_at_utc, expires_at_utc
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .bind(
        challengeId,
        key.keyId,
        wireKeyId,
        body.operation,
        body.method,
        body.path,
        body.bodySHA256,
        base64URL(challengeBytes),
        proofType,
        verificationEnvironment,
        now.toISOString(),
        expiresAt,
      ),
  ]);
  return json(
    {
      challengeId,
      challenge: base64URL(challengeBytes),
      proofType,
      expiresAtUtc: expiresAt,
    },
    201,
    noStoreHeaders(),
  );
}

function validatedRegistrationValues(
  body: Record<string, unknown>,
): DeviceRegistrationValues | Response {
  const token = body.token;
  if (!isValidDeviceToken(token)) {
    return json({ error: "token is required" }, 400, noStoreHeaders());
  }
  if (body.sources !== undefined && !isValidSources(body.sources)) {
    return json({ error: "sources are invalid" }, 400, noStoreHeaders());
  }
  if (
    body.environment !== undefined &&
    body.environment !== "sandbox" &&
    body.environment !== "production"
  ) {
    return json({ error: "environment is invalid" }, 400, noStoreHeaders());
  }
  if (
    !isOptionalBoundedString(body.locale, 35) ||
    !isOptionalBoundedString(body.cityName, MAX_DEVICE_TEXT_LENGTH) ||
    !isOptionalFiniteNumber(body.minMagnitude, 0, 10) ||
    !isOptionalFiniteNumber(body.radiusKm, 0, 2_000) ||
    !isOptionalFiniteNumber(body.utcOffsetMinutes, -840, 840) ||
    !isOptionalBoolean(body.includeTestAlerts) ||
    !isOptionalBoolean(body.notifyAtNight) ||
    !isOptionalFiniteNumber(body.latitude, -90, 90) ||
    !isOptionalFiniteNumber(body.longitude, -180, 180)
  ) {
    return json({ error: "device registration fields are invalid" }, 400, noStoreHeaders());
  }
  const hasLatitude = body.latitude !== undefined;
  const hasLongitude = body.longitude !== undefined;
  if (hasLatitude !== hasLongitude) {
    return json(
      { error: "latitude and longitude must be provided together" },
      400,
      noStoreHeaders(),
    );
  }
  if (body.radiusKm !== undefined && !hasLatitude) {
    return json(
      { error: "radiusKm requires latitude and longitude" },
      400,
      noStoreHeaders(),
    );
  }
  return registrationValues(body);
}

async function handleDeviceRegistration(
  request: Request,
  env: Env,
  payload: DeviceRequestPayload,
  authorization: AuthorizedDeviceMutation,
): Promise<Response> {
  const body = payload.body;
  const rateLimitResponse = await enforceDeviceMutationRateLimit(
    request,
    env,
    "POST /v1/devices",
    body.token,
    authorization.keyId ?? undefined,
  );
  if (rateLimitResponse) return rateLimitResponse;
  const values = validatedRegistrationValues(body);
  if (values instanceof Response) return values;
  try {
    if (authorization.mode === "attested") {
      if (
        (await completeAttestedRegistration(env.DB, authorization, values)) !==
        "completed"
      ) {
        return appAttestConflictResponse();
      }
    } else {
      await registrationStatement(env.DB, values, null).run();
    }
  } catch (error) {
    console.error(
      JSON.stringify({
        outcome: "device_registration_failed",
        errorName: error instanceof Error ? error.name : "UnknownError",
      }),
    );
    return json(
      { error: "device registration is temporarily unavailable" },
      503,
      noStoreHeaders(),
    );
  }
  // A device token is an APNs credential. The client already supplied it, so
  // never reflect it (or the linked subscription record) back in a response.
  return json({ registered: true }, 201, noStoreHeaders());
}

async function deviceTokenFromBody(
  payload: DeviceRequestPayload,
): Promise<{ token: string } | Response> {
  if (!isValidDeviceToken(payload.body.token)) {
    return json({ error: "token is required" }, 400, noStoreHeaders());
  }
  return { token: payload.body.token };
}

function isTokenRequest(
  value: { token: string } | Response,
): value is { token: string } {
  return "token" in value;
}

type DeviceTestPushRequest =
  | { kind: "immediate"; token: string }
  | { kind: "delayed"; token: string };

/**
 * Keep the public test-push shape strict. The delayed mode has a fixed server
 * delay rather than accepting client-selected times, and its exact JSON bytes
 * are already bound into the existing `test-push` App Attest assertion.
 */
function deviceTestPushRequestFromBody(
  payload: DeviceRequestPayload,
): DeviceTestPushRequest | Response {
  const { body } = payload;
  if (!isValidDeviceToken(body.token)) {
    return json({ error: "token is required" }, 400, noStoreHeaders());
  }
  const names = Object.keys(body);
  if (names.length === 1 && Object.hasOwn(body, "token")) {
    return { kind: "immediate", token: body.token };
  }
  if (
    names.length === 2 &&
    Object.hasOwn(body, "token") &&
    Object.hasOwn(body, "delivery") &&
    body.delivery === "delayed-training"
  ) {
    return { kind: "delayed", token: body.token };
  }
  return json(
    { error: "invalid test alert request" },
    400,
    noStoreHeaders(),
  );
}

function isDeviceTestPushRequest(
  value: DeviceTestPushRequest | Response,
): value is DeviceTestPushRequest {
  return !(value instanceof Response);
}

function isEmptyDeviceDeletionRequest(body: Record<string, unknown>): boolean {
  // A no-token delete is deliberately the exact empty JSON object. Keeping
  // this distinct from malformed/unknown request shapes makes the App Attest
  // body binding stable and prevents an omitted token from broadening a
  // legacy or development deletion request.
  return Object.keys(body).length === 0;
}

/**
 * Complete a deletion addressed only by the authenticated App Attest key.
 * The client does not send an APNs token in this form, so every mutation is
 * anchored to `app_attest_key_id = authorization.keyId`; a valid key can
 * never delete a different key's subscription.
 */
async function completeAttestedKeyBoundDeletion(
  db: D1Database,
  authorization: AttestedDeviceMutation,
): Promise<"completed" | "conflict"> {
  // The unique index normally means this contains zero or one row. Reading
  // the current token only lets us remove the corresponding sanitized APNs
  // failure hash; it is never returned or logged. Each deleting statement
  // below repeats the key ownership check so a stale read cannot cross keys.
  const ownedDevices = await db
    .prepare("SELECT token FROM devices WHERE app_attest_key_id = ?")
    .bind(authorization.keyId)
    .all<{ token: string }>();
  const ownedFailureRecords = await Promise.all(
    ownedDevices.results.map(async ({ token }) => ({
      token,
      tokenHash: await tokenHash(token),
    })),
  );

  return completeAttestedAuthorization(
    db,
    authorization,
    (consumed) => [
      db
        .prepare(
          `DELETE FROM notification_deliveries
           WHERE device_token IN (
             SELECT token FROM devices
             WHERE app_attest_key_id = ? AND ${consumed.sql}
           )`,
        )
        .bind(authorization.keyId, ...consumed.bindings),
      ...ownedFailureRecords.map(({ token, tokenHash: hashedToken }) =>
        db
          .prepare(
            `DELETE FROM alert_delivery_failures
             WHERE token_hash = ? AND EXISTS (
               SELECT 1 FROM devices
               WHERE token = ? AND app_attest_key_id = ?
                 AND ${consumed.sql}
             )`,
          )
          .bind(
            hashedToken,
            token,
            authorization.keyId,
            ...consumed.bindings,
          ),
      ),
      db
        .prepare(
          `DELETE FROM devices
           WHERE app_attest_key_id = ? AND ${consumed.sql}`,
        )
        .bind(authorization.keyId, ...consumed.bindings),
      ...appAttestRetentionCleanupStatements(db, new Date().toISOString()),
    ],
  );
}

export async function handleDeviceDeletion(
  request: Request,
  env: Env,
  payload: DeviceRequestPayload,
  authorization: AuthorizedDeviceMutation,
): Promise<Response> {
  if (
    authorization.mode === "attested" &&
    isEmptyDeviceDeletionRequest(payload.body)
  ) {
    // An empty request deliberately removes only a subscription already bound
    // to this key. A newly attested key has not established ownership of a
    // legacy/unbound token, so claiming a tokenless opt-out would let a fresh
    // app instance erase someone else's subscription. The client must supply
    // the exact APNs token for that migration/recovery case.
    if (authorization.verification.proofType !== "assertion") {
      return json(
        { error: "a current device token is required to remove this registration" },
        409,
        noStoreHeaders(),
      );
    }
    const rateLimitResponse = await enforceDeviceMutationRateLimit(
      request,
      env,
      "DELETE /v1/devices",
      undefined,
      authorization.keyId,
    );
    if (rateLimitResponse) return rateLimitResponse;
    try {
      if (
        (await completeAttestedKeyBoundDeletion(env.DB, authorization)) !==
        "completed"
      ) {
        return appAttestConflictResponse();
      }
      // A fresh, valid assertion for a key that has no current device reaches
      // the same desired end state. The one-time proof remains replay-safe.
      return new Response(null, { status: 204, headers: noStoreHeaders() });
    } catch (error) {
      console.error(
        JSON.stringify({
          outcome: "attested_key_bound_device_deletion_failed",
          errorName: error instanceof Error ? error.name : "UnknownError",
        }),
      );
      return json(
        { error: "device deletion is temporarily unavailable" },
        503,
        noStoreHeaders(),
      );
    }
  }

  const body = await deviceTokenFromBody(payload);
  if (!isTokenRequest(body)) return body;
  const rateLimitResponse = await enforceDeviceMutationRateLimit(
    request,
    env,
    "DELETE /v1/devices",
    body.token,
    authorization.keyId ?? undefined,
  );
  if (rateLimitResponse) return rateLimitResponse;
  try {
    if (authorization.mode === "attested") {
      const ownership = deletionOwnershipCondition(
        body.token,
        authorization.keyId,
      );
      // APNs can rotate a token between launches. If the callback has already
      // replaced the in-memory token, deleting only that new (not-yet-synced)
      // value would leave the prior key-owned registration active forever
      // after the client disables itself. A verified key may therefore remove
      // every subscription it owns, plus the requested legacy/unbound token;
      // `ownership` still rejects a token bound to a different App Attest key.
      // Read the candidate tokens only to remove their corresponding hashed
      // delivery-failure records—tokens themselves are never returned/logged.
      const deletionCandidates = await env.DB
        .prepare(
          `SELECT token FROM devices
           WHERE app_attest_key_id = ?
              OR (token = ? AND app_attest_key_id IS NULL)`,
        )
        .bind(authorization.keyId, body.token)
        .all<{ token: string }>();
      const deletionCandidateFailureRecords = await Promise.all(
        deletionCandidates.results.map(async ({ token }) => ({
          token,
          tokenHash: await tokenHash(token),
        })),
      );
      if (
        (await completeAttestedAuthorization(
          env.DB,
          authorization,
          (consumed) => {
            const ownedOrLegacyDeviceCondition = `(
              app_attest_key_id = ?
              OR (token = ? AND app_attest_key_id IS NULL)
            ) AND ${consumed.sql}`;
            return [
              env.DB
                .prepare(
                  `DELETE FROM notification_deliveries
                   WHERE device_token IN (
                     SELECT token FROM devices
                     WHERE ${ownedOrLegacyDeviceCondition}
                   )`,
                )
                .bind(
                  authorization.keyId,
                  body.token,
                  ...consumed.bindings,
                ),
              ...deletionCandidateFailureRecords.map(({ token, tokenHash: hashedToken }) =>
                env.DB
                  .prepare(
                    `DELETE FROM alert_delivery_failures
                     WHERE token_hash = ? AND EXISTS (
                       SELECT 1 FROM devices
                       WHERE token = ?
                         AND ${ownedOrLegacyDeviceCondition}
                     )`,
                  )
                  .bind(
                    hashedToken,
                    token,
                    authorization.keyId,
                    body.token,
                    ...consumed.bindings,
                  ),
              ),
              env.DB
                .prepare(
                  `DELETE FROM devices
                   WHERE ${ownedOrLegacyDeviceCondition}`,
                )
                .bind(
                  authorization.keyId,
                  body.token,
                  ...consumed.bindings,
                ),
              ...appAttestRetentionCleanupStatements(
                env.DB,
                new Date().toISOString(),
              ),
            ];
          },
          ownership,
        )) !== "completed"
      ) {
        return appAttestConflictResponse();
      }
      // DELETE remains idempotent. A different valid App Attest key cannot
      // delete a subscription it does not own because every deletion SQL
      // statement includes this key binding.
      return new Response(null, { status: 204, headers: noStoreHeaders() });
    }
    const outcome = await deleteDeviceRegistration(env.DB, body.token);
    if (outcome === "not_deleted") {
      console.error(JSON.stringify({ outcome: "device_deletion_not_completed" }));
      return json(
        { error: "device deletion is temporarily unavailable" },
        503,
        noStoreHeaders(),
      );
    }
    // DELETE remains idempotent: a token already removed by a concurrent
    // client refresh or APNs cleanup has the same desired final state.
    return new Response(null, { status: 204, headers: noStoreHeaders() });
  } catch (error) {
    console.error(
      JSON.stringify({
        outcome: "device_deletion_failed",
        errorName: error instanceof Error ? error.name : "UnknownError",
      }),
    );
    return json(
      { error: "device deletion is temporarily unavailable" },
      503,
      noStoreHeaders(),
    );
  }
}

type ProductionTrainingTestPushClaimOutcome =
  | "claimed"
  | "already_claimed"
  | "conflict";

export interface ProductionTrainingTestPushClaimResult {
  outcome: ProductionTrainingTestPushClaimOutcome;
  window: ProductionTrainingTestPushWindow;
}

/**
 * Atomically consume an already-verified App Attest assertion, advance its
 * monotonic counter, and claim the one permitted production training push for
 * this key and UTC day. The INSERT-or-ignore result is read from the same D1
 * transaction, so two concurrent valid assertions cannot both reach APNs.
 */
export async function completeAttestedProductionTrainingTestPushClaim(
  db: D1Database,
  authorization: AttestedDeviceMutation,
  token: string,
  now = new Date(),
): Promise<ProductionTrainingTestPushClaimResult> {
  const window = productionTrainingTestPushWindow(now);
  const verification = authorization.verification;
  // Test-push challenges intentionally cannot bootstrap a new App Attest key.
  // Keep that invariant here as well so callers cannot broaden it later.
  if (verification.proofType !== "assertion") {
    return { outcome: "conflict", window };
  }
  // A development AAGUID is never eligible to trigger an APNs production
  // training alert, even if a caller supplied a production-looking device
  // payload to an isolated staging Worker.
  if (appAttestMutationEnvironment(authorization) !== "production") {
    return { outcome: "conflict", window };
  }

  const nowUtc = now.toISOString();
  const matching = challengeMatchesNow(authorization.challenge, nowUtc);
  const consumed = challengeConsumedNowCondition(authorization.challenge.id, nowUtc);
  const metadata = verification.metadata;
  // The conditional claim repeats the ownership and production-environment
  // checks inside the transaction. A device deleted or rebound after the
  // earlier lookup cannot consume a daily production-test slot for another
  // subscription.
  const ownsProductionDevice = {
    sql: `EXISTS (
      SELECT 1 FROM devices
      WHERE token = ? AND app_attest_key_id = ? AND environment = 'production'
    )`,
    bindings: [token, authorization.keyId],
  };
  const results = await db.batch([
    db
      .prepare(
        `UPDATE app_attest_keys
         SET sign_count = ?, last_asserted_at_utc = ?,
             validation_category = COALESCE(?, validation_category),
             bundle_version = COALESCE(?, bundle_version)
         WHERE key_id = ? AND environment = 'production' AND sign_count < ? AND revoked_at_utc IS NULL
           AND EXISTS (SELECT 1 FROM app_attest_challenges WHERE ${matching.sql})
           AND ${ownsProductionDevice.sql}`,
      )
      .bind(
        verification.signCount,
        nowUtc,
        metadata?.validationCategory ?? null,
        metadata?.bundleVersion ?? null,
        authorization.keyId,
        verification.signCount,
        ...matching.bindings,
        ...ownsProductionDevice.bindings,
      ),
    db
      .prepare(
        `UPDATE app_attest_challenges SET consumed_at_utc = ?
         WHERE ${matching.sql}
           AND ${ownsProductionDevice.sql}
           AND EXISTS (
             SELECT 1 FROM app_attest_keys
             WHERE key_id = ? AND environment = 'production' AND sign_count = ? AND revoked_at_utc IS NULL
           )`,
      )
      .bind(
        nowUtc,
        ...matching.bindings,
        ...ownsProductionDevice.bindings,
        authorization.keyId,
        verification.signCount,
      ),
    db
      .prepare(
        `INSERT OR IGNORE INTO production_training_test_push_claims (
          app_attest_key_id, utc_day, claimed_at_utc, expires_at_utc
        ) SELECT ?, ?, ?, ?
        WHERE ${consumed.sql} AND ${ownsProductionDevice.sql}`,
      )
      .bind(
        authorization.keyId,
        window.utcDay,
        nowUtc,
        window.expiresAtUtc,
        ...consumed.bindings,
        ...ownsProductionDevice.bindings,
      ),
  ]);
  const authorizationCompleted =
    (results[0]?.meta.changes ?? 0) === 1 &&
    (results[1]?.meta.changes ?? 0) === 1;
  if (!authorizationCompleted) return { outcome: "conflict", window };
  return {
    outcome: (results[2]?.meta.changes ?? 0) === 1
      ? "claimed"
      : "already_claimed",
    window,
  };
}

export async function handleDeviceTestPush(
  request: Request,
  env: Env,
  payload: DeviceRequestPayload,
  authorization: AuthorizedDeviceMutation,
): Promise<Response> {
  const body = deviceTestPushRequestFromBody(payload);
  if (!isDeviceTestPushRequest(body)) return body;
  const rateLimitResponse = await enforceDeviceMutationRateLimit(
    request,
    env,
    "POST /v1/devices/test",
    body.token,
    authorization.keyId ?? undefined,
  );
  if (rateLimitResponse) return rateLimitResponse;
  const row = await env.DB
    .prepare(
      authorization.mode === "attested"
        ? "SELECT * FROM devices WHERE token = ? AND app_attest_key_id = ?"
        : "SELECT * FROM devices WHERE token = ?",
    )
    .bind(
      body.token,
      ...(authorization.mode === "attested" ? [authorization.keyId] : []),
    )
    .first<DeviceRow>();
  if (!row) return json({ error: "device not found" }, 404, noStoreHeaders());
  const device = rowToDevice(row);
  if (!productionTestPushAllowed(env, device)) {
    return json(
      { error: "production test alerts are disabled" },
      403,
      noStoreHeaders(),
    );
  }
  if (!hasApnsConfiguration(env)) {
    return json(
      { error: "APNs credentials are not configured" },
      503,
      noStoreHeaders(),
    );
  }
  if (body.kind === "delayed" && device.environment !== "production") {
    // The delayed path exists only to obtain production TestFlight evidence.
    // Keep sandbox development tests on the synchronous, visibly interactive
    // path so a staging Worker cannot accumulate scheduled background work.
    return json(
      { error: "delayed test alerts require a production TestFlight device" },
      403,
      noStoreHeaders(),
    );
  }
  if (device.environment === "production") {
    // A production training push is never available through a development
    // bypass, even if a misconfigured non-production Worker happens to point
    // at an APNs production token. There must be one existing, asserted App
    // Attest key to own the daily claim.
    if (authorization.mode !== "attested") {
      return json(
        { error: "production test alerts require app integrity verification" },
        403,
        noStoreHeaders(),
      );
    }
    try {
      const claim = await completeAttestedProductionTrainingTestPushClaim(
        env.DB,
        authorization,
        body.token,
      );
      if (claim.outcome === "conflict") return appAttestConflictResponse();
      if (claim.outcome === "already_claimed") {
        return productionTrainingTestPushLimitResponse(claim.window);
      }
    } catch (error) {
      // Do not include an APNs token, App Attest key, proof, or request body in
      // an operational log. A claim-storage failure must fail closed before
      // attempting a production training notification.
      console.error(
        JSON.stringify({
          outcome: "production_training_test_push_claim_failed",
          errorName: error instanceof Error ? error.name : "UnknownError",
        }),
      );
      return json(
        { error: "production test alert is temporarily unavailable" },
        503,
        noStoreHeaders(),
      );
    }
  } else if (authorization.mode === "attested") {
    // Preserve the existing assertion counter/challenge transaction for
    // sandbox tests. The durable once-per-UTC-day claim is intentionally only
    // for a real production APNs delivery.
    if (
      (await completeAttestedAuthorization(env.DB, authorization)) !== "completed"
    ) {
      return appAttestConflictResponse();
    }
  }
  if (body.kind === "delayed") {
    // The production branch above completed the existing App Attest assertion
    // and one-per-key-per-UTC-day D1 claim before scheduling. A failed
    // scheduler write deliberately consumes that same daily slot, matching the
    // existing policy that an APNs failure is still one outbound attempt.
    if (authorization.mode !== "attested") {
      return json(
        { error: "production test alerts require app integrity verification" },
        403,
        noStoreHeaders(),
      );
    }
    try {
      return json(
        {
          accepted: true,
          scheduledAtUtc: await scheduleDelayedTrainingTestPush(
            env,
            authorization.keyId,
          ),
        },
        202,
        noStoreHeaders(),
      );
    } catch (error) {
      // No request data, APNs token, or App Attest identifier is logged. The
      // accepted claim remains the durable at-most-one attempt boundary.
      console.error(
        JSON.stringify({
          outcome: "delayed_training_test_push_schedule_failed",
          errorName: error instanceof Error ? error.name : "UnknownError",
        }),
      );
      return json(
        { error: "delayed test alert is temporarily unavailable" },
        503,
        noStoreHeaders(),
      );
    }
  }
  const now = new Date().toISOString();
  const event: NormalizedEvent = {
    id: "test:0",
    sourceId: device.sources[0] ?? "jma_eew",
    eventId: "TEST-EVENT",
    serial: 1,
    kind: "eew",
    originTimeUtc: now,
    reportTimeUtc: now,
    hypocenter: "Test Region",
    latitude: 35,
    longitude: 135,
    magnitude: 5.5,
    depth: 10,
    maxIntensity: "5-",
    isWarn: true,
    isFinal: false,
    isCancel: false,
    isTraining: true,
    tsunami: null,
    raw: null,
  };
  const deviceTokenHash = await tokenHash(device.token);
  try {
    const result = await sendPush(
      env,
      device,
      event,
      "training",
      await cachedApnsAuthorizationFromRelay(env),
      await apnsCollapseID(event),
    );
    if (!result.ok) {
      logApnsFailure(event, "training", deviceTokenHash, result);
      return json(
        { error: "test alert could not be delivered" },
        502,
        noStoreHeaders(),
      );
    }
  } catch (error) {
    logApnsException(event, "training", deviceTokenHash, error);
    return json(
      { error: "test alert could not be delivered" },
      502,
      noStoreHeaders(),
    );
  }
  return json({ ok: true }, 200, noStoreHeaders());
}

async function handleRequest(
  request: Request,
  env: Env,
): Promise<Response> {
  // The public API is consumed by native clients, not browser JavaScript.
  // Deliberately do not grant a cross-origin browser read/write capability.
  if (request.method === "OPTIONS") {
    return new Response(null, { status: 405, headers: { allow: "GET, POST, DELETE" } });
  }
  const url = new URL(request.url);

  if (url.pathname === "/") {
    return json({
      name: "QuakeSignal Notification Service",
      runtime: "Cloudflare Workers + Durable Objects + D1",
      purpose: "APNs alert delivery only",
      earthquakeData: "Clients fetch directly from Wolfx",
      health: "/healthz",
    });
  }
  if (url.pathname === "/privacy" && request.method === "GET") {
    return legalPage(
      "Privacy Policy",
      "QuakeSignal is designed to collect only the information required to provide location-aware earthquake notifications.",
      [
        {
          heading: "Data we process",
          body: "If you enable notifications, the service stores the APNs device token, app locale, selected earthquake sources, magnitude threshold, alert preferences (including a test-alert preference), alert radius, optional selected-city label, registration timestamps, and one approximate coordinate on a 0.1° grid. That coordinate is derived from either the selected city's coordinate or the current device location; neither an exact GPS fix nor an unrounded selected-city coordinate is sent. To prevent fraudulent subscription changes, the service also stores an opaque Apple App Attest key identifier, public verification key, attestation receipt, monotonic assertion counter, and integrity timestamps; newer Apple proofs may additionally carry the app build version and distribution category. The app does not require an account, name, email address, contacts, photos, or advertising identifier.",
        },
        {
          heading: "How data is used",
          body: "Subscription data is used only to decide whether an earthquake event matches your preferences and to send the requested Apple Push Notification. Location is not used for advertising, profiling, or sale.",
        },
        {
          heading: "Storage and deletion",
          body: "Subscription settings and the associated App Attest integrity record are stored in Cloudflare D1. Removing notification registration from the app deletes the matching device registration, even when this launch has no APNs token, if an existing App Attest key can prove it owns that subscription. A new key cannot claim a legacy subscription with an empty request. After reinstall or device restore, a fresh Apple attestation plus the exact APNs token may safely rebind that one token and retire its old key record; assertions and tokenless requests cannot transfer another key's subscription. If it was the last registration using an App Attest key, that associated verifier, receipt, and assertion-counter record is deleted. A reviewed production training test creates a separate token-free claim containing only the opaque App Attest key ID and UTC timestamps; it is retained for at most 14 days to enforce one production training attempt per key per UTC day. Its optional fixed-delay check also creates one private scheduler record containing only that opaque App Attest key ID, a due time, and an at-most-once attempted state; it contains no APNs token, request body, proof, preferences, location, or earthquake payload. That temporary record is deleted after its one scheduled attempt or cancellation; an alarm more than 30 seconds late is deleted without delivery. Each App Attest challenge expires in no more than five minutes and expired records are removed by routine cleanup. A daily retention job purges registrations that are not refreshed for 90 days with their orphaned integrity records. Sanitized delivery-failure token hashes are retained for at most 14 days for reliability investigations. Disabling notifications or location access stops new collection but does not reliably send a deletion request, so use the in-app removal control when possible.",
        },
        {
          heading: "Third-party services",
          body: "The app fetches earthquake information directly from the Wolfx Open API. Cloudflare is used only to store notification subscriptions, verify Apple App Attest proofs, watch upstream alerts, and request delivery through Apple Push Notification service. Their handling of network metadata is governed by their own policies. The App Attest private key never leaves your device.",
        },
        {
          heading: "Safety notice",
          body: "QuakeSignal is not an official government warning platform. Data and notifications can be delayed, incomplete, or inaccurate. Follow official announcements and local emergency instructions.",
        },
      ],
    );
  }
  if (url.pathname === "/terms" && request.method === "GET") {
    return legalPage(
      "Terms of Use",
      "By using QuakeSignal, you acknowledge the limitations of third-party earthquake data and mobile notification delivery.",
      [
        {
          heading: "Informational service",
          body: "QuakeSignal provides aggregated earthquake information and preparedness guidance for general informational purposes. It is not an official emergency warning system and does not replace government alerts, emergency services, or professional advice.",
        },
        {
          heading: "No delivery guarantee",
          body: "Earthquake data may be revised or cancelled. Internet connectivity, upstream providers, Cloudflare, Apple Push Notification service, iOS settings, Focus modes, and device state can delay or prevent delivery.",
        },
        {
          heading: "Your responsibility",
          body: "Use official sources for authoritative information and follow local emergency instructions. Do not rely on QuakeSignal as the sole basis for safety-critical decisions.",
        },
        {
          heading: "Open-source software",
          body: "The application source is offered under the MIT License. These service terms do not expand the warranties or liabilities in that license.",
        },
      ],
    );
  }
  if (url.pathname === "/support" && request.method === "GET") {
    return legalPage(
      "Support",
      "Get help with notifications, data sources, localization, or earthquake subscription settings.",
      [
        {
          heading: "Before reporting a problem",
          body: "Confirm that notifications and location access are enabled in iOS Settings, your selected source and magnitude threshold match the event, and the device has a working network connection.",
        },
        {
          heading: "Report an issue",
          body: "Open a GitHub issue with your app version, iOS version, language, selected data source, and a description of what happened. Never include an APNs device token or precise home address.",
        },
      ],
    );
  }
  if (url.pathname === "/healthz" && request.method === "GET") {
    // Do this before obtaining the global relay stub. A health flood must be
    // rejected at the edge rather than forcing the alert relay into startup,
    // D1 health queries, or outbox recovery work.
    const rateLimitResponse = await enforceDeviceEndpointRateLimit(
      env,
      "GET /healthz",
    );
    if (rateLimitResponse) return rateLimitResponse;
    try {
      const relay = env.RELAY.get(env.RELAY.idFromName("global"));
      const response = await relay.fetch("https://relay.internal/status");
      return json(await response.json(), response.status);
    } catch (error) {
      // A relay storage outage (including exhausted Durable Object writes)
      // must not turn readiness into a Worker exception. Do not expose the
      // provider error; return an explicitly fail-closed, cache-bypassing
      // health document so monitors can distinguish this from a healthy 200.
      console.error(
        JSON.stringify({
          outcome: "relay_health_status_unavailable",
          errorName: error instanceof Error ? error.name : "UnknownError",
        }),
      );
      return json(
        {
          ok: false,
          mode: "notification-only",
          error: "relay health status is temporarily unavailable",
          upstreams: Object.fromEntries(
            ALL_WOLFX_SOURCES.map((source) => [source, "unavailable"]),
          ),
          upstream: {
            status: "degraded",
            transport: "degraded",
            websocketStatus: "degraded",
            httpFallbackActive: null,
            staleSources: ALL_WOLFX_SOURCES,
            pendingIngestSources: ALL_WOLFX_SOURCES,
            sources: {},
          },
          delivery: {
            apnsConfigured: null,
            activeDlqIncidents: null,
            pendingDlqPersistenceFallbacks: null,
            activePageFailures: null,
            activeQuarantinedFailures: null,
            activeRetryFailures: null,
            pendingOutboxRows: null,
            staleOutboxRows: null,
            status: "degraded",
          },
        },
        503,
        noStoreHeaders(),
      );
    }
  }
  if (
    url.pathname === "/v1/live" ||
    url.pathname === "/v1/quakes/recent" ||
    url.pathname.startsWith("/v1/quakes/")
  ) {
    return json({
      error: "earthquake data endpoints are disabled; fetch directly from Wolfx",
    }, 410);
  }
  if (url.pathname.startsWith("/v1/app-attest/")) {
    // Reserve the same fail-closed limits for the App Attest challenge and
    // bootstrap routes. Their handlers are added separately, but this guard
    // means an unauthenticated route cannot become an unbounded mutation by
    // accident during that rollout.
    const route = appAttestRateLimitRoute(request, url.pathname);
    const endpointRateLimitResponse = await enforceDeviceEndpointRateLimit(
      env,
      route,
    );
    if (endpointRateLimitResponse) return endpointRateLimitResponse;
    if (url.pathname !== "/v1/app-attest/challenge") {
      const mutationRateLimitResponse = await enforceDeviceMutationRateLimit(
        request,
        env,
        route,
      );
      if (mutationRateLimitResponse) return mutationRateLimitResponse;
    }
  }
  if (
    url.pathname === "/v1/app-attest/challenge" &&
    request.method === "POST"
  ) {
    const challengeRateLimitResponse = await enforceAppAttestChallengeRateLimit(
      env,
    );
    if (challengeRateLimitResponse) return challengeRateLimitResponse;
    return handleAppAttestChallenge(request, env);
  }
  if (url.pathname === "/v1/devices" && request.method === "POST") {
    const rateLimitResponse = await enforceDeviceEndpointRateLimit(
      env,
      "POST /v1/devices",
    );
    if (rateLimitResponse) return rateLimitResponse;
    const payload = await deviceRequestBody(request);
    if (!isDeviceRequestPayload(payload)) return payload;
    const authorization = await authorizeAppAttestMutation(
      request,
      payload,
      env,
      "device-registration",
    );
    if (authorization instanceof Response) return authorization;
    return handleDeviceRegistration(request, env, payload, authorization);
  }
  if (url.pathname === "/v1/devices" && request.method === "DELETE") {
    const rateLimitResponse = await enforceDeviceEndpointRateLimit(
      env,
      "DELETE /v1/devices",
    );
    if (rateLimitResponse) return rateLimitResponse;
    const payload = await deviceRequestBody(request);
    if (!isDeviceRequestPayload(payload)) return payload;
    const authorization = await authorizeAppAttestMutation(
      request,
      payload,
      env,
      "device-deletion",
    );
    if (authorization instanceof Response) {
      // A tokenless deletion is meaningful only with a verified App Attest
      // key. Preserve the normal missing-token contract for development,
      // bypass, and unauthenticated clients rather than exposing a second
      // deletion capability to them.
      return isEmptyDeviceDeletionRequest(payload.body)
        ? json({ error: "token is required" }, 400, noStoreHeaders())
        : authorization;
    }
    return handleDeviceDeletion(request, env, payload, authorization);
  }
  if (url.pathname === "/v1/devices/test" && request.method === "POST") {
    const rateLimitResponse = await enforceDeviceEndpointRateLimit(
      env,
      "POST /v1/devices/test",
    );
    if (rateLimitResponse) return rateLimitResponse;
    const payload = await deviceRequestBody(request);
    if (!isDeviceRequestPayload(payload)) return payload;
    const authorization = await authorizeAppAttestMutation(
      request,
      payload,
      env,
      "test-push",
    );
    if (authorization instanceof Response) return authorization;
    return handleDeviceTestPush(request, env, payload, authorization);
  }
  return json({ error: "not found" }, 404);
}

async function handleAlertDeliveryQueue(
  batch: MessageBatch<unknown>,
  env: Env,
): Promise<void> {
  const queueNames = resolveAlertDeliveryQueueNames(env);
  if (batch.queue === queueNames.deadLetter) {
    await handleAlertDeliveryDlq(batch, env);
    return;
  }

  if (batch.queue === queueNames.persistenceFallback) {
    // This Queue must remain consumerless so exhausted D1-persistence failures
    // remain available for operator recovery instead of being acknowledged by
    // this Worker. Throwing makes an accidental consumer attachment explicit
    // in Queue errors and preserves the message for that consumer's retry
    // lifecycle rather than silently discarding it here.
    console.error(
      JSON.stringify({
        queue: batch.queue,
        outcome: "alert_delivery_dlq_persistence_fallback_consumer_misconfigured",
      }),
    );
    throw new Error(
      "The alert-delivery DLQ persistence fallback queue must not have a Worker consumer",
    );
  }

  if (batch.queue !== queueNames.primary) {
    for (const message of batch.messages) {
      console.error(
        JSON.stringify({
          queueMessageId: message.id,
          queueAttempt: message.attempts,
          queue: batch.queue,
          outcome: "unexpected_alert_queue_message_discarded",
        }),
      );
      message.ack();
    }
    return;
  }

  const relay = env.RELAY.get(env.RELAY.idFromName("global"));
  for (const message of batch.messages) {
    if (!isAlertDeliveryMessage(message.body)) {
      if (isLegacyAlertDeliveryMessage(message.body)) {
        try {
          // A Worker upgrade can encounter a pre-outbox Queue message. First
          // place it in D1, then ack the legacy Queue copy; never discard it
          // merely because the new acknowledgement protocol adds outboxId.
          const response = await relay.fetch(
            new Request("https://relay.internal/outbox/legacy", {
              method: "POST",
              headers: { "content-type": "application/json" },
              body: JSON.stringify(message.body),
            }),
          );
          if (response.ok) {
            message.ack();
          } else {
            message.retry({ delaySeconds: retryDelaySeconds(message.attempts) });
          }
        } catch (error) {
          console.warn(
            JSON.stringify({
              queueMessageId: message.id,
              queueAttempt: message.attempts,
              outcome: "legacy_alert_queue_outbox_migration_retry",
              errorName: error instanceof Error ? error.name : "UnknownError",
            }),
          );
          message.retry({ delaySeconds: retryDelaySeconds(message.attempts) });
        }
        continue;
      }
      console.error(
        JSON.stringify({
          queueMessageId: message.id,
          queueAttempt: message.attempts,
          outcome: "invalid_alert_queue_message_discarded",
        }),
      );
      message.ack();
      continue;
    }
    try {
      const response = await relay.fetch(
        new Request("https://relay.internal/deliver", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify(message.body),
        }),
      );
      if (response.ok) {
        // D1 remains the hand-off source of truth until delivery has completed
        // and this acknowledgement is durable. If the Queue ack itself is
        // lost, a later message sees the outbox record already acknowledged
        // and safely finishes without re-sending APNs work.
        const outboxAck = await relay.fetch(
          new Request("https://relay.internal/outbox/ack", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ outboxId: message.body.outboxId }),
          }),
        );
        if (outboxAck.ok) {
          message.ack();
        } else {
          console.error(
            JSON.stringify({
              queueMessageId: message.id,
              queueAttempt: message.attempts,
              deliveryId: message.body.deliveryId,
              outboxId: message.body.outboxId,
              outcome: "alert_delivery_outbox_ack_retry",
              status: outboxAck.status,
            }),
          );
          message.retry({ delaySeconds: retryDelaySeconds(message.attempts) });
        }
      } else if (response.status >= 400 && response.status < 500) {
        // Keep even an unexpected relay 4XX in the Queue retry/DLQ lifecycle.
        // Acknowledging it here would leave the durable outbox row pending and
        // eventually resurrect it after its hand-off lease expired.
        console.error(
          JSON.stringify({
            queueMessageId: message.id,
            queueAttempt: message.attempts,
            deliveryId: message.body.deliveryId,
            outcome: "alert_delivery_relay_client_failure_retry",
            status: response.status,
          }),
        );
        message.retry({
          delaySeconds: retryDelaySecondsFromRelay(response, message.attempts),
        });
      } else {
        message.retry({
          delaySeconds: retryDelaySecondsFromRelay(response, message.attempts),
        });
      }
    } catch (error) {
      console.warn(
        JSON.stringify({
          queueMessageId: message.id,
          queueAttempt: message.attempts,
          deliveryId: message.body.deliveryId,
          outcome: "alert_delivery_consumer_retry",
          errorName: error instanceof Error ? error.name : "UnknownError",
        }),
      );
      message.retry({ delaySeconds: retryDelaySeconds(message.attempts) });
    }
  }
}

/**
 * DLQ messages are incident evidence, not retry candidates. Persist only
 * delivery metadata (never a device token or event payload) and acknowledge
 * after that write succeeds. If D1 remains unavailable, the bounded Queue
 * retry policy routes the original message to the intentionally consumerless
 * terminal evidence Queue rather than allowing it to be silently discarded.
 * Operators resolve/replay it manually before that Queue's retention expires.
 */
async function handleAlertDeliveryDlq(
  batch: MessageBatch<unknown>,
  env: Env,
): Promise<void> {
  const relay = env.RELAY.get(env.RELAY.idFromName("global"));
  for (const message of batch.messages) {
    const evidence = dlqIncidentEvidence(message);
    try {
      const incidentRecorded = await persistDlqIncidentAndFinalizeOutbox(
        env,
        evidence,
      );
      if (incidentRecorded) {
        console.error(
          JSON.stringify({
            queueMessageId: message.id,
            queueAttempt: message.attempts,
            deliveryId: evidence.deliveryId,
            eventId: evidence.eventId,
            sourceId: evidence.sourceId,
            notificationReason: evidence.notificationReason,
            outcome: "alert_delivery_dlq_incident_recorded",
          }),
        );
      } else {
        // This Queue copy arrived after its owned row reached another terminal
        // outcome. Acknowledging it is safe: the conditional D1 batch proved
        // it cannot create a new active incident or alter that final decision.
        console.info(
          JSON.stringify({
            queueMessageId: message.id,
            queueAttempt: message.attempts,
            outboxId: evidence.outboxId,
            outcome: "alert_delivery_dlq_terminal_outbox_discarded",
          }),
        );
      }
      message.ack();
      continue;
    } catch (d1Error) {
      // D1 is unavailable, but acknowledging the DLQ message would lose the
      // only terminal-delivery evidence. First persist a token-free marker in
      // the global Durable Object, which can later replay the identical D1
      // transaction before normal outbox work resumes.
      try {
        const fallback = await relay.fetch(
          new Request("https://relay.internal/dlq/persistence-fallback", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify(evidence),
          }),
        );
        if (!fallback.ok) {
          throw new Error(
            `DLQ persistence fallback returned HTTP ${fallback.status}`,
          );
        }
        console.error(
          JSON.stringify({
            queueMessageId: message.id,
            queueAttempt: message.attempts,
            deliveryId: evidence.deliveryId,
            eventId: evidence.eventId,
            sourceId: evidence.sourceId,
            notificationReason: evidence.notificationReason,
            outcome: "alert_delivery_dlq_persistence_fallback_recorded",
            d1ErrorName: d1Error instanceof Error ? d1Error.name : "UnknownError",
          }),
        );
        message.ack();
      } catch (fallbackError) {
        // If both D1 and the independent Durable Object fallback are
        // unavailable, do not acknowledge. The DLQ's bounded retry policy
        // ultimately routes the original Queue message to its consumerless
        // terminal-evidence Queue for external operator recovery.
        console.error(
          JSON.stringify({
            queueMessageId: message.id,
            queueAttempt: message.attempts,
            outcome: "alert_delivery_dlq_persistence_retry",
            d1ErrorName: d1Error instanceof Error ? d1Error.name : "UnknownError",
            fallbackErrorName:
              fallbackError instanceof Error ? fallbackError.name : "UnknownError",
          }),
        );
        message.retry({ delaySeconds: retryDelaySeconds(message.attempts) });
      }
    }
  }
}

export default {
  fetch: handleRequest,
  queue: handleAlertDeliveryQueue,
};
