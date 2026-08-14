import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
export const repositoryRoot = resolve(scriptDirectory, "../..");

const contractFiles = {
  project: "ios/project.yml",
  projectFile: "ios/QuakeSignal.xcodeproj/project.pbxproj",
  infoPlist: "ios/QuakeSignal/Supporting/Info.plist",
  workerConfig: "backend/cloudflare/wrangler.jsonc",
  iosWorkflow: ".github/workflows/ios.yml",
  cloudflareWorkflow: ".github/workflows/cloudflare.yml",
};

const APPROVED_WORKER_ORIGIN = "https://quakesignal-api.hopeso.workers.dev";
const CHECKOUT_ACTION = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1";
const ROOT_ENV = {
  XCODE_PROJECT: "ios/QuakeSignal.xcodeproj",
  XCODE_SCHEME: "QuakeSignal",
  XCODEGEN_VERSION: "2.46.0",
  XCODEGEN_SHA256: "4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806",
};
const ROOT_PERMISSIONS = { contents: "read" };
const ROOT_CONCURRENCY = {
  group: "ios-${{ github.workflow }}-${{ github.ref }}-${{ github.event_name }}",
  "cancel-in-progress": "${{ github.event_name != 'workflow_dispatch' }}",
};
// The production Worker deploy and the TestFlight signing job share this
// lock. That serializes a policy-changing deploy with the live policy smoke
// and the subsequent signed upload: a deployment either completes before the
// smoke or waits until the archive/upload completes.
const SHARED_PRODUCTION_POLICY_CONCURRENCY = {
  group: "quakesignal-production-app-attest-policy",
  "cancel-in-progress": false,
};
const TESTFLIGHT_JOB_HEADER = {
  name: "Archive and optionally upload TestFlight build",
  needs: "test",
  if: "github.event_name == 'workflow_dispatch' && (inputs.archive_only || inputs.upload_to_testflight) && github.ref == 'refs/heads/main' && github.ref_protected",
  "runs-on": "macos-latest",
  environment: { name: "ios-app-store-release" },
  concurrency: SHARED_PRODUCTION_POLICY_CONCURRENCY,
};
const CLOUDFLARE_DEPLOY_PRODUCTION_HEADER = {
  name: "Deploy production Worker",
  needs: "validate",
  if: "github.event_name == 'workflow_dispatch' && inputs.deploy_production && github.ref == 'refs/heads/main' && github.ref_protected",
  "runs-on": "ubuntu-latest",
  environment: { name: "cloudflare-production" },
  concurrency: SHARED_PRODUCTION_POLICY_CONCURRENCY,
};
// This covers the full effective workflow job graph: the ordinary test lane
// and every TestFlight post-smoke step (XcodeGen, signing material handling,
// archive, export, artifact verification, upload, artifact retention, and
// cleanup). A deliberate workflow change must update this reviewed value
// alongside its tests; an unreviewed sibling job, extra post-smoke step, or
// edited signing/upload action fails before release automation can use
// credentials.
const TESTFLIGHT_POST_SMOKE_SEQUENCE_FINGERPRINT = "sha256:GHBE1k4uqcheECQ5cNXKPICgIfw9u5qVAszmfpcilI4";
const WORKFLOW_JOBS_FINGERPRINT = "sha256:L7aiDGvFTkOYdNqTat2iPNfT0dwjKfkIZBBIh_rIOls";
const CLOUDFLARE_WORKFLOW_JOBS_FINGERPRINT = "sha256:MVyNUXvoZoqo5wXo0qmLaZow6cqQA8aUpc_YWLVvvjI";

