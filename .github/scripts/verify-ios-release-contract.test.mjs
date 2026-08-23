import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { chmod, mkdtemp, mkdir, readFile, readdir, rm, symlink, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import test from "node:test";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";

import { verifyIOSReleaseContract } from "./verify-ios-release-contract.mjs";

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const approvedOrigin = "https://quakesignal-api.hopeso.workers.dev";
const reviewedAppIdentityRoutes = [
  {
    appIdentity: "5TT564H883.com.quakesignal.app",
    apnsTopic: "com.quakesignal.app",
    platform: "ios",
  },
];
const reviewedAppIdentityRoutesJSON = JSON.stringify(reviewedAppIdentityRoutes);
const xcodeCloudReleaseFiles = [
  "ios/ci_scripts/ci_post_clone.sh",
  "ios/ci_scripts/ci_pre_xcodebuild.sh",
  "ios/ci_scripts/ci_post_xcodebuild.sh",
  "ios/ci_scripts/xcode-cloud-release-guard.py",
  "ios/ci_scripts/verify-signed-apple-artifacts.sh",
];
const executableReleaseFiles = new Set(
  xcodeCloudReleaseFiles.filter((path) => path.endsWith(".sh") || path.endsWith(".py")),
);
const screenshotAutomationFiles = [
  "ios/ScreenshotAutomation/README.md",
  "ios/ScreenshotAutomation/assemble-ios-screenshot-provenance.rb",
  "ios/ScreenshotAutomation/assemble-ios-screenshot-provenance.test.rb",
  "ios/ScreenshotAutomation/assemble-maccatalyst-screenshot-provenance.rb",
  "ios/ScreenshotAutomation/assemble-maccatalyst-screenshot-provenance.test.rb",
  "ios/ScreenshotAutomation/assemble-platform-screenshot-provenance.rb",
  "ios/ScreenshotAutomation/assemble-platform-screenshot-provenance.test.rb",
  "ios/ScreenshotAutomation/capture-ios-screenshot-set.sh",
  "ios/ScreenshotAutomation/capture-ios-screenshot.sh",
  "ios/ScreenshotAutomation/capture-maccatalyst-screenshot-set.sh",
  "ios/ScreenshotAutomation/capture-maccatalyst-screenshot.sh",
  "ios/ScreenshotAutomation/capture-platform-screenshot-interface.test.sh",
  "ios/ScreenshotAutomation/capture-platform-screenshot-set.sh",
  "ios/ScreenshotAutomation/capture-platform-screenshot.sh",
  "ios/ScreenshotAutomation/ios-screenshot-build-binding.rb",
  "ios/ScreenshotAutomation/ios-screenshot-build-binding.test.rb",
  "ios/ScreenshotAutomation/ios-screenshot-capture-interface.test.sh",
  "ios/ScreenshotAutomation/ios-screenshot-content-validator-fixture.swift",
  "ios/ScreenshotAutomation/ios-screenshot-content-validator.swift",
  "ios/ScreenshotAutomation/ios-screenshot-content-validator.test.sh",
  "ios/ScreenshotAutomation/ios-screenshot-plan.rb",
  "ios/ScreenshotAutomation/ios-screenshot-plan.test.rb",
  "ios/ScreenshotAutomation/ios-screenshot-simulator-lease.rb",
  "ios/ScreenshotAutomation/ios-screenshot-simulator-lease.test.rb",
  "ios/ScreenshotAutomation/ios-screenshot-swift-inputs.rb",
  "ios/ScreenshotAutomation/ios-screenshot-swift-inputs.test.rb",
  "ios/ScreenshotAutomation/maccatalyst-capture-interface.test.sh",
  "ios/ScreenshotAutomation/maccatalyst-capture-retry-policy.sh",
  "ios/ScreenshotAutomation/maccatalyst-capture-retry-policy.test.sh",
  "ios/ScreenshotAutomation/maccatalyst-capture-window.swift",
  "ios/ScreenshotAutomation/maccatalyst-content-validator-fixture.swift",
  "ios/ScreenshotAutomation/maccatalyst-content-validator.test.sh",
  "ios/ScreenshotAutomation/maccatalyst-flatten-png.swift",
  "ios/ScreenshotAutomation/maccatalyst-process-guard.sh",
  "ios/ScreenshotAutomation/maccatalyst-process-guard.test.sh",
  "ios/ScreenshotAutomation/maccatalyst-screenshot-plan.rb",
  "ios/ScreenshotAutomation/maccatalyst-screenshot-plan.test.rb",
  "ios/ScreenshotAutomation/maccatalyst-validate-content.swift",
  "ios/ScreenshotAutomation/maccatalyst-window-evidence.swift",
  "ios/ScreenshotAutomation/parse-ios-screenshot-build-settings.rb",
  "ios/ScreenshotAutomation/parse-ios-screenshot-build-settings.test.rb",
  "ios/ScreenshotAutomation/platform-screenshot-plan.rb",
  "ios/ScreenshotAutomation/platform-screenshot-plan.test.rb",
  "ios/ScreenshotAutomation/prepare-ios-screenshot-build-source.rb",
  "ios/ScreenshotAutomation/prepare-ios-screenshot-build-source.test.rb",
  "ios/ScreenshotAutomation/resolve-ios-screenshot-simulator.rb",
  "ios/ScreenshotAutomation/resolve-ios-screenshot-simulator.test.rb",
  "ios/ScreenshotAutomation/safe-zip-tree.rb",
  "ios/ScreenshotAutomation/safe-zip-tree.test.rb",
  "ios/ScreenshotAutomation/screenshot-process-guard.sh",
  "ios/ScreenshotAutomation/screenshot-process-guard.test.sh",
  "ios/ScreenshotAutomation/screenshot-test-temp-root.rb",
  "ios/ScreenshotAutomation/seal-screenshot-capture-package.rb",
  "ios/ScreenshotAutomation/seal-screenshot-capture-package.test.rb",
  "ios/ScreenshotAutomation/validate-vision-map-content.rb",
  "ios/ScreenshotAutomation/validate-vision-map-content.test.rb",
  "ios/ScreenshotAutomation/validate-watch-foreground-badge.rb",
  "ios/ScreenshotAutomation/validate-watch-foreground-badge.test.rb",
  "ios/ScreenshotAutomation/vision-map-capture-guard.sh",
  "ios/ScreenshotAutomation/vision-map-capture-guard.test.sh",
  "ios/ScreenshotAutomation/watch-capture-guard-xcrun-stub.rb",
  "ios/ScreenshotAutomation/watch-capture-guard.sh",
  "ios/ScreenshotAutomation/watch-capture-guard.test.sh",
];
const executableScreenshotAutomationFiles = new Set([
  "ios/ScreenshotAutomation/capture-ios-screenshot-set.sh",
  "ios/ScreenshotAutomation/capture-ios-screenshot.sh",
  "ios/ScreenshotAutomation/assemble-maccatalyst-screenshot-provenance.rb",
  "ios/ScreenshotAutomation/assemble-maccatalyst-screenshot-provenance.test.rb",
  "ios/ScreenshotAutomation/assemble-platform-screenshot-provenance.rb",
  "ios/ScreenshotAutomation/capture-maccatalyst-screenshot-set.sh",
  "ios/ScreenshotAutomation/capture-maccatalyst-screenshot.sh",
  "ios/ScreenshotAutomation/capture-platform-screenshot-interface.test.sh",
  "ios/ScreenshotAutomation/capture-platform-screenshot-set.sh",
  "ios/ScreenshotAutomation/capture-platform-screenshot.sh",
  "ios/ScreenshotAutomation/ios-screenshot-build-binding.rb",
  "ios/ScreenshotAutomation/ios-screenshot-capture-interface.test.sh",
  "ios/ScreenshotAutomation/ios-screenshot-content-validator.test.sh",
  "ios/ScreenshotAutomation/ios-screenshot-plan.rb",
  "ios/ScreenshotAutomation/ios-screenshot-simulator-lease.rb",
  "ios/ScreenshotAutomation/ios-screenshot-simulator-lease.test.rb",
  "ios/ScreenshotAutomation/ios-screenshot-swift-inputs.rb",
  "ios/ScreenshotAutomation/ios-screenshot-swift-inputs.test.rb",
  "ios/ScreenshotAutomation/maccatalyst-capture-interface.test.sh",
  "ios/ScreenshotAutomation/maccatalyst-capture-retry-policy.test.sh",
  "ios/ScreenshotAutomation/maccatalyst-content-validator.test.sh",
  "ios/ScreenshotAutomation/maccatalyst-process-guard.test.sh",
  "ios/ScreenshotAutomation/maccatalyst-screenshot-plan.rb",
  "ios/ScreenshotAutomation/maccatalyst-screenshot-plan.test.rb",
  "ios/ScreenshotAutomation/parse-ios-screenshot-build-settings.rb",
  "ios/ScreenshotAutomation/platform-screenshot-plan.rb",
  "ios/ScreenshotAutomation/prepare-ios-screenshot-build-source.rb",
  "ios/ScreenshotAutomation/resolve-ios-screenshot-simulator.rb",
  "ios/ScreenshotAutomation/safe-zip-tree.test.rb",
  "ios/ScreenshotAutomation/seal-screenshot-capture-package.rb",
  "ios/ScreenshotAutomation/validate-vision-map-content.rb",
  "ios/ScreenshotAutomation/validate-vision-map-content.test.rb",
  "ios/ScreenshotAutomation/vision-map-capture-guard.sh",
  "ios/ScreenshotAutomation/vision-map-capture-guard.test.sh",
  "ios/ScreenshotAutomation/watch-capture-guard-xcrun-stub.rb",
]);

function fixtureFiles({
  buildNumber = "10",
  projectFileVersions = [buildNumber, buildNumber, buildNumber],
  infoBundleVersion = "$(CURRENT_PROJECT_VERSION)",
  allowedVersions = "1,2,3,4,5,6,7,8,9,10",
  workflowDefault = buildNumber,
  archiveConfiguration = "Release",
  remoteOrigin = "${{ vars.CLOUDFLARE_WORKER_URL }}",
  remoteRunPrefix = "",
  workerConfigSuffix = "",
} = {}) {
  const remoteRun = [
    "set -euo pipefail",
    `if [ \"$IOS_RELEASE_API_BASE_URL\" != \"${approvedOrigin}\" ]; then`,
    `  echo \"::error::IOS_RELEASE_API_BASE_URL must be ${approvedOrigin}\"`,
    "  exit 1",
    "fi",
    remoteRunPrefix,
    "node scripts/wait-for-worker-readiness.mjs \"$IOS_RELEASE_API_BASE_URL\"",
    "node scripts/smoke-test.mjs \"$IOS_RELEASE_API_BASE_URL\" \\",
    "  --expected-app-attest-policy-fingerprint \"$APP_ATTEST_POLICY_FINGERPRINT\" \\",
    "  --required-app-attest-bundle-version \"$BUILD_NUMBER\"",
  ].filter(Boolean).map((line) => `          ${line}`).join("\n");
  const files = {
    "ios/project.yml": `options:
  deploymentTarget:
    iOS: "17.0"
    tvOS: "17.0"
    watchOS: "10.0"
    visionOS: "1.0"
settings:
  base:
    MARKETING_VERSION: "1.1"
    CURRENT_PROJECT_VERSION: "${buildNumber}"
targets:
  QuakeSignal:
    type: application
    platform: iOS
    dependencies:
      - target: QuakeSignalWatch
        embed: true
        platformFilter: iOS
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.quakesignal.app
        TARGETED_DEVICE_FAMILY: "1,2"
      configs:
        Release:
          CODE_SIGN_ENTITLEMENTS: QuakeSignal/Supporting/QuakeSignal-Release.entitlements
          PROVISIONING_PROFILE_SPECIFIER: $(QUAKESIGNAL_IOS_PROFILE_NAME)
  QuakeSignalTV:
    type: application
    platform: tvOS
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.quakesignal.app
        TARGETED_DEVICE_FAMILY: "3"
      configs:
        Release:
          PROVISIONING_PROFILE_SPECIFIER: $(QUAKESIGNAL_TV_PROFILE_NAME)
  QuakeSignalVision:
    type: application
    platform: visionOS
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.quakesignal.app
        TARGETED_DEVICE_FAMILY: "7"
      configs:
        Release:
          CODE_SIGN_ENTITLEMENTS: QuakeSignalVision/Supporting/QuakeSignalVision-Release.entitlements
          PROVISIONING_PROFILE_SPECIFIER: $(QUAKESIGNAL_VISION_PROFILE_NAME)
  QuakeSignalWatch:
    type: application
    platform: watchOS
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.quakesignal.app.watchkitapp
        TARGETED_DEVICE_FAMILY: "4"
      configs:
        Release:
          PROVISIONING_PROFILE_SPECIFIER: $(QUAKESIGNAL_WATCH_PROFILE_NAME)
schemes:
  QuakeSignal:
    archive: { config: Release }
  QuakeSignalTV:
    archive: { config: Release }
  QuakeSignalVision:
    archive: { config: Release }
  QuakeSignalWatch:
    archive: { config: Release }
`,
    "ios/QuakeSignal.xcodeproj/project.pbxproj": projectFileVersions
      .map((version) => `\t\t\t\tCURRENT_PROJECT_VERSION = ${version};`)
      .join("\n"),
    "ios/QuakeSignal/Supporting/Info.plist": `<?xml version="1.0"?>\n<plist><dict>\n<key>CFBundleVersion</key>\n<string>${infoBundleVersion}</string>\n</dict></plist>\n`,
    "ios/QuakeSignalTV/Supporting/Info.plist": `<?xml version="1.0"?>\n<plist><dict>\n<key>CFBundleVersion</key>\n<string>${infoBundleVersion}</string>\n</dict></plist>\n`,
    "ios/QuakeSignalVision/Supporting/Info.plist": `<?xml version="1.0"?>\n<plist><dict>\n<key>CFBundleVersion</key>\n<string>${infoBundleVersion}</string>\n</dict></plist>\n`,
    "ios/QuakeSignalWatch/Supporting/Info.plist": `<?xml version="1.0"?>\n<plist><dict>\n<key>CFBundleVersion</key>\n<string>${infoBundleVersion}</string>\n</dict></plist>\n`,
    "backend/cloudflare/wrangler.jsonc": `{\n  "vars": {\n    "APP_ATTEST_ENFORCEMENT": "required",\n    "APP_ATTEST_APP_ID": "5TT564H883.com.quakesignal.app",\n    "APP_ATTEST_APNS_ROUTES": ${JSON.stringify(reviewedAppIdentityRoutesJSON)},\n    "APP_ATTEST_ALLOWED_BUNDLE_VERSIONS": "${allowedVersions}",\n    "APP_ATTEST_REQUIRE_RELEASE_METADATA": "false"\n  }\n}${workerConfigSuffix}\n`,
    ".github/workflows/ios.yml": `name: iOS\non:\n  workflow_dispatch:\n    inputs:\n      build_number:\n        default: "${workflowDefault}"\n        type: string\nenv:\n  XCODE_PROJECT: ios/QuakeSignal.xcodeproj\n  XCODE_SCHEME: QuakeSignal\n  XCODEGEN_VERSION: 2.46.0\n  XCODEGEN_SHA256: 4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806\njobs:\n  testflight:\n    steps:\n      - name: Check out repository\n        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1\n      - name: Verify iOS and Worker release contract\n        id: release-contract\n        env:\n          BUILD_NUMBER: \${{ inputs.build_number }}\n        run: node .github/scripts/verify-ios-release-contract.mjs --build-number "$BUILD_NUMBER"\n      - name: Verify production notification origin readiness and contract\n        working-directory: backend/cloudflare\n        env:\n          IOS_RELEASE_API_BASE_URL: ${remoteOrigin}\n          BUILD_NUMBER: \${{ inputs.build_number }}\n          APP_ATTEST_POLICY_FINGERPRINT: \${{ steps.release-contract.outputs.app_attest_policy_fingerprint }}\n        run: |\n${remoteRun}\n      - name: Archive signed App Store build\n        env:\n          BUILD_NUMBER: \${{ inputs.build_number }}\n          IOS_PROFILE_NAME: \${{ vars.IOS_APP_STORE_PROFILE_NAME }}\n          IOS_RELEASE_API_BASE_URL: \${{ vars.CLOUDFLARE_WORKER_URL }}\n        run: >-\n          xcodebuild archive\n          -project "$XCODE_PROJECT"\n          -scheme "$XCODE_SCHEME"\n          -configuration ${archiveConfiguration}\n          -destination 'generic/platform=iOS'\n          -archivePath "$RUNNER_TEMP/QuakeSignal.xcarchive"\n          DEVELOPMENT_TEAM=5TT564H883\n          CODE_SIGN_STYLE=Manual\n          CODE_SIGN_IDENTITY='Apple Distribution'\n          PROVISIONING_PROFILE_SPECIFIER="$IOS_PROFILE_NAME"\n          CURRENT_PROJECT_VERSION="$BUILD_NUMBER"\n          QUAKESIGNAL_API_BASE_URL="$IOS_RELEASE_API_BASE_URL"\n`,
  };
  files[".github/workflows/ios.yml"] = files[".github/workflows/ios.yml"]
    .replace(
      "        type: string\nenv:\n",
      `        type: string
      archive_only:
        description: Archive, verify, and hash a signed IPA without retaining or uploading it
        required: false
        default: false
        type: boolean
      upload_to_testflight:
        description: Archive, sign, and upload a new build to TestFlight
        required: false
        default: false
        type: boolean
permissions:
  contents: read
concurrency:
  group: ios-\${{ github.workflow }}-\${{ github.ref }}-\${{ github.event_name }}
  cancel-in-progress: \${{ github.event_name != 'workflow_dispatch' }}
env:
`,
    )
    .replace(
      "jobs:\n  testflight:\n    steps:\n",
      `jobs:
  testflight:
    name: Archive and optionally upload TestFlight build
    needs: test
    if: >-
      github.event_name == 'workflow_dispatch' &&
      (inputs.archive_only || inputs.upload_to_testflight) &&
      github.ref == 'refs/heads/main' &&
      github.ref_protected
    runs-on: macos-latest
    environment:
      name: ios-app-store-release
    steps:
`,
    )
    .replace(
      "      build_number:\n        default:",
      "      build_number:\n        description: Exact pre-approved CFBundleVersion from ios/project.yml and the Worker App Attest allow-list\n        required: false\n        default:",
    );
  return files;
}

async function fixtureWorkflow({
  workflowDefault = "10",
  remoteOrigin = "${{ vars.CLOUDFLARE_WORKER_URL }}",
  remoteRunPrefix = "",
  archiveConfiguration = "Release",
} = {}) {
  let workflow = await readFile(join(repositoryRoot, ".github/workflows/ios.yml"), "utf8");
  const replaceOnce = (from, to, label) => {
    if (!workflow.includes(from)) throw new Error(`fixture could not locate ${label}`);
    workflow = workflow.replace(from, to);
  };

  if (workflowDefault !== "10") {
    replaceOnce(
      '        default: "10"\n        type: string\n',
      `        default: "${workflowDefault}"\n        type: string\n`,
      "build_number default",
    );
  }
  if (remoteOrigin !== "${{ vars.CLOUDFLARE_WORKER_URL }}") {
    replaceOnce(
      "          IOS_RELEASE_API_BASE_URL: ${{ vars.CLOUDFLARE_WORKER_URL }}\n          BUILD_NUMBER:",
      `          IOS_RELEASE_API_BASE_URL: ${remoteOrigin}\n          BUILD_NUMBER:`,
      "remote origin",
    );
  }
  if (remoteRunPrefix) {
    const marker = "      - name: Verify production notification origin readiness and contract\n";
    const offset = workflow.indexOf(marker);
    if (offset < 0) throw new Error("fixture could not locate remote policy smoke");
    const before = workflow.slice(0, offset + marker.length);
    const after = workflow.slice(offset + marker.length);
    const runStart = "        run: |\n          set -euo pipefail\n";
    if (!after.includes(runStart)) throw new Error("fixture could not locate remote policy smoke run command");
    workflow = `${before}${after.replace(runStart, `${runStart}          ${remoteRunPrefix}\n`)}`;
  }
  if (archiveConfiguration !== "Release") {
    const marker = "      - name: Archive signed App Store build\n";
    const offset = workflow.indexOf(marker);
    if (offset < 0) throw new Error("fixture could not locate signed archive");
    const before = workflow.slice(0, offset + marker.length);
    const after = workflow.slice(offset + marker.length);
    if (!after.includes("          -configuration Release\n")) {
      throw new Error("fixture could not locate archive configuration");
    }
    workflow = `${before}${after.replace("          -configuration Release\n", `          -configuration ${archiveConfiguration}\n`)}`;
  }
  return workflow;
}

async function fixturePlatformWorkflow({ workflowDefault = "10" } = {}) {
  let workflow = await readFile(join(repositoryRoot, ".github/workflows/apple-platforms.yml"), "utf8");
  if (workflowDefault !== "10") {
    const from = '        default: "10"\n        type: string\n';
    if (!workflow.includes(from)) throw new Error("fixture could not locate native platform build_number default");
    workflow = workflow.replace(from, `        default: "${workflowDefault}"\n        type: string\n`);
  }
  return workflow;
}

async function writeFixture(options = {}) {
  const tempRoot = process.env.QUAKESIGNAL_TEST_TEMP_ROOT || tmpdir();
  const root = await mkdtemp(join(tempRoot, "quakesignal-ios-release-contract-"));
  const files = fixtureFiles(options);
  const buildNumber = options.buildNumber ?? "10";
  let project = await readFile(join(repositoryRoot, "ios/project.yml"), "utf8");
  if (buildNumber !== "10") {
    project = project.replace(
      '    CURRENT_PROJECT_VERSION: "10"\n',
      `    CURRENT_PROJECT_VERSION: "${buildNumber}"\n`,
    );
  }
  files["ios/project.yml"] = project;
  const allowedVersions = options.allowedVersions ?? "1,2,3,4,5,6,7,8,9,10";
  const workerConfigSuffix = options.workerConfigSuffix ?? "";
  const workerConfig = await readFile(join(repositoryRoot, "backend/cloudflare/wrangler.jsonc"), "utf8");
  files["backend/cloudflare/wrangler.jsonc"] = workerConfig.replace(
    '"APP_ATTEST_ALLOWED_BUNDLE_VERSIONS": "1,2,3,4,5,6,7,8,9,10"',
    `"APP_ATTEST_ALLOWED_BUNDLE_VERSIONS": "${allowedVersions}"`,
  ) + workerConfigSuffix;
  const projectFileVersions = options.projectFileVersions ?? [buildNumber, buildNumber, buildNumber];
  let projectFileIndex = 0;
  files["ios/QuakeSignal.xcodeproj/project.pbxproj"] = (
    await readFile(join(repositoryRoot, "ios/QuakeSignal.xcodeproj/project.pbxproj"), "utf8")
  ).replace(/CURRENT_PROJECT_VERSION = 10;/g, () => {
    const version = projectFileVersions[projectFileIndex++];
    if (version === undefined) throw new Error("fixture projectFileVersions must contain three entries");
    return `CURRENT_PROJECT_VERSION = ${version};`;
  });
  if (projectFileIndex !== 3) throw new Error("fixture generated project must contain three build versions");

  const workflowDirectory = join(repositoryRoot, ".github/workflows");
  for (const entry of await readdir(workflowDirectory, { withFileTypes: true })) {
    if (entry.isFile() && /\.ya?ml$/i.test(entry.name)) {
      files[`.github/workflows/${entry.name}`] = await readFile(join(workflowDirectory, entry.name), "utf8");
    }
  }
  files[".github/workflows/ios.yml"] = await fixtureWorkflow(options);
  files[".github/workflows/apple-platforms.yml"] = await fixturePlatformWorkflow(options);
  files[".github/workflows/apple-platform-screenshots.yml"] = await readFile(
    join(repositoryRoot, ".github/workflows/apple-platform-screenshots.yml"),
    "utf8",
  );
  files[".github/workflows/cloudflare.yml"] = await readFile(
    join(repositoryRoot, ".github/workflows/cloudflare.yml"),
    "utf8",
  );
  files["ios/AppStore/ExportOptions.plist"] = await readFile(
    join(repositoryRoot, "ios/AppStore/ExportOptions.plist"),
    "utf8",
  );
  files["ios/AppStore/platforms/maccatalyst/screenshot-manifest-v1.1-build10.json"] = await readFile(
    join(repositoryRoot, "ios/AppStore/platforms/maccatalyst/screenshot-manifest-v1.1-build10.json"),
    "utf8",
  );
  for (const relativePath of [
    "ios/QuakeSignal/Supporting/Info.plist",
    "ios/QuakeSignalTV/Supporting/Info.plist",
    "ios/QuakeSignalVision/Supporting/Info.plist",
    "ios/QuakeSignalWatch/Supporting/Info.plist",
    "ios/QuakeSignal/Supporting/QuakeSignal-Release.entitlements",
    "ios/QuakeSignal/Supporting/QuakeSignal-Catalyst.entitlements",
    "ios/QuakeSignalVision/Supporting/QuakeSignalVision-Release.entitlements",
    "ios/QuakeSignal/App/AppDelegate.swift",
    "ios/QuakeSignal/App/PlatformCapabilities.swift",
    "ios/QuakeSignal/App/QuakeSignalApp.swift",
    "ios/QuakeSignal/Features/Detail/QuakeDetailView.swift",
    "ios/QuakeSignal/Features/Guide/DisasterGuideView.swift",
    "ios/QuakeSignal/Features/List/QuakeListView.swift",
    "ios/QuakeSignal/Features/Home/QuakeRowView.swift",
    "ios/QuakeSignal/Features/Map/EpicenterMapView.swift",
    "ios/QuakeSignal/Features/Onboarding/OnboardingView.swift",
    "ios/QuakeSignal/Features/Root/RootView.swift",
    "ios/QuakeSignal/Features/Settings/SourceDisclaimerView.swift",
    "ios/QuakeSignal/Features/Settings/SettingsView.swift",
    "ios/QuakeSignal/Models/EEWEvent.swift",
    "ios/QuakeSignal/Networking/ForegroundHTTPFallbackPolicy.swift",
    "ios/QuakeSignal/Networking/LiveSocketClient.swift",
    "ios/QuakeSignal/Networking/WolfxClient.swift",
    "ios/QuakeSignal/Notifications/EmergencyAlertAudio.swift",
    "ios/QuakeSignal/Notifications/NotificationManager.swift",
    "ios/QuakeSignal/Notifications/PushPayload.swift",
    "ios/QuakeSignal/State/AlertPolicy.swift",
    "ios/QuakeSignal/State/AppSettings.swift",
    "ios/QuakeSignal/State/LocationManager.swift",
    "ios/QuakeSignal/State/QuakeStore.swift",
    "ios/QuakeSignalShared/AlertSoundPreference.swift",
    "ios/QuakeSignalShared/ForegroundQuakeStore.swift",
    "ios/QuakeSignalShared/ScreenshotAutomation.swift",
    "ios/QuakeSignalShared/WatchAlertPreferenceBridge.swift",
    "ios/QuakeSignalShared/WatchForegroundEmergencyPolicy.swift",
    "ios/QuakeSignalTV/TVAlertPreferences.swift",
    "ios/QuakeSignalTV/TVAlertSoundSettingsView.swift",
    "ios/QuakeSignalTV/TVDashboardView.swift",
    "ios/QuakeSignalTV/TVEmergencyAlertView.swift",
    "ios/QuakeSignalTV/TVEmergencyMonitor.swift",
    "ios/QuakeSignalTV/TVEmergencyPresentationPolicy.swift",
    "ios/QuakeSignalTV/TVUserInitiatedAlertAudio.swift",
    "ios/QuakeSignalTV/Supporting/PrivacyInfo.xcprivacy",
    "ios/QuakeSignalWatch/QuakeSignalWatchApp.swift",
    "ios/QuakeSignalWatch/WatchDashboardView.swift",
    "ios/QuakeSignalWatch/WatchEmergencyAlertAudio.swift",
    "ios/QuakeSignalWatch/WatchForegroundEmergencyMonitor.swift",
    "ios/QuakeSignalWatch/Supporting/PrivacyInfo.xcprivacy",
    "ios/QuakeSignal/Resources/PrivacyInfo.xcprivacy",
    "ios/QuakeSignal/Resources/en.lproj/Localizable.strings",
    "ios/QuakeSignal/Resources/ja.lproj/Localizable.strings",
    "ios/QuakeSignal/Resources/zh-Hans.lproj/Localizable.strings",
    "ios/QuakeSignalVision/Resources/PrivacyInfo.xcprivacy",
    "ios/QuakeSignal.xcodeproj/xcshareddata/xcschemes/QuakeSignal.xcscheme",
    "ios/QuakeSignal.xcodeproj/xcshareddata/xcschemes/QuakeSignalTV.xcscheme",
    "ios/QuakeSignal.xcodeproj/xcshareddata/xcschemes/QuakeSignalVision.xcscheme",
    "ios/QuakeSignal.xcodeproj/xcshareddata/xcschemes/QuakeSignalWatch.xcscheme",
    "backend/cloudflare/package.json",
    "backend/cloudflare/package-lock.json",
    "backend/cloudflare/scripts/legal-page-contract.mjs",
    "backend/cloudflare/scripts/render-staging-config.mjs",
    "backend/cloudflare/scripts/smoke-test-policy.mjs",
    "backend/cloudflare/scripts/smoke-test.mjs",
    "backend/cloudflare/scripts/verify-apns-worker-secrets.mjs",
    "backend/cloudflare/scripts/verify-production-gates.mjs",
    "backend/cloudflare/scripts/wait-for-worker-readiness.mjs",
    "backend/cloudflare/staging/wrangler.staging.template.json",
    ".github/scripts/assemble-apple-screenshot-release-set.rb",
    ".github/scripts/assemble-apple-screenshot-release-set.test.rb",
    ".github/scripts/verify-apple-screenshot-release-set.rb",
    ".github/scripts/verify-apple-screenshot-release-set.test.rb",
    ".github/scripts/verify-store-assets.rb",
    ".github/scripts/verify-store-assets.test.rb",
    "ios/AppStore/README.md",
    "ios/AppStore/screenshot-manifest-v1.1-build10.template.json",
  ]) {
    files[relativePath] = await readFile(join(repositoryRoot, relativePath), "utf8");
  }
  for (const relativePath of xcodeCloudReleaseFiles) {
    files[relativePath] = await readFile(join(repositoryRoot, relativePath), "utf8");
  }
  for (const relativePath of screenshotAutomationFiles) {
    files[relativePath] = await readFile(join(repositoryRoot, relativePath), "utf8");
  }
  for (const [relativePath, contents] of Object.entries(files)) {
    const path = join(root, relativePath);
    await mkdir(dirname(path), { recursive: true });
    await writeFile(path, contents, "utf8");
    if (executableReleaseFiles.has(relativePath)) await chmod(path, 0o755);
    if (executableScreenshotAutomationFiles.has(relativePath)) await chmod(path, 0o755);
  }
  return root;
}

async function withFixture(t, options, callback) {
  const root = await writeFixture(options);
  t.after(() => rm(root, { recursive: true, force: true }));
  return callback(root);
}

async function expectFailure(t, options, expression) {
  await withFixture(t, options, async (root) => {
    await assert.rejects(verifyIOSReleaseContract({ root }), expression);
  });
}

test("the checked-in public Release contract is coherent", async () => {
  const verified = await verifyIOSReleaseContract({ root: repositoryRoot });
  assert.equal(verified.buildNumber, "10");
  assert.deepEqual(verified.allowedBundleVersions, ["1", "10", "2", "3", "4", "5", "6", "7", "8", "9"]);
  assert.deepEqual(verified.appIdentityRoutes, reviewedAppIdentityRoutes);
  assert.equal(
    verified.appAttestPolicyFingerprint,
    "sha256:mI8J143835lDZjM-HsTvoDNHqnasuWTgi2Ydv3t63Go",
  );
});

test("fails closed on modified or non-executable Xcode Cloud release hooks", async (t) => {
  await withFixture(t, {}, async (root) => {
    const path = join(root, "ios/ci_scripts/ci_pre_xcodebuild.sh");
    await writeFile(path, `${await readFile(path, "utf8")}\n# unreviewed bypass\n`, "utf8");
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /Xcode Cloud release hooks must match the reviewed fingerprint/i,
    );
  });
  await withFixture(t, {}, async (root) => {
    const path = join(root, "ios/ci_scripts/ci_post_xcodebuild.sh");
    await chmod(path, 0o644);
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /ci_post_xcodebuild\.sh must be executable/i,
    );
  });
  await withFixture(t, {}, async (root) => {
    const path = join(root, "ios/ci_scripts/xcode-cloud-release-guard.py");
    await chmod(path, 0o644);
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /xcode-cloud-release-guard\.py must be executable/i,
    );
  });
  await withFixture(t, {}, async (root) => {
    const path = join(root, "ios/ci_scripts/verify-signed-apple-artifacts.sh");
    const contents = await readFile(path, "utf8");
    await writeFile(path, contents.replace('"$codesign_tool" --verify --deep --strict', "true # codesign bypass"), "utf8");
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /Xcode Cloud release hooks must match the reviewed fingerprint/i,
    );
  });
});

