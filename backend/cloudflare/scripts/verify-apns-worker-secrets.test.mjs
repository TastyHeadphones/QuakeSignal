import assert from "node:assert/strict";
import test from "node:test";

import {
  listedSecretNames,
  missingRequiredSecretNames,
  parseConfigArgument,
  requiredSecretNames,
} from "./verify-apns-worker-secrets.mjs";

test("accepts only an explicit, nonempty staging config argument", () => {
  assert.equal(parseConfigArgument([]), undefined);
  assert.equal(parseConfigArgument(["--config", "/tmp/staging-wrangler.json"]), "/tmp/staging-wrangler.json");
  assert.throws(() => parseConfigArgument(["--config"]), /Usage/);
  assert.throws(() => parseConfigArgument(["--config", "", "--other"]), /Usage/);
});

test("checks secret names without reading any secret values", () => {
  const names = listedSecretNames(JSON.stringify(requiredSecretNames.map((name) => ({ name }))));
  assert.deepEqual(missingRequiredSecretNames(names), []);
  assert.deepEqual(
    missingRequiredSecretNames(listedSecretNames('[{"name":"APNS_KEY_ID"}]')),
    ["APNS_PRIVATE_KEY", "APNS_TEAM_ID", "APNS_BUNDLE_ID"],
  );
  assert.throws(() => listedSecretNames("{}"), /unexpected Worker secret-list format/);
});
