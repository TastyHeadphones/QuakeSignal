import assert from "node:assert/strict";

export const APP_ATTEST_POLICY_FORMAT = "quakesignal-app-attest-policy/v1";

const APP_ATTEST_POLICY_FINGERPRINT_PATTERN = /^sha256:[A-Za-z0-9_-]{43}$/;
const BUNDLE_VERSION_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$/;

/**
 * A release smoke must validate the configured Worker origin itself. Following
 * a redirect could otherwise validate a different host after the protected
 * environment variable was approved.
 */
export function fetchWithoutRedirect(fetchImpl, input, init = {}) {
  return fetchImpl(input, { ...init, redirect: "error" });
}

/**
 * Parse the release-only policy assertions without making a network request so
 * CI can fail locally for a malformed command rather than silently skipping a
 * deployment-consistency check.
 */
export function parseSmokeTestArguments(
  arguments_ = process.argv.slice(2),
  environment = process.env,
) {
  const positional = [];
  let expectedAppAttestPolicyFingerprint;
  let requiredAppAttestBundleVersion;

  for (let index = 0; index < arguments_.length; index += 1) {
    const argument = arguments_[index];
    if (argument === "--expected-app-attest-policy-fingerprint") {
      if (expectedAppAttestPolicyFingerprint !== undefined) {
        throw new Error("--expected-app-attest-policy-fingerprint may be supplied only once.");
      }
      expectedAppAttestPolicyFingerprint = arguments_[++index];
      if (!APP_ATTEST_POLICY_FINGERPRINT_PATTERN.test(expectedAppAttestPolicyFingerprint ?? "")) {
        throw new Error("--expected-app-attest-policy-fingerprint must be sha256:<base64url>.");
      }
      continue;
    }
    if (argument === "--required-app-attest-bundle-version") {
      if (requiredAppAttestBundleVersion !== undefined) {
        throw new Error("--required-app-attest-bundle-version may be supplied only once.");
      }
      requiredAppAttestBundleVersion = arguments_[++index];
      if (!BUNDLE_VERSION_PATTERN.test(requiredAppAttestBundleVersion ?? "")) {
        throw new Error("--required-app-attest-bundle-version must be a valid bundle version.");
      }
      continue;
    }
    if (argument.startsWith("--")) {
      throw new Error(`Unknown smoke-test option: ${argument}`);
    }
    positional.push(argument);
  }

  if (positional.length > 1) {
    throw new Error("Usage: node scripts/smoke-test.mjs [url] [policy assertion options]");
  }
  const baseURL = positional[0] ?? environment.QUAKESIGNAL_API_URL;
  if (!baseURL?.trim()) {
    throw new Error(
      "Usage: node scripts/smoke-test.mjs https://quakesignal-api.hopeso.workers.dev [--expected-app-attest-policy-fingerprint sha256:<base64url> --required-app-attest-bundle-version <build>]",
    );
  }
  if (
    (expectedAppAttestPolicyFingerprint === undefined) !==
    (requiredAppAttestBundleVersion === undefined)
  ) {
    throw new Error(
      "--expected-app-attest-policy-fingerprint and --required-app-attest-bundle-version must be supplied together.",
    );
  }

  return {
    baseURL,
    expectedAppAttestPolicyFingerprint,
    requiredAppAttestBundleVersion,
  };
}

/**
 * Health exposes a deployment fingerprint rather than a claim that every
 * iOS App Attest proof carries Apple release metadata. The build-membership
 * check therefore proves the deployed allow-list agrees with the release
 * contract; it is not a substitute for cryptographic metadata enforcement.
 */
export function assertAppAttestPolicyHealth(
  healthBody,
  {
    expectedAppAttestPolicyFingerprint,
    requiredAppAttestBundleVersion,
  } = {},
) {
  const policy = healthBody?.appAttestPolicy;
  assert.equal(
    policy?.format,
    APP_ATTEST_POLICY_FORMAT,
    "health endpoint must identify its App Attest policy fingerprint format",
  );
  assert.match(
    policy?.fingerprint ?? "",
    APP_ATTEST_POLICY_FINGERPRINT_PATTERN,
    "health endpoint must expose a SHA-256 App Attest policy fingerprint",
  );
  assert.ok(
    Array.isArray(policy?.allowedBundleVersions) &&
      policy.allowedBundleVersions.length > 0,
    "health endpoint must expose a non-empty effective App Attest bundle-version allow-list",
  );
  assert.ok(
    policy.allowedBundleVersions.every(
      (version) => typeof version === "string" && BUNDLE_VERSION_PATTERN.test(version),
    ),
    "health endpoint must expose only valid App Attest bundle versions",
  );
  assert.deepEqual(
    policy.allowedBundleVersions,
    [...new Set(policy.allowedBundleVersions)].sort(),
    "health endpoint must expose a sorted, de-duplicated App Attest bundle-version allow-list",
  );

  if (expectedAppAttestPolicyFingerprint !== undefined) {
    assert.equal(
      policy.fingerprint,
      expectedAppAttestPolicyFingerprint,
      "deployed App Attest policy fingerprint must match this release's reviewed contract",
    );
    assert.ok(
      policy.allowedBundleVersions.includes(requiredAppAttestBundleVersion),
      `deployed App Attest policy must allow build ${requiredAppAttestBundleVersion}`,
    );
  }
  return policy;
}
