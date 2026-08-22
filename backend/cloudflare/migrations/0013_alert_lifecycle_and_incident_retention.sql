-- Every successful registration mutation receives a fresh, opaque revision.
-- APNs cleanup uses this identity, never a wall-clock timestamp, to distinguish
-- the exact sent snapshot from a same-millisecond authenticated renewal. The
-- legacy sentinel is replaced immediately for existing rows, while the trigger
-- also protects a rolling pre-0013 Worker that omits the new column on INSERT.
ALTER TABLE devices ADD COLUMN registration_revision TEXT NOT NULL
  DEFAULT 'legacy';

UPDATE devices
  SET registration_revision = lower(hex(randomblob(16)))
  WHERE registration_revision = 'legacy';

CREATE UNIQUE INDEX IF NOT EXISTS idx_devices_registration_revision
  ON devices(registration_revision);

CREATE TRIGGER IF NOT EXISTS devices_registration_revision_legacy_insert
AFTER INSERT ON devices
WHEN NEW.registration_revision = 'legacy'
BEGIN
  UPDATE devices
  SET registration_revision = lower(hex(randomblob(16)))
  WHERE token = NEW.token AND registration_revision = 'legacy';
END;

-- A resolved row keyed by the rejected registration revision is a short-lived
-- causal marker. It prevents a duplicate, already-in-flight APNs rejection for
-- that old revision from quarantining a subsequently re-registered token.
ALTER TABLE alert_delivery_failures ADD COLUMN registration_revision TEXT;

-- BadDeviceToken failures use a revision-specific primary-key namespace so a
-- deterministic outbox delivery can retain evidence for multiple successive
-- registrations of the same APNs token. Keep the original logical delivery
-- ID separately for same-delivery bounded retry behavior and incident review.
ALTER TABLE alert_delivery_failures ADD COLUMN origin_delivery_id TEXT;

CREATE INDEX IF NOT EXISTS idx_alert_delivery_failures_registration_revision
  ON alert_delivery_failures(token_hash, registration_revision, apns_reason);

-- A decision fence is independent of the per-delivery failure-row primary
-- key. Explicit subscription deletion, guarded APNs cleanup, or authenticated
-- rehabilitation records the exact opaque revision here before removing or
-- resolving it. Delayed duplicate APNs responses can then never act on a later
-- reincarnation of the same token, even when the outbox delivery ID is reused.
CREATE TABLE IF NOT EXISTS apns_registration_revision_fences (
  registration_revision TEXT PRIMARY KEY,
  token_hash TEXT,
  app_attest_key_id TEXT,
  decision_id TEXT NOT NULL,
  decision_kind TEXT NOT NULL,
  blocks_lifecycle_replay INTEGER NOT NULL
    CHECK (blocks_lifecycle_replay IN (0, 1)),
  processed_at_utc TEXT NOT NULL,
  UNIQUE (decision_id)
) WITHOUT ROWID;

CREATE INDEX IF NOT EXISTS idx_apns_registration_revision_fences_retention
  ON apns_registration_revision_fences(processed_at_utc);

CREATE INDEX IF NOT EXISTS idx_apns_registration_revision_fences_token_hash
  ON apns_registration_revision_fences(token_hash)
  WHERE token_hash IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_apns_registration_revision_fences_key
  ON apns_registration_revision_fences(app_attest_key_id)
  WHERE app_attest_key_id IS NOT NULL;

-- During a rolling deploy, a pre-0013 Worker can still execute its historical
-- UPSERT, which updates `updated_at` without naming the revision column. Give
-- that successful mutation a fresh revision too—even when both timestamps are
-- equal—so a stale APNs response cannot mistake it for the sent snapshot.
CREATE TRIGGER IF NOT EXISTS devices_registration_revision_legacy_update
AFTER UPDATE OF updated_at ON devices
WHEN NEW.registration_revision = OLD.registration_revision
BEGIN
  -- Do not rely on recursive trigger execution for the nested revision UPDATE.
  -- Preserve the exact retired revision directly so later opt-out can upgrade
  -- its full lineage and a late BadDeviceToken response can still claim it.
  INSERT INTO apns_registration_revision_fences (
    registration_revision, token_hash, app_attest_key_id,
    decision_id, decision_kind,
    blocks_lifecycle_replay, processed_at_utc
  ) SELECT
    OLD.registration_revision, NULL,
    COALESCE(NEW.app_attest_key_id, OLD.app_attest_key_id),
    lower(hex(randomblob(16))), 'registration_renewal', 0,
    strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
  WHERE NOT EXISTS (
    SELECT 1 FROM apns_registration_revision_fences
    WHERE registration_revision = OLD.registration_revision
  );
  UPDATE devices
  SET registration_revision = lower(hex(randomblob(16)))
  WHERE token = NEW.token AND registration_revision = OLD.registration_revision;
