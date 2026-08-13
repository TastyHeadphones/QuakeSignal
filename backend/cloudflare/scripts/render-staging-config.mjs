#!/usr/bin/env node

import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, isAbsolute, relative, resolve } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath, pathToFileURL } from "node:url";

const SCRIPT_DIRECTORY = dirname(fileURLToPath(import.meta.url));
const WORKER_ROOT = resolve(SCRIPT_DIRECTORY, "..");
const TEMPLATE_PATH = resolve(
  WORKER_ROOT,
  "staging/wrangler.staging.template.json",
);
const PRODUCTION_CONFIG_PATH = resolve(WORKER_ROOT, "wrangler.jsonc");

const PRODUCTION_D1_DATABASE_NAME = "quakesignal-production";
const PRODUCTION_D1_DATABASE_ID = "834fba5c-0d99-4398-9565-18c6858eb2a8";
const PRODUCTION_RATE_LIMIT_NAMESPACE_IDS = new Set([
  "62228001",
  "62228002",
  "62228003",
]);
const PRODUCTION_WORKER_NAMES = new Set([
  "quakesignal-api",
  "quakesignal-production",
]);

const MAX_QUEUE_NAME_LENGTH = 63;
const DLQ_SUFFIX = "-alert-delivery-dlq";
const DLQ_PERSISTENCE_FALLBACK_SUFFIX = "-alert-delivery-dlq-fallback";
const MAX_STAGING_WORKER_NAME_LENGTH =
  MAX_QUEUE_NAME_LENGTH - DLQ_PERSISTENCE_FALLBACK_SUFFIX.length;
const RESOURCE_NAME_PATTERN = /^[a-z][a-z0-9-]*[a-z0-9]$/;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const BUNDLE_VERSION_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$/;

export class StagingConfigError extends Error {}

function fail(message) {
  throw new StagingConfigError(message);
}

function requiredEnvironmentValue(name, environment) {
  const value = environment[name]?.trim();
  if (!value) fail(`${name} is required`);
  return value;
}

function stagingResourceName(name, environment) {
  const value = requiredEnvironmentValue(name, environment);
  if (
    value.length < 3 ||
    value.length > MAX_STAGING_WORKER_NAME_LENGTH ||
    !RESOURCE_NAME_PATTERN.test(value) ||
    value.includes("--")
  ) {
    fail(
      `${name} must be 3-${MAX_STAGING_WORKER_NAME_LENGTH} lowercase letters, numbers, or single dashes`,
    );
  }

  const segments = value.split("-");
  if (!value.startsWith("quakesignal-") || !segments.includes("staging")) {
    fail(`${name} must start with quakesignal- and include a staging segment`);
  }

  if (PRODUCTION_WORKER_NAMES.has(value)) {
    fail(`${name} must not name a production Worker`);
  }

  return value;
}

function stagingD1DatabaseName(environment) {
  if (
    requiredEnvironmentValue(
      "CLOUDFLARE_STAGING_D1_DATABASE_NAME",
      environment,
    ) === PRODUCTION_D1_DATABASE_NAME
  ) {
    fail("CLOUDFLARE_STAGING_D1_DATABASE_NAME must not name the production D1 database");
  }
  const value = stagingResourceName(
    "CLOUDFLARE_STAGING_D1_DATABASE_NAME",
    environment,
  );
  return value;
}

function stagingD1DatabaseId(environment) {
  const value = requiredEnvironmentValue(
    "CLOUDFLARE_STAGING_D1_DATABASE_ID",
    environment,
  ).toLowerCase();
  if (!UUID_PATTERN.test(value)) {
    fail("CLOUDFLARE_STAGING_D1_DATABASE_ID must be a D1 UUID");
  }
  if (value === PRODUCTION_D1_DATABASE_ID) {
    fail("CLOUDFLARE_STAGING_D1_DATABASE_ID must not be the production D1 database ID");
  }
  return value;
}