test("Xcode Cloud hooks isolate inherited shell, PATH, and Python imports and reject extra resources", async (t) => {
  await withFixture(t, {}, async (root) => {
    const ciScripts = join(root, "ios/ci_scripts");
    await writeFile(join(ciScripts, "json.py"), "import os\nos._exit(73)\n", "utf8");
    const bashEnvironment = join(root, "untrusted-bash-env.sh");
    await writeFile(bashEnvironment, "exit 74\n", "utf8");
    const untrustedBin = join(root, "untrusted-bin");
    await mkdir(untrustedBin);
    for (const name of ["dirname", "python3", "git"]) {
      const tool = join(untrustedBin, name);
      await writeFile(tool, "#!/bin/sh\nexit 75\n", "utf8");
      await chmod(tool, 0o755);
    }

    const output = execFileSync(join(ciScripts, "ci_pre_xcodebuild.sh"), [], {
      cwd: root,
      encoding: "utf8",
      env: {
        ...process.env,
        BASH_ENV: bashEnvironment,
        CI_XCODEBUILD_ACTION: "test",
        CI_WORKFLOW: "Ordinary CI",
        DEVELOPER_DIR: join(root, "untrusted-developer-dir"),
        PATH: untrustedBin,
        PYTHONPATH: ciScripts,
        SDKROOT: join(root, "untrusted-sdk"),
        TOOLCHAINS: "untrusted-toolchain",
      },
    });
    assert.match(output, /No protected release gate is required for test actions\./);
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /ios\/ci_scripts inventory must be exactly the reviewed set/i,
    );
  });
});