const PRE_SIGNING_COMMAND = "node .github/scripts/verify-ios-release-contract.mjs --build-number \"$BUILD_NUMBER\"";
const REMOTE_SMOKE_COMMAND = [
  "set -euo pipefail",
  `if [ \"$IOS_RELEASE_API_BASE_URL\" != \"${APPROVED_WORKER_ORIGIN}\" ]; then`,
  `  echo \"::error::IOS_RELEASE_API_BASE_URL must be ${APPROVED_WORKER_ORIGIN}\"`,
  "  exit 1",
  "fi",
  "node scripts/wait-for-worker-readiness.mjs \"$IOS_RELEASE_API_BASE_URL\"",
  "node scripts/smoke-test.mjs \"$IOS_RELEASE_API_BASE_URL\" \\",
  "  --expected-app-attest-policy-fingerprint \"$APP_ATTEST_POLICY_FINGERPRINT\" \\",
  "  --required-app-attest-bundle-version \"$BUILD_NUMBER\"",
].join("\n") + "\n";
const ARCHIVE_COMMAND = [
  "xcodebuild archive",
  "-project \"$XCODE_PROJECT\"",
  "-scheme \"$XCODE_SCHEME\"",
  "-configuration Release",
  "-destination 'generic/platform=iOS'",
  "-archivePath \"$RUNNER_TEMP/QuakeSignal.xcarchive\"",
  "DEVELOPMENT_TEAM=5TT564H883",
  "CODE_SIGN_STYLE=Manual",
  "CODE_SIGN_IDENTITY='Apple Distribution'",
  "PROVISIONING_PROFILE_SPECIFIER=\"$IOS_PROFILE_NAME\"",
  "CURRENT_PROJECT_VERSION=\"$BUILD_NUMBER\"",
  "QUAKESIGNAL_API_BASE_URL=\"$IOS_RELEASE_API_BASE_URL\"",
].join(" ");

function fail(message) {
  throw new Error(`iOS release contract: ${message}`);
}

function exactlyOne(matches, label) {
  if (matches.length !== 1) {
    fail(`${label} must appear exactly once (found ${matches.length}).`);
  }
  return matches[0];
}

function releaseBuildNumber(value, label) {
  const normalized = String(value).trim();
  if (!/^[1-9][0-9]*$/.test(normalized)) {
    fail(`${label} must be a positive decimal CFBundleVersion.`);
  }
  return normalized;
}

function requestedBuildNumber(arguments_) {
  if (arguments_.length === 0) return undefined;
  if (arguments_.length !== 2 || arguments_[0] !== "--build-number") {
    fail("usage is verify-ios-release-contract.mjs [--build-number <CFBundleVersion>].");
  }
  return releaseBuildNumber(arguments_[1], "requested build_number");
}

function captureProjectBuildNumber(project) {
  const matches = [...project.matchAll(
    /^\s*CURRENT_PROJECT_VERSION:\s*(?:"([^"]+)"|'([^']+)'|([^\s#]+))\s*(?:#.*)?$/gm,
  )].map((match) => match[1] ?? match[2] ?? match[3]);
  return releaseBuildNumber(
    exactlyOne(matches, "ios/project.yml CURRENT_PROJECT_VERSION"),
    "ios/project.yml CURRENT_PROJECT_VERSION",
  );
}

function verifyGeneratedProject(projectFile, buildNumber) {
  const versions = [...projectFile.matchAll(
    /^\s*CURRENT_PROJECT_VERSION\s*=\s*([^;]+);\s*$/gm,
  )].map((match) => match[1].trim().replace(/^"|"$/g, ""));
  if (versions.length !== 3) {
    fail(`generated Xcode project must contain exactly 3 CURRENT_PROJECT_VERSION entries (found ${versions.length}).`);
  }
  for (const version of versions) {
    if (releaseBuildNumber(version, "generated Xcode project CURRENT_PROJECT_VERSION") !== buildNumber) {
      fail(`generated Xcode project CURRENT_PROJECT_VERSION ${version} does not match ios/project.yml ${buildNumber}.`);
    }
  }
  return versions.length;
}

function verifyInfoPlist(infoPlist) {
  exactlyOne([...infoPlist.matchAll(/<key>\s*CFBundleVersion\s*<\/key>/g)], "Info.plist CFBundleVersion");
  exactlyOne(
    [...infoPlist.matchAll(/<key>\s*CFBundleVersion\s*<\/key>\s*<string>\s*\$\(CURRENT_PROJECT_VERSION\)\s*<\/string>/g)],
    "Info.plist CFBundleVersion interpolation",
  );
}

