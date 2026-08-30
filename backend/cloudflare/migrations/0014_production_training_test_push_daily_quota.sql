-- Raise the per-key production training test-push quota from one boolean row
-- per UTC day to a countable claim (at most 10). Existing same-day rows keep
-- their original timestamps and count as the first used slot.
CREATE TABLE IF NOT EXISTS production_training_test_push_claims_v2 (
  app_attest_key_id TEXT NOT NULL,
  utc_day TEXT NOT NULL CHECK (
    utc_day GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
  ),
  claim_count INTEGER NOT NULL CHECK (
    claim_count >= 1 AND claim_count <= 10
  ),
  claimed_at_utc TEXT NOT NULL,
  expires_at_utc TEXT NOT NULL,
  PRIMARY KEY (app_attest_key_id, utc_day)
) WITHOUT ROWID;

INSERT INTO production_training_test_push_claims_v2 (
  app_attest_key_id, utc_day, claim_count, claimed_at_utc, expires_at_utc
)
SELECT app_attest_key_id, utc_day, 1, claimed_at_utc, expires_at_utc
FROM production_training_test_push_claims;

DROP TABLE production_training_test_push_claims;
ALTER TABLE production_training_test_push_claims_v2
  RENAME TO production_training_test_push_claims;

CREATE INDEX IF NOT EXISTS idx_production_training_test_push_claims_expiry
  ON production_training_test_push_claims(expires_at_utc);
