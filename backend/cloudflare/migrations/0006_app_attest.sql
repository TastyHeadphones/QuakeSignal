-- App Attest key material is an app-instance integrity credential, not a
-- customer account. Challenge rows bind a single exact device mutation to a
-- short-lived Apple proof; keys retain the public verifier and monotonic
-- assertion counter only.
CREATE TABLE IF NOT EXISTS app_attest_challenges (
  id TEXT PRIMARY KEY,
  key_id TEXT NOT NULL,
  wire_key_id TEXT NOT NULL,
  operation TEXT NOT NULL CHECK (operation IN (
    'device-registration',
    'device-deletion',
    'test-push'
  )),
  method TEXT NOT NULL,
  path TEXT NOT NULL,
  body_sha256 TEXT NOT NULL,
  challenge TEXT NOT NULL,
  required_proof TEXT NOT NULL CHECK (required_proof IN ('attestation', 'assertion')),
  -- Keep a challenge scoped to the AAGUID verifier that issued it. This
  -- prevents an accidental shared D1 binding from crossing development and
  -- production App Attest environments.
  environment TEXT NOT NULL CHECK (environment IN ('development', 'production')),
  created_at_utc TEXT NOT NULL,
  expires_at_utc TEXT NOT NULL,
  consumed_at_utc TEXT
);

CREATE INDEX IF NOT EXISTS idx_app_attest_challenges_active
  ON app_attest_challenges(key_id, expires_at_utc, consumed_at_utc);

CREATE TABLE IF NOT EXISTS app_attest_keys (
  key_id TEXT PRIMARY KEY,
  public_key_pem TEXT NOT NULL,
  sign_count INTEGER NOT NULL DEFAULT 0 CHECK (sign_count >= 0),
  app_id TEXT NOT NULL,
  -- Development keys belong only to an isolated staging Worker. Production
  -- code continues to bind and query only `production` key material.
  environment TEXT NOT NULL CHECK (environment IN ('development', 'production')),
  validation_category INTEGER,
  bundle_version TEXT,
  receipt_base64 TEXT NOT NULL,
  attested_at_utc TEXT NOT NULL,
  last_asserted_at_utc TEXT,
  revoked_at_utc TEXT
);

-- A protected deletion or training test must prove it owns the subscription.
-- Existing pre-App-Attest subscriptions remain NULL until their next secure
-- registration, at which point the authenticated app instance claims them.
ALTER TABLE devices ADD COLUMN app_attest_key_id TEXT;

CREATE INDEX IF NOT EXISTS idx_devices_app_attest_key
  ON devices(app_attest_key_id);
