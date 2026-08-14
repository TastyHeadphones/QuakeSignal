import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const CLOUDFLARE_API_BASE = "https://api.cloudflare.com/client/v4";

// UniSphereco LLC approved this exact public Workers.dev production origin.
// It is intentionally not a Custom Domain, route, zone WAF dependency, or
// private-CA/mTLS deployment.
export const PRODUCTION_WORKER_NAME = "quakesignal-api";
export const PRODUCTION_WORKERS_SUBDOMAIN = "hopeso";
export const PRODUCTION_WORKER_URL = "https://quakesignal-api.hopeso.workers.dev";

export const APP_ATTEST_DEPLOYMENT_PHASE = {
  launch: "launch",
  testflightBootstrap: "testflight-bootstrap",
};

function fail(message) {
  throw new Error(message);
}

/**
 * A first production Worker deployment is needed before a TestFlight build can
 * exercise the real App Attest/APNs path. That bootstrap remains a protected,
 * APNs-ready deployment, but it cannot honestly claim that physical TestFlight
 * proof already happened. `launch` is the normal fail-closed phase; the
 * bootstrap phase is explicit and accepts only a reviewer-set `false` value
 * until that proof is recorded.
 */
export function verifyAppAttestDeploymentPhase(environment) {
  const phase = environment.APP_ATTEST_DEPLOYMENT_PHASE?.trim() ||
    APP_ATTEST_DEPLOYMENT_PHASE.launch;
  const approved = environment.APP_ATTEST_PRODUCTION_ENFORCED;

  if (phase === APP_ATTEST_DEPLOYMENT_PHASE.launch) {
    if (approved !== "true") {
      fail("APP_ATTEST_PRODUCTION_ENFORCED must be exactly true for a production launch deployment.");
    }
    return phase;
  }

  if (phase === APP_ATTEST_DEPLOYMENT_PHASE.testflightBootstrap) {
    if (approved !== "false") {
      fail("APP_ATTEST_PRODUCTION_ENFORCED must be exactly false for a TestFlight bootstrap deployment.");
    }
    return phase;
  }

  fail("APP_ATTEST_DEPLOYMENT_PHASE must be launch or testflight-bootstrap.");
}

export function verifyProductionWorkerOrigin(environment) {
  if (environment.CLOUDFLARE_WORKER_URL !== PRODUCTION_WORKER_URL) {
    fail(`CLOUDFLARE_WORKER_URL must be exactly ${PRODUCTION_WORKER_URL}.`);
  }
  return PRODUCTION_WORKER_URL;
}

async function fetchCloudflareJSON(url, token, fetchImpl) {
  let response;
  try {
    response = await fetchImpl(url, {
      headers: { Authorization: `Bearer ${token}` },
      signal: AbortSignal.timeout(10_000),
    });
  } catch {
    fail("Could not verify the Cloudflare account Workers.dev subdomain.");
  }

  let payload;
  try {
    payload = await response.json();
  } catch {
    fail("Cloudflare returned an invalid Workers.dev production-gate response.");
  }

  if (!response.ok || payload?.success !== true || !payload?.result) {
    fail("Cloudflare Workers.dev subdomain is unavailable for the production gate.");
  }

  return payload.result;
}

/**
 * `workers.dev` does not have a customer zone, so this gate verifies the
 * selected account's exact Workers.dev subdomain instead of claiming to verify
 * a Custom Domain or zone WAF rule. Native Cloudflare rate-limit bindings
 * remain versioned in wrangler.jsonc and are validated by the workflow's
 * Wrangler dry run. APNs secret names are verified separately by
 * `verify-apns-worker-secrets.mjs` before deployment.
 */
export async function verifyProductionGates(
  environment = process.env,
  fetchImpl = fetch,
) {
  const required = [
    "CLOUDFLARE_API_TOKEN",
    "CLOUDFLARE_ACCOUNT_ID",
    "CLOUDFLARE_WORKER_URL",
    "APP_ATTEST_PRODUCTION_ENFORCED",
  ];
  const missing = required.filter((name) => !environment[name]?.trim());
  if (missing.length > 0) {
    fail(`Missing protected Cloudflare production configuration: ${missing.join(", ")}`);
  }

  const accountId = environment.CLOUDFLARE_ACCOUNT_ID;
  if (!/^[a-f0-9]{32}$/i.test(accountId)) {
    fail("CLOUDFLARE_ACCOUNT_ID must be a 32-character Cloudflare ID.");
  }

  const workersSubdomain = await fetchCloudflareJSON(
    `${CLOUDFLARE_API_BASE}/accounts/${accountId}/workers/subdomain`,
    environment.CLOUDFLARE_API_TOKEN,
    fetchImpl,
  );
  if (workersSubdomain.subdomain !== PRODUCTION_WORKERS_SUBDOMAIN) {
    fail(`Cloudflare account must own the ${PRODUCTION_WORKERS_SUBDOMAIN}.workers.dev subdomain.`);
  }

  return {
    origin: verifyProductionWorkerOrigin(environment),
    phase: verifyAppAttestDeploymentPhase(environment),
    workersSubdomain: workersSubdomain.subdomain,
  };
}

async function main() {
  try {
    const verified = await verifyProductionGates();
    console.log(
      `Verified ${verified.phase} App Attest gate for ${verified.workersSubdomain}.workers.dev and the approved public production origin ${verified.origin}.`,
    );
  } catch (error) {
    const message = error instanceof Error ? error.message : "Cloudflare production gate failed.";
    console.error(`::error::${message}`);
    process.exitCode = 1;
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await main();
}
