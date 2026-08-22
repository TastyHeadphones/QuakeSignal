import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
export const repositoryRoot = resolve(scriptDirectory, "../..");

const files = {
  desktop: ".github/workflows/desktop-release.yml",
  desktopConfig: "desktop/src-tauri/tauri.conf.json",
  desktopRuntime: "desktop/src-tauri/src/lib.rs",
  homebrew: ".github/workflows/homebrew-tap.yml",
};

const REPOSITORY = "TastyHeadphones/QuakeSignal";
const CHECKOUT = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1";
const DOWNLOAD_ARTIFACT = "actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c";
const UPLOAD_ARTIFACT = "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a";

const DESKTOP_CONCURRENCY = {
  group: "desktop-release-${{ github.ref }}",
  "cancel-in-progress": false,
};
const PROVENANCE_HEADER = {
  name: "Verify protected tag provenance",
  if: "startsWith(github.ref, 'refs/tags/v') && github.ref_protected && github.repository == 'TastyHeadphones/QuakeSignal'",
  "runs-on": "ubuntu-latest",
  permissions: { contents: "read" },
};
const MACOS_DIRECT_HEADER = {
  name: "macOS direct/Homebrew universal",
  needs: ["verify-release-provenance"],
  if: [
    "always() && (",
    "  (startsWith(github.ref, 'refs/tags/v') &&",
    "   github.ref_protected &&",
    "   github.repository == 'TastyHeadphones/QuakeSignal' &&",
    "   needs.verify-release-provenance.result == 'success') ||",
    "  (github.event_name == 'workflow_dispatch' &&",
    "   github.ref == 'refs/heads/main' &&",
    "   github.ref_protected &&",
    "   inputs.build_macos_direct)",
    ")",
  ].join("\n"),
  "runs-on": "macos-latest",
  environment: { name: "macos-direct-release" },
  env: { RUST_TARGET: "universal-apple-darwin" },
};
const MACOS_APP_STORE_VERSION = "1.1.0";
const MACOS_APP_STORE_BUNDLE_IDENTIFIER = "com.quakesignal.desktop";
const MACOS_APP_STORE_APPLE_ID = "6800642853";
const MACOS_APP_STORE_ALTOOL_PLATFORM = "macos";
const MACOS_APP_STORE_HEADER = {
  name: "macOS App Store universal",
  if: "github.event_name == 'workflow_dispatch' && github.ref == 'refs/heads/main' && github.ref_protected && (inputs.build_macos_app_store == true || inputs.upload_macos_to_app_store_connect == true)",
  "runs-on": "macos-latest",
  environment: { name: "macos-app-store-release" },
  env: { RUST_TARGET: "universal-apple-darwin" },
};
const RELEASE_HEADER = {
  name: "Publish release",
  needs: ["verify-release-provenance", "macos-direct"],
  if: "always() && startsWith(github.ref, 'refs/tags/v') && github.ref_protected && github.repository == 'TastyHeadphones/QuakeSignal' && needs.verify-release-provenance.result == 'success' && needs.macos-direct.result == 'success'",
  "runs-on": "ubuntu-latest",
  permissions: { contents: "write" },
};
const HOMEBREW_CONCURRENCY = {
  group: "homebrew-tap-${{ inputs.version }}",
  "cancel-in-progress": false,
};
const HOMEBREW_ENV = {
  UPSTREAM_REPOSITORY: REPOSITORY,
  TAP_REPOSITORY: "TastyHeadphones/homebrew-tap",
};
const HOMEBREW_PUBLISH_HEADER = {
  name: "Verify notarized release and publish cask",
  if: "github.event_name == 'workflow_dispatch' && inputs.publish_to_tap && github.ref == 'refs/heads/main' && github.ref_protected && github.repository == 'TastyHeadphones/QuakeSignal'",
  "runs-on": "macos-latest",
  environment: { name: "homebrew-tap-release" },
};
const DESKTOP_JOB_IDS = [
  "macos-app-store",
  "macos-direct",
  "microsoft-store",
  "release",
  "verify-release-provenance",
  "windows",
];

// These fingerprints cover the direct-release and Homebrew step sequences.
// The explicit frontend gate below also covers every npm-based desktop build
// job, including Windows and the Mac App Store lane.
const MACOS_DIRECT_STEPS_FINGERPRINT = "sha256:9_cZ-KeTzLZFiOlAwbIJw4av4Zlihs9Xr2eXsQfnbmA";
const MACOS_APP_STORE_STEPS_FINGERPRINT = "sha256:hTaWK2GTIrrEc34RKsSVTM0n4llBmdOqS9KNelgqgF4";
const RELEASE_STEPS_FINGERPRINT = "sha256:3dX8Og0fyNOioMHFK-Jt8FiTZTqwkc8dhXjbovwV2qI";
const HOMEBREW_PUBLISH_STEPS_FINGERPRINT = "sha256:NuwuAFiTLY6LC19V3jx8XcjFSwpafYQVpgHgnveCywY";

