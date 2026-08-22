import {
  extractEqlistEntries,
  normalizeJmaEew,
  normalizeJmaEqlistEntry,
} from "../../src/alerts/normalize";
import type {
  AlertSound,
  DeviceRecord,
  NormalizedEvent,
  NotifyReason,
} from "../../src/types/domain";
import {
  buildPushPayload,
  DEFAULT_ALERT_SOUND,
  isAlertSound,
  normalizedAlertSound,
  notificationReasonForEvent,
  reconcileEventRevision,
  URGENT_EEW_DELIVERY_TTL_MS,
} from "../../src/push/policy";

// Named exports keep the safety policy directly exercisable by the focused
// bundled Worker tests without duplicating its implementation in a fixture.
export { buildPushPayload, notificationReasonForEvent, reconcileEventRevision };
import {
  isHeartbeat,
  isPong,
  type JmaEewMessage,
  type JmaEqlistEntry,
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

/**
 * Non-secret App Attest inputs that determine which proofs the Worker accepts.
 * They are deliberately separate from `Env` so the effective policy can be
 * made visible through the read-only health contract and tested without
 * creating Durable Object or D1 bindings.
 */
export interface AppAttestPolicyEnvironment {
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

/**
 * Server-owned routing from one cryptographically verified App Attest app ID
 * to its APNs topic. The JSON allow-list is deliberately separate from the
 * registration body: a client may select only an identity that its App Attest
 * proof subsequently authenticates, and can never provide a topic directly.
 */
export interface AppIdentityRoutingEnvironment {
  APP_ATTEST_APP_ID?: string;
  APP_ATTEST_APNS_ROUTES?: string;
  /** Legacy single-topic fallback used only when the route allow-list is unset. */
  APNS_BUNDLE_ID?: string;
}

interface Env extends AlertDeliveryQueueNameEnvironment, AppAttestPolicyEnvironment,
  AppIdentityRoutingEnvironment {
  DB: D1Database;
  RELAY: DurableObjectNamespace;
  /**
   * A deliberately narrow per-App-Attest-key scheduler. It stores no APNs
   * token and gives an internal TestFlight tester time to background, lock, or
   * terminate the app before one reviewed training notification is attempted.
   */
  TRAINING_PUSH_SCHEDULER: DurableObjectNamespace;
  ALERT_DELIVERY_QUEUE: Queue<AlertDeliveryMessage>;
  /** Higher route-wide circuit breaker, used only after the client budget. */
  DEVICE_API_RATE_LIMIT: RateLimit;
  DEVICE_MUTATION_RATE_LIMIT: RateLimit;
  /**
   * Historical name for every public route's lower pre-proof client budget.
   * Its pseudonymous key is derived only from Cloudflare's authenticated
   * client-IP header, never caller key input.
   */
  APP_ATTEST_CHALLENGE_RATE_LIMIT: RateLimit;
  APNS_PRIVATE_KEY?: string;
  APNS_KEY_ID?: string;
  APNS_TEAM_ID?: string;
  ENABLE_PRODUCTION_TEST_PUSH?: string;
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
  alert_sound?: string | null;
  city_name: string | null;
  latitude: number | null;
  longitude: number | null;
  radius_km: number | null;
  include_test_alerts: number;
  utc_offset_minutes: number | null;
  notify_at_night: number;
  app_attest_key_id?: string | null;
  /** Added by migration 0011; optional here for rolling tests/legacy fixtures. */
  app_identity?: string | null;
  apns_topic?: string | null;
  app_platform?: string | null;
  /** Added by migration 0013; optional for focused legacy-row fixtures. */
  registration_revision?: string;
  created_at: string;
  updated_at: string;
}

const HTTP_BASE = "https://api.wolfx.jp";
/**
 * Build 8's APNs relay intentionally accepts only feeds whose upstream reuse
 * terms have been mapped for this release. Keep this policy immutable and
 * server-owned: a registration body or deployment variable cannot widen it.
 */
export const APNS_RELAY_EEW_SOURCES = [
  "jma_eew",
] as const satisfies readonly WolfxSourceId[];
const APNS_RELAY_REPORT_SOURCES = [
  "jma_eqlist",
] as const satisfies readonly WolfxSourceId[];
export const APNS_RELAY_SOURCES = [
  ...APNS_RELAY_EEW_SOURCES,
  ...APNS_RELAY_REPORT_SOURCES,
] as const satisfies readonly WolfxSourceId[];
export const APNS_RELAY_DISABLED_SOURCES = [
  "sc_eew",
  "cenc_eew",
  "fj_eew",
  "cq_eew",
  "cenc_eqlist",
] as const satisfies readonly WolfxSourceId[];
type ApnsRelaySourceId = (typeof APNS_RELAY_SOURCES)[number];

export function isApnsRelaySource(value: unknown): value is ApnsRelaySourceId {
  return typeof value === "string" &&
    (APNS_RELAY_SOURCES as readonly string[]).includes(value);
}

function isDisabledApnsRelaySource(value: unknown): value is WolfxSourceId {
  return typeof value === "string" &&
    (APNS_RELAY_DISABLED_SOURCES as readonly string[]).includes(value);
}

const UPSTREAM_ROUTES = ["jma_eew", "jma_eqlist"] as const;
type UpstreamRoute = (typeof UPSTREAM_ROUTES)[number];
interface UpstreamDataReadinessCandidate {
  socket: WebSocket;
  durableIntentRecorded: boolean;
}
const APNS_MAX_CONCURRENT_DELIVERIES = 2;
// Keep one queue message comfortably below Workers' subrequest limits. A
// single-recipient page leaves conservative headroom under the Workers Free
// 50-query invocation budget even when admission, terminal cleanup, outcome
// reconciliation, gates, and one child-page append all run. Routine outbox and
// durability maintenance are alarm-owned and never composed with this page.
const DEVICE_DELIVERY_PAGE_SIZE = 1;
const DEVICE_REGISTRATION_MAX_AGE_MS = 90 * 24 * 60 * 60_000;
const DELIVERY_DEDUP_RETENTION_MS = 14 * 24 * 60 * 60_000;
// Normalized upstream facts are private relay state, not a public historical
// feed. The daily cleanup uses an 89-day eligibility cutoff while comfortably
// exceeding every Queue/outbox safety window. A failed or delayed cleanup may
// postpone deletion and is disclosed in the public privacy text.
const RELAY_EVENT_RETENTION_CUTOFF_MS = 89 * 24 * 60 * 60_000;
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
// Earthquake-list WebSocket messages are complete ranked snapshots, not
// individual EEW revisions. Keep their intent in one durable cursor and commit
// a source fingerprint only after every contained event has crossed the D1
// boundary. A repeated unchanged 50-entry list then costs a read, rather than
// fifty journal puts and fifty deletes.
const PENDING_LIVE_SNAPSHOT_PREFIX = "pending-live-snapshot:";
const PENDING_LIVE_SNAPSHOT_LATEST_PREFIX = "pending-live-snapshot-latest:";
// A source can receive one more complete ranked-list frame while the active
// cursor and its newest replacement are both waiting on D1. Retain that third
// *accepted* frame before applying WebSocket backpressure, rather than
// silently dropping an earthquake report that exists only in that frame.
// Frames after the source is closed are intentionally not admitted: this is a
// fixed three-slot durable boundary, not a write-per-frame queue.
const PENDING_LIVE_SNAPSHOT_OVERFLOW_PREFIX = "pending-live-snapshot-overflow:";
const LIVE_SNAPSHOT_OVERLOAD_PREFIX = "live-snapshot-overload:";
const UPSTREAM_LIVE_SNAPSHOT_FINGERPRINT_PREFIX =
  "upstream-live-snapshot-fingerprint:";
const PENDING_INGEST_RETRY_DELAY_MS = 5_000;
// Point-event feeds normally publish one revision at a time, but an upstream
// reconnect can replay the same revision rapidly. Keep a small resident cache
// of *post-D1-commit* event fingerprints so those replays do not churn the
// Durable Object journal. The cache is intentionally not durable: a restart
// falls back to the journal/D1 correctness path rather than claiming work was
// committed when it was not.
const RECENT_COMMITTED_LIVE_EVENT_FINGERPRINT_LIMIT = 512;
const LIVE_SNAPSHOT_FAILURE_RETRY_DELAY_MS = 60_000;
const LIVE_SNAPSHOT_INGEST_BATCH_SIZE = 8;
const LIVE_SNAPSHOT_RESUME_INTERVAL_MS = 5_000;
// If a DLQ message cannot be written to D1, its sanitized incident evidence is
// first kept in global Durable Object storage. This prefix is deliberately
// separate from live-ingest journaling so recovery can finalize the outbox
// before any ordinary Queue replay.
const DLQ_PERSISTENCE_FALLBACK_PREFIX = "dlq-persistence-fallback:";
const DLQ_PERSISTENCE_FALLBACK_REPLAY_BATCH_SIZE = 8;
// APNs and D1 cannot share a transaction. Before contacting APNs, the global
// relay durably records one exact single-recipient page intent. It removes it
// only after every observed provider outcome and accepted lifecycle evidence
// crosses D1. A crash in the provider/D1 gap therefore becomes an idempotent,
// collapse-ID-bounded retry instead of lost provenance. Rolling version-1
// post-2xx records share this prefix/capacity and remain replayable.
const APNS_ACCEPTANCE_JOURNAL_PREFIX = "apns-acceptance:v1:";
const APNS_ACCEPTANCE_JOURNAL_MAX_RECORDS = 128;
const APNS_ACCEPTANCE_JOURNAL_MAX_RECORD_BYTES = 64 * 1_024;
const APNS_ACCEPTANCE_JOURNAL_REPLAY_BATCH_SIZE = 1;
const APNS_ACCEPTANCE_JOURNAL_MAX_AGE_MS = DELIVERY_DEDUP_RETENTION_MS;
// Match the primary Queue's initial attempt plus five configured retries.
// Once this budget is reserved, recovery performs only D1 terminalization and
// can never turn a persistent provider failure into an unbounded alarm loop.
const APNS_DELIVERY_INTENT_MAX_PROVIDER_ATTEMPTS = 6;
// A production training request uses the same transaction-time registration
// fence as alert delivery, but it has no Queue-owned journal to recover. The
// provider request itself is bounded to twenty seconds; release only a crashed
// training fence after a full minute so no still-running request can overlap a
// later registration mutation.
const TRAINING_APNS_ATTEMPT_RECOVERY_MS = 60_000;
const OUTBOX_REPLAY_BATCH_SIZE = 8;
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
// A live WebSocket relay can receive frequent heartbeats for both JMA sources.
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
// A bare HTTP 101 only proves the HTTP Upgrade completed. Wait for a later
// valid Wolfx liveness frame after this stable interval before clearing an
// exponential reconnect history; otherwise a rapid open/close flap would
// spend three reset writes before each next failure.
const UPSTREAM_RECONNECT_STABLE_LIVENESS_MS = 60_000;
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
const LEGACY_APNS_TOPIC = "com.quakesignal.app";
const MAX_APP_IDENTITY_ROUTES = 16;
const MAX_APP_IDENTITY_ROUTE_CONFIGURATION_LENGTH = 8 * 1024;
// Keep this module-local: Workers accepts exported handlers/classes, but a
// primitive module export would prevent the deployed module from starting.
const APP_ATTEST_POLICY_FORMAT = "quakesignal-app-attest-policy/v2";
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
const DELIVERY_MAINTENANCE_DEFERRED_HEADER =
  "x-quakesignal-outbox-maintenance-deferred";
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
// An urgent warning intentionally expires before APNs' conservative 15-minute
// provider-error retry floor rather than arriving stale. APNs still receives
// expiration=0, so Apple is never asked to retain it for an offline device.
const TRAINING_DELIVERY_TTL_MS = 30 * 60_000;
const REPORT_DELIVERY_TTL_MS = 60 * 60_000;

interface ApnsDeliveryResult {
  ok: boolean;
  apnsId: string | null;
  /** Worker receipt time for APNs' response; present on accepted deliveries. */
  acceptedAtUtc?: string;
  status?: number;
  apnsReason?: string | null;
  invalidationTimestampMs?: number | null;
  retryAfterSeconds?: number | null;
  /** APNs has authoritatively invalidated this exact registration snapshot. */
  terminalUnregistration?: boolean;
  /** APNs rejected the device token and documents that it must not be retried. */
  terminalInvalidToken?: boolean;
  /** Never delete on a malformed 410 response without its safety timestamp. */
  unregistrationTimestampMissing?: boolean;
  /** Deletion completed, no row remains, or a newer registration won the race. */
  terminalResolved?: boolean;
  /** The exact registration snapshot sent to APNs was actually deleted. */
  deactivated?: boolean;
  /** A newer same-token row was preserved and atomically quarantined in D1. */
  badDeviceTokenQuarantined?: boolean;
}

interface ProductionTrainingRelayRequest {
  token: string;
  registrationRevision: string;
  appAttestKeyId: string;
  kind: "immediate" | "delayed";
  deadlineUtc: string;
  collapseId: string;
}

function isProductionTrainingRelayRequest(
  value: unknown,
): value is ProductionTrainingRelayRequest {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const candidate = value as Partial<ProductionTrainingRelayRequest>;
  return (
    Object.keys(value).length === 6 &&
    isValidDeviceToken(candidate.token) &&
    typeof candidate.registrationRevision === "string" &&
    candidate.registrationRevision.length > 0 &&
    candidate.registrationRevision.length <= 256 &&
    canonicalizeAppAttestKeyId(candidate.appAttestKeyId)?.keyId ===
      candidate.appAttestKeyId &&
    (candidate.kind === "immediate" || candidate.kind === "delayed") &&
    typeof candidate.deadlineUtc === "string" &&
    Number.isFinite(Date.parse(candidate.deadlineUtc)) &&
    typeof candidate.collapseId === "string" &&
    /^quake-[0-9a-f]{56}$/.test(candidate.collapseId)
  );
}

export type AppleAppPlatform =
  | "ios"
  | "ipados"
  | "macos"
  | "watchos"
  | "tvos"
  | "visionos";

/** A server allow-listed App Attest identity and its exact APNs route. */
export interface AuthenticatedAppRoute {
  appIdentity: string;
  apnsTopic: string;
  platform: AppleAppPlatform;
}

type RoutedDeviceRecord = DeviceRecord &
  AuthenticatedAppRoute & {
    appAttestKeyId: string | null;
    registrationRevision: string;
  };

interface PreparedDelivery {
  device: RoutedDeviceRecord;
  tokenHash: string;
}

interface AcceptedDelivery extends PreparedDelivery {
  acceptedAtUtc: string;
}

interface AcceptedDeliveryEvidence {
  token: string;
  tokenHash: string;
  snapshotRegistrationRevision: string;
  snapshotAppAttestKeyId: string | null;
  firstAcceptedAtUtc: string;
  lastAcceptedAtUtc: string;
}

interface ApnsIntentObservedBatch {
  /** Relay observation after every provider promise in this batch settled. */
  observedAtUtc: string;
  /** Exact routes and original lineage identities contacted in this attempt. */
  deliveries: MappedApnsIntentRecipient[];
  /** Results are positionally aligned with this attempt's deliveries. */
  results: ApnsDeliveryResult[];
}

interface PendingApnsAcceptanceRecord {
  version: 1;
  writeId: string;
  deliveryId: string;
  eventRef: string;
  sourceId: ApnsRelaySourceId;
  reason: NotifyReason;
  createdAtUtc: string;
  deliveries: AcceptedDeliveryEvidence[];
}

interface PendingApnsDeliveryIntentRecord {
  version: 2;
  writeId: string;
  createdAtUtc: string;
  /** Monotonic attempt sequence; recipient-specific counters enforce budget. */
  providerAttempts: number;
  /** Initial admitted send plus at most five contacts per original recipient. */
  recipientProviderAttempts: Record<string, number>;
  /** Latest reserved provider-contact observation for lifecycle retention. */
  lastProviderAttemptAtUtc: string;
  /** Earliest instant where recovery may reserve another provider contact. */
  nextProviderAttemptAtUtc: string;
  /** Per-contacted revision provider backoff; uncontacted peers remain due. */
  recipientRetryNotBeforeUtc: Record<string, string>;
  /** D1 classified the current no-observed-response attempt as unknown. */
  unobservedAttemptReconciled: boolean;
  /**
   * Equals lastProviderAttemptAtUtc only after D1 durably records conservative
   * lifecycle evidence for that reserved contact. Null forbids provider I/O.
   */
  lifecycleEvidencePreparedAtUtc: string | null;
  /**
   * Compact provider outcomes durably captured before any fallible D1
   * acceptance, cleanup, or incident write. Recovery reconciles these
   * outcomes without contacting APNs again.
   */
  observedBatch: ApnsIntentObservedBatch | null;
  message: AlertDeliveryMessage;
  deliveries: PreparedDelivery[];
}

interface MappedApnsIntentRecipient {
  delivery: PreparedDelivery;
  /** Stable position in the immutable original intent recipient array. */
  originDeliveryIndex: number;
  snapshotRegistrationRevision: string;
}

interface ApnsIntentRecipientResolution {
  /** Current registrations that retain source consent and lineage continuity. */
  sourceConsenting: MappedApnsIntentRecipient[];
  /** Subset still eligible and safe for a provider redispatch now. */
  redispatch: MappedApnsIntentRecipient[];
}

interface ApnsDeliveryIntentHandle {
  storageKey: string;
  writeId: string;
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
  | "eew_10m"
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
  /**
   * Exact normalized-event identity for a resident duplicate check. Older
   * journal records legitimately omit it; they fall back to canonical event
   * comparison during a rolling deploy.
   */
  fingerprint?: string;
}

type LiveSnapshotSource = "jma_eqlist";

/**
 * A complete WebSocket earthquake-list snapshot is journaled before the first
 * D1 slice. `retryAtMs` makes a D1 failure a bounded alarm retry rather than a
 * repeated WebSocket-frame write loop. The committed fingerprint is separate:
 * it is written atomically with deletion only after the final D1 slice.
 */
interface PendingLiveSnapshotWork {
  version: 1;
  source: LiveSnapshotSource;
  fingerprint: string;
  events: QueuedEvent[];
  nextIndex: number;
  createdAtMs: number;
  retryAtMs: number;
}

interface LiveSnapshotAdvanceResult {
  advanced: boolean;
  hasNextWork: boolean;
}

interface LiveSnapshotSlots {
  active: PendingLiveSnapshotWork | undefined;
  latest: PendingLiveSnapshotWork | undefined;
  overflow: PendingLiveSnapshotWork | undefined;
}

/**
 * A bounded ranked-list relay can preserve one active snapshot plus two newer
 * accepted replacements. The third distinct frame is persisted in the
 * overflow slot together with this marker before the list socket is closed.
 * Later frames are not admitted after explicit transport backpressure. This
 * prevents write-per-frame churn without silently losing the final frame that
 * crossed the relay boundary before backpressure took effect.
 */
interface LiveSnapshotOverload {
  version: 1;
  source: LiveSnapshotSource;
  reason: "invalid" | "overload";
  observedAtMs: number;
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
  /** APNs batches or consent-removal token handoffs awaiting safe replay. */
  pendingApnsAcceptanceBatches: number | null;
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
    input.pendingApnsAcceptanceBatches === null ||
    input.pendingApnsAcceptanceBatches > 0 ||
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
  return (
    value === "new" ||
    value === "updated" ||
    value === "final" ||
    value === "cancelled" ||
    value === "report" ||
    value === "training"
  );
}

function isAlertDeliveryExpiryPolicy(
  value: unknown,
): value is AlertDeliveryExpiryPolicy {
  return (
    value === "eew_10m" ||
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
    case "cancelled":
      return { policy: "report_60m", ttlMs: REPORT_DELIVERY_TTL_MS };
    case "training":
      return { policy: "training_30m", ttlMs: TRAINING_DELIVERY_TTL_MS };
    case "new":
    case "updated":
      return { policy: "eew_10m", ttlMs: URGENT_EEW_DELIVERY_TTL_MS };
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
 * prevents the two required JMA routes from retrying in lockstep without making
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
 * Bound setup-time upstream work so the two direct JMA watcher connections
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
  const calculated = calculateAlertDeliveryExpiry(
    message.event,
    message.reason,
    createdAtUtc,
  );
  if (
    typeof message.expiresAtUtc === "string" &&
    Number.isFinite(Date.parse(message.expiresAtUtc)) &&
    isAlertDeliveryExpiryPolicy(message.expiryPolicy)
  ) {
    // Queue copies created before build 7 may still carry the deployed 30-minute
    // label. Preserve an earlier deadline, but never let that legacy envelope
    // extend a real new/update warning past the reviewed ten-minute policy.
    if (
      message.expiryPolicy === "eew_30m" &&
      (message.reason === "new" || message.reason === "updated")
    ) {
      return {
        expiresAtUtc: new Date(Math.min(
          Date.parse(message.expiresAtUtc),
          Date.parse(calculated.expiresAtUtc),
        )).toISOString(),
        expiryPolicy: "eew_10m",
      };
    }
    return {
      expiresAtUtc: message.expiresAtUtc,
      expiryPolicy: message.expiryPolicy,
    };
  }
  return calculated;
}

export function isQueuedEvent(value: unknown): value is QueuedEvent {
  if (!value || typeof value !== "object") return false;
  const event = value as Partial<QueuedEvent>;
  return (
    typeof event.id === "string" &&
    event.id === `${event.sourceId}:${event.eventId}` &&
    isNonEmptyText(event.eventId) &&
    typeof event.sourceId === "string" &&
    isApnsRelaySource(event.sourceId) &&
    typeof event.serial === "number" &&
    Number.isSafeInteger(event.serial) &&
    event.serial >= 0 &&
    (event.sourceId === "jma_eew"
      ? event.kind === "eew"
      : event.kind === "report") &&
    isNonEmptyText(event.originTimeUtc) &&
    Number.isFinite(Date.parse(event.originTimeUtc)) &&
    isNonEmptyText(event.reportTimeUtc) &&
    Number.isFinite(Date.parse(event.reportTimeUtc)) &&
    isNonEmptyText(event.hypocenter) &&
    typeof event.latitude === "number" &&
    isNormalizableLatitude(event.latitude) &&
    typeof event.longitude === "number" &&
    isNormalizableLongitude(event.longitude) &&
    typeof event.magnitude === "number" &&
    Number.isFinite(event.magnitude) &&
    (event.depth === null ||
      (typeof event.depth === "number" && Number.isFinite(event.depth))) &&
    (event.maxIntensity === null || typeof event.maxIntensity === "string") &&
    typeof event.isWarn === "boolean" &&
    typeof event.isFinal === "boolean" &&
    typeof event.isCancel === "boolean" &&
    typeof event.isTraining === "boolean" &&
    (event.tsunami === null || typeof event.tsunami === "string")
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
    isApnsRelaySource(work.source) &&
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

/**
 * Keep the exact semantic event shape independent of source-payload property
 * order. `raw` never crosses the D1 or Queue boundary, so it must not affect
 * whether a replay is safe to suppress.
 */
function canonicalQueuedEvent(event: QueuedEvent): string {
  return JSON.stringify([
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
    event.isWarn,
    event.isFinal,
    event.isCancel,
    event.isTraining,
    event.tsunami,
  ]);
}

async function liveEventFingerprint(event: QueuedEvent): Promise<string> {
  return sha256Hex(canonicalQueuedEvent(event));
}

function isLiveEventFingerprint(value: unknown): value is string {
  return typeof value === "string" && /^[a-f0-9]{64}$/.test(value);
}

function isPendingIngestRecord(value: unknown): value is PendingIngestRecord {
  if (!value || typeof value !== "object") return false;
  const record = value as Partial<PendingIngestRecord>;
  return (
    typeof record.writeId === "string" &&
    record.writeId.length > 0 &&
    isQueuedEvent(record.event) &&
    (record.fingerprint === undefined || isLiveEventFingerprint(record.fingerprint))
  );
}

function isLiveSnapshotSource(source: WolfxSourceId): source is LiveSnapshotSource {
  return source === "jma_eqlist";
}

function isPendingLiveSnapshotWork(
  value: unknown,
): value is PendingLiveSnapshotWork {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const work = value as Partial<PendingLiveSnapshotWork>;
  return (
    work.version === 1 &&
    work.source === "jma_eqlist" &&
    typeof work.fingerprint === "string" &&
    work.fingerprint.length > 0 &&
    Array.isArray(work.events) &&
    work.events.length > 0 &&
    work.events.length <= MAX_HTTP_SNAPSHOT_EVENTS &&
    new Set(work.events.map((event) => event.id)).size === work.events.length &&
    work.events.every(
      (event) => isQueuedEvent(event) && event.sourceId === work.source,
    ) &&
    typeof work.nextIndex === "number" &&
    Number.isSafeInteger(work.nextIndex) &&
    work.nextIndex >= 0 &&
    work.nextIndex <= work.events.length &&
    typeof work.createdAtMs === "number" &&
    Number.isSafeInteger(work.createdAtMs) &&
    work.createdAtMs > 0 &&
    typeof work.retryAtMs === "number" &&
    Number.isSafeInteger(work.retryAtMs) &&
    work.retryAtMs > 0
  );
}

function liveSnapshotWorkStorageKey(
  source: LiveSnapshotSource,
): string {
  return `${PENDING_LIVE_SNAPSHOT_PREFIX}${source}`;
}

function liveSnapshotLatestStorageKey(source: LiveSnapshotSource): string {
  return `${PENDING_LIVE_SNAPSHOT_LATEST_PREFIX}${source}`;
}

function liveSnapshotOverflowStorageKey(source: LiveSnapshotSource): string {
  return `${PENDING_LIVE_SNAPSHOT_OVERFLOW_PREFIX}${source}`;
}

function liveSnapshotOverloadStorageKey(source: LiveSnapshotSource): string {
  return `${LIVE_SNAPSHOT_OVERLOAD_PREFIX}${source}`;
}

function isLiveSnapshotOverload(
  value: unknown,
): value is LiveSnapshotOverload {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const overload = value as Partial<LiveSnapshotOverload>;
  return (
    overload.version === 1 &&
    overload.source === "jma_eqlist" &&
    (overload.reason === "invalid" || overload.reason === "overload") &&
    typeof overload.observedAtMs === "number" &&
    Number.isSafeInteger(overload.observedAtMs) &&
    overload.observedAtMs > 0
  );
}

function liveSnapshotFingerprintStorageKey(source: LiveSnapshotSource): string {
  return `${UPSTREAM_LIVE_SNAPSHOT_FINGERPRINT_PREFIX}${source}`;
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

function isAcceptedDeliveryEvidence(
  value: unknown,
): value is AcceptedDeliveryEvidence {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const evidence = value as Partial<AcceptedDeliveryEvidence>;
  return (
    typeof evidence.token === "string" &&
    evidence.token.length > 0 &&
    evidence.token.length <= 512 &&
    typeof evidence.tokenHash === "string" &&
    /^[0-9a-f]{64}$/.test(evidence.tokenHash) &&
    typeof evidence.snapshotRegistrationRevision === "string" &&
    evidence.snapshotRegistrationRevision.length > 0 &&
    evidence.snapshotRegistrationRevision.length <= 256 &&
    (evidence.snapshotAppAttestKeyId === null ||
      (typeof evidence.snapshotAppAttestKeyId === "string" &&
        evidence.snapshotAppAttestKeyId.length > 0 &&
        evidence.snapshotAppAttestKeyId.length <= 1_024)) &&
    typeof evidence.firstAcceptedAtUtc === "string" &&
    Number.isFinite(Date.parse(evidence.firstAcceptedAtUtc)) &&
    typeof evidence.lastAcceptedAtUtc === "string" &&
    Number.isFinite(Date.parse(evidence.lastAcceptedAtUtc)) &&
    Date.parse(evidence.firstAcceptedAtUtc) <=
      Date.parse(evidence.lastAcceptedAtUtc)
  );
}

function isBoundedApnsJournalRecord(value: unknown): boolean {
  try {
    return new TextEncoder().encode(JSON.stringify(value)).byteLength <=
      APNS_ACCEPTANCE_JOURNAL_MAX_RECORD_BYTES;
  } catch {
    return false;
  }
}

function isPendingApnsAcceptanceRecord(
  value: unknown,
): value is PendingApnsAcceptanceRecord {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const record = value as Partial<PendingApnsAcceptanceRecord>;
  return (
    record.version === 1 &&
    typeof record.writeId === "string" &&
    record.writeId.length > 0 &&
    record.writeId.length <= 128 &&
    typeof record.deliveryId === "string" &&
    record.deliveryId.length > 0 &&
    record.deliveryId.length <= 512 &&
    typeof record.eventRef === "string" &&
    record.eventRef.length > 0 &&
    record.eventRef.length <= 512 &&
    isApnsRelaySource(record.sourceId) &&
    isNotifyReason(record.reason) &&
    typeof record.createdAtUtc === "string" &&
    Number.isFinite(Date.parse(record.createdAtUtc)) &&
    Array.isArray(record.deliveries) &&
    record.deliveries.length > 0 &&
    record.deliveries.length <= APNS_MAX_CONCURRENT_DELIVERIES &&
    record.deliveries.every(isAcceptedDeliveryEvidence) &&
    new Set(record.deliveries.map((delivery) =>
      `${delivery.tokenHash}\u0000${delivery.snapshotRegistrationRevision}`
    )).size ===
      record.deliveries.length &&
    isBoundedApnsJournalRecord(record)
  );
}

function isRoutedDeviceRecord(value: unknown): value is RoutedDeviceRecord {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const device = value as Partial<RoutedDeviceRecord>;
  return (
    typeof device.token === "string" &&
    isValidDeviceToken(device.token) &&
    (device.environment === "sandbox" || device.environment === "production") &&
    (device.locale === null ||
      (typeof device.locale === "string" && device.locale.length <= 128)) &&
    isValidSources(device.sources) &&
    typeof device.minMagnitude === "number" &&
    Number.isFinite(device.minMagnitude) &&
    typeof device.criticalAlertsEnabled === "boolean" &&
    isAlertSound(device.alertSound) &&
    (device.cityName === null ||
      (typeof device.cityName === "string" && device.cityName.length <= 512)) &&
    (device.latitude === null ||
      (typeof device.latitude === "number" &&
        isNormalizableLatitude(device.latitude))) &&
    (device.longitude === null ||
      (typeof device.longitude === "number" &&
        isNormalizableLongitude(device.longitude))) &&
    (device.radiusKm === null ||
      (typeof device.radiusKm === "number" &&
        Number.isFinite(device.radiusKm) &&
        device.radiusKm > 0)) &&
    typeof device.includeTestAlerts === "boolean" &&
    (device.utcOffsetMinutes === null ||
      (typeof device.utcOffsetMinutes === "number" &&
        Number.isSafeInteger(device.utcOffsetMinutes) &&
        device.utcOffsetMinutes >= -840 &&
        device.utcOffsetMinutes <= 840)) &&
    typeof device.notifyAtNight === "boolean" &&
    (device.appAttestKeyId === null ||
      (typeof device.appAttestKeyId === "string" &&
        device.appAttestKeyId.length > 0 &&
        device.appAttestKeyId.length <= 1_024)) &&
    typeof device.registrationRevision === "string" &&
    device.registrationRevision.length > 0 &&
    device.registrationRevision.length <= 256 &&
    typeof device.createdAt === "string" &&
    Number.isFinite(Date.parse(device.createdAt)) &&
    typeof device.updatedAt === "string" &&
    Number.isFinite(Date.parse(device.updatedAt)) &&
    isAuthenticatedAppRoute({
      appIdentity: device.appIdentity,
      apnsTopic: device.apnsTopic,
      platform: device.platform,
    })
  );
}

function isPreparedDelivery(value: unknown): value is PreparedDelivery {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const delivery = value as Partial<PreparedDelivery>;
  return (
    isRoutedDeviceRecord(delivery.device) &&
    typeof delivery.tokenHash === "string" &&
    /^[0-9a-f]{64}$/.test(delivery.tokenHash)
  );
}

function isMappedApnsIntentRecipient(
  value: unknown,
): value is MappedApnsIntentRecipient {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const recipient = value as Partial<MappedApnsIntentRecipient>;
  return (
    Object.keys(value).length === 3 &&
    isPreparedDelivery(recipient.delivery) &&
    Number.isSafeInteger(recipient.originDeliveryIndex) &&
    (recipient.originDeliveryIndex as number) >= 0 &&
    (recipient.originDeliveryIndex as number) < APNS_MAX_CONCURRENT_DELIVERIES &&
    typeof recipient.snapshotRegistrationRevision === "string" &&
    recipient.snapshotRegistrationRevision.length > 0 &&
    recipient.snapshotRegistrationRevision.length <= 256
  );
}

function isStoredApnsDeliveryResult(value: unknown): value is ApnsDeliveryResult {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const result = value as Partial<ApnsDeliveryResult>;
  const allowedKeys = new Set([
    "ok",
    "apnsId",
    "acceptedAtUtc",
    "status",
    "apnsReason",
    "invalidationTimestampMs",
    "retryAfterSeconds",
    "terminalUnregistration",
    "terminalInvalidToken",
    "unregistrationTimestampMissing",
    "terminalResolved",
    "deactivated",
    "badDeviceTokenQuarantined",
  ]);
  if (Object.keys(value).some((key) => !allowedKeys.has(key))) return false;
  if (
    typeof result.ok !== "boolean" ||
    !(
      result.apnsId === null ||
      (typeof result.apnsId === "string" && result.apnsId.length <= 256 &&
        !/[\u0000-\u001f\u007f]/.test(result.apnsId))
    )
  ) return false;
  if (
    result.acceptedAtUtc !== undefined &&
    (typeof result.acceptedAtUtc !== "string" ||
      !Number.isFinite(Date.parse(result.acceptedAtUtc)))
  ) return false;
  if (result.ok && result.acceptedAtUtc === undefined) return false;
  if (
    result.status !== undefined &&
    (!Number.isSafeInteger(result.status) || result.status < 100 ||
      result.status > 599)
  ) return false;
  if (
    result.apnsReason !== undefined && result.apnsReason !== null &&
    (typeof result.apnsReason !== "string" ||
      !/^[A-Za-z]+$/.test(result.apnsReason) || result.apnsReason.length > 64)
  ) return false;
  if (
    result.invalidationTimestampMs !== undefined &&
    result.invalidationTimestampMs !== null &&
    (!Number.isSafeInteger(result.invalidationTimestampMs) ||
      result.invalidationTimestampMs <= 0)
  ) return false;
  if (
    result.retryAfterSeconds !== undefined &&
    result.retryAfterSeconds !== null &&
    (!Number.isSafeInteger(result.retryAfterSeconds) ||
      result.retryAfterSeconds < 0 ||
      result.retryAfterSeconds > MAX_QUEUE_RETRY_DELAY_SECONDS)
  ) return false;
  for (const property of [
    "terminalUnregistration",
    "terminalInvalidToken",
    "unregistrationTimestampMissing",
    "terminalResolved",
    "deactivated",
    "badDeviceTokenQuarantined",
  ] as const) {
    if (result[property] !== undefined && typeof result[property] !== "boolean") {
      return false;
    }
  }
  return true;
}

function isApnsIntentObservedBatch(
  value: unknown,
  maximumDeliveryCount: number,
): value is ApnsIntentObservedBatch {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const batch = value as Partial<ApnsIntentObservedBatch>;
  return (
    Object.keys(value).length === 3 &&
    typeof batch.observedAtUtc === "string" &&
    Number.isFinite(Date.parse(batch.observedAtUtc)) &&
    Array.isArray(batch.deliveries) &&
    batch.deliveries.length > 0 &&
    batch.deliveries.length <= maximumDeliveryCount &&
    batch.deliveries.every(isMappedApnsIntentRecipient) &&
    batch.deliveries.every((delivery) =>
      delivery.originDeliveryIndex < maximumDeliveryCount
    ) &&
    new Set(batch.deliveries.map((delivery) =>
      delivery.originDeliveryIndex
    )).size === batch.deliveries.length &&
    new Set(batch.deliveries.map((delivery) =>
      `${delivery.delivery.tokenHash}\u0000${delivery.delivery.device.registrationRevision}`
    )).size === batch.deliveries.length &&
    Array.isArray(batch.results) &&
    batch.results.length === batch.deliveries.length &&
    batch.results.every(isStoredApnsDeliveryResult)
  );
}

function isPendingApnsDeliveryIntentRecord(
  value: unknown,
): value is PendingApnsDeliveryIntentRecord {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const record = value as Partial<PendingApnsDeliveryIntentRecord>;
  return (
    record.version === 2 &&
    typeof record.writeId === "string" &&
    record.writeId.length > 0 &&
    record.writeId.length <= 128 &&
    typeof record.createdAtUtc === "string" &&
    Number.isFinite(Date.parse(record.createdAtUtc)) &&
    typeof record.providerAttempts === "number" &&
    Number.isSafeInteger(record.providerAttempts) &&
    record.providerAttempts >= 0 &&
    record.providerAttempts <= Number.MAX_SAFE_INTEGER &&
    record.recipientProviderAttempts !== null &&
    typeof record.recipientProviderAttempts === "object" &&
    !Array.isArray(record.recipientProviderAttempts) &&
    Object.keys(record.recipientProviderAttempts).length <=
      APNS_MAX_CONCURRENT_DELIVERIES &&
    Object.entries(record.recipientProviderAttempts).every(
      ([revision, attempts]) =>
        revision.length > 0 && revision.length <= 256 &&
        Number.isSafeInteger(attempts) && attempts >= 0 &&
        attempts <= APNS_DELIVERY_INTENT_MAX_PROVIDER_ATTEMPTS,
    ) &&
    typeof record.lastProviderAttemptAtUtc === "string" &&
    Number.isFinite(Date.parse(record.lastProviderAttemptAtUtc)) &&
    typeof record.nextProviderAttemptAtUtc === "string" &&
    Number.isFinite(Date.parse(record.nextProviderAttemptAtUtc)) &&
    record.recipientRetryNotBeforeUtc !== null &&
    typeof record.recipientRetryNotBeforeUtc === "object" &&
    !Array.isArray(record.recipientRetryNotBeforeUtc) &&
    Object.keys(record.recipientRetryNotBeforeUtc).length <=
      APNS_DELIVERY_INTENT_MAX_PROVIDER_ATTEMPTS *
        APNS_MAX_CONCURRENT_DELIVERIES &&
    Object.entries(record.recipientRetryNotBeforeUtc).every(
      ([revision, retryAt]) =>
        revision.length > 0 && revision.length <= 256 &&
        typeof retryAt === "string" && Number.isFinite(Date.parse(retryAt)),
    ) &&
    typeof record.unobservedAttemptReconciled === "boolean" &&
    (record.lifecycleEvidencePreparedAtUtc === null ||
      (typeof record.lifecycleEvidencePreparedAtUtc === "string" &&
        Number.isFinite(Date.parse(record.lifecycleEvidencePreparedAtUtc)) &&
        record.lifecycleEvidencePreparedAtUtc ===
          record.lastProviderAttemptAtUtc)) &&
    isAlertDeliveryMessage(record.message) &&
    JSON.stringify(record.message) ===
      JSON.stringify(apnsJournalMessage(record.message)) &&
    Array.isArray(record.deliveries) &&
    record.deliveries.length > 0 &&
    record.deliveries.length <= APNS_MAX_CONCURRENT_DELIVERIES &&
    record.deliveries.every(isPreparedDelivery) &&
    (record.observedBatch === null ||
      isApnsIntentObservedBatch(record.observedBatch, record.deliveries.length)) &&
    new Set(record.deliveries.map((delivery) =>
      `${delivery.tokenHash}\u0000${delivery.device.registrationRevision}`
    )).size === record.deliveries.length &&
    // The original registration revision is the durable recipient identity
    // carried into every observed subset. Reject duplicate aliases instead of
    // letting an integrity check or retry budget depend on array first-match.
    new Set(record.deliveries.map((delivery) =>
      delivery.device.registrationRevision
    )).size === record.deliveries.length &&
    isBoundedApnsJournalRecord(record)
  );
}

async function apnsAcceptanceJournalStorageKey(
  deliveryId: string,
  eventRef: string,
  sourceId: ApnsRelaySourceId,
  reason: NotifyReason,
  deliveries: AcceptedDeliveryEvidence[],
): Promise<string> {
  const stableIdentity = JSON.stringify([
    deliveryId,
    eventRef,
    sourceId,
    reason,
    [...deliveries.map((delivery) => [
      delivery.tokenHash,
      delivery.snapshotRegistrationRevision,
    ])].sort(([leftHash, leftRevision], [rightHash, rightRevision]) =>
      leftHash.localeCompare(rightHash) || leftRevision.localeCompare(rightRevision)
    ),
  ]);
  return `${APNS_ACCEPTANCE_JOURNAL_PREFIX}${await sha256Hex(stableIdentity)}`;
}

async function apnsDeliveryIntentStorageKey(
  message: AlertDeliveryMessage,
  deliveries: PreparedDelivery[],
): Promise<string> {
  const stableIdentity = JSON.stringify([
    message,
    [...deliveries].sort((left, right) =>
      left.tokenHash.localeCompare(right.tokenHash) ||
      left.device.registrationRevision.localeCompare(
        right.device.registrationRevision,
      )
    ),
  ]);
  return `${APNS_ACCEPTANCE_JOURNAL_PREFIX}${await sha256Hex(stableIdentity)}`;
}

/**
 * Recognize only the two bounded fields needed to retire a Queue copy created
 * before the JMA-only policy. The body is otherwise untrusted and is never
 * allowed to reach payload construction or APNs.
 */
function disabledSourceOutboxId(value: unknown): string | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const candidate = value as { outboxId?: unknown; event?: unknown };
  if (
    typeof candidate.outboxId !== "string" ||
    candidate.outboxId.length === 0 ||
    candidate.outboxId.length > 128 ||
    !candidate.event ||
    typeof candidate.event !== "object" ||
    Array.isArray(candidate.event)
  ) {
    return null;
  }
  const sourceId = (candidate.event as { sourceId?: unknown }).sourceId;
  return isDisabledApnsRelaySource(sourceId) ? candidate.outboxId : null;
}

function disabledSourceFromEventReference(value: string): WolfxSourceId | null {
  const separator = value.indexOf(":");
  if (separator <= 0) return null;
  const sourceId = value.slice(0, separator);
  return isDisabledApnsRelaySource(sourceId) ? sourceId : null;
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
  if (!isApnsRelaySource(event.sourceId)) {
    throw new RangeError("APNs relay source is not permitted");
  }
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

function apnsJournalMessage(
  message: AlertDeliveryMessage,
): AlertDeliveryMessage {
  const event = message.event;
  // Queue validation is structural and intentionally tolerates rolling fields.
  // Persist a strict allow-list so a legacy `raw` member or unknown property can
  // never enter the temporary raw-token journal alongside the device snapshot.
  return {
    version: 1,
    outboxId: message.outboxId,
    deliveryId: message.deliveryId,
    rootDeliveryId: message.rootDeliveryId,
    event: {
      id: event.id,
      sourceId: event.sourceId,
      eventId: event.eventId,
      serial: event.serial,
      kind: event.kind,
      originTimeUtc: event.originTimeUtc,
      reportTimeUtc: event.reportTimeUtc,
      hypocenter: event.hypocenter,
      latitude: event.latitude,
      longitude: event.longitude,
      magnitude: event.magnitude,
      depth: event.depth,
      maxIntensity: event.maxIntensity,
      isWarn: event.isWarn,
      isFinal: event.isFinal,
      isCancel: event.isCancel,
      isTraining: event.isTraining,
      tsunami: event.tsunami,
    },
    reason: message.reason,
    ...(message.expiresAtUtc === undefined
      ? {}
      : { expiresAtUtc: message.expiresAtUtc }),
    ...(message.expiryPolicy === undefined
      ? {}
      : { expiryPolicy: message.expiryPolicy }),
    ...(message.afterDeviceCursor === undefined
      ? {}
      : { afterDeviceCursor: message.afterDeviceCursor }),
  };
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
  const canonicalQueueMessageId = evidence.outboxId === null
    ? evidence.queueMessageId
    : `outbox:${evidence.outboxId}`;
  return db
    .prepare(
      `INSERT INTO alert_delivery_incidents (
        queue_message_id, outbox_id, delivery_id, root_delivery_id, event_id, source_id,
        event_serial, notification_reason, queue_attempts, status,
        first_seen_utc, last_seen_utc
      ) SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, 'active', ?, ?
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
      canonicalQueueMessageId,
      evidence.outboxId,
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
  effectiveDate = "12 August 2026",
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
  <header><span class="mark">⌁</span><h1>${title}</h1><p>${summary}</p><p class="meta">QuakeSignal · Effective ${effectiveDate}</p></header>
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

function storedDeviceRelaySources(value: string): WolfxSourceId[] {
  try {
    const parsed: unknown = JSON.parse(value);
    return Array.isArray(parsed)
      ? [...new Set(parsed.filter(isApnsRelaySource))]
      : [];
  } catch {
    return [];
  }
}

function rowToDevice(row: DeviceRow): RoutedDeviceRecord {
  return {
    token: row.token,
    environment: row.environment,
    locale: row.locale,
    // Read old registrations fail-closed. A pre-build-8 row may still contain
    // other source IDs, but none can participate in matching or test alerts.
    sources: storedDeviceRelaySources(row.sources),
    minMagnitude: row.min_magnitude,
    // Critical Alerts are not approved for this public bundle. Keep legacy
    // storage readable, but never let a saved or forged preference enable it.
    criticalAlertsEnabled: false,
    alertSound: normalizedAlertSound(row.alert_sound),
    cityName: row.city_name,
    latitude: row.latitude,
    longitude: row.longitude,
    radiusKm: row.radius_km,
    includeTestAlerts: !!row.include_test_alerts,
    utcOffsetMinutes: row.utc_offset_minutes,
    notifyAtNight: !!row.notify_at_night,
    appAttestKeyId: row.app_attest_key_id ?? null,
    // Migration 0013 guarantees a non-empty unique value in D1. The fallback
    // exists only for focused pre-migration fixtures; production deployment
    // applies migrations before this Worker revision begins fanout.
    registrationRevision:
      typeof row.registration_revision === "string" &&
      row.registration_revision.length > 0
        ? row.registration_revision
        : `legacy-fixture:${row.updated_at}`,
    // Migration 0011 makes all three fields non-null. These fallbacks keep a
    // rolling Worker and focused pre-migration test fixtures on the historical
    // iOS route; send-time allow-list validation still runs before APNs.
    appIdentity: row.app_identity ?? APP_ATTEST_APP_ID,
    apnsTopic: row.apns_topic ?? LEGACY_APNS_TOPIC,
    platform: (row.app_platform ?? "ios") as AppleAppPlatform,
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
    case "jma_eqlist":
      return extractEqlistEntries<JmaEqlistEntry>(
        message as WolfxEqlistMessage,
      ).map(({ entry }) => normalizeJmaEqlistEntry(entry));
    default:
      // The shared client domain still knows about other Wolfx source IDs,
      // but the build-8 APNs relay must fail closed for every non-JMA feed.
      return [];
  }
}

function isFiniteNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value);
}

function isNonEmptyText(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

const MAX_WOLFX_CONTROL_VERSION = 99_999_999;
const MAX_WOLFX_DECIMAL_CONNECTION_ID_DIGITS = 20;
const MIN_13_DIGIT_EPOCH_MS = 1_000_000_000_000;
const MAX_13_DIGIT_EPOCH_MS = 9_999_999_999_999;
const MIN_EARTHQUAKE_MAGNITUDE = -2;
const MAX_EARTHQUAKE_MAGNITUDE = 12;
const MAX_EARTHQUAKE_DEPTH_KM = 1_000;
const JMA_INTENSITIES = [
  "0", "1", "2", "3", "4", "5-", "5+", "6-", "6+", "7",
] as const;
const NORMALIZED_EVENT_VALIDATION_FIELDS: readonly (keyof NormalizedEvent)[] = [
  "id",
  "sourceId",
  "eventId",
  "serial",
  "kind",
  "originTimeUtc",
  "reportTimeUtc",
  "hypocenter",
  "latitude",
  "longitude",
  "magnitude",
  "depth",
  "maxIntensity",
  "isWarn",
  "isFinal",
  "isCancel",
  "isTraining",
  "tsunami",
  "raw",
];

interface JmaCalendarParts {
  year: number;
  month: number;
  day: number;
  hour: number;
  minute: number;
  second: number;
}

function isPlainRecord(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === "object" && !Array.isArray(value);
}

function isLeapYear(year: number): boolean {
  return year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
}

function isValidJmaCalendarParts(parts: JmaCalendarParts): boolean {
  const daysInMonth = [
    31,
    isLeapYear(parts.year) ? 29 : 28,
    31,
    30,
    31,
    30,
    31,
    31,
    30,
    31,
    30,
    31,
  ];
  return (
    parts.year >= 1_000 &&
    parts.year <= 9_999 &&
    parts.month >= 1 &&
    parts.month <= 12 &&
    parts.day >= 1 &&
    parts.day <= (daysInMonth[parts.month - 1] ?? 0) &&
    parts.hour >= 0 &&
    parts.hour <= 23 &&
    parts.minute >= 0 &&
    parts.minute <= 59 &&
    parts.second >= 0 &&
    parts.second <= 59
  );
}

function parseJmaDateTime(
  value: unknown,
  includeSeconds: boolean,
): JmaCalendarParts | null {
  if (typeof value !== "string") return null;
  const match = (includeSeconds
    ? /^([1-9]\d{3})\/(\d{2})\/(\d{2}) (\d{2}):(\d{2}):(\d{2})$/
    : /^([1-9]\d{3})\/(\d{2})\/(\d{2}) (\d{2}):(\d{2})$/
  ).exec(value);
  if (!match) return null;
  const parts: JmaCalendarParts = {
    year: Number(match[1]),
    month: Number(match[2]),
    day: Number(match[3]),
    hour: Number(match[4]),
    minute: Number(match[5]),
    second: includeSeconds ? Number(match[6]) : 0,
  };
  return isValidJmaCalendarParts(parts) ? parts : null;
}

function parseJmaEventId(value: unknown): JmaCalendarParts | null {
  if (typeof value !== "string") return null;
  const match = /^([1-9]\d{3})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})$/.exec(value);
  if (!match) return null;
  const parts: JmaCalendarParts = {
    year: Number(match[1]),
    month: Number(match[2]),
    day: Number(match[3]),
    hour: Number(match[4]),
    minute: Number(match[5]),
    second: Number(match[6]),
  };
  return isValidJmaCalendarParts(parts) ? parts : null;
}

function jmaCalendarMinuteMatches(
  left: JmaCalendarParts,
  right: JmaCalendarParts,
): boolean {
  return (
    left.year === right.year &&
    left.month === right.month &&
    left.day === right.day &&
    left.hour === right.hour &&
    left.minute === right.minute
  );
}

function jmaCalendarMilliseconds(parts: JmaCalendarParts): number {
  return Date.UTC(
    parts.year,
    parts.month - 1,
    parts.day,
    parts.hour,
    parts.minute,
    parts.second,
  );
}

function canonicalDecimal(value: unknown): number | null {
  if (
    typeof value !== "string" ||
    value.length > 24 ||
    !/^-?(?:0|[1-9]\d*)(?:\.\d+)?$/.test(value)
  ) {
    return null;
  }
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function isBoundedMagnitude(value: unknown): value is number {
  return (
    isFiniteNumber(value) &&
    value >= MIN_EARTHQUAKE_MAGNITUDE &&
    value <= MAX_EARTHQUAKE_MAGNITUDE
  );
}

function isJmaIntensity(value: unknown): value is string {
  return typeof value === "string" &&
    (JMA_INTENSITIES as readonly string[]).includes(value);
}

function canonicalEqlistDepth(value: unknown): number | null {
  if (typeof value !== "string") return null;
  const match = /^(0|[1-9]\d*)km$/.exec(value);
  if (!match) return null;
  const parsed = Number(match[1]);
  return parsed <= MAX_EARTHQUAKE_DEPTH_KM ? parsed : null;
}

function normalizedEventExactlyMatches(
  actual: NormalizedEvent,
  expected: NormalizedEvent,
): boolean {
  return NORMALIZED_EVENT_VALIDATION_FIELDS.every((field) =>
    Object.is(actual[field], expected[field])
  );
}

function isCanonicalWolfxUuid(value: unknown): value is string {
  return typeof value === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(value);
}

function isCanonicalWolfxControlVersion(value: unknown): value is number {
  return (
    typeof value === "number" &&
    Number.isSafeInteger(value) &&
    value > 0 &&
    value <= MAX_WOLFX_CONTROL_VERSION
  );
}

function isCanonicalWolfxConnectionId(value: unknown): value is string {
  if (isCanonicalWolfxUuid(value)) return true;
  return (
    typeof value === "string" &&
    value.length <= MAX_WOLFX_DECIMAL_CONNECTION_ID_DIGITS &&
    /^[1-9]\d*$/.test(value)
  );
}

function isCanonicalWolfxTimestamp(value: unknown): value is string | number {
  if (typeof value === "string") {
    if (!/^[1-9]\d{12}$/.test(value)) return false;
    const milliseconds = Number(value);
    return Number.isSafeInteger(milliseconds) && String(milliseconds) === value;
  }
  return (
    typeof value === "number" &&
    Number.isSafeInteger(value) &&
    value >= MIN_13_DIGIT_EPOCH_MS &&
    value <= MAX_13_DIGIT_EPOCH_MS
  );
}

function isStructurallyValidWolfxControlFrame(message: unknown): boolean {
  if (!isPlainRecord(message)) return false;
  const value = message as Record<string, unknown>;
  if (isHeartbeat(message)) {
    return (
      isCanonicalWolfxControlVersion(value.ver) &&
      isCanonicalWolfxConnectionId(value.id) &&
      isCanonicalWolfxTimestamp(value.timestamp)
    );
  }
  return isPong(message) && isCanonicalWolfxTimestamp(value.timestamp);
}

function normalizableCoordinate(value: unknown): number | null {
  const number = typeof value === "string" ? Number(value) : value;
  return typeof number === "number" && Number.isFinite(number) ? number : null;
}

function isNormalizableLatitude(value: unknown): boolean {
  const number = normalizableCoordinate(value);
  return number !== null && number >= -90 && number <= 90;
}

function isNormalizableLongitude(value: unknown): boolean {
  const number = normalizableCoordinate(value);
  return number !== null && number >= -180 && number <= 180;
}

function hasValidNormalizedEventTimes(
  events: readonly NormalizedEvent[],
): boolean {
  return events.every((event) =>
    typeof event.originTimeUtc === "string" &&
    Number.isFinite(Date.parse(event.originTimeUtc)) &&
    typeof event.reportTimeUtc === "string" &&
    Number.isFinite(Date.parse(event.reportTimeUtc)) &&
    isNormalizableLatitude(event.latitude) &&
    isNormalizableLongitude(event.longitude) &&
    Number.isFinite(event.magnitude) &&
    typeof event.hypocenter === "string" &&
    event.hypocenter.trim().length > 0
  );
}

function isStructurallyValidEqlistEntry(
  entry: unknown,
): boolean {
  if (!isPlainRecord(entry)) return false;
  const value = entry as Record<string, unknown>;
  const eventId = parseJmaEventId(value.EventID);
  const time = parseJmaDateTime(value.time, false);
  const timeFull = parseJmaDateTime(value.time_full, true);
  const magnitude = canonicalDecimal(value.magnitude);
  const latitude = canonicalDecimal(value.latitude);
  const longitude = canonicalDecimal(value.longitude);
  const depth = canonicalEqlistDepth(value.depth);
  return (
    eventId !== null &&
    time !== null &&
    timeFull !== null &&
    jmaCalendarMinuteMatches(time, timeFull) &&
    isNonEmptyText(value.Title) &&
    isNonEmptyText(value.location) &&
    magnitude !== null &&
    magnitude >= MIN_EARTHQUAKE_MAGNITUDE &&
    magnitude <= MAX_EARTHQUAKE_MAGNITUDE &&
    isJmaIntensity(value.shindo) &&
    depth !== null &&
    latitude !== null &&
    latitude >= -90 &&
    latitude <= 90 &&
    longitude !== null &&
    longitude >= -180 &&
    longitude <= 180 &&
    typeof value.info === "string"
  );
}

function isStructurallyValidEqlistSnapshot(
  message: Record<string, unknown>,
  normalizedEvents: readonly NormalizedEvent[],
): boolean {
  if (
    typeof message.md5 !== "string" ||
    !/^[0-9a-f]{32}$/.test(message.md5) ||
    (Object.hasOwn(message, "type") && message.type !== "jma_eqlist") ||
    normalizedEvents.length === 0
  ) return false;
  const entries = extractEqlistEntries(message as WolfxEqlistMessage);
  const rankedKeys = Object.keys(message).filter((key) => key.startsWith("No"));
  if (
    entries.length !== normalizedEvents.length ||
    entries.length > MAX_HTTP_SNAPSHOT_EVENTS ||
    rankedKeys.length !== entries.length ||
    rankedKeys.some((key) => !/^No(?:[1-9]|[1-4]\d|50)$/.test(key)) ||
    entries.some(({ rank, entry }, index) =>
      !Number.isSafeInteger(rank) ||
      rank !== index + 1 ||
      !isStructurallyValidEqlistEntry(entry)
    )
  ) {
    return false;
  }
  const expectedEvents = entries.map(({ entry }) =>
    normalizeJmaEqlistEntry(entry as JmaEqlistEntry)
  );
  return (
    hasValidNormalizedEventTimes(normalizedEvents) &&
    expectedEvents.every((expected, index) =>
      normalizedEventExactlyMatches(normalizedEvents[index], expected)
    )
  );
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
  if (!isApnsRelaySource(sourceId)) return false;
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

  if (sourceId === "jma_eew") {
    if (normalizedEvents.length !== 1 || !hasValidNormalizedEventTimes(normalizedEvents)) {
      return false;
    }
    const value = message as Record<string, unknown>;
    const eventId = parseJmaEventId(value.EventID);
    const originTime = parseJmaDateTime(value.OriginTime, true);
    const announcedTime = parseJmaDateTime(value.AnnouncedTime, true);
    const issue = isPlainRecord(value.Issue) ? value.Issue : null;
    const accuracy = isPlainRecord(value.Accuracy) ? value.Accuracy : null;
    const maxIntChange = isPlainRecord(value.MaxIntChange) ? value.MaxIntChange : null;
    const warnArea = Array.isArray(value.WarnArea) ? value.WarnArea : null;
    const base =
      (Object.hasOwn(value, "type") ? value.type === "jma_eew" : true) &&
      isNonEmptyText(value.Title) &&
      isNonEmptyText(value.CodeType) &&
      issue !== null &&
      isNonEmptyText(issue.Source) &&
      isNonEmptyText(issue.Status) &&
      eventId !== null &&
      originTime !== null &&
      announcedTime !== null &&
      jmaCalendarMilliseconds(announcedTime) >= jmaCalendarMilliseconds(originTime) &&
      isFiniteNumber(value.Latitude) &&
      isNormalizableLatitude(value.Latitude) &&
      isFiniteNumber(value.Longitude) &&
      isNormalizableLongitude(value.Longitude) &&
      accuracy !== null &&
      typeof accuracy.Epicenter === "string" &&
      typeof accuracy.Depth === "string" &&
      typeof accuracy.Magnitude === "string" &&
      maxIntChange !== null &&
      typeof maxIntChange.String === "string" &&
      typeof maxIntChange.Reason === "string" &&
      warnArea !== null &&
      warnArea.every((area) =>
        isPlainRecord(area) &&
        typeof area.Chiiki === "string" &&
        typeof area.Shindo1 === "string" &&
        typeof area.Shindo2 === "string" &&
        typeof area.Time === "string" &&
        typeof area.Type === "string" &&
        typeof area.Arrive === "boolean"
      ) &&
      typeof value.isSea === "boolean" &&
      typeof value.isAssumption === "boolean" &&
      typeof value.OriginalText === "string";
    if (!base) return false;
    if (
      Number.isSafeInteger(value.Serial) &&
      (value.Serial as number) > 0 &&
      isNonEmptyText(value.Hypocenter) &&
      isBoundedMagnitude(value.Magunitude) &&
      isFiniteNumber(value.Depth) &&
      value.Depth >= 0 &&
      value.Depth <= MAX_EARTHQUAKE_DEPTH_KM &&
      isJmaIntensity(value.MaxIntensity) &&
      typeof value.isWarn === "boolean" &&
      typeof value.isFinal === "boolean" &&
      typeof value.isCancel === "boolean" &&
      typeof value.isTraining === "boolean"
    ) {
      const expected = normalizeJmaEew(message as JmaEewMessage);
      return normalizedEventExactlyMatches(normalizedEvents[0], expected);
    }
    return false;
  }

  if (sourceId !== "jma_eqlist") return false;
  return isStructurallyValidEqlistSnapshot(
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

/**
 * Wolfx list frames may change non-event envelope fields or rank ordering
 * without changing the report revisions we persist. Fingerprint the bounded,
 * normalized snapshot in a stable ID order so those harmless replays do not
 * recreate Durable Object work after the prior list has committed.
 */
async function liveSnapshotFingerprint(
  events: readonly NormalizedEvent[],
): Promise<string> {
  const canonical = events
    .map(snapshotEvent)
    .sort((left, right) => left.id.localeCompare(right.id));
  return sha256Hex(JSON.stringify(canonical));
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
        is_warn = CASE
          WHEN excluded.serial = events.serial
            THEN MAX(events.is_warn, excluded.is_warn)
          ELSE excluded.is_warn
        END,
        is_final = MAX(events.is_final, excluded.is_final),
        is_cancel = MAX(events.is_cancel, excluded.is_cancel),
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
        WHERE id = ? AND (
          serial > ?
          OR (
            serial = ? AND (
              (is_cancel = 1 AND ? != 'cancelled')
              OR (is_final = 1 AND ? IN ('new', 'updated'))
            )
          )
        )
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
      // rather than resurrecting stale emergency work. The status predicates
      // also close the same-serial final/cancel race while permitting the
      // matching terminal lifecycle notification itself.
      message.event.id,
      message.event.serial,
      message.event.serial,
      message.reason,
      message.reason,
    );
}

/**
 * Terminalize one queued page when D1 already contains a newer committed
 * revision or a same-serial terminal lifecycle that supersedes its reason.
 * This correlated delivery-time fence prevents a delayed Queue copy from
 * presenting active warning work after final/cancel is durable.
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
             AND (
               events.serial > alert_delivery_outbox.event_serial
               OR (
                 events.serial = alert_delivery_outbox.event_serial AND (
                   (events.is_cancel = 1
                     AND alert_delivery_outbox.notification_reason != 'cancelled')
                   OR (events.is_final = 1
                     AND alert_delivery_outbox.notification_reason IN ('new', 'updated'))
                 )
               )
             )
         )`,
    )
    .bind(now, outboxId);
}

/**
 * Once a newer event revision or same-serial terminal lifecycle commits,
 * retire every incompatible pending page in the same D1 batch. The
 * delivery-time fence above protects Queue copies that were already handed
 * off before this transaction committed.
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
             AND (
               events.serial > alert_delivery_outbox.event_serial
               OR (
                 events.serial = alert_delivery_outbox.event_serial AND (
                   (events.is_cancel = 1
                     AND alert_delivery_outbox.notification_reason != 'cancelled')
                   OR (events.is_final = 1
                     AND alert_delivery_outbox.notification_reason IN ('new', 'updated'))
                 )
               )
             )
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
  createMessage: (
    acceptedEvent: NormalizedEvent,
    previous: NormalizedEvent | null,
  ) => AlertDeliveryMessage | null,
): Promise<{
  previous: NormalizedEvent | null;
  message: AlertDeliveryMessage | null;
}> {
  if (!isApnsRelaySource(event.sourceId)) {
    throw new RangeError("APNs relay source is not permitted");
  }
  const previous = await getEvent(db, event.id);
  const acceptedEvent = reconcileEventRevision(event, previous);
  if (acceptedEvent === null) return { previous, message: null };
  const message = createMessage(acceptedEvent, previous);
  const now = new Date().toISOString();
  const statements = [
    eventUpsertStatement(db, acceptedEvent, now),
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
 * Persist a small, already-validated earthquake-list snapshot slice with two
 * D1 binding calls: one read of the prior revisions and one atomic write batch.
 * Both HTTP recovery and live list WebSockets use it because a ranked list can
 * contain fifty reports; issuing a get+batch per entry would exceed the
 * Workers Free D1 invocation budget.
 */
async function persistHttpSnapshotEvents(
  db: D1Database,
  snapshots: readonly QueuedEvent[],
  mode: "initial" | "recovery" | "live",
): Promise<void> {
  if (snapshots.length === 0) return;
  if (snapshots.some((event) => !isApnsRelaySource(event.sourceId))) {
    throw new RangeError("APNs relay source is not permitted");
  }
  if (snapshots.length > HTTP_SNAPSHOT_INGEST_BATCH_SIZE) {
    throw new RangeError("snapshot persistence slice exceeds its D1-safe bound");
  }
  const ids = snapshots.map((event) => event.id);
  if (new Set(ids).size !== ids.length) {
    throw new TypeError("snapshot persistence slice contains duplicate event IDs");
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
    const acceptedEvent = reconcileEventRevision(event, previous);
    if (acceptedEvent === null) continue;
    const reason = notificationReasonForEvent(acceptedEvent, previous);
    const message =
      reason === null ||
        mode === "initial" ||
        (mode === "recovery" && !isRecentHttpRecoveryEvent(acceptedEvent))
        ? null
        : createAlertDeliveryMessage(acceptedEvent, reason);
    statements.push(
      eventUpsertStatement(db, acceptedEvent, now),
      supersedeOlderOutboxRowsForEventStatement(db, acceptedEvent.id, now),
    );
    if (message) {
      statements.push(outboxInsertStatement(db, message, message.deliveryId, now));
    }
  }
  if (statements.length > 0) await db.batch(statements);
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
    value.length > 0 &&
    value.length <= APNS_RELAY_SOURCES.length &&
    new Set(value).size === value.length &&
    value.every(isApnsRelaySource)
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
  if (!isApnsRelaySource(event.sourceId)) return false;
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
    device.radiusKm == null ||
    device.latitude == null ||
    device.longitude == null ||
    event.latitude == null ||
    event.longitude == null
  ) {
    return false;
  }
  return (
    haversineDistanceKm(
      device.latitude,
      device.longitude,
      event.latitude,
      event.longitude,
    ) <= device.radiusKm
  );
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

export class AppIdentityRouteConfigurationError extends Error {
  constructor() {
    super("App identity routing configuration is invalid");
    this.name = "AppIdentityRouteConfigurationError";
  }
}

export class AppIdentityRouteNotAllowedError extends Error {
  constructor() {
    super("App identity route is not allow-listed");
    this.name = "AppIdentityRouteNotAllowedError";
  }
}

const APPLE_APP_PLATFORMS = new Set<AppleAppPlatform>([
  "ios",
  "ipados",
  "macos",
  "watchos",
  "tvos",
  "visionos",
]);

function isAppleBundleIdentifier(value: string): boolean {
  return (
    value.length > 0 &&
    value.length <= 255 &&
    /^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*$/.test(value)
  );
}

function isAuthenticatedAppRoute(value: unknown): value is AuthenticatedAppRoute {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const candidate = value as Partial<AuthenticatedAppRoute>;
  const names = Object.keys(value);
  if (
    names.length !== 3 ||
    !names.every((name) => ["appIdentity", "apnsTopic", "platform"].includes(name)) ||
    typeof candidate.appIdentity !== "string" ||
    typeof candidate.apnsTopic !== "string" ||
    typeof candidate.platform !== "string" ||
    !APPLE_APP_PLATFORMS.has(candidate.platform as AppleAppPlatform) ||
    !isAppleBundleIdentifier(candidate.apnsTopic)
  ) {
    return false;
  }
  const separator = candidate.appIdentity.indexOf(".");
  if (separator <= 0 || separator === candidate.appIdentity.length - 1) return false;
  const teamId = candidate.appIdentity.slice(0, separator);
  const bundleId = candidate.appIdentity.slice(separator + 1);
  // This service sends only ordinary alert pushes. Requiring the authenticated
  // bundle ID to equal its topic prevents an allow-list typo from turning one
  // app's proof into authority over another app or extension's APNs channel.
  return /^[A-Z0-9]{10}$/.test(teamId) &&
    isAppleBundleIdentifier(bundleId) && bundleId === candidate.apnsTopic;
}

/**
 * Resolve the complete server-owned identity allow-list. When the new setting
 * is absent, synthesize exactly the historical iOS route so deployed clients
 * and already-migrated rows keep working without a flag day. Once the setting
 * is present it is authoritative and malformed/partial values fail closed.
 */
export function configuredAppIdentityRoutes(
  env: AppIdentityRoutingEnvironment,
): AuthenticatedAppRoute[] {
  const primaryAppIdentity = env.APP_ATTEST_APP_ID ?? APP_ATTEST_APP_ID;
  const configured = env.APP_ATTEST_APNS_ROUTES;
  if (configured === undefined) {
    const legacy: AuthenticatedAppRoute = {
      appIdentity: primaryAppIdentity,
      apnsTopic: env.APNS_BUNDLE_ID ?? LEGACY_APNS_TOPIC,
      platform: "ios",
    };
    if (!isAuthenticatedAppRoute(legacy)) {
      throw new AppIdentityRouteConfigurationError();
    }
    return [legacy];
  }
  if (
    configured.length === 0 ||
    configured.length > MAX_APP_IDENTITY_ROUTE_CONFIGURATION_LENGTH
  ) {
    throw new AppIdentityRouteConfigurationError();
  }
  let decoded: unknown;
  try {
    decoded = JSON.parse(configured);
  } catch {
    throw new AppIdentityRouteConfigurationError();
  }
  if (
    !Array.isArray(decoded) ||
    decoded.length === 0 ||
    decoded.length > MAX_APP_IDENTITY_ROUTES ||
    !decoded.every(isAuthenticatedAppRoute)
  ) {
    throw new AppIdentityRouteConfigurationError();
  }
  const routes = decoded.map((route) => ({ ...route }));
  if (new Set(routes.map(({ appIdentity }) => appIdentity)).size !== routes.length) {
    throw new AppIdentityRouteConfigurationError();
  }
  // Existing clients do not send `appIdentity`. Keeping the configured
  // primary identity mandatory preserves that wire contract while still
  // making every additional platform opt-in.
  if (!routes.some(({ appIdentity }) => appIdentity === primaryAppIdentity)) {
    throw new AppIdentityRouteConfigurationError();
  }
  return routes.sort((left, right) =>
    left.appIdentity < right.appIdentity
      ? -1
      : left.appIdentity > right.appIdentity
        ? 1
        : 0
  );
}

function defaultAppIdentityRoute(
  env: AppIdentityRoutingEnvironment,
): AuthenticatedAppRoute {
  const primaryAppIdentity = env.APP_ATTEST_APP_ID ?? APP_ATTEST_APP_ID;
  const route = configuredAppIdentityRoutes(env).find(
    ({ appIdentity }) => appIdentity === primaryAppIdentity,
  );
  if (!route) throw new AppIdentityRouteConfigurationError();
  return route;
}

/**
 * Select an allow-listed route for a mutation. A fresh key may name an app
 * identity because the exact body is challenge-bound and the subsequent App
 * Attest proof verifies that same app ID. An existing key is always anchored
 * to its stored app ID and cannot switch identities through request JSON.
 */
export function authenticatedAppRouteForRequest(
  env: AppIdentityRoutingEnvironment,
  body: Record<string, unknown>,
  storedAppIdentity?: string,
): AuthenticatedAppRoute {
  const requested = body.appIdentity;
  if (requested !== undefined && typeof requested !== "string") {
    throw new AppIdentityRouteNotAllowedError();
  }
  if (
    storedAppIdentity !== undefined &&
    requested !== undefined &&
    requested !== storedAppIdentity
  ) {
    throw new AppIdentityRouteNotAllowedError();
  }
  const identity = storedAppIdentity ??
    (requested as string | undefined) ??
    (env.APP_ATTEST_APP_ID ?? APP_ATTEST_APP_ID);
  const route = configuredAppIdentityRoutes(env).find(
    ({ appIdentity }) => appIdentity === identity,
  );
  if (!route) throw new AppIdentityRouteNotAllowedError();
  return route;
}

function allowedStoredAppIdentityRoute(
  env: AppIdentityRoutingEnvironment,
  device: Pick<RoutedDeviceRecord, "appIdentity" | "apnsTopic" | "platform">,
): AuthenticatedAppRoute {
  const route = configuredAppIdentityRoutes(env).find(
    ({ appIdentity }) => appIdentity === device.appIdentity,
  );
  if (
    !route ||
    route.apnsTopic !== device.apnsTopic ||
    route.platform !== device.platform
  ) {
    throw new AppIdentityRouteNotAllowedError();
  }
  return route;
}

function hasApnsConfiguration(env: Env): boolean {
  if (!(env.APNS_PRIVATE_KEY && env.APNS_KEY_ID && env.APNS_TEAM_ID)) return false;
  // Keep APNS_BUNDLE_ID mandatory for the legacy single-route mode. Explicit
  // per-identity routes carry their own topics and need only provider-key
  // credentials shared by the Apple developer team.
  if (env.APP_ATTEST_APNS_ROUTES === undefined && !env.APNS_BUNDLE_ID) return false;
  try {
    return configuredAppIdentityRoutes(env).length > 0;
  } catch {
    return false;
  }
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

interface DeviceDeletionResult {
  outcome: DeviceDeletionOutcome;
  currentUpdatedAt: string | null;
}

/**
 * Delete the device and its delivery-deduplication records in one D1
 * transaction. APNs 410 cleanup first validates Apple's invalidation timestamp
 * against the snapshot sent to APNs, then deletes only that snapshot's opaque
 * revision. Authenticated user removal owns the current row unconditionally.
 * The BadDeviceToken path has its separate revision-decision transaction below.
 */
async function deleteDeviceRegistration(
  db: D1Database,
  token: string,
  expectedRegistrationRevision?: string | null,
  preserveAlertLifecycle = false,
): Promise<DeviceDeletionResult> {
  const deviceCondition = expectedRegistrationRevision
    ? "token = ? AND registration_revision = ?"
    : "token = ?";
  const deviceBindings = expectedRegistrationRevision
    ? [token, expectedRegistrationRevision]
    : [token];
  const hashedToken = await tokenHash(token);
  const now = new Date().toISOString();
  const deletionDecisionId = crypto.randomUUID();
  const deletionKind = expectedRegistrationRevision
    ? "apns_unregistration"
    : "explicit_removal";
  const lifecycleCleanup = preserveAlertLifecycle
    ? []
    : [
        db
          .prepare(
            `DELETE FROM alert_lifecycle_recipients
             WHERE (
               token_hash = ? AND EXISTS (
                 SELECT 1 FROM devices WHERE ${deviceCondition}
               )
             ) OR app_attest_key_id IN (
               SELECT app_attest_key_id FROM devices
               WHERE ${deviceCondition} AND app_attest_key_id IS NOT NULL
             )`,
          )
          .bind(
            hashedToken,
            ...deviceBindings,
            ...deviceBindings,
          ),
      ];
  const fenceStatements = [
    db
      .prepare(
        `INSERT INTO apns_registration_revision_fences (
           token_hash, registration_revision, app_attest_key_id,
           decision_id, decision_kind,
           blocks_lifecycle_replay, processed_at_utc
         )
         SELECT ?, registration_revision, app_attest_key_id, ?, ?, 1, ?
         FROM devices
         WHERE ${deviceCondition}
         ON CONFLICT(registration_revision) DO UPDATE SET
           token_hash = COALESCE(
             excluded.token_hash,
             apns_registration_revision_fences.token_hash
           ),
           decision_kind = excluded.decision_kind,
           blocks_lifecycle_replay = 1,
           processed_at_utc = MAX(
             excluded.processed_at_utc,
             apns_registration_revision_fences.processed_at_utc
           )`,
      )
      .bind(
        hashedToken,
        deletionDecisionId,
        deletionKind,
        now,
        ...deviceBindings,
      ),
    db
      .prepare(
        `INSERT OR IGNORE INTO apns_registration_revision_fences (
           token_hash, registration_revision, app_attest_key_id,
           decision_id, decision_kind,
           blocks_lifecycle_replay, processed_at_utc
         )
         SELECT token_hash, registration_revision, NULL,
                lower(hex(randomblob(16))), 'bad_device_token', 1, ?
         FROM alert_delivery_failures
         WHERE token_hash = ? AND status = 'active'
           AND apns_reason = 'BadDeviceToken'
           AND registration_revision IS NOT NULL
           AND EXISTS (SELECT 1 FROM devices WHERE ${deviceCondition})
         ON CONFLICT(registration_revision) DO UPDATE SET
           token_hash = COALESCE(
             excluded.token_hash,
             apns_registration_revision_fences.token_hash
           ),
           decision_kind = 'bad_device_token',
           blocks_lifecycle_replay = 1,
           processed_at_utc = MAX(
             excluded.processed_at_utc,
             apns_registration_revision_fences.processed_at_utc
           )`,
      )
      .bind(now, hashedToken, ...deviceBindings),
    ...(expectedRegistrationRevision
      ? []
      : [
          db
            .prepare(
              `UPDATE apns_registration_revision_fences
               SET decision_kind = 'explicit_removal',
                   blocks_lifecycle_replay = 1,
                   processed_at_utc = MAX(processed_at_utc, ?)
               WHERE (
                 token_hash = ?
                 OR app_attest_key_id IN (
                   SELECT app_attest_key_id FROM devices
                   WHERE ${deviceCondition} AND app_attest_key_id IS NOT NULL
                 )
               ) AND EXISTS (
                 SELECT 1 FROM devices WHERE ${deviceCondition}
               )`,
            )
            .bind(
              now,
              hashedToken,
              ...deviceBindings,
              ...deviceBindings,
            ),
        ]),
  ];
  const deviceDeletionIndex = 2 + fenceStatements.length + lifecycleCleanup.length;
  const results = await db.batch([
    db
      .prepare(
        `DELETE FROM notification_deliveries
         WHERE device_token IN (
           SELECT token FROM devices WHERE ${deviceCondition}
         )`,
      )
      .bind(...deviceBindings),
    ...fenceStatements,
    db
      .prepare(
        `DELETE FROM alert_delivery_failures
         WHERE token_hash = ? AND EXISTS (
           SELECT 1 FROM devices WHERE ${deviceCondition}
         )`,
      )
      .bind(hashedToken, ...deviceBindings),
    ...lifecycleCleanup,
    db.prepare(`DELETE FROM devices WHERE ${deviceCondition}`).bind(...deviceBindings),
    ...appAttestRetentionCleanupStatements(db, now),
  ]);
  if ((results[deviceDeletionIndex]?.meta.changes ?? 0) > 0) {
    return { outcome: "deleted", currentUpdatedAt: null };
  }

  const current = await db
    .prepare("SELECT updated_at FROM devices WHERE token = ?")
    .bind(token)
    .first<{ updated_at: string }>();
  if (!current) return { outcome: "not_found", currentUpdatedAt: null };
  if (expectedRegistrationRevision) {
    return {
      outcome: "newer_registration",
      currentUpdatedAt: current.updated_at,
    };
  }
  // Any deletion that leaves the same current row must be retried. Treating an
  // unconditional zero-change result as not-found would also falsely report a
  // successful user-requested removal while the registration still exists.
  return { outcome: "not_deleted", currentUpdatedAt: current.updated_at };
}

async function deactivateDevice(
  db: D1Database,
  device: RoutedDeviceRecord,
): Promise<DeviceDeletionResult | null> {
  try {
    return await deleteDeviceRegistration(
      db,
      device.token,
      device.registrationRevision,
      true,
    );
  } catch {
    return null;
  }
}

/**
 * Give each BadDeviceToken revision its own failure-row identity. The original
 * logical delivery ID remains in `origin_delivery_id`, while the dedicated
 * decision-fence table is authoritative for duplicate-response suppression.
 */
export function badDeviceTokenFailureId(registrationRevision: string): string {
  return `bad-device-token-revision:${registrationRevision}`;
}

export async function deactivateBadDeviceToken(
  db: D1Database,
  device: RoutedDeviceRecord,
  event: NormalizedEvent,
  reason: NotifyReason,
  deliveryId: string,
): Promise<"deleted" | "not_found" | "quarantined" | null> {
  try {
    const hashedToken = await tokenHash(device.token);
    const now = new Date().toISOString();
    const decisionId = crypto.randomUUID();
    const failureId = badDeviceTokenFailureId(device.registrationRevision);
    const results = await db.batch([
      // Claim this exact sent revision first. A same-token renewal fence is
      // deliberately claimable: if renewal serialized before Apple's
      // rejection, the renewed token must be quarantined. Consent-ending and
      // already-processed fences remain unclaimable, so a duplicate response
      // cannot cross an explicit removal or act on a later reincarnation.
      db
        .prepare(
          `INSERT INTO apns_registration_revision_fences (
             token_hash, registration_revision, app_attest_key_id,
             decision_id, decision_kind,
             blocks_lifecycle_replay, processed_at_utc
           ) VALUES (?, ?, ?, ?, 'bad_device_token', 1, ?)
           ON CONFLICT(registration_revision) DO UPDATE SET
             token_hash = excluded.token_hash,
             app_attest_key_id = COALESCE(
               excluded.app_attest_key_id,
               apns_registration_revision_fences.app_attest_key_id
             ),
             decision_id = excluded.decision_id,
             decision_kind = 'bad_device_token',
             blocks_lifecycle_replay = 1,
             processed_at_utc = MAX(
               excluded.processed_at_utc,
               apns_registration_revision_fences.processed_at_utc
             )
           WHERE apns_registration_revision_fences.decision_kind =
                   'registration_renewal'
             AND apns_registration_revision_fences.blocks_lifecycle_replay = 0`,
        )
        .bind(
          hashedToken,
          device.registrationRevision,
          device.appAttestKeyId ?? null,
          decisionId,
          now,
        ),
      db
        .prepare(
          `DELETE FROM notification_deliveries
           WHERE device_token IN (
             SELECT token FROM devices
             WHERE token = ? AND registration_revision = ?
               AND EXISTS (
                 SELECT 1 FROM apns_registration_revision_fences
                 WHERE registration_revision = ? AND decision_id = ?
               )
           )`,
        )
        .bind(
          device.token,
          device.registrationRevision,
          device.registrationRevision,
          decisionId,
        ),
      // If an earlier cleanup attempt failed after APNs rejected another
      // revision, deleting the current row also owns resolution of that active
      // evidence. Preserve each such revision as its own 14-day fence first.
      db
        .prepare(
          `INSERT OR IGNORE INTO apns_registration_revision_fences (
             token_hash, registration_revision, app_attest_key_id,
             decision_id, decision_kind,
             blocks_lifecycle_replay, processed_at_utc
           )
           SELECT token_hash, registration_revision, NULL,
                  lower(hex(randomblob(16))), 'bad_device_token', 1,
                  MAX(?, last_seen_utc)
           FROM alert_delivery_failures
           WHERE token_hash = ? AND status = 'active'
             AND apns_reason = 'BadDeviceToken'
             AND registration_revision IS NOT NULL
             AND EXISTS (
               SELECT 1 FROM devices
               WHERE token = ? AND registration_revision = ?
             )
             AND EXISTS (
               SELECT 1 FROM apns_registration_revision_fences
               WHERE registration_revision = ? AND decision_id = ?
             )`,
        )
        .bind(
          now,
          hashedToken,
          device.token,
          device.registrationRevision,
          device.registrationRevision,
          decisionId,
        ),
      db
        .prepare(
          `DELETE FROM alert_delivery_failures
           WHERE token_hash = ? AND status = 'active' AND EXISTS (
             SELECT 1 FROM devices
             WHERE token = ? AND registration_revision = ?
           ) AND EXISTS (
             SELECT 1 FROM apns_registration_revision_fences
             WHERE registration_revision = ? AND decision_id = ?
           )`,
        )
        .bind(
          hashedToken,
          device.token,
          device.registrationRevision,
          device.registrationRevision,
          decisionId,
        ),
      db
        .prepare(
          `DELETE FROM devices
           WHERE token = ? AND registration_revision = ?
             AND EXISTS (
               SELECT 1 FROM apns_registration_revision_fences
               WHERE registration_revision = ? AND decision_id = ?
             )`,
        )
        .bind(
          device.token,
          device.registrationRevision,
          device.registrationRevision,
          decisionId,
        ),
      // This statement follows the conditional delete in the same D1 batch.
      // The first response for this exact sent revision owns the decision. If
      // a registration serialized first, its distinct revision remains and is
      // quarantined even when both writes share a wall-clock timestamp. The
      // dedicated fence makes every duplicate response a no-op independently
      // of the per-delivery failure-row primary key.
      db
        .prepare(
          `INSERT INTO alert_delivery_failures (
            delivery_id, origin_delivery_id, token_hash, event_ref, source_id,
            notification_reason, apns_status, apns_reason, disposition,
            first_seen_utc, last_seen_utc, registration_revision
          )
          SELECT ?, ?, ?, ?, ?, ?, 400, 'BadDeviceToken', 'quarantine',
                 MAX(?, updated_at), MAX(?, updated_at), ?
          FROM devices
          WHERE token = ? AND registration_revision <> ?
            AND EXISTS (
              SELECT 1 FROM apns_registration_revision_fences
              WHERE registration_revision = ? AND decision_id = ?
            )
          ON CONFLICT(delivery_id, token_hash) DO UPDATE SET
            origin_delivery_id = excluded.origin_delivery_id,
            apns_status = 400,
            apns_reason = 'BadDeviceToken',
            disposition = 'quarantine',
            registration_revision = excluded.registration_revision,
            status = 'active',
            resolved_at_utc = NULL,
            last_seen_utc = excluded.last_seen_utc,
            occurrences = alert_delivery_failures.occurrences + 1`,
        )
        .bind(
          failureId,
          deliveryId,
          hashedToken,
          event.id,
          event.sourceId,
          reason,
          now,
          now,
          device.registrationRevision,
          device.token,
          device.registrationRevision,
          device.registrationRevision,
          decisionId,
        ),
      ...appAttestRetentionCleanupStatements(db, now),
    ]);
    if ((results[4]?.meta.changes ?? 0) > 0) return "deleted";
    if ((results[5]?.meta.changes ?? 0) > 0) return "quarantined";
    // The atomic transaction observed neither a deletable sent snapshot nor a
    // claimable newer row. Another response already processed this revision,
    // or another deletion already reached the desired state.
    return "not_found";
  } catch {
    return null;
  }
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

async function sendPushRequest(
  env: Env,
  device: RoutedDeviceRecord,
  event: NormalizedEvent,
  reason: NotifyReason,
  authorization: string,
  collapseId: string,
): Promise<ApnsDeliveryResult> {
  // Final defense in depth: no direct caller, legacy Queue copy, or tampered
  // D1 row can turn a disabled source into an APNs request.
  if (!isApnsRelaySource(event.sourceId)) {
    throw new RangeError("APNs relay source is not permitted");
  }
  requireApnsConfiguration(env);
  // `device.apnsTopic` came from the server-derived registration row. Match
  // all persisted route fields against the current allow-list again so a
  // disabled platform, stale mapping, or tampered D1 value cannot reach APNs.
  allowedStoredAppIdentityRoute(env, device);
  const host =
    device.environment === "sandbox"
      ? "api.sandbox.push.apple.com"
      : "api.push.apple.com";
  const response = await withApnsRequestTimeout((signal) =>
    fetch(`https://${host}/3/device/${encodeURIComponent(device.token)}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${authorization}`,
        "apns-topic": device.apnsTopic,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-expiration": APNS_EXPIRATION_IMMEDIATE,
        "apns-collapse-id": collapseId,
        "apns-id": crypto.randomUUID(),
        "content-type": "application/json",
      },
      body: JSON.stringify(buildPushPayload(event, reason, device.alertSound)),
      signal,
    }),
  );
  const responseReceivedAtMs = Date.now();
  const apnsId = response.headers.get("apns-id");
  if (response.ok) {
    return {
      ok: true,
      apnsId,
      acceptedAtUtc: new Date(responseReceivedAtMs).toISOString(),
    };
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
  const terminalInvalidToken =
    response.status === 400 && apnsReason === "BadDeviceToken";
  const registeredAfterInvalidation =
    terminalUnregistration &&
    !Number.isNaN(Date.parse(device.updatedAt)) &&
    Date.parse(device.updatedAt) > (invalidationTimestampMs as number);
  return {
    ok: false,
    apnsId,
    status: response.status,
    apnsReason,
    invalidationTimestampMs,
    retryAfterSeconds: retryAfterSeconds(response),
    terminalUnregistration,
    terminalInvalidToken,
    unregistrationTimestampMissing,
    // Apple's timestamp describes the sent token snapshot. If that snapshot
    // was registered strictly later, no D1 cleanup is necessary. Otherwise a
    // separate post-network phase conditionally deletes its exact revision.
    terminalResolved: terminalUnregistration && registeredAfterInvalidation,
  };
}

/**
 * Apply recipient-scoped terminal cleanup only after every provider 2xx from
 * the same small batch has crossed D1 while its pre-send intent remains
 * durable. A peer's fallible cleanup can therefore never strand acceptance
 * provenance in process memory.
 */
async function applyTerminalApnsCleanup(
  env: Env,
  device: RoutedDeviceRecord,
  event: NormalizedEvent,
  reason: NotifyReason,
  deliveryId: string,
  result: ApnsDeliveryResult,
): Promise<ApnsDeliveryResult> {
  if (result.ok) return result;
  const unregistrationDeletion =
    result.terminalUnregistration && !result.terminalResolved
      ? await deactivateDevice(env.DB, device)
      : null;
  const badDeviceTokenOutcome = result.terminalInvalidToken
    ? await deactivateBadDeviceToken(env.DB, device, event, reason, deliveryId)
    : null;
  const deactivated =
    unregistrationDeletion?.outcome === "deleted" ||
    badDeviceTokenOutcome === "deleted";
  const unregistrationResolved =
    unregistrationDeletion !== null &&
    unregistrationDeletion.outcome !== "not_deleted";
  const badDeviceTokenQuarantined = badDeviceTokenOutcome === "quarantined";
  return {
    ...result,
    terminalResolved:
      result.terminalResolved ||
      (result.terminalUnregistration && unregistrationResolved) ||
      (result.terminalInvalidToken &&
        (badDeviceTokenOutcome === "deleted" ||
          badDeviceTokenOutcome === "not_found")),
    deactivated,
    badDeviceTokenQuarantined,
  };
}

async function sendPush(
  env: Env,
  device: RoutedDeviceRecord,
  event: NormalizedEvent,
  reason: NotifyReason,
  authorization: string,
  collapseId: string,
  deliveryId = `direct-apns:${crypto.randomUUID()}`,
): Promise<ApnsDeliveryResult> {
  return applyTerminalApnsCleanup(
    env,
    device,
    event,
    reason,
    deliveryId,
    await sendPushRequest(
      env,
      device,
      event,
      reason,
      authorization,
      collapseId,
    ),
  );
}

/**
 * Production training is an authenticated diagnostic, not an alert fan-out.
 * Its short-lived D1 admission trigger prevents a pre-response renewal from
 * committing. Once the response marker commits, clean up only the exact sent
 * revision: a causally later renewal is authoritative and is never globally
 * quarantined by this diagnostic result.
 */
export async function applyTrainingTerminalApnsCleanup(
  db: D1Database,
  device: RoutedDeviceRecord,
  result: ApnsDeliveryResult,
): Promise<ApnsDeliveryResult> {
  if (
    result.ok ||
    !((result.terminalUnregistration && !result.terminalResolved) ||
      result.terminalInvalidToken)
  ) return result;
  const deletion = await deactivateDevice(db, device);
  if (deletion === null) {
    throw new Error("production training rejection cleanup failed");
  }
  return {
    ...result,
    terminalResolved: true,
    deactivated: deletion.outcome === "deleted",
    badDeviceTokenQuarantined: false,
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

async function productionTrainingPushThroughRelay(
  env: Env,
  device: RoutedDeviceRecord,
  kind: "immediate" | "delayed",
  deadlineUtc: string,
  collapseId: string,
): Promise<ApnsDeliveryResult> {
  if (device.appAttestKeyId === null || device.environment !== "production") {
    throw new Error("production training relay requires an attested production device");
  }
  const relay = env.RELAY.get(env.RELAY.idFromName("global"));
  const response = await relay.fetch(new Request(
    "https://relay.internal/apns/training",
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        token: device.token,
        registrationRevision: device.registrationRevision,
        appAttestKeyId: device.appAttestKeyId,
        kind,
        deadlineUtc,
        collapseId,
      } satisfies ProductionTrainingRelayRequest),
    },
  ));
  const body: unknown = await response.json().catch(() => null);
  const result = body && typeof body === "object" && !Array.isArray(body) &&
      Object.hasOwn(body, "result")
    ? (body as { result?: unknown }).result
    : null;
  if (
    !response.ok || !result || typeof result !== "object" ||
    Array.isArray(result) || typeof (result as { ok?: unknown }).ok !== "boolean" ||
    !(typeof (result as { apnsId?: unknown }).apnsId === "string" ||
      (result as { apnsId?: unknown }).apnsId === null)
  ) {
    throw new Error("production training relay returned an invalid result");
  }
  return result as ApnsDeliveryResult;
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
  // page or one authenticated topic group, not one recipient subscription.
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
 * `DeviceTokenNotForTopic` remains an infrastructure incident, not a reason to
 * quarantine a recipient. Multi-platform pages isolate topic-scoped failures
 * to their route group so one disabled Watch topic cannot block iOS delivery;
 * the bounded Queue-to-DLQ path still preserves the failed route's evidence.
 */
export function isPageLevelApnsFailure(result: ApnsDeliveryResult): boolean {
  if (
    result.terminalUnregistration ||
    result.terminalInvalidToken ||
    result.unregistrationTimestampMissing
  ) {
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

/** Failures that can be isolated to one APNs topic within a mixed route page. */
export function isTopicScopedApnsFailure(result: ApnsDeliveryResult): boolean {
  return [
    "AppRouteNotAllowed",
    "BadTopic",
    "DeviceTokenNotForTopic",
    "MissingTopic",
    "TopicDisallowed",
  ].includes(result.apnsReason ?? "");
}

function apnsFailureDisposition(
  result: ApnsDeliveryResult,
): ApnsFailureDisposition {
  // A 410 without Apple's invalidation timestamp is intentionally fail-safe:
  // preserve the registration and stop this delivery pending operator/client
  // review, rather than risking deletion of a freshly rotated token.
  if (result.unregistrationTimestampMissing) return "quarantine";

  // Apple documents BadDeviceToken as an invalid recipient token. Delete only
  // the exact opaque registration revision sent to APNs. A concurrent
  // authenticated refresh is preserved but quarantined across events unless
  // this old revision was already processed; a later authenticated renewal
  // resolves active evidence while retaining that duplicate-response fence.
  // If D1 cleanup/evidence persistence fails, the current bounded page retry
  // may contact APNs again because there is no cleanup-only durable work item.
  if (result.terminalInvalidToken) {
    if (result.badDeviceTokenQuarantined) {
      return "quarantine";
    }
    return result.terminalResolved ? "terminal" : "retry";
  }

  // A timestamped APNs 410 is also a safe deletion signal. If D1 cleanup
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

  // Topic, payload, and other non-terminal token failures (for example a 403)
  // are durable incident evidence, but retrying a
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

function durableApnsResult(
  settled: PromiseSettledResult<ApnsDeliveryResult>,
): ApnsDeliveryResult {
  if (settled.status === "fulfilled") return { ...settled.value };
  return {
    ok: false,
    apnsId: null,
    apnsReason:
      settled.reason instanceof AppIdentityRouteNotAllowedError
        ? "AppRouteNotAllowed"
        : "TransportError",
  };
}

function apnsObservedBatchRetryPolicy(results: ApnsDeliveryResult[]): {
  retryRequired: boolean;
  retryDelaySeconds: number;
} {
  let retryRequired = false;
  let retryDelaySeconds = DEFAULT_QUEUE_RETRY_DELAY_SECONDS;
  for (const result of results) {
    if (result.ok) continue;
    const disposition = apnsFailureDisposition(result);
    if (disposition !== "retry" && disposition !== "page_retry") continue;
    retryRequired = true;
    retryDelaySeconds = Math.max(
      retryDelaySeconds,
      apnsRetryDelaySeconds(result),
    );
  }
  return { retryRequired, retryDelaySeconds };
}

function deterministicPageFailure(
  results: ApnsDeliveryResult[],
): ApnsDeliveryResult | null {
  const pageFailures = results.filter((result) =>
    !result.ok && isPageLevelApnsFailure(result)
  );
  pageFailures.sort((left, right) => {
    const delay = apnsRetryDelaySeconds(right) - apnsRetryDelaySeconds(left);
    if (delay !== 0) return delay;
    const reason = (left.apnsReason ?? "").localeCompare(right.apnsReason ?? "");
    if (reason !== 0) return reason;
    return (left.status ?? 0) - (right.status ?? 0);
  });
  return pageFailures[0] ?? null;
}

export async function recordDeliveryFailure(
  db: D1Database,
  deliveryId: string,
  event: NormalizedEvent,
  reason: NotifyReason,
  deviceToken: string,
  tokenHashValue: string,
  registrationRevision: string,
  registrationUpdatedAt: string,
  result: ApnsDeliveryResult,
  disposition: Exclude<ApnsFailureDisposition, "terminal" | "page_retry">,
  observedAtUtc = new Date().toISOString(),
): Promise<void> {
  const now = observedAtUtc;
  // An active invalid-token row must not age out before the registration whose
  // fanout it suppresses. Pin its last-seen clock to at least that snapshot's
  // refresh time. If atomic BadDeviceToken cleanup failed and an authenticated
  // renewal serialized before this fallback write, the same D1 statement also
  // observes the current raw-token row and pins retention to its clock. If the
  // evidence writes first, registration resolves it instead. Raw tokens are
  // used only for this D1 lookup and never copied into failure evidence.
  const lastSeenUtc = deliveryFailureLastSeenUtc(now, registrationUpdatedAt);
  const badDeviceToken = result.apnsReason === "BadDeviceToken";
  const failureId = badDeviceToken
    ? badDeviceTokenFailureId(registrationRevision)
    : deliveryId;
  await db
    .prepare(
      `INSERT INTO alert_delivery_failures (
        delivery_id, origin_delivery_id, token_hash, event_ref, source_id,
        notification_reason, apns_status, apns_reason, disposition,
        first_seen_utc, last_seen_utc, registration_revision
      ) SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
          MAX(?, COALESCE(
            (SELECT updated_at FROM devices WHERE token = ?), ?
          )), ?
      ON CONFLICT(delivery_id, token_hash) DO UPDATE SET
        origin_delivery_id = excluded.origin_delivery_id,
        apns_status = excluded.apns_status,
        apns_reason = excluded.apns_reason,
        disposition = excluded.disposition,
        registration_revision = excluded.registration_revision,
        status = 'active',
        resolved_at_utc = NULL,
        last_seen_utc = MAX(
          alert_delivery_failures.last_seen_utc,
          excluded.last_seen_utc
        ),
        occurrences = alert_delivery_failures.occurrences + CASE
          WHEN alert_delivery_failures.last_seen_utc < excluded.last_seen_utc
            THEN 1 ELSE 0 END`,
    )
    .bind(
      failureId,
      badDeviceToken ? deliveryId : null,
      tokenHashValue,
      event.id,
      event.sourceId,
      reason,
      result.status ?? null,
      result.apnsReason ?? null,
      disposition,
      now,
      lastSeenUtc,
      badDeviceToken ? deviceToken : null,
      lastSeenUtc,
      registrationRevision,
    )
    .run();
}

export function deliveryFailureLastSeenUtc(
  observedAtUtc: string,
  registrationUpdatedAt: string,
): string {
  const registrationUpdatedAtMs = Date.parse(registrationUpdatedAt);
  return !Number.isNaN(registrationUpdatedAtMs) &&
      registrationUpdatedAtMs > Date.parse(observedAtUtc)
    ? registrationUpdatedAt
    : observedAtUtc;
}

async function recordPageDeliveryFailure(
  db: D1Database,
  outboxId: string,
  message: AlertDeliveryMessage,
  result: ApnsDeliveryResult,
  observedAtUtc = new Date().toISOString(),
): Promise<void> {
  const now = observedAtUtc;
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
        last_seen_utc = MAX(
          alert_delivery_page_failures.last_seen_utc,
          excluded.last_seen_utc
        ),
        occurrences = alert_delivery_page_failures.occurrences + CASE
          WHEN alert_delivery_page_failures.last_seen_utc < excluded.last_seen_utc
            THEN 1 ELSE 0 END`,
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
       WHERE status = 'active'
         AND (
           (disposition = 'quarantine'
             AND (COALESCE(origin_delivery_id, delivery_id) = ?
               OR apns_reason = 'BadDeviceToken'))
           OR (disposition = 'retry' AND apns_reason = 'BadDeviceToken'
             AND COALESCE(origin_delivery_id, delivery_id) <> ?)
         )
         AND token_hash IN (${placeholders})`,
    )
    .bind(deliveryId, deliveryId, ...tokenHashes)
    .all<{ token_hash: string }>();
  const quarantinedHashes = new Set(result.results.map((row) => row.token_hash));
  return new Set(
    tokens.filter((token, index) => quarantinedHashes.has(tokenHashes[index])),
  );
}

function isTerminalAlertLifecycleReason(reason: NotifyReason): boolean {
  return reason === "final" || reason === "cancelled";
}

/**
 * Terminal revisions close only alerts this service previously delivered and
 * whose source the current registration still selects. Match both the token
 * hash and the opaque App Attest key: the hash preserves continuity across an
 * integrity-key reset with the same APNs token, while the key preserves
 * continuity across ordinary APNs token rotation. Magnitude/location changes
 * cannot strand a warning, but removing its feed remains an immediate consent
 * boundary.
 */
export async function terminalAlertLifecycleDevices(
  db: D1Database,
  eventRef: string,
  devices: RoutedDeviceRecord[],
): Promise<RoutedDeviceRecord[]> {
  if (devices.length === 0) return [];
  const tokenHashes = await Promise.all(
    devices.map((device) => tokenHash(device.token)),
  );
  const appAttestKeyIds = [
    ...new Set(
      devices.flatMap((device) =>
        device.appAttestKeyId === null ? [] : [device.appAttestKeyId]
      ),
    ),
  ];
  const tokenPlaceholders = tokenHashes.map(() => "?").join(", ");
  const keyPredicate = appAttestKeyIds.length === 0
    ? ""
    : ` OR lifecycle.app_attest_key_id IN (${
      appAttestKeyIds.map(() => "?").join(", ")
    })`;
  const possibleKeyPredicate = appAttestKeyIds.length === 0
    ? ""
    : ` OR possible.app_attest_key_id IN (${
      appAttestKeyIds.map(() => "?").join(", ")
    })`;
  const result = await db
    .prepare(
      `SELECT lifecycle.token_hash, lifecycle.app_attest_key_id
       FROM alert_lifecycle_recipients AS lifecycle
       WHERE lifecycle.event_ref = ?
         AND (lifecycle.token_hash IN (${tokenPlaceholders})${keyPredicate})
         AND NOT EXISTS (
           SELECT 1 FROM apns_registration_revision_fences AS fence
           WHERE fence.registration_revision = lifecycle.registration_revision
             AND fence.blocks_lifecycle_replay = 1
             AND fence.decision_kind IN (
               'explicit_removal', 'empty_source_removal',
               'stale_registration_retention'
             )
             AND fence.processed_at_utc >= lifecycle.last_evidence_at_utc
         )
       UNION
       SELECT possible.token_hash, possible.app_attest_key_id
       FROM alert_lifecycle_possible_attempts AS possible
       WHERE possible.event_ref = ?
         AND (possible.token_hash IN (${tokenPlaceholders})${possibleKeyPredicate})
         AND NOT EXISTS (
           SELECT 1 FROM apns_registration_revision_fences AS fence
           WHERE fence.registration_revision = possible.registration_revision
             AND fence.blocks_lifecycle_replay = 1
             AND fence.decision_kind IN (
               'explicit_removal', 'empty_source_removal',
               'stale_registration_retention'
             )
         )`,
    )
    .bind(
      eventRef,
      ...tokenHashes,
      ...appAttestKeyIds,
      eventRef,
      ...tokenHashes,
      ...appAttestKeyIds,
    )
    .all<{ token_hash: string; app_attest_key_id: string | null }>();
  const deliveredTokenHashes = new Set(
    result.results.map(({ token_hash: value }) => value),
  );
  const deliveredAppAttestKeyIds = new Set(
    result.results.flatMap(({ app_attest_key_id: value }) =>
      value === null ? [] : [value]
    ),
  );
  return devices.filter((device, index) =>
    deliveredTokenHashes.has(tokenHashes[index]) ||
    (device.appAttestKeyId !== null &&
      deliveredAppAttestKeyIds.has(device.appAttestKeyId))
  );
}

export async function recordDeliveredDevices(
  db: D1Database,
  deliveryId: string,
  eventRef: string,
  sourceId: WolfxSourceId,
  reason: NotifyReason,
  deliveries: AcceptedDeliveryEvidence[],
  resolveFailureEvidence = true,
): Promise<void> {
  if (deliveries.length === 0) return;
  const currentRegistrationCondition = `(
    token = ? OR (? IS NOT NULL AND app_attest_key_id = ?)
  ) AND EXISTS (
    SELECT 1 FROM json_each(
      CASE WHEN json_valid(devices.sources) THEN devices.sources ELSE '[]' END
    ) WHERE value = ?
  )
  AND NOT EXISTS (
    SELECT 1 FROM apns_registration_revision_fences AS fence
    WHERE fence.registration_revision = ?
      AND fence.blocks_lifecycle_replay = 1
      AND fence.decision_kind IN (
        'explicit_removal', 'empty_source_removal',
        'stale_registration_retention'
      )
  )
  ORDER BY CASE WHEN token = ? THEN 0 ELSE 1 END
  LIMIT 1`;
  const currentRegistrationBindings = (
    delivery: AcceptedDeliveryEvidence,
  ): unknown[] => [
    delivery.token,
    delivery.snapshotAppAttestKeyId,
    delivery.snapshotAppAttestKeyId,
    sourceId,
    delivery.snapshotRegistrationRevision,
    delivery.token,
  ];
  const lifecycleStatements = reason === "new" || reason === "updated"
    ? deliveries.map((delivery) =>
        db
          .prepare(
            `INSERT INTO alert_lifecycle_recipients (
               event_ref, token_hash, app_attest_key_id, registration_revision,
               evidence_kind, first_evidence_at_utc, last_evidence_at_utc
             )
             SELECT ?, ?, app_attest_key_id, registration_revision,
                    'apns_accepted', ?, ?
             FROM devices
             WHERE ${currentRegistrationCondition}
             ON CONFLICT(event_ref, token_hash) DO UPDATE SET
               app_attest_key_id = excluded.app_attest_key_id,
               registration_revision = excluded.registration_revision,
               evidence_kind = 'apns_accepted',
               first_evidence_at_utc = MIN(
                 alert_lifecycle_recipients.first_evidence_at_utc,
                 excluded.first_evidence_at_utc
               ),
               last_evidence_at_utc = MAX(
                 alert_lifecycle_recipients.last_evidence_at_utc,
                 excluded.last_evidence_at_utc
               )`,
          )
          .bind(
            eventRef,
            delivery.tokenHash,
            delivery.firstAcceptedAtUtc,
            delivery.lastAcceptedAtUtc,
            ...currentRegistrationBindings(delivery),
          )
      )
    : [];
  const failureResolutionStatements = resolveFailureEvidence
    ? deliveries.map((delivery) =>
        db
          .prepare(
            // Resolve only evidence whose provider-response observation is no
            // later than this APNs 2xx. D1 serialization alone is insufficient
            // when two requests overlap; delayed journal replay disables this
            // update while retaining the original accepted-at timestamp.
            `UPDATE alert_delivery_failures
             SET status = 'resolved',
                 resolved_at_utc = MAX(?, last_seen_utc),
                 last_seen_utc = MAX(?, last_seen_utc)
             WHERE token_hash = ? AND status = 'active'
               AND last_seen_utc <= ?
               AND (
                 delivery_id = ?
                 OR origin_delivery_id = ?
                 OR apns_reason = 'BadDeviceToken'
               )
               AND EXISTS (
                 SELECT 1 FROM devices
                 WHERE ${currentRegistrationCondition}
               )`,
          )
          .bind(
            delivery.lastAcceptedAtUtc,
            delivery.lastAcceptedAtUtc,
            delivery.tokenHash,
            delivery.lastAcceptedAtUtc,
            deliveryId,
            deliveryId,
            ...currentRegistrationBindings(delivery),
          )
      )
    : [];
  await db.batch(
    [
      ...deliveries.map((delivery) =>
        db
          .prepare(
            `INSERT INTO notification_deliveries
             (delivery_id, device_token, delivered_at_utc, lifecycle_reconciled)
             SELECT ?, token, ?, 1 FROM devices
             WHERE ${currentRegistrationCondition}
             ON CONFLICT(delivery_id, device_token) DO UPDATE SET
               lifecycle_reconciled = 1`,
          )
          .bind(
            deliveryId,
            delivery.firstAcceptedAtUtc,
            ...currentRegistrationBindings(delivery),
          ),
      ),
      ...failureResolutionStatements,
      ...lifecycleStatements,
    ],
  );
}

/**
 * A controlled production training 2xx is current-revision provider evidence,
 * even though it must not create earthquake delivery or lifecycle rows. Clear
 * only older/equal BadDeviceToken observations for the still-exact revision;
 * a later rejection remains active by its provider-response timestamp.
 */
async function resolveBadDeviceTokenAfterTrainingAcceptance(
  db: D1Database,
  device: RoutedDeviceRecord,
  acceptedAtUtc: string,
): Promise<void> {
  const hashedToken = await tokenHash(device.token);
  await db
    .prepare(
      `UPDATE alert_delivery_failures
       SET status = 'resolved',
           resolved_at_utc = MAX(?, last_seen_utc),
           last_seen_utc = MAX(?, last_seen_utc)
       WHERE token_hash = ? AND status = 'active'
         AND apns_reason = 'BadDeviceToken'
         AND last_seen_utc <= ?
         AND EXISTS (
           SELECT 1 FROM devices
           WHERE token = ? AND registration_revision = ?
         )`,
    )
    .bind(
      acceptedAtUtc,
      acceptedAtUtc,
      hashedToken,
      acceptedAtUtc,
      device.token,
      device.registrationRevision,
    )
    .run();
}

interface DeliveryPageResult {
  nextAfterDeviceCursor: number | null;
  retryRequired: boolean;
  retryDelaySeconds: number;
  invalidateApnsJwt: boolean;
  /** Provider/payload page failure or one topic-group failure, never one token. */
  pageFailure: ApnsDeliveryResult | null;
  /** Only provider-wide failures may stop cursor progression to later pages. */
  globalPageFailure: boolean;
  /** The pre-send intent completion transaction already recorded pageFailure. */
  pageFailurePersistedByIntent: boolean;
  /** An expiry or newer serial stopped the page before later APNs batches. */
  terminalState: OutboxDeliveryGateState | null;
}

type OutboxDeliveryGateState =
  | "pending"
  | "acknowledged"
  | "expired"
  | "superseded"
  | "missing";

export async function dispatchPushPage(
  env: Env,
  event: NormalizedEvent,
  reason: NotifyReason,
  authorization: string,
  deliveryId: string,
  afterDeviceCursor?: number,
  beforeApnsBatch?: () => Promise<OutboxDeliveryGateState>,
  persistAcceptedBatch?: (
    deliveries: AcceptedDelivery[],
  ) => Promise<void>,
  prepareApnsBatch?: (
    deliveries: PreparedDelivery[],
  ) => Promise<ApnsDeliveryIntentHandle>,
  persistObservedApnsBatch?: (
    intent: ApnsDeliveryIntentHandle,
    observedAtUtc: string,
    deliveries: MappedApnsIntentRecipient[],
    results: ApnsDeliveryResult[],
  ) => Promise<void>,
  finalApnsBatchAdmission?: (
    intent: ApnsDeliveryIntentHandle,
    deliveries: PreparedDelivery[],
  ) => Promise<MappedApnsIntentRecipient[]>,
  completeApnsBatch?: (
    intent: ApnsDeliveryIntentHandle,
    pageFailure: ApnsDeliveryResult | null,
  ) => Promise<boolean>,
): Promise<DeliveryPageResult> {
  if (!isApnsRelaySource(event.sourceId)) {
    throw new RangeError("APNs relay source is not permitted");
  }
  if (
    [
      prepareApnsBatch,
      persistObservedApnsBatch,
      finalApnsBatchAdmission,
      completeApnsBatch,
    ].filter((callback) => callback !== undefined).length % 4 !== 0
  ) {
    throw new TypeError("APNs intent callbacks must be supplied together");
  }
  // APNs JWT credentials are environment-specific. A production Worker must
  // never page a legacy sandbox subscription (and an isolated development
  // Worker must never reach production subscriptions), even if an older
  // client registered it before the App Attest registration fence existed.
  const deviceEnvironment = apnsDeviceEnvironmentForWorker(env);
  const rows = await env.DB
    .prepare(
      `SELECT rowid AS cursor, * FROM devices
       WHERE rowid > ? AND environment = ?
       ORDER BY rowid ASC
       LIMIT ?`,
    )
    .bind(afterDeviceCursor ?? 0, deviceEnvironment, DEVICE_DELIVERY_PAGE_SIZE)
    .all<DeviceRow>();
  const page = rows.results;
  const nextAfterDeviceCursor =
    page.length === DEVICE_DELIVERY_PAGE_SIZE
      ? (page.at(-1)?.cursor ?? null)
      : null;
  const pageDevices = page.map(rowToDevice);
  const devices = isTerminalAlertLifecycleReason(reason)
    ? await terminalAlertLifecycleDevices(
        env.DB,
        event.id,
        pageDevices.filter((device) => device.sources.includes(event.sourceId)),
      )
    : pageDevices.filter((device) => shouldNotify(device, event, reason));
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
  let retryRequired = false;
  let retryDelaySeconds = DEFAULT_QUEUE_RETRY_DELAY_SECONDS;
  let invalidateApnsJwt = false;
  let pageFailure: ApnsDeliveryResult | null = null;
  let globalPageFailure = false;
  let pageFailurePersistedByIntent = false;
  let terminalState: OutboxDeliveryGateState | null = null;

  // Do not mix APNs topics in one concurrent batch. A topic entitlement or
  // token/topic mismatch can then stop only that route while other platforms
  // on the same D1 page still receive the alert. Provider/auth/transport
  // failures remain page-wide and stop every later route group.
  const pendingRouteGroups = new Map<string, RoutedDeviceRecord[]>();
  for (const device of pendingDevices) {
    const routeKey = `${device.appIdentity}\u0000${device.apnsTopic}\u0000${device.platform}`;
    const group = pendingRouteGroups.get(routeKey) ?? [];
    group.push(device);
    pendingRouteGroups.set(routeKey, group);
  }

  routeGroups:
  for (const routeDevices of pendingRouteGroups.values()) {
    for (
      let start = 0;
      start < routeDevices.length;
      start += APNS_MAX_CONCURRENT_DELIVERIES
    ) {
      // Re-check immediately before every small APNs batch. The initial relay
      // gate handles the common case; this closes the window where a newer event
      // revision commits while the current page is reading/filtering devices.
      const gateState = beforeApnsBatch ? await beforeApnsBatch() : "pending";
      if (gateState !== "pending") {
        terminalState = gateState;
        break routeGroups;
      }
      const batch = routeDevices.slice(
        start,
        start + APNS_MAX_CONCURRENT_DELIVERIES,
      );
      const deliveries: PreparedDelivery[] = await Promise.all(
        batch.map(async (device) => ({
          device,
          tokenHash: await tokenHash(device.token),
        })),
      );
      // This is the first durable boundary for a provider attempt. A crash at
      // any point after it (including immediately after APNs returns 2xx) leaves
      // enough event/recipient state for the global relay to retry safely.
      const preparedIntent = prepareApnsBatch
        ? await prepareApnsBatch(deliveries)
        : null;
      // Supersession/expiry can commit while intent admission and conservative
      // lifecycle evidence cross D1. Make the authoritative outbox read the
      // final awaited operation before any provider byte is sent.
      let contactedRecipients = deliveries.map((delivery, originDeliveryIndex) => ({
        delivery,
        originDeliveryIndex,
        snapshotRegistrationRevision: delivery.device.registrationRevision,
      }));
      const admittedRecipients =
        finalApnsBatchAdmission && preparedIntent
          ? await finalApnsBatchAdmission(preparedIntent, deliveries)
          : null;
      if (admittedRecipients !== null) contactedRecipients = admittedRecipients;
      const contactedDeliveries = contactedRecipients.map(({ delivery }) => delivery);
      const finalGateState = finalApnsBatchAdmission
        ? (contactedDeliveries.length > 0 ? "pending" : "changed")
        : (beforeApnsBatch ? await beforeApnsBatch() : "pending");
      if (finalGateState !== "pending") {
        if (finalGateState !== "changed") terminalState = finalGateState;
        if (preparedIntent && completeApnsBatch) {
          if (finalGateState !== "changed") {
            await completeApnsBatch(preparedIntent, null);
          }
        }
        if (finalGateState === "changed") {
          retryRequired = true;
          retryDelaySeconds = Math.max(
            retryDelaySeconds,
            DEFAULT_QUEUE_RETRY_DELAY_SECONDS,
          );
        }
        break routeGroups;
      }
      const results = await Promise.allSettled(
        contactedDeliveries.map(({ device }) =>
          sendPushRequest(
            env,
            device,
            event,
            reason,
            authorization,
            collapseId,
          ),
        ),
      );
      const observedAtUtc = new Date().toISOString();
      const durableResults = results.map(durableApnsResult);
      if (preparedIntent && persistObservedApnsBatch) {
        // This DO write precedes every fallible D1 write below. Recovery can
        // replay exact accept/terminal/page outcomes without another APNs
        // contact, and the maximum observed Retry-After is never lost behind
        // a peer's failing cleanup.
        await persistObservedApnsBatch(
          preparedIntent,
          observedAtUtc,
          contactedRecipients,
          durableResults,
        );
      }
      const intentOwnsOutcomePersistence =
        preparedIntent !== null && completeApnsBatch !== undefined;
      const providerFailure = deterministicPageFailure(durableResults);
      if (intentOwnsOutcomePersistence) {
        // The durable observed-batch reconciler owns every D1 mutation. Do not
        // repeat accepted/failure/cleanup statements in this request: keeping
        // one owner is idempotent and keeps the single-recipient page
        // below the Workers Free D1 query budget.
        const intentStillPending = await completeApnsBatch(
          preparedIntent,
          providerFailure,
        );
        if (intentStillPending) {
          // A transaction-time admission can deliberately omit a recipient
          // whose revision changed during preparation. The durable intent owns
          // that recipient's re-resolution, so keep the Queue/outbox page alive
          // until the continuation is actually complete instead of returning a
          // success that `/outbox/ack` could terminalize.
          retryRequired = true;
          retryDelaySeconds = Math.max(
            retryDelaySeconds,
            DEFAULT_QUEUE_RETRY_DELAY_SECONDS,
          );
        }
      }
      const acceptedBatch: AcceptedDelivery[] = [];
      for (const [index, result] of results.entries()) {
        if (result.status === "fulfilled" && result.value.ok) {
          acceptedBatch.push({
            ...contactedDeliveries[index],
            acceptedAtUtc: result.value.acceptedAtUtc as string,
          });
        }
      }
      if (acceptedBatch.length > 0 && !intentOwnsOutcomePersistence) {
        if (persistAcceptedBatch) {
          await persistAcceptedBatch(acceptedBatch);
        } else {
          await recordDeliveredDevices(
            env.DB,
            deliveryId,
            event.id,
            event.sourceId,
            reason,
            acceptedBatch.map((delivery) => ({
              token: delivery.device.token,
              tokenHash: delivery.tokenHash,
              snapshotRegistrationRevision:
                delivery.device.registrationRevision,
              snapshotAppAttestKeyId: delivery.device.appAttestKeyId,
              firstAcceptedAtUtc: delivery.acceptedAtUtc,
              lastAcceptedAtUtc: delivery.acceptedAtUtc,
            })),
            true,
          );
        }
      }

      // Provider calls are complete and every observed 2xx is durable. Only
      // now may a peer's BadDeviceToken/410 path enter fallible D1 cleanup.
      // Preserve PromiseSettledResult shape so the existing page-level
      // classifier continues to handle transport rejections consistently.
      for (const [index, result] of results.entries()) {
        if (
          !intentOwnsOutcomePersistence &&
          result.status === "fulfilled" && !result.value.ok
        ) {
          result.value = await applyTerminalApnsCleanup(
            env,
            contactedDeliveries[index].device,
            event,
            reason,
            deliveryId,
            result.value,
          );
        }
      }

      // A terminal-token response is only retryable while its exact sent
      // revision still needs cleanup. Apply that cleanup before deriving the
      // page retry policy; otherwise the pre-cleanup observation permanently
      // marks a successfully deleted BadDeviceToken as Queue-retry work.
      // Intent-owned outcomes are reconciled from their durable journal, where
      // an unresolved cleanup remains pending and therefore still retries.
      if (!intentOwnsOutcomePersistence) {
        const observedRetryPolicy = apnsObservedBatchRetryPolicy(
          results.map((result, index) =>
            result.status === "fulfilled"
              ? result.value
              : durableResults[index]
          ),
        );
        retryRequired ||= observedRetryPolicy.retryRequired;
        retryDelaySeconds = Math.max(
          retryDelaySeconds,
          observedRetryPolicy.retryDelaySeconds,
        );
      } else {
        const observedRetryPolicy = apnsObservedBatchRetryPolicy(
          durableResults.filter((result) =>
            !result.terminalInvalidToken && !result.terminalUnregistration
          ),
        );
        retryRequired ||= observedRetryPolicy.retryRequired;
        retryDelaySeconds = Math.max(
          retryDelaySeconds,
          observedRetryPolicy.retryDelaySeconds,
        );
      }

      // Classify every fulfilled peer before acting on a page-scoped failure.
      // APNs can return a provider-token error for one concurrent request and
      // a longer Retry-After or terminal-token result for another; neither
      // observed outcome may disappear behind the first page classification.
      for (const [index, result] of results.entries()) {
        const delivery = contactedDeliveries[index];
        if (result.status === "fulfilled") {
          if (result.value.ok) {
            // Persisted immediately above before any later APNs batch or
            // provider/failure handling can supersede this known acceptance.
          } else {
            const disposition = apnsFailureDisposition(result.value);
            const quarantinePersisted =
              disposition === "quarantine" &&
              result.value.badDeviceTokenQuarantined === true;
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
              if (!intentOwnsOutcomePersistence) await recordDeliveryFailure(
                env.DB,
                deliveryId,
                event,
                reason,
                delivery.device.token,
                delivery.tokenHash,
                delivery.device.registrationRevision,
                delivery.device.updatedAt,
                result.value,
                "retry",
              );
            } else if (disposition === "quarantine" && !quarantinePersisted) {
              if (!intentOwnsOutcomePersistence) await recordDeliveryFailure(
                env.DB,
                deliveryId,
                event,
                reason,
                delivery.device.token,
                delivery.tokenHash,
                delivery.device.registrationRevision,
                delivery.device.updatedAt,
                result.value,
                "quarantine",
              );
            }
          }
        } else {
          // Rejections were handled as page-level failures above. This branch
          // remains for type exhaustiveness if the classifier is tightened.
          logApnsException(event, reason, delivery.tokenHash, result.reason);
          retryRequired = true;
          retryDelaySeconds = Math.max(
            retryDelaySeconds,
            APNS_TRANSIENT_RETRY_DELAY_SECONDS,
          );
          // A rejected send can be a deterministic stored-route mismatch,
          // not an uncertain token-level transport outcome. Preserve the
          // page/topic failure without manufacturing retry evidence for a
          // device that was never contacted.
          const durableResult = durableResults[index];
          if (
            !intentOwnsOutcomePersistence &&
            !isTopicScopedApnsFailure(durableResult)
          ) {
            await recordDeliveryFailure(
              env.DB,
              deliveryId,
              event,
              reason,
              delivery.device.token,
              delivery.tokenHash,
              delivery.device.registrationRevision,
              delivery.device.updatedAt,
              durableResult,
              "retry",
            );
          }
        }
      }
      if (providerFailure) {
        const failure = providerFailure;
        pageFailure ??= failure;
        retryRequired = true;
        retryDelaySeconds = Math.max(
          retryDelaySeconds,
          apnsRetryDelaySeconds(failure),
        );
        invalidateApnsJwt ||= failure.apnsReason === "ExpiredProviderToken";
        globalPageFailure ||= !isTopicScopedApnsFailure(failure);
        if (intentOwnsOutcomePersistence) {
          pageFailurePersistedByIntent = true;
        }
        if (isTopicScopedApnsFailure(failure)) break;
        break routeGroups;
      }
      if (preparedIntent && completeApnsBatch && !intentOwnsOutcomePersistence) {
        await completeApnsBatch(preparedIntent, null);
      }
    }
  }

  return {
    nextAfterDeviceCursor,
    retryRequired,
    retryDelaySeconds,
    invalidateApnsJwt,
    pageFailure,
    globalPageFailure,
    pageFailurePersistedByIntent,
    terminalState,
  };
}

export function productionTestPushAllowed(
  enableProductionTestPush: string | undefined,
  deviceEnvironment: "sandbox" | "production",
  kind: DeviceTestPushRequest["kind"],
): boolean {
  return (
    deviceEnvironment !== "production" ||
    kind === "immediate" ||
    enableProductionTestPush === "true"
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
  // A successful HTTP Upgrade is not upstream liveness. Track each socket's
  // first valid Wolfx frame in memory and reset its durable exponential
  // reconnect history only after it remains live for a bounded interval.
  // This keeps an Upgrade-then-close flap from returning to the five-second
  // retry floor and spending Durable Object rows indefinitely.
  private readonly upstreamActivatedAtMs = new Map<UpstreamRoute, number>();
  private readonly upstreamLivenessSinceMs = new Map<UpstreamRoute, number>();
  private readonly lastUpstreamTransportMessageMs = new Map<UpstreamRoute, number>();
  private readonly stableReconnectBackoffResetRoutes = new Set<UpstreamRoute>();
  // Transport traffic and alert-source readiness are deliberately separate.
  // A heartbeat can keep a previously validated socket alive, but only a data
  // frame that later crosses its durable D1/journal boundary may put that
  // exact socket in this ready map. The validated map is the in-flight token
  // that lets the eventual commit prove which connection supplied the data.
  private readonly validatedUpstreamDataSockets = new Map<
    UpstreamRoute,
    UpstreamDataReadinessCandidate
  >();
  private readonly readyUpstreamSockets = new Map<UpstreamRoute, WebSocket>();
  private readonly statuses = new Map<WolfxSourceId, string>();
  private readonly lastSuccessfulUpstreamMs = new Map<WolfxSourceId, number>();
  private readonly lastSuccessfulHttpPollMs = new Map<WolfxSourceId, number>();
  // These maps are a per-instance cache of successfully committed durable
  // freshness checkpoints. They are populated from storage on the first
  // committed data frame (or later ready-socket heartbeat) after an eviction,
  // so a restart never fabricates a checkpoint.
  private readonly lastPersistedUpstreamSuccessMs = new Map<WolfxSourceId, number>();
  private readonly lastPersistedHttpSuccessMs = new Map<WolfxSourceId, number>();
  // A failed write must not publish fresh in-memory evidence, but retrying it
  // for every heartbeat would create an error storm after a storage quota is
  // exhausted. Bound failed retries to the same checkpoint cadence.
  private readonly lastUpstreamCheckpointAttemptMs = new Map<WolfxSourceId, number>();
  private readonly lastHttpCheckpointAttemptMs = new Map<WolfxSourceId, number>();
  // Only D1-committed point-event fingerprints enter this bounded resident
  // LRU. It is an optimization for rapid upstream replay, never a durability
  // boundary: an eviction or restart deliberately returns to the journal.
  private readonly committedLiveEventFingerprints = new Map<string, true>();
  // Resuming a durable changed-snapshot cursor is paced in memory. A restart
  // may cause one early retry, but never a steady sub-minute polling loop;
  // the cursor itself remains the durable fail-closed fence.
  private lastHttpSnapshotResumeStartedMs: number | null = null;
  // WebSocket message handlers use waitUntil and may overlap while awaiting
  // storage. Serialize one source/transport freshness update so a burst of
  // heartbeats cannot all observe the same old checkpoint and write it again.
  private readonly freshnessUpdates = new Map<string, Promise<unknown>>();
  private httpSeedInFlight: Promise<void> | null = null;
  private pendingIngestDrain: Promise<void> | null = null;
  // One source can publish the same complete ranked list more than once while
  // its first bounded D1 slices are still settling. Keep one drain per source
  // so duplicate frames share the durable cursor instead of racing it.
  private readonly liveSnapshotDrains = new Map<
    LiveSnapshotSource,
    Promise<void>
  >();
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
  // Capacity and the exact intent must be durable before APNs sees a batch.
  // Serialize provider work and every terminal gate in one global lane so
  // concurrent Queue requests cannot consume the final slot or supersede an
  // admitted provider attempt while its D1 outcome is unresolved.
  private apnsDeliverySerial: Promise<void> = Promise.resolve();

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

    if (url.pathname === "/dlq/finalize" && request.method === "POST") {
      let body: unknown;
      try {
        body = await request.json();
      } catch {
        return Response.json({ error: "invalid DLQ incident evidence" }, { status: 400 });
      }
      if (!isDlqIncidentEvidence(body)) {
        return Response.json({ error: "invalid DLQ incident evidence" }, { status: 400 });
      }
      try {
        return await this.serializeApnsDelivery(async () => {
          // Terminal DLQ state cannot outrun a provider acceptance already
          // journaled—or a batch currently admitted in this same serial lane.
          if (await this.reconcileApnsAcceptanceJournal()) {
            throw new Error("APNs durability maintenance owns this invocation");
          }
          const incidentRecorded = await persistDlqIncidentAndFinalizeOutbox(
            this.env,
            body,
          );
          return Response.json({ ok: true, incidentRecorded });
        });
      } catch {
        return Response.json(
          { error: "DLQ finalization is temporarily unavailable" },
          { status: 503 },
        );
      }
    }

    if (url.pathname === "/apns/training" && request.method === "POST") {
      let body: unknown;
      try {
        body = await request.json();
      } catch {
        return Response.json({ error: "invalid production training request" }, { status: 400 });
      }
      if (!isProductionTrainingRelayRequest(body)) {
        return Response.json({ error: "invalid production training request" }, { status: 400 });
      }
      try {
        return await this.serializeApnsDelivery(async () => {
          // A controlled training response and every alert response share one
          // causal lane. Reconcile admitted alert work first, then re-read the
          // exact current production revision inside that lane before APNs.
          if (await this.reconcileApnsAcceptanceJournal()) {
            throw new Error("APNs durability maintenance owns this invocation");
          }
          const row = await this.env.DB
            .prepare(
              `SELECT * FROM devices
               WHERE token = ? AND registration_revision = ?
                 AND app_attest_key_id = ? AND environment = 'production'`,
            )
            .bind(
              body.token,
              body.registrationRevision,
              body.appAttestKeyId,
            )
            .first<DeviceRow>();
          if (!row) {
            return Response.json(
              { error: "production training registration changed" },
              { status: 409 },
            );
          }
          const device = rowToDevice(row);
          allowedStoredAppIdentityRoute(this.env, device);
          if (
            !productionTestPushAllowed(
              this.env.ENABLE_PRODUCTION_TEST_PUSH,
              device.environment,
              body.kind,
            ) || !hasApnsConfiguration(this.env)
          ) {
            return Response.json(
              { error: "production training delivery is disabled" },
              { status: 403 },
            );
          }
          const event = trainingTestEvent();
          const expectedCollapseId = await apnsCollapseID(event);
          if (body.collapseId !== expectedCollapseId) {
            return Response.json(
              { error: "invalid production training collapse ID" },
              { status: 400 },
            );
          }
          const authorization = await this.apnsAuthorization();
          const collapseId = body.collapseId;
          const finalDevice = rowToDevice(row);
          const trainingAttemptId = `training:${crypto.randomUUID()}`;
          const admittedAtUtc = new Date().toISOString();
          const trainingTokenHash = await tokenHash(finalDevice.token);
          // Schedule crash recovery before the final D1 admission. The INSERT
          // below is intentionally the last awaited operation before fetch.
          await this.scheduleRelayAlarm(
            Date.now() + TRAINING_APNS_ATTEMPT_RECOVERY_MS,
          );
          const admission = await this.env.DB
            .prepare(
              `INSERT INTO apns_provider_attempts (
                 attempt_id, registration_revision, token_hash,
                 event_ref, outbox_id, admitted_at_utc
               )
               SELECT ?, registration_revision, ?, ?, ?, ? FROM devices
               WHERE token = ? AND registration_revision = ?
                 AND app_attest_key_id = ? AND environment = 'production'
                 AND NOT EXISTS (
                   SELECT 1 FROM apns_registration_revision_fences
                   WHERE registration_revision = devices.registration_revision
                     AND blocks_lifecycle_replay = 1
                 )
               RETURNING registration_revision`,
            )
            .bind(
              trainingAttemptId,
              trainingTokenHash,
              event.id,
              trainingAttemptId,
              admittedAtUtc,
              body.token,
              body.registrationRevision,
              body.appAttestKeyId,
            )
            .first<{ registration_revision: string }>();
          // The serial lane can wait behind emergency recovery. Recheck after
          // every preceding await so a delayed appointment or concurrent
          // opt-out/revision change never reaches APNs. This exact D1 read is
          // the final awaited operation before provider contact.
          if (!admission || Date.now() > Date.parse(body.deadlineUtc)) {
            if (admission) {
              await this.env.DB
                .prepare(
                  `UPDATE apns_provider_attempts
                   SET outcome_reconciled_at_utc = ?
                   WHERE attempt_id = ? AND outcome_reconciled_at_utc IS NULL`,
                )
                .bind(new Date().toISOString(), trainingAttemptId)
                .run();
            }
            return Response.json(
              { error: "production training registration or deadline changed" },
              { status: 409 },
            );
          }
          allowedStoredAppIdentityRoute(this.env, finalDevice);
          let result: ApnsDeliveryResult;
          try {
            result = await sendPushRequest(
              this.env,
              finalDevice,
              event,
              "training",
              authorization,
              collapseId,
            );
          } finally {
            // This D1 marker is the response-order boundary. Any registration
            // mutation serialized before it fails closed on the unresolved
            // attempt; one serialized afterward is a new revision that the
            // exact cleanup below cannot delete or quarantine.
            await this.env.DB
              .prepare(
                `UPDATE apns_provider_attempts
                 SET outcome_reconciled_at_utc = COALESCE(
                   outcome_reconciled_at_utc, ?
                 ) WHERE attempt_id = ?`,
              )
              .bind(new Date().toISOString(), trainingAttemptId)
              .run();
          }
          result = await applyTrainingTerminalApnsCleanup(
            this.env.DB,
            finalDevice,
            result,
          );
          if (result.ok && result.acceptedAtUtc) {
            await resolveBadDeviceTokenAfterTrainingAcceptance(
              this.env.DB,
              finalDevice,
              result.acceptedAtUtc,
            );
          }
          return Response.json({ result });
        });
      } catch {
        return Response.json(
          { error: "production training delivery is temporarily unavailable" },
          { status: 503 },
        );
      }
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
    if (
      url.pathname === "/outbox/source-policy/reject" &&
      request.method === "POST"
    ) {
      let body: unknown;
      try {
        body = await request.json();
      } catch {
        return Response.json({ error: "invalid source-policy rejection" }, { status: 400 });
      }
      const outboxId =
        body && typeof body === "object" && !Array.isArray(body) &&
          "outboxId" in body
          ? (body as { outboxId?: unknown }).outboxId
          : null;
      if (
        typeof outboxId !== "string" ||
        outboxId.length === 0 ||
        outboxId.length > 128
      ) {
        return Response.json({ error: "invalid source-policy rejection" }, { status: 400 });
      }
      return this.serializeApnsDelivery(async () => {
        if (await this.reconcileApnsAcceptanceJournal()) {
          throw new Error("APNs durability maintenance owns this invocation");
        }
        const superseded = await this.supersedeOutboxForSourcePolicy(outboxId);
        return Response.json({ ok: true, alreadyMissingOrAllowed: !superseded });
      });
    }
    await this.ensureRequestStarted();
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
      return this.serializeApnsDelivery(() => this.deliverQueuedPage(body));
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
      return this.serializeApnsDelivery(async () => {
        if (await this.reconcileApnsAcceptanceJournal()) {
          throw new Error("APNs durability maintenance owns this invocation");
        }
        const acknowledged = await this.finalizeOutbox(outboxId, "delivered");
        // An old Queue message can outlive terminal-outbox retention. Its relay
        // path already proved that no APNs work remains safe; acknowledge that
        // Queue copy instead of retrying it into a misleading DLQ incident.
        return Response.json({ ok: true, alreadyMissing: !acknowledged });
      });
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

  /**
   * Queue/API requests must not inherit the alarm's purge, outbox-flush, or
   * bounded migration budget before doing their own D1 work. Start only the
   * in-memory transports and ensure an alarm owns durable maintenance.
   */
  private async ensureRequestStarted(): Promise<void> {
    await this.ensureUpstreams();
    if (await this.state.storage.getAlarm() === null) {
      await this.scheduleRoutineRelayAlarm();
    }
  }

  async alarm(): Promise<void> {
    try {
      // Prepared APNs work outranks every later outbox supersession/expiry
      // decision. Recovery can itself contact APNs, so it shares the exact
      // serial lane used by live delivery and every terminal outbox gate.
      const apnsMaintenancePerformed = await this.serializeApnsDelivery(() =>
        this.reconcileApnsAcceptanceJournal()
      );
      if (apnsMaintenancePerformed) {
        await this.ensureUpstreams();
        return;
      }
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
        // waiting for its durable retry time, but do not let ordinary D1 work
        // bypass the same failure deferral and enter an automatic alarm loop.
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
        // sweeps. Keep attempting the preferred sockets. A complete outage
        // retains the alternate transport's exclusive turn, while a partial
        // outage may process bounded work already accepted from healthy
        // routes without sharing a due HTTP recovery turn.
        await this.ensureUpstreams();
        if (!await this.partialFallbackMaintenanceAllowed(
          fallbackActive,
          pendingHttpSnapshot,
          Date.now(),
        )) return;
      }
      // Repair only durable slot shapes left by an interrupted older revision.
      // The normal active → latest → overflow transitions are transactional;
      // this lets an alarm resume a valid newer slot even if no subsequent
      // WebSocket frame arrives after a rolling deploy or eviction.
      await this.repairPendingLiveSnapshotSlots();
      if (await this.hasAnyActiveLiveSnapshotWork()) {
        // A live ranked-list cursor has the same bounded-D1 requirement as an
        // HTTP cursor. Whether it is due now or waiting for its five-second
        // continuation, do not combine its recovery window with ordinary D1
        // journal/outbox work. The final scheduler below retains the exact
        // cursor retry deadline.
        if (await this.drainPendingLiveSnapshotWorks()) return;
        await this.ensureUpstreams();
        return;
      }
      // Every D1-heavy maintenance class owns one alarm invocation. Combining
      // journal replay, an eight-row outbox flush, and the retention batch can
      // exceed Workers Free's 50-query ceiling before a live delivery starts.
      if (await this.apnsDurabilityMaintenanceOwnsInvocation()) {
        await this.serializeApnsDelivery(() =>
          this.reconcileApnsAcceptanceJournal()
        );
        await this.ensureUpstreams();
        return;
      }
      const pendingDlqFallback = await this.state.storage.list({
        prefix: DLQ_PERSISTENCE_FALLBACK_PREFIX,
        limit: 1,
      });
      if (pendingDlqFallback.size > 0) {
        await this.serializeApnsDelivery(async () => {
          if (await this.reconcileApnsAcceptanceJournal()) return;
          await this.reconcileDlqPersistenceFallbacks();
        });
        await this.ensureUpstreams();
        return;
      }
      const pendingLegacy = await this.state.storage.list({
        prefix: LEGACY_PENDING_DELIVERY_PREFIX,
        limit: 1,
      });
      if (pendingLegacy.size > 0) {
        await this.migrateLegacyPendingDeliveries();
        await this.ensureUpstreams();
        return;
      }
      if (await this.drainPendingLiveSnapshotWorks()) return;
      const pendingIngest = await this.state.storage.list({
        prefix: PENDING_INGEST_PREFIX,
        limit: 1,
      });
      if (pendingIngest.size > 0) {
        await this.drainPendingIngestJournal(1, 1);
        await this.ensureUpstreams();
        return;
      }
      if (await this.devicePurgeIsDue()) {
        await this.purgeExpiredDevicesIfDue();
        await this.ensureUpstreams();
        return;
      }
      if (
        await this.flushAlertDeliveryOutbox(ROUTINE_OUTBOX_FLUSH_BATCH_SIZE) >
          0
      ) {
        await this.ensureUpstreams();
        return;
      }
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
    // All D1 recovery/flush/purge work is alarm-owned and staged one bounded
    // class per invocation. A first health/request bootstrap only ensures that
    // such an alarm exists; it never spends that maintenance budget itself.
    if (alarm === null) await this.scheduleRoutineRelayAlarm();
  }

  private async ensureApnsAcceptanceJournalCapacity(
    exemptKey?: string,
  ): Promise<void> {
    const pending = await this.state.storage.list({
      prefix: APNS_ACCEPTANCE_JOURNAL_PREFIX,
      limit: APNS_ACCEPTANCE_JOURNAL_MAX_RECORDS + 1,
    });
    const occupied = exemptKey && pending.has(exemptKey)
      ? pending.size - 1
      : pending.size;
    if (occupied >= APNS_ACCEPTANCE_JOURNAL_MAX_RECORDS) {
      throw new Error("APNs acceptance journal capacity is exhausted");
    }
  }

  /**
   * Reserve one bounded Durable Object record before the first APNs byte is
   * sent. The exact event plus registration snapshots are the recovery owner;
   * the writeId prevents an old completion from deleting a replacement.
   */
  private async persistApnsDeliveryIntent(
    message: AlertDeliveryMessage,
    deliveries: PreparedDelivery[],
  ): Promise<ApnsDeliveryIntentHandle> {
    if (
      deliveries.length < 1 ||
      deliveries.length > APNS_MAX_CONCURRENT_DELIVERIES
    ) {
      throw new RangeError("APNs delivery intent batch is out of bounds");
    }
    const storedMessage = apnsJournalMessage(message);
    const key = await apnsDeliveryIntentStorageKey(storedMessage, deliveries);
    await this.ensureApnsAcceptanceJournalCapacity(key);
    let handle: ApnsDeliveryIntentHandle | null = null;
    let storedRecord: PendingApnsDeliveryIntentRecord | null = null;
    let alreadyPending = false;
    await this.state.storage.transaction(async (transaction) => {
      const current = await transaction.get<unknown>(key);
      if (current !== undefined) {
        if (!isPendingApnsDeliveryIntentRecord(current)) {
          throw new Error("APNs delivery intent identity collision");
        }
        alreadyPending = true;
        storedRecord = current;
        handle = { storageKey: key, writeId: current.writeId };
        return;
      }
      const createdAtUtc = new Date().toISOString();
      const record: PendingApnsDeliveryIntentRecord = {
        version: 2,
        writeId: crypto.randomUUID(),
        createdAtUtc,
        providerAttempts: 0,
        recipientProviderAttempts: {},
        lastProviderAttemptAtUtc: createdAtUtc,
        nextProviderAttemptAtUtc: createdAtUtc,
        recipientRetryNotBeforeUtc: {},
        unobservedAttemptReconciled: true,
        lifecycleEvidencePreparedAtUtc: null,
        observedBatch: null,
        message: storedMessage,
        deliveries,
      };
      if (!isPendingApnsDeliveryIntentRecord(record)) {
        throw new Error("APNs delivery intent record exceeds its bounds");
      }
      await transaction.put(key, record);
      storedRecord = record;
      handle = { storageKey: key, writeId: record.writeId };
    });
    if (!handle || !storedRecord) {
      throw new Error("APNs delivery intent write failed");
    }
    await this.scheduleRelayAlarm(Date.now() + PENDING_INGEST_RETRY_DELAY_MS);
    if (alreadyPending) {
      // The serial recovery owner, not a duplicate Queue request, decides when
      // the existing durable intent may contact APNs again.
      throw new Error("APNs delivery intent is already pending recovery");
    }
    return handle;
  }

  private async completeApnsDeliveryIntent(
    handle: ApnsDeliveryIntentHandle,
  ): Promise<void> {
    const reconciledAtUtc = new Date().toISOString();
    await this.env.DB
      .prepare(
        `UPDATE apns_provider_attempts
         SET outcome_reconciled_at_utc = COALESCE(
           outcome_reconciled_at_utc, ?
         )
         WHERE attempt_id LIKE ?`,
      )
      .bind(reconciledAtUtc, `${handle.writeId}:%`)
      .run();
    await this.state.storage.transaction(async (transaction) => {
      const current = await transaction.get<unknown>(handle.storageKey);
      if (
        isPendingApnsDeliveryIntentRecord(current) &&
        current.writeId === handle.writeId
      ) {
        await transaction.delete(handle.storageKey);
      }
    });
  }

  /** Reserve one recovery provider contact before network I/O. */
  private async reserveApnsDeliveryIntentRecovery(
    key: string,
    record: PendingApnsDeliveryIntentRecord,
  ): Promise<PendingApnsDeliveryIntentRecord> {
    let reserved: PendingApnsDeliveryIntentRecord | null = null;
    await this.state.storage.transaction(async (transaction) => {
      const current = await transaction.get<unknown>(key);
      if (
        !isPendingApnsDeliveryIntentRecord(current) ||
        current.writeId !== record.writeId
      ) {
        throw new Error("APNs delivery intent changed before recovery");
      }
      if (current.observedBatch !== null) {
        throw new Error("APNs delivery intent outcomes require reconciliation");
      }
      const nowMs = Date.now();
      if (nowMs < Date.parse(current.nextProviderAttemptAtUtc)) {
        throw new Error("APNs delivery intent recovery is not due");
      }
      const attemptedAtUtc = new Date(nowMs).toISOString();
      reserved = {
        ...current,
        providerAttempts: current.providerAttempts + 1,
        lastProviderAttemptAtUtc: attemptedAtUtc,
        nextProviderAttemptAtUtc: new Date(
          nowMs + DEFAULT_QUEUE_RETRY_DELAY_SECONDS * 1_000,
        ).toISOString(),
        // Optimistic marker: the immediately following final D1 admission
        // either writes exact attempt evidence and contacts APNs, or restores
        // the prior record without spending this reservation.
        lifecycleEvidencePreparedAtUtc: attemptedAtUtc,
        unobservedAttemptReconciled: false,
        observedBatch: null,
      };
      await transaction.put(key, reserved);
    });
    if (!reserved) throw new Error("APNs delivery intent recovery reservation failed");
    return reserved;
  }

  private async restoreUncontactedApnsIntentReservation(
    key: string,
    reserved: PendingApnsDeliveryIntentRecord,
    prior: PendingApnsDeliveryIntentRecord,
  ): Promise<void> {
    await this.state.storage.transaction(async (transaction) => {
      const current = await transaction.get<unknown>(key);
      if (
        !isPendingApnsDeliveryIntentRecord(current) ||
        current.writeId !== reserved.writeId ||
        current.providerAttempts !== reserved.providerAttempts ||
        current.lastProviderAttemptAtUtc !== reserved.lastProviderAttemptAtUtc ||
        current.observedBatch !== null
      ) {
        throw new Error("APNs uncontacted reservation changed before restore");
      }
      await transaction.put(key, prior);
    });
    await this.scheduleRelayAlarm(Date.now() + PENDING_INGEST_RETRY_DELAY_MS);
  }

  private async persistApnsDeliveryIntentObservedBatch(
    handle: ApnsDeliveryIntentHandle,
    observedAtUtc: string,
    deliveries: MappedApnsIntentRecipient[],
    results: ApnsDeliveryResult[],
  ): Promise<void> {
    const observedBatch: ApnsIntentObservedBatch = {
      observedAtUtc,
      deliveries,
      results: results.map((result) => ({ ...result })),
    };
    let retryAtMs: number | null = null;
    await this.state.storage.transaction(async (transaction) => {
      const current = await transaction.get<unknown>(handle.storageKey);
      if (
        !isPendingApnsDeliveryIntentRecord(current) ||
        current.writeId !== handle.writeId ||
        current.lifecycleEvidencePreparedAtUtc !==
          current.lastProviderAttemptAtUtc ||
        current.observedBatch !== null ||
        !isApnsIntentObservedBatch(observedBatch, current.deliveries.length)
      ) {
        throw new Error("APNs delivery outcomes cannot be journaled");
      }
      const retryPolicy = apnsObservedBatchRetryPolicy(observedBatch.results);
      retryAtMs = retryPolicy.retryRequired
        ? Math.max(
            Date.parse(current.nextProviderAttemptAtUtc),
            Date.parse(observedAtUtc) + retryPolicy.retryDelaySeconds * 1_000,
          )
        : Date.parse(current.nextProviderAttemptAtUtc);
      await transaction.put(handle.storageKey, {
        ...current,
        observedBatch,
        nextProviderAttemptAtUtc: new Date(retryAtMs).toISOString(),
      } satisfies PendingApnsDeliveryIntentRecord);
    });
    await this.scheduleRelayAlarm(
      Math.min(
        retryAtMs ?? Date.now() + PENDING_INGEST_RETRY_DELAY_MS,
        Date.now() + PENDING_INGEST_RETRY_DELAY_MS,
      ),
    );
  }

  /**
   * Reconcile one already-observed provider batch before any recovery contact.
   * All results were durably journaled together, so every peer's D1 mutation
   * is attempted even when another peer fails. The record is cleared only
   * after every applicable acceptance, cleanup, failure, and page incident is
   * durable; otherwise recovery repeats these idempotent operations without
   * contacting APNs again.
   */
  private async reconcileObservedApnsDeliveryIntentBatch(
    key: string,
    record: PendingApnsDeliveryIntentRecord,
    resolveRecoveredPageFailure = false,
  ): Promise<PendingApnsDeliveryIntentRecord | null> {
    const observed = record.observedBatch;
    if (observed === null) return record;
    const attemptId = `${record.writeId}:${record.providerAttempts}`;
    const attemptRows = await this.env.DB
      .prepare(
        `SELECT registration_revision, outcome_reconciled_at_utc
         FROM apns_provider_attempts
         WHERE attempt_id = ?`,
      )
      .bind(attemptId)
      .all<{
        registration_revision: string;
        outcome_reconciled_at_utc: string | null;
      }>();
    const attemptByRevision = new Map(
      attemptRows.results.map((row) => [row.registration_revision, row]),
    );
    const alreadyReconciled = observed.deliveries.every(({ delivery: { device } }) =>
      attemptByRevision.get(device.registrationRevision)
        ?.outcome_reconciled_at_utc !== null &&
      attemptByRevision.get(device.registrationRevision)
        ?.outcome_reconciled_at_utc !== undefined
    );
    if (!alreadyReconciled && observed.deliveries.some(({ delivery: { device } }) =>
      !attemptByRevision.has(device.registrationRevision)
    )) {
      throw new Error("APNs observed outcomes lost their D1 attempt fence");
    }
    const event = eventFromDeliveryMessage(record.message);
    const reconciledResults = observed.results.map((result) => ({ ...result }));
    const accepted = observed.deliveries.flatMap((recipient, index) => {
      const result = reconciledResults[index];
      return result.ok
        ? [{
            ...recipient.delivery,
            acceptedAtUtc: result.acceptedAtUtc as string,
          }]
        : [];
    });
    const firstPhase: Promise<unknown>[] = [];
    if (!alreadyReconciled && accepted.length > 0) {
      firstPhase.push(recordDeliveredDevices(
        this.env.DB,
        record.message.deliveryId,
        event.id,
        event.sourceId,
        record.message.reason,
        accepted.map((delivery) => ({
          token: delivery.device.token,
          tokenHash: delivery.tokenHash,
          snapshotRegistrationRevision: delivery.device.registrationRevision,
          snapshotAppAttestKeyId: delivery.device.appAttestKeyId,
          firstAcceptedAtUtc: delivery.acceptedAtUtc,
          lastAcceptedAtUtc: delivery.acceptedAtUtc,
        })),
        true,
      ));
    }
    for (const [index, result] of reconciledResults.entries()) {
      if (alreadyReconciled) break;
      if (result.ok) continue;
      const delivery = observed.deliveries[index].delivery;
      firstPhase.push(
        applyTerminalApnsCleanup(
          this.env,
          delivery.device,
          event,
          record.message.reason,
          record.message.deliveryId,
          result,
        ).then((cleaned) => {
          reconciledResults[index] = cleaned;
        }),
      );
    }
    const firstSettled = await Promise.allSettled(firstPhase);
    const firstFailure = firstSettled.find((result) => result.status === "rejected");
    if (firstFailure?.status === "rejected") throw firstFailure.reason;

    const evidenceWrites: Promise<unknown>[] = [];
    for (const [index, result] of reconciledResults.entries()) {
      if (alreadyReconciled) break;
      if (result.ok || isPageLevelApnsFailure(result)) continue;
      const disposition = apnsFailureDisposition(result);
      const delivery = observed.deliveries[index].delivery;
      if (disposition === "retry") {
        evidenceWrites.push(recordDeliveryFailure(
          this.env.DB,
          record.message.deliveryId,
          event,
          record.message.reason,
          delivery.device.token,
          delivery.tokenHash,
          delivery.device.registrationRevision,
          delivery.device.updatedAt,
          result,
          "retry",
          observed.observedAtUtc,
        ));
      } else if (
        disposition === "quarantine" &&
        result.badDeviceTokenQuarantined !== true
      ) {
        evidenceWrites.push(recordDeliveryFailure(
          this.env.DB,
          record.message.deliveryId,
          event,
          record.message.reason,
          delivery.device.token,
          delivery.tokenHash,
          delivery.device.registrationRevision,
          delivery.device.updatedAt,
          result,
          "quarantine",
          observed.observedAtUtc,
        ));
      }
    }
    const pageFailure = deterministicPageFailure(reconciledResults);
    if (!alreadyReconciled && pageFailure) {
      evidenceWrites.push(recordPageDeliveryFailure(
        this.env.DB,
        record.message.outboxId,
        record.message,
        pageFailure,
        observed.observedAtUtc,
      ));
    }
    const evidenceSettled = await Promise.allSettled(evidenceWrites);
    const evidenceFailure = evidenceSettled.find(
      (result) => result.status === "rejected",
    );
    if (evidenceFailure?.status === "rejected") throw evidenceFailure.reason;

    if (
      resolveRecoveredPageFailure &&
      !pageFailure &&
      !(await this.hasOtherApnsIntentForOutbox(key, record.message.outboxId))
    ) {
      // This clean batch is a recovery of the only remaining failed route for
      // the page, not merely a healthy later route in the same live dispatch.
      // Resolve before the outcome marker so a crash can only repeat this
      // idempotent write, never skip it.
      await resolvePageDeliveryFailure(this.env.DB, record.message.outboxId);
    }

    if (!alreadyReconciled) {
      await this.env.DB.batch([
      ...observed.deliveries.flatMap((recipient, index) => {
        const delivery = recipient.delivery;
        const result = reconciledResults[index];
        // A provider HTTP response (2xx or rejection) proves whether this
        // attempt was accepted. AppRouteNotAllowed proves no provider contact.
        // Preserve possible-contact evidence only for an unknown transport
        // outcome such as a timeout/reset where APNs might have accepted.
        const definitiveOutcome = result.ok || result.status !== undefined ||
          result.apnsReason === "AppRouteNotAllowed";
        return definitiveOutcome
          ? [
            this.env.DB
              .prepare(
                `DELETE FROM alert_lifecycle_possible_attempts
                 WHERE attempt_id = ? AND registration_revision = ?`,
              )
              .bind(attemptId, delivery.device.registrationRevision),
          ]
          : [];
      }),
      ...observed.deliveries.map(({ delivery }) =>
        this.env.DB
          .prepare(
            `UPDATE apns_provider_attempts
             SET outcome_reconciled_at_utc = COALESCE(
               outcome_reconciled_at_utc, ?
             )
             WHERE attempt_id = ? AND registration_revision = ?`,
          )
          .bind(
            observed.observedAtUtc,
            attemptId,
            delivery.device.registrationRevision,
          )
      ),
      ]);
      const markerRows = await this.env.DB
        .prepare(
          `SELECT registration_revision FROM apns_provider_attempts
           WHERE attempt_id = ? AND outcome_reconciled_at_utc IS NOT NULL`,
        )
        .bind(attemptId)
        .all<{ registration_revision: string }>();
      const marked = new Set(
        markerRows.results.map((row) => row.registration_revision),
      );
      if (observed.deliveries.some(({ delivery: { device } }) =>
        !marked.has(device.registrationRevision)
      )) {
        throw new Error("APNs observed outcome marker did not commit");
      }
    }

    const remaining = await this.currentDevicesForApnsIntent(record);
    const contactedByOrigin = new Map(
      observed.deliveries.map((recipient) => [
        recipient.snapshotRegistrationRevision,
        recipient,
      ] as const),
    );
    const retryableContactedOrigins = new Set(
      observed.deliveries.flatMap((recipient, index) => {
        const disposition = apnsFailureDisposition(reconciledResults[index]);
        return disposition === "retry" || disposition === "page_retry"
          ? [recipient.snapshotRegistrationRevision]
          : [];
      }),
    );
    const keepIntent = remaining.redispatch.some((recipient) => {
      const contacted = contactedByOrigin.get(
        recipient.snapshotRegistrationRevision,
      );
      return contacted === undefined ||
        contacted.delivery.device.registrationRevision !==
          recipient.delivery.device.registrationRevision ||
        retryableContactedOrigins.has(recipient.snapshotRegistrationRevision);
    });
    let reconciled: PendingApnsDeliveryIntentRecord | null = null;
    await this.state.storage.transaction(async (transaction) => {
      const current = await transaction.get<unknown>(key);
      if (
        !isPendingApnsDeliveryIntentRecord(current) ||
        current.writeId !== record.writeId ||
        current.observedBatch?.observedAtUtc !== observed.observedAtUtc
      ) {
        throw new Error("APNs observed outcome record changed during reconciliation");
      }
      if (keepIntent) {
        const retryNotBefore = {
          ...current.recipientRetryNotBeforeUtc,
        };
        for (const [index, recipient] of observed.deliveries.entries()) {
          const originRevision = recipient.snapshotRegistrationRevision;
          if (retryableContactedOrigins.has(originRevision)) {
            const result = reconciledResults[index];
            const resultRetryAtUtc = new Date(
              Date.parse(observed.observedAtUtc) +
                apnsRetryDelaySeconds(result) * 1_000,
            ).toISOString();
            const priorRetryAt = retryNotBefore[originRevision];
            retryNotBefore[originRevision] = priorRetryAt === undefined
              ? resultRetryAtUtc
              : new Date(Math.max(
                  Date.parse(priorRetryAt),
                  Date.parse(resultRetryAtUtc),
                )).toISOString();
          } else {
            delete retryNotBefore[originRevision];
          }
        }
        const nowUtc = new Date().toISOString();
        const nextRetryAtMs = Math.min(
          ...remaining.redispatch.map(({ snapshotRegistrationRevision }) =>
            Date.parse(
              retryNotBefore[snapshotRegistrationRevision] ?? nowUtc,
            )
          ),
        );
        reconciled = {
          ...current,
          observedBatch: null,
          unobservedAttemptReconciled: true,
          recipientRetryNotBeforeUtc: retryNotBefore,
          nextProviderAttemptAtUtc: new Date(nextRetryAtMs).toISOString(),
        };
        await transaction.put(key, reconciled);
      } else {
        await transaction.delete(key);
      }
    });
    if (!keepIntent) return null;
    if (!reconciled) {
      throw new Error("APNs observed outcome reconciliation was not committed");
    }
    // TypeScript cannot observe assignments made inside the D1 transaction
    // callback; the guard above establishes the runtime invariant.
    const committedReconciled = reconciled as PendingApnsDeliveryIntentRecord;
    if (pageFailure?.apnsReason === "ExpiredProviderToken") {
      this.apnsJwtCache = null;
    }
    await this.scheduleRelayAlarm(Date.parse(committedReconciled.nextProviderAttemptAtUtc));
    return committedReconciled;
  }

  private async hasOtherApnsIntentForOutbox(
    currentKey: string,
    outboxId: string,
  ): Promise<boolean> {
    const pending = await this.state.storage.list<unknown>({
      prefix: APNS_ACCEPTANCE_JOURNAL_PREFIX,
      limit: APNS_ACCEPTANCE_JOURNAL_MAX_RECORDS + 1,
    });
    for (const [key, value] of pending) {
      if (key === currentKey) continue;
      if (
        isPendingApnsDeliveryIntentRecord(value) &&
        value.message.outboxId === outboxId
      ) return true;
    }
    return false;
  }

  private async terminalizeExhaustedApnsDeliveryIntent(
    key: string,
    record: PendingApnsDeliveryIntentRecord,
  ): Promise<void> {
    await persistDlqIncidentAndFinalizeOutbox(this.env, {
      queueMessageId:
        `apns-intent:${key.slice(APNS_ACCEPTANCE_JOURNAL_PREFIX.length)}`,
      queueAttempts: record.providerAttempts,
      deliveryId: record.message.deliveryId,
      rootDeliveryId: record.message.rootDeliveryId,
      eventId: record.message.event.eventId,
      sourceId: record.message.event.sourceId,
      eventSerial: record.message.event.serial,
      notificationReason: record.message.reason,
      outboxId: record.message.outboxId,
    });
    await this.completeApnsDeliveryIntent({
      storageKey: key,
      writeId: record.writeId,
    });
  }

  private async currentDevicesForApnsIntent(
    record: PendingApnsDeliveryIntentRecord,
  ): Promise<ApnsIntentRecipientResolution> {
    const event = eventFromDeliveryMessage(record.message);
    const originalDelivered = await deliveredDeviceTokens(
      this.env.DB,
      record.message.deliveryId,
      record.deliveries.map(({ device }) => device.token),
    );
    const candidates: MappedApnsIntentRecipient[] = [];
    for (const [originDeliveryIndex, prepared] of record.deliveries.entries()) {
      if (originalDelivered.has(prepared.device.token)) continue;
      const fence = await this.env.DB
        .prepare(
          `SELECT blocks_lifecycle_replay, decision_kind
           FROM apns_registration_revision_fences
           WHERE registration_revision = ? LIMIT 1`,
        )
        .bind(prepared.device.registrationRevision)
        .first<{ blocks_lifecycle_replay: number; decision_kind: string }>();
      // Only an explicit consent boundary retires the original lineage. A
      // BadDeviceToken or timestamped-410 decision applies to the contacted
      // token/revision, but ordinary same-key rotation may remap the still-live
      // intent to the replacement token. Delivery-failure dedupe/quarantine
      // below still prevents recontacting an unchanged invalid registration.
      if (
        fence?.blocks_lifecycle_replay === 1 &&
        [
          "explicit_removal",
          "empty_source_removal",
          "stale_registration_retention",
        ].includes(fence.decision_kind)
      ) continue;
      const rows = await this.env.DB
        .prepare(
          `SELECT * FROM devices
           WHERE environment = ?
             AND (token = ? OR (? IS NOT NULL AND app_attest_key_id = ?))
           ORDER BY CASE WHEN token = ? THEN 0 ELSE 1 END
           LIMIT 2`,
        )
        .bind(
          prepared.device.environment,
          prepared.device.token,
          prepared.device.appAttestKeyId,
          prepared.device.appAttestKeyId,
          prepared.device.token,
        )
        .all<DeviceRow>();
      for (const row of rows.results) {
        const device = rowToDevice(row);
        if (device.sources.includes(event.sourceId)) {
          candidates.push({
            delivery: {
              device,
              tokenHash: await tokenHash(device.token),
            },
            originDeliveryIndex,
            snapshotRegistrationRevision:
              prepared.device.registrationRevision,
          });
          break;
        }
      }
    }
    const sourceConsenting = candidates;
    const current = sourceConsenting.map(({ delivery }) => delivery.device);
    const eligible = isTerminalAlertLifecycleReason(record.message.reason)
      ? await terminalAlertLifecycleDevices(this.env.DB, event.id, current)
      : current.filter((device) => shouldNotify(device, event, record.message.reason));
    const delivered = await deliveredDeviceTokens(
      this.env.DB,
      record.message.deliveryId,
      eligible.map((device) => device.token),
    );
    const quarantined = await quarantinedDeviceTokens(
      this.env.DB,
      record.message.deliveryId,
      eligible.map((device) => device.token),
    );
    const redispatchRevisions = new Set(
      eligible
        .filter((device) =>
          !delivered.has(device.token) && !quarantined.has(device.token)
        )
        .map((device) => device.registrationRevision),
    );
    return {
      sourceConsenting,
      redispatch: [
        ...new Map(
          sourceConsenting
            .filter(({ delivery }) =>
              redispatchRevisions.has(delivery.device.registrationRevision)
            )
            .map((recipient) => [
              recipient.delivery.device.registrationRevision,
              recipient,
            ] as const),
        ).values(),
      ],
    };
  }

  /**
   * Recover an admitted provider batch. Current source consent and routing
   * always win: exact-token continuity is preferred, ordinary same-key token
   * rotation is allowed, and a blocking revision fence drops the stale work.
   */
  private async recoverApnsDeliveryIntent(
    key: string,
    record: PendingApnsDeliveryIntentRecord,
  ): Promise<void> {
    const reconciled = await this.reconcileObservedApnsDeliveryIntentBatch(
      key,
      record,
      true,
    );
    if (reconciled === null) return;
    record = reconciled;
    if (
      record.observedBatch === null &&
      record.providerAttempts > 0 &&
      record.lifecycleEvidencePreparedAtUtc === record.lastProviderAttemptAtUtc &&
      !record.unobservedAttemptReconciled
    ) {
      // This serial lane can reach an admitted/no-outcome record only after the
      // original provider turn disappeared (crash/eviction). Its attempt-owned
      // possible-contact evidence is already durable, so classify the missing
      // response as unknown before honoring backoff or admitting another
      // contact. That releases event ingestion for an urgent final/cancel while
      // retaining honest conservative lifecycle continuity.
      await this.env.DB
        .prepare(
          `UPDATE apns_provider_attempts
           SET outcome_reconciled_at_utc = COALESCE(
             outcome_reconciled_at_utc, ?
           )
           WHERE attempt_id = ?`,
        )
        .bind(
          new Date().toISOString(),
          `${record.writeId}:${record.providerAttempts}`,
        )
        .run();
      let updatedRecord: PendingApnsDeliveryIntentRecord | null = null;
      await this.state.storage.transaction(async (transaction) => {
        const current = await transaction.get<unknown>(key);
        if (
          !isPendingApnsDeliveryIntentRecord(current) ||
          current.writeId !== record.writeId ||
          current.providerAttempts !== record.providerAttempts ||
          current.observedBatch !== null
        ) {
          throw new Error("APNs unknown-outcome record changed during reconciliation");
        }
        updatedRecord = { ...current, unobservedAttemptReconciled: true };
        await transaction.put(key, updatedRecord);
      });
      if (!updatedRecord) {
        throw new Error("APNs unknown-outcome reconciliation was not committed");
      }
      record = updatedRecord;
    }
    const resolution = await this.currentDevicesForApnsIntent(record);
    const outboxGate = await this.expireOutboxIfDue(record.message);
    if (outboxGate !== "pending") {
      await this.completeApnsDeliveryIntent({
        storageKey: key,
        writeId: record.writeId,
      });
      return;
    }
    const expiry = record.message.expiresAtUtc === undefined
      ? null
      : Date.parse(record.message.expiresAtUtc);
    if (expiry !== null && Number.isFinite(expiry) && Date.now() >= expiry) {
      console.warn(JSON.stringify({
        deliveryId: record.message.deliveryId,
        outcome: "expired_apns_delivery_intent_retired_with_conservative_lifecycle",
      }));
      await this.completeApnsDeliveryIntent({
        storageKey: key,
        writeId: record.writeId,
      });
      return;
    }
    const redispatchCandidates = resolution.redispatch;
    if (redispatchCandidates.length === 0) {
      await this.completeApnsDeliveryIntent({
        storageKey: key,
        writeId: record.writeId,
      });
      return;
    }
    if (
      resolution.redispatch.every((recipient) =>
        (record.recipientProviderAttempts[
          recipient.snapshotRegistrationRevision
        ] ?? 0) >= APNS_DELIVERY_INTENT_MAX_PROVIDER_ATTEMPTS
      )
    ) {
      await this.terminalizeExhaustedApnsDeliveryIntent(key, record);
      return;
    }
    const nextProviderAttemptAtMs = Date.parse(record.nextProviderAttemptAtUtc);
    if (Date.now() < nextProviderAttemptAtMs) {
      await this.scheduleRelayAlarm(nextProviderAttemptAtMs);
      // A durable conservative lifecycle row already protects this intent.
      // Defer only its provider scope; unrelated alerts, training requests,
      // terminal gates, and maintenance may continue through the serial lane.
      return;
    }
    const nowMs = Date.now();
    const retryableCandidates = redispatchCandidates.filter(({
      snapshotRegistrationRevision,
    }) =>
      (record.recipientProviderAttempts[snapshotRegistrationRevision] ?? 0) <
        APNS_DELIVERY_INTENT_MAX_PROVIDER_ATTEMPTS
    );
    const deliveries = retryableCandidates.filter(({
      snapshotRegistrationRevision,
    }) => {
      const retryAt = record.recipientRetryNotBeforeUtc[
        snapshotRegistrationRevision
      ];
      return (
        (retryAt === undefined || Date.parse(retryAt) <= nowMs)
      );
    });
    if (deliveries.length === 0) {
      const earliestRecipientRetry = Math.min(
        ...retryableCandidates.map(({ snapshotRegistrationRevision }) =>
          Date.parse(
            record.recipientRetryNotBeforeUtc[snapshotRegistrationRevision] ??
              record.nextProviderAttemptAtUtc,
          )
        ),
      );
      await this.scheduleRelayAlarm(earliestRecipientRetry);
      return;
    }
    const event = eventFromDeliveryMessage(record.message);
    const authorization = await this.apnsAuthorization();
    const collapseId = await apnsCollapseID(event);
    const contactedRecipients = await this.admitApnsProviderAttempt(
      { storageKey: key, writeId: record.writeId },
      record.message,
      deliveries,
    );
    if (contactedRecipients.length === 0) return;
    const results = await Promise.allSettled(
      contactedRecipients.map(({ delivery: { device } }) =>
        sendPushRequest(
          this.env,
          device,
          event,
          record.message.reason,
          authorization,
          collapseId,
        )
      ),
    );
    const observedAtUtc = new Date().toISOString();
    await this.persistApnsDeliveryIntentObservedBatch(
      { storageKey: key, writeId: record.writeId },
      observedAtUtc,
      contactedRecipients,
      results.map(durableApnsResult),
    );
    const observedRecord = await this.state.storage.get<unknown>(key);
    if (
      !isPendingApnsDeliveryIntentRecord(observedRecord) ||
      observedRecord.writeId !== record.writeId ||
      observedRecord.observedBatch?.observedAtUtc !== observedAtUtc
    ) {
      throw new Error("APNs recovery outcomes were not durably journaled");
    }
    await this.reconcileObservedApnsDeliveryIntentBatch(
      key,
      observedRecord,
      true,
    );
  }

  /**
   * Rolling-deploy compatibility for version-1 post-2xx records. New delivery
   * uses the version-2 pre-send intent above, but an older isolate can still
   * write this shape while the deployment converges.
   */
  private async persistApnsAcceptedBatch(
    deliveryId: string,
    eventRef: string,
    sourceId: ApnsRelaySourceId,
    reason: NotifyReason,
    deliveries: AcceptedDelivery[],
  ): Promise<void> {
    if (
      deliveries.length < 1 ||
      deliveries.length > APNS_MAX_CONCURRENT_DELIVERIES
    ) {
      throw new RangeError("APNs acceptance journal batch is out of bounds");
    }
    const evidence: AcceptedDeliveryEvidence[] = deliveries.map((delivery) => ({
      token: delivery.device.token,
      tokenHash: delivery.tokenHash,
      snapshotRegistrationRevision: delivery.device.registrationRevision,
      snapshotAppAttestKeyId: delivery.device.appAttestKeyId,
      firstAcceptedAtUtc: delivery.acceptedAtUtc,
      lastAcceptedAtUtc: delivery.acceptedAtUtc,
    }));
    const key = await apnsAcceptanceJournalStorageKey(
      deliveryId,
      eventRef,
      sourceId,
      reason,
      evidence,
    );
    await this.ensureApnsAcceptanceJournalCapacity(key);
    const now = new Date().toISOString();
    let storedRecord: PendingApnsAcceptanceRecord | null = null;
    await this.state.storage.transaction(async (transaction) => {
      const current = await transaction.get<unknown>(key);
      if (current !== undefined && !isPendingApnsAcceptanceRecord(current)) {
        throw new Error("APNs acceptance journal record is invalid");
      }
      const existing = current as PendingApnsAcceptanceRecord | undefined;
      if (
        existing &&
        (existing.deliveryId !== deliveryId ||
          existing.eventRef !== eventRef ||
          existing.sourceId !== sourceId ||
          existing.reason !== reason)
      ) {
        throw new Error("APNs acceptance journal identity collision");
      }
      const merged = new Map<string, AcceptedDeliveryEvidence>(
        (existing?.deliveries ?? []).map((delivery) => [
          `${delivery.tokenHash}\u0000${delivery.snapshotRegistrationRevision}`,
          delivery,
        ]),
      );
      for (const delivery of evidence) {
        const evidenceKey =
          `${delivery.tokenHash}\u0000${delivery.snapshotRegistrationRevision}`;
        const prior = merged.get(evidenceKey);
        merged.set(evidenceKey, prior
          ? {
              ...delivery,
              snapshotAppAttestKeyId:
                delivery.snapshotAppAttestKeyId ??
                prior.snapshotAppAttestKeyId,
              firstAcceptedAtUtc:
                Date.parse(prior.firstAcceptedAtUtc) <
                    Date.parse(delivery.firstAcceptedAtUtc)
                  ? prior.firstAcceptedAtUtc
                  : delivery.firstAcceptedAtUtc,
              lastAcceptedAtUtc:
                Date.parse(prior.lastAcceptedAtUtc) >
                    Date.parse(delivery.lastAcceptedAtUtc)
                  ? prior.lastAcceptedAtUtc
                  : delivery.lastAcceptedAtUtc,
            }
          : delivery);
      }
      storedRecord = {
        version: 1,
        writeId: crypto.randomUUID(),
        deliveryId,
        eventRef,
        sourceId,
        reason,
        createdAtUtc: existing?.createdAtUtc ?? now,
        deliveries: [...merged.values()],
      };
      if (!isPendingApnsAcceptanceRecord(storedRecord)) {
        throw new Error("APNs acceptance journal record exceeds its bounds");
      }
      await transaction.put(key, storedRecord);
    });
    if (!storedRecord) throw new Error("APNs acceptance journal write failed");
    // The transaction callback assigns this only after validating and storing
    // the bounded record; the guard above establishes the runtime invariant.
    const committedRecord = storedRecord as PendingApnsAcceptanceRecord;
    await this.scheduleRelayAlarm(Date.now() + PENDING_INGEST_RETRY_DELAY_MS);
    await recordDeliveredDevices(
      this.env.DB,
      deliveryId,
      eventRef,
      sourceId,
      reason,
      committedRecord.deliveries,
      true,
    );
    const committedWriteId = committedRecord.writeId;
    await this.state.storage.transaction(async (transaction) => {
      const current = await transaction.get<unknown>(key);
      if (
        isPendingApnsAcceptanceRecord(current) &&
        current.writeId === committedWriteId
      ) {
        await transaction.delete(key);
      }
    });
  }

  /**
   * Reconcile both pre-send intents and rolling version-1 accepted batches
   * before any outbox terminal gate. Valid pre-send work is redispatched from
   * the current consenting registration; malformed records remain visible and
   * fail closed for operator repair.
   */
  private async apnsDurabilityMaintenanceOwnsInvocation(): Promise<boolean> {
    const database = this.env.DB;
    if (
      !database ||
      typeof database.prepare !== "function" ||
      typeof database.batch !== "function"
    ) {
      return false;
    }
    const crashedTrainingCutoff = new Date(
      Date.now() - TRAINING_APNS_ATTEMPT_RECOVERY_MS,
    ).toISOString();
    let pendingStatement: D1PreparedStatement;
    try {
      pendingStatement = database
        .prepare(
          `SELECT (
           EXISTS (SELECT 1 FROM legacy_device_removal_tokens)
           OR EXISTS (
             SELECT 1 FROM notification_deliveries
             WHERE lifecycle_reconciled = 0
           )
           OR EXISTS (
             SELECT 1 FROM apns_provider_attempts
             WHERE attempt_id LIKE 'training:%'
               AND outcome_reconciled_at_utc IS NULL
               AND admitted_at_utc <= ?
           )
         ) AS pending`,
          )
        .bind(crashedTrainingCutoff);
    } catch {
      return false;
    }
    if (typeof pendingStatement.first !== "function") return false;
    const d1Pending = await pendingStatement.first<number>("pending");
    if ((d1Pending ?? 0) !== 0) return true;
    const pending = await this.state.storage.list<unknown>({
      prefix: APNS_ACCEPTANCE_JOURNAL_PREFIX,
      limit: APNS_ACCEPTANCE_JOURNAL_MAX_RECORDS + 1,
    });
    const now = Date.now();
    for (const value of pending.values()) {
      if (!isPendingApnsDeliveryIntentRecord(value)) return true;
      if (value.observedBatch !== null) return true;
      if (
        value.lifecycleEvidencePreparedAtUtc === value.lastProviderAttemptAtUtc &&
        !value.unobservedAttemptReconciled
      ) return true;
      const createdAt = Date.parse(value.createdAtUtc);
      if (
        !Number.isFinite(createdAt) ||
        now - createdAt > APNS_ACCEPTANCE_JOURNAL_MAX_AGE_MS
      ) return true;
      if (now >= Date.parse(value.nextProviderAttemptAtUtc)) return true;
    }
    return false;
  }

  private async reconcileApnsAcceptanceJournal(
    limit = APNS_ACCEPTANCE_JOURNAL_REPLAY_BATCH_SIZE,
  ): Promise<boolean> {
    if (
      !Number.isSafeInteger(limit) ||
      limit < 1 ||
      limit > APNS_ACCEPTANCE_JOURNAL_REPLAY_BATCH_SIZE
    ) {
      throw new RangeError(
        "APNs acceptance journal replay limit must be a positive bounded safe integer",
      );
    }
    const database = this.env.DB;
    const d1MaintenanceAvailable = Boolean(
      database &&
      typeof database.prepare === "function" &&
      typeof database.batch === "function"
    );
    const pending = await this.state.storage.list<unknown>({
      prefix: APNS_ACCEPTANCE_JOURNAL_PREFIX,
      limit: APNS_ACCEPTANCE_JOURNAL_MAX_RECORDS + 1,
    });
    if (!d1MaintenanceAvailable) {
      // Storage-only harnesses still exercise the journal's fail-closed
      // integrity boundary. Validate every visible record before declining
      // D1 work; malformed or tampered evidence must never disappear merely
      // because a maintenance caller lacks a database binding.
      for (const [key, value] of pending) {
        if (isPendingApnsDeliveryIntentRecord(value)) {
          const computedTokenHashes = await Promise.all(
            value.deliveries.map((delivery) => tokenHash(delivery.device.token)),
          );
          const expectedKey = await apnsDeliveryIntentStorageKey(
            value.message,
            value.deliveries,
          );
          const observedTokenHashes = value.observedBatch === null
            ? []
            : await Promise.all(
                value.observedBatch.deliveries.map(({ delivery }) =>
                  tokenHash(delivery.device.token)
                ),
              );
          const intentMismatch = expectedKey !== key ||
            value.deliveries.some((delivery, index) =>
              delivery.tokenHash !== computedTokenHashes[index]
            ) ||
            (value.observedBatch !== null &&
              value.observedBatch.deliveries.some((recipient, index) => {
                const original = value.deliveries[recipient.originDeliveryIndex];
                const delivery = recipient.delivery;
                return delivery.tokenHash !== observedTokenHashes[index] ||
                  original === undefined ||
                  original.device.registrationRevision !==
                    recipient.snapshotRegistrationRevision ||
                  (original.device.token !== delivery.device.token &&
                    (original.device.appAttestKeyId === null ||
                      original.device.appAttestKeyId !==
                        delivery.device.appAttestKeyId));
              }));
          if (intentMismatch) {
            await this.scheduleRelayAlarm(
              Date.now() + PENDING_INGEST_RETRY_DELAY_MS,
            );
            throw new Error("APNs delivery intent integrity check failed");
          }
          continue;
        }
        if (!isPendingApnsAcceptanceRecord(value)) {
          await this.scheduleRelayAlarm(
            Date.now() + PENDING_INGEST_RETRY_DELAY_MS,
          );
          throw new Error("APNs acceptance journal record is invalid");
        }
        const computedTokenHashes = await Promise.all(
          value.deliveries.map((delivery) => tokenHash(delivery.token)),
        );
        const expectedKey = await apnsAcceptanceJournalStorageKey(
          value.deliveryId,
          value.eventRef,
          value.sourceId,
          value.reason,
          value.deliveries,
        );
        if (
          expectedKey !== key ||
          value.deliveries.some((delivery, index) =>
            delivery.tokenHash !== computedTokenHashes[index]
          )
        ) {
          await this.scheduleRelayAlarm(
            Date.now() + PENDING_INGEST_RETRY_DELAY_MS,
          );
          throw new Error("APNs acceptance journal integrity check failed");
        }
      }
      return false;
    }
    const crashedTrainingCutoff = new Date(
      Date.now() - TRAINING_APNS_ATTEMPT_RECOVERY_MS,
    ).toISOString();
    let releaseTrainingAttempts: D1PreparedStatement;
    let pendingRemovalStatement: D1PreparedStatement;
    try {
      releaseTrainingAttempts = database
        .prepare(
          `UPDATE apns_provider_attempts
           SET outcome_reconciled_at_utc = admitted_at_utc
           WHERE attempt_id LIKE 'training:%'
             AND outcome_reconciled_at_utc IS NULL
             AND admitted_at_utc <= ?`,
        )
        .bind(crashedTrainingCutoff);
      pendingRemovalStatement = database
        .prepare("SELECT 1 AS pending FROM legacy_device_removal_tokens LIMIT 1")
        .bind();
    } catch {
      return false;
    }
    if (
      typeof releaseTrainingAttempts.run !== "function" ||
      typeof pendingRemovalStatement.first !== "function" ||
      typeof pendingRemovalStatement.all !== "function"
    ) {
      return false;
    }
    const releasedTrainingAttempts = await releaseTrainingAttempts.run();
    if ((releasedTrainingAttempts.meta.changes ?? 0) > 0) {
      // A provider request is bounded to twenty seconds. After one minute an
      // unresolved training marker can only be a crashed/evicted call; release
      // its mutation fence without fabricating APNs success or token cleanup.
      await this.scheduleRelayAlarm(Date.now() + PENDING_INGEST_RETRY_DELAY_MS);
      return true;
    }
    const pendingRemoval = await pendingRemovalStatement.first<{ pending: number }>();
    if (pendingRemoval) {
      await this.reconcileLegacyDeviceRemovals();
      // Even a fully drained slice owns this invocation's D1 budget. A later
      // alarm/Queue turn may reconcile provider outcomes or legacy acceptance;
      // never compose all three maintenance classes under the Free-plan cap.
      await this.scheduleRelayAlarm(Date.now() + PENDING_INGEST_RETRY_DELAY_MS);
      return true;
    }
    // Inspect the complete bounded journal so a hash-ordered, not-yet-due
    // intent cannot hide an independent due record or malformed evidence.
    // Provider/D1 work remains capped by `limit`; Durable Object reads do not
    // consume the Worker's D1 subrequest budget.
    let replayed = 0;
    let maintenancePerformed = false;
    for (const [key, value] of pending) {
      if (isPendingApnsDeliveryIntentRecord(value)) {
        const computedTokenHashes = await Promise.all(
          value.deliveries.map((delivery) => tokenHash(delivery.device.token)),
        );
        const observedTokenHashes = value.observedBatch === null
          ? []
          : await Promise.all(
              value.observedBatch.deliveries.map(({ delivery }) =>
                tokenHash(delivery.device.token)
              ),
            );
        const expectedKey = await apnsDeliveryIntentStorageKey(
          value.message,
          value.deliveries,
        );
        if (
          expectedKey !== key ||
          value.deliveries.some((delivery, index) =>
            delivery.tokenHash !== computedTokenHashes[index]
          ) ||
          (value.observedBatch !== null &&
            value.observedBatch.deliveries.some((recipient, index) => {
              const delivery = recipient.delivery;
              const hashMatches = delivery.tokenHash === observedTokenHashes[index];
              const original = value.deliveries[recipient.originDeliveryIndex];
              const belongsToOriginalLineage = original !== undefined &&
                original.device.registrationRevision ===
                  recipient.snapshotRegistrationRevision &&
                (original.device.token === delivery.device.token ||
                  (original.device.appAttestKeyId !== null &&
                    original.device.appAttestKeyId ===
                      delivery.device.appAttestKeyId));
              return !hashMatches || !belongsToOriginalLineage;
            }))
        ) {
          console.error(JSON.stringify({
            journalKey: key,
            deliveryId: value.message.deliveryId,
            outcome: "apns_delivery_intent_integrity_mismatch_preserved",
          }));
          await this.scheduleRelayAlarm(
            Date.now() + PENDING_INGEST_RETRY_DELAY_MS,
          );
          throw new Error("APNs delivery intent integrity check failed");
        }
        // A captured provider outcome is stronger than the generic age or
        // backoff policy. Reconcile 2xx, terminal-token cleanup, quarantine,
        // and page evidence first; any D1 failure preserves the raw record
        // and blocks its retirement rather than degrading it to mere unknown
        // lifecycle evidence.
        if (value.observedBatch !== null) {
          if (replayed >= limit) {
            await this.scheduleRelayAlarm(
              Date.now() + PENDING_INGEST_RETRY_DELAY_MS,
            );
            continue;
          }
          replayed += 1;
          await this.recoverApnsDeliveryIntent(key, value);
          maintenancePerformed = true;
          continue;
        }
        const createdAtMs = Date.parse(value.createdAtUtc);
        if (
          !Number.isFinite(createdAtMs) ||
          Date.now() - createdAtMs > APNS_ACCEPTANCE_JOURNAL_MAX_AGE_MS
        ) {
          console.error(JSON.stringify({
            journalKey: key,
            deliveryId: value.message.deliveryId,
            outcome:
              "aged_apns_delivery_intent_retired_with_conservative_lifecycle",
          }));
          await this.completeApnsDeliveryIntent({
            storageKey: key,
            writeId: value.writeId,
          });
          maintenancePerformed = true;
          continue;
        }
        const retryAtMs = Date.parse(value.nextProviderAttemptAtUtc);
        if (
          value.lifecycleEvidencePreparedAtUtc ===
            value.lastProviderAttemptAtUtc &&
          value.unobservedAttemptReconciled &&
          Date.now() < retryAtMs
        ) {
          await this.scheduleRelayAlarm(retryAtMs);
          continue;
        }
        if (replayed >= limit) {
          await this.scheduleRelayAlarm(
            Math.min(
              retryAtMs,
              Date.now() + PENDING_INGEST_RETRY_DELAY_MS,
            ),
          );
          continue;
        }
        replayed += 1;
        await this.recoverApnsDeliveryIntent(key, value);
        maintenancePerformed = true;
        continue;
      }
      if (!isPendingApnsAcceptanceRecord(value)) {
        console.error(JSON.stringify({
          journalKey: key,
          outcome: "invalid_apns_acceptance_journal_preserved",
        }));
        await this.scheduleRelayAlarm(
          Date.now() + PENDING_INGEST_RETRY_DELAY_MS,
        );
        throw new Error("APNs acceptance journal record is invalid");
      }
      const computedTokenHashes = await Promise.all(
        value.deliveries.map((delivery) => tokenHash(delivery.token)),
      );
      const expectedKey = await apnsAcceptanceJournalStorageKey(
        value.deliveryId,
        value.eventRef,
        value.sourceId,
        value.reason,
        value.deliveries,
      );
      if (
        expectedKey !== key ||
        value.deliveries.some((delivery, index) =>
          delivery.tokenHash !== computedTokenHashes[index]
        )
      ) {
        console.error(JSON.stringify({
          journalKey: key,
          deliveryId: value.deliveryId,
          outcome: "apns_acceptance_journal_integrity_mismatch_preserved",
        }));
        await this.scheduleRelayAlarm(
          Date.now() + PENDING_INGEST_RETRY_DELAY_MS,
        );
        throw new Error("APNs acceptance journal integrity check failed");
      }
      const createdAtMs = Date.parse(value.createdAtUtc);
      if (
        !Number.isFinite(createdAtMs) ||
        Date.now() - createdAtMs > APNS_ACCEPTANCE_JOURNAL_MAX_AGE_MS
      ) {
        console.error(JSON.stringify({
          journalKey: key,
          deliveryId: value.deliveryId,
          outcome: "expired_apns_acceptance_journal_removed",
        }));
        await this.state.storage.delete(key);
        maintenancePerformed = true;
        continue;
      }
      if (replayed >= limit) continue;
      replayed += 1;
      maintenancePerformed = true;
      try {
        await recordDeliveredDevices(
          this.env.DB,
          value.deliveryId,
          value.eventRef,
          value.sourceId,
          value.reason,
          value.deliveries,
          false,
        );
      } catch (error) {
        console.error(JSON.stringify({
          deliveryId: value.deliveryId,
          outcome: "apns_acceptance_journal_d1_retry",
          errorName: error instanceof Error ? error.name : "UnknownError",
        }));
        await this.scheduleRelayAlarm(
          Date.now() + PENDING_INGEST_RETRY_DELAY_MS,
        );
        throw error;
      }
      await this.state.storage.transaction(async (transaction) => {
        const current = await transaction.get<unknown>(key);
        if (
          isPendingApnsAcceptanceRecord(current) &&
          current.writeId === value.writeId
        ) {
          await transaction.delete(key);
        }
      });
    }
    const remaining = await this.state.storage.list<unknown>({
      prefix: APNS_ACCEPTANCE_JOURNAL_PREFIX,
      limit: APNS_ACCEPTANCE_JOURNAL_MAX_RECORDS + 1,
    });
    // Version-2 intents have already crossed the conservative lifecycle
    // boundary before any provider contact. They may wait independently for
    // their durable retry gate without blocking unrelated work. Version-1
    // accepted batches and malformed records still fail closed globally until
    // their known APNs acceptance is reconciled or repaired.
    const blockingRemaining = [...remaining.values()].some((value) =>
      !isPendingApnsDeliveryIntentRecord(value) ||
      value.observedBatch !== null ||
      value.lifecycleEvidencePreparedAtUtc !== value.lastProviderAttemptAtUtc
    );
    if (blockingRemaining) {
      await this.scheduleRelayAlarm(
        Date.now() + PENDING_INGEST_RETRY_DELAY_MS,
      );
      throw new Error("APNs acceptance journal replay remains pending");
    }
    if (maintenancePerformed) {
      await this.scheduleRelayAlarm(Date.now() + PENDING_INGEST_RETRY_DELAY_MS);
      return true;
    }
    return this.reconcileLegacyAcceptedLifecycle();
  }

  /**
   * Hash and retire raw-token consent-removal handoffs created by SQL-only
   * rolling-deploy triggers or stale-device cleanup. D1/SQLite has no SHA-256,
   * so this bounded table is the only way to join an unbound token's lifecycle
   * pseudonym without retaining the subscription itself. Alert/journal work is
   * blocked until every row is converted and the raw token is deleted.
   */
  private async reconcileLegacyDeviceRemovals(limit = 8): Promise<void> {
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 8) {
      throw new RangeError(
        "legacy device-removal replay limit must be a positive bounded safe integer",
      );
    }
    const pending = await this.env.DB
      .prepare(
        `SELECT token, registration_revision, app_attest_key_id,
                decision_kind, removed_at_utc
         FROM legacy_device_removal_tokens
         ORDER BY removed_at_utc ASC, token ASC
         LIMIT ?`,
      )
      .bind(limit)
      .all<{
        token: string;
        registration_revision: string;
        app_attest_key_id: string | null;
        decision_kind: "empty_source_removal" | "stale_registration_retention";
        removed_at_utc: string;
      }>();
    if (pending.results.length === 0) return;
    const removals = await Promise.all(pending.results.map(async (row) => ({
      token: row.token,
      tokenHash: await tokenHash(row.token),
      registrationRevision: row.registration_revision,
      appAttestKeyId: row.app_attest_key_id,
      decisionKind: row.decision_kind,
      removedAtUtc: row.removed_at_utc,
    })));
    const removalsJson = JSON.stringify(removals);
    const now = new Date().toISOString();
    const removalCte = `WITH removals AS (
      SELECT
        json_extract(value, '$.token') AS token,
        json_extract(value, '$.tokenHash') AS token_hash,
        json_extract(value, '$.registrationRevision') AS registration_revision,
        json_extract(value, '$.appAttestKeyId') AS app_attest_key_id,
        json_extract(value, '$.decisionKind') AS decision_kind,
        json_extract(value, '$.removedAtUtc') AS removed_at_utc
      FROM json_each(?)
    )`;
    // Deliberately do not mark `apns_provider_attempts` reconciled here. A
    // provider outcome may already be durable in the DO journal; consent
    // removal blocks lifecycle replay, but that observed 2xx/410/BDT/page
    // result must still reach its idempotent D1 reconciliation owner before
    // terminal/outbox work can proceed.
    await this.env.DB.batch([
      this.env.DB
        .prepare(
          `${removalCte}
           UPDATE apns_registration_revision_fences
           SET decision_kind = COALESCE((
                 SELECT removal.decision_kind FROM removals AS removal
                 WHERE removal.registration_revision =
                         apns_registration_revision_fences.registration_revision
                    OR removal.token_hash =
                      apns_registration_revision_fences.token_hash
                    OR (
                      removal.app_attest_key_id IS NOT NULL AND
                      removal.app_attest_key_id =
                        apns_registration_revision_fences.app_attest_key_id
                    )
                 LIMIT 1
               ), decision_kind),
               token_hash = COALESCE(token_hash, (
                 SELECT removal.token_hash FROM removals AS removal
                 WHERE removal.registration_revision =
                         apns_registration_revision_fences.registration_revision
                    OR (
                      removal.app_attest_key_id IS NOT NULL AND
                      removal.app_attest_key_id =
                        apns_registration_revision_fences.app_attest_key_id
                    )
                 LIMIT 1
               )),
               blocks_lifecycle_replay = 1,
               processed_at_utc = MAX(processed_at_utc, ?)
           WHERE EXISTS (
             SELECT 1 FROM removals AS removal
             WHERE removal.registration_revision =
                     apns_registration_revision_fences.registration_revision
                OR removal.token_hash =
                  apns_registration_revision_fences.token_hash
                OR (
                  removal.app_attest_key_id IS NOT NULL AND
                  removal.app_attest_key_id =
                    apns_registration_revision_fences.app_attest_key_id
                )
           )`,
        )
        .bind(removalsJson, now),
      this.env.DB
        .prepare(
          `${removalCte}
           INSERT INTO apns_registration_revision_fences (
             registration_revision, token_hash, app_attest_key_id,
             decision_id, decision_kind,
             blocks_lifecycle_replay, processed_at_utc
           )
           SELECT registration_revision, token_hash, app_attest_key_id,
                  lower(hex(randomblob(16))), decision_kind, 1,
                  MAX(removed_at_utc, ?)
           FROM removals WHERE 1
           ON CONFLICT(registration_revision) DO UPDATE SET
             token_hash = COALESCE(
               apns_registration_revision_fences.token_hash,
               excluded.token_hash
             ),
             app_attest_key_id = COALESCE(
               apns_registration_revision_fences.app_attest_key_id,
               excluded.app_attest_key_id
             ),
             decision_kind = excluded.decision_kind,
             blocks_lifecycle_replay = 1,
             processed_at_utc = MAX(
               apns_registration_revision_fences.processed_at_utc,
               excluded.processed_at_utc
             )`,
        )
        .bind(removalsJson, now),
      this.env.DB
        .prepare(
          `${removalCte}
           DELETE FROM alert_lifecycle_recipients
           WHERE EXISTS (
             SELECT 1 FROM removals AS removal
             WHERE removal.token_hash = alert_lifecycle_recipients.token_hash
                OR (
                  removal.app_attest_key_id IS NOT NULL AND
                  removal.app_attest_key_id =
                    alert_lifecycle_recipients.app_attest_key_id
                )
           )`,
        )
        .bind(removalsJson),
      this.env.DB
        .prepare(
          `${removalCte}
           DELETE FROM alert_lifecycle_possible_attempts
           WHERE EXISTS (
             SELECT 1 FROM removals AS removal
             WHERE removal.token_hash =
                   alert_lifecycle_possible_attempts.token_hash
                OR (
                  removal.app_attest_key_id IS NOT NULL AND
                  removal.app_attest_key_id =
                    alert_lifecycle_possible_attempts.app_attest_key_id
                )
           )`,
        )
        .bind(removalsJson),
      this.env.DB
        .prepare(
          `${removalCte}
           DELETE FROM alert_delivery_failures
           WHERE token_hash IN (SELECT token_hash FROM removals)`,
        )
        .bind(removalsJson),
      this.env.DB
        .prepare(
          `${removalCte}
           DELETE FROM notification_deliveries
           WHERE device_token IN (SELECT token FROM removals)`,
        )
        .bind(removalsJson),
      this.env.DB
        .prepare(
          `${removalCte}
           DELETE FROM legacy_device_removal_tokens
           WHERE EXISTS (
             SELECT 1 FROM removals AS removal
             WHERE removal.token = legacy_device_removal_tokens.token
               AND removal.registration_revision =
                 legacy_device_removal_tokens.registration_revision
           )`,
        )
        .bind(removalsJson),
    ]);
    const remaining = await this.env.DB
      .prepare("SELECT 1 AS pending FROM legacy_device_removal_tokens LIMIT 1")
      .first<{ pending: number }>();
    if (remaining) {
      await this.scheduleRelayAlarm(Date.now() + PENDING_INGEST_RETRY_DELAY_MS);
      throw new Error("legacy device-removal reconciliation remains pending");
    }
  }

  /**
   * During a rolling deploy an older Worker can still write only the legacy
   * notification-delivery row after migration 0013. Convert a bounded slice
   * into the new lifecycle evidence before any terminal gate proceeds.
   */
  private async reconcileLegacyAcceptedLifecycle(limit = 4): Promise<boolean> {
    const pending = await this.env.DB
      .prepare(
        `SELECT nd.delivery_id, nd.device_token, nd.delivered_at_utc,
                outbox.event_ref, outbox.notification_reason
         FROM notification_deliveries AS nd
         LEFT JOIN alert_delivery_outbox AS outbox
           ON outbox.delivery_id = nd.delivery_id
         WHERE nd.lifecycle_reconciled = 0
         ORDER BY nd.delivered_at_utc ASC
         LIMIT ?`,
      )
      .bind(limit)
      .all<{
        delivery_id: string;
        device_token: string;
        delivered_at_utc: string;
        event_ref: string | null;
        notification_reason: NotifyReason | null;
    }>();
    for (const row of pending.results) {
      const separator = row.event_ref?.indexOf(":") ?? -1;
      const source = separator > 0
        ? row.event_ref?.slice(0, separator)
        : null;
      const legacyTokenHash = await tokenHash(row.device_token);
      const deviceRow = await this.env.DB
        .prepare(
          `SELECT * FROM devices
           WHERE (
             token = ?
             AND NOT EXISTS (
               SELECT 1 FROM apns_registration_revision_fences
               WHERE token_hash = ? AND blocks_lifecycle_replay = 1
                 AND decision_kind IN (
                   'explicit_removal', 'empty_source_removal',
                   'stale_registration_retention'
                 )
             )
           ) OR app_attest_key_id IN (
             SELECT app_attest_key_id
             FROM apns_registration_revision_fences
             WHERE token_hash = ?
               AND app_attest_key_id IS NOT NULL
               AND NOT (
                 blocks_lifecycle_replay = 1
                 AND decision_kind IN (
                   'explicit_removal', 'empty_source_removal',
                   'stale_registration_retention'
                 )
               )
           )
           ORDER BY CASE WHEN token = ? THEN 0 ELSE 1 END, updated_at DESC
           LIMIT 1`,
        )
        .bind(
          row.device_token,
          legacyTokenHash,
          legacyTokenHash,
          row.device_token,
        )
        .first<DeviceRow>();
      if (
        row.event_ref !== null &&
        (row.notification_reason === "new" ||
          row.notification_reason === "updated") &&
        isApnsRelaySource(source) &&
        deviceRow !== null
      ) {
        const device = rowToDevice(deviceRow);
        if (device.sources.includes(source)) {
          await recordDeliveredDevices(
            this.env.DB,
            row.delivery_id,
            row.event_ref,
            source,
            row.notification_reason,
            [{
              token: device.token,
              tokenHash: await tokenHash(device.token),
              snapshotRegistrationRevision: device.registrationRevision,
              snapshotAppAttestKeyId: device.appAttestKeyId,
              firstAcceptedAtUtc: row.delivered_at_utc,
              lastAcceptedAtUtc: row.delivered_at_utc,
            }],
            false,
          );
        }
      }
      // A non-active reason, missing historical outbox, removed device, or
      // current source opt-out needs no lifecycle row. Mark only if the exact
      // legacy delivery still exists; explicit deletion may have removed it.
      await this.env.DB
        .prepare(
          `UPDATE notification_deliveries
           SET lifecycle_reconciled = 1
           WHERE delivery_id = ? AND device_token = ?
             AND lifecycle_reconciled = 0
             AND (
               ? NOT IN ('new', 'updated')
               OR ? IS NULL
               OR NOT EXISTS (
                 SELECT 1 FROM devices WHERE token = ?
               )
               OR EXISTS (
                 SELECT 1 FROM apns_registration_revision_fences
                 WHERE token_hash = ? AND blocks_lifecycle_replay = 1
               )
               OR NOT EXISTS (
                 SELECT 1 FROM json_each(
                   CASE WHEN json_valid((
                     SELECT sources FROM devices WHERE token = ?
                   )) THEN (
                     SELECT sources FROM devices WHERE token = ?
                   ) ELSE '[]' END
                 ) WHERE value = ?
               )
             )`,
        )
        .bind(
          row.delivery_id,
          row.device_token,
          row.notification_reason,
          row.event_ref,
          row.device_token,
          legacyTokenHash,
          row.device_token,
          row.device_token,
          source,
        )
        .run();
    }
    const remaining = await this.env.DB
      .prepare(
        `SELECT 1 AS pending FROM notification_deliveries
         WHERE lifecycle_reconciled = 0 LIMIT 1`,
      )
      .first<{ pending: number }>();
    if (remaining) {
      await this.scheduleRelayAlarm(Date.now() + PENDING_INGEST_RETRY_DELAY_MS);
      throw new Error("legacy accepted lifecycle reconciliation remains pending");
    }
    return pending.results.length > 0;
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
        await this.scheduleRelayAlarm(
          Date.now() + PENDING_INGEST_RETRY_DELAY_MS,
        );
        throw new Error("DLQ persistence fallback record is invalid");
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
        throw error;
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
    const remaining = await this.state.storage.list({
      prefix: DLQ_PERSISTENCE_FALLBACK_PREFIX,
      limit: 1,
    });
    if (remaining.size > 0) {
      // More than one bounded replay slice remains. Do not let normal outbox
      // maintenance re-enqueue, expire, or supersede those canonical terminal
      // rows until every durable DLQ decision has crossed D1.
      await this.scheduleRelayAlarm(
        Date.now() + PENDING_INGEST_RETRY_DELAY_MS,
      );
      throw new Error("DLQ persistence fallback replay remains pending");
    }
  }

  private async migrateLegacyPendingDeliveries(): Promise<void> {
    const pending = await this.state.storage.list<unknown>({
      prefix: LEGACY_PENDING_DELIVERY_PREFIX,
      limit: OUTBOX_REPLAY_BATCH_SIZE,
    });
    for (const [key, value] of pending) {
      const disabledSource = value && typeof value === "object" &&
          !Array.isArray(value) && "event" in value &&
          (value as { event?: unknown }).event &&
          typeof (value as { event?: unknown }).event === "object"
        ? ((value as { event: { sourceId?: unknown } }).event.sourceId)
        : null;
      if (isDisabledApnsRelaySource(disabledSource)) {
        await this.state.storage.delete(key);
        console.info(JSON.stringify({
          sourceId: disabledSource,
          outcome: "disabled_source_legacy_outbox_superseded",
        }));
        continue;
      }
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
    const remaining = await this.state.storage.list({
      prefix: LEGACY_PENDING_DELIVERY_PREFIX,
      limit: 1,
    });
    if (remaining.size > 0) {
      await this.scheduleRelayAlarm(Date.now() + PENDING_INGEST_RETRY_DELAY_MS);
    }
  }

  /**
   * A hit proves this exact normalized point event already crossed D1 during
   * this relay instance. Move it to the LRU tail without touching Durable
   * Object storage; source freshness still follows the normal paced checkpoint
   * path below.
   */
  private hasCommittedLiveEventFingerprint(fingerprint: string): boolean {
    if (!this.committedLiveEventFingerprints.has(fingerprint)) return false;
    this.committedLiveEventFingerprints.delete(fingerprint);
    this.committedLiveEventFingerprints.set(fingerprint, true);
    return true;
  }

  private rememberCommittedLiveEventFingerprint(fingerprint: string): void {
    this.committedLiveEventFingerprints.delete(fingerprint);
    this.committedLiveEventFingerprints.set(fingerprint, true);
    while (
      this.committedLiveEventFingerprints.size >
      RECENT_COMMITTED_LIVE_EVENT_FINGERPRINT_LIMIT
    ) {
      const oldest = this.committedLiveEventFingerprints.keys().next().value;
      if (oldest === undefined) return;
      this.committedLiveEventFingerprints.delete(oldest);
    }
  }

  /**
   * Persist live events before D1 ingestion. There is one coalescing journal
   * key per source/event so a burst of revisions retains the highest serial;
   * `writeId` prevents a drain of an older snapshot from deleting a newer one.
   */
  private async enqueueLiveIngest(
    event: NormalizedEvent,
    readinessCandidate?: UpstreamDataReadinessCandidate,
  ): Promise<void> {
    if (!isApnsRelaySource(event.sourceId)) {
      console.error(JSON.stringify({
        sourceId: event.sourceId,
        outcome: "disabled_source_live_ingest_rejected",
      }));
      return;
    }
    const { raw: _raw, ...snapshot } = event;
    const key = `${PENDING_INGEST_PREFIX}${event.sourceId}:${encodeURIComponent(event.id)}`;
    const fingerprint = await liveEventFingerprint(snapshot);
    // Do not treat an in-memory sighting as proof. This cache is populated
    // only after a D1 event/outbox transaction and its corresponding durable
    // journal delete both succeed. A cache hit can skip journal churn, but it
    // still takes the normal fail-closed freshness path.
    if (this.hasCommittedLiveEventFingerprint(fingerprint)) {
      if (readinessCandidate) readinessCandidate.durableIntentRecorded = true;
      await this.markSourceSuccessfulAndPublishReadiness(event.sourceId);
      return;
    }
    const record: PendingIngestRecord = {
      event: snapshot,
      writeId: crypto.randomUUID(),
      fingerprint,
    };
    try {
      const journalOutcome = await this.state.storage.transaction(async (transaction) => {
        const current = await transaction.get<PendingIngestRecord>(key);
        if (
          isPendingIngestRecord(current) &&
          (
            current.fingerprint === fingerprint ||
            // A relay updated in place can still find a pre-fingerprint record
            // from the immediately preceding revision. It is an exact replay
            // only when every persisted normalized field is identical.
            canonicalQueuedEvent(current.event) === canonicalQueuedEvent(snapshot)
          )
        ) {
          return "duplicate" as const;
        }
        if (!isPendingIngestRecord(current)) {
          await transaction.put(key, record);
          return "written" as const;
        }
        // Apply the same monotonic lifecycle reconciliation used at the D1
        // boundary. A pending final/cancel must survive an equal- or
        // higher-serial active replay while D1 is unavailable; serial-only
        // replacement would otherwise erase the terminal transition before it
        // ever reached the outbox.
        const reconciled = reconcileEventRevision(
          { ...snapshot, raw: null },
          { ...current.event, raw: null },
        );
        if (reconciled === null) return "retained" as const;
        const { raw: _reconciledRaw, ...reconciledSnapshot } = reconciled;
        const reconciledFingerprint = await liveEventFingerprint(
          reconciledSnapshot,
        );
        if (
          reconciledFingerprint === current.fingerprint ||
          canonicalQueuedEvent(reconciledSnapshot) ===
            canonicalQueuedEvent(current.event)
        ) return "duplicate" as const;
        await transaction.put(key, {
          event: reconciledSnapshot,
          writeId: crypto.randomUUID(),
          fingerprint: reconciledFingerprint,
        } satisfies PendingIngestRecord);
        return "written" as const;
      });
      // The original attempt already owns either an in-flight D1 drain or a
      // durable retry alarm. Retrying an exact pending replay here would turn
      // one upstream duplicate burst into a D1 retry loop even though no new
      // event intent exists.
      if (readinessCandidate) readinessCandidate.durableIntentRecorded = true;
      if (journalOutcome === "duplicate") {
        // The original drain may have crossed its delete/mark boundary between
        // the transaction above and this candidate flag. Re-check once; if it
        // is still pending, that drain will perform the same publication.
        await this.markSourceSuccessfulAndPublishReadiness(event.sourceId);
        return;
      }
      await this.drainPendingIngestJournal(1, 1);
      // A pre-existing drain can process this just-written record before it
      // observes the candidate flag above. Re-check after the shared drain
      // settles; the pending-work fence still prevents premature readiness.
      await this.markSourceSuccessfulAndPublishReadiness(event.sourceId);
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
    maxEntries: number | null = 1,
    outboxFlushLimit: number | null = 1,
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
      if (remaining !== null && remaining <= 0) {
        const more = await this.state.storage.list({
          prefix: PENDING_INGEST_PREFIX,
          limit: 1,
        });
        if (more.size > 0) {
          await this.scheduleRelayAlarm(
            Date.now() + PENDING_INGEST_RETRY_DELAY_MS,
          );
        }
        return;
      }
      const limit = remaining === null
        ? OUTBOX_REPLAY_BATCH_SIZE
        : Math.min(remaining, OUTBOX_REPLAY_BATCH_SIZE);
      const pending = await this.state.storage.list<unknown>({
        prefix: PENDING_INGEST_PREFIX,
        limit,
      });
      if (pending.size === 0) return;

      for (const [key, value] of pending) {
        const storedSource = value && typeof value === "object" &&
            !Array.isArray(value) && "event" in value &&
            (value as { event?: unknown }).event &&
            typeof (value as { event?: unknown }).event === "object"
          ? ((value as { event: { sourceId?: unknown } }).event.sourceId)
          : null;
        if (isDisabledApnsRelaySource(storedSource)) {
          // This is not malformed unknown work: it is an explicitly retired
          // pre-build-8 source. Remove it so the old journal cannot ingest or
          // force a permanent five-second retry loop after the policy change.
          await this.state.storage.delete(key);
          console.info(JSON.stringify({
            journalKey: key,
            sourceId: storedSource,
            outcome: "disabled_source_live_ingest_superseded",
          }));
          if (remaining !== null) remaining -= 1;
          continue;
        }
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
          const journalDeleted = await this.state.storage.transaction(async (transaction) => {
            const current = await transaction.get<PendingIngestRecord>(key);
            // A newer record arrived while D1 committed the old one. Leave it
            // for the next loop; only the exact drained write may be removed.
            if (isPendingIngestRecord(current) && current.writeId === value.writeId) {
              await transaction.delete(key);
              return true;
            }
            return false;
          });
          // The resident duplicate cache is intentionally populated only
          // after both D1 and this journal-delete boundary succeed. If either
          // fails, a later replay must retain the durable pending-work fence.
          if (journalDeleted) {
            this.rememberCommittedLiveEventFingerprint(
              value.fingerprint ?? await liveEventFingerprint(value.event),
            );
          }
          // Freshness follows the durable D1/outbox transaction—not merely a
          // live WebSocket frame—so readiness exposes ingestion failures.
          await this.markSourceSuccessfulAndPublishReadiness(value.event.sourceId);
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
   * Read validated complete-list work in creation order. Unlike a point-event
   * journal, a complete ranked list is one durable unit: the final committed
   * fingerprint is written only after every bounded D1 slice succeeds.
   */
  private async pendingLiveSnapshotWorks(
    source?: LiveSnapshotSource,
  ): Promise<Array<[string, PendingLiveSnapshotWork]>> {
    const prefix = source === undefined
      ? PENDING_LIVE_SNAPSHOT_PREFIX
      : liveSnapshotWorkStorageKey(source);
    const pending = await this.state.storage.list<unknown>({
      prefix,
    });
    const works: Array<[string, PendingLiveSnapshotWork]> = [];
    for (const [key, value] of pending) {
      if (
        !isPendingLiveSnapshotWork(value) ||
        key !== liveSnapshotWorkStorageKey(value.source)
      ) {
        // Never delete an unreadable live snapshot. It is safer to leave
        // readiness degraded than to silently lose reports that already reached
        // the relay's durable boundary.
        console.error(JSON.stringify({ outcome: "invalid_live_snapshot_record" }));
        continue;
      }
      works.push([key, value]);
    }
    return works.sort(([, left], [, right]) =>
      left.createdAtMs - right.createdAtMs ||
      left.fingerprint.localeCompare(right.fingerprint)
    );
  }

  /**
   * Decode the fixed per-source live-list slots. Invalid durable values are an
   * integrity fence, never a cue to overwrite already accepted event intent.
   */
  private decodeLiveSnapshotSlots(
    source: LiveSnapshotSource,
    activeValue: unknown,
    latestValue: unknown,
    overflowValue: unknown,
  ): LiveSnapshotSlots | null {
    const decode = (value: unknown): PendingLiveSnapshotWork | undefined | null => {
      if (value === undefined) return undefined;
      return isPendingLiveSnapshotWork(value) && value.source === source
        ? value
        : null;
    };
    const active = decode(activeValue);
    const latest = decode(latestValue);
    const overflow = decode(overflowValue);
    if (active === null || latest === null || overflow === null) {
      console.error(JSON.stringify({ outcome: "invalid_live_snapshot_record" }));
      return null;
    }
    return { active, latest, overflow };
  }

  /**
   * A normal slot transition is atomic, but a rolling deploy or older
   * interrupted revision can leave a newer slot without an active cursor.
   * Repair that shape only from the serialized writer/alarm path. Status
   * readers remain strictly read-only and fail closed.
   */
  private async readAndRepairLiveSnapshotSlots(
    source: LiveSnapshotSource,
  ): Promise<LiveSnapshotSlots | null> {
    const workKey = liveSnapshotWorkStorageKey(source);
    const latestKey = liveSnapshotLatestStorageKey(source);
    const overflowKey = liveSnapshotOverflowStorageKey(source);
    const repair = async (
      target: DurableKeyValueStore,
    ): Promise<LiveSnapshotSlots | null> => {
      const [activeValue, latestValue, overflowValue] = await Promise.all([
        target.get<unknown>(workKey),
        target.get<unknown>(latestKey),
        target.get<unknown>(overflowKey),
      ]);
      const slots = this.decodeLiveSnapshotSlots(
        source,
        activeValue,
        latestValue,
        overflowValue,
      );
      if (!slots || slots.active || (!slots.latest && !slots.overflow)) {
        return slots;
      }

      const active = slots.latest ?? slots.overflow;
      if (!active) return slots;
      await target.put(workKey, active);
      if (slots.latest) {
        if (slots.overflow) {
          await target.put(latestKey, slots.overflow);
          await target.delete(overflowKey);
        } else {
          await target.delete(latestKey);
        }
        return {
          active,
          latest: slots.overflow,
          overflow: undefined,
        };
      }
      await target.delete(overflowKey);
      return { active, latest: undefined, overflow: undefined };
    };
    if (typeof this.state.storage.transaction === "function") {
      return this.state.storage.transaction((transaction) => repair(transaction));
    }
    return repair(this.state.storage);
  }

  private async repairPendingLiveSnapshotSlots(): Promise<void> {
    for (const source of APNS_RELAY_REPORT_SOURCES) {
      await this.liveSnapshotDrain(source, async () => {
        await this.readAndRepairLiveSnapshotSlots(source);
      });
    }
  }

  private async hasPendingLiveSnapshot(
    source: LiveSnapshotSource,
  ): Promise<boolean> {
    const [active, latest, overflow, overload] = await Promise.all([
      this.state.storage.get<unknown>(liveSnapshotWorkStorageKey(source)),
      this.state.storage.get<unknown>(liveSnapshotLatestStorageKey(source)),
      this.state.storage.get<unknown>(liveSnapshotOverflowStorageKey(source)),
      this.state.storage.get<unknown>(liveSnapshotOverloadStorageKey(source)),
    ]);
    // Presence, rather than successful decoding, is the readiness fence. An
    // alarm can repair only known-good records; a malformed key must remain
    // visible until an operator resolves it rather than being hidden by a
    // heartbeat or HTTP response.
    return active !== undefined || latest !== undefined || overflow !== undefined ||
      overload !== undefined;
  }

  private async hasAnyActiveLiveSnapshotWork(): Promise<boolean> {
    // A marker-only invalid/overload condition is deliberately health-stale,
    // but it owns no D1 cursor. Let normal outbox, DLQ, and journal recovery
    // continue in that state instead of starving unrelated delivery work.
    return (await this.pendingLiveSnapshotWorks()).length > 0;
  }

  private flagLiveSnapshotBlocked(
    source: LiveSnapshotSource,
    reason: LiveSnapshotOverload["reason"],
  ): Promise<void> {
    return this.liveSnapshotDrain(source, async () => {
      const key = liveSnapshotOverloadStorageKey(source);
      const current = await this.state.storage.get<unknown>(key);
      // The first durable failure is enough to fail readiness closed. Do not
      // turn an invalid or overloaded upstream into a write-per-frame loop.
      if (current !== undefined) return;
      await this.state.storage.put(key, {
        version: 1,
        source,
        reason,
        observedAtMs: Date.now(),
      } satisfies LiveSnapshotOverload);
    });
  }

  private async backpressureLiveSnapshotSource(
    source: LiveSnapshotSource,
  ): Promise<void> {
    const socket = this.upstreams.get(source);
    if (!socket) return;
    // Drop route ownership before close so its listener cannot schedule a
    // duplicate recovery. This is explicit transport backpressure, not a
    // hidden discard: health remains fail-closed under the overload marker and
    // the next reconnect asks Wolfx for a fresh complete list after the two
    // durable cursors finish.
    this.upstreams.delete(source);
    this.clearUpstreamLiveness(source);
    this.setRouteStatus(source, "error");
    try {
      socket.close(1013, "live snapshot backpressure");
    } catch {
      // The scheduled reconnect below is authoritative even if the runtime
      // already closed the WebSocket before this explicit close request.
    }
    await this.scheduleUpstreamReconnect(
      source,
      "wolfx_upstream_websocket_error",
      { reason: "live_snapshot_overload" },
    );
  }

  private liveSnapshotDrain<T>(
    source: LiveSnapshotSource,
    operation: () => Promise<T>,
  ): Promise<T> {
    const previous = this.liveSnapshotDrains.get(source) ?? Promise.resolve();
    const queued = previous.then(operation, operation);
    const serial = queued.then(
      () => undefined,
      () => undefined,
    );
    this.liveSnapshotDrains.set(source, serial);
    void serial.then(
      () => {
        if (this.liveSnapshotDrains.get(source) === serial) {
          this.liveSnapshotDrains.delete(source);
        }
      },
      () => {
        if (this.liveSnapshotDrains.get(source) === serial) {
          this.liveSnapshotDrains.delete(source);
        }
      },
    );
    return queued;
  }

  /**
   * Journal one complete EQLIST WebSocket frame before its first D1 write. A
   * duplicate first checks the committed fingerprint and active work, so it
   * does not recreate fifty one-event journals after the prior frame drained.
   * One source has at most one active cursor plus two newer accepted frames.
   * The active cursor is never overwritten once durable, even before its first
   * D1 slice. The third distinct frame is retained in an overflow slot before
   * explicit WebSocket backpressure closes the source, which bounds changed
   * frame storage without dropping intent that reached this relay.
   */
  private enqueueLiveSnapshot(
    source: LiveSnapshotSource,
    normalizedEvents: readonly NormalizedEvent[],
    readinessCandidate?: UpstreamDataReadinessCandidate,
  ): Promise<void> {
    return this.liveSnapshotDrain(source, async () => {
      const fingerprint = await liveSnapshotFingerprint(normalizedEvents);
      const workKey = liveSnapshotWorkStorageKey(source);
      const latestKey = liveSnapshotLatestStorageKey(source);
      const overflowKey = liveSnapshotOverflowStorageKey(source);
      const overloadKey = liveSnapshotOverloadStorageKey(source);
      const [slots, overloadValue, committed] = await Promise.all([
        this.readAndRepairLiveSnapshotSlots(source),
        this.state.storage.get<unknown>(overloadKey),
        this.state.storage.get<string>(liveSnapshotFingerprintStorageKey(source)),
      ]);
      if (!slots) return;
      if (
        overloadValue !== undefined &&
        (!isLiveSnapshotOverload(overloadValue) || overloadValue.source !== source)
      ) {
        console.error(JSON.stringify({ outcome: "invalid_live_snapshot_overload" }));
        return;
      }
      let { active, latest, overflow } = slots;
      const overload = overloadValue as LiveSnapshotOverload | undefined;

      if (overload) {
        if (active || latest || overflow) {
          // Existing D1-safe work remains the only accepted intent while the
          // source is overloaded. Close the direct list socket and recover
          // with a fresh complete snapshot after these three bounded cursors
          // drain; do not keep accepting and replacing frames that cannot fit
          // in the durable window.
          if (overload.reason === "overload") {
            await this.backpressureLiveSnapshotSource(source);
          }
          await this.drainLiveSnapshotWorkForSource(source);
          return;
        }
      }
      if (!active && !latest && !overflow && committed === fingerprint) {
        // A later valid frame exactly matching the committed snapshot is safe
        // evidence that the bounded overload window has ended. Clear the
        // stale marker before allowing a freshness checkpoint.
        if (overload) await this.state.storage.delete(overloadKey);
        if (readinessCandidate) readinessCandidate.durableIntentRecorded = true;
        await this.markSourceSuccessfulAndPublishReadiness(source);
        return;
      }

      if (
        active?.fingerprint !== fingerprint &&
        latest?.fingerprint !== fingerprint &&
        overflow?.fingerprint !== fingerprint
      ) {
        const createdAtMs = Date.now();
        const work: PendingLiveSnapshotWork = {
          version: 1,
          source,
          fingerprint,
          events: normalizedEvents.map(snapshotEvent),
          nextIndex: 0,
          createdAtMs,
          retryAtMs: createdAtMs,
        };
        if (!active) {
          const replace = async (target: DurableKeyValueStore): Promise<void> => {
            await target.put(workKey, work);
            // A valid replacement and marker clear must be atomic: a crash
            // between separate operations could otherwise make old freshness
            // look ready before the new event snapshot is durable.
            if (overload) await target.delete(overloadKey);
          };
          if (typeof this.state.storage.transaction === "function") {
            await this.state.storage.transaction((transaction) => replace(transaction));
          } else {
            await replace(this.state.storage);
          }
          active = work;
        } else if (!latest) {
          // Never overwrite an active cursor once it crossed the Durable
          // Object boundary. The second slot is the newest full replacement
          // and is promoted only after the active cursor commits all slices.
          await this.state.storage.put(latestKey, work);
          latest = work;
        } else if (!overflow) {
          // Persist the third accepted frame atomically with the overload
          // marker *before* closing the socket. That preserves its event
          // intent while bounding source admission to three complete lists.
          const overflowAndBackpressure = async (
            target: DurableKeyValueStore,
          ): Promise<void> => {
            await target.put(overflowKey, work);
            await target.put(overloadKey, {
              version: 1,
              source,
              reason: "overload",
              observedAtMs: createdAtMs,
            } satisfies LiveSnapshotOverload);
          };
          if (typeof this.state.storage.transaction === "function") {
            await this.state.storage.transaction((transaction) =>
              overflowAndBackpressure(transaction)
            );
          } else {
            await overflowAndBackpressure(this.state.storage);
          }
          overflow = work;
          console.error(JSON.stringify({
            outcome: "live_snapshot_overload",
            source,
          }));
          await this.backpressureLiveSnapshotSource(source);
        }
        // The durable cursor now owns recovery even if this instance is evicted
        // before its first D1 slice. Ask for a prompt but bounded continuation.
        await this.scheduleRelayAlarm(Date.now() + 1);
      }
      if (
        readinessCandidate &&
        [active, latest, overflow].some((work) => work?.fingerprint === fingerprint)
      ) {
        readinessCandidate.durableIntentRecorded = true;
      }
      await this.drainLiveSnapshotWorkForSource(source);
    });
  }

  /**
   * Process at most one eight-event slice. Keeping this separate from normal
   * outbox/journal maintenance prevents a fifty-report list from expanding an
   * ordinary relay alarm into an unbounded D1 turn.
   */
  private async drainLiveSnapshotWorkForSource(
    source: LiveSnapshotSource,
  ): Promise<boolean> {
    const now = Date.now();
    const pending = await this.pendingLiveSnapshotWorks(source);
    const due = pending.find(([, work]) => work.retryAtMs <= now);
    if (!due) return false;
    const [key, work] = due;
    const start = work.nextIndex;
    const end = Math.min(
      work.events.length,
      start + LIVE_SNAPSHOT_INGEST_BATCH_SIZE,
    );
    try {
      await persistHttpSnapshotEvents(
        this.env.DB,
        work.events.slice(start, end),
        "live",
      );
    } catch (error) {
      await this.deferLiveSnapshotWork(key, work);
      console.error(
        JSON.stringify({
          source: work.source,
          outcome: "live_snapshot_d1_retry",
          errorName: error instanceof Error ? error.name : "UnknownError",
        }),
      );
      return true;
    }

    const advanced = await this.advanceLiveSnapshotWork(key, work, end);
    if (!advanced.advanced) return true;
    if (advanced.hasNextWork) {
      await this.scheduleRelayAlarm(Date.now() + LIVE_SNAPSHOT_RESUME_INTERVAL_MS);
      return true;
    }
    // The advance transaction deleted the durability fence before this update,
    // so this is the first point where source freshness may be published.
    await this.markSourceSuccessfulAndPublishReadiness(work.source);
    return true;
  }

  /**
   * The relay alarm is not itself ordered with a WebSocket `waitUntil` after
   * either path begins external D1 I/O. Select one due source, then enter that
   * source's same in-memory serial queue used by frame ingestion. The durable
   * cursor checks below remain the cross-instance crash fence.
   */
  private async drainPendingLiveSnapshotWorks(): Promise<boolean> {
    const now = Date.now();
    const due = (await this.pendingLiveSnapshotWorks()).find(
      ([, work]) => work.retryAtMs <= now,
    );
    if (!due) return false;
    return this.liveSnapshotDrain(
      due[1].source,
      () => this.drainLiveSnapshotWorkForSource(due[1].source),
    );
  }

  private async deferLiveSnapshotWork(
    workKey: string,
    work: PendingLiveSnapshotWork,
  ): Promise<void> {
    const retryAtMs = Date.now() + LIVE_SNAPSHOT_FAILURE_RETRY_DELAY_MS;
    const storage = this.state.storage;
    const defer = async (target: DurableKeyValueStore): Promise<boolean> => {
      const current = await target.get<unknown>(workKey);
      if (
        !isPendingLiveSnapshotWork(current) ||
        current.fingerprint !== work.fingerprint ||
        current.createdAtMs !== work.createdAtMs ||
        current.nextIndex !== work.nextIndex
      ) return false;
      await target.put(workKey, { ...work, retryAtMs });
      return true;
    };
    const deferred = typeof storage.transaction === "function"
      ? await storage.transaction((transaction) => defer(transaction))
      : await defer(storage);
    if (deferred) await this.scheduleRelayAlarm(retryAtMs);
  }

  /**
   * Move a cursor only if it is still the exact work that D1 just committed.
   * The final transition writes the committed fingerprint and removes the work
   * in one Durable Object transaction; crashing on either side cannot make an
   * uncommitted list appear deduplicated.
   */
  private async advanceLiveSnapshotWork(
    workKey: string,
    work: PendingLiveSnapshotWork,
    nextIndex: number,
  ): Promise<LiveSnapshotAdvanceResult> {
    const storage = this.state.storage;
    const advance = async (
      target: DurableKeyValueStore,
    ): Promise<LiveSnapshotAdvanceResult> => {
      const current = await target.get<unknown>(workKey);
      if (
        !isPendingLiveSnapshotWork(current) ||
        current.fingerprint !== work.fingerprint ||
        current.createdAtMs !== work.createdAtMs ||
        current.nextIndex !== work.nextIndex
      ) return { advanced: false, hasNextWork: false };
      if (nextIndex < work.events.length) {
        await target.put(workKey, {
          ...work,
          nextIndex,
          retryAtMs: Date.now() + LIVE_SNAPSHOT_RESUME_INTERVAL_MS,
        });
        return { advanced: true, hasNextWork: true };
      }
      const latestKey = liveSnapshotLatestStorageKey(work.source);
      const overflowKey = liveSnapshotOverflowStorageKey(work.source);
      const latestValue = await target.get<unknown>(latestKey);
      const overflowValue = await target.get<unknown>(overflowKey);
      if (
        latestValue !== undefined &&
        (!isPendingLiveSnapshotWork(latestValue) ||
          latestValue.source !== work.source)
      ) {
        // Do not discard a completed snapshot or overwrite an unreadable
        // replacement. Repeating the final D1-safe slice is idempotent and
        // preserves a fail-closed recovery path until the record is repaired.
        console.error(JSON.stringify({ outcome: "invalid_live_snapshot_latest" }));
        return { advanced: false, hasNextWork: false };
      }
      if (
        overflowValue !== undefined &&
        (!isPendingLiveSnapshotWork(overflowValue) ||
          overflowValue.source !== work.source)
      ) {
        console.error(JSON.stringify({ outcome: "invalid_live_snapshot_overflow" }));
        return { advanced: false, hasNextWork: false };
      }
      const latest = latestValue as PendingLiveSnapshotWork | undefined;
      const overflow = overflowValue as PendingLiveSnapshotWork | undefined;
      await target.put(
        liveSnapshotFingerprintStorageKey(work.source),
        work.fingerprint,
      );
      if (latest) {
        await target.put(workKey, {
          ...latest,
          nextIndex: 0,
          retryAtMs: Date.now() + LIVE_SNAPSHOT_RESUME_INTERVAL_MS,
        });
        if (overflow) {
          await target.put(latestKey, overflow);
          await target.delete(overflowKey);
        } else {
          await target.delete(latestKey);
        }
        return { advanced: true, hasNextWork: true };
      } else if (overflow) {
        await target.put(workKey, {
          ...overflow,
          nextIndex: 0,
          retryAtMs: Date.now() + LIVE_SNAPSHOT_RESUME_INTERVAL_MS,
        });
        await target.delete(overflowKey);
        return { advanced: true, hasNextWork: true };
      } else {
        await target.delete(workKey);
        return { advanced: true, hasNextWork: false };
      }
    };
    if (typeof storage.transaction !== "function") return advance(storage);
    return storage.transaction((transaction) => advance(transaction));
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
  ): Promise<number> {
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
        const disabledSource = disabledSourceFromEventReference(row.event_ref);
        if (disabledSource !== null) {
          await this.supersedeOutboxForSourcePolicy(row.id);
          console.info(
            JSON.stringify({
              outboxId: row.id,
              sourceId: disabledSource,
              outcome: "disabled_source_alert_outbox_superseded",
            }),
          );
          continue;
        }
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
    return rows.results.length;
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

  private async deferOutboxForDurabilityMaintenance(
    outboxId: string,
  ): Promise<void> {
    const retryAt = new Date(
      Date.now() + PENDING_INGEST_RETRY_DELAY_MS,
    ).toISOString();
    const result = await this.env.DB
      .prepare(
        `UPDATE alert_delivery_outbox
         SET queue_lease_until_utc = NULL, next_enqueue_at_utc = ?
         WHERE id = ? AND acknowledged_at_utc IS NULL AND final_status IS NULL`,
      )
      .bind(retryAt, outboxId)
      .run();
    if ((result.meta.changes ?? 0) !== 1) {
      throw new Error("delivery outbox changed during maintenance deferral");
    }
    await this.scheduleRelayAlarm(Date.parse(retryAt));
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

  /**
   * Final transaction-time admission immediately before provider I/O. The
   * outbox ordering/deadline decision and every exact recipient revision are
   * observed in one D1 batch, so an opt-out, rotation, or newer event that
   * serialized during authorization/evidence preparation prevents a stale
   * APNs contact. Recovery re-resolves changed recipients from the durable
   * intent rather than sending this snapshot.
   */
  private async admitApnsProviderAttempt(
    handle: ApnsDeliveryIntentHandle,
    message: AlertDeliveryMessage,
    recipients: MappedApnsIntentRecipient[],
  ): Promise<MappedApnsIntentRecipient[]> {
    if (recipients.length === 0) return [];
    const event = eventFromDeliveryMessage(message);
    const requested = isTerminalAlertLifecycleReason(message.reason)
      ? recipients
      : recipients.filter(({ delivery }) =>
          shouldNotify(delivery.device, event, message.reason)
        );
    if (requested.length === 0) return [];
    const priorValue = await this.state.storage.get<unknown>(handle.storageKey);
    if (
      !isPendingApnsDeliveryIntentRecord(priorValue) ||
      priorValue.writeId !== handle.writeId ||
      priorValue.observedBatch !== null
    ) {
      throw new Error("APNs delivery intent changed before admission");
    }
    const budgetedRequested = requested.filter((recipient) =>
      (priorValue.recipientProviderAttempts[
        recipient.snapshotRegistrationRevision
      ] ?? 0) < APNS_DELIVERY_INTENT_MAX_PROVIDER_ATTEMPTS
    );
    if (budgetedRequested.length === 0) return [];
    const reserved = await this.reserveApnsDeliveryIntentRecovery(
      handle.storageKey,
      priorValue,
    );
    const attemptId = `${reserved.writeId}:${reserved.providerAttempts}`;
    const admittedAtUtc = reserved.lastProviderAttemptAtUtc;
    try {
      const results = await this.env.DB.batch([
        supersedeOutboxIfNewerRevisionStatement(
          this.env.DB,
          message.outboxId,
          admittedAtUtc,
        ),
        ...budgetedRequested.map(({
          delivery,
          snapshotRegistrationRevision,
        }) =>
          this.env.DB
            .prepare(
              `INSERT OR IGNORE INTO apns_provider_attempts (
                 attempt_id, registration_revision, token_hash,
                 event_ref, outbox_id, admitted_at_utc
               )
               SELECT ?, registration_revision, ?, ?, ?, ? FROM devices
               WHERE token = ? AND registration_revision = ?
                 AND app_attest_key_id IS ?
                 AND EXISTS (
                   SELECT 1 FROM json_each(
                     CASE WHEN json_valid(devices.sources)
                       THEN devices.sources ELSE '[]' END
                   ) WHERE value = ?
                 )
                 AND NOT EXISTS (
                   SELECT 1 FROM apns_registration_revision_fences
                   WHERE registration_revision = ?
                     AND blocks_lifecycle_replay = 1
                     AND decision_kind IN (
                       'explicit_removal', 'empty_source_removal',
                       'stale_registration_retention'
                     )
                 )
                 AND EXISTS (
                   SELECT 1 FROM alert_delivery_outbox
                   WHERE id = ? AND acknowledged_at_utc IS NULL
                     AND expires_at_utc IS NOT NULL AND expires_at_utc > ?
                 )
               RETURNING registration_revision`,
            )
            .bind(
              attemptId,
              delivery.tokenHash,
              message.event.id,
              message.outboxId,
              admittedAtUtc,
              delivery.device.token,
              delivery.device.registrationRevision,
              delivery.device.appAttestKeyId,
              message.event.sourceId,
              snapshotRegistrationRevision,
              message.outboxId,
              admittedAtUtc,
            )
        ),
        ...(message.reason === "new" || message.reason === "updated"
          ? budgetedRequested.map(({ delivery }) =>
            this.env.DB
              .prepare(
                `INSERT OR IGNORE INTO alert_lifecycle_possible_attempts (
                   attempt_id, event_ref, token_hash, app_attest_key_id,
                   registration_revision, evidence_at_utc
                 )
                 SELECT ?, ?, ?, app_attest_key_id,
                        registration_revision, ?
                 FROM devices
                 WHERE token = ? AND registration_revision = ?
                   AND EXISTS (
                     SELECT 1 FROM apns_provider_attempts
                     WHERE attempt_id = ?
                       AND registration_revision = devices.registration_revision
                   )`,
              )
              .bind(
                attemptId,
                message.event.id,
                delivery.tokenHash,
                admittedAtUtc,
                delivery.device.token,
                delivery.device.registrationRevision,
                attemptId,
              )
          )
          : []),
      ]);
      const admittedWithIndex = budgetedRequested.flatMap((recipient, index) =>
        (results[index + 1]?.results.length ?? 0) === 1
          ? [{ recipient, index }]
          : []
      );
      const admitted = admittedWithIndex.map(({ recipient }) => recipient);
      // The exact D1 snapshot is authoritative for preferences; this final
      // synchronous recheck additionally closes a local quiet-hour boundary
      // without introducing another awaited TOCTOU before fetch.
      const stillEligible = isTerminalAlertLifecycleReason(message.reason)
        ? admitted
        : admitted.filter(({ delivery }) =>
            shouldNotify(delivery.device, event, message.reason)
          );
      if (admitted.length === 0 || stillEligible.length !== admitted.length) {
        await this.env.DB.batch([
          this.env.DB
            .prepare(
              "DELETE FROM alert_lifecycle_possible_attempts WHERE attempt_id = ?",
            )
            .bind(attemptId),
          this.env.DB
            .prepare("DELETE FROM apns_provider_attempts WHERE attempt_id = ?")
            .bind(attemptId),
        ]);
        await this.restoreUncontactedApnsIntentReservation(
          handle.storageKey,
          reserved,
          priorValue,
        );
        return [];
      }
      if (message.reason === "new" || message.reason === "updated") {
        const possibleOffset = 1 + budgetedRequested.length;
        if (admittedWithIndex.some(({ index }) =>
          (results[possibleOffset + index]?.meta.changes ?? 0) !== 1
        )) {
          throw new Error("APNs possible-contact evidence was not admitted");
        }
      }
      await this.state.storage.transaction(async (transaction) => {
        const current = await transaction.get<unknown>(handle.storageKey);
        if (
          !isPendingApnsDeliveryIntentRecord(current) ||
          current.writeId !== reserved.writeId ||
          current.providerAttempts !== reserved.providerAttempts ||
          current.lastProviderAttemptAtUtc !== reserved.lastProviderAttemptAtUtc ||
          current.observedBatch !== null
        ) {
          throw new Error("APNs admitted reservation changed before provider contact");
        }
        const recipientProviderAttempts = {
          ...current.recipientProviderAttempts,
        };
        for (const { snapshotRegistrationRevision } of admitted) {
          const next =
            (recipientProviderAttempts[snapshotRegistrationRevision] ?? 0) + 1;
          if (next > APNS_DELIVERY_INTENT_MAX_PROVIDER_ATTEMPTS) {
            throw new Error("APNs recipient provider-attempt budget is exhausted");
          }
          recipientProviderAttempts[snapshotRegistrationRevision] = next;
        }
        await transaction.put(handle.storageKey, {
          ...current,
          recipientProviderAttempts,
        } satisfies PendingApnsDeliveryIntentRecord);
      });
      return stillEligible;
    } catch (error) {
      await this.env.DB.batch([
        this.env.DB
          .prepare(
            "DELETE FROM alert_lifecycle_possible_attempts WHERE attempt_id = ?",
          )
          .bind(attemptId),
        this.env.DB
          .prepare("DELETE FROM apns_provider_attempts WHERE attempt_id = ?")
          .bind(attemptId),
      ]).catch(() => undefined);
      await this.restoreUncontactedApnsIntentReservation(
        handle.storageKey,
        reserved,
        priorValue,
      ).catch(() => undefined);
      throw error;
    }
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

  /**
   * Terminalize only an outbox row whose stored event reference names one of
   * the five explicitly disabled sources. The D1 predicate is authoritative,
   * so a forged Queue body cannot retire an allowed JMA alert by ID alone.
   */
  private async supersedeOutboxForSourcePolicy(outboxId: string): Promise<boolean> {
    const now = new Date().toISOString();
    const results = await this.env.DB.batch([
      this.env.DB
        .prepare(
          `UPDATE alert_delivery_outbox
           SET acknowledged_at_utc = COALESCE(acknowledged_at_utc, ?),
               terminal_reason = COALESCE(terminal_reason, 'superseded'),
               queue_lease_until_utc = NULL
           WHERE id = ?
             AND acknowledged_at_utc IS NULL
             AND final_status IS NULL
             AND instr(event_ref, ':') > 1
             AND substr(event_ref, 1, instr(event_ref, ':') - 1) IN (
               'sc_eew',
               'cenc_eew',
               'fj_eew',
               'cq_eew',
               'cenc_eqlist'
             )`,
        )
        .bind(now, outboxId),
      this.env.DB
        .prepare(
          `UPDATE alert_delivery_page_failures
           SET status = 'resolved', resolved_at_utc = COALESCE(resolved_at_utc, ?)
           WHERE outbox_id = ? AND status = 'active'
             AND EXISTS (
               SELECT 1 FROM alert_delivery_outbox
               WHERE id = ? AND terminal_reason = 'superseded'
             )`,
        )
        .bind(now, outboxId, outboxId),
    ]);
    return (results[0]?.meta.changes ?? 0) > 0;
  }

  private async devicePurgeIsDue(): Promise<boolean> {
    const lastPurge = await this.state.storage.get<number>(LAST_DEVICE_PURGE_KEY);
    return !lastPurge || Date.now() - lastPurge >= DEVICE_PURGE_INTERVAL_MS;
  }

  private async purgeExpiredDevicesIfDue(): Promise<void> {
    if (!await this.devicePurgeIsDue()) return;

    const deviceCutoff = new Date(
      Date.now() - DEVICE_REGISTRATION_MAX_AGE_MS,
    ).toISOString();
    const deliveryCutoff = new Date(
      Date.now() - DELIVERY_DEDUP_RETENTION_MS,
    ).toISOString();
    const eventCutoff = new Date(
      Date.now() - RELAY_EVENT_RETENTION_CUTOFF_MS,
    ).toISOString();
    const purgeObservedAt = new Date(Date.now()).toISOString();
    await this.env.DB.batch([
      // SQLite cannot SHA-256 unbound raw tokens. Move each consent-ending
      // stale deletion into the bounded handoff first; reconciliation below
      // hashes it, blocks the full lineage, and removes the raw token before
      // this purge is considered complete.
      this.env.DB
        .prepare(
          `INSERT INTO legacy_device_removal_tokens (
             token, registration_revision, app_attest_key_id,
             decision_kind, removed_at_utc
           )
           SELECT token, registration_revision, app_attest_key_id,
                  'stale_registration_retention', ?
           FROM devices WHERE updated_at < ?
           ON CONFLICT(token) DO UPDATE SET
             registration_revision = excluded.registration_revision,
             app_attest_key_id = excluded.app_attest_key_id,
             decision_kind = excluded.decision_kind,
             removed_at_utc = excluded.removed_at_utc`,
        )
        .bind(purgeObservedAt, deviceCutoff),
      // Retention is a consent-ending removal. Upgrade every older
      // continuity-preserving fence carried by the same authenticated key so
      // a pending acceptance for a rotated token cannot attach to a future
      // reincarnation after the current registration ages out.
      this.env.DB
        .prepare(
          `UPDATE apns_registration_revision_fences
           SET decision_kind = 'stale_registration_retention',
               blocks_lifecycle_replay = 1,
               processed_at_utc = MAX(processed_at_utc, ?)
           WHERE app_attest_key_id IN (
             SELECT app_attest_key_id FROM devices
             WHERE updated_at < ? AND app_attest_key_id IS NOT NULL
           )`,
        )
        .bind(purgeObservedAt, deviceCutoff),
      // A stale registration can still have an APNs request in flight. Fence
      // every opaque revision before bulk deletion so a delayed provider
      // response cannot act on a later reincarnation of the same token. No raw
      // token or hash is needed because the revision is globally unique.
      this.env.DB
        .prepare(
          `INSERT INTO apns_registration_revision_fences (
             registration_revision, token_hash, app_attest_key_id,
             decision_id, decision_kind,
             blocks_lifecycle_replay, processed_at_utc
           )
           SELECT registration_revision, NULL, app_attest_key_id,
                  lower(hex(randomblob(16))),
                  'stale_registration_retention', 1, ?
           FROM devices WHERE updated_at < ?
           ON CONFLICT(registration_revision) DO UPDATE SET
             decision_kind = excluded.decision_kind,
             blocks_lifecycle_replay = 1,
             processed_at_utc = MAX(
               excluded.processed_at_utc,
               apns_registration_revision_fences.processed_at_utc
             )`,
        )
        .bind(purgeObservedAt, deviceCutoff),
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
          "DELETE FROM alert_lifecycle_recipients WHERE last_evidence_at_utc < ?",
        )
        .bind(deliveryCutoff),
      this.env.DB
        .prepare(
          `DELETE FROM alert_lifecycle_possible_attempts
           WHERE evidence_at_utc < ?
             AND NOT EXISTS (
               SELECT 1 FROM apns_provider_attempts AS attempt
               WHERE attempt.attempt_id =
                       alert_lifecycle_possible_attempts.attempt_id
                 AND attempt.registration_revision =
                       alert_lifecycle_possible_attempts.registration_revision
                 AND attempt.outcome_reconciled_at_utc IS NULL
             )`,
        )
        .bind(deliveryCutoff),
      this.env.DB
        .prepare(
          `DELETE FROM apns_provider_attempts
           WHERE admitted_at_utc < ?
             AND outcome_reconciled_at_utc IS NOT NULL`,
        )
        .bind(deliveryCutoff),
      this.env.DB
        .prepare(
          `DELETE FROM apns_registration_revision_fences
           WHERE processed_at_utc < ?
             AND NOT EXISTS (
               SELECT 1 FROM alert_lifecycle_possible_attempts AS possible
               WHERE possible.registration_revision =
                 apns_registration_revision_fences.registration_revision
             )
             AND NOT EXISTS (
               SELECT 1 FROM apns_provider_attempts AS attempt
               WHERE attempt.registration_revision =
                   apns_registration_revision_fences.registration_revision
                 AND attempt.outcome_reconciled_at_utc IS NULL
             )`,
        )
        .bind(deliveryCutoff),
      this.env.DB
        .prepare(
          `DELETE FROM alert_delivery_failures
           WHERE (
             status = 'active' AND apns_reason = 'BadDeviceToken'
             AND disposition IN ('quarantine', 'retry')
             AND last_seen_utc < ?
           ) OR (
             NOT (
               status = 'active' AND COALESCE(apns_reason, '') = 'BadDeviceToken'
               AND disposition IN ('quarantine', 'retry')
             )
             AND last_seen_utc < ?
           )`,
        )
        .bind(deviceCutoff, deliveryCutoff),
      // Resolved DLQ/page evidence and terminal outbox payload snapshots have
      // the same short post-resolution retention as delivery deduplication.
      // Active incidents are deliberately retained: a deadline may expire an
      // old EEW page before a human fixes the provider/Queue configuration.
      this.env.DB
        .prepare(
          `DELETE FROM alert_delivery_incidents
           WHERE status = 'resolved' AND resolved_at_utc IS NOT NULL
             AND resolved_at_utc < ?`,
        )
        .bind(deliveryCutoff),
      this.env.DB
        .prepare(
          `DELETE FROM alert_delivery_page_failures
           WHERE status = 'resolved' AND resolved_at_utc IS NOT NULL
             AND resolved_at_utc < ?`,
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
      // Revision rows have no foreign-key cascade in the original schema, so
      // prune them before their canonical event rows. Event retention remains
      // far longer than Queue delivery and terminal-outbox retention.
      this.env.DB
        .prepare("DELETE FROM event_revisions WHERE recorded_at_utc < ?")
        .bind(eventCutoff),
      this.env.DB
        .prepare("DELETE FROM events WHERE last_updated_utc < ?")
        .bind(eventCutoff),
      this.env.DB
        .prepare("DELETE FROM devices WHERE updated_at < ?")
        .bind(deviceCutoff),
      ...appAttestRetentionCleanupStatements(
        this.env.DB,
        purgeObservedAt,
      ),
    ]);
      // The raw-token consent handoff is a separate, fail-closed maintenance
      // class. Combining its conversion batch with the retention batch can
      // exceed Workers Free's 50-query invocation ceiling; the pending row
      // keeps alert work blocked and the short alarm below owns conversion.
      await this.scheduleRelayAlarm(Date.now() + PENDING_INGEST_RETRY_DELAY_MS);
      await this.state.storage.put(LAST_DEVICE_PURGE_KEY, Date.now());
  }

  private async deliverQueuedPage(
    message: AlertDeliveryMessage,
  ): Promise<Response> {
    try {
      // Never let expiry/supersession discard a provider acceptance whose D1
      // write is still pending. The bounded reconciler either drains the next
      // record and proves the journal empty or throws before this terminal
      // gate and before any new APNs request.
      const recoveryOwnsInvocation =
        await this.reconcileApnsAcceptanceJournal();
      if (recoveryOwnsInvocation) {
        // The recovered outcome/consent handoff owned this invocation's D1
        // budget. Leave the current Queue row pending for one short retry; it
        // will then observe dedupe/terminal state without combining a fresh
        // APNs page with the maintenance batch.
        await this.deferOutboxForDurabilityMaintenance(message.outboxId);
        return Response.json(
          { ok: true, deferredForDurabilityMaintenance: true },
          {
            status: 202,
            headers: { [DELIVERY_MAINTENANCE_DEFERRED_HEADER]: "1" },
          },
        );
      }
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
        async () => {
          const gate = await this.expireOutboxIfDue(message);
          return gate;
        },
        (deliveries) =>
          recordDeliveredDevices(
            this.env.DB,
            message.deliveryId,
            event.id,
            event.sourceId,
            message.reason,
            deliveries.map((delivery) => ({
              token: delivery.device.token,
              tokenHash: delivery.tokenHash,
              snapshotRegistrationRevision:
                delivery.device.registrationRevision,
              snapshotAppAttestKeyId: delivery.device.appAttestKeyId,
              firstAcceptedAtUtc: delivery.acceptedAtUtc,
              lastAcceptedAtUtc: delivery.acceptedAtUtc,
            })),
            true,
          ),
        (deliveries) => this.persistApnsDeliveryIntent(message, deliveries),
        (intent, observedAtUtc, deliveries, results) =>
          this.persistApnsDeliveryIntentObservedBatch(
            intent,
            observedAtUtc,
            deliveries,
            results,
          ),
        (intent, deliveries) =>
          this.admitApnsProviderAttempt(
            intent,
            message,
            deliveries.map((delivery, originDeliveryIndex) => ({
              delivery,
              originDeliveryIndex,
              snapshotRegistrationRevision:
                delivery.device.registrationRevision,
            })),
          ),
        async (intent, _failure) => {
          const current = await this.state.storage.get<unknown>(
            intent.storageKey,
          );
          if (
            !isPendingApnsDeliveryIntentRecord(current) ||
            current.writeId !== intent.writeId ||
            current.observedBatch === null
          ) {
            throw new Error("APNs observed batch is unavailable for completion");
          }
          return (await this.reconcileObservedApnsDeliveryIntentBatch(
            intent.storageKey,
            current,
          )) !== null;
        },
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
        if (!page.pageFailurePersistedByIntent) {
          await recordPageDeliveryFailure(
            this.env.DB,
            message.outboxId,
            message,
            page.pageFailure,
          );
        }
      } else {
        // A successful/non-provider retry proves the page-level provider
        // incident cleared even if one recipient still needs its own retry.
        await resolvePageDeliveryFailure(this.env.DB, message.outboxId);
      }
      if (!page.globalPageFailure && page.nextAfterDeviceCursor !== null) {
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
      // Data readiness and transport activity are intentionally independent.
      // Keep HTTP fallback active for an unready route, but do not churn a
      // newly upgraded socket while its initial snapshot is still arriving.
      // An unready socket gets one bounded window; after readiness, only a
      // current heartbeat/data frame extends the transport watchdog.
      if (
        current?.readyState === 1 &&
        this.upstreamTransportIsStale(route, current, now)
      ) {
        this.upstreams.delete(route);
        this.clearUpstreamLiveness(route);
        this.setRouteStatus(route, "closed");
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

  private upstreamTransportIsStale(
    route: UpstreamRoute,
    socket: WebSocket,
    now: number,
  ): boolean {
    if (this.upstreams.get(route) !== socket || socket.readyState !== 1) return true;
    const activatedAtMs = this.upstreamActivatedAtMs.get(route);
    const ready = this.readyUpstreamSockets.get(route) === socket;
    const watchdogAtMs = ready
      ? this.lastUpstreamTransportMessageMs.get(route)
      : activatedAtMs;
    return (
      typeof watchdogAtMs !== "number" ||
      !Number.isFinite(watchdogAtMs) ||
      watchdogAtMs <= 0 ||
      watchdogAtMs > now ||
      now - watchdogAtMs > UPSTREAM_STALE_AFTER_MS
    );
  }

  private routeIsOpen(route: UpstreamRoute): boolean {
    const now = Date.now();
    return !isUpstreamSourceStale(
      this.statuses.get(route) ?? "connecting",
      this.lastSuccessfulUpstreamMs.get(route),
      false,
      now,
    );
  }

  private allRoutesOpen(): boolean {
    return UPSTREAM_ROUTES.every((route) => this.routeIsOpen(route));
  }

  private anyRouteOpen(): boolean {
    return UPSTREAM_ROUTES.some((route) => this.routeIsOpen(route));
  }

  private async anyRouteHasBeenDegradedForGrace(now: number): Promise<boolean> {
    const degradedRoutes = UPSTREAM_ROUTES.filter((route) => !this.routeIsOpen(route));
    if (degradedRoutes.length === 0) return false;
    const degradedSince = await Promise.all(
      degradedRoutes.map((route) =>
        this.state.storage.get<number>(
          `${UPSTREAM_DEGRADED_SINCE_PREFIX}${route}`,
        )
      ),
    );
    return degradedSince.some(
      (degradedAt) =>
        typeof degradedAt === "number" &&
        Number.isFinite(degradedAt) &&
        degradedAt > 0 &&
        degradedAt <= now - HTTP_RECOVERY_SEED_GRACE_MS,
    );
  }

  /**
   * Enter the HTTP alternate transport after any live WebSocket route has
   * remained down through the grace period. Recovery polls only stale sources,
   * so one broken list route is covered without polling healthy feeds. Once
   * active, retain it during partial socket recovery and remove it only after
   * all routes are demonstrably open again.
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
    if (!await this.anyRouteHasBeenDegradedForGrace(Date.now())) return false;
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

  private async partialFallbackMaintenanceAllowed(
    fallbackActive: boolean,
    pendingHttpSnapshot: boolean,
    now: number,
  ): Promise<boolean> {
    if (!fallbackActive || pendingHttpSnapshot || !this.anyRouteOpen()) {
      return false;
    }
    if (!await this.httpFallbackTurnIsDue(now)) return false;
    return (await this.legacyHttpSeedFenceUntil()) <= now;
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
    const degradedRoutes = UPSTREAM_ROUTES.filter((route) => !this.routeIsOpen(route));
    if (degradedRoutes.length === 0) return null;
    const degradedSince = await Promise.all(
      degradedRoutes.map((route) =>
        this.state.storage.get<number>(
          `${UPSTREAM_DEGRADED_SINCE_PREFIX}${route}`,
        )
      ),
    );
    const activationCandidates = degradedSince.filter(
      (degradedAt): degradedAt is number =>
        typeof degradedAt === "number" &&
        Number.isFinite(degradedAt) &&
        degradedAt > 0,
    );
    if (activationCandidates.length === 0) return null;
    const activationAt = Math.min(...activationCandidates) +
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
      ? storedIndex % APNS_RELAY_SOURCES.length
      : 0;
    for (let offset = 0; offset < APNS_RELAY_SOURCES.length; offset += 1) {
      const index = (start + offset) % APNS_RELAY_SOURCES.length;
      const candidate = APNS_RELAY_SOURCES[index];
      if (candidates.includes(candidate)) return candidate;
    }
    return null;
  }

  private async advanceHttpSeedSource(
    source: WolfxSourceId,
  ): Promise<boolean> {
    const index = APNS_RELAY_SOURCES.indexOf(source as ApnsRelaySourceId);
    if (index < 0) return false;
    const next = (index + 1) % APNS_RELAY_SOURCES.length;
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
    return APNS_RELAY_SOURCES.filter(
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
    let pendingApnsAcceptanceBatches: number | null;
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
    try {
      const pendingAcceptances = await this.state.storage.list({
        prefix: APNS_ACCEPTANCE_JOURNAL_PREFIX,
        limit: APNS_ACCEPTANCE_JOURNAL_MAX_RECORDS + 1,
      });
      const pendingConsentRemovals =
        (await this.env.DB
          .prepare(
            "SELECT COUNT(*) AS pending_count FROM legacy_device_removal_tokens",
          )
          .first<number>("pending_count")) ?? 0;
      pendingApnsAcceptanceBatches =
        pendingAcceptances.size + pendingConsentRemovals;
    } catch {
      pendingApnsAcceptanceBatches = null;
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
      pendingApnsAcceptanceBatches,
      activePageFailures,
      activeQuarantinedFailures,
      activeRetryFailures,
      pendingOutboxRows,
      staleOutboxRows,
      status: deliveryReadinessStatus({
        apnsConfigured,
        activeDlqIncidents,
        pendingDlqPersistenceFallbacks,
        pendingApnsAcceptanceBatches,
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
      APNS_RELAY_SOURCES.map(async (source) => {
        const [
          persisted,
          persistedHttp,
          pendingJournal,
          pendingHttpWork,
          pendingLiveSnapshotWork,
          pendingLiveSnapshotLatest,
          pendingLiveSnapshotOverflow,
          pendingLiveSnapshotOverload,
        ] = await Promise.all([
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
          isLiveSnapshotSource(source)
            ? this.state.storage.get<unknown>(liveSnapshotWorkStorageKey(source))
            : Promise.resolve(undefined),
          isLiveSnapshotSource(source)
            ? this.state.storage.get<unknown>(liveSnapshotLatestStorageKey(source))
            : Promise.resolve(undefined),
          isLiveSnapshotSource(source)
            ? this.state.storage.get<unknown>(liveSnapshotOverflowStorageKey(source))
            : Promise.resolve(undefined),
          isLiveSnapshotSource(source)
            ? this.state.storage.get<unknown>(liveSnapshotOverloadStorageKey(source))
            : Promise.resolve(undefined),
        ]);
        const lastWebSocketSuccessMs = this.lastSuccessfulUpstreamMs.get(source) ??
          persisted;
        const lastHttpSuccessMs = this.lastSuccessfulHttpPollMs.get(source) ??
          persistedHttp;
        const status = this.statuses.get(source) ?? "connecting";
        const hasPendingLiveIngest = pendingJournal.size > 0;
        const hasPendingLiveSnapshot =
          pendingLiveSnapshotWork !== undefined ||
          pendingLiveSnapshotLatest !== undefined ||
          pendingLiveSnapshotOverflow !== undefined ||
          pendingLiveSnapshotOverload !== undefined;
        // A malformed cursor is still an unfinished durability signal. Fail
        // closed until an alarm clears/rebuilds it; never let a prior fresh
        // HTTP timestamp hide corrupt alternate-transport work.
        const hasPendingHttpSnapshot = pendingHttpWork !== undefined;
        const websocketStale = isUpstreamSourceStale(
          status,
          lastWebSocketSuccessMs,
          hasPendingLiveIngest || hasPendingLiveSnapshot,
          now,
        );
        const httpStale = isHttpFallbackSourceStale(
          lastHttpSuccessMs,
          hasPendingLiveIngest || hasPendingHttpSnapshot || hasPendingLiveSnapshot,
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
          pendingLiveSnapshot: hasPendingLiveSnapshot,
          pendingHttpSnapshot: hasPendingHttpSnapshot,
          websocketStale,
          httpStale,
          // A partially persisted HTTP snapshot is deliberately not ready
          // even when WebSocket traffic has recovered: otherwise /healthz
          // could declare success before the alternate transport's durable
          // cursor has finished committing its bounded event slices.
          stale: transport === "unavailable" || hasPendingHttpSnapshot ||
            hasPendingLiveSnapshot,
        };
      }),
    );
    const staleSources = sourceHealth
      .filter((source) => source.stale)
      .map((source) => source.source);
    const pendingIngestSources = sourceHealth
      .filter((source) =>
        source.pendingLiveIngest || source.pendingLiveSnapshot ||
        source.pendingHttpSnapshot
      )
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
            pendingLiveSnapshot: source.pendingLiveSnapshot,
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
    if (!(UPSTREAM_ROUTES as readonly string[]).includes(route)) {
      console.error(JSON.stringify({
        route: typeof route === "string" ? route.slice(0, 64) : "invalid",
        outcome: "disabled_wolfx_upstream_route_rejected",
      }));
      return;
    }
    if (this.connectingRoutes.has(route)) return;
    // A new handshake attempt is a new route lifecycle even before the
    // Upgrade resolves. Never leave a prior socket's validation token or
    // readiness available while the replacement connection is in flight.
    this.clearUpstreamLiveness(route);
    this.setRouteStatus(route, "connecting");
    this.connectingRoutes.add(route);
    // `fetch(... Upgrade)` is the documented alternative client path for
    // Workers. It gives us a response status for a rejected Wolfx handshake,
    // unlike the constructor's generic `error` event, while still retaining a
    // standard WebSocket after a successful Upgrade.
    this.state.waitUntil(this.connectWithUpgrade(route));
  }

  private serializeApnsDelivery<T>(operation: () => Promise<T>): Promise<T> {
    const queued = this.apnsDeliverySerial.then(operation, operation);
    this.apnsDeliverySerial = queued.then(
      () => undefined,
      () => undefined,
    );
    return queued;
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
      const [fallbackAlarmAt, reconnectAlarmAt, liveSnapshotAlarmAt] =
        await Promise.all([
          this.nextHttpFallbackAlarmAt(now),
          this.nextUpstreamReconnectAlarmAt(now),
          this.nextLiveSnapshotAlarmAt(now),
        ]);
      let effectiveLiveSnapshotAlarmAt = liveSnapshotAlarmAt;
      if (liveSnapshotAlarmAt !== null && fallbackAlarmAt !== null) {
        const [fallbackActive, pendingHttpSnapshot] = await Promise.all([
          this.readHttpFallbackActive(),
          this.pendingHttpSnapshotWorks().then((works) => works.length > 0),
        ]);
        if (
          (fallbackActive || pendingHttpSnapshot) &&
          !await this.partialFallbackMaintenanceAllowed(
            fallbackActive,
            pendingHttpSnapshot,
            now,
          )
        ) {
          // Do not repeatedly wake for live work while a protected HTTP turn
          // would refuse to run it. The cursor remains durable and resumes at
          // the same retry/sweep/fence boundary as alternate transport.
          effectiveLiveSnapshotAlarmAt = Math.max(
            liveSnapshotAlarmAt,
            fallbackAlarmAt,
          );
        }
      }
      const requestedAlarmAt = Math.min(
        routineAlarmAt,
        ...(fallbackAlarmAt === null ? [] : [fallbackAlarmAt]),
        ...(reconnectAlarmAt === null ? [] : [reconnectAlarmAt]),
        ...(effectiveLiveSnapshotAlarmAt === null
          ? []
          : [effectiveLiveSnapshotAlarmAt]),
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

  private async nextLiveSnapshotAlarmAt(now: number): Promise<number | null> {
    const pending = await this.pendingLiveSnapshotWorks();
    if (pending.length === 0) return null;
    const retryAtMs = Math.min(...pending.map(([, work]) => work.retryAtMs));
    return retryAtMs <= now ? now + 1 : retryAtMs;
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
        this.clearUpstreamLiveness(route);
        this.setRouteStatus(route, "error");
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
      this.clearUpstreamLiveness(route);
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
    expectedSocket?: WebSocket,
  ): Promise<void> {
    return this.serializeRelayAlarm(async () => {
      // A close/error can remove or replace the socket while a message's
      // freshness write is still pending. Never let that old message clear
      // the new failure state after it has lost ownership of the route.
      if (expectedSocket && this.upstreams.get(route) !== expectedSocket) {
        return;
      }
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
    this.clearUpstreamLiveness(route);
    this.upstreamActivatedAtMs.set(route, Date.now());
    this.setRouteStatus(route, "connecting");
    // Do not treat the HTTP 101 as a usable upstream response. A peer can
    // accept the Upgrade and immediately close; freshness and reconnect
    // recovery begin only after a later valid Wolfx message reaches the
    // listener below.
    const queries = route === "jma_eew"
      ? ["query_jmaeew"]
      : ["query_jmaeqlist"];
    for (const query of queries) socket.send(query);
  }

  private rejectUpstreamFrame(
    route: UpstreamRoute,
    socket: WebSocket,
    reason: "non_text" | "invalid_json" | "unexpected_type" | "invalid_data",
  ): Promise<void> {
    if (this.upstreams.get(route) !== socket) return Promise.resolve();
    // Detach and clear readiness synchronously. Buffered messages from this
    // socket can still be delivered after close(), and none may restore the
    // route while durable reconnect scheduling is in flight.
    this.upstreams.delete(route);
    this.clearUpstreamLiveness(route);
    this.setRouteStatus(route, "error");
    try {
      socket.close(1008, "invalid upstream frame");
    } catch {
      // The socket is already detached; the durable reconnect below owns
      // recovery even if the runtime has closed it first.
    }
    console.warn(JSON.stringify({
      outcome: "wolfx_upstream_frame_rejected",
      route,
      reason,
    }));
    const reconnect = this.scheduleUpstreamReconnect(
      route,
      "wolfx_upstream_websocket_error",
      { reason: `invalid_frame_${reason}` },
    );
    if (!isLiveSnapshotSource(route)) return reconnect;
    // The list-specific durability marker and route reconnect are independent
    // fail-closed actions. Start both now so a queued snapshot drain cannot
    // postpone the transport recovery alarm.
    return Promise.all([
      this.flagLiveSnapshotBlocked(route, "invalid"),
      reconnect,
    ]).then(() => undefined);
  }

  private attachUpstreamSocketListeners(
    route: UpstreamRoute,
    socket: WebSocket,
  ): void {
    socket.addEventListener("message", (event) => {
      // A deliberate backpressure close removes route ownership before the
      // runtime finishes draining already-buffered WebSocket events. Never
      // accept those orphaned frames after the relay has switched to a fresh
      // reconnect/query cycle.
      if (this.upstreams.get(route) !== socket) return;
      if (typeof event.data !== "string") {
        this.state.waitUntil(this.rejectUpstreamFrame(route, socket, "non_text"));
        return;
      }
      let message: unknown;
      try {
        message = JSON.parse(event.data);
      } catch {
        this.state.waitUntil(this.rejectUpstreamFrame(route, socket, "invalid_json"));
        return;
      }
      if (isHeartbeat(message) || isPong(message)) {
        if (!isStructurallyValidWolfxControlFrame(message)) {
          this.state.waitUntil(this.rejectUpstreamFrame(route, socket, "invalid_data"));
          return;
        }
        // Heartbeats are transport watchdog evidence only. They may extend a
        // route that this exact socket already made ready, but can neither
        // create readiness after Upgrade nor restore it after invalid data.
        this.state.waitUntil(this.recordUpstreamTransportLiveness(route, socket));
        return;
      }
      if (
        !message ||
        typeof message !== "object" ||
        Array.isArray(message) ||
        (message as { type?: unknown }).type !== route
      ) {
        this.state.waitUntil(this.rejectUpstreamFrame(route, socket, "unexpected_type"));
        return;
      }

      const source = route;
      let normalizedEvents: NormalizedEvent[];
      try {
        normalizedEvents = normalizeMessages(source, message);
      } catch {
        this.state.waitUntil(this.rejectUpstreamFrame(route, socket, "invalid_data"));
        return;
      }
      if (
        normalizedEvents.length === 0 ||
        !isStructurallyValidHttpSnapshot(source, message, normalizedEvents)
      ) {
        this.state.waitUntil(this.rejectUpstreamFrame(route, socket, "invalid_data"));
        return;
      }

      // This token is not readiness. The ingest path flips its durable-intent
      // bit only after this particular frame is journaled (or proven already
      // committed); an older drain can therefore never certify newer data.
      const readinessCandidate: UpstreamDataReadinessCandidate = {
        socket,
        durableIntentRecorded: false,
      };
      this.validatedUpstreamDataSockets.set(route, readinessCandidate);
      this.readyUpstreamSockets.delete(route);
      this.setRouteStatus(route, "connecting");
      this.state.waitUntil(this.recordUpstreamTransportLiveness(route, socket));
      if (isLiveSnapshotSource(source)) {
        // Ranked earthquake lists are full snapshots. Journal their complete
        // normalized list once, then fingerprint only after every bounded D1
        // slice commits; a repeated unchanged frame therefore makes no
        // per-event Durable Object writes.
        this.state.waitUntil(
          this.enqueueLiveSnapshot(source, normalizedEvents, readinessCandidate),
        );
        return;
      }
      for (const normalized of normalizedEvents) {
        // The journal persists first and marks freshness only after the D1
        // event/outbox transaction commits. Multiple revisions are safely
        // coalesced and serialized by the Durable Object drain.
        this.state.waitUntil(this.enqueueLiveIngest(normalized, readinessCandidate));
      }
    });
    socket.addEventListener("close", (event) => {
      // A replaced socket must not erase the status or reconnect request for a
      // newer healthy connection to the same route.
      if (this.upstreams.get(route) !== socket) return;
      // Close reasons are upstream-controlled text, so expose only bounded,
      // operationally useful metadata in the structured log.
      this.upstreams.delete(route);
      this.clearUpstreamLiveness(route);
      this.setRouteStatus(route, "closed");
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
      this.clearUpstreamLiveness(route);
      this.setRouteStatus(route, "error");
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
    this.statuses.set(route, status);
  }

  private clearUpstreamLiveness(route: UpstreamRoute): void {
    this.upstreamActivatedAtMs.delete(route);
    this.upstreamLivenessSinceMs.delete(route);
    this.lastUpstreamTransportMessageMs.delete(route);
    this.stableReconnectBackoffResetRoutes.delete(route);
    this.validatedUpstreamDataSockets.delete(route);
    this.readyUpstreamSockets.delete(route);
  }

  /**
   * Record transport watchdog evidence without creating source readiness.
   * Only a socket already made ready by a durable data commit may use later
   * heartbeats to extend freshness or reset stable reconnect history.
   */
  private async recordUpstreamTransportLiveness(
    route: UpstreamRoute,
    socket: WebSocket,
  ): Promise<void> {
    if (this.upstreams.get(route) !== socket) return;
    const now = Date.now();
    const livenessSinceMs = this.upstreamLivenessSinceMs.get(route) ?? now;
    this.upstreamLivenessSinceMs.set(route, livenessSinceMs);
    this.lastUpstreamTransportMessageMs.set(route, now);

    if (this.readyUpstreamSockets.get(route) !== socket) {
      return;
    }
    await this.markSourceSuccessful(route, socket);

    // A close listener deletes the socket synchronously before it queues its
    // durable recovery. Re-check ownership after any freshness I/O so a stale
    // message cannot zero that recovery state.
    if (
      this.upstreams.get(route) !== socket ||
      now - livenessSinceMs < UPSTREAM_RECONNECT_STABLE_LIVENESS_MS ||
      this.stableReconnectBackoffResetRoutes.has(route)
    ) {
      return;
    }
    this.stableReconnectBackoffResetRoutes.add(route);
    try {
      await this.resetUpstreamReconnectBackoff(route, socket);
    } catch (error) {
      // Retry on a subsequent valid frame if Durable Object storage is
      // temporarily unavailable; never claim a reset that did not persist.
      this.stableReconnectBackoffResetRoutes.delete(route);
      throw error;
    }
  }

  private serializeFreshnessUpdate<T>(
    key: string,
    operation: () => Promise<T>,
  ): Promise<T> {
    const previous = this.freshnessUpdates.get(key) ?? Promise.resolve();
    const update = previous.then(
      () => operation(),
      () => operation(),
    );
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

  private markSourceSuccessful(
    source: WolfxSourceId,
    expectedReadySocket?: WebSocket,
  ): Promise<boolean> {
    return this.serializeFreshnessUpdate(`websocket:${source}`, async () => {
      const route = isApnsRelaySource(source) ? source : null;
      if (
        expectedReadySocket &&
        (
          route === null ||
          this.upstreams.get(route) !== expectedReadySocket ||
          this.readyUpstreamSockets.get(route) !== expectedReadySocket
        )
      ) {
        return false;
      }
      const pendingForSource = await this.state.storage.list({
        prefix: `${PENDING_INGEST_PREFIX}${source}:`,
        limit: 1,
      });
      const pendingLiveSnapshot = isLiveSnapshotSource(source)
        ? await this.hasPendingLiveSnapshot(source)
        : false;
      // A heartbeat can prove that a socket is open, but not that its preceding
      // event or complete ranked list was durably committed. Leave readiness
      // stale until the appropriate journal drains successfully.
      if (pendingForSource.size > 0 || pendingLiveSnapshot) return false;
      const now = Date.now();
      const checkpointAvailable = await this.checkpointFreshness(
        source,
        `${UPSTREAM_LAST_SUCCESS_PREFIX}${source}`,
        this.lastPersistedUpstreamSuccessMs,
        this.lastUpstreamCheckpointAttemptMs,
        UPSTREAM_FRESHNESS_CHECKPOINT_INTERVAL_MS,
        now,
      );
      if (!checkpointAvailable) return false;
      // A close, invalid frame, or replacement socket may have won while the
      // heartbeat checkpoint was awaiting storage. Its old evidence may not
      // republish in-memory freshness for the new route lifecycle.
      if (
        expectedReadySocket &&
        (
          route === null ||
          this.upstreams.get(route) !== expectedReadySocket ||
          this.readyUpstreamSockets.get(route) !== expectedReadySocket
        )
      ) {
        return false;
      }
      this.lastSuccessfulUpstreamMs.set(source, now);
      return true;
    });
  }

  private async markSourceSuccessfulAndPublishReadiness(
    source: WolfxSourceId,
  ): Promise<void> {
    const route = isApnsRelaySource(source) ? source : null;
    const candidate = route === null
      ? null
      : this.validatedUpstreamDataSockets.get(route) ?? null;
    // Snapshot the token before the asynchronous pending-work check. If a new
    // frame records durable intent while an older completion is checkpointing,
    // the older completion cannot adopt that newer token after the await.
    const publishableCandidate = candidate?.durableIntentRecorded === true
      ? candidate
      : null;
    const checkpointAvailable = await this.markSourceSuccessful(source);
    if (
      !checkpointAvailable ||
      route === null ||
      publishableCandidate === null ||
      this.validatedUpstreamDataSockets.get(route) !== publishableCandidate ||
      this.upstreams.get(route) !== publishableCandidate.socket
    ) {
      return;
    }
    // This is the only transition into WebSocket readiness: this exact frame
    // was durably admitted, every source fence is now drained, and the current
    // socket's freshness checkpoint succeeded.
    this.readyUpstreamSockets.set(route, publishableCandidate.socket);
    this.validatedUpstreamDataSockets.delete(route);
    this.setRouteStatus(route, "open");
  }

  private markHttpSourceSuccessful(source: WolfxSourceId): Promise<void> {
    return this.serializeFreshnessUpdate(`http:${source}`, async () => {
      const pendingForSource = await this.state.storage.list({
        prefix: `${PENDING_INGEST_PREFIX}${source}:`,
        limit: 1,
      });
      const pendingLiveSnapshot = isLiveSnapshotSource(source)
        ? await this.hasPendingLiveSnapshot(source)
        : false;
      // Do not let an HTTP response cover up a WebSocket event that reached the
      // relay but has not crossed the D1 durability boundary yet.
      if (pendingForSource.size > 0 || pendingLiveSnapshot) return;
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
    if (!isApnsRelaySource(source)) {
      return { completed: false, snapshotWorkStarted: false };
    }
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
      limit: APNS_RELAY_SOURCES.length,
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
      APNS_RELAY_SOURCES.map((source) =>
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
      APNS_RELAY_SOURCES.map(async (candidate) => ({
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
    // cannot immediately re-run the full JMA-only sweep. Claim it
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
    if (!isApnsRelaySource(event.sourceId)) {
      throw new RangeError("APNs relay source is not permitted");
    }
    const { message } = await persistEventAndOutbox(
      this.env.DB,
      event,
      (acceptedEvent, previous) => {
        const reason = notificationReasonForEvent(acceptedEvent, previous);
        if (!reason || mode === "initial") return null;
        if (mode === "recovery" && !isRecentHttpRecoveryEvent(acceptedEvent)) {
          return null;
        }
        return createAlertDeliveryMessage(acceptedEvent, reason);
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

function trainingTestEvent(now = new Date().toISOString()): NormalizedEvent {
  return {
    // Training alerts exercise only the fixed relay policy, never a legacy
    // registration's first stored source selection.
    id: TRAINING_TEST_EVENT_ID, sourceId: "jma_eew", eventId: "TEST-EVENT",
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
      // Prepare the deterministic training collapse ID before the ownership
      // lookup. A delayed appointment that is deleted while this preparation
      // waits must never carry a stale row into the relay.
      const collapseId = await apnsCollapseID(trainingTestEvent());
      // The global relay performs a second exact-revision lookup inside its
      // APNs serial lane. This local read avoids scheduling an obviously
      // deleted key, while the relay closes the final read/send race.
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
      if (
        !productionTestPushAllowed(
          this.env.ENABLE_PRODUCTION_TEST_PUSH,
          device.environment,
          "delayed",
        ) ||
        !hasApnsConfiguration(this.env)
      ) return;
      const result = await productionTrainingPushThroughRelay(
        this.env,
        device,
        "delayed",
        new Date(
          job.dueAtMs + DELAYED_TRAINING_TEST_PUSH_MAX_LATE_MS,
        ).toISOString(),
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

function canonicalIpv4(value: string): string | null {
  const parts = value.split(".");
  if (parts.length !== 4) return null;
  const octets: number[] = [];
  for (const part of parts) {
    if (!/^\d{1,3}$/.test(part)) return null;
    const octet = Number(part);
    if (!Number.isSafeInteger(octet) || octet < 0 || octet > 255) return null;
    octets.push(octet);
  }
  return octets.join(".");
}

export function cloudflareAuthenticatedClientIp(request: Request): string | null {
  // Cloudflare overwrites this header at the Worker boundary. Accept only the
  // exact IPv4/IPv6 forms it supplies; alphabet-only checks would let values
  // such as `A` or `::::` escape the documented malformed-header fallback.
  // Canonicalization also makes IPv6 compression/case and zero-padded IPv4
  // aliases consume one budget. The raw value never leaves this function.
  const value = request.headers.get("cf-connecting-ip")?.trim();
  if (!value || value.length > 45) return null;
  if (!value.includes(":")) return canonicalIpv4(value);
  if (!/^[0-9A-Fa-f:.]+$/.test(value)) return null;
  let candidate = value;
  const lastColon = candidate.lastIndexOf(":");
  const dottedTail = candidate.slice(lastColon + 1);
  if (dottedTail.includes(".")) {
    const canonicalTail = canonicalIpv4(dottedTail);
    if (canonicalTail === null) return null;
    candidate = `${candidate.slice(0, lastColon + 1)}${canonicalTail}`;
  }
  try {
    const hostname = new URL(`http://[${candidate}]/`).hostname;
    if (!hostname.startsWith("[") || !hostname.endsWith("]")) return null;
    const canonical = hostname.slice(1, -1).toLowerCase();
    return canonical.includes(":") ? canonical : null;
  } catch {
    return null;
  }
}

async function deviceClientRateLimitKey(
  request: Request,
  route: string,
): Promise<string> {
  const clientIp = cloudflareAuthenticatedClientIp(request) ??
    "missing-cloudflare-client-ip";
  return sha256Hex(
    JSON.stringify([
      "quakesignal-device-rate-limit",
      "cloudflare-client-ip",
      route,
      clientIp,
    ]),
  );
}

function logDeviceRateLimitOutcome(
  outcome:
    | "device_api_rate_limited"
    | "device_api_rate_limit_unavailable",
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
  request: Request,
  env: Env,
  route: string,
): Promise<Response | null> {
  try {
    // The historically named challenge binding is the lower per-client
    // pre-proof budget for every public route. DEVICE_API_RATE_LIMIT is
    // reserved for the materially higher route-wide circuit breaker below.
    const outcome = await env.APP_ATTEST_CHALLENGE_RATE_LIMIT.limit({
      key: await deviceClientRateLimitKey(request, route),
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

async function enforceDeviceEndpointCircuitBreaker(
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
    logDeviceRateLimitOutcome(
      "device_api_rate_limit_unavailable",
      route,
      undefined,
      error,
    );
  }
  return deviceRateLimitResponse();
}

async function enforceDeviceEndpointBudgets(
  request: Request,
  env: Env,
  route: string,
): Promise<Response | null> {
  const clientResponse = await enforceDeviceEndpointRateLimit(
    request,
    env,
    route,
  );
  if (clientResponse) return clientResponse;
  // Only requests admitted by their pseudonymous client bucket consume this
  // materially higher route-wide circuit breaker. This keeps distributed
  // invalid proofs from removing the Worker's overall blast-radius cap.
  return enforceDeviceEndpointCircuitBreaker(env, route);
}

function publicEndpointRateLimitRoute(request: Request, url: URL): string {
  const method = ["GET", "POST", "DELETE", "OPTIONS"].includes(request.method)
    ? request.method
    : "OTHER";
  const exactPaths = new Set([
    "/",
    "/privacy",
    "/terms",
    "/support",
    "/healthz",
    "/v1/app-attest/challenge",
    "/v1/devices",
    "/v1/devices/test",
  ]);
  if (exactPaths.has(url.pathname)) return `${method} ${url.pathname}`;
  if (
    url.pathname === "/v1/live" ||
    url.pathname === "/v1/quakes/recent" ||
    url.pathname.startsWith("/v1/quakes/")
  ) return `${method} /v1/quakes/*`;
  if (url.pathname.startsWith("/v1/app-attest/")) {
    return `${method} /v1/app-attest/*`;
  }
  // Never incorporate attacker-selected unknown path/method text into the
  // native limiter key: every unmatched request shares one bounded route.
  return `${method} /unmatched`;
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
  // The Apple callback provides opaque, variable-length bytes; the client
  // serializes those bytes as canonical lowercase hexadecimal. Validate that
  // transport encoding without assuming today's APNs byte length.
  return (
    typeof value === "string" &&
    value.length >= 10 &&
    value.length <= MAX_DEVICE_TOKEN_LENGTH &&
    value.length % 2 === 0 &&
    /^[0-9a-f]+$/.test(value)
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
  app_id: string;
}

interface AttestedDeviceMutation {
  mode: "attested";
  keyId: string;
  /** The verified Apple AAGUID environment, never client supplied. */
  environment: AppAttestEnvironment;
  challenge: AppAttestChallengeBinding;
  verification: Awaited<ReturnType<typeof verifyAppAttestProof>>;
  /** App identity verified by this proof and resolved only from server config. */
  appRoute: AuthenticatedAppRoute;
}

interface DevelopmentBypassDeviceMutation {
  mode: "development_bypass";
  keyId: null;
  /** Always the configured primary route; bypass never trusts client identity. */
  appRoute: AuthenticatedAppRoute;
}

type AuthorizedDeviceMutation =
  | AttestedDeviceMutation
  | DevelopmentBypassDeviceMutation;

function appRouteForAuthorizedMutation(
  authorization: AuthorizedDeviceMutation,
): AuthenticatedAppRoute {
  if (!isAuthenticatedAppRoute(authorization.appRoute)) {
    throw new AppIdentityRouteNotAllowedError();
  }
  return authorization.appRoute;
}

interface DeviceRegistrationValues {
  token: string;
  environment: "sandbox" | "production";
  locale: string | null;
  sources: string;
  minMagnitude: number;
  alertSound: AlertSound;
  cityName: string | null;
  latitude: number | null;
  longitude: number | null;
  radiusKm: number | null;
  includeTestAlerts: number;
  utcOffsetMinutes: number | null;
  notifyAtNight: number;
  now: string;
}

type ApnsDeviceEnvironment = DeviceRegistrationValues["environment"];

/**
 * App Attest's verifier environment is server-authenticated, whereas an APNs
 * environment in a JSON body is only client input. Keep the conversion in one
 * place so a production verifier cannot be used to register a sandbox token,
 * or vice versa.
 */
export function apnsEnvironmentForAppAttestEnvironment(
  environment: AppAttestEnvironment,
): ApnsDeviceEnvironment {
  return environment === "development" ? "sandbox" : "production";
}

/**
 * Development bypasses are local/staging-only and may never create a
 * production APNs subscription. Production bypasses are already impossible
 * by configuration, but this default keeps direct callers fail-closed too.
 */
export function apnsEnvironmentForAuthorizedDeviceMutation(
  authorization: Pick<AuthorizedDeviceMutation, "mode"> & {
    environment?: AppAttestEnvironment;
  },
): ApnsDeviceEnvironment {
  return authorization.mode === "attested"
    ? apnsEnvironmentForAppAttestEnvironment(authorization.environment ?? "production")
    : "sandbox";
}

/** The APNs population that this Worker instance is allowed to deliver to. */
export function apnsDeviceEnvironmentForWorker(
  env: AppAttestPolicyEnvironment,
): ApnsDeviceEnvironment {
  return apnsEnvironmentForAppAttestEnvironment(
    appAttestVerificationEnvironment(env),
  );
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

function appAttestRequired(env: AppAttestPolicyEnvironment): boolean {
  // Fail closed by default. A local-only worker can deliberately set
  // `disabled`; checked-in production configuration always uses `required`.
  return env.APP_ATTEST_ENFORCEMENT !== "disabled";
}

function appAttestDevelopmentBypassAllowed(env: AppAttestPolicyEnvironment): boolean {
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

export function appAttestAllowedBundleVersions(
  env: AppAttestPolicyEnvironment,
): Set<string> {
  const configured = env.APP_ATTEST_ALLOWED_BUNDLE_VERSIONS ?? "1";
  return new Set(
    configured
      .split(",")
      .map((value) => value.trim())
      .filter((value) => /^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$/.test(value)),
  );
}

/**
 * The effective, non-secret App Attest deployment policy. This is a
 * deployment-consistency signal only: on iOS releases whose valid proofs lack
 * Apple's optional release-metadata extension, an allowed bundle version
 * cannot be cryptographically observed on every request.
 */
export interface AppAttestPolicy {
  appId: string;
  protocolVersion: string;
  required: boolean;
  developmentBypassAllowed: boolean;
  verificationEnvironment: AppAttestEnvironment;
  requireReleaseMetadata: boolean;
  allowedBundleVersions: string[];
  authenticatedAppRoutes: AuthenticatedAppRoute[];
}

export function effectiveAppAttestPolicy(
  env: AppAttestPolicyEnvironment & AppIdentityRoutingEnvironment,
): AppAttestPolicy {
  return {
    appId: env.APP_ATTEST_APP_ID ?? APP_ATTEST_APP_ID,
    protocolVersion: APP_ATTEST_PROTOCOL_VERSION,
    required: appAttestRequired(env),
    developmentBypassAllowed: appAttestDevelopmentBypassAllowed(env),
    verificationEnvironment: appAttestVerificationEnvironment(env),
    requireReleaseMetadata: env.APP_ATTEST_REQUIRE_RELEASE_METADATA === "true",
    allowedBundleVersions: [...appAttestAllowedBundleVersions(env)].sort(),
    authenticatedAppRoutes: configuredAppIdentityRoutes(env),
  };
}

/**
 * Fixed-order, UTF-8 policy serialization used for the public health
 * fingerprint. Keep this deliberately simple rather than hashing a rendered
 * JSON object: release automation in another runtime must produce the exact
 * same bytes without relying on object-key insertion order.
 */
export function canonicalAppAttestPolicy(policy: AppAttestPolicy): string {
  const allowedBundleVersions = [...new Set(policy.allowedBundleVersions)].sort();
  const authenticatedAppRoutes = policy.authenticatedAppRoutes
    .map(({ appIdentity, apnsTopic, platform }) => ({
      appIdentity,
      apnsTopic,
      platform,
    }))
    .sort((left, right) =>
      left.appIdentity < right.appIdentity
        ? -1
        : left.appIdentity > right.appIdentity
          ? 1
          : 0
    );
  return [
    `app_id=${policy.appId}`,
    `protocol_version=${policy.protocolVersion}`,
    `required=${policy.required}`,
    `development_bypass_allowed=${policy.developmentBypassAllowed}`,
    `verification_environment=${policy.verificationEnvironment}`,
    `require_release_metadata=${policy.requireReleaseMetadata}`,
    `allowed_bundle_versions=${allowedBundleVersions.join(",")}`,
    `app_attest_apns_routes=${JSON.stringify(authenticatedAppRoutes)}`,
    "",
  ].join("\n");
}

/**
 * A stable, public deployment fingerprint. It contains no key material,
 * tokens, or device identity, and runs entirely in the outer Worker before a
 * health request ever reaches the global Durable Object.
 */
export async function appAttestPolicyFingerprint(
  policy: AppAttestPolicy,
): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(canonicalAppAttestPolicy(policy)),
  );
  return `sha256:${base64URL(new Uint8Array(digest))}`;
}

interface AppAttestHealthPolicy {
  format: typeof APP_ATTEST_POLICY_FORMAT;
  fingerprint: string;
  /** Needed for the release smoke test to prove the expected build is accepted. */
  allowedBundleVersions: string[];
}

async function appAttestHealthPolicy(
  env: AppAttestPolicyEnvironment & AppIdentityRoutingEnvironment,
): Promise<AppAttestHealthPolicy> {
  const policy = effectiveAppAttestPolicy(env);
  return {
    format: APP_ATTEST_POLICY_FORMAT,
    fingerprint: await appAttestPolicyFingerprint(policy),
    allowedBundleVersions: policy.allowedBundleVersions,
  };
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
  const sources = body.sources === undefined ? APNS_RELAY_SOURCES : body.sources;
  return {
    token: body.token as string,
    environment: body.environment === "sandbox" ? "sandbox" : "production",
    locale: typeof body.locale === "string" ? body.locale : null,
    sources: JSON.stringify(sources),
    minMagnitude: typeof body.minMagnitude === "number" ? body.minMagnitude : 0,
    alertSound: normalizedAlertSound(body.alertSound),
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
  appRoute: AuthenticatedAppRoute,
  guardSql = "1 = 1",
  guardBindings: unknown[] = [],
  allowAttestedTokenRebind = false,
): D1PreparedStatement {
  const registrationRevision = crypto.randomUUID();
  return db
    .prepare(
      `INSERT INTO devices (
        token, environment, locale, sources, min_magnitude,
        critical_alerts_enabled, alert_sound, city_name, latitude, longitude, radius_km,
        include_test_alerts, utc_offset_minutes, notify_at_night,
        app_attest_key_id, app_identity, apns_topic, app_platform,
        registration_revision, created_at, updated_at
      ) SELECT ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
      WHERE ${guardSql}
      ON CONFLICT(token) DO UPDATE SET
        environment = excluded.environment,
        locale = excluded.locale,
        sources = excluded.sources,
        min_magnitude = excluded.min_magnitude,
        critical_alerts_enabled = 0,
        alert_sound = excluded.alert_sound,
        city_name = excluded.city_name,
        latitude = excluded.latitude,
        longitude = excluded.longitude,
        radius_km = excluded.radius_km,
        include_test_alerts = excluded.include_test_alerts,
        utc_offset_minutes = excluded.utc_offset_minutes,
        notify_at_night = excluded.notify_at_night,
        app_attest_key_id = excluded.app_attest_key_id,
        app_identity = excluded.app_identity,
        apns_topic = excluded.apns_topic,
        app_platform = excluded.app_platform,
        registration_revision = excluded.registration_revision,
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
      values.alertSound ?? DEFAULT_ALERT_SOUND,
      values.cityName,
      values.latitude,
      values.longitude,
      values.radiusKm,
      values.includeTestAlerts,
      values.utcOffsetMinutes,
      values.notifyAtNight,
      appAttestKeyId,
      appRoute.appIdentity,
      appRoute.apnsTopic,
      appRoute.platform,
      registrationRevision,
      values.now,
      values.now,
      ...guardBindings,
      allowAttestedTokenRebind ? 1 : 0,
    );
}

function registrationContinuityFenceStatement(
  db: D1Database,
  token: string,
  tokenHashValue: string,
  appAttestKeyId: string | null,
  observedAtUtc: string,
  guardSql = "1 = 1",
  guardBindings: unknown[] = [],
): D1PreparedStatement {
  return db
    .prepare(
      `INSERT OR IGNORE INTO apns_registration_revision_fences (
         token_hash, registration_revision, app_attest_key_id,
         decision_id, decision_kind,
         blocks_lifecycle_replay, processed_at_utc
       )
       SELECT ?, registration_revision, ?, ?, 'registration_renewal', 0, ?
       FROM devices
       WHERE token = ? AND ${guardSql}`,
    )
    .bind(
      tokenHashValue,
      appAttestKeyId,
      crypto.randomUUID(),
      observedAtUtc,
      token,
      ...guardBindings,
    );
}

async function authorizeAppAttestMutation(
  request: Request,
  payload: DeviceRequestPayload,
  env: Env,
  operation: AppAttestOperation,
): Promise<AuthorizedDeviceMutation | Response> {
  if (!appAttestRequired(env)) {
    try {
      return {
        mode: "development_bypass",
        keyId: null,
        appRoute: defaultAppIdentityRoute(env),
      };
    } catch {
      return appAttestFailureResponse();
    }
  }
  if (
    request.headers.get(APP_ATTEST_DEVELOPMENT_BYPASS_HEADER) ===
    APP_ATTEST_DEVELOPMENT_BYPASS_VALUE
  ) {
    if (!appAttestDevelopmentBypassAllowed(env)) return appAttestFailureResponse();
    try {
      return {
        mode: "development_bypass",
        keyId: null,
        appRoute: defaultAppIdentityRoute(env),
      };
    } catch {
      return appAttestFailureResponse();
    }
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
        `SELECT key_id, public_key_pem, sign_count, app_id FROM app_attest_keys
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
    const appRoute = authenticatedAppRouteForRequest(
      env,
      payload.body,
      existingRow?.app_id,
    );
    const verification = await verifyAppAttestProof({
      appId: appRoute.appIdentity,
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
      appRoute,
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
  // Keep this transaction-level fence in addition to the HTTP-handler
  // validation below. It prevents a future direct caller from consuming a
  // verified challenge while writing a token for the opposite APNs endpoint.
  if (
    values.environment !== apnsEnvironmentForAuthorizedDeviceMutation(authorization)
  ) {
    return "conflict";
  }
  const now = values.now;
  const matching = challengeMatchesNow(authorization.challenge, now);
  const consumed = challengeConsumedNowCondition(authorization.challenge.id, now);
  const verification = authorization.verification;
  const metadata = verification.metadata;
  const appAttestEnvironment = appAttestMutationEnvironment(authorization);
  const appRoute = appRouteForAuthorizedMutation(authorization);
  const currentTokenHash = await tokenHash(values.token);
  const baseOwnership = registrationOwnershipCondition(
    values.token,
    authorization.keyId,
    verification.proofType,
  );
  const ownership = {
    sql: `(${baseOwnership.sql}) AND NOT EXISTS (
      SELECT 1 FROM apns_provider_attempts
      WHERE token_hash = ? AND outcome_reconciled_at_utc IS NULL
    )`,
    bindings: [...baseOwnership.bindings, currentTokenHash],
  };
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
          appRoute.appIdentity,
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
  // Remove a prior subscription's ordinary token-hashed failure evidence in
  // the same guarded transaction as its device row. Active BadDeviceToken
  // evidence is fenced and resolved instead. Dedicated processed-revision
  // fences survive the device/failure cleanup: a duplicate stale APNs response
  // for the retired token may arrive after it is registered again.
  const priorDevices = await db
    .prepare(
      `SELECT token, registration_revision FROM devices
       WHERE app_attest_key_id = ? AND token <> ?`,
    )
    .bind(authorization.keyId, values.token)
    .all<{ token: string; registration_revision: string }>();
  const priorDeviceFailureRecords = await Promise.all(
    priorDevices.results.map(async ({ token, registration_revision }) => ({
      token,
      tokenHash: await tokenHash(token),
      registrationRevision: registration_revision,
    })),
  );

  const priorTokenCleanup = [
    // Keep bounded delivery dedupe for a retired token until its ordinary
    // 14-day cleanup. A pre-send intent that crashed after its D1 acceptance
    // uses this exact delivery/token row as the universal completion fence
    // before remapping an unresolved recipient to the rotated token.
    ...priorDeviceFailureRecords.flatMap(({
      token,
      tokenHash: hashedToken,
      registrationRevision,
    }) => {
      // Every prior-token mutation is guarded by that token's own provider
      // attempt hash. The target-token ownership predicate above deliberately
      // cannot authorize cleanup of a rotated sibling.
      const priorOwnership = {
        sql: `NOT EXISTS (
          SELECT 1 FROM apns_provider_attempts
          WHERE token_hash = ? AND outcome_reconciled_at_utc IS NULL
        )`,
        bindings: [hashedToken],
      };
      return [
      db
        .prepare(
          `INSERT INTO alert_lifecycle_recipients (
             event_ref, token_hash, app_attest_key_id, registration_revision,
             evidence_kind, first_evidence_at_utc, last_evidence_at_utc
           )
           SELECT outbox.event_ref, ?, ?, ?, 'apns_accepted',
                  MIN(delivery.delivered_at_utc),
                  MAX(delivery.delivered_at_utc)
           FROM notification_deliveries AS delivery
           JOIN alert_delivery_outbox AS outbox
             ON outbox.delivery_id = delivery.delivery_id
           WHERE delivery.device_token = ?
             AND delivery.lifecycle_reconciled = 0
             AND outbox.notification_reason IN ('new', 'updated')
             AND json_valid(outbox.event_json)
             AND EXISTS (
               SELECT 1 FROM json_each(
                 CASE WHEN json_valid(?) THEN ? ELSE '[]' END
               ) WHERE value = json_extract(outbox.event_json, '$.sourceId')
             )
             AND EXISTS (
               SELECT 1 FROM devices
               WHERE token = ? AND registration_revision = ?
                 AND app_attest_key_id = ? AND token <> ?
                 AND ${consumed.sql} AND ${priorOwnership.sql}
             )
           GROUP BY outbox.event_ref
           ON CONFLICT(event_ref, token_hash) DO UPDATE SET
             app_attest_key_id = excluded.app_attest_key_id,
             registration_revision = excluded.registration_revision,
             evidence_kind = 'apns_accepted',
             first_evidence_at_utc = MIN(
               alert_lifecycle_recipients.first_evidence_at_utc,
               excluded.first_evidence_at_utc
             ),
             last_evidence_at_utc = MAX(
               alert_lifecycle_recipients.last_evidence_at_utc,
               excluded.last_evidence_at_utc
             )`,
        )
        .bind(
          hashedToken,
          authorization.keyId,
          registrationRevision,
          token,
          values.sources,
          values.sources,
          token,
          registrationRevision,
          authorization.keyId,
          values.token,
          ...consumed.bindings,
          ...priorOwnership.bindings,
        ),
      db
        .prepare(
          `UPDATE notification_deliveries
           SET lifecycle_reconciled = 1
           WHERE device_token = ? AND lifecycle_reconciled = 0
             AND EXISTS (
               SELECT 1 FROM devices
               WHERE token = ? AND registration_revision = ?
                 AND app_attest_key_id = ? AND token <> ?
                 AND ${consumed.sql} AND ${priorOwnership.sql}
             )`,
        )
        .bind(
          token,
          token,
          registrationRevision,
          authorization.keyId,
          values.token,
          ...consumed.bindings,
          ...priorOwnership.bindings,
        ),
      db
        .prepare(
          `INSERT OR IGNORE INTO apns_registration_revision_fences (
             token_hash, registration_revision, app_attest_key_id,
             decision_id, decision_kind,
             blocks_lifecycle_replay, processed_at_utc
           ) SELECT ?, ?, ?, ?, 'token_rotation', 0, ?
           WHERE EXISTS (
             SELECT 1 FROM devices
             WHERE token = ? AND registration_revision = ?
               AND app_attest_key_id = ? AND token <> ?
               AND ${consumed.sql} AND ${priorOwnership.sql}
           )`,
        )
        .bind(
          hashedToken,
          registrationRevision,
          authorization.keyId,
          crypto.randomUUID(),
          now,
          token,
          registrationRevision,
          authorization.keyId,
          values.token,
          ...consumed.bindings,
          ...priorOwnership.bindings,
        ),
      db
        .prepare(
          `INSERT OR IGNORE INTO apns_registration_revision_fences (
             token_hash, registration_revision, app_attest_key_id,
             decision_id, decision_kind,
             blocks_lifecycle_replay, processed_at_utc
           )
           SELECT token_hash, registration_revision, ?,
                  lower(hex(randomblob(16))), 'bad_device_token', 1,
                  MAX(?, last_seen_utc)
           FROM alert_delivery_failures
           WHERE token_hash = ? AND status = 'active'
             AND apns_reason = 'BadDeviceToken'
             AND registration_revision IS NOT NULL
             AND EXISTS (
               SELECT 1 FROM devices
               WHERE token = ? AND registration_revision = ?
                 AND app_attest_key_id = ? AND token <> ?
               AND ${consumed.sql} AND ${priorOwnership.sql}
             )
           ON CONFLICT(registration_revision) DO UPDATE SET
             token_hash = COALESCE(
               excluded.token_hash,
               apns_registration_revision_fences.token_hash
             ),
             decision_kind = 'bad_device_token',
             blocks_lifecycle_replay = 1,
             processed_at_utc = MAX(
               excluded.processed_at_utc,
               apns_registration_revision_fences.processed_at_utc
             )`,
        )
        .bind(
          authorization.keyId,
          now,
          hashedToken,
          token,
          registrationRevision,
          authorization.keyId,
          values.token,
          ...consumed.bindings,
          ...priorOwnership.bindings,
        ),
      db
        .prepare(
          `UPDATE alert_delivery_failures
           SET status = 'resolved',
               resolved_at_utc = MAX(?, last_seen_utc),
               last_seen_utc = MAX(?, last_seen_utc)
           WHERE token_hash = ? AND apns_reason = 'BadDeviceToken'
             AND status = 'active' AND EXISTS (
               SELECT 1 FROM devices
               WHERE token = ? AND app_attest_key_id = ? AND token <> ?
                 AND ${consumed.sql} AND ${priorOwnership.sql}
             )`,
        )
        .bind(
          now,
          now,
          hashedToken,
          token,
          authorization.keyId,
          values.token,
          ...consumed.bindings,
          ...priorOwnership.bindings,
        ),
      db
        .prepare(
          `DELETE FROM alert_delivery_failures
           WHERE token_hash = ?
             AND COALESCE(apns_reason, '') <> 'BadDeviceToken'
             AND EXISTS (
               SELECT 1 FROM devices
               WHERE token = ? AND app_attest_key_id = ? AND token <> ?
                 AND ${consumed.sql} AND ${priorOwnership.sql}
             )`,
        )
        .bind(
          hashedToken,
          token,
          authorization.keyId,
          values.token,
          ...consumed.bindings,
          ...priorOwnership.bindings,
        ),
      ];
    }),
    ...priorDeviceFailureRecords.map(({
      token,
      tokenHash: hashedToken,
      registrationRevision,
    }) =>
      db
        .prepare(
          `DELETE FROM devices
           WHERE token = ? AND registration_revision = ?
             AND app_attest_key_id = ?
             AND ${consumed.sql}
             AND NOT EXISTS (
               SELECT 1 FROM apns_provider_attempts
               WHERE token_hash = ? AND outcome_reconciled_at_utc IS NULL
             )`,
        )
        .bind(
          token,
          registrationRevision,
          authorization.keyId,
          ...consumed.bindings,
          hashedToken,
        )
    ),
  ];
  // Capture the exact token's owner inside the D1 batch, before the UPSERT
  // replaces it. Two concurrent fresh-key rebinds therefore serialize A→B→C:
  // C observes B transactionally and carries every rotated-token lineage to C
  // instead of relying on a stale JS pre-read of A.
  const transactionalLineageRekey = [
    db
      .prepare(
        `UPDATE alert_lifecycle_recipients
         SET app_attest_key_id = ?
         WHERE (
           token_hash = ?
           OR app_attest_key_id IN (
             SELECT app_attest_key_id FROM devices
             WHERE token = ? AND app_attest_key_id IS NOT NULL
           )
         ) AND ${consumed.sql} AND ${ownership.sql}`,
      )
      .bind(
        authorization.keyId,
        currentTokenHash,
        values.token,
        ...consumed.bindings,
        ...ownership.bindings,
      ),
    db
      .prepare(
        `UPDATE apns_registration_revision_fences
         SET app_attest_key_id = ?
         WHERE (
           token_hash = ?
           OR app_attest_key_id IN (
             SELECT app_attest_key_id FROM devices
             WHERE token = ? AND app_attest_key_id IS NOT NULL
           )
         ) AND ${consumed.sql} AND ${ownership.sql}`,
      )
      .bind(
        authorization.keyId,
        currentTokenHash,
        values.token,
        ...consumed.bindings,
        ...ownership.bindings,
      ),
    db
      .prepare(
        `UPDATE alert_lifecycle_possible_attempts
         SET app_attest_key_id = ?
         WHERE (
           token_hash = ?
           OR app_attest_key_id IN (
             SELECT app_attest_key_id FROM devices
             WHERE token = ? AND app_attest_key_id IS NOT NULL
           )
         ) AND ${consumed.sql} AND ${ownership.sql}`,
      )
      .bind(
        authorization.keyId,
        currentTokenHash,
        values.token,
        ...consumed.bindings,
        ...ownership.bindings,
      ),
  ];
  const sameTokenContinuityFence = registrationContinuityFenceStatement(
    db,
    values.token,
    currentTokenHash,
    authorization.keyId,
    now,
    consumed.sql,
    consumed.bindings,
  );
  const registrationIndex = commonStatements.length +
    priorTokenCleanup.length + transactionalLineageRekey.length + 1;

  const results = await db.batch([
    ...commonStatements,
    ...priorTokenCleanup,
    ...transactionalLineageRekey,
    sameTokenContinuityFence,
    registrationStatement(
      db,
      values,
      authorization.keyId,
      appRoute,
      consumed.sql,
      consumed.bindings,
      verification.proofType === "attestation",
    ),
    // A fallback BadDeviceToken failure can serialize just before this
    // authenticated renewal. Fence each sent revision before resolving its
    // active health row so a later duplicate response cannot act on the fresh
    // registration.
    db
      .prepare(
        `INSERT OR IGNORE INTO apns_registration_revision_fences (
           token_hash, registration_revision, app_attest_key_id,
           decision_id, decision_kind,
           blocks_lifecycle_replay, processed_at_utc
         )
         SELECT token_hash, registration_revision, ?,
                lower(hex(randomblob(16))), 'bad_device_token', 1,
                MAX(?, last_seen_utc)
         FROM alert_delivery_failures
         WHERE token_hash = ? AND apns_reason = 'BadDeviceToken'
           AND status = 'active' AND registration_revision IS NOT NULL
           AND EXISTS (
             SELECT 1 FROM devices
             WHERE token = ? AND app_attest_key_id = ? AND updated_at = ?
               AND ${consumed.sql}
           )
         ON CONFLICT(registration_revision) DO UPDATE SET
           token_hash = excluded.token_hash,
           app_attest_key_id = excluded.app_attest_key_id,
           decision_id = excluded.decision_id,
           decision_kind = 'bad_device_token',
           blocks_lifecycle_replay = 1,
           processed_at_utc = MAX(
             excluded.processed_at_utc,
             apns_registration_revision_fences.processed_at_utc
           )
         WHERE apns_registration_revision_fences.decision_kind =
                 'registration_renewal'
           AND apns_registration_revision_fences.blocks_lifecycle_replay = 0`,
      )
      .bind(
        authorization.keyId,
        now,
        currentTokenHash,
        values.token,
        authorization.keyId,
        now,
        ...consumed.bindings,
      ),
    // An authenticated same-token renewal serialized after quarantine is the
    // intentional recovery boundary. Resolve its active BadDeviceToken state,
    // while retaining the dedicated short-lived revision fence above.
    db
      .prepare(
        `UPDATE alert_delivery_failures
         SET status = 'resolved',
             resolved_at_utc = MAX(?, last_seen_utc),
             last_seen_utc = MAX(?, last_seen_utc)
         WHERE token_hash = ? AND apns_reason = 'BadDeviceToken'
           AND status = 'active' AND EXISTS (
           SELECT 1 FROM devices
           WHERE token = ? AND app_attest_key_id = ? AND updated_at = ?
             AND ${consumed.sql}
         )`,
      )
      .bind(
        now,
        now,
        currentTokenHash,
        values.token,
        authorization.keyId,
        now,
        ...consumed.bindings,
      ),
    // Other per-token failure evidence does not participate in the stale APNs
    // response fence and can keep the historical successful-renewal cleanup.
    db
      .prepare(
        `DELETE FROM alert_delivery_failures
         WHERE token_hash = ?
           AND COALESCE(apns_reason, '') <> 'BadDeviceToken'
           AND EXISTS (
             SELECT 1 FROM devices
             WHERE token = ? AND app_attest_key_id = ? AND updated_at = ?
               AND ${consumed.sql}
           )`,
      )
      .bind(
        currentTokenHash,
        values.token,
        authorization.keyId,
        now,
        ...consumed.bindings,
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
  const appRoute = appRouteForAuthorizedMutation(authorization);
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
          appRoute.appIdentity,
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
      `SELECT key_id, app_id FROM app_attest_keys
       WHERE key_id = ? AND environment = ? AND revoked_at_utc IS NULL`,
    )
    .bind(key.keyId, verificationEnvironment)
    .first<{ key_id: string; app_id: string }>();
  if (existing) {
    try {
      // Refuse even to issue an assertion challenge for a platform removed
      // from the server allow-list. A later proof cannot re-enable that route.
      authenticatedAppRouteForRequest(env, {}, existing.app_id);
    } catch {
      return appAttestFailureResponse();
    }
  }
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

export function validatedRegistrationValues(
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
  // `appIdentity` is only a selector for the App Attest verifier and must be
  // matched by the proof. Topic/platform are exclusively server-derived; do
  // not silently accept aliases that a future refactor might accidentally use.
  if (
    [
      "apnsTopic",
      "apns_topic",
      "topic",
      "bundleId",
      "bundleIdentifier",
      "appPlatform",
      "app_platform",
      "platform",
    ].some((name) => Object.hasOwn(body, name))
  ) {
    return json(
      { error: "APNs routing fields are server controlled" },
      400,
      noStoreHeaders(),
    );
  }
  if (
    body.appIdentity !== undefined &&
    (typeof body.appIdentity !== "string" ||
      !/^[A-Z0-9]{10}\.[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*$/.test(
        body.appIdentity,
      ) ||
      body.appIdentity.length > 266)
  ) {
    return json({ error: "app identity is invalid" }, 400, noStoreHeaders());
  }
  if (
    !isOptionalBoundedString(body.locale, 35) ||
    !isOptionalBoundedString(body.cityName, MAX_DEVICE_TEXT_LENGTH) ||
    (body.alertSound !== undefined && !isAlertSound(body.alertSound)) ||
    !isOptionalFiniteNumber(body.minMagnitude, 0, 10) ||
    !isOptionalFiniteNumber(body.radiusKm, 1, 2_000) ||
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
  if (!hasLatitude || body.radiusKm === undefined) {
    return json(
      { error: "latitude, longitude, and radiusKm are required" },
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
  if (
    values.environment !== apnsEnvironmentForAuthorizedDeviceMutation(authorization)
  ) {
    return json(
      { error: "device environment is not permitted for this app integrity environment" },
      400,
      noStoreHeaders(),
    );
  }
  try {
    if (authorization.mode === "attested") {
      if (
        (await completeAttestedRegistration(env.DB, authorization, values)) !==
        "completed"
      ) {
        return appAttestConflictResponse();
      }
    } else {
      const currentTokenHash = await tokenHash(values.token);
      const registrationResults = await env.DB.batch([
        registrationContinuityFenceStatement(
          env.DB,
          values.token,
          currentTokenHash,
          null,
          values.now,
          `NOT EXISTS (
            SELECT 1 FROM apns_provider_attempts
            WHERE token_hash = ? AND outcome_reconciled_at_utc IS NULL
          )`,
          [currentTokenHash],
        ),
        registrationStatement(
          env.DB,
          values,
          null,
          appRouteForAuthorizedMutation(authorization),
          `NOT EXISTS (
            SELECT 1 FROM apns_provider_attempts
            WHERE token_hash = ? AND outcome_reconciled_at_utc IS NULL
          )`,
          [currentTokenHash],
          false,
        ),
      ]);
      if ((registrationResults[1]?.meta.changes ?? 0) === 0) {
        throw new Error("device registration is fenced by an APNs attempt");
      }
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
export async function completeAttestedKeyBoundDeletion(
  db: D1Database,
  authorization: AttestedDeviceMutation,
): Promise<"completed" | "conflict"> {
  const deletionObservedAt = new Date().toISOString();
  // The unique index normally means this contains zero or one row. Reading
  // the current token only lets us remove the corresponding sanitized APNs
  // failure hash; it is never returned or logged. Each deleting statement
  // below repeats the key ownership check so a stale read cannot cross keys.
  const ownedDevices = await db
    .prepare(
      `SELECT token, registration_revision FROM devices
       WHERE app_attest_key_id = ?`,
    )
    .bind(authorization.keyId)
    .all<{ token: string; registration_revision: string }>();
  const ownedFailureRecords = await Promise.all(
    ownedDevices.results.map(async ({ token, registration_revision }) => ({
      token,
      tokenHash: await tokenHash(token),
      registrationRevision: registration_revision,
    })),
  );

  return completeAttestedAuthorization(
    db,
    authorization,
    (consumed) => [
      // Fence the revision observed by this transaction, not only the JS
      // pre-read above. A same-key renewal can commit between that read and
      // challenge consumption; the final key-wide DELETE must never retire an
      // unfenced revision that an in-flight APNs response can later reuse.
      db
        .prepare(
          `INSERT INTO apns_registration_revision_fences (
             token_hash, registration_revision, app_attest_key_id,
             decision_id, decision_kind,
             blocks_lifecycle_replay, processed_at_utc
           )
           SELECT NULL, registration_revision, app_attest_key_id,
                  lower(hex(randomblob(16))), 'explicit_removal', 1, ?
           FROM devices
           WHERE app_attest_key_id = ? AND ${consumed.sql}
           ON CONFLICT(registration_revision) DO UPDATE SET
             decision_kind = 'explicit_removal',
             blocks_lifecycle_replay = 1,
             processed_at_utc = MAX(
               excluded.processed_at_utc,
               apns_registration_revision_fences.processed_at_utc
             )`,
        )
        .bind(
          deletionObservedAt,
          authorization.keyId,
          ...consumed.bindings,
        ),
      db
        .prepare(
          `DELETE FROM notification_deliveries
           WHERE device_token IN (
             SELECT token FROM devices
             WHERE app_attest_key_id = ? AND ${consumed.sql}
           )`,
        )
        .bind(authorization.keyId, ...consumed.bindings),
      ...ownedFailureRecords.flatMap(({
        token,
        tokenHash: hashedToken,
        registrationRevision,
      }) => [
        db
          .prepare(
            `INSERT OR IGNORE INTO apns_registration_revision_fences (
               token_hash, registration_revision, app_attest_key_id,
               decision_id, decision_kind,
               blocks_lifecycle_replay, processed_at_utc
             ) SELECT ?, ?, ?, ?, 'explicit_removal', 1, ?
             WHERE EXISTS (
               SELECT 1 FROM devices
               WHERE token = ? AND registration_revision = ?
                 AND app_attest_key_id = ? AND ${consumed.sql}
             )`,
          )
          .bind(
            hashedToken,
            registrationRevision,
            authorization.keyId,
            crypto.randomUUID(),
            deletionObservedAt,
            token,
            registrationRevision,
            authorization.keyId,
            ...consumed.bindings,
          ),
        db
          .prepare(
            `INSERT OR IGNORE INTO apns_registration_revision_fences (
               token_hash, registration_revision, app_attest_key_id,
               decision_id, decision_kind,
               blocks_lifecycle_replay, processed_at_utc
             )
             SELECT token_hash, registration_revision, ?,
                    lower(hex(randomblob(16))), 'bad_device_token', 1,
                    MAX(?, last_seen_utc)
             FROM alert_delivery_failures
             WHERE token_hash = ? AND status = 'active'
               AND apns_reason = 'BadDeviceToken'
               AND registration_revision IS NOT NULL
               AND EXISTS (
                 SELECT 1 FROM devices
                 WHERE token = ? AND registration_revision = ?
                   AND app_attest_key_id = ? AND ${consumed.sql}
               )`,
          )
          .bind(
            authorization.keyId,
            deletionObservedAt,
            hashedToken,
            token,
            registrationRevision,
            authorization.keyId,
            ...consumed.bindings,
          ),
      ]),
      // A pending acceptance can belong to an older token revision retired by
      // this same key. Upgrade the entire authenticated continuity lineage,
      // not only the current row, so an explicit opt-out cannot be undone by
      // replay after a later same-token registration.
      db
        .prepare(
          `UPDATE apns_registration_revision_fences
           SET decision_kind = 'explicit_removal',
               blocks_lifecycle_replay = 1,
               processed_at_utc = MAX(processed_at_utc, ?)
           WHERE app_attest_key_id = ? AND EXISTS (
             SELECT 1 FROM devices
             WHERE app_attest_key_id = ? AND ${consumed.sql}
           )`,
        )
        .bind(
          deletionObservedAt,
          authorization.keyId,
          authorization.keyId,
          ...consumed.bindings,
        ),
      db
        .prepare(
          `DELETE FROM alert_delivery_failures
           WHERE registration_revision IN (
             SELECT registration_revision FROM devices
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
      ...ownedFailureRecords.map(({ token, tokenHash: hashedToken }) =>
        db
          .prepare(
            `DELETE FROM alert_lifecycle_recipients
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
          `DELETE FROM alert_lifecycle_recipients
           WHERE app_attest_key_id = ? AND ${consumed.sql}`,
        )
        .bind(authorization.keyId, ...consumed.bindings),
      db
        .prepare(
          `DELETE FROM devices
           WHERE app_attest_key_id = ? AND ${consumed.sql}`,
        )
        .bind(authorization.keyId, ...consumed.bindings),
      ...appAttestRetentionCleanupStatements(db, deletionObservedAt),
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
          `SELECT token, registration_revision FROM devices
           WHERE app_attest_key_id = ?
              OR (token = ? AND app_attest_key_id IS NULL)`,
        )
        .bind(authorization.keyId, body.token)
        .all<{ token: string; registration_revision: string }>();
      const deletionCandidateFailureRecords = await Promise.all(
        deletionCandidates.results.map(async ({ token, registration_revision }) => ({
          token,
          tokenHash: await tokenHash(token),
          registrationRevision: registration_revision,
        })),
      );
      const deletionObservedAt = new Date().toISOString();
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
              // Repeat the fence selection inside the challenge-consuming D1
              // transaction. The JS token/hash list can be stale if a
              // same-key renewal commits while its proof is being verified.
              env.DB
                .prepare(
                  `INSERT INTO apns_registration_revision_fences (
                     token_hash, registration_revision, app_attest_key_id,
                     decision_id, decision_kind,
                     blocks_lifecycle_replay, processed_at_utc
                   )
                   SELECT NULL, registration_revision, app_attest_key_id,
                          lower(hex(randomblob(16))),
                          'explicit_removal', 1, ?
                   FROM devices
                   WHERE ${ownedOrLegacyDeviceCondition}
                   ON CONFLICT(registration_revision) DO UPDATE SET
                     decision_kind = 'explicit_removal',
                     blocks_lifecycle_replay = 1,
                     processed_at_utc = MAX(
                       excluded.processed_at_utc,
                       apns_registration_revision_fences.processed_at_utc
                     )`,
                )
                .bind(
                  deletionObservedAt,
                  authorization.keyId,
                  body.token,
                  ...consumed.bindings,
                ),
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
              ...deletionCandidateFailureRecords.flatMap(({
                token,
                tokenHash: hashedToken,
                registrationRevision,
              }) => [
                env.DB
                  .prepare(
                    `INSERT OR IGNORE INTO apns_registration_revision_fences (
                       token_hash, registration_revision, app_attest_key_id,
                       decision_id,
                       decision_kind, blocks_lifecycle_replay, processed_at_utc
                     ) SELECT ?, ?, ?, ?, 'explicit_removal', 1, ?
                     WHERE EXISTS (
                       SELECT 1 FROM devices
                       WHERE token = ? AND registration_revision = ?
                         AND ${ownedOrLegacyDeviceCondition}
                     )`,
                  )
                  .bind(
                    hashedToken,
                    registrationRevision,
                    authorization.keyId,
                    crypto.randomUUID(),
                    deletionObservedAt,
                    token,
                    registrationRevision,
                    authorization.keyId,
                    body.token,
                    ...consumed.bindings,
                  ),
                env.DB
                  .prepare(
                    `INSERT OR IGNORE INTO apns_registration_revision_fences (
                       token_hash, registration_revision, app_attest_key_id,
                       decision_id,
                       decision_kind, blocks_lifecycle_replay, processed_at_utc
                     )
                     SELECT token_hash, registration_revision, ?,
                            lower(hex(randomblob(16))), 'bad_device_token', 1,
                            MAX(?, last_seen_utc)
                     FROM alert_delivery_failures
                     WHERE token_hash = ? AND status = 'active'
                       AND apns_reason = 'BadDeviceToken'
                       AND registration_revision IS NOT NULL
                       AND EXISTS (
                         SELECT 1 FROM devices
                         WHERE token = ? AND registration_revision = ?
                           AND ${ownedOrLegacyDeviceCondition}
                       )`,
                  )
                  .bind(
                    authorization.keyId,
                    deletionObservedAt,
                    hashedToken,
                    token,
                    registrationRevision,
                    authorization.keyId,
                    body.token,
                    ...consumed.bindings,
                  ),
              ]),
              env.DB
                .prepare(
                  `UPDATE apns_registration_revision_fences
                   SET decision_kind = 'explicit_removal',
                       blocks_lifecycle_replay = 1,
                       processed_at_utc = MAX(processed_at_utc, ?)
                   WHERE app_attest_key_id = ? AND EXISTS (
                     SELECT 1 FROM devices
                     WHERE ${ownedOrLegacyDeviceCondition}
                   )`,
                )
                .bind(
                  deletionObservedAt,
                  authorization.keyId,
                  authorization.keyId,
                  body.token,
                  ...consumed.bindings,
                ),
              env.DB
                .prepare(
                  `DELETE FROM alert_delivery_failures
                   WHERE registration_revision IN (
                     SELECT registration_revision FROM devices
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
              ...deletionCandidateFailureRecords.map(({ token, tokenHash: hashedToken }) =>
                env.DB
                  .prepare(
                    `DELETE FROM alert_lifecycle_recipients
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
                  `DELETE FROM alert_lifecycle_recipients
                   WHERE app_attest_key_id = ? AND ${consumed.sql}`,
                )
                .bind(
                  authorization.keyId,
                  ...consumed.bindings,
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
                deletionObservedAt,
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
    const deletion = await deleteDeviceRegistration(env.DB, body.token);
    if (deletion.outcome === "not_deleted") {
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
  // A test-push request is also an APNs send path. Require both the verified
  // request identity and this Worker's configured verifier to agree with the
  // stored APNs endpoint, so a historical cross-environment registration
  // cannot turn a production provider JWT into a sandbox request.
  if (
    device.environment !== apnsEnvironmentForAuthorizedDeviceMutation(authorization) ||
    device.environment !== apnsDeviceEnvironmentForWorker(env)
  ) {
    return json(
      { error: "device environment is not permitted for this app integrity environment" },
      403,
      noStoreHeaders(),
    );
  }
  try {
    const storedRoute = allowedStoredAppIdentityRoute(env, device);
    const authorizedRoute = appRouteForAuthorizedMutation(authorization);
    if (
      storedRoute.appIdentity !== authorizedRoute.appIdentity ||
      storedRoute.apnsTopic !== authorizedRoute.apnsTopic ||
      storedRoute.platform !== authorizedRoute.platform
    ) {
      throw new AppIdentityRouteNotAllowedError();
    }
  } catch {
    return json(
      { error: "device app route is not permitted" },
      403,
      noStoreHeaders(),
    );
  }
  if (!productionTestPushAllowed(
    env.ENABLE_PRODUCTION_TEST_PUSH,
    device.environment,
    body.kind,
  )) {
    return json(
      { error: "delayed production test alerts are disabled" },
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
  const event = trainingTestEvent();
  const deviceTokenHash = await tokenHash(device.token);
  try {
    const result = device.environment === "production"
      ? await productionTrainingPushThroughRelay(
          env,
          device,
          "immediate",
          new Date(Date.now() + DELAYED_TRAINING_TEST_PUSH_MAX_LATE_MS)
            .toISOString(),
          await apnsCollapseID(event),
        )
      : await sendPush(
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
  const url = new URL(request.url);
  const publicBudgetResponse = await enforceDeviceEndpointBudgets(
    request,
    env,
    publicEndpointRateLimitRoute(request, url),
  );
  if (publicBudgetResponse) return publicBudgetResponse;
  // The public API is consumed by native clients, not browser JavaScript.
  // Deliberately do not grant a cross-origin browser read/write capability.
  if (request.method === "OPTIONS") {
    return new Response(null, { status: 405, headers: { allow: "GET, POST, DELETE" } });
  }

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
      "QuakeSignal clients fetch public earthquake information directly from Wolfx. Only opted-in alert registration on an iPhone or iPad sends app registration data to QuakeSignal-operated notification infrastructure; opening this public page sends ordinary web-request metadata to Cloudflare but no local app settings.",
      [
        {
          heading: "Platform scope",
          body: "Only the app when running on an iPhone or iPad can register with the QuakeSignal notification relay in this release. The embedded Apple Watch companion and Apple TV app request recent reports directly from Wolfx over encrypted WebSocket and HTTPS connections while open, keep current report state in memory, and store only the selected alert presentation mode locally. Apple Vision Pro and Mac Catalyst use the full interface, contact Wolfx directly while open, and keep preferences and guide details in local app storage. Those foreground-only Apple experiences do not independently use the notification relay, App Attest, or APNs and do not provide background emergency alerts. A system-mirrored iPhone notification on a paired Watch remains part of the iPhone registration. The separate Windows desktop app, legacy Tauri macOS builds (dormant for Apple release 1.1 build 8), and Chrome extension also contact Wolfx directly and do not register with the relay.",
        },
        {
          heading: "Data we process",
          body: "If you enable alert registration on an iPhone or iPad, the service stores the APNs device token, app locale, selected JMA feed types, magnitude threshold, alert preferences (including the exact alert-sound identifier and a test-alert preference), alert radius, optional selected-city label, registration timestamps, a fresh opaque registration revision, and one approximate coordinate on a 0.1° grid. The opaque revision lets a stale APNs response act only on the exact registration snapshot that was sent. That coordinate is derived from either the selected city's coordinate or the most recent current-device location that the app successfully registered while open; neither an exact GPS fix nor an unrounded selected-city coordinate is sent. While the app is inactive, its last successfully registered bounded alert area remains in use until the next foreground renewal, removal, or retention cleanup. To prevent fraudulent subscription changes, the service also stores an opaque Apple App Attest key identifier, public verification key, attestation receipt, monotonic assertion counter, and integrity timestamps; newer Apple proofs may additionally carry the app build version and distribution category. QuakeSignal does not require an account, name, email address, contacts, photos, or advertising identifier for this registration.",
        },
        {
          heading: "Data kept on your device",
          body: "In the full Apple interface, alert preferences, the chosen city, the preparedness-kit checklist, and any optional family contact name and telephone number stay in local app storage. Within QuakeSignal, current report and GPS state remain in app memory; Apple provides the map and system Location Services under its own policies. Direct Wolfx earthquake requests do not include the chosen city or device location, and QuakeSignal does not send the exact GPS fix, checklist, or family contact details to its notification service. To clear local guide values, erase both Family Check-In fields and uncheck each selected preparedness-kit item; this is separate from removing an iPhone/iPad alert registration. The Apple Watch and Apple TV apps keep current report state only in memory for the foreground session, store the selected System, Urgent, or Japanese Voice presentation mode locally, and do not persist guide details. The Windows desktop app, legacy Tauri macOS builds, and Chrome extension keep their event history and preferences in their own local storage.",
        },
        {
          heading: "How data is used",
          body: "The iPhone/iPad subscription data is used only to secure the notification service, apply your selected JMA feed type, magnitude, and radius filters to JMA-issued information relayed through Wolfx, send the requested Apple Push Notification, and investigate bounded delivery failures. A short-lived alert-lifecycle record lets a final or cancellation reach a current registration when APNs accepted the earlier active warning or a crash left provider acceptance unknowable, even if revised magnitude or location estimates no longer match; neither evidence kind proves display, and the current registration must still select that JMA feed. Before routing every public request—including this page, root, health, OPTIONS, disabled endpoints, and normalized unmatched paths—the Worker derives a route-scoped SHA-256 pseudonym from Cloudflare's authenticated client-IP header for a per-location counter that admits at most 60 requests per 60 seconds for that normalized method/route family; a missing or malformed header shares one bounded fallback bucket. Only admitted requests consume the separate 300-per-minute route-wide circuit breaker, so one client cannot consume more than 60 of that route budget. QuakeSignal never writes the raw IP or this pseudonym to D1 or application logs, although Cloudflare may separately process ordinary request/security metadata under its own policies. These filters control relay delivery and presentation only; QuakeSignal does not forecast earthquakes or predict local intensity or arrival time. Location is not used for advertising, profiling, or sale.",
        },
        {
          heading: "Storage and deletion",
          body: [
            "Subscription settings and the associated App Attest integrity record are stored in Cloudflare D1. A legacy registration whose stored source list is explicitly empty is deleted with its raw-token deduplication and orphaned App Attest state rather than silently assigned a feed. Any already-existing one-way failure hash cannot be safely joined by SQL; ordinary or resolved evidence remains on its 14-day last-seen cleanup, while active BadDeviceToken quarantine or retry evidence follows the rule below. During rolling deployment, revisionless legacy invalid-token evidence is conservatively pinned to the newest registration clock until authenticated new-Worker recovery resolves the matching hash; an old isolate's unfenced deletion fails closed and must retry after deployment convergence.",
            "Removing notification registration from the app deletes the matching device registration, even when this launch has no APNs token, if an existing App Attest key can prove it owns that subscription. A new key cannot claim a legacy subscription with an empty request. After reinstall or device restore, a fresh Apple attestation plus the exact APNs token may safely rebind that one token and retire its old key record; assertions and tokenless requests cannot transfer another key's subscription. If the old App Attest key and exact APNs token are both unavailable, a public support issue cannot privately identify or delete that unreachable registration; do not post either identifier or any proof there. Support can guide recovery.",
            "An old registration becomes eligible for deletion after it has not been refreshed for 90 days, together with its orphaned integrity record. The next successful daily cleanup first places a blocking opaque-revision fence and upgrades older continuity fences for the same opaque App Attest lineage, then removes the registration; an operational cleanup failure can delay deletion. Normalized earthquake event rows and their revision history become eligible for deletion after 89 days and are removed by the next successful daily cleanup; an operational cleanup failure can delay deletion. If an in-app removal deletes the last registration using an App Attest key, the associated verifier, receipt, and assertion-counter record is deleted too.",
            "If APNs returns BadDeviceToken, only the exact opaque registration revision sent to APNs is removed with its orphaned verifier and active failure evidence. A separate processed-revision fence retains the opaque revision, optional SHA-256 token hash, optional opaque App Attest key ID, random decision ID, decision kind, replay-blocking flag, and timestamp for 14 days so a duplicate stale response cannot act on a re-registered token; it contains no raw APNs token, location, proof, or request body. A same-token registration serialized before the APNs cleanup transaction is preserved but its SHA-256 token hash is quarantined across alerts and degrades readiness unless that sent revision was already processed. An authenticated same-token renewal serialized after that transaction resolves the active quarantine while retaining the processed-revision fence. An immediate APNs 2xx resolves only matching evidence whose captured provider-response time is no later than that acceptance; delayed journal replay does not resolve active evidence merely because its D1 write runs later. Otherwise the active pseudonymous row follows a 90-day last-seen window aligned with stale registration cleanup, with last-seen never earlier than the preserved registration update time. If D1 cleanup or evidence storage fails, a bounded Queue attempt may contact APNs again because there is no separate cleanup-only record. The next foreground registration can replace its local integrity key once and retry with a fresh Apple attestation if that verifier is absent.",
            "APNs and D1 cannot share a transaction. Before each small provider batch, the global relay stores the exact queued event/delivery data and one complete sent registration snapshot in a bounded Durable Object journal: raw APNs token and SHA-256 token hash, opaque current and original-lineage registration revisions, a stable original-recipient index, and optional App Attest key ID, server-selected environment/topic/platform route, coarse matching area, selected sources and alert preferences, registration timestamps, per-recipient bounded provider-attempt counts and retry times, latest attempt-observation time, and conservative-evidence marker. An observed batch can additionally contain the nullable APNs response ID, HTTP status/reason, accepted or invalidation timestamp, Retry-After value, and bounded cleanup/disposition flags. The journal retains at most 128 combined records, at most 64 KiB each. Before every bounded provider contact, D1 records unknown-provider-outcome lifecycle evidence for each still-consenting active-warning recipient; a known APNs 2xx separately promotes that evidence and writes exact delivery deduplication. Recovery allows the initial contact plus at most five later contacts per original recipient, honors a longer provider Retry-After, and lets unrelated alerts proceed while one intent waits. Recovery reuses the same stable collapse ID for at-least-once provider contact. Valid, integrity-matched records become eligible for safe retirement after 14 days; a D1 outage or consent race can delay deletion until evidence reconciliation succeeds. Malformed or token-hash/storage-key-mismatched records are preserved for operator repair, can exceed 14 days until repaired, and degrade readiness instead of being silently discarded. Replay maps only to a current registration that still selects the source and passes its current magnitude, location, training, and quiet-hour eligibility; ordinary token rotation or a fresh exact-token key rebind can preserve continuity, while explicit removal, empty-source remediation, or stale-registration retention blocks the retired authenticated lineage. A persisted delivery deadline prevents stale redispatch while retaining possible-contact continuity. Neither provider contact nor APNs acceptance proves device display or user receipt.",
            "For alert closure, pseudonymous lifecycle row stores only an event reference, SHA-256 token hash, optional opaque App Attest key ID, and first/last evidence timestamps. Accepted-recipient rows add an opaque registration revision and an APNs-accepted evidence kind; pre-contact attempt rows add a possible-contact evidence kind and a random bounded attempt identifier. The lifecycle record set covers an opaque registration revision, an APNs-accepted or possible-contact evidence kind, and, during provider settlement, an APNs-accepted or unknown-provider-outcome evidence kind. It becomes eligible for deletion 14 days after the latest active-warning evidence. Possible-contact evidence does not create a notification-delivery deduplication row. The exact registration revision prevents an older removal fence from suppressing later accepted evidence after a new opt-in. A token-free provider-page or terminal-Queue incident stores event/delivery/source/reason/status/count/timestamp metadata. Confirmed later processing automatically resolves the matching provider-page failure; a terminal-Queue incident remains until an operator records both resolved status and a UTC resolution timestamp. Either becomes eligible 14 days after resolution; alert expiry alone starts no retention clock. These incident rows contain no APNs token, location preference, proof, or raw request/upstream body.",
            "A reviewed production training test creates a separate token-free claim containing only the opaque App Attest key ID and UTC timestamps. The training-test claim becomes eligible for deletion after 14 days and is removed by the next successful routine cleanup; an operational cleanup failure can delay deletion. Immediately before either production training contact, the relay also writes a separate pseudonymous D1 provider-attempt fence containing a random attempt ID, the exact opaque registration revision, a SHA-256 APNs-token hash, synthetic training event/outbox references, and admission/reconciliation timestamps. It contains no raw APNs token, proof, request body, preferences, or location. Device mutation fails closed while that exact marker is unresolved; provider settlement resolves it, while a crash releases it after 60 seconds without claiming APNs acceptance. A resolved marker becomes eligible for deletion 14 days after admission; operational cleanup failure can delay deletion. The optional fixed-delay check also creates one private scheduler record containing only that opaque App Attest key ID, a due time, and an at-most-once attempted state; it contains no APNs token, request body, proof, preferences, location, or earthquake payload. That temporary record is deleted after its one scheduled attempt or cancellation; an alarm more than 30 seconds late is deleted without delivery. Each App Attest challenge becomes invalid in no more than five minutes; its expired row is removed by the next successful routine cleanup, and an operational cleanup failure can delay deletion. Ordinary and resolved sanitized delivery-failure token hashes and processed-revision fences become eligible for deletion 14 days after they were last seen, resolved, or processed and are removed by the next successful routine cleanup; active BadDeviceToken quarantine or retry evidence instead follows the 90-day rule above. An operational cleanup failure can delay deletion. When QuakeSignal is next active, losing a current-location fix replaces it with the saved city fallback when available; without a fallback it attempts to delete the stale relay row and reports a failed registration if deletion cannot be confirmed. Disabling notifications or location access cannot guarantee that cleanup runs, so use the in-app removal control before a reset when possible.",
          ].join(" "),
        },
        {
          heading: "Third-party services",
          body: "All clients fetch earthquake information directly from the Wolfx Open API, which receives ordinary connection metadata such as an IP address under its own policies. Full-interface Apple clients also use Apple Maps and system Location Services when those features are used; Apple handles associated service data under its own policies, while QuakeSignal does not include the exact location in Wolfx requests or its relay. Cloudflare hosts these public pages and may process ordinary web-request and security metadata. Cloudflare D1, Apple Push Notification service, and Apple App Attest are used for app data only on opted-in iPhone/iPad alerts: Cloudflare stores subscriptions, verifies proofs, watches only the jma_eew and jma_eqlist Wolfx feeds, filters and presents the relayed JMA-issued information, and requests delivery through APNs. The relay does not create an earthquake forecast or predict local intensity or arrival time. The App Attest private key never leaves the iPhone or iPad. Following the public GitHub support link is subject to GitHub's policies.",
        },
        {
          heading: "Safety notice",
          body: "QuakeSignal is not an official government warning platform. Data and notifications can be delayed, incomplete, or inaccurate. Follow official announcements and local emergency instructions.",
        },
      ],
      "22 August 2026",
    );
  }
  if (url.pathname === "/terms" && request.method === "GET") {
    return legalPage(
      "Terms of Use",
      "By using QuakeSignal, you acknowledge the limitations of third-party earthquake data and mobile notification delivery.",
      [
        {
          heading: "Informational service",
          body: "QuakeSignal filters and presents relayed earthquake information and provides preparedness guidance for general informational purposes. It does not forecast earthquakes or predict local intensity or arrival time. It is not an official emergency warning system and does not replace government alerts, emergency services, or professional advice.",
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
      "Get help with QuakeSignal on iPhone, iPad, Apple Watch, Apple TV, Apple Vision Pro, Mac Catalyst, Windows, legacy Tauri macOS builds, or Chrome.",
      [
        {
          heading: "iPhone and iPad alerts",
          body: "For opted-in background alerts, confirm that alert registration is enabled in QuakeSignal, notifications are allowed in system Settings, the selected JMA feed type and magnitude/radius filters match the issued report, and the device has a working network connection. If you use Current Location for radius filtering, also confirm location access. These settings filter relayed JMA-issued information; they do not predict local intensity or arrival time. Focus modes, system settings, and device state can delay or suppress delivery; Time Sensitive notifications remain under user and system control and are not Critical Alerts.",
        },
        {
          heading: "Foreground-only Apple experiences",
          body: "The embedded Apple Watch companion and Apple TV app refresh recent Wolfx reports while open. A fresh active warning can present protective guidance and the native Watch warning haptic; if Urgent or Japanese Voice is selected on the paired iPhone, Watch can also play that mirrored sound while active. Apple TV warning ingestion remains visual-only: System is visual-only on Apple TV, and custom Apple TV audio requires an explicit Siri Remote action. Neither target independently registers for APNs or App Attest, provides background emergency delivery, or uses Critical Alerts; Apple TV never starts warning audio automatically. A notification mirrored to a paired Watch is still an iPhone feature. Apple Vision Pro and Mac Catalyst use the full interface and direct Wolfx data while open, but do not independently use the QuakeSignal notification relay or provide background emergency alerts.",
        },
        {
          heading: "Registration removal after a reset",
          body: "Use Settings → Remove Alert Registration before deleting the iPhone/iPad app or resetting its integrity key when possible. A newly attested app that receives the exact same APNs token can safely rebind and retire that token's old key record. If both the old integrity key and token are unavailable, support cannot identify the old registration from a public issue; it becomes eligible for deletion after it has not been refreshed for 90 days and is removed by the next successful daily cleanup. An operational cleanup failure can delay deletion. Never post an APNs token, App Attest key identifier or proof, or location in an issue.",
        },
        {
          heading: "Native desktop and Chrome",
          body: "The separate Windows desktop app, legacy Tauri macOS builds (dormant for Apple release 1.1 build 8), and Chrome extension connect directly to Wolfx and keep preferences and recent event state locally. They do not register with the QuakeSignal iPhone/iPad notification service. Check the app or extension connection status, selected sources and thresholds, local notification permission, and network access when troubleshooting.",
        },
        {
          heading: "Report an issue",
          body: "Open a GitHub issue with the app version and build, exact platform and operating-system version, language, selected data source, expected result, and what happened. Redact screenshots before posting. Never include an APNs device token, App Attest proof, exact address or GPS coordinate, family contact details, or other private information.",
        },
      ],
      "20 August 2026",
    );
  }
  if (url.pathname === "/healthz" && request.method === "GET") {
    // This read-only document is intentionally generated by the outer Worker,
    // not `QuakeRelay.statusResponse()`: it adds no Durable Object read/write
    // work and remains available when the relay cannot answer at all.
    const appAttestPolicy = await appAttestHealthPolicy(env);
    try {
      const relay = env.RELAY.get(env.RELAY.idFromName("global"));
      const response = await relay.fetch("https://relay.internal/status");
      const relayHealth = await response.json();
      return json(
        {
          ...(typeof relayHealth === "object" && relayHealth !== null &&
              !Array.isArray(relayHealth)
            ? relayHealth
            : {}),
          appAttestPolicy,
        },
        response.status,
        noStoreHeaders(),
      );
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
            APNS_RELAY_SOURCES.map((source) => [source, "unavailable"]),
          ),
          upstream: {
            status: "degraded",
            transport: "degraded",
            websocketStatus: "degraded",
            httpFallbackActive: null,
            staleSources: APNS_RELAY_SOURCES,
            pendingIngestSources: APNS_RELAY_SOURCES,
            sources: {},
          },
          delivery: {
            apnsConfigured: null,
            activeDlqIncidents: null,
            pendingDlqPersistenceFallbacks: null,
            pendingApnsAcceptanceBatches: null,
            activePageFailures: null,
            activeQuarantinedFailures: null,
            activeRetryFailures: null,
            pendingOutboxRows: null,
            staleOutboxRows: null,
            status: "degraded",
          },
          appAttestPolicy,
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
  const isAppAttestChallengeRequest =
    url.pathname === "/v1/app-attest/challenge" && request.method === "POST";
  if (isAppAttestChallengeRequest) {
    return handleAppAttestChallenge(request, env);
  }
  if (url.pathname.startsWith("/v1/app-attest/")) {
    // Reserve the same fail-closed limits for the App Attest challenge and
    // bootstrap routes. Their handlers are added separately, but this guard
    // means an unauthenticated route cannot become an unbounded mutation by
    // accident during that rollout.
    const route = appAttestRateLimitRoute(request, url.pathname);
    if (url.pathname !== "/v1/app-attest/challenge") {
      const mutationRateLimitResponse = await enforceDeviceMutationRateLimit(
        request,
        env,
        route,
      );
      if (mutationRateLimitResponse) return mutationRateLimitResponse;
    }
  }
  if (url.pathname === "/v1/devices" && request.method === "POST") {
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
      const disabledOutboxId = disabledSourceOutboxId(message.body);
      if (disabledOutboxId !== null) {
        try {
          const response = await relay.fetch(
            new Request("https://relay.internal/outbox/source-policy/reject", {
              method: "POST",
              headers: { "content-type": "application/json" },
              body: JSON.stringify({ outboxId: disabledOutboxId }),
            }),
          );
          if (!response.ok) {
            message.retry({ delaySeconds: retryDelaySeconds(message.attempts) });
            continue;
          }
          console.info(
            JSON.stringify({
              queueMessageId: message.id,
              queueAttempt: message.attempts,
              outboxId: disabledOutboxId,
              outcome: "disabled_source_alert_queue_message_superseded",
            }),
          );
          message.ack();
        } catch (error) {
          console.warn(
            JSON.stringify({
              queueMessageId: message.id,
              queueAttempt: message.attempts,
              outboxId: disabledOutboxId,
              outcome: "disabled_source_alert_queue_rejection_retry",
              errorName: error instanceof Error ? error.name : "UnknownError",
            }),
          );
          message.retry({ delaySeconds: retryDelaySeconds(message.attempts) });
        }
        continue;
      }
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
        if (
          response.headers.get(DELIVERY_MAINTENANCE_DEFERRED_HEADER) === "1"
        ) {
          // The relay atomically released this outbox row to its short alarm
          // before responding. Ack this Queue copy without terminalizing the
          // outbox; the alarm creates a fresh Queue delivery after bounded D1
          // maintenance, so recovery work cannot consume the five APNs retry
          // attempts of an otherwise healthy page.
          message.ack();
          continue;
        }
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
      const finalization = await relay.fetch(
        new Request("https://relay.internal/dlq/finalize", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify(evidence),
        }),
      );
      if (!finalization.ok) {
        throw new Error(`DLQ finalization returned HTTP ${finalization.status}`);
      }
      const finalizationBody: unknown = await finalization.json();
      if (
        !finalizationBody ||
        typeof finalizationBody !== "object" ||
        Array.isArray(finalizationBody) ||
        typeof (finalizationBody as { incidentRecorded?: unknown })
            .incidentRecorded !== "boolean"
      ) {
        throw new Error("DLQ finalization response was invalid");
      }
      const incidentRecorded =
        (finalizationBody as { incidentRecorded: boolean }).incidentRecorded;
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
      // The serialized finalization path (D1 or acceptance-journal replay) is
      // unavailable. Acknowledging now would lose terminal-delivery evidence,
      // so first persist a token-free fallback in the same global DO. Its
      // alarm replays only after pending APNs acceptances are reconciled.
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
