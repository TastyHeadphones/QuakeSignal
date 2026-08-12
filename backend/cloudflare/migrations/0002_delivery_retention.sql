-- Registrations are refreshed whenever an authorized client launches. Index
-- updated_at so the Durable Object's daily 90-day purge is bounded.
CREATE INDEX IF NOT EXISTS idx_devices_updated_at
  ON devices(updated_at);

-- Queue delivery is at-least-once. Record confirmed APNs accepts so a retry
-- does not deliberately send the same event revision to the same device.
-- The Durable Object removes these short-lived rows after 14 days.
CREATE TABLE IF NOT EXISTS notification_deliveries (
  delivery_id TEXT NOT NULL,
  device_token TEXT NOT NULL,
  delivered_at_utc TEXT NOT NULL,
  PRIMARY KEY (delivery_id, device_token)
);

CREATE INDEX IF NOT EXISTS idx_notification_deliveries_delivered_at
  ON notification_deliveries(delivered_at_utc);