function stagingRateLimitNamespaceId(name, environment) {
  const value = requiredEnvironmentValue(name, environment);
  if (!/^[1-9][0-9]*$/.test(value)) {
    fail(`${name} must be a positive decimal namespace ID`);
  }
  if (PRODUCTION_RATE_LIMIT_NAMESPACE_IDS.has(value)) {
    fail(`${name} must not use a production rate-limit namespace ID`);
  }
  return value;
}

function allowedBundleVersions(environment) {
  // GitHub exposes an unset Environment variable as an empty string. Treat
  // that exactly like omission so the checked-in Debug build's CFBundleVersion
  // 1 remains the safe default rather than making first staging deployment
  // depend on an otherwise optional variable.
  const configured = (
    environment.CLOUDFLARE_STAGING_ALLOWED_BUNDLE_VERSIONS ?? ""
  ).trim();
  const bundleVersions = configured || "1";
  const rawValues = bundleVersions
    .split(",")
    .map((value) => value.trim());

  if (
    rawValues.length === 0 ||
    rawValues.some((value) => !BUNDLE_VERSION_PATTERN.test(value))
  ) {
    fail(
      "CLOUDFLARE_STAGING_ALLOWED_BUNDLE_VERSIONS must be a comma-separated list of valid CFBundleVersion values",
    );
  }
  if (new Set(rawValues).size !== rawValues.length) {
    fail("CLOUDFLARE_STAGING_ALLOWED_BUNDLE_VERSIONS must not contain duplicates");
  }
  return rawValues.join(",");
}

function isChildPath(candidate, parent) {
  const pathFromParent = relative(parent, candidate);
  return (
    pathFromParent.length > 0 &&
    !pathFromParent.startsWith("..") &&
    !isAbsolute(pathFromParent)
  );
}

function allowedOutputRoots(environment) {
  const roots = [tmpdir(), environment.RUNNER_TEMP]
    .filter((value) => typeof value === "string" && value.trim())
    .map((value) => resolve(value));
  return [...new Set(roots)];
}

function parseOutputPath(arguments_, currentWorkingDirectory, environment) {
  if (arguments_.length !== 2 || arguments_[0] !== "--output") {
    fail("usage: node scripts/render-staging-config.mjs --output <path>");
  }

  const rawPath = arguments_[1]?.trim();
  if (!rawPath) fail("--output requires an explicit path");
  const outputPath = isAbsolute(rawPath)
    ? resolve(rawPath)
    : resolve(currentWorkingDirectory, rawPath);

  if (
    outputPath === PRODUCTION_CONFIG_PATH ||
    outputPath === TEMPLATE_PATH ||
    outputPath === resolve(WORKER_ROOT, "wrangler.json")
  ) {
    fail("refusing to overwrite a checked-in Worker configuration");
  }
  if (!allowedOutputRoots(environment).some((root) => isChildPath(outputPath, root))) {
    fail("staging config output must be under the OS temp directory or RUNNER_TEMP");
  }
  return outputPath;
}

function replacePlaceholders(value, replacements) {
  if (typeof value === "string") {
    return value.replace(/__([A-Z0-9_]+)__/g, (placeholder, key) => {
      if (!(key in replacements)) fail(`template uses unknown ${placeholder}`);
      return replacements[key];
    });
  }
  if (Array.isArray(value)) {
    return value.map((item) => replacePlaceholders(item, replacements));
  }
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([key, item]) => [
        key,
        replacePlaceholders(item, replacements),
      ]),
    );
  }
  return value;
}

function assertNoPlaceholders(value) {
  if (typeof value === "string") {
    if (/__[A-Z0-9_]+__/.test(value)) {
      fail("unresolved staging-config template placeholder");
    }
    return;
  }
  if (Array.isArray(value)) {
    value.forEach(assertNoPlaceholders);
    return;
  }
  if (value && typeof value === "object") {
    Object.values(value).forEach(assertNoPlaceholders);
  }
}