test("fails closed when a release-critical Worker helper drifts", async (t) => {
  await withFixture(t, {}, async (root) => {
    const path = join(root, "backend/cloudflare/scripts/wait-for-worker-readiness.mjs");
    await writeFile(path, `${await readFile(path, "utf8")}\n// unreviewed readiness bypass\n`, "utf8");
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /release-critical Worker helpers must match the reviewed fingerprint/i,
    );
  });
  for (const relativePath of [
    "backend/cloudflare/scripts/legal-page-contract.mjs",
    "backend/cloudflare/scripts/render-staging-config.mjs",
    "backend/cloudflare/staging/wrangler.staging.template.json",
  ]) {
    await withFixture(t, {}, async (root) => {
      const path = join(root, relativePath);
      await writeFile(path, `${await readFile(path, "utf8")}\n`, "utf8");
      await assert.rejects(
        verifyIOSReleaseContract({ root }),
        /release-critical Worker helpers must match the reviewed fingerprint/i,
      );
    });
  }
  await withFixture(t, {}, async (root) => {
    const path = join(root, "backend/cloudflare/scripts/smoke-test.mjs");
    const source = await readFile(path, "utf8");
    const mutated = source.replace(
      'from "./legal-page-contract.mjs";',
      'from "./unreviewed-legal-page-contract.mjs";',
    );
    assert.notEqual(mutated, source);
    await writeFile(path, mutated, "utf8");
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /release-critical Worker helpers must match the reviewed fingerprint/i,
    );
  });
  await withFixture(t, {}, async (root) => {
    const path = join(root, "backend/cloudflare/scripts/legal-page-contract.mjs");
    await rm(path);
    await symlink(join(repositoryRoot, "backend/cloudflare/scripts/legal-page-contract.mjs"), path);
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /legal-page-contract\.mjs must be a regular checked-in file/i,
    );
  });
});

test("fails closed when the native screenshot automation inventory, bytes, or modes drift", async (t) => {
  await withFixture(t, {}, async (root) => {
    const path = join(root, "ios/ScreenshotAutomation/vision-map-capture-guard.sh");
    await writeFile(path, `${await readFile(path, "utf8")}\n# unreviewed semantic bypass\n`, "utf8");
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /native screenshot automation helpers must match the reviewed fingerprint/i,
    );
  });
  await withFixture(t, {}, async (root) => {
    const path = join(root, "ios/ScreenshotAutomation/validate-vision-map-content.rb");
    await chmod(path, 0o644);
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /validate-vision-map-content\.rb executable mode must match/i,
    );
  });
  await withFixture(t, {}, async (root) => {
    await writeFile(
      join(root, "ios/ScreenshotAutomation/unreviewed-capture-helper.sh"),
      "#!/bin/bash\nexit 0\n",
      "utf8",
    );
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /ios\/ScreenshotAutomation inventory must be exactly the reviewed set/i,
    );
  });
  await withFixture(t, {}, async (root) => {
    const path = join(root, "ios/ScreenshotAutomation/validate-vision-map-content.rb");
    await rm(path);
    await symlink(join(repositoryRoot, "ios/ScreenshotAutomation/validate-vision-map-content.rb"), path);
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /ios\/ScreenshotAutomation must contain only the exact reviewed regular files/i,
    );
  });
});

test("fails closed when checked-in distribution entitlements gain a capability", async (t) => {
  for (const relativePath of [
    "ios/QuakeSignal/Supporting/QuakeSignal-Release.entitlements",
    "ios/QuakeSignal/Supporting/QuakeSignal-Catalyst.entitlements",
    "ios/QuakeSignalVision/Supporting/QuakeSignalVision-Release.entitlements",
  ]) {
    await withFixture(t, {}, async (root) => {
      const path = join(root, relativePath);
      const source = await readFile(path, "utf8");
      const injected = source.includes("</dict>")
        ? source.replace("</dict>", "\t<key>com.apple.developer.associated-domains</key>\n\t<string>applinks:attacker.invalid</string>\n</dict>")
        : source.replace("<dict/>", "<dict>\n\t<key>com.apple.developer.associated-domains</key>\n\t<string>applinks:attacker.invalid</string>\n</dict>");
      assert.notEqual(injected, source);
      await writeFile(
        path,
        injected,
        "utf8",
      );
      await assert.rejects(
        verifyIOSReleaseContract({ root }),
        /effective entitlements must contain exactly/i,
      );
    });
  }
});

test("keeps the Mac Catalyst screenshot plan source-only and exact", async (t) => {
  for (const [from, to] of [
    ['"uploadApproved": false', '"uploadApproved": true'],
    ['"captureSelector": "maccatalyst-map"', '"captureSelector": "maccatalyst-unreviewed"'],
    ['"selectedPixels": [2560, 1600]', '"selectedPixels": [2500, 1600]'],
  ]) {
    await withFixture(t, {}, async (root) => {
      const path = join(root, "ios/AppStore/platforms/maccatalyst/screenshot-manifest-v1.1-build10.json");
      const source = await readFile(path, "utf8");
      const mutated = source.replace(from, to);
      assert.notEqual(mutated, source);
      await writeFile(path, mutated, "utf8");
      await assert.rejects(
        verifyIOSReleaseContract({ root }),
        /Mac Catalyst screenshot/i,
      );
    });
  }
});

test("keeps the Mac Catalyst alert-preferences selector on the production Japanese voice destination", async (t) => {
  for (const [relativePath, from, to] of [
    [
      "ios/QuakeSignalShared/ScreenshotAutomation.swift",
      ".visionAlertPreferences, .macAlertPreferences:\n            .settings",
      ".visionAlertPreferences, .macAlertPreferences:\n            .home",
    ],
    [
      "ios/QuakeSignal/Features/Settings/SettingsView.swift",
      "ScreenshotAutomation.isAlertPreferencesFrame(",
      "ScreenshotAutomation.isAlertPreferencesFrameForMutation(",
    ],
    [
      "ios/QuakeSignal/Features/Root/RootView.swift",
      "ScreenshotAutomation.rootDestination(",
      "ScreenshotAutomation.rootDestinationForMutation(",
    ],
  ]) {
    await withFixture(t, {}, async (root) => {
      const path = join(root, relativePath);
      const source = await readFile(path, "utf8");
      const mutated = source.replace(from, to);
      assert.notEqual(mutated, source);
      await writeFile(path, mutated, "utf8");
      await assert.rejects(
        verifyIOSReleaseContract({ root }),
        /Mac Catalyst alert-preferences selector/i,
      );
    });
  }
});

test("keeps historical Mac Catalyst report rows date-qualified", async (t) => {
  await withFixture(t, {}, async (root) => {
    const path = join(root, "ios/QuakeSignal/Features/Home/QuakeRowView.swift");
    const source = await readFile(path, "utf8");
    const mutated = source.replace(
      "formatted(date: .numeric, time: .shortened)",
      "formatted(date: .omitted, time: .shortened)",
    );
    assert.notEqual(mutated, source);
    await writeFile(path, mutated, "utf8");
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /report rows must show a calendar date/i,
    );
  });
});

test("fails closed when foreground-only Vision capability, layout, or localized disclosure drifts", async (t) => {
  await withFixture(t, {}, async (root) => {
    const path = join(root, "ios/QuakeSignal/App/PlatformCapabilities.swift");
    const source = await readFile(path, "utf8");
    await writeFile(
      path,
      source.replace("#elseif os(visionOS)\n        false", "#elseif os(visionOS)\n        true"),
      "utf8",
    );
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /foreground-only Apple platform policy must match the reviewed fingerprint/i,
    );
  });
  await withFixture(t, {}, async (root) => {
    const path = join(root, "ios/QuakeSignal/App/QuakeSignalApp.swift");
    const source = await readFile(path, "utf8");
    const mutated = source.replace(
      "static let defaultWindowWidth: CGFloat = 1_600",
      "static let defaultWindowWidth: CGFloat = 1_200",
    );
    assert.notEqual(mutated, source);
    await writeFile(path, mutated, "utf8");
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /foreground-only Apple platform policy must match the reviewed fingerprint/i,
    );
  });
  await withFixture(t, {}, async (root) => {
    const path = join(root, "ios/QuakeSignal/App/QuakeSignalApp.swift");
    const source = await readFile(path, "utf8");
    const mutated = source.replace(
      "static let minimumControlTargetSize: CGFloat = 60",
      "static let minimumControlTargetSize: CGFloat = 44",
    );
    assert.notEqual(mutated, source);
    await writeFile(path, mutated, "utf8");
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /foreground-only Apple platform policy must match the reviewed fingerprint/i,
    );
  });
  await withFixture(t, {}, async (root) => {
    const path = join(root, "ios/QuakeSignal/Features/Guide/DisasterGuideView.swift");
    const source = await readFile(path, "utf8");
    const mutated = source.replace(
      ".visionReadableListSurface(",
      ".listStyle(.plain)\n            .visionReadableListSurface(",
    );
    assert.notEqual(mutated, source);
    await writeFile(path, mutated, "utf8");
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /foreground-only Apple platform policy must match the reviewed fingerprint/i,
    );
  });
  for (const [name, from, to] of [
    [
      "visionOS-only post-quake composition",
      "#if os(visionOS)\n                    VisionAfterQuakeItems",
      "#if os(iOS)\n                    VisionAfterQuakeItems",
    ],
    [
      "wide post-quake row",
      "AnyLayout(HStackLayout(alignment: .top, spacing: 24))",
      "AnyLayout(VStackLayout(alignment: .leading, spacing: 24))",
    ],
    [
      "accessibility Dynamic Type fallback",
      "!dynamicTypeSize.isAccessibilitySize",
      "true",
    ],
    [
      "post-quake row bottom inset regression",
      "static let afterQuakeRowBottomInset: CGFloat = 44",
      "static let afterQuakeRowBottomInset: CGFloat = 32",
    ],
    [
      "post-quake row bottom inset application",
      ".padding(.bottom, VisionGuideLayoutPolicy.afterQuakeRowBottomInset)",
      ".padding(.bottom, 0)",
    ],
    [
      "multi-line localized post-quake actions",
      ".fixedSize(horizontal: false, vertical: true)",
      ".lineLimit(1)",
    ],
  ]) {
    await withFixture(t, {}, async (root) => {
      const path = join(root, "ios/QuakeSignal/Features/Guide/DisasterGuideView.swift");
      const source = await readFile(path, "utf8");
      const mutated = source.replace(from, to);
      assert.notEqual(mutated, source, `${name} fixture mutation must apply`);
      await writeFile(path, mutated, "utf8");
      await assert.rejects(
        verifyIOSReleaseContract({ root }),
        /foreground-only Apple platform policy must match the reviewed fingerprint/i,
      );
    });
  }
  await withFixture(t, {}, async (root) => {
    const path = join(root, "ios/QuakeSignal/Resources/en.lproj/Localizable.strings");
    const source = await readFile(path, "utf8");
    await writeFile(
      path,
      source.replace('"platform.alertRegistration.foregroundOnly" = "Foreground monitoring only";', '"platform.alertRegistration.foregroundOnly" = "Foreground monitoring on Mac";'),
      "utf8",
    );
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /foreground-only Apple platform policy must match the reviewed fingerprint/i,
    );
  });
  for (const relativePath of [
    "ios/QuakeSignalTV/Supporting/PrivacyInfo.xcprivacy",
    "ios/QuakeSignalVision/Resources/PrivacyInfo.xcprivacy",
    "ios/QuakeSignalWatch/Supporting/PrivacyInfo.xcprivacy",
  ]) {
    for (const [from, to] of [
      ["<key>NSPrivacyTracking</key>\n\t<false/>", "<key>NSPrivacyTracking</key>\n\t<true/>"],
      ["<key>NSPrivacyCollectedDataTypes</key>\n\t<array/>", "<key>NSPrivacyCollectedDataTypes</key>\n\t<array><dict/></array>"],
      ["<string>CA92.1</string>", "<string>UNREVIEWED.1</string>"],
    ]) {
      await withFixture(t, {}, async (root) => {
        const path = join(root, relativePath);
        const source = await readFile(path, "utf8");
        const mutated = source.replace(from, to);
        assert.notEqual(mutated, source);
        await writeFile(path, mutated, "utf8");
        await assert.rejects(
          verifyIOSReleaseContract({ root }),
          /must declare tracking false, no tracking domains or collected data, and only UserDefaults accessed for reason CA92\.1/i,
        );
      });
    }
  }
});

