import assert from "node:assert/strict";
import test from "node:test";

import {
  APP_ATTEST_DEPLOYMENT_PHASE,
  PRODUCTION_WORKER_URL,
  PRODUCTION_WORKERS_SUBDOMAIN,
  TERMINAL_DLQ_FALLBACK_MONITOR_RECOVERY_VERIFICATION_VARIABLE,
  verifyAppAttestDeploymentPhase,
  verifyProductionGates,
  verifyProductionWorkerOrigin,
  verifyTerminalDlqFallbackMonitorRecovery,
} from "./verify-production-gates.mjs";

const environment = {
  CLOUDFLARE_API_TOKEN: "test-token",
  CLOUDFLARE_ACCOUNT_ID: "a".repeat(32),
  CLOUDFLARE_WORKER_URL: PRODUCTION_WORKER_URL,
  APP_ATTEST_PRODUCTION_ENFORCED: "true",
  [TERMINAL_DLQ_FALLBACK_MONITOR_RECOVERY_VERIFICATION_VARIABLE]: "true",
};

function fetchWithWorkersSubdomain(subdomain = PRODUCTION_WORKERS_SUBDOMAIN) {
  return async (url) => {
    assert.equal(
      url,
      `https://api.cloudflare.com/client/v4/accounts/${environment.CLOUDFLARE_ACCOUNT_ID}/workers/subdomain`,
    );
    return {
      ok: true,
      json: async () => ({
        success: true,
        result: { subdomain },
      }),
    };
  };
}

test("accepts the approved public Workers.dev production origin", async () => {
  const result = await verifyProductionGates(environment, fetchWithWorkersSubdomain());
  assert.deepEqual(result, {
    origin: PRODUCTION_WORKER_URL,
    phase: APP_ATTEST_DEPLOYMENT_PHASE.launch,
    workersSubdomain: PRODUCTION_WORKERS_SUBDOMAIN,
    terminalDlqFallbackMonitorRecoveryVerified: true,
  });
});

test("fails closed when protected production values are absent", async () => {
  await assert.rejects(
    verifyProductionGates(
      { ...environment, CLOUDFLARE_WORKER_URL: "" },
      fetchWithWorkersSubdomain(),
    ),
    /missing protected Cloudflare production configuration/i,
  );
  await assert.rejects(
    verifyProductionGates(
      { ...environment, APP_ATTEST_PRODUCTION_ENFORCED: "" },
      fetchWithWorkersSubdomain(),
    ),
    /missing protected Cloudflare production configuration/i,
  );
  await assert.rejects(
    verifyProductionGates(
      {
        ...environment,
        [TERMINAL_DLQ_FALLBACK_MONITOR_RECOVERY_VERIFICATION_VARIABLE]: "",
      },
      fetchWithWorkersSubdomain(),
    ),
    /missing protected Cloudflare production configuration/i,
  );
});

test("requires an explicit protected monitor and recovery attestation without querying Queue depth", async () => {
  assert.equal(verifyTerminalDlqFallbackMonitorRecovery(environment), true);
  assert.throws(
    () =>
      verifyTerminalDlqFallbackMonitorRecovery({
        ...environment,
        [TERMINAL_DLQ_FALLBACK_MONITOR_RECOVERY_VERIFICATION_VARIABLE]: "false",
      }),
    /must be exactly true after an operator verifies the terminal DLQ fallback monitor and recovery procedure/i,
  );

  await assert.rejects(
    verifyProductionGates(
      {
        ...environment,
        [TERMINAL_DLQ_FALLBACK_MONITOR_RECOVERY_VERIFICATION_VARIABLE]: "false",
      },
      async () => {
        throw new Error("the Cloudflare API must not be called before this gate fails");
      },
    ),
    /must be exactly true after an operator verifies the terminal DLQ fallback monitor and recovery procedure/i,
  );
});

test("fails closed when the deployment account does not own hopeso.workers.dev", async () => {
  await assert.rejects(
    verifyProductionGates(environment, fetchWithWorkersSubdomain("another-account")),
    /must own the hopeso\.workers\.dev subdomain/i,
  );
});

test("requires the exact user-approved public Workers.dev origin", () => {
  assert.equal(verifyProductionWorkerOrigin(environment), PRODUCTION_WORKER_URL);
  assert.throws(
    () =>
      verifyProductionWorkerOrigin({
        ...environment,
        CLOUDFLARE_WORKER_URL: "https://other-worker.hopeso.workers.dev",
      }),
    /must be exactly https:\/\/quakesignal-api\.hopeso\.workers\.dev/i,
  );
});

test("requires a reviewer-approved phase for launch versus TestFlight bootstrap", () => {
  assert.equal(
    verifyAppAttestDeploymentPhase({
      ...environment,
      APP_ATTEST_DEPLOYMENT_PHASE: APP_ATTEST_DEPLOYMENT_PHASE.launch,
    }),
    APP_ATTEST_DEPLOYMENT_PHASE.launch,
  );
  assert.equal(
    verifyAppAttestDeploymentPhase({
      ...environment,
      APP_ATTEST_PRODUCTION_ENFORCED: "false",
      APP_ATTEST_DEPLOYMENT_PHASE: APP_ATTEST_DEPLOYMENT_PHASE.testflightBootstrap,
    }),
    APP_ATTEST_DEPLOYMENT_PHASE.testflightBootstrap,
  );
  assert.throws(
    () =>
      verifyAppAttestDeploymentPhase({
        ...environment,
        APP_ATTEST_PRODUCTION_ENFORCED: "false",
      }),
    /must be exactly true/i,
  );
  assert.throws(
    () =>
      verifyAppAttestDeploymentPhase({
        ...environment,
        APP_ATTEST_DEPLOYMENT_PHASE: APP_ATTEST_DEPLOYMENT_PHASE.testflightBootstrap,
      }),
    /must be exactly false/i,
  );
  assert.throws(
    () =>
      verifyAppAttestDeploymentPhase({
        ...environment,
        APP_ATTEST_DEPLOYMENT_PHASE: "preview",
      }),
    /must be launch or testflight-bootstrap/i,
  );
});

test("requires the terminal fallback monitor attestation during TestFlight bootstrap too", async () => {
  const bootstrapEnvironment = {
    ...environment,
    APP_ATTEST_PRODUCTION_ENFORCED: "false",
    APP_ATTEST_DEPLOYMENT_PHASE: APP_ATTEST_DEPLOYMENT_PHASE.testflightBootstrap,
  };
  const result = await verifyProductionGates(
    bootstrapEnvironment,
    fetchWithWorkersSubdomain(),
  );
  assert.equal(result.phase, APP_ATTEST_DEPLOYMENT_PHASE.testflightBootstrap);
  assert.equal(result.terminalDlqFallbackMonitorRecoveryVerified, true);

  await assert.rejects(
    verifyProductionGates(
      {
        ...bootstrapEnvironment,
        [TERMINAL_DLQ_FALLBACK_MONITOR_RECOVERY_VERIFICATION_VARIABLE]: "false",
      },
      async () => {
        throw new Error("the Cloudflare API must not be called before this gate fails");
      },
    ),
    /must be exactly true after an operator verifies the terminal DLQ fallback monitor and recovery procedure/i,
  );
});