END;

-- A pseudonymous D1 admission fence spans the provider/D1 gap. Authenticated
-- renewal fails closed while an exact registration revision has an in-flight
-- or not-yet-reconciled APNs outcome; it retries after the relay durably
-- classifies that outcome, so a post-response renewal cannot be mistaken for
-- a pre-response refresh (and vice versa) without cross-colo wall clocks.
CREATE TABLE IF NOT EXISTS apns_provider_attempts (
  attempt_id TEXT NOT NULL,
  registration_revision TEXT NOT NULL,
  token_hash TEXT NOT NULL,
  event_ref TEXT NOT NULL,
  outbox_id TEXT NOT NULL,
  admitted_at_utc TEXT NOT NULL,
  outcome_reconciled_at_utc TEXT,
  PRIMARY KEY (attempt_id, registration_revision)
) WITHOUT ROWID;

CREATE INDEX IF NOT EXISTS idx_apns_provider_attempts_token_hash
  ON apns_provider_attempts(token_hash);

CREATE INDEX IF NOT EXISTS idx_apns_provider_attempts_event
  ON apns_provider_attempts(event_ref, outcome_reconciled_at_utc);

-- A controlled production training push has no Queue-owned retry journal, but
-- it still reserves the exact registration revision immediately before APNs.
-- Fail registration mutation closed while that short-lived marker is active;
-- the relay marks it resolved at provider settlement, or releases a crashed
-- marker after the request timeout plus a conservative grace period.
CREATE TRIGGER IF NOT EXISTS devices_block_training_apns_attempt_update
BEFORE UPDATE ON devices
WHEN EXISTS (
  SELECT 1 FROM apns_provider_attempts
  WHERE attempt_id LIKE 'training:%'
    AND registration_revision = OLD.registration_revision
    AND outcome_reconciled_at_utc IS NULL
)
BEGIN
  SELECT RAISE(ABORT, 'device mutation waits for training APNs outcome');
END;

CREATE TRIGGER IF NOT EXISTS devices_block_training_apns_attempt_delete
BEFORE DELETE ON devices
WHEN EXISTS (
  SELECT 1 FROM apns_provider_attempts
  WHERE attempt_id LIKE 'training:%'
    AND registration_revision = OLD.registration_revision
    AND outcome_reconciled_at_utc IS NULL
)
BEGIN
  SELECT RAISE(ABORT, 'device mutation waits for training APNs outcome');
END;

-- Event ingestion and provider I/O share D1's serialization boundary. Once an
-- exact provider attempt is admitted, a newer/final/cancel revision of that
-- same event retries from its Durable Object ingest journal until every
-- observed outcome is reconciled. This closes the otherwise unavoidable gap
-- between the final admission batch and the first APNs byte without relying on
-- cross-isolate clocks or an in-memory mutex.
CREATE TRIGGER IF NOT EXISTS events_block_unreconciled_apns_attempt
BEFORE UPDATE ON events
WHEN EXISTS (
  SELECT 1 FROM apns_provider_attempts
  WHERE event_ref = OLD.id AND outcome_reconciled_at_utc IS NULL
)
BEGIN
  SELECT RAISE(ABORT, 'event revision waits for APNs outcome reconciliation');
END;

-- Pre-contact lifecycle provenance is attempt-owned. It is visible to
-- terminal warning continuity only after the same transaction admits an exact
-- current recipient, and can be removed without erasing older accepted or
-- possible-contact evidence when a final clock/consent check cancels contact.
CREATE TABLE IF NOT EXISTS alert_lifecycle_possible_attempts (
  attempt_id TEXT NOT NULL,
  event_ref TEXT NOT NULL,
  token_hash TEXT NOT NULL,
  app_attest_key_id TEXT,
  registration_revision TEXT NOT NULL,
  evidence_at_utc TEXT NOT NULL,
  PRIMARY KEY (attempt_id, registration_revision)
) WITHOUT ROWID;

CREATE INDEX IF NOT EXISTS idx_alert_lifecycle_possible_event_hash
  ON alert_lifecycle_possible_attempts(event_ref, token_hash);