function parseWorkerConfig(workerConfig) {
  const withoutComments = workerConfig.replace(
    /"(?:\\.|[^"\\])*"|\/\/[^\r\n]*|\/\*[\s\S]*?\*\//g,
    (token) => token.startsWith("\"") ? token : "",
  ).replace(/,\s*([}\]])/g, "$1");
  for (const key of [
    "APP_ATTEST_ENFORCEMENT",
    "APP_ATTEST_APP_ID",
    "APP_ATTEST_ALLOWED_BUNDLE_VERSIONS",
    "APP_ATTEST_REQUIRE_RELEASE_METADATA",
  ]) {
    const definitions = [...withoutComments.matchAll(new RegExp(`"${key}"\\s*:`, "g"))];
    if (definitions.length !== 1) {
      fail(`wrangler ${key} must be defined exactly once outside comments.`);
    }
  }
  let parsed;
  try {
    parsed = JSON.parse(withoutComments);
  } catch {
    fail("backend/cloudflare/wrangler.jsonc must be valid JSONC.");
  }
  if (!isRecord(parsed.vars)) {
    fail("backend/cloudflare/wrangler.jsonc must contain a vars object.");
  }
  return parsed.vars;
}

function captureWorkerAllowedVersions(workerConfig) {
  const vars = parseWorkerConfig(workerConfig);
  const raw = vars.APP_ATTEST_ALLOWED_BUNDLE_VERSIONS;
  if (typeof raw !== "string") {
    fail("APP_ATTEST_ALLOWED_BUNDLE_VERSIONS must be one string in wrangler vars.");
  }
  const versions = raw.split(",").map((value) => value.trim());
  if (versions.length === 0 || versions.some((value) => value === "")) {
    fail("APP_ATTEST_ALLOWED_BUNDLE_VERSIONS must be a nonempty comma-separated list.");
  }
  for (const version of versions) releaseBuildNumber(version, "APP_ATTEST_ALLOWED_BUNDLE_VERSIONS entry");
  if (new Set(versions).size !== versions.length) {
    fail("APP_ATTEST_ALLOWED_BUNDLE_VERSIONS must not contain duplicate versions.");
  }
  return versions.sort();
}

function requiredWorkerValue(vars, key, expected) {
  if (vars[key] !== expected) {
    fail(`wrangler ${key} must be exactly ${JSON.stringify(expected)} for the reviewed public release contract.`);
  }
}

function appAttestPolicyFingerprint(vars, allowedBundleVersions) {
  const policy = [
    `app_id=${vars.APP_ATTEST_APP_ID}`,
    "protocol_version=1",
    `required=${vars.APP_ATTEST_ENFORCEMENT !== "disabled"}`,
    `development_bypass_allowed=${vars.APP_ATTEST_ENFORCEMENT === "development" && vars.APP_ATTEST_DEVELOPMENT_BYPASS === "true"}`,
    `verification_environment=${vars.APP_ATTEST_ENFORCEMENT === "development" && vars.APP_ATTEST_DEVELOPMENT_ENVIRONMENT === "true" ? "development" : "production"}`,
    `require_release_metadata=${vars.APP_ATTEST_REQUIRE_RELEASE_METADATA === "true"}`,
    `allowed_bundle_versions=${allowedBundleVersions.join(",")}`,
    "",
  ].join("\n");
  return `sha256:${createHash("sha256").update(policy, "utf8").digest("base64url")}`;
}

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function record(value, label) {
  if (!isRecord(value)) fail(`${label} must be a mapping.`);
  return value;
}

function sameValue(actual, expected) {
  if (actual === expected) return true;
  if (Array.isArray(actual) && Array.isArray(expected)) {
    return actual.length === expected.length && actual.every((value, index) => sameValue(value, expected[index]));
  }
  if (isRecord(actual) && isRecord(expected)) {
    const actualKeys = Object.keys(actual).sort();
    const expectedKeys = Object.keys(expected).sort();
    return JSON.stringify(actualKeys) === JSON.stringify(expectedKeys) &&
      actualKeys.every((key) => sameValue(actual[key], expected[key]));
  }
  return false;
}

function exactRecord(value, expected, label) {
  const actual = record(value, label);
  const actualKeys = Object.keys(actual).sort();
  const expectedKeys = Object.keys(expected).sort();
  if (JSON.stringify(actualKeys) !== JSON.stringify(expectedKeys)) {
    fail(`${label} must contain exactly ${expectedKeys.join(", ")}.`);
  }
  for (const [key, expectedValue] of Object.entries(expected)) {
    if (!sameValue(actual[key], expectedValue)) {
      fail(`${label}.${key} must be exactly ${JSON.stringify(expectedValue)}.`);
    }
  }
}

