import assert from "node:assert/strict";

export const APP_ATTEST_POLICY_FORMAT = "quakesignal-app-attest-policy/v2";
export const REQUIRED_WOLFX_SOURCES = [
  "jma_eew",
  "jma_eqlist",
];

const APP_ATTEST_POLICY_FINGERPRINT_PATTERN = /^sha256:[A-Za-z0-9_-]{43}$/;
const BUNDLE_VERSION_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$/;
export const SMOKE_REQUEST_TIMEOUT_MS = 15_000;
export const SMOKE_MAX_RESPONSE_BYTES = 1024 * 1024;

async function readBoundedResponseBody(response, maximumBytes, abort) {
  if (response.body === null) return new Uint8Array();
  const reader = response.body.getReader();
  const chunks = [];
  let length = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      length += value.byteLength;
      if (length > maximumBytes) {
        abort();
        throw new Error(`smoke response exceeded ${maximumBytes} bytes`);
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const body = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return body;
}

/**
 * A release smoke must validate the configured Worker origin itself. Following
 * a redirect could otherwise validate a different host after the protected
 * environment variable was approved.
 */
export async function fetchWithoutRedirect(
  fetchImpl,
  input,
  init = {},
  {
    timeoutMs = SMOKE_REQUEST_TIMEOUT_MS,
    maximumResponseBytes = SMOKE_MAX_RESPONSE_BYTES,
  } = {},
) {
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs <= 0) {
    throw new Error("smoke request timeout must be a positive integer");
  }
  if (!Number.isSafeInteger(maximumResponseBytes) || maximumResponseBytes <= 0) {
    throw new Error("smoke response limit must be a positive integer");
  }
  const controller = new AbortController();
  const callerSignal = init.signal;
  const forwardAbort = () => controller.abort(callerSignal.reason);
  if (callerSignal?.aborted) forwardAbort();
  else callerSignal?.addEventListener("abort", forwardAbort, { once: true });
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => {
      const error = new Error(`smoke request exceeded ${timeoutMs}ms`);
      controller.abort(error);
      reject(error);
    }, timeoutMs);
  });
  try {
    return await Promise.race([
      (async () => {
        const response = await fetchImpl(input, {
          ...init,
          redirect: "error",
          signal: controller.signal,
        });
        const body = await readBoundedResponseBody(
          response,
          maximumResponseBytes,
          () => controller.abort(new Error(`smoke response exceeded ${maximumResponseBytes} bytes`)),
        );
        return new Response(body.length > 0 ? body : null, {
          headers: response.headers,
          status: response.status,
          statusText: response.statusText,
        });
      })(),
      timeout,
    ]);
  } finally {
    clearTimeout(timer);
    callerSignal?.removeEventListener("abort", forwardAbort);
  }
}

export function hasReadyWolfxSourceHealth(upstream) {
  const sources = upstream?.sources;
  if (sources === null || typeof sources !== "object" || Array.isArray(sources)) return false;
  // The Worker health payload also reports configured non-Wolfx feeds. The
  // release gate must require the two approved JMA feeds, while allowing that
  // broader inventory to remain visible for operational diagnostics.
  return REQUIRED_WOLFX_SOURCES.every((source) => {
    const health = sources[source];
    return health !== null && typeof health === "object" && !Array.isArray(health) &&
      health.stale === false &&
      ["websocket", "http-polling"].includes(health.transport);
  });
}

export function assertReadyWolfxSourceHealth(upstream) {
  assert.equal(
    hasReadyWolfxSourceHealth(upstream),
    true,
    "production health must expose the two approved JMA sources as fresh on an allowed transport",
  );
}

export function assertReadyDeliveryHealth(delivery) {
  assert.equal(
    delivery?.status,
    "ready",
    "production health must not pass without APNs readiness",
  );
  assert.equal(
    delivery?.apnsConfigured,
    true,
    "production health must explicitly confirm APNs signing configuration",
  );
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