CREATE INDEX IF NOT EXISTS idx_alert_lifecycle_possible_event_key
  ON alert_lifecycle_possible_attempts(event_ref, app_attest_key_id)
  WHERE app_attest_key_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_alert_lifecycle_possible_retention
  ON alert_lifecycle_possible_attempts(evidence_at_utc);

-- SQLite cannot SHA-256 a raw APNs token. A rolling pre-0013 empty-source
-- opt-out (and runtime stale-registration purge) therefore moves only the
-- soon-to-be-deleted token into this bounded reconciliation table. The new
-- Worker hashes it, blocks the retired lineage, removes hash-linked lifecycle
-- state, and deletes this raw row before any alert journal/terminal work.
CREATE TABLE IF NOT EXISTS legacy_device_removal_tokens (
  token TEXT PRIMARY KEY,
  registration_revision TEXT NOT NULL,
  app_attest_key_id TEXT,
  decision_kind TEXT NOT NULL
    CHECK (decision_kind IN ('empty_source_removal', 'stale_registration_retention')),
  removed_at_utc TEXT NOT NULL
) WITHOUT ROWID;

CREATE INDEX IF NOT EXISTS idx_legacy_device_removal_tokens_time
  ON legacy_device_removal_tokens(removed_at_utc);

-- Replacing a registration in place retires the old opaque revision even when
-- the APNs token is unchanged. Preserve that causal lineage so a later
-- consent-ending removal can upgrade every earlier revision, while leaving a
-- late BadDeviceToken response free to claim a pre-removal renewal fence.
-- New code predeclares the same fence with a token hash; this compatibility
-- trigger supplies the App Attest key for a rolling old Worker.
CREATE TRIGGER IF NOT EXISTS devices_registration_revision_continuity_fence
BEFORE UPDATE OF registration_revision ON devices
WHEN NEW.registration_revision <> OLD.registration_revision
  AND OLD.registration_revision <> 'legacy'
BEGIN
  INSERT INTO apns_registration_revision_fences (
    registration_revision, token_hash, app_attest_key_id,
    decision_id, decision_kind,
    blocks_lifecycle_replay, processed_at_utc
  ) SELECT
    OLD.registration_revision, NULL,
    COALESCE(NEW.app_attest_key_id, OLD.app_attest_key_id),
    lower(hex(randomblob(16))), 'registration_renewal', 0,
    strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
  WHERE NOT EXISTS (
    SELECT 1 FROM apns_registration_revision_fences
    WHERE registration_revision = OLD.registration_revision
  );
END;

-- A pre-0013 Worker cannot attach a token hash to an unbound renewal fence,
-- and retaining the raw APNs token in a fence would violate the privacy
-- contract. Fail that narrow rolling-deploy mutation closed; the current
-- Worker retries it with an explicit pseudonymous continuity fence.
CREATE TRIGGER IF NOT EXISTS devices_reject_unbound_legacy_update
BEFORE UPDATE OF updated_at ON devices
WHEN NEW.registration_revision = OLD.registration_revision
  AND OLD.app_attest_key_id IS NULL
  AND NOT (
    CASE WHEN json_valid(NEW.sources) THEN
      json_type(NEW.sources) = 'array' AND json_array_length(NEW.sources) = 0
    ELSE 0 END
  )
BEGIN
  SELECT RAISE(ABORT, 'unbound legacy registration renewal requires current worker');
END;

-- A terminal EEW revision can legitimately move its estimated epicenter or
-- magnitude outside the subscription filter that selected an earlier warning.
-- Retain a short-lived, pseudonymous record of active-warning recipients so
-- final/cancel lifecycle pushes follow an alert APNs accepted—or might have
-- accepted in the bounded provider/D1 crash window—instead of re-evaluating
-- revised estimates. The evidence kind keeps that distinction explicit; even
-- a confirmed APNs acceptance does not prove display on the device.
CREATE TABLE IF NOT EXISTS alert_lifecycle_recipients (
  event_ref TEXT NOT NULL,
  token_hash TEXT NOT NULL,
  app_attest_key_id TEXT,
  registration_revision TEXT,
  evidence_kind TEXT NOT NULL DEFAULT 'apns_accepted'
    CHECK (evidence_kind IN ('apns_accepted', 'unknown_provider_outcome')),
  first_evidence_at_utc TEXT NOT NULL,
  last_evidence_at_utc TEXT NOT NULL,
  PRIMARY KEY (event_ref, token_hash)
) WITHOUT ROWID;