function exactRecordWithAllowedKeys(value, expected, allowedKeys, label) {
  const actual = record(value, label);
  const actualKeys = Object.keys(actual).sort();
  const expectedKeys = [...new Set([...Object.keys(expected), ...allowedKeys])].sort();
  if (JSON.stringify(actualKeys) !== JSON.stringify(expectedKeys)) {
    fail(`${label} must contain exactly ${expectedKeys.join(", ")}.`);
  }
  for (const [key, expectedValue] of Object.entries(expected)) {
    if (!sameValue(actual[key], expectedValue)) {
      fail(`${label}.${key} must be exactly ${JSON.stringify(expectedValue)}.`);
    }
  }
}

function canonicalJSON(value) {
  if (Array.isArray(value)) return value.map(canonicalJSON);
  if (isRecord(value)) {
    return Object.fromEntries(
      Object.keys(value).sort().map((key) => [key, canonicalJSON(value[key])]),
    );
  }
  return value;
}

function workflowSequenceFingerprint(value) {
  return `sha256:${createHash("sha256").update(JSON.stringify(canonicalJSON(value)), "utf8").digest("base64url")}`;
}

// Parse the effective YAML rather than matching source lines. Ruby/Psych is
// present on the macOS and Ubuntu GitHub runners already used by this project.
// Safe loading resolves quoted/escaped keys and aliases while rejecting custom
// object tags; the AST pass also rejects duplicate mapping keys.
const RUBY_YAML_TO_JSON = String.raw`
require "yaml"
require "json"
source = STDIN.read
tree = Psych.parse(source)
def validate_mapping_keys(node)
  return if node.nil?
  return unless node.respond_to?(:children)
  children = node.children
  return if children.nil?
  if node.is_a?(Psych::Nodes::Mapping)
    seen = {}
    children.each_slice(2) do |key, value|
      if key.is_a?(Psych::Nodes::Scalar)
        raise "duplicate YAML key: #{key.value}" if seen[key.value]
        seen[key.value] = true
      end
      validate_mapping_keys(key)
      validate_mapping_keys(value)
    end
  else
    children.each { |child| validate_mapping_keys(child) }
  end
end
validate_mapping_keys(tree)
value = YAML.safe_load(source, aliases: true, permitted_classes: [], permitted_symbols: [], symbolize_names: false)
raise "workflow must be a YAML mapping" unless value.is_a?(Hash)
puts JSON.generate(value)
`;

function parseEffectiveWorkflow(workflow) {
  try {
    const output = execFileSync("ruby", ["-r", "yaml", "-r", "json", "-e", RUBY_YAML_TO_JSON], {
      input: workflow,
      encoding: "utf8",
      stdio: ["pipe", "pipe", "pipe"],
    });
    return record(JSON.parse(output), "iOS workflow");
  } catch (error) {
    const detail = error && typeof error === "object" && "stderr" in error
      ? String(error.stderr).trim()
      : "";
    fail(`.github/workflows/ios.yml must be safe, duplicate-free YAML${detail ? `: ${detail}` : "."}`);
  }
}

function workflowDispatch(workflow) {
  // Psych follows YAML 1.1 and emits the unquoted GitHub key `on` as true.
  const trigger = workflow.on ?? workflow.true;
  const dispatch = record(record(trigger, "iOS workflow triggers").workflow_dispatch, "iOS workflow workflow_dispatch");
  return record(dispatch.inputs, "iOS workflow workflow_dispatch inputs");
}

function stepByName(steps, name, label) {
  const matches = steps.filter((step) => isRecord(step) && step.name === name);
  return exactlyOne(matches, label);
}

