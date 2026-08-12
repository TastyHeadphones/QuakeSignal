-- Keep this constraint in a follow-on migration so any environment that has
-- already applied 0006 receives the same ownership guarantee. A hardware-
-- backed App Attest key protects one current APNs subscription; guarded
-- re-registration replaces that key's prior token before inserting a new one.
CREATE UNIQUE INDEX IF NOT EXISTS uq_devices_active_app_attest_key
  ON devices(app_attest_key_id)
  WHERE app_attest_key_id IS NOT NULL;