-- The opaque App Attest key survives an ordinary APNs token rotation. The
-- token hash independently preserves continuity when a reinstall creates a new
-- App Attest key but APNs returns the same token.
CREATE INDEX IF NOT EXISTS idx_alert_lifecycle_recipients_key
  ON alert_lifecycle_recipients(event_ref, app_attest_key_id)
  WHERE app_attest_key_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_alert_lifecycle_recipients_retention
  ON alert_lifecycle_recipients(last_evidence_at_utc);

-- A rolling pre-0013 Worker records APNs 2xx dedupe but does not know the new
-- lifecycle table. Mark every row unresolved by default; the new Worker sets
-- this bit atomically with lifecycle handling, and its bounded compatibility
-- reconciler converts any old-Worker acceptance before terminal fanout.
ALTER TABLE notification_deliveries ADD COLUMN lifecycle_reconciled INTEGER
  NOT NULL DEFAULT 0 CHECK (lifecycle_reconciled IN (0, 1));

CREATE INDEX IF NOT EXISTS idx_notification_deliveries_lifecycle_reconcile
  ON notification_deliveries(lifecycle_reconciled, delivered_at_utc);

-- Authenticated renewal resolves active per-token quarantine without scanning
-- the full operational-failure table, while preserving processed revisions.
CREATE INDEX IF NOT EXISTS idx_alert_delivery_failures_token_hash
  ON alert_delivery_failures(token_hash);

-- Before this Worker revision, BadDeviceToken evidence was scoped only to one
-- delivery and a successful later registration did not clear it. Leave active
-- legacy quarantine/retry rows active so rollout cannot re-contact a token
-- APNs already rejected. The new global lookup blocks that hash until a later
-- authenticated same-token registration or APNs acceptance resolves it, or
-- until its 90-day last-seen retention window expires. Restart that clock at
-- migration time (or the newest retained registration timestamp, if later):
-- an old failure timestamp must not expire while a device refreshed by the old
-- Worker can still remain in the 90-day registration window.
UPDATE alert_delivery_failures
SET last_seen_utc = MAX(
  last_seen_utc,
  strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
  COALESCE(
    (SELECT MAX(updated_at) FROM devices),
    strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
  )
)
WHERE status = 'active'
  AND apns_reason = 'BadDeviceToken'
  AND registration_revision IS NULL;

-- A lingering old Worker can create or refresh another legacy BadDeviceToken
-- row after the one-shot pin above. SQLite cannot SHA-256-join its raw device
-- token to the historical hash, and globally advancing every legacy row would
-- retain unrelated hashes indefinitely. Reject that narrow rolling mutation;
-- its Queue retry is handled by the current Worker with revision provenance.
CREATE TRIGGER IF NOT EXISTS alert_failures_reject_legacy_bdt_insert
BEFORE INSERT ON alert_delivery_failures
WHEN NEW.status = 'active'
  AND NEW.apns_reason = 'BadDeviceToken'
  AND NEW.registration_revision IS NULL
BEGIN
  SELECT RAISE(ABORT, 'legacy BadDeviceToken evidence requires current worker');
END;

CREATE TRIGGER IF NOT EXISTS alert_failures_reject_legacy_bdt_update
BEFORE UPDATE ON alert_delivery_failures
WHEN NEW.status = 'active'
  AND NEW.apns_reason = 'BadDeviceToken'
  AND NEW.registration_revision IS NULL
BEGIN
  SELECT RAISE(ABORT, 'legacy BadDeviceToken evidence requires current worker');
END;

-- A lingering pre-0013 Worker can delete by timestamp or by key without the
-- opaque revision it actually observed. A trigger cannot reconstruct that
-- causal decision after the row is gone, so fail closed unless new code has
-- already declared the exact revision fence in the same D1 batch. Rolling old
-- mutations retry after the isolate drains; they cannot erase a renewal or
-- misclassify an ordinary token rotation as an explicit opt-out.
CREATE TRIGGER IF NOT EXISTS devices_require_revision_fence
BEFORE DELETE ON devices
WHEN NOT EXISTS (
  SELECT 1 FROM apns_registration_revision_fences
  WHERE registration_revision = OLD.registration_revision
)
BEGIN
  SELECT RAISE(ABORT, 'device revision fence required');
END;