test("fails closed when foreground lifecycle or nonpersistent Wolfx transport policy drifts", async (t) => {
  for (const [relativePath, from, to] of [
    [
      "ios/QuakeSignal/State/AlertPolicy.swift",
      "payload.hasUsableMatchingEventSnapshot && isSceneActive",
      "isSceneActive",
    ],
    [
      "ios/QuakeSignal/State/AlertPolicy.swift",
      "event.isActiveWarning && WarningFreshnessPolicy.isFresh(event, now: now)",
      "event.isActiveWarning",
    ],
    [
      "ios/QuakeSignal/Notifications/NotificationManager.swift",
      "self.isForegroundSceneActive &&\n                UIApplication.shared.applicationState == .active",
      "self.isForegroundSceneActive",
    ],
    [
      "ios/QuakeSignal/State/QuakeStore.swift",
      "let now = Date()\n        clockNow = now\n        merge(event)",
      "let now = clockNow\n        merge(event)",
    ],
    [
      "ios/QuakeSignal/Features/Root/RootView.swift",
      "store.ingestTapped(event: cached, reason: reason)",
      "store.presentedAlert = PresentedAlert(event: cached, reason: reason)",
    ],
    [
      "ios/QuakeSignal/Features/Map/EpicenterMapView.swift",
      "return .openSettings",
      "return .request",
    ],
    [
      "ios/QuakeSignal/State/LocationManager.swift",
      "let remainingLifetime = LocationFixPolicy.remainingLifetime(forTimestamp: timestamp)",
      "let remainingLifetime = LocationFixPolicy.maximumAge",
    ],
    [
      "ios/QuakeSignal/Models/EEWEvent.swift",
      "return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil",
      "return coordinate",
    ],
    [
      "ios/QuakeSignal/Networking/WolfxClient.swift",
      "guard isSceneActive else { return }",
      "guard pendingRequestID == nil else { return }",
    ],
    [
      "ios/QuakeSignalTV/TVDashboardView.swift",
      ".task(id: manualRefreshLifecycle.taskID(isSceneActive: scenePhase == .active))",
      ".task",
    ],
    [
      "ios/QuakeSignalTV/TVEmergencyMonitor.swift",
      "self.ingest(snapshot.events, isBackfill: true)",
      "self.ingest(snapshot.events, isBackfill: false)",
    ],
    [
      "ios/QuakeSignalTV/TVAlertPreferences.swift",
      "static func permitsAutomaticWarningPlayback(_ preference: AlertSoundPreference) -> Bool {\n        false\n    }",
      "static func permitsAutomaticWarningPlayback(_ preference: AlertSoundPreference) -> Bool {\n        true\n    }",
    ],
    [
      "ios/QuakeSignalWatch/WatchDashboardView.swift",
      ".task(id: manualRefreshLifecycle.taskID(isSceneActive: scenePhase == .active))",
      ".task",
    ],
    [
      "ios/QuakeSignalWatch/WatchForegroundEmergencyMonitor.swift",
      "self.ingest(snapshot.events, isBackfill: true)",
      "self.ingest(snapshot.events, isBackfill: false)",
    ],
    [
      "ios/QuakeSignalShared/WatchAlertPreferenceBridge.swift",
      "CFGetTypeID(number) == CFNumberGetTypeID()",
      "CFGetTypeID(number) == CFBooleanGetTypeID()",
    ],
    [
      "ios/QuakeSignal/State/QuakeStore.swift",
      "case .stopSocket:\n            liveSocket.stop()",
      "case .stopSocket:\n            liveSocket.start()",
    ],
    [
      "ios/QuakeSignal/Networking/ForegroundHTTPFallbackPolicy.swift",
      "static func shouldAcceptDirectEvent(isForegroundActive: Bool) -> Bool {\n        isForegroundActive\n    }",
      "static func shouldAcceptDirectEvent(isForegroundActive: Bool) -> Bool {\n        true\n    }",
    ],
    [
      "ios/QuakeSignal/Networking/WolfxClient.swift",
      "configuration.requestCachePolicy = .reloadIgnoringLocalCacheData",
      "configuration.requestCachePolicy = .returnCacheDataElseLoad",
    ],
  ]) {
    await withFixture(t, {}, async (root) => {
      const path = join(root, relativePath);
      const source = await readFile(path, "utf8");
      const mutated = source.replace(from, to);
      assert.notEqual(mutated, source);
      await writeFile(path, mutated, "utf8");
      await assert.rejects(
        verifyIOSReleaseContract({ root }),
        /foreground-only Apple platform policy must match the reviewed fingerprint/i,
      );
    });
  }
});

test("Settings explains the routine-only night toggle in every supported localization", async () => {
  const settingsView = await readFile(
    join(repositoryRoot, "ios/QuakeSignal/Features/Settings/SettingsView.swift"),
    "utf8",
  );
  assert.match(
    settingsView,
    /if PlatformCapabilities\.supportsAttestedAlertRegistration \{[\s\S]*Toggle\(isOn: \$settings\.notifyAtNight\) \{[\s\S]*Text\("settings\.notifyAtNight"\)[\s\S]*Text\("settings\.notifyAtNight\.detail"\)/,
  );

  const expectedCopy = new Map([
    [
      "en",
      [
        '"settings.notifyAtNight" = "Routine Reports at Night";',
        '"settings.notifyAtNight.detail" = "This toggle controls routine reports only. Emergency warnings remain eligible at night.";',
      ],
    ],
    [
      "ja",
      [
        '"settings.notifyAtNight" = "夜間の通常地震情報";',
        '"settings.notifyAtNight.detail" = "この設定は通常の地震情報にのみ適用されます。緊急警報は夜間も通知対象のままです。";',
      ],
    ],
    [
      "zh-Hans",
      [
        '"settings.notifyAtNight" = "夜间常规地震报告";',
        '"settings.notifyAtNight.detail" = "此开关仅控制常规地震报告。紧急预警在夜间仍属于可通知范围。";',
      ],
    ],
  ]);

  for (const [locale, requiredLines] of expectedCopy) {
    const source = await readFile(
      join(repositoryRoot, `ios/QuakeSignal/Resources/${locale}.lproj/Localizable.strings`),
      "utf8",
    );
    for (const requiredLine of requiredLines) {
      assert.equal(source.split("\n").filter((line) => line === requiredLine).length, 1);
    }
  }
});

test("tvOS and Watch manual refreshes are scene-bound instead of unstructured tasks", async () => {
  for (const [relativePath, refreshCall] of [
    ["ios/QuakeSignalTV/TVDashboardView.swift", "await store.refresh()"],
    ["ios/QuakeSignalWatch/WatchDashboardView.swift", "await store.refresh(limit: 12)"],
  ]) {
    const source = await readFile(join(repositoryRoot, relativePath), "utf8");
    assert.match(
      source,
      /\.task\(id: manualRefreshLifecycle\.taskID\(isSceneActive: scenePhase == \.active\)\)/,
    );
    assert.match(
      source,
      /guard manualRefreshLifecycle\.shouldRun\(isSceneActive: scenePhase == \.active\) else \{ return \}/,
    );
    assert.match(source, /manualRefreshLifecycle\.cancelPendingRefresh\(\)/);
    assert.match(source, /manualRefreshLifecycle\.requestRefresh\(isSceneActive: scenePhase == \.active\)/);
    assert.equal(source.includes(refreshCall), true);
    assert.doesNotMatch(source, /Task \{ await store\.refresh/);
  }
});

test("fails closed when Debug screenshot fixture gates drift", async (t) => {
  for (const [from, to] of [
    [
      "#if DEBUG && (targetEnvironment(simulator) || targetEnvironment(macCatalyst))\n        selectedFrame != nil",
      "#if DEBUG\n        selectedFrame != nil",
    ],
    [
      "#if DEBUG && (targetEnvironment(simulator) || targetEnvironment(macCatalyst))\n        guard let captureTarget = currentCaptureTarget else { return nil }",
      "#if targetEnvironment(simulator)\n        guard let captureTarget = currentCaptureTarget else { return nil }",
    ],
    [
      "#else\n        []\n#endif",
      "#else\n        fixtureEventsForRelease\n#endif",
    ],
  ]) {
    await withFixture(t, {}, async (root) => {
      const path = join(root, "ios/QuakeSignalShared/ScreenshotAutomation.swift");
      const source = await readFile(path, "utf8");
      const mutated = source.replace(from, to);
      assert.notEqual(mutated, source);
      await writeFile(path, mutated, "utf8");
      await assert.rejects(
        verifyIOSReleaseContract({ root }),
        /foreground-only Apple platform policy must match the reviewed fingerprint/i,
      );
    });
  }
});

test("fails closed on executable Xcode graph or shared-scheme injection", async (t) => {
  await withFixture(t, {}, async (root) => {
    const path = join(root, "ios/project.yml");
    const source = await readFile(path, "utf8");
    await writeFile(
      path,
      source.replace(
        "        Release:\n          CODE_SIGN_IDENTITY: Apple Distribution\n",
        "        Release:\n          SWIFT_EXEC: /tmp/unreviewed-compiler-wrapper\n          CODE_SIGN_IDENTITY: Apple Distribution\n",
      ),
      "utf8",
    );
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /Xcode Cloud guard XCODE_SOURCE_GRAPH_FINGERPRINT/i,
    );
  });
  await withFixture(t, {}, async (root) => {
    const path = join(root, "ios/QuakeSignal.xcodeproj/project.pbxproj");
    await writeFile(path, `${await readFile(path, "utf8")}\n/* PBXShellScriptBuildPhase */\n`, "utf8");
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /forbidden executable surface PBXShellScriptBuildPhase/i,
    );
  });
  await withFixture(t, {}, async (root) => {
    const path = join(root, "ios/QuakeSignal.xcodeproj/xcshareddata/xcschemes/QuakeSignal.xcscheme");
    await writeFile(path, `${await readFile(path, "utf8")}\n<!-- unreviewed scheme action -->\n`, "utf8");
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /shared archive schemes must match the reviewed fingerprint/i,
    );
  });
});

test("XML comments cannot impersonate the required bundle-version key", async (t) => {
  await withFixture(t, {}, async (root) => {
    const path = join(root, "ios/QuakeSignal/Supporting/Info.plist");
    const source = await readFile(path, "utf8");
    const commented = source.replace(
      "<key>CFBundleVersion</key>\n\t<string>$(CURRENT_PROJECT_VERSION)</string>",
      "<!-- <key>CFBundleVersion</key>\n\t<string>$(CURRENT_PROJECT_VERSION)</string> -->",
    );
    assert.notEqual(commented, source);
    await writeFile(
      path,
      commented,
      "utf8",
    );
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /Info\.plist CFBundleVersion must appear exactly once \(found 0\)/i,
    );
  });
});

test("foreground-only platform plists cannot acquire notification relay configuration", async (t) => {
  await withFixture(t, {}, async (root) => {
    const path = join(root, "ios/QuakeSignalVision/Supporting/Info.plist");
    const source = await readFile(path, "utf8");
    await writeFile(
      path,
      source.replace(
        "</dict>",
        "\t<key>QUAKESIGNAL_API_BASE_URL</key>\n\t<string>$(QUAKESIGNAL_API_BASE_URL)</string>\n</dict>",
      ),
      "utf8",
    );
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /foreground-only and must not embed Worker or App Attest configuration/i,
    );
  });
  await withFixture(t, {}, async (root) => {
    const path = join(root, "ios/QuakeSignalVision/Supporting/Info.plist");
    const source = await readFile(path, "utf8");
    await writeFile(
      path,
      source.replace(
        "show distance and nearby earthquake context while the app is open",
        "alert you about activity near you",
      ),
      "utf8",
    );
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /must disclose foreground-only location use exactly/i,
    );
  });
});

test("fails closed on npm release hooks or repository npm control files", async (t) => {
  await withFixture(t, {}, async (root) => {
    const path = join(root, "backend/cloudflare/package.json");
    const manifest = JSON.parse(await readFile(path, "utf8"));
    manifest.scripts["preverify:production-gates"] = "./node_modules/.bin/wrangler deploy --config attacker.jsonc";
    await writeFile(path, `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /npm lifecycle hook preverify:production-gates/i,
    );
  });
  await withFixture(t, {}, async (root) => {
    const path = join(root, "backend/cloudflare/package.json");
    const manifest = JSON.parse(await readFile(path, "utf8"));
    manifest.scripts.postprepare = "./node_modules/.bin/wrangler deploy --config attacker.jsonc";
    await writeFile(path, `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /npm lifecycle hook postprepare/i,
    );
  });
  await withFixture(t, {}, async (root) => {
    await writeFile(join(root, "backend/cloudflare/.npmrc"), "script-shell=./attacker.sh\n", "utf8");
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /backend\/cloudflare\/\.npmrc is forbidden/i,
    );
  });
  await withFixture(t, {}, async (root) => {
    await writeFile(join(root, "backend/cloudflare/npm-shrinkwrap.json"), "{}\n", "utf8");
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /npm-shrinkwrap\.json is forbidden/i,
    );
  });
});

test("fails closed on Worker dependency graph deletion, drift, or substitution", async (t) => {
  await withFixture(t, {}, async (root) => {
    await rm(join(root, "backend/cloudflare/package-lock.json"));
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /package-lock\.json must exist as a regular checked-in file/i,
    );
  });
  await withFixture(t, {}, async (root) => {
    const path = join(root, "backend/cloudflare/package-lock.json");
    await writeFile(path, `${await readFile(path, "utf8")}\n`, "utf8");
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /Worker npm dependency graph must match the reviewed fingerprint/i,
    );
  });
  await withFixture(t, {}, async (root) => {
    const path = join(root, "backend/cloudflare/package.json");
    const manifest = JSON.parse(await readFile(path, "utf8"));
    manifest.devDependencies.wrangler = "4.120.0";
    await writeFile(path, `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /Worker npm dependency graph must match the reviewed fingerprint/i,
    );
  });
  for (const key of ["workspaces", "overrides"]) {
    await withFixture(t, {}, async (root) => {
      const path = join(root, "backend/cloudflare/package.json");
      const manifest = JSON.parse(await readFile(path, "utf8"));
      manifest[key] = key === "workspaces" ? ["packages/*"] : { wrangler: "4.120.0" };
      await writeFile(path, `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
      await assert.rejects(
        verifyIOSReleaseContract({ root }),
        new RegExp(key, "i"),
      );
    });
  }
});

test("a future build is rejected until the Xcode Cloud guard is coordinated", async (t) => {
  await withFixture(t, {
    buildNumber: "11",
    allowedVersions: "1,2,3,4,5,6,7,8,9,10,11",
    workflowDefault: "11",
  }, async (root) => {
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /Xcode Cloud guard BUILD_NUMBER must match 11 \(received 10\)/i,
    );
  });
});