function verifyArchiveWorkflow(workflowSource, buildNumber) {
  const workflow = parseEffectiveWorkflow(workflowSource);
  if (Object.hasOwn(workflow, "defaults")) {
    fail("workflow-level defaults are forbidden for the release-contract execution boundary.");
  }
  exactRecord(workflow.env, ROOT_ENV, "workflow env");
  exactRecord(workflow.permissions, ROOT_PERMISSIONS, "workflow permissions");
  exactRecord(workflow.concurrency, ROOT_CONCURRENCY, "workflow concurrency");

  const dispatch = workflowDispatch(workflow);
  exactRecord(record(dispatch.archive_only, "iOS workflow archive_only input"), {
    description: "Archive, export, and validate a signed IPA without uploading it to App Store Connect",
    required: false,
    default: false,
    type: "boolean",
  }, "iOS workflow archive_only input");
  exactRecord(record(dispatch.upload_to_testflight, "iOS workflow upload_to_testflight input"), {
    description: "Archive, sign, and upload a new build to TestFlight",
    required: false,
    default: false,
    type: "boolean",
  }, "iOS workflow upload_to_testflight input");
  const buildInput = record(dispatch.build_number, "iOS workflow build_number input");
  const defaultBuildNumber = releaseBuildNumber(buildInput.default, "iOS workflow build_number default");
  if (defaultBuildNumber !== buildNumber) {
    fail(`iOS workflow build_number default ${defaultBuildNumber} does not match ios/project.yml ${buildNumber}.`);
  }
  exactRecord(buildInput, {
    description: "Exact pre-approved CFBundleVersion from ios/project.yml and the Worker App Attest allow-list",
    required: false,
    default: buildNumber,
    type: "string",
  }, "iOS workflow build_number input");

  const jobs = record(workflow.jobs, "iOS workflow jobs");
  const testflight = record(jobs.testflight, "iOS workflow testflight job");
  exactRecordWithAllowedKeys(
    testflight,
    TESTFLIGHT_JOB_HEADER,
    ["steps"],
    "testflight job header",
  );
  if (!Array.isArray(testflight.steps)) fail("iOS workflow testflight steps must be a sequence.");
  const steps = testflight.steps;
  const expectedPrelude = [
    "Check out repository",
    "Verify iOS and Worker release contract",
    "Verify production notification origin readiness and contract",
  ];
  if (steps.length < expectedPrelude.length ||
      steps.slice(0, expectedPrelude.length).some((step, index) => step?.name !== expectedPrelude[index])) {
    fail("testflight must run checkout, static release contract, and remote policy smoke consecutively before all other steps.");
  }
  exactRecord(steps[0], {
    name: "Check out repository",
    uses: CHECKOUT_ACTION,
  }, "testflight checkout step");
  exactRecord(steps[1], {
    name: "Verify iOS and Worker release contract",
    id: "release-contract",
    env: { BUILD_NUMBER: "${{ inputs.build_number }}" },
    run: PRE_SIGNING_COMMAND,
  }, "pre-signing release-contract step");
  exactRecord(steps[2], {
    name: "Verify production notification origin readiness and contract",
    "working-directory": "backend/cloudflare",
    env: {
      IOS_RELEASE_API_BASE_URL: "${{ vars.CLOUDFLARE_WORKER_URL }}",
      BUILD_NUMBER: "${{ inputs.build_number }}",
      APP_ATTEST_POLICY_FINGERPRINT: "${{ steps.release-contract.outputs.app_attest_policy_fingerprint }}",
    },
    run: REMOTE_SMOKE_COMMAND,
  }, "remote App Attest policy contract step");

  const archive = stepByName(steps, "Archive signed App Store build", "iOS workflow signed archive step");
  exactRecord(archive, {
    name: "Archive signed App Store build",
    env: {
      BUILD_NUMBER: "${{ inputs.build_number }}",
      IOS_PROFILE_NAME: "${{ vars.IOS_APP_STORE_PROFILE_NAME }}",
      IOS_RELEASE_API_BASE_URL: "${{ vars.CLOUDFLARE_WORKER_URL }}",
    },
    run: ARCHIVE_COMMAND,
  }, "signed archive step");
  const postSmokeFingerprint = workflowSequenceFingerprint(steps.slice(expectedPrelude.length));
  if (postSmokeFingerprint !== TESTFLIGHT_POST_SMOKE_SEQUENCE_FINGERPRINT) {
    fail("testflight post-remote signing sequence must match the reviewed fingerprint.");
  }
  if (workflowSequenceFingerprint(jobs) !== WORKFLOW_JOBS_FINGERPRINT) {
    fail("iOS workflow jobs must match the reviewed release-job graph fingerprint.");
  }
}

