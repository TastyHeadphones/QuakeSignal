-- The delivery Queue is at-least-once. After its bounded retry policy is
-- exhausted, the DLQ consumer persists sanitized incident metadata here and
-- does not replay the alert automatically.
CREATE TABLE IF NOT EXISTS alert_delivery_incidents (
  queue_message_id TEXT PRIMARY KEY,
  delivery_id TEXT,
  root_delivery_id TEXT,
  event_id TEXT,
  source_id TEXT,
  event_serial INTEGER,
  notification_reason TEXT,
  queue_attempts INTEGER NOT NULL,
  status TEXT NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'resolved')),
  first_seen_utc TEXT NOT NULL,
  last_seen_utc TEXT NOT NULL,
  resolved_at_utc TEXT
);

CREATE INDEX IF NOT EXISTS idx_alert_delivery_incidents_status
  ON alert_delivery_incidents(status, last_seen_utc DESC);