-- Migration cleanup alone cannot catch a rolling old Worker that still
-- accepts `sources=[]`. These compatibility triggers turn an exact empty JSON
-- array into the same consent-ending deletion, never a silent default source.
CREATE TRIGGER IF NOT EXISTS devices_empty_sources_legacy_insert
AFTER INSERT ON devices
WHEN CASE WHEN json_valid(NEW.sources) THEN
  json_type(NEW.sources) = 'array' AND json_array_length(NEW.sources) = 0
ELSE 0 END
BEGIN
  INSERT INTO legacy_device_removal_tokens (
    token, registration_revision, app_attest_key_id,
    decision_kind, removed_at_utc
  )
  SELECT token, registration_revision, app_attest_key_id,
         'empty_source_removal', strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
  FROM devices WHERE token = NEW.token
  ON CONFLICT(token) DO UPDATE SET
    registration_revision = excluded.registration_revision,
    app_attest_key_id = excluded.app_attest_key_id,
    decision_kind = excluded.decision_kind,
    removed_at_utc = excluded.removed_at_utc;
  INSERT OR IGNORE INTO apns_registration_revision_fences (
    registration_revision, token_hash, app_attest_key_id,
    decision_id, decision_kind,
    blocks_lifecycle_replay, processed_at_utc
  )
  SELECT registration_revision, NULL, app_attest_key_id,
         lower(hex(randomblob(16))), 'empty_source_removal', 1,
         strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
  FROM devices
  WHERE token = NEW.token;
  DELETE FROM notification_deliveries WHERE device_token = NEW.token;
  DELETE FROM alert_lifecycle_recipients
    WHERE NEW.app_attest_key_id IS NOT NULL
      AND app_attest_key_id = NEW.app_attest_key_id;
  DELETE FROM devices WHERE token = NEW.token;
  DELETE FROM app_attest_keys
    WHERE key_id = NEW.app_attest_key_id
      AND NOT EXISTS (
        SELECT 1 FROM devices
        WHERE app_attest_key_id = NEW.app_attest_key_id
      );
  DELETE FROM app_attest_challenges
    WHERE consumed_at_utc IS NOT NULL
      AND key_id = NEW.app_attest_key_id
      AND NOT EXISTS (
        SELECT 1 FROM app_attest_keys WHERE key_id = NEW.app_attest_key_id
      );
END;

CREATE TRIGGER IF NOT EXISTS devices_empty_sources_legacy_update
AFTER UPDATE OF sources ON devices
WHEN CASE WHEN json_valid(NEW.sources) THEN
  json_type(NEW.sources) = 'array' AND json_array_length(NEW.sources) = 0
ELSE 0 END
BEGIN
  INSERT INTO legacy_device_removal_tokens (
    token, registration_revision, app_attest_key_id,
    decision_kind, removed_at_utc
  )
  SELECT token, registration_revision, app_attest_key_id,
         'empty_source_removal', strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
  FROM devices WHERE token = NEW.token
  ON CONFLICT(token) DO UPDATE SET
    registration_revision = excluded.registration_revision,
    app_attest_key_id = excluded.app_attest_key_id,
    decision_kind = excluded.decision_kind,
    removed_at_utc = excluded.removed_at_utc;
  INSERT OR IGNORE INTO apns_registration_revision_fences (
    registration_revision, token_hash, app_attest_key_id,
    decision_id, decision_kind,
    blocks_lifecycle_replay, processed_at_utc
  )
  SELECT registration_revision, NULL, app_attest_key_id,
         lower(hex(randomblob(16))), 'empty_source_removal', 1,
         strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
  FROM devices
  WHERE token = NEW.token;
  DELETE FROM notification_deliveries WHERE device_token = NEW.token;
  DELETE FROM alert_lifecycle_recipients
    WHERE NEW.app_attest_key_id IS NOT NULL
      AND app_attest_key_id = NEW.app_attest_key_id;
  DELETE FROM devices WHERE token = NEW.token;
  DELETE FROM app_attest_keys
    WHERE key_id = NEW.app_attest_key_id
      AND NOT EXISTS (
        SELECT 1 FROM devices
        WHERE app_attest_key_id = NEW.app_attest_key_id
      );
  DELETE FROM app_attest_challenges
    WHERE consumed_at_utc IS NOT NULL
      AND key_id = NEW.app_attest_key_id
      AND NOT EXISTS (
        SELECT 1 FROM app_attest_keys WHERE key_id = NEW.app_attest_key_id
      );