const PROVENANCE_COMMAND = [
  "set -euo pipefail",
  "# Fetch main explicitly even though checkout fetched full history;",
  "# this avoids relying on checkout's remote-ref layout for tag runs.",
  "git fetch --no-tags --prune origin \\",
  "  '+refs/heads/main:refs/remotes/origin/main'",
  "",
  "tag_commit=\"$(git rev-parse \"${GITHUB_REF}^{commit}\")\"",
  "main_commit=\"$(git rev-parse 'refs/remotes/origin/main^{commit}')\"",
  "if ! git merge-base --is-ancestor \"$tag_commit\" \"$main_commit\"; then",
  "  echo \"::error::${GITHUB_REF} targets $tag_commit, which is not contained in protected main ($main_commit)\"",
  "  exit 1",
  "fi",
  "",
  "echo \"Verified ${GITHUB_REF} target $tag_commit is contained in protected main history at $main_commit.\"",
  "",
].join("\n");

function fail(message) {
  throw new Error(`desktop release contract: ${message}`);
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
  if (!sameValue(actual, expected)) {
    fail(`${label} must be exactly ${JSON.stringify(expected)}.`);
  }
}

function exactRecordWithSteps(value, expected, label) {
  const actual = record(value, label);
  const keys = Object.keys(actual).sort();
  const expectedKeys = [...Object.keys(expected), "steps"].sort();
  if (JSON.stringify(keys) !== JSON.stringify(expectedKeys) || !sameValue(
    Object.fromEntries(Object.entries(actual).filter(([key]) => key !== "steps")),
    expected,
  )) {
    fail(`${label} must contain the reviewed header and only a steps sequence in addition.`);
  }
  if (!Array.isArray(actual.steps)) fail(`${label}.steps must be a sequence.`);
  return actual.steps;
}

function exactNames(steps, names, label) {
  const actual = steps.map((step) => isRecord(step) ? step.name : undefined);
  if (!sameValue(actual, names)) {
    fail(`${label} must contain exactly these ordered steps: ${names.join(" → ")}.`);
  }
}

function step(steps, name, label) {
  const matches = steps.filter((candidate) => isRecord(candidate) && candidate.name === name);
  if (matches.length !== 1) fail(`${label} must appear exactly once (found ${matches.length}).`);
  return matches[0];
}

function requireText(value, snippets, label) {
  if (typeof value !== "string") fail(`${label} must be a shell command.`);
  for (const snippet of snippets) {
    if (!value.includes(snippet)) fail(`${label} must include ${JSON.stringify(snippet)}.`);
  }
}

function canonicalJSON(value) {
  if (Array.isArray(value)) return value.map(canonicalJSON);
  if (isRecord(value)) {
    return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonicalJSON(value[key])]));
  }
  return value;
}

function fingerprint(value) {
  return `sha256:${createHash("sha256").update(JSON.stringify(canonicalJSON(value)), "utf8").digest("base64url")}`;
}

function secretReferences(value) {
  if (typeof value === "string") return /\bsecrets\b/i.test(value) ? [value] : [];
  if (Array.isArray(value)) return value.flatMap(secretReferences);
  if (isRecord(value)) return Object.values(value).flatMap(secretReferences);
  return [];
}

function assertNoSecrets(value, label) {
  if (secretReferences(value).length > 0) fail(`${label} must not materialize or reference GitHub secrets.`);
}

function environmentName(job) {
  if (!isRecord(job)) return undefined;
  if (typeof job.environment === "string") return job.environment;
  return isRecord(job.environment) ? job.environment.name : undefined;
}

function isStaticEnvironment(job) {
  const name = environmentName(job);
  return name === undefined || (typeof name === "string" && !name.includes("${{"));
}

function containsAnyText(value, needles) {
  if (typeof value === "string") return needles.some((needle) => value.includes(needle));
  if (Array.isArray(value)) return value.some((candidate) => containsAnyText(candidate, needles));
  if (isRecord(value)) return Object.values(value).some((candidate) => containsAnyText(candidate, needles));
  return false;
}

