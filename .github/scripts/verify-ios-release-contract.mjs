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
  infoPlists: [
    "ios/QuakeSignal/Supporting/Info.plist",
    "ios/QuakeSignalTV/Supporting/Info.plist",
    "ios/QuakeSignalVision/Supporting/Info.plist",
    "ios/QuakeSignalWatch/Supporting/Info.plist",
  ],
  workerConfig: "backend/cloudflare/wrangler.jsonc",
  iosWorkflow: ".github/workflows/ios.yml",
  platformWorkflow: ".github/workflows/apple-platforms.yml",
  screenshotWorkflow: ".github/workflows/apple-platform-screenshots.yml",
  cloudflareWorkflow: ".github/workflows/cloudflare.yml",
};

const APPROVED_WORKER_ORIGIN = "https://quakesignal-api.hopeso.workers.dev";
const REVIEWED_APP_ATTEST_APNS_ROUTES = [
  {
    appIdentity: "5TT564H883.com.quakesignal.app",
    apnsTopic: "com.quakesignal.app",
    platform: "ios",
  },
];
const APPLE_APP_PLATFORMS = new Set([
  "ios",
  "ipados",
  "macos",
  "watchos",
  "tvos",
  "visionos",
]);
const MAX_APP_IDENTITY_ROUTES = 16;
const MAX_APP_IDENTITY_ROUTE_CONFIGURATION_LENGTH = 8 * 1024;
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
const PLATFORM_ROOT_ENV = {
  XCODE_PROJECT: "ios/QuakeSignal.xcodeproj",
  XCODEGEN_VERSION: "2.46.0",
  XCODEGEN_SHA256: "4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806",
};
const PLATFORM_ROOT_CONCURRENCY = {
  group: "apple-platforms-${{ github.workflow }}-${{ github.ref }}-${{ inputs.platform }}",
  "cancel-in-progress": false,
};
const SCREENSHOT_ROOT_CONCURRENCY = {
  group: "apple-platform-screenshot-candidates-${{ github.ref }}",
  "cancel-in-progress": true,
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
  name: "Archive iOS with embedded Watch and optionally upload to TestFlight",
  needs: ["test", "generic-platform-builds"],
  if: "github.event_name == 'workflow_dispatch' && (inputs.archive_only || inputs.upload_to_testflight) && github.ref == 'refs/heads/main' && github.ref_protected",
  "runs-on": "macos-latest",
  environment: { name: "ios-app-store-release" },
  concurrency: SHARED_PRODUCTION_POLICY_CONCURRENCY,
};
const GENERIC_BUILD_MATRIX = {
  include: [
    { name: "iOS/iPadOS", key: "ios", scheme: "QuakeSignal", destination: "generic/platform=iOS" },
    { name: "tvOS", key: "tvos", scheme: "QuakeSignalTV", destination: "generic/platform=tvOS" },
    { name: "visionOS", key: "visionos", scheme: "QuakeSignalVision", destination: "generic/platform=visionOS" },
    { name: "watchOS", key: "watchos", scheme: "QuakeSignalWatch", destination: "generic/platform=watchOS" },
  ],
};
const GENERIC_BUILD_JOB_HEADER = {
  name: "Unsigned Release (${{ matrix.name }})",
  "runs-on": "macos-latest",
  strategy: {
    "fail-fast": false,
    matrix: GENERIC_BUILD_MATRIX,
  },
};
const PLATFORM_RELEASE_MATRIX = {
  include: [
    {
      key: "${{ inputs.platform }}",
      name: "${{ inputs.platform == 'tvos' && 'tvOS' || 'visionOS' }}",
      scheme: "${{ inputs.platform == 'tvos' && 'QuakeSignalTV' || 'QuakeSignalVision' }}",
      destination: "${{ inputs.platform == 'tvos' && 'generic/platform=tvOS' || 'generic/platform=visionOS' }}",
      bundle_identifier: "com.quakesignal.app",
      profile_secret: "${{ inputs.platform == 'tvos' && 'TVOS_APP_STORE_PROVISIONING_PROFILE' || 'VISIONOS_APP_STORE_PROVISIONING_PROFILE' }}",
      profile_variable: "${{ inputs.platform == 'tvos' && 'TVOS_APP_STORE_PROFILE_NAME' || 'VISIONOS_APP_STORE_PROFILE_NAME' }}",
      profile_platform: "${{ inputs.platform == 'tvos' && 'tvOS' || 'visionOS' }}",
      requires_alert_entitlements: "${{ inputs.platform == 'visionos' && 'true' || 'false' }}",
    },
  ],
};
const PLATFORM_RELEASE_JOB_HEADER = {
  name: "Archive ${{ matrix.name }} and optionally upload to TestFlight",
  if: "github.event_name == 'workflow_dispatch' && (inputs.archive_only || inputs.upload_to_testflight) && github.ref == 'refs/heads/main' && github.ref_protected",
  "runs-on": "macos-latest",
  environment: { name: "ios-app-store-release" },
  concurrency: SHARED_PRODUCTION_POLICY_CONCURRENCY,
  strategy: {
    "fail-fast": false,
    matrix: PLATFORM_RELEASE_MATRIX,
  },
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
const TESTFLIGHT_POST_SMOKE_SEQUENCE_FINGERPRINT = "sha256:xM030AZh5xMVT6_k67kP87iiOa-QkUvi5Gn0_0gaTPU";
const WORKFLOW_JOBS_FINGERPRINT = "sha256:GFimuJ4Csf-1zDTLellUSizy0YmbN4o8bIFRFolQNHc";
const PLATFORM_POST_SMOKE_SEQUENCE_FINGERPRINT = "sha256:9zTH6eFLeuD9DBkjY5u6xQCKlM0R8iq41uNxhG7Jdhc";
const PLATFORM_WORKFLOW_JOBS_FINGERPRINT = "sha256:emUFxjkPtvbXsmvC8IJvc8SbQdyQvypmE-MV3PDzynw";
const SCREENSHOT_WORKFLOW_JOBS_FINGERPRINT = "sha256:KqK_JYFbg7zm-IgdGk2ZW2HBJ0mdkgZUxIQUXI_Jwnk";
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
  "QUAKESIGNAL_IOS_PROFILE_NAME=\"$IOS_PROFILE_NAME\"",
  "QUAKESIGNAL_WATCH_PROFILE_NAME=\"$WATCH_PROFILE_NAME\"",
  "CURRENT_PROJECT_VERSION=\"$BUILD_NUMBER\"",
  "QUAKESIGNAL_API_BASE_URL=\"$IOS_RELEASE_API_BASE_URL\"",
].join(" ");
const PLATFORM_ARCHIVE_COMMAND = [
  "xcodebuild archive",
  "-project \"$XCODE_PROJECT\"",
  "-scheme \"$PLATFORM_SCHEME\"",
  "-configuration Release",
  "-destination \"$PLATFORM_DESTINATION\"",
  "-archivePath \"$RUNNER_TEMP/QuakeSignal-$PLATFORM_KEY.xcarchive\"",
  "DEVELOPMENT_TEAM=5TT564H883",
  "CODE_SIGN_STYLE=Manual",
  "CODE_SIGN_IDENTITY='Apple Distribution'",
  "QUAKESIGNAL_TV_PROFILE_NAME=\"$PLATFORM_PROFILE_NAME\"",
  "QUAKESIGNAL_VISION_PROFILE_NAME=\"$PLATFORM_PROFILE_NAME\"",
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

function verifyAppleProject(projectSource) {
  const project = parseEffectiveYAML(projectSource, "XcodeGen project", "ios/project.yml");
  const projectSettings = record(record(project.settings, "XcodeGen project settings").base, "XcodeGen project base settings");
  if (String(projectSettings.MARKETING_VERSION) !== "1.1") {
    fail("ios/project.yml MARKETING_VERSION must be exactly 1.1 for this coordinated release.");
  }
  if (Object.hasOwn(projectSettings, "TARGETED_DEVICE_FAMILY")) {
    fail("TARGETED_DEVICE_FAMILY must be target-scoped for the native Apple platform matrix.");
  }

  const deploymentTargets = record(record(project.options, "XcodeGen project options").deploymentTarget, "XcodeGen deployment targets");
  const expectedDeploymentTargets = { iOS: "17.0", tvOS: "17.0", watchOS: "10.0", visionOS: "1.0" };
  for (const [platform, version] of Object.entries(expectedDeploymentTargets)) {
    if (String(deploymentTargets[platform]) !== version) {
      fail(`ios/project.yml ${platform} deployment target must be ${version}.`);
    }
  }

  const targets = record(project.targets, "XcodeGen targets");
  const expectedTargets = {
    QuakeSignal: {
      platform: "iOS",
      type: "application",
      bundleIdentifier: "com.quakesignal.app",
      family: "1,2",
      profileVariable: "$(QUAKESIGNAL_IOS_PROFILE_NAME)",
      entitlements: "QuakeSignal/Supporting/QuakeSignal-Release.entitlements",
    },
    QuakeSignalTV: {
      platform: "tvOS",
      type: "application",
      bundleIdentifier: "com.quakesignal.app",
      family: "3",
      profileVariable: "$(QUAKESIGNAL_TV_PROFILE_NAME)",
    },
    QuakeSignalVision: {
      platform: "visionOS",
      type: "application",
      bundleIdentifier: "com.quakesignal.app",
      family: "7",
      profileVariable: "$(QUAKESIGNAL_VISION_PROFILE_NAME)",
      entitlements: "QuakeSignalVision/Supporting/QuakeSignalVision-Release.entitlements",
    },
    QuakeSignalWatch: {
      platform: "watchOS",
      type: "application",
      bundleIdentifier: "com.quakesignal.app.watchkitapp",
      family: "4",
      profileVariable: "$(QUAKESIGNAL_WATCH_PROFILE_NAME)",
    },
  };
  for (const [name, expected] of Object.entries(expectedTargets)) {
    const target = record(targets[name], `XcodeGen ${name} target`);
    if (target.platform !== expected.platform || target.type !== expected.type) {
      fail(`${name} must remain a native ${expected.platform} ${expected.type} target.`);
    }
    const settings = record(target.settings, `${name} settings`);
    const base = record(settings.base, `${name} base settings`);
    const release = record(record(settings.configs, `${name} config settings`).Release, `${name} Release settings`);
    if (base.PRODUCT_BUNDLE_IDENTIFIER !== expected.bundleIdentifier) {
      fail(`${name} PRODUCT_BUNDLE_IDENTIFIER must be ${expected.bundleIdentifier}.`);
    }
    if (String(base.TARGETED_DEVICE_FAMILY) !== expected.family) {
      fail(`${name} TARGETED_DEVICE_FAMILY must be ${expected.family}.`);
    }
    if (release.PROVISIONING_PROFILE_SPECIFIER !== expected.profileVariable) {
      fail(`${name} Release must use target-scoped ${expected.profileVariable} provisioning.`);
    }
    if (expected.entitlements) {
      if (release.CODE_SIGN_ENTITLEMENTS !== expected.entitlements) {
        fail(`${name} Release entitlements must be ${expected.entitlements}.`);
      }
    } else if (Object.hasOwn(release, "CODE_SIGN_ENTITLEMENTS")) {
      fail(`${name} is foreground-only and must not acquire release alert entitlements implicitly.`);
    }
  }

  const iosDependencies = targets.QuakeSignal.dependencies;
  if (!Array.isArray(iosDependencies)) fail("QuakeSignal dependencies must embed the Watch app.");
  const watchDependency = exactlyOne(
    iosDependencies.filter((dependency) => isRecord(dependency) && dependency.target === "QuakeSignalWatch"),
    "QuakeSignal embedded Watch dependency",
  );
  exactRecord(watchDependency, {
    target: "QuakeSignalWatch",
    embed: true,
    platformFilter: "iOS",
  }, "QuakeSignal embedded Watch dependency");

  const schemes = record(project.schemes, "XcodeGen schemes");
  for (const name of Object.keys(expectedTargets)) {
    const scheme = record(schemes[name], `XcodeGen ${name} scheme`);
    if (record(scheme.archive, `${name} archive action`).config !== "Release") {
      fail(`${name} archive action must use Release.`);
    }
  }
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

function verifyInfoPlist(infoPlist, label) {
  exactlyOne([...infoPlist.matchAll(/<key>\s*CFBundleVersion\s*<\/key>/g)], `${label} CFBundleVersion`);
  exactlyOne(
    [...infoPlist.matchAll(/<key>\s*CFBundleVersion\s*<\/key>\s*<string>\s*\$\(CURRENT_PROJECT_VERSION\)\s*<\/string>/g)],
    `${label} CFBundleVersion interpolation`,
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
    "APP_ATTEST_APNS_ROUTES",
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

function isAppleBundleIdentifier(value) {
  return typeof value === "string" && value.length > 0 && value.length <= 255 &&
    /^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*$/.test(value);
}

function normalizedWorkerAppIdentityRoutes(vars) {
  const configured = vars.APP_ATTEST_APNS_ROUTES;
  if (
    typeof configured !== "string" ||
    configured.length === 0 ||
    configured.length > MAX_APP_IDENTITY_ROUTE_CONFIGURATION_LENGTH
  ) {
    fail("wrangler APP_ATTEST_APNS_ROUTES must be a nonempty JSON string within the reviewed size limit.");
  }
  let decoded;
  try {
    decoded = JSON.parse(configured);
  } catch {
    fail("wrangler APP_ATTEST_APNS_ROUTES must be valid JSON.");
  }
  if (!Array.isArray(decoded) || decoded.length === 0 || decoded.length > MAX_APP_IDENTITY_ROUTES) {
    fail("wrangler APP_ATTEST_APNS_ROUTES must be a nonempty route array within the reviewed count limit.");
  }
  const routes = decoded.map((route, index) => {
    if (!isRecord(route) || !sameValue(Object.keys(route).sort(), ["apnsTopic", "appIdentity", "platform"])) {
      fail(`wrangler APP_ATTEST_APNS_ROUTES entry ${index} must contain exactly appIdentity, apnsTopic, and platform.`);
    }
    const { appIdentity, apnsTopic, platform } = route;
    if (
      typeof appIdentity !== "string" ||
      typeof apnsTopic !== "string" ||
      typeof platform !== "string" ||
      !APPLE_APP_PLATFORMS.has(platform) ||
      !isAppleBundleIdentifier(apnsTopic)
    ) {
      fail(`wrangler APP_ATTEST_APNS_ROUTES entry ${index} is not a valid authenticated Apple app route.`);
    }
    const separator = appIdentity.indexOf(".");
    const teamId = separator > 0 ? appIdentity.slice(0, separator) : "";
    const bundleId = separator > 0 ? appIdentity.slice(separator + 1) : "";
    if (
      !/^[A-Z0-9]{10}$/.test(teamId) ||
      !isAppleBundleIdentifier(bundleId) ||
      bundleId !== apnsTopic
    ) {
      fail(`wrangler APP_ATTEST_APNS_ROUTES entry ${index} must bind one valid App Attest app identity to its identical APNs topic.`);
    }
    // Rebuild each route in a fixed key order so harmless JSON key order and
    // whitespace never alter the release fingerprint.
    return { appIdentity, apnsTopic, platform };
  });
  if (new Set(routes.map(({ appIdentity }) => appIdentity)).size !== routes.length) {
    fail("wrangler APP_ATTEST_APNS_ROUTES must not repeat an app identity.");
  }
  if (!routes.some(({ appIdentity }) => appIdentity === vars.APP_ATTEST_APP_ID)) {
    fail("wrangler APP_ATTEST_APNS_ROUTES must include the primary APP_ATTEST_APP_ID.");
  }
  return routes.sort((left, right) =>
    left.appIdentity < right.appIdentity
      ? -1
      : left.appIdentity > right.appIdentity
        ? 1
        : 0
  );
}

function requiredWorkerValue(vars, key, expected) {
  if (vars[key] !== expected) {
    fail(`wrangler ${key} must be exactly ${JSON.stringify(expected)} for the reviewed public release contract.`);
  }
}

function appAttestPolicyFingerprint(vars, allowedBundleVersions, appIdentityRoutes) {
  const policy = [
    `app_id=${vars.APP_ATTEST_APP_ID}`,
    "protocol_version=1",
    `required=${vars.APP_ATTEST_ENFORCEMENT !== "disabled"}`,
    `development_bypass_allowed=${vars.APP_ATTEST_ENFORCEMENT === "development" && vars.APP_ATTEST_DEVELOPMENT_BYPASS === "true"}`,
    `verification_environment=${vars.APP_ATTEST_ENFORCEMENT === "development" && vars.APP_ATTEST_DEVELOPMENT_ENVIRONMENT === "true" ? "development" : "production"}`,
    `require_release_metadata=${vars.APP_ATTEST_REQUIRE_RELEASE_METADATA === "true"}`,
    `allowed_bundle_versions=${allowedBundleVersions.join(",")}`,
    `app_attest_apns_routes=${JSON.stringify(appIdentityRoutes)}`,
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

function parseEffectiveYAML(source, label, path) {
  try {
    const output = execFileSync("ruby", ["-r", "yaml", "-r", "json", "-e", RUBY_YAML_TO_JSON], {
      input: source,
      encoding: "utf8",
      stdio: ["pipe", "pipe", "pipe"],
    });
    return record(JSON.parse(output), label);
  } catch (error) {
    const detail = error && typeof error === "object" && "stderr" in error
      ? String(error.stderr).trim()
      : "";
    fail(`${path} must be safe, duplicate-free YAML${detail ? `: ${detail}` : "."}`);
  }
}

function parseEffectiveWorkflow(workflow, label = "iOS workflow", path = ".github/workflows/ios.yml") {
  return parseEffectiveYAML(workflow, label, path);
}

function workflowDispatch(workflow, label = "iOS workflow") {
  // Psych follows YAML 1.1 and emits the unquoted GitHub key `on` as true.
  const trigger = workflow.on ?? workflow.true;
  const dispatch = record(record(trigger, `${label} triggers`).workflow_dispatch, `${label} workflow_dispatch`);
  return record(dispatch.inputs, `${label} workflow_dispatch inputs`);
}

function stepByName(steps, name, label) {
  const matches = steps.filter((step) => isRecord(step) && step.name === name);
  return exactlyOne(matches, label);
}

function forbidSimulatorDownloads(jobs, label) {
  if (/xcodebuild\s+-downloadPlatform\b/.test(JSON.stringify(jobs))) {
    fail(`${label} must not download Simulator runtimes during build or release jobs.`);
  }
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
  forbidSimulatorDownloads(jobs, "iOS workflow");
  const genericBuilds = record(jobs["generic-platform-builds"], "generic Apple platform build job");
  exactRecordWithAllowedKeys(
    genericBuilds,
    GENERIC_BUILD_JOB_HEADER,
    ["steps"],
    "generic Apple platform build job header",
  );
  if (!Array.isArray(genericBuilds.steps)) fail("generic Apple platform build steps must be a sequence.");
  const genericBuild = stepByName(
    genericBuilds.steps,
    "Build credential-free generic Release target",
    "generic credential-free build step",
  );
  exactRecord(genericBuild, {
    name: "Build credential-free generic Release target",
    env: {
      PLATFORM_KEY: "${{ matrix.key }}",
      PLATFORM_SCHEME: "${{ matrix.scheme }}",
      PLATFORM_DESTINATION: "${{ matrix.destination }}",
    },
    run: [
      "set -euo pipefail",
      "set -o pipefail",
      "xcodebuild build \\",
      "  -project \"$XCODE_PROJECT\" \\",
      "  -scheme \"$PLATFORM_SCHEME\" \\",
      "  -configuration Release \\",
      "  -destination \"$PLATFORM_DESTINATION\" \\",
      "  -derivedDataPath \"$RUNNER_TEMP/quakesignal-$PLATFORM_KEY-derived-data\" \\",
      "  CODE_SIGNING_ALLOWED=NO | tee \"xcodebuild-$PLATFORM_KEY-generic-release.log\"",
      "",
    ].join("\n"),
  }, "generic credential-free build step");

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
      WATCH_PROFILE_NAME: "${{ vars.WATCHOS_APP_STORE_PROFILE_NAME }}",
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

function verifyPlatformArchiveWorkflow(workflowSource, buildNumber) {
  const label = "native platform workflow";
  const workflow = parseEffectiveWorkflow(
    workflowSource,
    label,
    ".github/workflows/apple-platforms.yml",
  );
  if (Object.hasOwn(workflow, "defaults")) {
    fail("native platform workflow-level defaults are forbidden for the release-contract execution boundary.");
  }
  exactRecord(workflow.env, PLATFORM_ROOT_ENV, "native platform workflow env");
  exactRecord(workflow.permissions, ROOT_PERMISSIONS, "native platform workflow permissions");
  exactRecord(workflow.concurrency, PLATFORM_ROOT_CONCURRENCY, "native platform workflow concurrency");
  const trigger = record(workflow.on ?? workflow.true, "native platform workflow triggers");
  if (!sameValue(Object.keys(trigger).sort(), ["workflow_dispatch"])) {
    fail("native platform release workflow must remain manual-only through workflow_dispatch.");
  }

  const dispatch = workflowDispatch(workflow, label);
  exactRecord(record(dispatch.platform, "native platform workflow platform input"), {
    description: "Native Apple platform to archive in this protected run",
    required: true,
    default: "tvos",
    type: "choice",
    options: ["tvos", "visionos"],
  }, "native platform workflow platform input");
  exactRecord(record(dispatch.archive_only, "native platform workflow archive_only input"), {
    description: "Archive, export, and validate a signed IPA without uploading it to App Store Connect",
    required: false,
    default: false,
    type: "boolean",
  }, "native platform workflow archive_only input");
  exactRecord(record(dispatch.upload_to_testflight, "native platform workflow upload_to_testflight input"), {
    description: "Archive, sign, and upload the selected native platform build to TestFlight",
    required: false,
    default: false,
    type: "boolean",
  }, "native platform workflow upload_to_testflight input");
  const buildInput = record(dispatch.build_number, "native platform workflow build_number input");
  const defaultBuildNumber = releaseBuildNumber(buildInput.default, "native platform workflow build_number default");
  if (defaultBuildNumber !== buildNumber) {
    fail(`native platform workflow build_number default ${defaultBuildNumber} does not match ios/project.yml ${buildNumber}.`);
  }
  exactRecord(buildInput, {
    description: "Exact coordinated CFBundleVersion from ios/project.yml and the Worker App Attest allow-list",
    required: false,
    default: buildNumber,
    type: "string",
  }, "native platform workflow build_number input");

  const jobs = record(workflow.jobs, "native platform workflow jobs");
  forbidSimulatorDownloads(jobs, "native platform workflow");
  if (!sameValue(Object.keys(jobs), ["release"])) {
    fail("native platform workflow must expose only its reviewed protected release job.");
  }
  const release = record(jobs.release, "native platform release job");
  exactRecordWithAllowedKeys(
    release,
    PLATFORM_RELEASE_JOB_HEADER,
    ["steps"],
    "native platform release job header",
  );
  if (!Array.isArray(release.steps)) fail("native platform release steps must be a sequence.");
  const steps = release.steps;
  const expectedPrelude = [
    "Check out repository",
    "Verify Apple platform and Worker release contract",
    "Verify production notification origin readiness and contract",
  ];
  if (steps.length < expectedPrelude.length ||
      steps.slice(0, expectedPrelude.length).some((step, index) => step?.name !== expectedPrelude[index])) {
    fail("native platform release must run checkout, static release contract, and remote policy smoke consecutively before all credential-bearing steps.");
  }
  exactRecord(steps[0], {
    name: "Check out repository",
    uses: CHECKOUT_ACTION,
  }, "native platform checkout step");
  exactRecord(steps[1], {
    name: "Verify Apple platform and Worker release contract",
    id: "release-contract",
    env: { BUILD_NUMBER: "${{ inputs.build_number }}" },
    run: PRE_SIGNING_COMMAND,
  }, "native platform pre-signing release-contract step");
  exactRecord(steps[2], {
    name: "Verify production notification origin readiness and contract",
    "working-directory": "backend/cloudflare",
    env: {
      IOS_RELEASE_API_BASE_URL: "${{ vars.CLOUDFLARE_WORKER_URL }}",
      BUILD_NUMBER: "${{ inputs.build_number }}",
      APP_ATTEST_POLICY_FINGERPRINT: "${{ steps.release-contract.outputs.app_attest_policy_fingerprint }}",
    },
    run: REMOTE_SMOKE_COMMAND,
  }, "native platform remote App Attest policy contract step");

  const archive = stepByName(steps, "Archive selected signed App Store build", "native platform signed archive step");
  exactRecord(archive, {
    name: "Archive selected signed App Store build",
    env: {
      BUILD_NUMBER: "${{ inputs.build_number }}",
      PLATFORM_KEY: "${{ matrix.key }}",
      PLATFORM_SCHEME: "${{ matrix.scheme }}",
      PLATFORM_DESTINATION: "${{ matrix.destination }}",
      PLATFORM_PROFILE_NAME: "${{ vars[matrix.profile_variable] }}",
      IOS_RELEASE_API_BASE_URL: "${{ vars.CLOUDFLARE_WORKER_URL }}",
    },
    run: PLATFORM_ARCHIVE_COMMAND,
  }, "native platform signed archive step");

  const postSmokeFingerprint = workflowSequenceFingerprint(steps.slice(expectedPrelude.length));
  if (postSmokeFingerprint !== PLATFORM_POST_SMOKE_SEQUENCE_FINGERPRINT) {
    fail("native platform post-remote signing sequence must match the reviewed fingerprint.");
  }
  if (workflowSequenceFingerprint(jobs) !== PLATFORM_WORKFLOW_JOBS_FINGERPRINT) {
    fail("native platform workflow jobs must match the reviewed protected-release graph fingerprint.");
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

function verifyScreenshotCandidateWorkflow(workflowSource) {
  const label = "native screenshot candidate workflow";
  const workflow = parseEffectiveWorkflow(
    workflowSource,
    label,
    ".github/workflows/apple-platform-screenshots.yml",
  );
  if (Object.hasOwn(workflow, "defaults")) {
    fail("native screenshot candidate workflow-level defaults are forbidden.");
  }
  exactRecord(workflow.permissions, ROOT_PERMISSIONS, "native screenshot candidate workflow permissions");
  exactRecord(workflow.concurrency, SCREENSHOT_ROOT_CONCURRENCY, "native screenshot candidate workflow concurrency");
  exactRecord(
    workflow.on ?? workflow.true,
    { workflow_dispatch: null },
    "native screenshot candidate workflow triggers",
  );

  if (/\$\{\{\s*secrets\./i.test(JSON.stringify(workflow))) {
    fail("native screenshot candidate workflow must remain credential-free.");
  }
  const jobs = record(workflow.jobs, "native screenshot candidate workflow jobs");
  if (!sameValue(Object.keys(jobs), ["capture"])) {
    fail("native screenshot candidate workflow must expose only its reviewed capture job.");
  }
  if (workflowSequenceFingerprint(jobs) !== SCREENSHOT_WORKFLOW_JOBS_FINGERPRINT) {
    fail("native screenshot candidate workflow jobs must match the reviewed capture graph fingerprint.");
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
  const path = (relativePath) => resolve(root, relativePath);
  const [project, projectFile, infoPlists, workerConfig, iosWorkflow, platformWorkflow, screenshotWorkflow, cloudflareWorkflow] = await Promise.all([
    readFile(path(contractFiles.project), "utf8"),
    readFile(path(contractFiles.projectFile), "utf8"),
    Promise.all(contractFiles.infoPlists.map((relativePath) => readFile(path(relativePath), "utf8"))),
    readFile(path(contractFiles.workerConfig), "utf8"),
    readFile(path(contractFiles.iosWorkflow), "utf8"),
    readFile(path(contractFiles.platformWorkflow), "utf8"),
    readFile(path(contractFiles.screenshotWorkflow), "utf8"),
    readFile(path(contractFiles.cloudflareWorkflow), "utf8"),
  ]);
  const buildNumber = captureProjectBuildNumber(project);
  if (expectedBuildNumber !== undefined) {
    const requested = releaseBuildNumber(expectedBuildNumber, "requested build_number");
    if (requested !== buildNumber) {
      fail(`requested build_number ${requested} does not match ios/project.yml ${buildNumber}.`);
    }
  }
  verifyAppleProject(project);
  const generatedProjectEntries = verifyGeneratedProject(projectFile, buildNumber);
  for (const [index, infoPlist] of infoPlists.entries()) {
    verifyInfoPlist(infoPlist, contractFiles.infoPlists[index]);
  }
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
  const appIdentityRoutes = normalizedWorkerAppIdentityRoutes(workerVars);
  if (!sameValue(appIdentityRoutes, REVIEWED_APP_ATTEST_APNS_ROUTES)) {
    fail(`wrangler APP_ATTEST_APNS_ROUTES must normalize to exactly ${JSON.stringify(REVIEWED_APP_ATTEST_APNS_ROUTES)} for the reviewed public release contract.`);
  }
  verifyArchiveWorkflow(iosWorkflow, buildNumber);
  verifyPlatformArchiveWorkflow(platformWorkflow, buildNumber);
  verifyScreenshotCandidateWorkflow(screenshotWorkflow);
  verifyProductionDeploymentSerialization(cloudflareWorkflow);
  return {
    buildNumber,
    allowedBundleVersions,
    appIdentityRoutes,
    generatedProjectEntries,
    appAttestPolicyFingerprint: appAttestPolicyFingerprint(
      workerVars,
      allowedBundleVersions,
      appIdentityRoutes,
    ),
  };
}

async function main() {
  try {
    const verified = await verifyIOSReleaseContract({
      expectedBuildNumber: requestedBuildNumber(process.argv.slice(2)),
    });
    console.log(`Verified coordinated Apple platform Release build ${verified.buildNumber} against Worker App Attest versions ${verified.allowedBundleVersions.join(",")} and ${verified.generatedProjectEntries} generated Xcode configurations.`);
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
