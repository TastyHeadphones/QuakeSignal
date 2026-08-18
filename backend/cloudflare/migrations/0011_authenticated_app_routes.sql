-- Persist only the APNs route derived by the Worker after App Attest identity
-- verification. Existing registrations are backfilled to the historical iOS
-- bundle so this migration does not interrupt the production population.
ALTER TABLE devices
  ADD COLUMN app_identity TEXT NOT NULL
    DEFAULT '5TT564H883.com.quakesignal.app'
    CHECK (length(app_identity) BETWEEN 3 AND 266);

ALTER TABLE devices
  ADD COLUMN apns_topic TEXT NOT NULL
    DEFAULT 'com.quakesignal.app'
    CHECK (length(apns_topic) BETWEEN 1 AND 255);

ALTER TABLE devices
  ADD COLUMN app_platform TEXT NOT NULL
    DEFAULT 'ios'
    CHECK (app_platform IN (
      'ios', 'ipados', 'macos', 'watchos', 'tvos', 'visionos'
    ));

-- Supports route audits and operational counts without changing rowid-based
-- delivery pagination. The runtime still revalidates every stored tuple
-- against its current deploy-time allow-list immediately before APNs.
CREATE INDEX IF NOT EXISTS idx_devices_authenticated_app_route
  ON devices(environment, app_identity, apns_topic, app_platform);