function verifyProductionDeploymentSerialization(workflowSource) {
  const workflow = parseEffectiveWorkflow(workflowSource);
  const jobs = record(workflow.jobs, "Cloudflare workflow jobs");
  const deployProduction = record(
    jobs["deploy-production"],
    "Cloudflare deploy-production job",
  );
  exactRecordWithAllowedKeys(
    deployProduction,
    CLOUDFLARE_DEPLOY_PRODUCTION_HEADER,
    ["steps"],
    "Cloudflare deploy-production job header",
  );
  if (workflowSequenceFingerprint(jobs) !== CLOUDFLARE_WORKFLOW_JOBS_FINGERPRINT) {
    fail("Cloudflare workflow jobs must match the reviewed production-release graph fingerprint.");
  }
}

/**
 * Verify the static release boundary shared by the iOS archive and the Worker
 * App Attest policy. The protected workflow separately proves that the live
 * Worker has this source policy before secrets are materialized.
 */
export async function verifyIOSReleaseContract({
  root = repositoryRoot,
  expectedBuildNumber,
} = {}) {
  const paths = Object.fromEntries(
    Object.entries(contractFiles).map(([key, relativePath]) => [key, resolve(root, relativePath)]),
  );
  const [project, projectFile, infoPlist, workerConfig, iosWorkflow, cloudflareWorkflow] = await Promise.all([
    readFile(paths.project, "utf8"),
    readFile(paths.projectFile, "utf8"),
    readFile(paths.infoPlist, "utf8"),
    readFile(paths.workerConfig, "utf8"),
    readFile(paths.iosWorkflow, "utf8"),
    readFile(paths.cloudflareWorkflow, "utf8"),
  ]);
  const buildNumber = captureProjectBuildNumber(project);
  if (expectedBuildNumber !== undefined) {
    const requested = releaseBuildNumber(expectedBuildNumber, "requested build_number");
    if (requested !== buildNumber) {
      fail(`requested build_number ${requested} does not match ios/project.yml ${buildNumber}.`);
    }
  }
  const generatedProjectEntries = verifyGeneratedProject(projectFile, buildNumber);
  verifyInfoPlist(infoPlist);
  const workerVars = parseWorkerConfig(workerConfig);
  requiredWorkerValue(workerVars, "APP_ATTEST_ENFORCEMENT", "required");
  requiredWorkerValue(workerVars, "APP_ATTEST_APP_ID", "5TT564H883.com.quakesignal.app");
  requiredWorkerValue(workerVars, "APP_ATTEST_REQUIRE_RELEASE_METADATA", "false");
  if (workerVars.APP_ATTEST_DEVELOPMENT_BYPASS !== undefined || workerVars.APP_ATTEST_DEVELOPMENT_ENVIRONMENT !== undefined) {
    fail("reviewed public Worker App Attest policy must not configure a development bypass/environment.");
  }
  const allowedBundleVersions = captureWorkerAllowedVersions(workerConfig);
  if (!allowedBundleVersions.includes(buildNumber)) {
    fail(`APP_ATTEST_ALLOWED_BUNDLE_VERSIONS must include ios/project.yml build ${buildNumber}.`);
  }
  verifyArchiveWorkflow(iosWorkflow, buildNumber);
  verifyProductionDeploymentSerialization(cloudflareWorkflow);
  return {
    buildNumber,
    allowedBundleVersions,
    generatedProjectEntries,
    appAttestPolicyFingerprint: appAttestPolicyFingerprint(workerVars, allowedBundleVersions),
  };
}

async function main() {
  try {
    const verified = await verifyIOSReleaseContract({
      expectedBuildNumber: requestedBuildNumber(process.argv.slice(2)),
    });
    console.log(`Verified iOS Release build ${verified.buildNumber} against Worker App Attest versions ${verified.allowedBundleVersions.join(",")} and ${verified.generatedProjectEntries} generated Xcode configurations.`);
    if (process.env.GITHUB_OUTPUT) {
      await (await import("node:fs/promises")).appendFile(
        process.env.GITHUB_OUTPUT,
        `app_attest_policy_fingerprint=${verified.appAttestPolicyFingerprint}\n`,
        "utf8",
      );
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : "iOS release contract verification failed.";
    console.error(`::error::${message}`);
    process.exitCode = 1;
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await main();
}
