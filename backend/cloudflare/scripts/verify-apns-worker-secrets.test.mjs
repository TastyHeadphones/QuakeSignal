import assert from "node:assert/strict";
import test from "node:test";

import {
  listedSecretNames,
  missingRequiredSecretNames,
  parseConfigArgument,
  requiredSecretNames,
  verifyAPNSSecretNames,
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

test("missing local Wrangler fails before any registry-capable process can run", () => {
  let spawnCalled = false;
  assert.throws(
    () => verifyAPNSSecretNames([], {
      spawn: () => {
        spawnCalled = true;
        throw new Error("must not spawn");
      },
      wranglerEntrypoint: "/definitely/missing/wrangler.js",
    }),
    /local Wrangler entrypoint is missing.*refusing any registry fallback/i,
  );
  assert.equal(spawnCalled, false);
});

test("secret inspection invokes only the reviewed local Wrangler through this Node executable", () => {
  const result = verifyAPNSSecretNames([], {
    spawn: (command, arguments_) => {
      assert.equal(command, process.execPath);
      assert.match(arguments_[0], /node_modules\/wrangler\/bin\/wrangler\.js$/);
      assert.deepEqual(arguments_.slice(1), ["secret", "list", "--format", "json"]);
      return {
        status: 0,
        stdout: JSON.stringify(requiredSecretNames.map((name) => ({ name }))),
      };
    },
  });
  assert.equal(result, 0);
});