test("fails closed when App Store export options drift", async (t) => {
  await withFixture(t, {}, async (root) => {
    const path = join(root, "ios/AppStore/ExportOptions.plist");
    const source = await readFile(path, "utf8");
    await writeFile(path, source.replace("app-store-connect", "ad-hoc"), "utf8");
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /App Store export options\.method/i,
    );
  });
  await withFixture(t, {}, async (root) => {
    const path = join(root, "ios/AppStore/ExportOptions.plist");
    const source = await readFile(path, "utf8");
    await writeFile(path, source.replace("</dict>", "<key>uploadSymbols</key><string>true</string></dict>"), "utf8");
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /App Store export options must contain exactly/i,
    );
  });
});

test("fails closed on source/version drift", async (t) => {
  await withFixture(t, {
    buildNumber: "6",
    allowedVersions: "1,2,3,4,5,6",
    workflowDefault: "6",
  }, async (root) => {
    await assert.rejects(
      verifyIOSReleaseContract({ root, expectedBuildNumber: "5" }),
      /requested build_number 5 does not match ios\/project\.yml 6/i,
    );
  });
  await expectFailure(t, {
    buildNumber: "6",
    projectFileVersions: ["6", "5", "6"],
    allowedVersions: "1,2,3,4,5,6",
    workflowDefault: "6",
  }, /does not match ios\/project\.yml 6/i);
  await expectFailure(t, {
    buildNumber: "6",
    allowedVersions: "1,2,3,4,5",
    workflowDefault: "6",
  }, /must include ios\/project\.yml build 6/i);
  await withFixture(t, {}, async (root) => {
    const path = join(root, "ios/QuakeSignal/Supporting/Info.plist");
    const source = await readFile(path, "utf8");
    await writeFile(
      path,
      source.replace("$(CURRENT_PROJECT_VERSION)", "6"),
      "utf8",
    );
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /Info\.plist CFBundleVersion interpolation/i,
    );
  });
  await expectFailure(t, {
    buildNumber: "10",
    allowedVersions: "1,2,3,4,5,6,7,8,9,10",
    workflowDefault: "7",
  }, /build_number default 7 does not match ios\/project\.yml 10/i);
});

test("fails closed when the remote smoke changes origin or executable command", async (t) => {
  await expectFailure(
    t,
    { remoteOrigin: "${{ vars.UNRELATED_WORKER_URL }}" },
    /remote App Attest policy contract step\.env must be exactly/i,
  );
  await expectFailure(
    t,
    { remoteRunPrefix: "echo remote-smoke-was-skipped" },
    /remote App Attest policy contract step.run must be exactly/i,
  );
});

test("fails closed on quoted keys and intervening steps in the pre-secret sequence", async (t) => {
  await withFixture(t, {}, async (root) => {
    const path = join(root, ".github/workflows/ios.yml");
    const contents = await readFile(path, "utf8");
    await writeFile(
      path,
      contents.replace(
        "        id: release-contract\n",
        "        \"if\": ${{ github.ref == 'refs/heads/never' }}\n        id: release-contract\n",
      ),
      "utf8",
    );
    await assert.rejects(verifyIOSReleaseContract({ root }), /pre-signing release-contract step must contain exactly/i);
  });
  await withFixture(t, {}, async (root) => {
    const path = join(root, ".github/workflows/ios.yml");
    const contents = await readFile(path, "utf8");
    await writeFile(
      path,
      contents.replace(
        "      - name: Verify production notification origin readiness and contract\n",
        "      - name: Mutate smoke helper\n        run: true\n      - name: Verify production notification origin readiness and contract\n",
      ),
      "utf8",
    );
      await assert.rejects(verifyIOSReleaseContract({ root }), /must run exact checkout, immutable-source validation, static release contract, and remote policy smoke consecutively/i);
  });
});

test("fails closed when the protected signing lane or dispatch consent widens", async (t) => {
  const inTestflight = (contents, from, to) => {
    const marker = "  testflight:\n";
    const offset = contents.indexOf(marker);
    assert.notEqual(offset, -1, "fixture must contain the TestFlight job");
    return `${contents.slice(0, offset)}${contents.slice(offset).replace(from, to)}`;
  };
  const mutations = [
    (contents) => inTestflight(contents, "      github.ref_protected\n", "      true\n"),
    (contents) => inTestflight(contents, "    runs-on: macos-latest\n", "    runs-on: self-hosted\n"),
    (contents) => inTestflight(contents, "      name: ios-app-store-release\n", "      name: unprotected-upload-lane\n"),
    (contents) => contents.replace("  contents: read\n", "  contents: write\n"),
    (contents) => contents.replace(
      "  cancel-in-progress: ${{ github.event_name != 'workflow_dispatch' }}\n",
      "  cancel-in-progress: true\n",
    ),
    (contents) => contents.replace(
      "      archive_only:\n        description: Archive, verify, and hash a signed IPA without retaining or uploading it\n        required: false\n        default: false\n        type: boolean\n",
      "      archive_only:\n        description: Archive, verify, and hash a signed IPA without retaining or uploading it\n        required: false\n        default: true\n        type: boolean\n",
    ),
  ];
  for (const mutate of mutations) {
    await withFixture(t, {}, async (root) => {
      const path = join(root, ".github/workflows/ios.yml");
      await writeFile(path, mutate(await readFile(path, "utf8")), "utf8");
      await assert.rejects(
        verifyIOSReleaseContract({ root }),
        /testflight job header|workflow permissions|workflow concurrency|archive_only input/i,
      );
    });
  }
});

test("fails closed on effective YAML defaults, aliases, escapes, and duplicate keys", async (t) => {
  for (const mutation of [
    (contents) => `${contents}defaults:\n  run:\n    shell: /usr/bin/true {0}\n`,
    (contents) => contents.replace(
      "jobs:\n",
      "jobs:\n  test:\n    env: &presecret\n      LEAK: \"${{ secrets.TEST }}\"\n    steps: []\n",
    ).replace("  testflight:\n", "  testflight:\n    env: *presecret\n"),
    (contents) => contents.replace(
      "  XCODEGEN_SHA256: 4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806\n",
      "  XCODEGEN_SHA256: 4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806\n  LEAK: \"${{ secre\\u0074s.TEST }}\"\n",
    ),
    (contents) => contents.replace(
      "  XCODE_SCHEME: QuakeSignal\n",
      "  XCODE_SCHEME: QuakeSignal\n  XCODE_SCHEME: Replacement\n",
    ),
  ]) {
    await withFixture(t, {}, async (root) => {
      const path = join(root, ".github/workflows/ios.yml");
      await writeFile(path, mutation(await readFile(path, "utf8")), "utf8");
      await assert.rejects(verifyIOSReleaseContract({ root }), /workflow-level defaults|testflight job header|workflow env|safe, duplicate-free YAML/i);
    });
  }
});

test("fails closed when the public archive drifts from reviewed Release arguments", async (t) => {
  await expectFailure(
    t,
    { archiveConfiguration: "InternalQA" },
    /signed archive step.run must be exactly/i,
  );
});

test("fails closed when a post-smoke step can alter the signed artifact sequence", async (t) => {
  for (const overwrite of [
    "        run: xcodebuild archive -configuration InternalQA -archivePath \"$RUNNER_TEMP/QuakeSignal.xcarchive\"\n",
    "        run: tool=xcodebuild; \"$tool\" archive -configuration InternalQA -archivePath \"$RUNNER_TEMP/QuakeSignal.xcarchive\"\n",
    "        run: printf 'mutated' > ios/project.yml\n",
  ]) {
    await withFixture(t, {}, async (root) => {
      const path = join(root, ".github/workflows/ios.yml");
      await writeFile(
        path,
        `${await readFile(path, "utf8")}      - name: Overwrite signed archive\n${overwrite}`,
        "utf8",
      );
      await assert.rejects(
        verifyIOSReleaseContract({ root }),
        /post-remote signing sequence must match the reviewed fingerprint/i,
      );
    });
  }
});

test("fails closed when iOS IPA export, digest binding, or App Store coordinates drift", async (t) => {
  const mutations = [
    [
      "Add :manageAppVersionAndBuildNumber bool false",
      "Add :manageAppVersionAndBuildNumber bool true",
    ],
    [
      'ipas=("$export_path"/*.ipa)',
      'ipas=("$export_path"/*)',
    ],
    [
      '[ "${#ipas[@]}" -ne 1 ]',
      '[ "${#ipas[@]}" -lt 1 ]',
    ],
    [
      '[ "${#unexpected[@]}" -ne 0 ]',
      'false',
    ],
    [
      '[ ! -f "${ipas[0]:-}" ]',
      '[ ! -e "${ipas[0]:-}" ]',
    ],
    [
      '[ -L "${ipas[0]:-}" ]',
      'false',
    ],
    [
      'ipa_sha256="$(/usr/bin/shasum -a 256 "$IPA_PATH")"',
      'ipa_sha256="0000000000000000000000000000000000000000000000000000000000000000"',
    ],
    [
      'echo "IPA_SHA256=$ipa_sha256" >> "$GITHUB_ENV"',
      'echo "IPA_SHA256=unreviewed" >> "$GITHUB_ENV"',
    ],
    [
      "          IOS_ALTOOL_PLATFORM: ios\n",
      "          IOS_ALTOOL_PLATFORM: watchos\n",
    ],
    [
      '            --platform "$IOS_ALTOOL_PLATFORM"\n',
      '            --type "$IOS_ALTOOL_PLATFORM"\n',
    ],
    [
      '          APP_STORE_CONNECT_APPLE_ID: "6800642443"\n',
      '          APP_STORE_CONNECT_APPLE_ID: "6800642853"\n',
    ],
    [
      "          IOS_BUNDLE_IDENTIFIER: com.quakesignal.app\n",
      "          IOS_BUNDLE_IDENTIFIER: com.quakesignal.app.watchkitapp\n",
    ],
    [
      '--bundle-version "$BUILD_NUMBER"',
      '--bundle-version 7',
    ],
    [
      "--bundle-short-version-string 1.1",
      "--bundle-short-version-string 1.0",
    ],
    [
      'if [ "$upload_sha256" != "${IPA_SHA256:?Verified iOS IPA SHA-256 is missing}" ]; then',
      'if [ "$upload_sha256" != "$upload_sha256" ]; then',
    ],
    [
      'if [ "${IPA_VERIFIED:-false}" != true ]; then',
      'if false; then',
    ],
    [
      'xcrun altool --validate-app "$IPA_PATH" "${upload_arguments[@]}"',
      'xcrun altool --validate-app "/tmp/unreviewed.ipa" "${upload_arguments[@]}"',
    ],
    [
      'xcrun altool --upload-package "$IPA_PATH" "${upload_arguments[@]}"',
      'xcrun altool --upload-package "/tmp/unreviewed.ipa" "${upload_arguments[@]}"',
    ],
  ];

  for (const [from, to] of mutations) {
    await withFixture(t, {}, async (root) => {
      const path = join(root, ".github/workflows/ios.yml");
      const source = await readFile(path, "utf8");
      assert.ok(source.includes(from), `fixture must contain ${from}`);
      const mutated = source.replace(from, to);
      assert.notEqual(mutated, source, "iOS signed lane mutation must apply");
      await writeFile(path, mutated, "utf8");
      await assert.rejects(
        verifyIOSReleaseContract({ root }),
        /iOS workflow exported IPA|iOS signed artifact verifier|iOS App Store Connect upload|post-remote signing sequence/i,
      );
    });
  }
});

test("fails closed when a native signed release job reintroduces Actions retention", async (t) => {
  const cases = [
    [".github/workflows/ios.yml", "      - name: Remove signing material\n", "${{ env.IPA_PATH }}"],
    [".github/workflows/apple-platforms.yml", "      - name: Remove signing material\n", "${{ env.APPLE_ARTIFACT_PATH }}"],
  ];
  for (const [relativePath, cleanupMarker, artifactPath] of cases) {
    await withFixture(t, {}, async (root) => {
      const path = join(root, relativePath);
      const source = await readFile(path, "utf8");
      assert.ok(source.includes(cleanupMarker), `fixture must contain cleanup marker in ${relativePath}`);
      const retained = [
        "      - name: Retain signed release binary",
        "        uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a",
        "        with:",
        "          name: forbidden-signed-release-binary",
        `          path: ${artifactPath}`,
        "",
      ].join("\n");
      await writeFile(path, source.replace(cleanupMarker, `${retained}${cleanupMarker}`), "utf8");
      await assert.rejects(
        verifyIOSReleaseContract({ root }),
        /must not retain signed release binaries as GitHub Actions artifacts/i,
      );
    });
  }
});

test("fails closed when a signed lane loses its immutable source checkout", async (t) => {
  for (const relativePath of [
    ".github/workflows/ios.yml",
    ".github/workflows/apple-platforms.yml",
  ]) {
    await withFixture(t, {}, async (root) => {
      const path = join(root, relativePath);
      const source = await readFile(path, "utf8");
      const immutableRef = "          ref: ${{ inputs.source_commit }}\n";
      assert.ok(source.includes(immutableRef), `fixture must contain immutable source checkout in ${relativePath}`);
      await writeFile(
        path,
        source.replace(immutableRef, "          ref: ${{ github.sha }}\n"),
        "utf8",
      );
      await assert.rejects(
        verifyIOSReleaseContract({ root }),
        /checkout|immutable signed source|protected-release graph|release-job graph/i,
      );
    });
  }
});

test("fails closed when a sibling job can bypass the protected release lane", async (t) => {
  await withFixture(t, {}, async (root) => {
    const path = join(root, ".github/workflows/ios.yml");
    const contents = await readFile(path, "utf8");
    await writeFile(
      path,
      contents.replace(
        "jobs:\n",
        `jobs:
  unreviewed-upload:
    runs-on: macos-latest
    environment:
      name: ios-app-store-release
    steps:
      - run: xcrun altool --upload-package /tmp/other.ipa
`,
      ),
      "utf8",
    );
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /release-job graph fingerprint/i,
    );
  });
});

test("fails closed on new or modified sibling workflow release surfaces", async (t) => {
  await withFixture(t, {}, async (root) => {
    const path = join(root, ".github/workflows/unreviewed-release.yml");
    await writeFile(path, `name: Unreviewed release
on: workflow_dispatch
jobs:
  upload:
    runs-on: macos-latest
    environment: ios-app-store-release
    steps:
      - run: xcrun altool --upload-package /tmp/unreviewed.ipa
`, "utf8");
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /workflow inventory must be exactly the reviewed set/i,
    );
  });
  await withFixture(t, {}, async (root) => {
    const path = join(root, ".github/workflows/desktop-build.yml");
    const source = await readFile(path, "utf8");
    await writeFile(
      path,
      `${source}
  constructed-release-bypass:
    runs-on: ubuntu-latest
    environment: \${{ format('{0}-{1}', 'ios-app-store', 'release') }}
    env:
      ALL_SECRETS: \${{ toJSON(secrets) }}
    steps:
      - run: true
`,
      "utf8",
    );
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /complete workflow directory must match the reviewed parsed-content fingerprint/i,
    );
  });
  await withFixture(t, {}, async (root) => {
    const path = join(root, ".github/workflows/desktop-build.yml");
    const source = await readFile(path, "utf8");
    await writeFile(path, source.replace("permissions:\n  contents: read\n", "permissions: write-all\n"), "utf8");
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /scalar write-all\/read-all permissions are forbidden/i,
    );
  });
  await withFixture(t, {}, async (root) => {
    const path = join(root, ".github/workflows/cloudflare-staging.yml");
    const source = await readFile(path, "utf8");
    const from = "          CLOUDFLARE_STAGING_WORKER_NAME: ${{ vars.CLOUDFLARE_STAGING_WORKER_NAME }}\n";
    assert.ok(source.includes(from));
    await writeFile(path, source.replace(from, "          CLOUDFLARE_STAGING_WORKER_NAME: quakesignal-api\n"), "utf8");
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /credential-bearing workflows must match the reviewed fingerprint|complete workflow directory/i,
    );
  });
  await withFixture(t, {}, async (root) => {
    const path = join(root, ".github/workflows/cloudflare-staging.yml");
    const source = await readFile(path, "utf8");
    assert.ok(source.includes("        run: npm ci --ignore-scripts\n"));
    await writeFile(path, source.replace("        run: npm ci --ignore-scripts\n", "        run: npm ci\n"), "utf8");
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /credential-bearing workflows must match the reviewed fingerprint|complete workflow directory/i,
    );
  });
});

