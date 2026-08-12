-- Every delivery page receives a durable, reason-specific deadline. New rows
-- write it with the event/outbox transaction; this backfill only gives existing
-- rows a conservative creation-time cap during the production upgrade.
ALTER TABLE alert_delivery_outbox
  ADD COLUMN expires_at_utc TEXT;

ALTER TABLE alert_delivery_outbox
  ADD COLUMN expiry_policy TEXT CHECK (expiry_policy IN (
    'eew_30m',
    'report_60m',
    'training_30m',
    'legacy_created_at'
  ));

-- `final_status` predates expiry and cannot be widened safely with SQLite's
-- ALTER TABLE. Keep it for compatibility and use this new canonical terminal
-- reason for delivery, DLQ, safe expiry, and superseded revision outcomes.
ALTER TABLE alert_delivery_outbox
  ADD COLUMN terminal_reason TEXT CHECK (terminal_reason IN (
    'delivered',
    'dlq',
    'expired',
    'superseded'
  ));

UPDATE alert_delivery_outbox
  SET expiry_policy = CASE notification_reason
    WHEN 'final' THEN 'report_60m'
    WHEN 'report' THEN 'report_60m'
    WHEN 'training' THEN 'training_30m'
    ELSE 'eew_30m'
  END,
  expires_at_utc = strftime(
    '%Y-%m-%dT%H:%M:%fZ',
    created_at_utc,
    CASE notification_reason
      WHEN 'final' THEN '+60 minutes'
      WHEN 'report' THEN '+60 minutes'
      ELSE '+30 minutes'
    END
  )
  WHERE expires_at_utc IS NULL;

UPDATE alert_delivery_outbox
  SET terminal_reason = final_status
  WHERE terminal_reason IS NULL AND final_status IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_alert_delivery_outbox_terminal_retention
  ON alert_delivery_outbox(acknowledged_at_utc, terminal_reason);

-- A provider/topic/payload failure belongs to the delivery page, not to a
-- recipient token. Active records make readiness fail closed until a later
-- successful page resolves them or the bounded Queue retry reaches the DLQ.
CREATE TABLE IF NOT EXISTS alert_delivery_page_failures (
  outbox_id TEXT PRIMARY KEY,
  delivery_id TEXT NOT NULL,
  root_delivery_id TEXT NOT NULL,
  event_ref TEXT NOT NULL,
  source_id TEXT NOT NULL,
  event_serial INTEGER NOT NULL,
  notification_reason TEXT NOT NULL,
  apns_status INTEGER,
  apns_reason TEXT,
  status TEXT NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'resolved')),
  first_seen_utc TEXT NOT NULL,
  last_seen_utc TEXT NOT NULL,
  occurrences INTEGER NOT NULL DEFAULT 1,
  resolved_at_utc TEXT
);

CREATE INDEX IF NOT EXISTS idx_alert_delivery_page_failures_active
  ON alert_delivery_page_failures(status, last_seen_utc DESC);
