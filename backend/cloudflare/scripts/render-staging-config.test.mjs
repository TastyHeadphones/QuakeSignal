import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { isAbsolute, join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const SCRIPT_DIRECTORY = resolve(fileURLToPath(new URL(".", import.meta.url)));
const WORKER_ROOT = resolve(SCRIPT_DIRECTORY, "..");
const RENDERER = join(SCRIPT_DIRECTORY, "render-staging-config.mjs");

const validEnvironment = {
  CLOUDFLARE_STAGING_WORKER_NAME: "quakesignal-api-staging",
  CLOUDFLARE_STAGING_D1_DATABASE_NAME: "quakesignal-api-staging",
  CLOUDFLARE_STAGING_D1_DATABASE_ID: "11111111-1111-4111-8111-111111111111",
  CLOUDFLARE_STAGING_DEVICE_API_RATE_LIMIT_NAMESPACE_ID: "72228001",
  CLOUDFLARE_STAGING_DEVICE_MUTATION_RATE_LIMIT_NAMESPACE_ID: "72228002",
  CLOUDFLARE_STAGING_APP_ATTEST_CHALLENGE_RATE_LIMIT_NAMESPACE_ID: "72228003",
};

function render({ outputPath, environment = {} }) {
  return spawnSync(process.execPath, [RENDERER, "--output", outputPath], {
    cwd: WORKER_ROOT,
    env: { ...process.env, ...validEnvironment, ...environment },
    encoding: "utf8",
  });
}

test("renders an isolated workers.dev config with development App Attest", async () => {
  const directory = await mkdtemp(join(tmpdir(), "quakesignal-staging-config-"));
  try {
    const outputPath = join(directory, "wrangler.staging.json");
    const result = render({
      outputPath,
      environment: { CLOUDFLARE_STAGING_ALLOWED_BUNDLE_VERSIONS: "1,2.0.0" },
    });
    assert.equal(result.status, 0, result.stderr);

    const config = JSON.parse(await readFile(outputPath, "utf8"));
    assert.equal(config.name, "quakesignal-api-staging");
    assert.equal(config.workers_dev, true);
    assert.equal("routes" in config, false);
    assert.equal("route" in config, false);
    assert.equal(isAbsolute(config.main), true);
    assert.equal(isAbsolute(config.d1_databases[0].migrations_dir), true);
    assert.equal(config.d1_databases[0].database_name, "quakesignal-api-staging");
    assert.equal(
      config.d1_databases[0].database_id,
      "11111111-1111-4111-8111-111111111111",
    );
    assert.deepEqual(config.vars, {
      ENABLE_PRODUCTION_TEST_PUSH: "false",
      APP_ATTEST_ENFORCEMENT: "development",
      APP_ATTEST_DEVELOPMENT_ENVIRONMENT: "true",
      APP_ATTEST_APP_ID: "5TT564H883.com.quakesignal.app",
      APP_ATTEST_ALLOWED_BUNDLE_VERSIONS: "1,2.0.0",
      APP_ATTEST_REQUIRE_RELEASE_METADATA: "false",
      ALERT_DELIVERY_QUEUE_NAME: "quakesignal-api-staging-alert-delivery",
      ALERT_DELIVERY_DLQ_NAME: "quakesignal-api-staging-alert-delivery-dlq",
      ALERT_DELIVERY_DLQ_FALLBACK_NAME:
        "quakesignal-api-staging-alert-delivery-dlq-fallback",
    });
    assert.equal("APP_ATTEST_DEVELOPMENT_BYPASS" in config.vars, false);
    assert.equal(
      config.queues.producers[0].queue,
      "quakesignal-api-staging-alert-delivery",
    );
    assert.equal(
      config.queues.consumers[0].dead_letter_queue,
      "quakesignal-api-staging-alert-delivery-dlq",
    );
    assert.equal(config.queues.consumers[1].queue,
      "quakesignal-api-staging-alert-delivery-dlq");
    assert.equal(
      config.queues.consumers[1].dead_letter_queue,
      "quakesignal-api-staging-alert-delivery-dlq-fallback",
    );
    assert.equal(
      config.queues.consumers.some(
        ({ queue }) => queue === "quakesignal-api-staging-alert-delivery-dlq-fallback",
      ),
      false,
      "the terminal D1-persistence fallback must remain consumerless",
    );
    assert.deepEqual(
      config.ratelimits.map((rateLimit) => rateLimit.namespace_id),
      ["72228001", "72228002", "72228003"],
    );
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("uses build 1 when GitHub expands the unset optional variable to an empty string", async () => {
  const directory = await mkdtemp(join(tmpdir(), "quakesignal-staging-config-"));
  try {
    const outputPath = join(directory, "wrangler.staging.json");
    const result = render({
      outputPath,
      // GitHub Actions expands an unset `vars.*` value to this exact value.
      environment: { CLOUDFLARE_STAGING_ALLOWED_BUNDLE_VERSIONS: "" },
    });
    assert.equal(result.status, 0, result.stderr);
    const config = JSON.parse(await readFile(outputPath, "utf8"));
    assert.equal(config.vars.APP_ATTEST_ALLOWED_BUNDLE_VERSIONS, "1");
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("rejects production resources, non-staging names, and repeated namespaces", async () => {
  const directory = await mkdtemp(join(tmpdir(), "quakesignal-staging-config-"));
  try {
    const cases = [
      {
        environment: {
          CLOUDFLARE_STAGING_D1_DATABASE_ID:
            "834fba5c-0d99-4398-9565-18c6858eb2a8",
        },
        expected: "must not be the production D1 database ID",
      },
      {
        environment: {
          CLOUDFLARE_STAGING_D1_DATABASE_NAME: "quakesignal-production",
        },
        expected: "must not name the production D1 database",
      },
      {
        environment: { CLOUDFLARE_STAGING_WORKER_NAME: "quakesignal-api" },
        expected: "include a staging segment",
      },
      {
        environment: {
          CLOUDFLARE_STAGING_DEVICE_MUTATION_RATE_LIMIT_NAMESPACE_ID:
            "72228001",
        },
        expected: "must be distinct",
      },
      {
        environment: {
          CLOUDFLARE_STAGING_APP_ATTEST_CHALLENGE_RATE_LIMIT_NAMESPACE_ID:
            "72228002",
        },
        expected: "must be distinct",
      },
      {
        environment: {
          CLOUDFLARE_STAGING_DEVICE_API_RATE_LIMIT_NAMESPACE_ID: "62228001",
        },
        expected: "must not use a production rate-limit namespace ID",
      },
      {
        environment: {
          CLOUDFLARE_STAGING_APP_ATTEST_CHALLENGE_RATE_LIMIT_NAMESPACE_ID:
            "62228003",
        },
        expected: "must not use a production rate-limit namespace ID",
      },
    ];

    for (const [index, testCase] of cases.entries()) {
      const result = render({
        outputPath: join(directory, `rejected-${index}.json`),
        environment: testCase.environment,
      });
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, new RegExp(testCase.expected));
    }
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("requires an explicit safe output path", async () => {
  const productionConfigPath = join(WORKER_ROOT, "wrangler.jsonc");
  const result = render({ outputPath: productionConfigPath });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /refusing to overwrite a checked-in Worker configuration/);

  const missingOutput = spawnSync(process.execPath, [RENDERER], {
    cwd: WORKER_ROOT,
    env: { ...process.env, ...validEnvironment },
    encoding: "utf8",
  });
  assert.notEqual(missingOutput.status, 0);
  assert.match(missingOutput.stderr, /usage: node scripts\/render-staging-config\.mjs --output <path>/);

  const unsafeOutput = render({
    outputPath: join(WORKER_ROOT, "generated-staging-wrangler.json"),
  });
  assert.notEqual(unsafeOutput.status, 0);
  assert.match(unsafeOutput.stderr, /must be under the OS temp directory or RUNNER_TEMP/);
});