test("fails closed on workflow_call scalars and YAML on/true trigger collisions", async (t) => {
  const dispatchBlock = `on:
  workflow_dispatch:
    inputs:
      apply_incident_disposition:
        description: Resolve only the reviewed, expired APNs-environment incident records
        required: false
        default: false
        type: boolean
`;
  await withFixture(t, {}, async (root) => {
    const path = join(root, ".github/workflows/apns-incident-disposition.yml");
    const source = await readFile(path, "utf8");
    assert.ok(source.includes(dispatchBlock));
    await writeFile(path, source.replace(dispatchBlock, "on: workflow_call\n"), "utf8");
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /workflow_call release bypass/i,
    );
  });
  await withFixture(t, {}, async (root) => {
    const path = join(root, ".github/workflows/apns-incident-disposition.yml");
    const source = await readFile(path, "utf8");
    assert.ok(source.includes(dispatchBlock));
    const collision = `on:
  push:
    branches: [main]
${dispatchBlock.replace(/^on:/, "true:")}`;
    await writeFile(path, source.replace(dispatchBlock, collision), "utf8");
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /raw path-and-source fingerprint/i,
    );
  });
});

test("fails closed when a production deploy can race the TestFlight policy proof", async (t) => {
  await withFixture(t, {}, async (root) => {
    const path = join(root, ".github/workflows/cloudflare.yml");
    await writeFile(
      path,
      (await readFile(path, "utf8")).replace(
        "      group: quakesignal-production-app-attest-policy\n",
        "      group: cloudflare-worker-${{ github.ref }}\n",
      ),
      "utf8",
    );
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /Cloudflare deploy-production job header\.concurrency/i,
    );
  });
});

test("fails closed when production post-deploy smoke omits the exact reviewed App Attest policy", async (t) => {
  await withFixture(t, {}, async (root) => {
    const path = join(root, ".github/workflows/cloudflare.yml");
    const source = await readFile(path, "utf8");
    const exactSmoke = [
      "          node scripts/smoke-test.mjs \"$WORKER_URL\" \\",
      "            --expected-app-attest-policy-fingerprint \"${{ steps.release-contract.outputs.app_attest_policy_fingerprint }}\" \\",
      "            --required-app-attest-bundle-version \"${{ steps.release-contract.outputs.build_number }}\"",
    ].join("\n");
    assert.ok(source.includes(exactSmoke));
    await writeFile(
      path,
      source.replace(exactSmoke, "          node scripts/smoke-test.mjs \"$WORKER_URL\""),
      "utf8",
    );
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /Cloudflare workflow jobs must match the reviewed production-release graph fingerprint/i,
    );
  });
});

test("fails closed when another Cloudflare job can change policy outside the lock", async (t) => {
  await withFixture(t, {}, async (root) => {
    const path = join(root, ".github/workflows/cloudflare.yml");
    const contents = await readFile(path, "utf8");
    await writeFile(
      path,
      contents.replace(
        "jobs:\n",
        `jobs:
  unreviewed-production-deploy:
    runs-on: ubuntu-latest
    environment:
      name: cloudflare-production
    steps:
      - run: npx wrangler deploy
`,
      ),
      "utf8",
    );
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /Cloudflare workflow jobs must match the reviewed production-release graph fingerprint/i,
    );
  });
});

test("fails closed when Worker validation omits the historical APNs incident guard", async (t) => {
  await withFixture(t, {}, async (root) => {
    const path = join(root, ".github/workflows/cloudflare.yml");
    const contents = await readFile(path, "utf8");
    const guard = `
      - name: Test historical APNs incident disposition guard
        working-directory: backend/cloudflare
        run: npm run test:historical-apns-incident-disposition
`;
    assert.match(contents, new RegExp(guard.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
    await writeFile(path, contents.replace(guard, "\n"), "utf8");
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /Cloudflare workflow jobs must match the reviewed production-release graph fingerprint/i,
    );
  });
});

test("fails closed when a JSONC comment impersonates the Worker allow-list", async (t) => {
  await withFixture(t, { workerConfigSuffix: "\n// \"APP_ATTEST_ALLOWED_BUNDLE_VERSIONS\": \"1,2,3,4,5,6,7,8,9,10\"" }, async (root) => {
    const path = join(root, "backend/cloudflare/wrangler.jsonc");
    const contents = await readFile(path, "utf8");
    await writeFile(path, contents.replace('    "APP_ATTEST_ALLOWED_BUNDLE_VERSIONS": "1,2,3,4,5,6,7,8,9,10",\n', ""), "utf8");
    await assert.rejects(verifyIOSReleaseContract({ root }), /must be defined exactly once outside comments/i);
  });
});

test("fails closed when the frozen production Worker deployment topology drifts", async (t) => {
  for (const [from, to] of [
    ['"main": "src/index.ts"', '"main": "src/unreviewed.ts"'],
    ['"ALERT_DELIVERY_QUEUE_NAME": "quakesignal-alert-delivery"', '"ALERT_DELIVERY_QUEUE_NAME": "unreviewed-alert-delivery"'],
  ]) {
    await withFixture(t, {}, async (root) => {
      const path = join(root, "backend/cloudflare/wrangler.jsonc");
      const source = await readFile(path, "utf8");
      assert.ok(source.includes(from));
      await writeFile(path, source.replace(from, to), "utf8");
      await assert.rejects(
        verifyIOSReleaseContract({ root }),
        /production Worker deployment configuration must match the reviewed fingerprint/i,
      );
    });
  }
});

test("fails closed when the reviewed App Attest APNs route is missing, changed, expanded, or wrong", async (t) => {
  const watchRoute = {
    appIdentity: "5TT564H883.com.quakesignal.app.watchkitapp",
    apnsTopic: "com.quakesignal.app.watchkitapp",
    platform: "watchos",
  };
  const mutations = [
    (vars) => delete vars.APP_ATTEST_APNS_ROUTES,
    (vars) => {
      vars.APP_ATTEST_APNS_ROUTES = JSON.stringify([
        { ...reviewedAppIdentityRoutes[0], platform: "ipados" },
      ]);
    },
    (vars) => {
      vars.APP_ATTEST_APNS_ROUTES = JSON.stringify([
        ...reviewedAppIdentityRoutes,
        watchRoute,
      ]);
    },
    (vars) => {
      vars.APP_ATTEST_APNS_ROUTES = JSON.stringify([
        { ...reviewedAppIdentityRoutes[0], apnsTopic: "com.quakesignal.wrong" },
      ]);
    },
  ];
  for (const mutate of mutations) {
    await withFixture(t, {}, async (root) => {
      const path = join(root, "backend/cloudflare/wrangler.jsonc");
      const source = await readFile(path, "utf8");
      const routeLine = '    "APP_ATTEST_APNS_ROUTES": "[{\\"appIdentity\\":\\"5TT564H883.com.quakesignal.app\\",\\"apnsTopic\\":\\"com.quakesignal.app\\",\\"platform\\":\\"ios\\"}]",\n';
      assert.ok(source.includes(routeLine));
      const variables = { APP_ATTEST_APNS_ROUTES: reviewedAppIdentityRoutesJSON };
      mutate(variables);
      const replacement = variables.APP_ATTEST_APNS_ROUTES === undefined
        ? ""
        : `    "APP_ATTEST_APNS_ROUTES": ${JSON.stringify(variables.APP_ATTEST_APNS_ROUTES)},\n`;
      await writeFile(path, source.replace(routeLine, replacement), "utf8");
      await assert.rejects(
        verifyIOSReleaseContract({ root }),
        /APP_ATTEST_APNS_ROUTES/i,
      );
    });
  }
});

test("fails closed when a native platform release gate or selected profile mapping widens", async (t) => {
  const mutations = [
    (contents) => contents.replace(
      "      github.ref_protected\n",
      "      true\n",
    ),
    (contents) => contents.replace(
      "      name: ios-app-store-release\n",
      "      name: unprotected-native-platform-release\n",
    ),
    (contents) => contents.replace(
      "TVOS_APP_STORE_PROVISIONING_PROFILE' || inputs.platform == 'visionos' && 'VISIONOS_APP_STORE_PROVISIONING_PROFILE",
      "UNREVIEWED_PROFILE' || inputs.platform == 'visionos' && 'VISIONOS_APP_STORE_PROVISIONING_PROFILE",
    ),
    (contents) => contents.replace(
      "jobs:\n  release:\n",
      "jobs:\n  bypass-upload:\n    runs-on: macos-latest\n    steps:\n      - run: xcrun altool --upload-package /tmp/bypass.ipa\n  release:\n",
    ),
  ];
  for (const mutate of mutations) {
    await withFixture(t, {}, async (root) => {
      const path = join(root, ".github/workflows/apple-platforms.yml");
      const source = await readFile(path, "utf8");
      const mutated = mutate(source);
      assert.notEqual(mutated, source, "native platform release mutation must apply");
      await writeFile(path, mutated, "utf8");
      await assert.rejects(
        verifyIOSReleaseContract({ root }),
        /native platform release job header|reviewed protected release job|protected-release graph fingerprint/i,
      );
    });
  }
});

test("fails closed when the Mac Catalyst signed-package route drifts", async (t) => {
  const mutations = [
    ["          - maccatalyst\n", ""],
    [
      "'generic/platform=macOS,variant=Mac Catalyst' }}",
      "'generic/platform=macOS' }}",
    ],
    [
      "'MACCATALYST_APP_STORE_PROVISIONING_PROFILE' }}",
      "'UNREVIEWED_CATALYST_PROFILE' }}",
    ],
    [
      "secrets.MACCATALYST_APP_STORE_INSTALLER_CERTIFICATE || ''",
      "secrets.UNREVIEWED_INSTALLER_CERTIFICATE || ''",
    ],
    [
      "vars.MACCATALYST_APP_STORE_INSTALLER_IDENTITY || ''",
      "vars.UNREVIEWED_INSTALLER_IDENTITY || ''",
    ],
    [
      "inputs.platform == 'visionos' && 'visionos' || 'macos'",
      "inputs.platform == 'visionos' && 'visionos' || 'ios'",
    ],
    [
      "Add :manageAppVersionAndBuildNumber bool false",
      "Add :manageAppVersionAndBuildNumber bool true",
    ],
    [
      '[ ! -f "${artifacts[0]:-}" ]',
      '[ ! -e "${artifacts[0]:-}" ]',
    ],
    [
      '[ "${#artifacts[@]}" -ne 1 ]',
      '[ "${#artifacts[@]}" -lt 1 ]',
    ],
    [
      '[ "${#unexpected[@]}" -ne 0 ]',
      'false',
    ],
    [
      '[ -L "${artifacts[0]:-}" ]',
      'false',
    ],
    [
      "Add :installerSigningCertificate string $PLATFORM_INSTALLER_IDENTITY",
      "Add :installerSigningCertificate string Unreviewed Installer",
    ],
    [
      "code_sign_style=Manual",
      "code_sign_style=Automatic",
    ],
    [
      "code_sign_style=Manual",
      "signing_arguments=()\n          code_sign_style=Manual",
    ],
    [
      'QUAKESIGNAL_CATALYST_PROFILE_NAME="$PLATFORM_PROFILE_NAME"',
      'QUAKESIGNAL_CATALYST_PROFILE_NAME="Unreviewed Catalyst Profile"',
    ],
    [
      "CODE_SIGN_IDENTITY='Apple Distribution'",
      "CODE_SIGN_IDENTITY='Apple Development'",
    ],
    [
      "verifier_arguments+=(--installer-identity",
      "verifier_arguments+=(--host-profile-name",
    ],
    [
      'xcrun altool --validate-app "$APPLE_ARTIFACT_PATH" "${upload_arguments[@]}"',
      'xcrun altool --validate-app "/tmp/unreviewed.pkg" "${upload_arguments[@]}"',
    ],
    [
      'xcrun altool --upload-package "$APPLE_ARTIFACT_PATH" "${upload_arguments[@]}"',
      'xcrun altool --upload-package "/tmp/unreviewed.pkg" "${upload_arguments[@]}"',
    ],
    [
      'APP_STORE_CONNECT_APPLE_ID: "6800642443"',
      'APP_STORE_CONNECT_APPLE_ID: "6800642853"',
    ],
    [
      'upload_sha256="$(/usr/bin/shasum -a 256 "$APPLE_ARTIFACT_PATH")"',
      'upload_sha256="${APPLE_ARTIFACT_SHA256}"',
    ],
    [
      'if [ "${APPLE_ARTIFACT_VERIFIED:-false}" != true ]; then',
      'if false; then',
    ],
  ];

  for (const [from, to] of mutations) {
    await withFixture(t, {}, async (root) => {
      const path = join(root, ".github/workflows/apple-platforms.yml");
      const source = await readFile(path, "utf8");
      assert.ok(source.includes(from), `fixture must contain ${from}`);
      const mutated = source.replace(from, to);
      assert.notEqual(mutated, source, "Mac Catalyst package mutation must apply");
      await writeFile(path, mutated, "utf8");
      await assert.rejects(
        verifyIOSReleaseContract({ root }),
        /native platform|credential-bearing workflows|workflow directory/i,
      );
    });
  }
});

test("fails closed when iOS loses its embedded Watch profile contract", async (t) => {
  await withFixture(t, {}, async (root) => {
    const path = join(root, ".github/workflows/ios.yml");
    const contents = await readFile(path, "utf8");
    await writeFile(
      path,
      contents.replace(
        "          WATCH_PROFILE: ${{ secrets.WATCHOS_APP_STORE_PROVISIONING_PROFILE }}\n",
        "          WATCH_PROFILE: ${{ secrets.UNRELATED_PROFILE }}\n",
      ),
      "utf8",
    );
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /post-remote signing sequence must match the reviewed fingerprint/i,
    );
  });
});

test("fails closed when the native target, bundle, or embedding matrix drifts", async (t) => {
  const mutations = [
    (contents) => contents.replace(
      "    CURRENT_PROJECT_VERSION: \"10\"\n",
      "    CURRENT_PROJECT_VERSION: \"10\"\n    TARGETED_DEVICE_FAMILY: \"1,2\"\n",
    ),
    (contents) => contents.replace(
      "        PRODUCT_BUNDLE_IDENTIFIER: com.quakesignal.app.watchkitapp\n",
      "        PRODUCT_BUNDLE_IDENTIFIER: com.quakesignal.app.unreviewed\n",
    ),
    (contents) => contents.replace(
      "        embed: true\n",
      "        embed: false\n",
    ),
    (contents) => contents.replace(
      "        SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD: NO\n",
      "        SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD: YES\n",
    ),
    (contents) => contents.replace(
      '        "ENABLE_APP_SANDBOX[sdk=macosx*]": YES\n',
      '        "ENABLE_APP_SANDBOX[sdk=macosx*]": NO\n',
    ),
  ];
  for (const mutate of mutations) {
    await withFixture(t, {}, async (root) => {
      const path = join(root, "ios/project.yml");
      await writeFile(path, mutate(await readFile(path, "utf8")), "utf8");
      await assert.rejects(
        verifyIOSReleaseContract({ root }),
        /target-scoped|PRODUCT_BUNDLE_IDENTIFIER|embedded Watch dependency|Mac Catalyst|Mac sandbox|Designed for iPad/i,
      );
    });
  }
});