// Ruby/Psych gives us the effective YAML document, including aliases and
// escaped keys. The AST walk rejects duplicate mapping keys before safe_load
// collapses them. GitHub's `on` parses as `true` under YAML 1.1, handled below.
const RUBY_YAML_TO_JSON = String.raw`
require "yaml"
require "json"
source = STDIN.read
tree = Psych.parse(source)
def validate_mapping_keys(node)
  return if node.nil? || !node.respond_to?(:children)
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

function parseWorkflow(source, label) {
  try {
    const output = execFileSync("ruby", ["-r", "yaml", "-r", "json", "-e", RUBY_YAML_TO_JSON], {
      input: source,
      encoding: "utf8",
      stdio: ["pipe", "pipe", "pipe"],
    });
    return record(JSON.parse(output), label);
  } catch (error) {
    const detail = error && typeof error === "object" && "stderr" in error ? String(error.stderr).trim() : "";
    fail(`${label} must be safe, duplicate-free effective YAML${detail ? `: ${detail}` : "."}`);
  }
}

function trigger(workflow, label) {
  return record(workflow.on ?? workflow.true, `${label} triggers`);
}

function dispatchInputs(workflow, label) {
  return record(record(trigger(workflow, label).workflow_dispatch, `${label} workflow_dispatch`), `${label} workflow_dispatch`).inputs
    ? record(record(trigger(workflow, label).workflow_dispatch, `${label} workflow_dispatch`).inputs, `${label} inputs`)
    : fail(`${label} workflow_dispatch must declare inputs.`);
}

function verifyDesktopWorkflow(workflow) {
  if (Object.hasOwn(workflow, "defaults")) fail("desktop release workflow-level defaults are forbidden.");
  assertNoSecrets(workflow.env, "desktop release root env");
  exactRecord(workflow.concurrency, DESKTOP_CONCURRENCY, "desktop release concurrency");
  exactRecord(workflow.permissions, { contents: "read" }, "desktop release root permissions");

  const desktopTrigger = trigger(workflow, "desktop release");
  exactRecord(record(desktopTrigger.push, "desktop release push trigger"), { tags: ["v*"] }, "desktop release push trigger");
  const inputs = dispatchInputs(workflow, "desktop release");
  exactRecord(inputs, {
    build_macos_direct: {
      description: "Build, sign, notarize, and upload the direct macOS DMG artifact",
      required: false,
      default: false,
      type: "boolean",
    },
    publish_to_store: {
      description: "Submit an update for the live Microsoft Store app",
      required: false,
      default: false,
      type: "boolean",
    },
    build_macos_app_store: {
      description: "Build and verify a signed Mac App Store package, retaining hash and log evidence only",
      required: false,
      default: false,
      type: "boolean",
    },
    upload_macos_to_app_store_connect: {
      description: "Build, validate, and upload only after exact-source screenshot approval",
      required: false,
      default: false,
      type: "boolean",
    },
  }, "desktop release workflow_dispatch inputs");

  const jobs = record(workflow.jobs, "desktop release jobs");
  if (!sameValue(Object.keys(jobs).sort(), DESKTOP_JOB_IDS)) {
    fail("desktop release must retain the reviewed job graph; a new job can otherwise bypass a protected release environment.");
  }
  for (const jobName of ["windows", "macos-direct", "macos-app-store"]) {
    const jobSteps = record(jobs[jobName], `${jobName} job`).steps;
    if (!Array.isArray(jobSteps)) fail(`${jobName} steps must be a sequence.`);
    const installs = jobSteps
      .map((candidate, index) => ({ candidate, index }))
      .filter(({ candidate }) => isRecord(candidate) && candidate.run === "npm ci");
    if (installs.length !== 1) {
      fail(`${jobName} must install frontend dependencies exactly once with npm ci.`);
    }
    const testStep = jobSteps[installs[0].index + 1];
    exactRecord(testStep, {
      name: "Test frontend safety policy",
      "working-directory": "desktop",
      run: "npm test",
    }, `${jobName} frontend safety-policy test gate`);
  }
  const macAppStoreSteps = exactRecordWithSteps(
    jobs["macos-app-store"],
    MACOS_APP_STORE_HEADER,
    "macos-app-store job",
  );
  if (macAppStoreSteps.some((candidate) =>
    isRecord(candidate) &&
    typeof candidate.uses === "string" &&
    /^actions\/upload-artifact@/.test(candidate.uses)
  )) {
    fail("macos-app-store must not retain its signed package as a GitHub Actions artifact in this public repository.");
  }
  exactNames(macAppStoreSteps, [
    "Check out repository",
    "Validate mutually exclusive Mac App Store mode",
    "Validate Mac App Store listing assets",
    "Require exact-source release-approved screenshot provenance before upload",
    "Set up Node.js",
    "Install Rust",
    "Cache Rust build",
    "Install frontend dependencies",
    "Test frontend safety policy",
    "Test Rust core",
    "Build unsigned universal Mac App Store app before signing material",
    "Validate protected Mac App Store configuration",
    "Import App Store certificates and provisioning profile",
    "Bundle signed sandboxed universal Mac App Store app",
    "Package and verify Mac App Store artifact",
    "Materialize App Store Connect API key immediately before upload",
    "Validate and upload Mac App Store package",
    "Remove App Store signing material",
  ], "macos-app-store steps");
  exactRecord(macAppStoreSteps[0], {
    name: "Check out repository",
    uses: CHECKOUT,
    with: { "fetch-depth": 0 },
  }, "macos-app-store checkout step");
  exactRecord(macAppStoreSteps[1], {
    name: "Validate mutually exclusive Mac App Store mode",
    shell: "bash",
    env: {
      HASH_LOG_ONLY: "${{ inputs.build_macos_app_store }}",
      UPLOAD_TO_APP_STORE_CONNECT: "${{ inputs.upload_macos_to_app_store_connect }}",
    },
    run: [
      "set -euo pipefail",
      "if [ \"$HASH_LOG_ONLY\" = \"true\" ] && [ \"$UPLOAD_TO_APP_STORE_CONNECT\" = \"true\" ]; then",
      "  echo \"::error::Select exactly one Mac App Store mode; hash/log-only and upload cannot both be true\"",
      "  exit 1",
      "fi",
      "",
    ].join("\n"),
  }, "macos-app-store mutually exclusive mode gate");
  exactRecord(macAppStoreSteps[2], {
    name: "Validate Mac App Store listing assets",
    run: "ruby .github/scripts/verify-store-assets.rb",
  }, "macos-app-store hash/log-only listing-assets gate");
  const screenshotUploadGate = macAppStoreSteps[3];
  exactRecord(screenshotUploadGate, {
    name: "Require exact-source release-approved screenshot provenance before upload",
    if: "github.event_name == 'workflow_dispatch' && inputs.upload_macos_to_app_store_connect",
    shell: "bash",
    run: [
      "set -euo pipefail",
      "baseline=\"$(node -p \"require('./desktop/AppStore/screenshot-provenance.json').capture.sourceBaselineCommit\")\"",
      "if [[ ! \"$baseline\" =~ ^[0-9a-f]{40}$ ]]; then",
      "  echo \"::error::Mac App Store screenshot provenance needs a full source baseline commit\"",
      "  exit 1",
      "fi",
      "node .github/scripts/verify-macos-app-store-screenshot-baseline.mjs \\",
      "  --baseline \"$baseline\" \\",
      "  --current \"$GITHUB_SHA\"",
      "ruby .github/scripts/verify-store-assets.rb \\",
      "  --require-macos-release-ready \\",
      "  --expected-source-commit=\"$baseline\"",
      "",
    ].join("\n"),
  }, "macos-app-store upload screenshot release gate");
  for (const safeStep of macAppStoreSteps.slice(0, 11)) {
    assertNoSecrets(safeStep, `macos-app-store pre-credential step ${safeStep.name}`);
  }
  const unsignedAppStoreBuild = step(
    macAppStoreSteps,
    "Build unsigned universal Mac App Store app before signing material",
    "macos-app-store unsigned build step",
  );
  requireText(unsignedAppStoreBuild.run, [
    "npm run tauri -- build --no-bundle --no-sign",
    "--target ${{ env.RUST_TARGET }} --features macos-app-store",
    "--config src-tauri/tauri.macos-app-store.conf.json",
  ], "macos-app-store unsigned build step.run");
  const validateAppStoreConfiguration = step(
    macAppStoreSteps,
    "Validate protected Mac App Store configuration",
    "macos-app-store protected configuration step",
  );
  requireText(validateAppStoreConfiguration.run, [
    'case "$INSTALLER_IDENTITY" in',
    "'Mac Installer Distribution: '*' (5TT564H883)'|'3rd Party Mac Developer Installer: '*' (5TT564H883)'",
    "Mac App Store packaging requires an exact Installer Distribution identity for team 5TT564H883",
  ], "macos-app-store protected configuration step.run");
  const packageAppStoreArtifact = step(
    macAppStoreSteps,
    "Package and verify Mac App Store artifact",
    "macos-app-store signed artifact verification step",
  );
  requireText(packageAppStoreArtifact.run, [
    `expected_short_version="${MACOS_APP_STORE_VERSION}"`,
    `expected_bundle_version="${MACOS_APP_STORE_VERSION}"`,
    'expected_team="5TT564H883"',
    `expected_bundle_identifier="${MACOS_APP_STORE_BUNDLE_IDENTIFIER}"`,
    "assert_plist_value \"$app/Contents/Info.plist\" \"CFBundleIdentifier\" \"$expected_bundle_identifier\"",
    "assert_plist_value \"$app/Contents/Info.plist\" \"CFBundleShortVersionString\" \"$expected_short_version\"",
    "assert_plist_value \"$app/Contents/Info.plist\" \"CFBundleVersion\" \"$expected_bundle_version\"",
    "echo 'MACOS_APP_STORE_PACKAGE_VERIFIED=false' >> \"$GITHUB_ENV\"",
    "xcrun productbuild --sign \"$MACOS_APP_STORE_INSTALLER_IDENTITY\"",
    'case "$MACOS_APP_STORE_INSTALLER_IDENTITY" in',
    'pkgutil --check-signature "$package" > "$signature_listing" 2>&1',
    '"Status: signed by a certificate trusted by macOS"',
    'leaf_identities != [expected_identity]',
    'package_sha256="$(/usr/bin/shasum -a 256 "$package")"',
    'echo "MACOS_APP_STORE_PACKAGE_SHA256=$package_sha256" >> "$GITHUB_ENV"',
    "echo 'MACOS_APP_STORE_PACKAGE_VERIFIED=true' >> \"$GITHUB_ENV\"",
  ], "macos-app-store signed artifact version/build verification step.run");
  const materializeAppStoreKey = step(
    macAppStoreSteps,
    "Materialize App Store Connect API key immediately before upload",
    "macos-app-store upload key step",
  );
  exactRecord(materializeAppStoreKey.env, {
    APP_STORE_CONNECT_KEY: "${{ secrets.MACOS_APP_STORE_CONNECT_API_KEY }}",
    APP_STORE_CONNECT_KEY_ID: "${{ vars.MACOS_APP_STORE_CONNECT_API_KEY_ID }}",
    APP_STORE_CONNECT_ISSUER: "${{ vars.MACOS_APP_STORE_CONNECT_API_ISSUER }}",
  }, "macos-app-store upload key step.env");
  if (materializeAppStoreKey.if !== "github.event_name == 'workflow_dispatch' && inputs.upload_macos_to_app_store_connect") {
    fail("macos-app-store upload key step must remain conditional on explicit upload consent.");
  }
  const uploadAppStorePackage = step(
    macAppStoreSteps,
    "Validate and upload Mac App Store package",
    "macos-app-store upload step",
  );
  if (uploadAppStorePackage.if !== "github.event_name == 'workflow_dispatch' && inputs.upload_macos_to_app_store_connect") {
    fail("macos-app-store upload step must remain conditional on explicit upload consent.");
  }
  exactRecord(uploadAppStorePackage.env, {
    MACOS_APP_STORE_ALTOOL_PLATFORM,
    MACOS_APP_STORE_APPLE_ID,
    MACOS_APP_STORE_BUNDLE_IDENTIFIER,
    MACOS_APP_STORE_SHORT_VERSION: MACOS_APP_STORE_VERSION,
    MACOS_APP_STORE_BUNDLE_VERSION: MACOS_APP_STORE_VERSION,
    APP_STORE_CONNECT_KEY_ID: "${{ vars.MACOS_APP_STORE_CONNECT_API_KEY_ID }}",
    APP_STORE_CONNECT_ISSUER: "${{ vars.MACOS_APP_STORE_CONNECT_API_ISSUER }}",
  }, "macos-app-store upload step.env");
  requireText(uploadAppStorePackage.run, [
    'if [ "${MACOS_APP_STORE_PACKAGE_VERIFIED:-false}" != true ]; then',
    'upload_sha256="$(/usr/bin/shasum -a 256 "${MACOS_APP_STORE_PACKAGE:?Mac App Store package path is missing}")"',
    'if [ "$upload_sha256" != "${MACOS_APP_STORE_PACKAGE_SHA256:?Verified Mac App Store package SHA-256 is missing}" ]; then',
    '--platform "$MACOS_APP_STORE_ALTOOL_PLATFORM"',
    '--apple-id "$MACOS_APP_STORE_APPLE_ID"',
    '--bundle-id "$MACOS_APP_STORE_BUNDLE_IDENTIFIER"',
    '--bundle-version "$MACOS_APP_STORE_BUNDLE_VERSION"',
    '--bundle-short-version-string "$MACOS_APP_STORE_SHORT_VERSION"',
    '--api-key "$APP_STORE_CONNECT_KEY_ID"',
    '--api-issuer "$APP_STORE_CONNECT_ISSUER"',
    '--output-format json',
    'xcrun altool --validate-app "$MACOS_APP_STORE_PACKAGE" "${upload_arguments[@]}"',
    'xcrun altool --upload-package "$MACOS_APP_STORE_PACKAGE" "${upload_arguments[@]}"',
  ], "macos-app-store upload step.run");
  const cleanupAppStoreSecrets = step(
    macAppStoreSteps,
    "Remove App Store signing material",
    "macos-app-store cleanup step",
  );
  if (cleanupAppStoreSecrets.if !== "always()") {
    fail("macos-app-store cleanup step must run with if: always().");
  }
  requireText(cleanupAppStoreSecrets.run, [
    'rm -f "$RUNNER_TEMP/quakesignal-macos-app-store-package-signature.txt"',
    "rm -f artifacts/macos-app-store/*.pkg",
  ], "macos-app-store cleanup step.run");
  if (fingerprint(macAppStoreSteps) !== MACOS_APP_STORE_STEPS_FINGERPRINT) {
    fail("macos-app-store steps must match the reviewed provenance, safe-build, signing, artifact verification, upload-consent, and cleanup sequence.");
  }
  const directCredentialMarkers = ["MACOS_DEVELOPER_ID_", "MACOS_NOTARY_"];
  for (const [jobName, job] of Object.entries(jobs)) {
    if (jobName === "macos-direct") continue;
    if (!isStaticEnvironment(job)) {
      fail(`non-direct release job ${jobName} must not select a dynamic environment.`);
    }
    if (environmentName(job) === "macos-direct-release") {
      fail(`only macos-direct may request the macos-direct-release environment (found ${jobName}).`);
    }
    if (containsAnyText(job, directCredentialMarkers)) {
      fail(`only macos-direct may reference Developer ID or notarization credentials (found ${jobName}).`);
    }
  }
  const provenanceSteps = exactRecordWithSteps(
    jobs["verify-release-provenance"], PROVENANCE_HEADER, "verify-release-provenance job",
  );
  exactNames(provenanceSteps, [
    "Check out tagged source and protected main history",
    "Verify tag target is contained in protected main",
  ], "verify-release-provenance steps");
  exactRecord(provenanceSteps[0], {
    name: "Check out tagged source and protected main history",
    uses: CHECKOUT,
    with: { "fetch-depth": 0 },
  }, "protected-tag checkout step");
  exactRecord(provenanceSteps[1], {
    name: "Verify tag target is contained in protected main",
    shell: "bash",
    run: PROVENANCE_COMMAND,
  }, "protected-main ancestry step");

  const directSteps = exactRecordWithSteps(jobs["macos-direct"], MACOS_DIRECT_HEADER, "macos-direct job");
  const directNames = [
    "Check out repository",
    "Set up Node.js",
    "Install Rust",
    "Cache Rust build",
    "Install frontend dependencies",
    "Test frontend safety policy",
    "Test Rust core",
    "Build unsigned universal macOS app before release credentials",
    "Verify protected tag matches app version",
    "Validate protected direct-release configuration",
    "Materialize notarization API key",
    "Sign, notarize, and staple built universal macOS DMG",
    "Verify and collect notarized direct-release artifact",
    "Upload notarized macOS direct-release artifact",
    "Remove notarization API key",
  ];
  exactNames(directSteps, directNames, "macos-direct steps");
  for (const safeStep of directSteps.slice(0, 9)) assertNoSecrets(safeStep, `macos-direct pre-credential step ${safeStep.name}`);
  exactRecord(directSteps[0], { name: "Check out repository", uses: CHECKOUT }, "macos-direct checkout step");
  requireText(directSteps[7].run, [
    "npm run tauri -- build --no-bundle --no-sign",
    "--target ${{ env.RUST_TARGET }}",
  ], "unsigned universal build step.run");

  const validateConfiguration = step(directSteps, "Validate protected direct-release configuration", "direct credential validation step");
  exactRecord(validateConfiguration.env, {
    DEVELOPER_ID_CERTIFICATE: "${{ secrets.MACOS_DEVELOPER_ID_CERTIFICATE }}",
    DEVELOPER_ID_CERTIFICATE_PASSWORD: "${{ secrets.MACOS_DEVELOPER_ID_CERTIFICATE_PASSWORD }}",
    DEVELOPER_ID_SIGNING_IDENTITY: "${{ vars.MACOS_DEVELOPER_ID_SIGNING_IDENTITY }}",
    NOTARY_API_KEY: "${{ secrets.MACOS_NOTARY_API_KEY }}",
    NOTARY_API_KEY_ID: "${{ secrets.MACOS_NOTARY_API_KEY_ID }}",
    NOTARY_API_ISSUER: "${{ secrets.MACOS_NOTARY_API_ISSUER }}",
  }, "direct credential validation env");
  requireText(validateConfiguration.run, ["required=(", "DEVELOPER_ID_CERTIFICATE", "NOTARY_API_ISSUER"], "direct credential validation step.run");

  const materializeNotaryKey = step(directSteps, "Materialize notarization API key", "notarization key step");
  exactRecord(materializeNotaryKey.env, {
    NOTARY_API_KEY: "${{ secrets.MACOS_NOTARY_API_KEY }}",
    NOTARY_API_KEY_ID: "${{ secrets.MACOS_NOTARY_API_KEY_ID }}",
  }, "notarization key step.env");
  requireText(materializeNotaryKey.run, ["AuthKey_${NOTARY_API_KEY_ID}.p8", "chmod 600", "APPLE_API_KEY_PATH=$key_path"], "notarization key step.run");

  const signAndNotarize = step(directSteps, "Sign, notarize, and staple built universal macOS DMG", "sign/notarize step");
  exactRecord(signAndNotarize.env, {
    APPLE_CERTIFICATE: "${{ secrets.MACOS_DEVELOPER_ID_CERTIFICATE }}",
    APPLE_CERTIFICATE_PASSWORD: "${{ secrets.MACOS_DEVELOPER_ID_CERTIFICATE_PASSWORD }}",
    APPLE_SIGNING_IDENTITY: "${{ vars.MACOS_DEVELOPER_ID_SIGNING_IDENTITY }}",
    APPLE_API_KEY: "${{ secrets.MACOS_NOTARY_API_KEY_ID }}",
    APPLE_API_ISSUER: "${{ secrets.MACOS_NOTARY_API_ISSUER }}",
  }, "sign/notarize step.env");
  requireText(signAndNotarize.run, ["npm run tauri -- bundle", "--target ${{ env.RUST_TARGET }}", "--bundles app,dmg"], "sign/notarize step.run");

  const verifyArtifact = step(directSteps, "Verify and collect notarized direct-release artifact", "direct artifact verification step");
  requireText(verifyArtifact.run, [
    "codesign --verify --deep --strict --verbose=2 \"$app\"",
    "Authority=Developer ID Application",
    "for architecture in arm64 x86_64; do",
    "verify_universal_app \"$app\"",
    "xcrun stapler validate \"$app\"",
    "xcrun stapler validate \"$dmg\"",
    "hdiutil attach \"$dmg\"",
    "verify_universal_app \"$mounted_app\"",
    "xcrun stapler validate \"$mounted_app\"",
    "spctl --assess --type execute --verbose=4 \"$mounted_app\"",
    "cp \"$dmg\" dist/",
  ], "direct artifact verification step.run");
  exactRecord(step(directSteps, "Upload notarized macOS direct-release artifact", "direct artifact upload step"), {
    name: "Upload notarized macOS direct-release artifact",
    uses: UPLOAD_ARTIFACT,
    with: { name: "release-macos-direct", path: "dist/*.dmg", "if-no-files-found": "error" },
  }, "direct artifact upload step");
  const cleanup = step(directSteps, "Remove notarization API key", "notarization cleanup step");
  if (cleanup.if !== "always()") fail("notarization cleanup must run with if: always().");
  requireText(cleanup.run, ["rm -f \"$RUNNER_TEMP/quakesignal-notary/AuthKey_${NOTARY_API_KEY_ID}.p8\""], "notarization cleanup step.run");
  if (fingerprint(directSteps) !== MACOS_DIRECT_STEPS_FINGERPRINT) {
    fail("macos-direct steps must match the reviewed safe-build, signing, notarization, verification, upload, and cleanup sequence.");
  }

  const releaseSteps = exactRecordWithSteps(jobs.release, RELEASE_HEADER, "release job");
  exactNames(releaseSteps, [
    "Check out repository",
    "Download notarized macOS direct-release artifact",
    "Generate SHA256 checksums",
    "Compose release notes",
    "Publish GitHub Release",
  ], "release steps");
  exactRecord(releaseSteps[1], {
    name: "Download notarized macOS direct-release artifact",
    uses: DOWNLOAD_ARTIFACT,
    with: { name: "release-macos-direct", path: "dist" },
  }, "direct release artifact download step");
  exactRecord(releaseSteps[2], {
    name: "Generate SHA256 checksums",
    "working-directory": "dist",
    run: "set -euo pipefail\nsha256sum -- * > SHA256SUMS.txt\n",
  }, "SHA256 publication step");
  requireText(releaseSteps[4].run, [
    "gh release create \"$tag\" dist/*",
    "gh release upload \"$tag\" dist/* --clobber",
  ], "GitHub Release publication step.run");
  if (fingerprint(releaseSteps) !== RELEASE_STEPS_FINGERPRINT) {
    fail("release steps must match the reviewed SHA256 and artifact publication sequence.");
  }

  return {
    directStepsFingerprint: fingerprint(directSteps),
    macAppStoreStepsFingerprint: fingerprint(macAppStoreSteps),
    releaseStepsFingerprint: fingerprint(releaseSteps),
  };
}

function verifyHomebrewWorkflow(workflow) {
  if (Object.hasOwn(workflow, "defaults")) fail("Homebrew workflow-level defaults are forbidden.");
  const homebrewTrigger = trigger(workflow, "Homebrew");
  if (!sameValue(Object.keys(homebrewTrigger).sort(), ["workflow_dispatch"])) {
    fail("Homebrew must be manual-only through workflow_dispatch.");
  }
  const inputs = dispatchInputs(workflow, "Homebrew");
  exactRecord(record(inputs.version, "Homebrew version input"), {
    description: "Numeric release version already published as v<version> (for example 1.0.1)",
    required: true,
    type: "string",
  }, "Homebrew version input");
  exactRecord(record(inputs.publish_to_tap, "Homebrew publish_to_tap input"), {
    description: "After every artifact/cask check passes, commit and push the cask to TastyHeadphones/homebrew-tap",
    required: false,
    default: false,
    type: "boolean",
  }, "Homebrew publish_to_tap input");
  exactRecord(workflow.concurrency, HOMEBREW_CONCURRENCY, "Homebrew concurrency");
  exactRecord(workflow.permissions, { actions: "read", contents: "read" }, "Homebrew permissions");
  exactRecord(workflow.env, HOMEBREW_ENV, "Homebrew env");

  const jobs = record(workflow.jobs, "Homebrew jobs");
  if (!sameValue(Object.keys(jobs).sort(), ["publish"])) fail("Homebrew must expose only its protected publish job.");
  const steps = exactRecordWithSteps(jobs.publish, HOMEBREW_PUBLISH_HEADER, "Homebrew publish job");
  exactNames(steps, [
    "Check out protected release source",
    "Verify the requested direct-release provenance",
    "Download and validate the notarized DMG and checksum",
    "Verify the public tap exists",
    "Render and validate the cask in a temporary tap checkout",
    "Push validated cask to the public tap",
  ], "Homebrew publish steps");
  for (const safeStep of steps.slice(0, -1)) assertNoSecrets(safeStep, `Homebrew pre-push step ${safeStep.name}`);
  exactRecord(steps[0], { name: "Check out protected release source", uses: CHECKOUT }, "Homebrew checkout step");

  const provenance = steps[1];
  requireText(provenance.run, [
    "gh release view \"$tag\" --repo \"$UPSTREAM_REPOSITORY\"",
    "--json tagName,isDraft,isPrerelease,assets",
    "QuakeSignal_\" + ($tag | ltrimstr(\"v\")) + \"_universal.dmg",
    "SHA256SUMS.txt",
    "git ls-remote --tags \"https://github.com/$UPSTREAM_REPOSITORY.git\"",
    "git fetch --no-tags --depth=1 origin",
    "git show \"$tag:desktop/src-tauri/tauri.conf.json\"",
    "gh run list --repo \"$UPSTREAM_REPOSITORY\" --workflow desktop-release.yml",
    "--commit \"$tag_commit\" --event push",
    "Verify protected tag provenance",
    "macOS direct/Homebrew universal",
    "Publish release",
    ".head_sha == $commit",
  ], "Homebrew release provenance step.run");

  const checksum = steps[2];
  requireText(checksum.run, [
    "--pattern \"$DMG_NAME\" --pattern SHA256SUMS.txt",
    "expected_sha=",
    "actual_sha=\"$(shasum -a 256 \"$dmg\"",
    "Downloaded DMG does not match SHA256SUMS.txt",
    "xcrun stapler validate \"$dmg\"",
    "Authority=Developer ID Application",
    "for architecture in arm64 x86_64; do",
    "spctl --assess --type execute --verbose=4 \"$app\"",
    "DMG_SHA256=$actual_sha",
  ], "Homebrew checksum and notarization step.run");

  const render = steps[4];
  requireText(render.run, [
    "git clone --depth 1 --branch main --single-branch",
    "ruby .github/scripts/render-homebrew-cask.rb",
    "\"$VERSION\" \"$DMG_SHA256\"",
    "brew audit",
    "TAP_DIRECTORY=$tap_dir",
  ], "Homebrew cask rendering step.run");
  const push = steps.at(-1);
  exactRecord(push.env, { GH_TOKEN: "${{ secrets.HOMEBREW_TAP_TOKEN }}" }, "Homebrew final push env");
  if (push.if !== "env.TAP_HAS_CHANGES == 'true'") fail("Homebrew token push must run only when the validated cask changed.");
  requireText(push.run, ["test -n \"$GH_TOKEN\"", "gh auth setup-git", "git -C \"$TAP_DIRECTORY\" push origin HEAD:main"], "Homebrew final push step.run");
  const tokenUses = secretReferences(workflow).filter((value) => value.includes("HOMEBREW_TAP_TOKEN"));
  if (tokenUses.length !== 1) fail("HOMEBREW_TAP_TOKEN must be referenced exactly once, in the final push step.");
  if (fingerprint(steps) !== HOMEBREW_PUBLISH_STEPS_FINGERPRINT) {
    fail("Homebrew publish steps must match the reviewed provenance, checksum, cask validation, and final-token-push sequence.");
  }
  return { homebrewStepsFingerprint: fingerprint(steps) };
}

/** Verify offline workflow contracts for the direct macOS and Homebrew lanes. */
export async function verifyDesktopReleaseContract({ root = repositoryRoot } = {}) {
  const [desktopSource, desktopConfigSource, desktopRuntimeSource, homebrewSource] = await Promise.all([
    readFile(resolve(root, files.desktop), "utf8"),
    readFile(resolve(root, files.desktopConfig), "utf8"),
    readFile(resolve(root, files.desktopRuntime), "utf8"),
    readFile(resolve(root, files.homebrew), "utf8"),
  ]);
  let desktopConfig;
  try {
    desktopConfig = JSON.parse(desktopConfigSource);
  } catch {
    fail("desktop/src-tauri/tauri.conf.json must be valid JSON.");
  }
  if (desktopConfig.version !== MACOS_APP_STORE_VERSION) {
    fail(`desktop/src-tauri/tauri.conf.json version must be exactly ${MACOS_APP_STORE_VERSION} for this reviewed release.`);
  }
  if (desktopConfig.identifier !== MACOS_APP_STORE_BUNDLE_IDENTIFIER) {
    fail(`desktop/src-tauri/tauri.conf.json identifier must be exactly ${MACOS_APP_STORE_BUNDLE_IDENTIFIER}.`);
  }
  const stdoutOnlyLogger = /tauri_plugin_log::Builder::new\(\)\s*\.targets\(\[tauri_plugin_log::Target::new\(\s*tauri_plugin_log::TargetKind::Stdout,?\s*\)\]\)\s*\.build\(\)/m;
  if (!stdoutOnlyLogger.test(desktopRuntimeSource)) {
    fail("desktop runtime must configure the Tauri logger with the reviewed stdout-only target.");
  }
  const loggerBuilders = desktopRuntimeSource.match(/tauri_plugin_log::Builder::new\s*\(/g) ?? [];
  const loggerTargets = desktopRuntimeSource.match(/tauri_plugin_log::Target::new\s*\(/g) ?? [];
  if (loggerBuilders.length !== 1 || loggerTargets.length !== 1 || /\buse\s+tauri_plugin_log\b/.test(desktopRuntimeSource)) {
    fail("desktop runtime must contain exactly one fully qualified Tauri logger and one reviewed target.");
  }
  if (/TargetKind::(?:LogDir|Folder|Webview)|tauri_plugin_log::Builder::new\(\)\s*\.build\(\)/.test(desktopRuntimeSource)) {
    fail("desktop runtime must not enable a persistent or implicit Tauri log target.");
  }
  return {
    ...verifyDesktopWorkflow(parseWorkflow(desktopSource, "desktop release workflow")),
    ...verifyHomebrewWorkflow(parseWorkflow(homebrewSource, "Homebrew workflow")),
  };
}

async function main() {
  try {
    const verified = await verifyDesktopReleaseContract();
    console.log(`Verified desktop/Homebrew release contract (direct ${verified.directStepsFingerprint}, Mac App Store ${verified.macAppStoreStepsFingerprint}, Homebrew ${verified.homebrewStepsFingerprint}).`);
  } catch (error) {
    console.error(`::error::${error instanceof Error ? error.message : "desktop release contract verification failed."}`);
    process.exitCode = 1;
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) await main();
