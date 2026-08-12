-- Production training alerts are an exceptional, reviewed operation. Keep a
-- durable, token-free claim keyed by the already-opaque App Attest key and UTC
-- calendar day so concurrent valid assertions cannot fan out more than one
-- production test push. The Worker deletes expired claims during its existing
-- daily App Attest retention pass.
CREATE TABLE IF NOT EXISTS production_training_test_push_claims (
  app_attest_key_id TEXT NOT NULL,
  utc_day TEXT NOT NULL CHECK (
    utc_day GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
  ),
  claimed_at_utc TEXT NOT NULL,
  expires_at_utc TEXT NOT NULL,
  PRIMARY KEY (app_attest_key_id, utc_day)
) WITHOUT ROWID;

-- Routine cleanup is bounded by expiry rather than scanning every historic
-- App Attest identity. No APNs token, request body, or proof is stored here.
CREATE INDEX IF NOT EXISTS idx_production_training_test_push_claims_expiry
  ON production_training_test_push_claims(expires_at_utc);