function assertStagingPolicy(config, values) {
  if (config.name !== values.workerName) fail("generated Worker name mismatch");
  if (config.workers_dev !== true) fail("staging must use workers.dev");
  if ("route" in config || "routes" in config) {
    fail("staging config must not contain routes or custom domains");
  }
  const migrationsDirectory = config.d1_databases?.[0]?.migrations_dir;
  if (
    typeof config.main !== "string" ||
    typeof migrationsDirectory !== "string" ||
    !isAbsolute(config.main) ||
    !isAbsolute(migrationsDirectory)
  ) {
    fail("generated main and migrations paths must be absolute");
  }

  const vars = config.vars ?? {};
  const expectedVars = {
    ENABLE_PRODUCTION_TEST_PUSH: "false",
    APP_ATTEST_ENFORCEMENT: "development",
    APP_ATTEST_DEVELOPMENT_ENVIRONMENT: "true",
    APP_ATTEST_APP_ID: "5TT564H883.com.quakesignal.app",
    APP_ATTEST_ALLOWED_BUNDLE_VERSIONS: values.bundleVersions,
    APP_ATTEST_REQUIRE_RELEASE_METADATA: "false",
    ALERT_DELIVERY_QUEUE_NAME: values.deliveryQueue,
    ALERT_DELIVERY_DLQ_NAME: values.deadLetterQueue,
    ALERT_DELIVERY_DLQ_FALLBACK_NAME: values.persistenceFallbackQueue,
  };
  for (const [name, expected] of Object.entries(expectedVars)) {
    if (vars[name] !== expected) fail(`staging var ${name} does not match policy`);
  }
  if ("APP_ATTEST_DEVELOPMENT_BYPASS" in vars) {
    fail("staging config must not enable APP_ATTEST_DEVELOPMENT_BYPASS");
  }

  const durableObjectBindings = config.durable_objects?.bindings ?? [];
  const durableObjectClasses = new Map(
    durableObjectBindings.map(({ name, class_name }) => [name, class_name]),
  );
  const migrations = config.migrations ?? [];
  if (
    durableObjectBindings.length !== 2 ||
    durableObjectClasses.get("RELAY") !== "QuakeRelay" ||
    durableObjectClasses.get("TRAINING_PUSH_SCHEDULER") !== "TrainingPushScheduler" ||
    migrations.length !== 2 ||
    migrations[0]?.tag !== "v1" ||
    migrations[0]?.new_sqlite_classes?.join(",") !== "QuakeRelay" ||
    migrations[1]?.tag !== "v2" ||
    migrations[1]?.new_sqlite_classes?.join(",") !== "TrainingPushScheduler"
  ) {
    fail("generated staging Durable Object bindings do not preserve the private training scheduler");
  }

  const database = config.d1_databases?.[0];
  if (
    !database ||
    database.database_name !== values.databaseName ||
    database?.database_id !== values.databaseId ||
    database.database_name === PRODUCTION_D1_DATABASE_NAME ||
    database.database_id === PRODUCTION_D1_DATABASE_ID
  ) {
    fail("generated staging D1 binding does not remain isolated");
  }

  const producerQueue = config.queues?.producers?.[0]?.queue;
  const [deliveryConsumer, deadLetterConsumer] = config.queues?.consumers ?? [];
  if (
    config.queues?.producers?.length !== 1 ||
    config.queues?.consumers?.length !== 2 ||
    producerQueue !== values.deliveryQueue ||
    deliveryConsumer?.queue !== values.deliveryQueue ||
    deliveryConsumer?.dead_letter_queue !== values.deadLetterQueue ||
    deadLetterConsumer?.queue !== values.deadLetterQueue ||
    deadLetterConsumer?.dead_letter_queue !== values.persistenceFallbackQueue ||
    config.queues?.consumers?.some(
      (consumer) => consumer.queue === values.persistenceFallbackQueue,
    )
  ) {
    fail("generated staging queue bindings do not preserve the consumerless DLQ persistence fallback");
  }

  const rateLimitNamespaceIds = new Set(
    (config.ratelimits ?? []).map((rateLimit) => rateLimit.namespace_id),
  );
  if (
    rateLimitNamespaceIds.size !== 3 ||
    !rateLimitNamespaceIds.has(values.deviceApiRateLimitNamespaceId) ||
    !rateLimitNamespaceIds.has(values.deviceMutationRateLimitNamespaceId) ||
    !rateLimitNamespaceIds.has(values.appAttestChallengeRateLimitNamespaceId) ||
    [...rateLimitNamespaceIds].some((id) =>
      PRODUCTION_RATE_LIMIT_NAMESPACE_IDS.has(id),
    )
  ) {
    fail("generated staging rate-limit namespaces do not remain isolated");
  }
}

