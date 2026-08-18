-- Keep only exact client/server sound identifiers. Existing registrations use
-- the system notification sound until their next authenticated refresh.
ALTER TABLE devices
  ADD COLUMN alert_sound TEXT NOT NULL DEFAULT 'system'
    CHECK (alert_sound IN ('system', 'urgent-tone', 'japanese-voice'));

-- Migration 0008 deployed an expiry-policy CHECK that predates the reviewed
-- ten-minute urgent-warning deadline. SQLite cannot widen a CHECK in place, so
-- rebuild this isolated outbox table while preserving every delivery field.
CREATE TABLE alert_delivery_outbox_v10 (
  id TEXT PRIMARY KEY,
  dedupe_key TEXT NOT NULL UNIQUE,
  delivery_id TEXT NOT NULL,
  root_delivery_id TEXT NOT NULL,
  event_ref TEXT NOT NULL,
  event_serial INTEGER NOT NULL,
  notification_reason TEXT NOT NULL,
  after_device_cursor INTEGER,
  event_json TEXT NOT NULL,
  created_at_utc TEXT NOT NULL,
  last_enqueued_at_utc TEXT,
  enqueue_attempts INTEGER NOT NULL DEFAULT 0,
  acknowledged_at_utc TEXT,
  next_enqueue_at_utc TEXT,
  queue_lease_until_utc TEXT,
  final_status TEXT CHECK (final_status IN ('delivered', 'dlq')),
  expires_at_utc TEXT,
  expiry_policy TEXT CHECK (expiry_policy IN (
    'eew_10m',
    'eew_30m',
    'report_60m',
    'training_30m',
    'legacy_created_at'
  )),
  terminal_reason TEXT CHECK (terminal_reason IN (
    'delivered',
    'dlq',
    'expired',
    'superseded'
  ))
);

INSERT INTO alert_delivery_outbox_v10 (
  id, dedupe_key, delivery_id, root_delivery_id, event_ref, event_serial,
  notification_reason, after_device_cursor, event_json, created_at_utc,
  last_enqueued_at_utc, enqueue_attempts, acknowledged_at_utc,
  next_enqueue_at_utc, queue_lease_until_utc, final_status, expires_at_utc,
  expiry_policy, terminal_reason
)
SELECT
  id, dedupe_key, delivery_id, root_delivery_id, event_ref, event_serial,
  notification_reason, after_device_cursor, event_json, created_at_utc,
  last_enqueued_at_utc, enqueue_attempts, acknowledged_at_utc,
  next_enqueue_at_utc, queue_lease_until_utc, final_status,
  CASE
    WHEN notification_reason IN ('new', 'updated') THEN
      CASE
        WHEN expires_at_utc IS NULL OR expires_at_utc > strftime(
          '%Y-%m-%dT%H:%M:%fZ', created_at_utc, '+10 minutes'
        ) THEN strftime('%Y-%m-%dT%H:%M:%fZ', created_at_utc, '+10 minutes')
        ELSE expires_at_utc
      END
    ELSE expires_at_utc
  END,
  CASE
    WHEN notification_reason IN ('new', 'updated') THEN 'eew_10m'
    ELSE expiry_policy
  END,
  terminal_reason
FROM alert_delivery_outbox;

DROP TABLE alert_delivery_outbox;
ALTER TABLE alert_delivery_outbox_v10 RENAME TO alert_delivery_outbox;

CREATE INDEX idx_alert_delivery_outbox_pending
  ON alert_delivery_outbox(
    acknowledged_at_utc,
    last_enqueued_at_utc,
    created_at_utc
  );

CREATE INDEX idx_alert_delivery_outbox_leased_pending
  ON alert_delivery_outbox(
    acknowledged_at_utc,
    final_status,
    next_enqueue_at_utc,
    queue_lease_until_utc,
    created_at_utc
  );

CREATE INDEX idx_alert_delivery_outbox_terminal_retention
  ON alert_delivery_outbox(acknowledged_at_utc, terminal_reason);
