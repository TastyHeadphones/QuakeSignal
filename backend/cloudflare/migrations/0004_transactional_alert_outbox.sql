-- An event write and its initial notification hand-off are committed together
-- in one D1 batch. Queue delivery remains at-least-once: rows stay pending
-- until the Queue consumer has completed relay delivery and recorded an ack.
CREATE TABLE IF NOT EXISTS alert_delivery_outbox (
  id TEXT PRIMARY KEY,
  -- Stable for normal pages and derived from a parent outbox id for a retry.
  -- This makes inserts idempotent across crashes without deduplicating later
  -- retry generations for the same page.
  dedupe_key TEXT NOT NULL UNIQUE,
  delivery_id TEXT NOT NULL,
  root_delivery_id TEXT NOT NULL,
  event_ref TEXT NOT NULL,
  event_serial INTEGER NOT NULL,
  notification_reason TEXT NOT NULL,
  after_device_cursor INTEGER,
  -- JSON contains only the normalized event snapshot; no raw upstream
  -- payload or APNs device token is ever written here.
  event_json TEXT NOT NULL,
  created_at_utc TEXT NOT NULL,
  last_enqueued_at_utc TEXT,
  enqueue_attempts INTEGER NOT NULL DEFAULT 0,
  acknowledged_at_utc TEXT
);

CREATE INDEX IF NOT EXISTS idx_alert_delivery_outbox_pending
  ON alert_delivery_outbox(acknowledged_at_utc, last_enqueued_at_utc, created_at_utc);

-- Per-device permanent APNs failures are quarantined as sanitized metadata so
-- a malformed/topic-mismatched subscription cannot block later recipients.
CREATE TABLE IF NOT EXISTS alert_delivery_failures (
  delivery_id TEXT NOT NULL,
  token_hash TEXT NOT NULL,
  event_ref TEXT NOT NULL,
  source_id TEXT NOT NULL,
  notification_reason TEXT NOT NULL,
  apns_status INTEGER,
  apns_reason TEXT,
  disposition TEXT NOT NULL CHECK (disposition IN ('quarantine', 'retry')),
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'resolved')),
  first_seen_utc TEXT NOT NULL,
  last_seen_utc TEXT NOT NULL,
  occurrences INTEGER NOT NULL DEFAULT 1,
  resolved_at_utc TEXT,
  PRIMARY KEY (delivery_id, token_hash)
);

CREATE INDEX IF NOT EXISTS idx_alert_delivery_failures_last_seen
  ON alert_delivery_failures(last_seen_utc DESC);

CREATE INDEX IF NOT EXISTS idx_alert_delivery_failures_active
  ON alert_delivery_failures(status, disposition, last_seen_utc DESC);