export async function renderStagingConfig({
  environment = process.env,
  arguments_ = process.argv.slice(2),
  currentWorkingDirectory = process.cwd(),
} = {}) {
  const outputPath = parseOutputPath(
    arguments_,
    currentWorkingDirectory,
    environment,
  );
  const workerName = stagingResourceName(
    "CLOUDFLARE_STAGING_WORKER_NAME",
    environment,
  );
  const databaseName = stagingD1DatabaseName(environment);
  const databaseId = stagingD1DatabaseId(environment);
  const deviceApiRateLimitNamespaceId = stagingRateLimitNamespaceId(
    "CLOUDFLARE_STAGING_DEVICE_API_RATE_LIMIT_NAMESPACE_ID",
    environment,
  );
  const deviceMutationRateLimitNamespaceId = stagingRateLimitNamespaceId(
    "CLOUDFLARE_STAGING_DEVICE_MUTATION_RATE_LIMIT_NAMESPACE_ID",
    environment,
  );
  const appAttestChallengeRateLimitNamespaceId = stagingRateLimitNamespaceId(
    "CLOUDFLARE_STAGING_APP_ATTEST_CHALLENGE_RATE_LIMIT_NAMESPACE_ID",
    environment,
  );
  if (
    new Set([
      deviceApiRateLimitNamespaceId,
      deviceMutationRateLimitNamespaceId,
      appAttestChallengeRateLimitNamespaceId,
    ]).size !== 3
  ) {
    fail("staging rate-limit namespace IDs must be distinct");
  }

  const values = {
    workerName,
    databaseName,
    databaseId,
    deviceApiRateLimitNamespaceId,
    deviceMutationRateLimitNamespaceId,
    appAttestChallengeRateLimitNamespaceId,
    bundleVersions: allowedBundleVersions(environment),
    deliveryQueue: `${workerName}-alert-delivery`,
    deadLetterQueue: `${workerName}${DLQ_SUFFIX}`,
    persistenceFallbackQueue: `${workerName}${DLQ_PERSISTENCE_FALLBACK_SUFFIX}`,
  };

  const template = JSON.parse(await readFile(TEMPLATE_PATH, "utf8"));
  const config = replacePlaceholders(template, {
    WORKER_NAME: values.workerName,
    SOURCE_ROOT: WORKER_ROOT,
    D1_DATABASE_NAME: values.databaseName,
    D1_DATABASE_ID: values.databaseId,
    DEVICE_API_RATE_LIMIT_NAMESPACE_ID: values.deviceApiRateLimitNamespaceId,
    DEVICE_MUTATION_RATE_LIMIT_NAMESPACE_ID:
      values.deviceMutationRateLimitNamespaceId,
    APP_ATTEST_CHALLENGE_RATE_LIMIT_NAMESPACE_ID:
      values.appAttestChallengeRateLimitNamespaceId,
    ALLOWED_BUNDLE_VERSIONS: values.bundleVersions,
    ALERT_DELIVERY_QUEUE_NAME: values.deliveryQueue,
    ALERT_DELIVERY_DLQ_NAME: values.deadLetterQueue,
    ALERT_DELIVERY_DLQ_FALLBACK_NAME: values.persistenceFallbackQueue,
  });
  assertNoPlaceholders(config);
  assertStagingPolicy(config, values);

  await mkdir(dirname(outputPath), { recursive: true });
  await writeFile(outputPath, `${JSON.stringify(config, null, 2)}\n`, "utf8");
  return { config, outputPath };
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(resolve(process.argv[1])).href
) {
  renderStagingConfig()
    .then(({ outputPath }) => {
      process.stdout.write(`Rendered isolated staging config: ${outputPath}\n`);
    })
    .catch((error) => {
      process.stderr.write(`Staging config was not rendered: ${error.message}\n`);
      process.exitCode = 1;
    });
}
