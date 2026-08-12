-- Queue.send and a D1 acknowledgement cannot share one transaction. Lease an
-- outbox hand-off so concurrent Durable Object requests do not re-enqueue the
-- same alert page while Cloudflare Queues owns its bounded retry/DLQ lifecycle.
ALTER TABLE alert_delivery_outbox
  ADD COLUMN next_enqueue_at_utc TEXT;

ALTER TABLE alert_delivery_outbox
  ADD COLUMN queue_lease_until_utc TEXT;

-- `acknowledged_at_utc` remains the terminal timestamp. Retain why it was
-- finalized so operations can distinguish a successful page from one captured
-- as a DLQ incident.
ALTER TABLE alert_delivery_outbox
  ADD COLUMN final_status TEXT CHECK (final_status IN ('delivered', 'dlq'));

-- Existing rows from migration 0004 are immediately eligible for one safe
-- hand-off. New rows always write this value with their creation transaction.
UPDATE alert_delivery_outbox
  SET next_enqueue_at_utc = COALESCE(last_enqueued_at_utc, created_at_utc)
  WHERE next_enqueue_at_utc IS NULL;

CREATE INDEX IF NOT EXISTS idx_alert_delivery_outbox_leased_pending
  ON alert_delivery_outbox(
    acknowledged_at_utc,
    final_status,
    next_enqueue_at_utc,
    queue_lease_until_utc,
    created_at_utc
  );