END;

-- Older clients could persist an explicit empty source array. Such a row can
-- never receive an alert and must not linger as an ambiguous opt-in. Do not
-- silently widen it to the current defaults: remove the invalid registration
-- and the raw-token/key-linked state that SQLite can identify safely.
INSERT INTO legacy_device_removal_tokens (
  token, registration_revision, app_attest_key_id,
  decision_kind, removed_at_utc
)
SELECT token, registration_revision, app_attest_key_id,
       'empty_source_removal', strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
FROM devices
WHERE CASE WHEN json_valid(sources) THEN
  json_type(sources) = 'array' AND json_array_length(sources) = 0
ELSE 0 END
ON CONFLICT(token) DO UPDATE SET
  registration_revision = excluded.registration_revision,
  app_attest_key_id = excluded.app_attest_key_id,
  decision_kind = excluded.decision_kind,
  removed_at_utc = excluded.removed_at_utc;

DELETE FROM notification_deliveries
  WHERE device_token IN (
    SELECT token FROM devices
    WHERE CASE WHEN json_valid(sources) THEN
      json_type(sources) = 'array' AND json_array_length(sources) = 0
    ELSE 0 END
  );

DELETE FROM alert_lifecycle_recipients
  WHERE app_attest_key_id IN (
    SELECT app_attest_key_id FROM devices
    WHERE CASE WHEN json_valid(sources) THEN
      json_type(sources) = 'array' AND json_array_length(sources) = 0
    ELSE 0 END
      AND app_attest_key_id IS NOT NULL
  );

-- SQLite has no built-in SHA-256 function, but the registration revision is
-- already globally unique and sufficient to suppress a delayed APNs response.
-- Fence each remediated row without retaining its raw token; runtime-created
-- fences additionally carry the one-way hash for operational provenance.
INSERT OR IGNORE INTO apns_registration_revision_fences (
  registration_revision, token_hash, app_attest_key_id,
  decision_id, decision_kind,
  blocks_lifecycle_replay, processed_at_utc
)
SELECT registration_revision, NULL, app_attest_key_id,
       lower(hex(randomblob(16))),
       'empty_source_removal', 1,
       strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
FROM devices
WHERE CASE WHEN json_valid(sources) THEN
  json_type(sources) = 'array' AND json_array_length(sources) = 0
ELSE 0 END;

DELETE FROM devices
  WHERE CASE WHEN json_valid(sources) THEN
    json_type(sources) = 'array' AND json_array_length(sources) = 0
  ELSE 0 END;

DELETE FROM app_attest_keys
  WHERE NOT EXISTS (
    SELECT 1 FROM devices
    WHERE devices.app_attest_key_id = app_attest_keys.key_id
  );

DELETE FROM app_attest_challenges
  WHERE consumed_at_utc IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM app_attest_keys
      WHERE app_attest_keys.key_id = app_attest_challenges.key_id
    );

-- `alert_delivery_failures` deliberately stores only a one-way token hash, so
-- SQL cannot safely join an empty-source row to that table without adding a
-- reversible identifier. Ordinary or resolved hashes retain the 14-day
-- cleanup, while active BadDeviceToken quarantine/retry hashes follow the
-- 90-day stale-registration window; migration 0013 creates no lifecycle rows
-- before the registration remediation above runs.

-- Older operational procedures could mark an incident resolved without
-- setting its explicit resolution timestamp. The historical resolution time
-- is unknowable, so give those rows a fresh migration-time start for the
-- post-resolution retention window before adding the index.
ALTER TABLE alert_delivery_incidents ADD COLUMN outbox_id TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS idx_alert_delivery_incidents_outbox
  ON alert_delivery_incidents(outbox_id)
  WHERE outbox_id IS NOT NULL;

UPDATE alert_delivery_incidents
  SET resolved_at_utc = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
  WHERE status = 'resolved' AND resolved_at_utc IS NULL;

UPDATE alert_delivery_page_failures
  SET resolved_at_utc = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
  WHERE status = 'resolved' AND resolved_at_utc IS NULL;

CREATE INDEX IF NOT EXISTS idx_alert_delivery_incidents_resolved_retention
  ON alert_delivery_incidents(status, resolved_at_utc);

CREATE INDEX IF NOT EXISTS idx_alert_delivery_page_failures_resolved_retention
  ON alert_delivery_page_failures(status, resolved_at_utc);