test("fails closed when generic Apple platform coverage or credential-free signing changes", async (t) => {
  for (const [from, to] of [
    ["            destination: generic/platform=macOS,variant=Mac Catalyst\n", "            destination: generic/platform=iOS\n"],
    ["            scheme: QuakeSignalTV\n", "            scheme: QuakeSignal\n"],
    ["            destination: generic/platform=visionOS\n", "            destination: generic/platform=iOS\n"],
    [
      "            CODE_SIGNING_ALLOWED=NO | tee \"xcodebuild-$PLATFORM_KEY-generic-release.log\"",
      "            CODE_SIGNING_ALLOWED=YES | tee \"xcodebuild-$PLATFORM_KEY-generic-release.log\"",
    ],
  ]) {
    await withFixture(t, {}, async (root) => {
      const path = join(root, ".github/workflows/ios.yml");
      const contents = await readFile(path, "utf8");
      assert.ok(contents.includes(from), `fixture must contain ${from.trim()}`);
      await writeFile(path, contents.replace(from, to), "utf8");
      await assert.rejects(
        verifyIOSReleaseContract({ root }),
        /generic Apple platform build job header|generic credential-free build step|release-job graph fingerprint/i,
      );
    });
  }
});

test("fails closed when build or release jobs reintroduce Simulator downloads", async (t) => {
  for (const relativePath of [
    ".github/workflows/ios.yml",
    ".github/workflows/apple-platforms.yml",
  ]) {
    await withFixture(t, {}, async (root) => {
      const path = join(root, relativePath);
      const contents = await readFile(path, "utf8");
      const marker = "    steps:\n";
      assert.ok(contents.includes(marker), `${relativePath} fixture must contain job steps`);
      await writeFile(
        path,
        contents.replace(
          marker,
          `${marker}      - run: xcodebuild -downloadPlatform watchOS -architectureVariant arm64\n`,
        ),
        "utf8",
      );
      await assert.rejects(
        verifyIOSReleaseContract({ root }),
        /must not download Simulator runtimes/i,
      );
    });
  }
});

test("fails closed when the credential-free screenshot harness checks drift", async (t) => {
  for (const [from, to] of [
    [
      '          if [ "$host_architecture" != "x86_64" ]; then\n',
      '          if false; then # skipped x86_64 hosted-runner proof\n',
    ],
    [
      "          expected_xcode=$'Xcode 26.6\\nBuild version 17F113'\n",
      "          expected_xcode=\"$(xcodebuild -version)\" # skipped exact Xcode proof\n",
    ],
    [
      '             [ "$visible_height" -lt 800 ]; then\n',
      '             [ "$visible_height" -lt 1 ]; then # skipped logical-display capacity proof\n',
    ],
    [
      "          QUAKESIGNAL_TEST_TEMP_ROOT: ${{ runner.temp }}\n",
      "          QUAKESIGNAL_TEST_TEMP_ROOT: /tmp # skipped runner-scoped test temp root\n",
    ],
    [
      "          RUNNER_TEMP: ${{ runner.temp }}\n",
      "          RUNNER_TEMP: /tmp # skipped canonical runner temp root\n",
    ],
    [
      "          TMPDIR: ${{ runner.temp }}\n",
      "          TMPDIR: /tmp # skipped runner-scoped conventional temp root\n",
    ],
    [
      "          node .github/scripts/verify-ios-release-contract.mjs\n",
      "          true # skipped reviewed screenshot helper fingerprint\n",
    ],
    [
      "          bash -n ios/ScreenshotAutomation/capture-ios-screenshot-set.sh\n",
      "          true # skipped iOS/iPadOS atomic set syntax check\n",
    ],
    [
      "          /usr/bin/ruby ios/ScreenshotAutomation/ios-screenshot-plan.test.rb\n",
      "          true # skipped exact iOS/iPadOS frame-plan test\n",
    ],
    [
      "          /usr/bin/ruby -c ios/ScreenshotAutomation/ios-screenshot-simulator-lease.rb\n",
      "          true # skipped simulator lease helper syntax check\n",
    ],
    [
      "          /usr/bin/ruby -c ios/ScreenshotAutomation/ios-screenshot-simulator-lease.test.rb\n",
      "          true # skipped simulator lease test syntax check\n",
    ],
    [
      "          /usr/bin/ruby ios/ScreenshotAutomation/ios-screenshot-simulator-lease.test.rb\n",
      "          true # skipped simulator lease fail-closed test\n",
    ],
    [
      "          /usr/bin/ruby -c ios/ScreenshotAutomation/ios-screenshot-swift-inputs.rb\n",
      "          true # skipped Swift input allowlist helper syntax check\n",
    ],
    [
      "          /usr/bin/ruby -c ios/ScreenshotAutomation/ios-screenshot-swift-inputs.test.rb\n",
      "          true # skipped Swift input allowlist test syntax check\n",
    ],
    [
      "          /usr/bin/ruby ios/ScreenshotAutomation/ios-screenshot-swift-inputs.test.rb\n",
      "          true # skipped Swift input allowlist test\n",
    ],
    [
      "          /usr/bin/ruby -c ios/ScreenshotAutomation/safe-zip-tree.rb\n",
      "          true # skipped safe ZIP-tree helper syntax check\n",
    ],
    [
      "          /usr/bin/ruby -c ios/ScreenshotAutomation/safe-zip-tree.test.rb\n",
      "          true # skipped safe ZIP-tree test syntax check\n",
    ],
    [
      "          /usr/bin/ruby ios/ScreenshotAutomation/safe-zip-tree.test.rb\n",
      "          true # skipped safe ZIP-tree fail-closed test\n",
    ],
    [
      "          /usr/bin/ruby -c ios/ScreenshotAutomation/screenshot-test-temp-root.rb\n",
      "          true # skipped portable test temp-root helper syntax check\n",
    ],
    [
      "          test -f ios/ScreenshotAutomation/safe-zip-tree.rb\n",
      "          true # skipped safe ZIP-tree library mode check\n",
    ],
    [
      "          test -f ios/ScreenshotAutomation/screenshot-test-temp-root.rb\n",
      "          true # skipped portable test temp-root library mode check\n",
    ],
    [
      "          test -x ios/ScreenshotAutomation/ios-screenshot-simulator-lease.rb\n",
      "          true # skipped simulator lease executable mode check\n",
    ],
    [
      "          test -x ios/ScreenshotAutomation/ios-screenshot-simulator-lease.test.rb\n",
      "          true # skipped simulator lease test executable mode check\n",
    ],
    [
      "          test -x ios/ScreenshotAutomation/ios-screenshot-swift-inputs.rb\n",
      "          true # skipped Swift input helper executable mode check\n",
    ],
    [
      "          test -x ios/ScreenshotAutomation/ios-screenshot-swift-inputs.test.rb\n",
      "          true # skipped Swift input test executable mode check\n",
    ],
    [
      "          test -x ios/ScreenshotAutomation/safe-zip-tree.test.rb\n",
      "          true # skipped safe ZIP-tree test executable mode check\n",
    ],
    [
      "          /usr/bin/ruby ios/ScreenshotAutomation/assemble-ios-screenshot-provenance.test.rb\n",
      "          true # skipped iOS/iPadOS aggregate provenance test\n",
    ],
    [
      "          bash ios/ScreenshotAutomation/ios-screenshot-capture-interface.test.sh\n",
      "          true # skipped iOS/iPadOS atomic interface test\n",
    ],
    [
      "          bash -n ios/ScreenshotAutomation/watch-capture-guard.sh\n",
      "          true # skipped Watch capture guard syntax check\n",
    ],
    [
      "          bash -n ios/ScreenshotAutomation/vision-map-capture-guard.sh\n",
      "          true # skipped Vision semantic capture guard syntax check\n",
    ],
    [
      "          bash ios/ScreenshotAutomation/vision-map-capture-guard.test.sh\n",
      "          true # skipped Vision semantic capture guard test\n",
    ],
    [
      "          /usr/bin/ruby -c ios/ScreenshotAutomation/validate-vision-map-content.rb\n",
      "          true # skipped Vision semantic validator syntax check\n",
    ],
    [
      "          /usr/bin/ruby ios/ScreenshotAutomation/validate-vision-map-content.test.rb\n",
      "          true # skipped Vision semantic validator test\n",
    ],
    [
      "          bash ios/ScreenshotAutomation/watch-capture-guard.test.sh\n",
      "          true # skipped Watch capture process-supervisor test\n",
    ],
    [
      "          /usr/bin/ruby -c ios/ScreenshotAutomation/validate-watch-foreground-badge.rb\n",
      "          true # skipped Watch foreground badge validator syntax check\n",
    ],
    [
      "          /usr/bin/ruby ios/ScreenshotAutomation/validate-watch-foreground-badge.test.rb\n",
      "          true # skipped Watch foreground badge validator test\n",
    ],
    [
      "          /usr/bin/ruby ios/ScreenshotAutomation/platform-screenshot-plan.test.rb\n",
      "          true # skipped exact platform frame-plan test\n",
    ],
    [
      "          /usr/bin/ruby ios/ScreenshotAutomation/assemble-platform-screenshot-provenance.test.rb\n",
      "          true # skipped aggregate provenance test\n",
    ],
    [
      "          bash ios/ScreenshotAutomation/capture-platform-screenshot-interface.test.sh\n",
      "          true # skipped screenshot interface fail-closed test\n",
    ],
    [
      "              ios/ScreenshotAutomation/capture-platform-screenshot-set.sh \\\n" +
        "                \"$PLATFORM_KEY\" \"$artifact_dir\"\n",
      "          true # skipped exact planned screenshot set capture\n",
    ],
    [
      "              bash ios/ScreenshotAutomation/capture-ios-screenshot-set.sh \"$artifact_dir\"\n",
      "              true # skipped exact iOS/iPadOS screenshot set capture\n",
    ],
    [
      "          rm -- \"$manifest\"\n",
      "          true # skipped removal of the superseded initial seal\n",
    ],
    [
      "          /usr/bin/ruby ios/ScreenshotAutomation/seal-screenshot-capture-package.rb \\\n" +
        "            \"$PLATFORM_KEY\" \"$SOURCE_COMMIT\" \"$CANDIDATE_DIR\" \"$manifest\"\n",
      "          true # skipped final capture-package reseal\n",
    ],
    [
      "          /usr/bin/ditto -c -k --norsrc --keepParent \"$CANDIDATE_DIR\" \"$candidate_zip\"\n",
      "          true # skipped exact conventional raw-package ZIP\n",
    ],
    [
      "            ${{ env.CANDIDATE_ZIP }}\n",
      "            # skipped independent inner ZIP upload\n",
    ],
    [
      '          final_sha="$(git rev-parse --verify HEAD)"\n',
      '          final_sha="$GITHUB_SHA" # skipped final source revision proof\n',
    ],
    [
      '          final_status="$(git status --porcelain=v1 --untracked-files=all)"\n',
      '          final_status="" # skipped final clean-tree proof\n',
    ],
    [
      '          if [ -e "$debug_local_override" ] || [ -L "$debug_local_override" ]; then\n' +
        '            echo "::error::Ignored Debug.local.xcconfig appeared before screenshot artifact upload"\n' +
        '            exit 1\n' +
        '          fi\n',
      '          true # skipped final ignored Debug.local override rejection\n',
    ],
    [
      '          pre_capture_sha="$(git rev-parse --verify HEAD)"\n',
      '          pre_capture_sha="$GITHUB_SHA" # skipped source revision proof\n',
    ],
    [
      '          pre_capture_status="$(git status --porcelain=v1 --untracked-files=all)"\n',
      '          pre_capture_status="" # skipped clean-tree proof\n',
    ],
    [
      '          post_capture_sha="$(git rev-parse --verify HEAD)"\n',
      '          post_capture_sha="$GITHUB_SHA" # skipped post-capture revision proof\n',
    ],
    [
      '          post_capture_status="$(git status --porcelain=v1 --untracked-files=all)"\n',
      '          post_capture_status="" # skipped post-capture clean-tree proof\n',
    ],
    [
      '          if [ -e "$debug_local_override" ] || [ -L "$debug_local_override" ]; then\n',
      '          if [ -e "$debug_local_override" ]; then # dangling ignored override accepted\n',
    ],
    [
      "              debugLocalOverridePresent: false,\n",
      "              debugLocalOverridePresent: true,\n",
    ],
    [
      '          ios/ScreenshotAutomation/capture-maccatalyst-screenshot-set.sh "$artifact_dir"\n',
      "          true # skipped exact Mac Catalyst hierarchy set capture\n",
    ],
    [
      '                  response.fetch("captureApi") == "UIKit.UIView.drawHierarchy" &&\n',
      '                  response.fetch("captureApi") == "ScreenCaptureKit.SCScreenshotManager" &&\n',
    ],
    [
      '                  response.fetch("drawHierarchyComplete") == true &&\n',
      '                  response.fetch("drawHierarchyComplete") == false &&\n',
    ],
    [
      '                  response.fetch("postCaptureResizePerformed") == false &&\n',
      '                  response.fetch("postCaptureResizePerformed") == true &&\n',
    ],
    [
      '              abort "Catalyst capture request hash mismatch" unless\n',
      '              true # skipped Catalyst request hash binding\n',
    ],
  ]) {
    await withFixture(t, {}, async (root) => {
      const path = join(root, ".github/workflows/apple-platform-screenshots.yml");
      const contents = await readFile(path, "utf8");
      assert.ok(contents.includes(from), `screenshot workflow fixture must contain ${from.trim()}`);
      await writeFile(path, contents.replace(from, to), "utf8");
      await assert.rejects(
        verifyIOSReleaseContract({ root }),
        /native screenshot candidate workflow jobs must match the reviewed capture graph fingerprint/i,
      );
    });
  }
});

test("fails closed when hosted screenshot approval, run binding, or retention drifts", async (t) => {
  for (const [from, to] of [
    [
      '              expected_workflow_path?(run.fetch("path"), ".github/workflows/apple-platform-screenshots.yml")\n',
      '              true # skipped capture workflow path binding\n',
    ],
    [
      "            --require-build10-screenshot-release-ready \\\n",
      "            --require-build10-screenshot-release-ready=false \\\n",
    ],
    [
      "          retention-days: 3\n",
      "          retention-days: 30\n",
    ],
    [
      "          merge-multiple: false\n",
      "          merge-multiple: true\n",
    ],
    [
      '            fail!("post-download artifact records changed") unless second_artifacts == expected_records\n',
      '            fail!("post-download artifact records changed") unless true\n',
    ],
    [
      '              ENV.fetch("GITHUB_REPOSITORY") == "TastyHeadphones/QuakeSignal"\n',
      '              ENV.fetch("GITHUB_REPOSITORY") == "UntrustedFork/QuakeSignal"\n',
    ],
    [
      '              abort "#{kind} approval reviewer is a placeholder" if placeholder\n',
      '              abort "#{kind} approval reviewer is a placeholder" if false\n',
    ],
    [
      '              [expected, "#{expected}@main"].include?(actual)\n',
      '              actual.start_with?(expected) # unsafe workflow path normalization\n',
    ],
    [
      "              run_ids.values.uniq.length == 4\n",
      "              run_ids.values.uniq.length >= 3\n",
    ],
    [
      "                approved_logins.include?(login)\n",
      "                true # skipped protected-environment reviewer binding\n",
    ],
    [
      '                attestation.fetch("distributionMode") == "testflight-upload"\n',
      '                attestation.fetch("distributionMode") != "untrusted"\n',
    ],
    [
      '              records.values.map { |_run, artifact| artifact.fetch("sha256") }.uniq.length == 4\n',
      '              records.values.map { |_run, artifact| artifact.fetch("sha256") }.length >= 4\n',
    ],
  ]) {
    await withFixture(t, {}, async (root) => {
      const path = join(root, ".github/workflows/apple-screenshot-release-ready.yml");
      const source = await readFile(path, "utf8");
      assert.ok(source.includes(from), `release-ready screenshot fixture must contain ${from.trim()}`);
      await writeFile(path, source.replace(from, to), "utf8");
      await assert.rejects(
        verifyIOSReleaseContract({ root }),
        /Apple screenshot release-ready workflow|hosted approval graph fingerprint|complete workflow directory/i,
      );
    });
  }
});

test("fails closed when the Mac Catalyst capture runner or toolchain loses exact geometry capacity", async (t) => {
  for (const [from, to, error] of [
    [
      "    runs-on: macos-26-intel\n",
      "    runs-on: macos-latest\n",
      /Mac Catalyst screenshot capture must run on macos-26-intel/i,
    ],
    [
      "      DEVELOPER_DIR: /Applications/Xcode_26.6.app/Contents/Developer\n",
      "      DEVELOPER_DIR: /Applications/Xcode.app/Contents/Developer\n",
      /Mac Catalyst screenshot capture toolchain/i,
    ],
    [
      "    runs-on: macos-26-intel\n    timeout-minutes: 90\n",
      "    runs-on: macos-26-intel\n    timeout-minutes: 30\n",
      /Mac Catalyst screenshot capture timeout must remain 90 minutes/i,
    ],
  ]) {
    await withFixture(t, {}, async (root) => {
      const path = join(root, ".github/workflows/apple-platform-screenshots.yml");
      const contents = await readFile(path, "utf8");
      assert.ok(contents.includes(from), `screenshot workflow fixture must contain ${from.trim()}`);
      await writeFile(path, contents.replace(from, to), "utf8");
      await assert.rejects(verifyIOSReleaseContract({ root }), error);
    });
  }
});

test("fails closed when normal push and pull-request lint omits a Vision screenshot guard", async (t) => {
  for (const command of [
    "          bash -n ios/ScreenshotAutomation/vision-map-capture-guard.sh\n",
    "          bash -n ios/ScreenshotAutomation/vision-map-capture-guard.test.sh\n",
    "          /usr/bin/ruby -c ios/ScreenshotAutomation/validate-vision-map-content.rb\n",
    "          /usr/bin/ruby -c ios/ScreenshotAutomation/validate-vision-map-content.test.rb\n",
    "          bash ios/ScreenshotAutomation/vision-map-capture-guard.test.sh\n",
    "          /usr/bin/ruby ios/ScreenshotAutomation/validate-vision-map-content.test.rb\n",
  ]) {
    await withFixture(t, {}, async (root) => {
      const path = join(root, ".github/workflows/workflow-lint.yml");
      const contents = await readFile(path, "utf8");
      assert.ok(contents.includes(command), `workflow-lint fixture must contain ${command.trim()}`);
      await writeFile(path, contents.replaceAll(command, ""), "utf8");
      await assert.rejects(
        verifyIOSReleaseContract({ root }),
        /complete workflow directory must match the reviewed parsed-content fingerprint/i,
      );
    });
  }
});

test("fails closed when normal push and pull-request lint omits an iOS screenshot guard", async (t) => {
  for (const command of [
    "      - \"ios/AppStore/**\"\n",
    "      - \"ios/ScreenshotAutomation/**\"\n",
    "          QUAKESIGNAL_TEST_TEMP_ROOT: ${{ runner.temp }}\n",
    "          RUNNER_TEMP: ${{ runner.temp }}\n",
    "          TMPDIR: ${{ runner.temp }}\n",
    "          bash -n ios/ScreenshotAutomation/capture-ios-screenshot-set.sh\n",
    "          /usr/bin/ruby -c ios/ScreenshotAutomation/ios-screenshot-build-binding.rb\n",
    "          /usr/bin/ruby -c ios/ScreenshotAutomation/ios-screenshot-simulator-lease.rb\n",
    "          /usr/bin/ruby -c ios/ScreenshotAutomation/ios-screenshot-simulator-lease.test.rb\n",
    "          /usr/bin/ruby -c ios/ScreenshotAutomation/ios-screenshot-swift-inputs.rb\n",
    "          /usr/bin/ruby -c ios/ScreenshotAutomation/ios-screenshot-swift-inputs.test.rb\n",
    "          /usr/bin/ruby -c ios/ScreenshotAutomation/safe-zip-tree.rb\n",
    "          /usr/bin/ruby -c ios/ScreenshotAutomation/safe-zip-tree.test.rb\n",
    "          /usr/bin/ruby -c ios/ScreenshotAutomation/screenshot-test-temp-root.rb\n",
    "          /usr/bin/ruby ios/ScreenshotAutomation/ios-screenshot-plan.test.rb\n",
    "          /usr/bin/ruby ios/ScreenshotAutomation/ios-screenshot-simulator-lease.test.rb\n",
    "          /usr/bin/ruby ios/ScreenshotAutomation/ios-screenshot-swift-inputs.test.rb\n",
    "          /usr/bin/ruby ios/ScreenshotAutomation/assemble-ios-screenshot-provenance.test.rb\n",
    "          bash ios/ScreenshotAutomation/ios-screenshot-capture-interface.test.sh\n",
    "          bash ios/ScreenshotAutomation/screenshot-process-guard.test.sh\n",
    "          /usr/bin/ruby ios/ScreenshotAutomation/safe-zip-tree.test.rb\n",
    "          /usr/bin/ruby -c .github/scripts/assemble-apple-screenshot-release-set.rb\n",
    "          /usr/bin/ruby -c .github/scripts/assemble-apple-screenshot-release-set.test.rb\n",
    "          /usr/bin/ruby -c .github/scripts/verify-apple-screenshot-release-set.rb\n",
    "          /usr/bin/ruby -c .github/scripts/verify-apple-screenshot-release-set.test.rb\n",
    "          /usr/bin/ruby .github/scripts/assemble-apple-screenshot-release-set.test.rb\n",
    "          /usr/bin/ruby .github/scripts/verify-apple-screenshot-release-set.test.rb\n",
    "          /usr/bin/ruby .github/scripts/verify-apple-screenshot-release-set.rb\n",
  ]) {
    await withFixture(t, {}, async (root) => {
      const path = join(root, ".github/workflows/workflow-lint.yml");
      const contents = await readFile(path, "utf8");
      assert.ok(contents.includes(command), `workflow-lint fixture must contain ${command.trim()}`);
      await writeFile(path, contents.replaceAll(command, ""), "utf8");
      await assert.rejects(
        verifyIOSReleaseContract({ root }),
        /complete workflow directory must match the reviewed parsed-content fingerprint/i,
      );
    });
  }
});

test("fails closed when normal push and pull-request lint omits foreground TV emergency coverage", async (t) => {
  for (const command of [
    "      - \"ios/QuakeSignalShared/**\"\n",
    "      - \"ios/QuakeSignalTests/**\"\n",
    "      - \"ios/QuakeSignalTV/**\"\n",
    "      - \"ios/QuakeSignalTVTests/**\"\n",
    "      - \"ios/QuakeSignalWatch/**\"\n",
    "            ios/QuakeSignalTV/TVEmergencyPresentationPolicy.swift \\\n",
    "            ios/QuakeSignalTVTests/TVEmergencyPresentationPolicyStandaloneTests.swift \\\n",
    "          \"$RUNNER_TEMP/tvos-emergency-policy-tests\"\n",
    "            ios/QuakeSignalShared/AlertSoundPreference.swift \\\n",
    "            ios/QuakeSignalTV/TVAlertPreferences.swift \\\n",
    "            ios/QuakeSignalTVTests/TVAlertAudioPolicyStandaloneTests.swift \\\n",
    "          \"$RUNNER_TEMP/tvos-alert-audio-policy-tests\"\n",
    "          /usr/bin/ruby -c ios/QuakeSignalTVTests/tvos-emergency-interface.test.rb\n",
    "          /usr/bin/ruby ios/QuakeSignalTVTests/tvos-emergency-interface.test.rb\n",
  ]) {
    await withFixture(t, {}, async (root) => {
      const path = join(root, ".github/workflows/workflow-lint.yml");
      const contents = await readFile(path, "utf8");
      assert.ok(contents.includes(command), `workflow-lint fixture must contain ${command.trim()}`);
      await writeFile(path, contents.replaceAll(command, ""), "utf8");
      await assert.rejects(
        verifyIOSReleaseContract({ root }),
        /complete workflow directory must match the reviewed parsed-content fingerprint/i,
      );
    });
  }
});

test("fails closed when the native Apple screenshot harness is assigned to a non-macOS runner", async (t) => {
  await withFixture(t, {}, async (root) => {
    const path = join(root, ".github/workflows/workflow-lint.yml");
    const contents = await readFile(path, "utf8");
    assert.ok(contents.includes("    runs-on: macos-latest\n"));
    await writeFile(path, contents.replace("    runs-on: macos-latest\n", "    runs-on: ubuntu-latest\n"), "utf8");
    await assert.rejects(
      verifyIOSReleaseContract({ root }),
      /native Apple screenshot harness must run on macos-latest/i,
    );
  });
});

test("fails closed when the normal lint runner's pinned Go toolchain is missing or drifts", async (t) => {
  const setupGo = `      - name: Set up Go
        uses: actions/setup-go@924ae3a1cded613372ab5595356fb5720e22ba16 # v6
        with:
          go-version: "1.25.0"
          cache: false

`;
  const runActionlint = `      # Pin the actionlint module version so syntax and expression validation
      # does not depend on a floating GitHub Action implementation.
      - name: Run actionlint
        run: |
          set -euo pipefail
          go version
          go run github.com/rhysd/actionlint/cmd/actionlint@v1.7.12 .github/workflows/*.yml

`;
  const mutations = [
    {
      label: "removed setup step",
      mutate: (contents) => contents.replace(setupGo, ""),
      error: /workflow-lint pinned Go setup step must appear exactly once \(found 0\)/i,
    },
    {
      label: "floating setup action",
      mutate: (contents) => contents.replace(
        "actions/setup-go@924ae3a1cded613372ab5595356fb5720e22ba16",
        "actions/setup-go@v6",
      ),
      error: /workflow-lint pinned Go setup step\.uses must be exactly/i,
    },
    {
      label: "drifted Go version",
      mutate: (contents) => contents.replace('go-version: "1.25.0"', 'go-version: "1.24.13"'),
      error: /workflow-lint pinned Go setup step\.with must be exactly/i,
    },
    {
      label: "enabled setup cache",
      mutate: (contents) => contents.replace("          cache: false\n", "          cache: true\n"),
      error: /workflow-lint pinned Go setup step\.with must be exactly/i,
    },
    {
      label: "setup after actionlint",
      mutate: (contents) => contents.replace(`${setupGo}${runActionlint}`, `${runActionlint}${setupGo}`),
      error: /workflow-lint pinned Go setup step must run before actionlint/i,
    },
  ];

  for (const { label, mutate, error } of mutations) {
    await withFixture(t, {}, async (root) => {
      const path = join(root, ".github/workflows/workflow-lint.yml");
      const contents = await readFile(path, "utf8");
      const mutated = mutate(contents);
      assert.notEqual(mutated, contents, `workflow-lint fixture must support ${label} mutation`);
      await writeFile(path, mutated, "utf8");
      await assert.rejects(verifyIOSReleaseContract({ root }), error);
    });
  }
});

test("fails closed when normal lint cannot validate historical screenshot commit ancestry", async (t) => {
  const mutations = [
    {
      label: "missing full-history checkout",
      from: `        with:
          # Historical screenshot locks verify commit existence and ancestry.
          fetch-depth: 0
`,
      to: "",
    },
    {
      label: "shallow checkout",
      from: "          fetch-depth: 0\n",
      to: "          fetch-depth: 1\n",
    },
  ];

  for (const { label, from, to } of mutations) {
    await withFixture(t, {}, async (root) => {
      const path = join(root, ".github/workflows/workflow-lint.yml");
      const contents = await readFile(path, "utf8");
      assert.ok(contents.includes(from), `workflow-lint fixture must support ${label} mutation`);
      await writeFile(path, contents.replace(from, to), "utf8");
      await assert.rejects(
        verifyIOSReleaseContract({ root }),
        /workflow-lint full-history checkout step.*(?:contain|be) exactly/i,
      );
    });
  }
});

test("fails closed when normal push and pull-request lint omits the Mac Catalyst screenshot harness", async (t) => {
  for (const command of [
    "      - \"ios/QuakeSignal/**\"\n",
    "          bash -n ios/ScreenshotAutomation/capture-maccatalyst-screenshot.sh\n",
    "          bash -n ios/ScreenshotAutomation/capture-maccatalyst-screenshot-set.sh\n",
    "          bash -n ios/ScreenshotAutomation/maccatalyst-capture-interface.test.sh\n",
    "          bash -n ios/ScreenshotAutomation/maccatalyst-capture-retry-policy.sh\n",
    "          bash -n ios/ScreenshotAutomation/maccatalyst-content-validator.test.sh\n",
    "          bash -n ios/ScreenshotAutomation/maccatalyst-process-guard.sh\n",
    "          /usr/bin/ruby -c ios/ScreenshotAutomation/maccatalyst-screenshot-plan.rb\n",
    "          /usr/bin/ruby -c ios/ScreenshotAutomation/assemble-maccatalyst-screenshot-provenance.rb\n",
    "          xcrun swiftc -typecheck ios/ScreenshotAutomation/maccatalyst-capture-window.swift\n",
    "          xcrun swiftc -typecheck ios/ScreenshotAutomation/maccatalyst-content-validator-fixture.swift\n",
    "          xcrun swiftc -typecheck ios/ScreenshotAutomation/maccatalyst-flatten-png.swift\n",
    "          xcrun swiftc -typecheck ios/ScreenshotAutomation/maccatalyst-validate-content.swift\n",
    "          xcrun swiftc -typecheck ios/ScreenshotAutomation/maccatalyst-window-evidence.swift\n",
    "          /usr/bin/ruby ios/ScreenshotAutomation/maccatalyst-screenshot-plan.test.rb\n",
    "          /usr/bin/ruby ios/ScreenshotAutomation/assemble-maccatalyst-screenshot-provenance.test.rb\n",
    "          bash ios/ScreenshotAutomation/maccatalyst-capture-interface.test.sh\n",
    "          bash ios/ScreenshotAutomation/maccatalyst-capture-retry-policy.test.sh\n",
    "          bash ios/ScreenshotAutomation/maccatalyst-content-validator.test.sh\n",
    "          bash ios/ScreenshotAutomation/maccatalyst-process-guard.test.sh\n",
  ]) {
    await withFixture(t, {}, async (root) => {
      const path = join(root, ".github/workflows/workflow-lint.yml");
      const contents = await readFile(path, "utf8");
      assert.ok(contents.includes(command), `workflow-lint fixture must contain ${command.trim()}`);
      await writeFile(path, contents.replaceAll(command, ""), "utf8");
      await assert.rejects(
        verifyIOSReleaseContract({ root }),
        /complete workflow directory must match the reviewed parsed-content fingerprint/i,
      );
    });
  }
});
