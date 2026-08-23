import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { lstat, readFile, readdir } from "node:fs/promises";
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
  releaseEntitlements: [
    "ios/QuakeSignal/Supporting/QuakeSignal-Release.entitlements",
    "ios/QuakeSignal/Supporting/QuakeSignal-Catalyst.entitlements",
    "ios/QuakeSignalVision/Supporting/QuakeSignalVision-Release.entitlements",
  ],
  platformCapabilityPolicy: [
    "ios/QuakeSignal/App/AppDelegate.swift",
    "ios/QuakeSignal/App/PlatformCapabilities.swift",
    "ios/QuakeSignal/App/QuakeSignalApp.swift",
    "ios/QuakeSignal/Features/Detail/QuakeDetailView.swift",
    "ios/QuakeSignal/Features/Guide/DisasterGuideView.swift",
    "ios/QuakeSignal/Features/Map/EpicenterMapView.swift",
    "ios/QuakeSignal/Features/Onboarding/OnboardingView.swift",
    "ios/QuakeSignal/Features/Root/RootView.swift",
    "ios/QuakeSignal/Features/List/QuakeListView.swift",
    "ios/QuakeSignal/Features/Home/QuakeRowView.swift",
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
  ],
  schemes: [
    "ios/QuakeSignal.xcodeproj/xcshareddata/xcschemes/QuakeSignal.xcscheme",
    "ios/QuakeSignal.xcodeproj/xcshareddata/xcschemes/QuakeSignalTV.xcscheme",
    "ios/QuakeSignal.xcodeproj/xcshareddata/xcschemes/QuakeSignalVision.xcscheme",
    "ios/QuakeSignal.xcodeproj/xcshareddata/xcschemes/QuakeSignalWatch.xcscheme",
  ],
  workerConfig: "backend/cloudflare/wrangler.jsonc",
  workerPackage: "backend/cloudflare/package.json",
  workerPackageLock: "backend/cloudflare/package-lock.json",
  exportOptions: "ios/AppStore/ExportOptions.plist",
  iosWorkflow: ".github/workflows/ios.yml",
  platformWorkflow: ".github/workflows/apple-platforms.yml",
  screenshotWorkflow: ".github/workflows/apple-platform-screenshots.yml",
  screenshotReleaseWorkflow: ".github/workflows/apple-screenshot-release-ready.yml",
  macCatalystScreenshotPlan: "ios/AppStore/platforms/maccatalyst/screenshot-manifest-v1.1-build10.json",
  cloudflareWorkflow: ".github/workflows/cloudflare.yml",
  signedArtifactVerifier: "ios/ci_scripts/verify-signed-apple-artifacts.sh",
  xcodeCloudHooks: [
    "ios/ci_scripts/ci_post_clone.sh",
    "ios/ci_scripts/ci_pre_xcodebuild.sh",
    "ios/ci_scripts/ci_post_xcodebuild.sh",
    "ios/ci_scripts/xcode-cloud-release-guard.py",
  ],
  releaseCriticalHelpers: [
    ".github/scripts/assemble-apple-screenshot-release-set.rb",
    ".github/scripts/assemble-apple-screenshot-release-set.test.rb",
    ".github/scripts/verify-apple-screenshot-release-set.rb",
    ".github/scripts/verify-apple-screenshot-release-set.test.rb",
    ".github/scripts/verify-store-assets.rb",
    ".github/scripts/verify-store-assets.test.rb",
    "backend/cloudflare/scripts/legal-page-contract.mjs",
    "backend/cloudflare/scripts/render-staging-config.mjs",
    "backend/cloudflare/scripts/smoke-test-policy.mjs",
    "backend/cloudflare/scripts/smoke-test.mjs",
    "backend/cloudflare/scripts/verify-apns-worker-secrets.mjs",
    "backend/cloudflare/scripts/verify-production-gates.mjs",
    "backend/cloudflare/scripts/wait-for-worker-readiness.mjs",
    "backend/cloudflare/staging/wrangler.staging.template.json",
    "ios/AppStore/README.md",
    "ios/AppStore/screenshot-manifest-v1.1-build10.template.json",
  ],
  screenshotAutomationHelpers: [
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
  ],
};

const REVIEWED_CI_SCRIPT_FILES = [
  ...contractFiles.xcodeCloudHooks,
  contractFiles.signedArtifactVerifier,
];

const EXECUTABLE_SCREENSHOT_AUTOMATION_FILES = new Set([
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

const REVIEWED_WORKFLOW_FILES = [
  ".github/workflows/apns-incident-disposition.yml",
  ".github/workflows/apple-platform-screenshots.yml",
  ".github/workflows/apple-platforms.yml",
  ".github/workflows/apple-screenshot-release-ready.yml",
  ".github/workflows/cloudflare-staging.yml",
  ".github/workflows/cloudflare.yml",
  ".github/workflows/desktop-build.yml",
  ".github/workflows/desktop-release.yml",
  ".github/workflows/extension-build.yml",
  ".github/workflows/homebrew-tap.yml",
  ".github/workflows/ios.yml",
  ".github/workflows/listing-assets.yml",
  ".github/workflows/terminal-dlq-fallback-monitor.yml",
  ".github/workflows/terminal-dlq-monitor.yml",
  ".github/workflows/workflow-lint.yml",
  ".github/workflows/xcode-cloud-signing-inspect.yml",
];

const APPROVED_WORKER_ORIGIN = "https://quakesignal-api.hopeso.workers.dev";
const VISION_LOCATION_USAGE_DESCRIPTION = "QuakeSignal uses your location to show distance and nearby earthquake context while the app is open.";
const FOREGROUND_PRIVACY_MANIFEST_PATHS = [
  "ios/QuakeSignalTV/Supporting/PrivacyInfo.xcprivacy",
  "ios/QuakeSignalVision/Resources/PrivacyInfo.xcprivacy",
  "ios/QuakeSignalWatch/Supporting/PrivacyInfo.xcprivacy",
];
const VISION_PRIVACY_MANIFEST_XML = [
  '<plist version="1.0"><dict>',
  "<key>NSPrivacyTracking</key><false/>",
  "<key>NSPrivacyTrackingDomains</key><array/>",
  "<key>NSPrivacyCollectedDataTypes</key><array/>",
  "<key>NSPrivacyAccessedAPITypes</key><array><dict>",
  "<key>NSPrivacyAccessedAPIType</key><string>NSPrivacyAccessedAPICategoryUserDefaults</string>",
  "<key>NSPrivacyAccessedAPITypeReasons</key><array><string>CA92.1</string></array>",
  "</dict></array></dict></plist>",
].join("");
const APP_STORE_EXPORT_OPTIONS = {
  method: "app-store-connect",
  destination: "export",
  signingStyle: "manual",
  teamID: "5TT564H883",
};
const RELEASE_ALERT_ENTITLEMENTS = {
  "aps-environment": "production",
  "com.apple.developer.devicecheck.appattest-environment": "production",
  "com.apple.developer.usernotifications.time-sensitive": true,
};
const RELEASE_CATALYST_ENTITLEMENTS = {
  "com.apple.security.app-sandbox": true,
  "com.apple.security.network.client": true,
  "com.apple.security.personal-information.location": true,
};
const RELEASE_TARGET_NAMES = [
  "QuakeSignal",
  "QuakeSignalTV",
  "QuakeSignalTests",
  "QuakeSignalVision",
  "QuakeSignalWatch",
];
const ARCHIVE_SCHEME_NAMES = [
  "QuakeSignal",
  "QuakeSignalTV",
  "QuakeSignalVision",
  "QuakeSignalWatch",
];
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
const UPLOAD_ARTIFACT_ACTION = "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a";
const DOWNLOAD_ARTIFACT_ACTION = "actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c";
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
const SCREENSHOT_RELEASE_ROOT_PERMISSIONS = { actions: "read", contents: "read" };
const SCREENSHOT_RELEASE_ROOT_CONCURRENCY = {
  group: "apple-screenshot-release-ready-${{ inputs.source_commit }}",
  "cancel-in-progress": false,
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
    { name: "Mac Catalyst", key: "maccatalyst", scheme: "QuakeSignal", destination: "generic/platform=macOS,variant=Mac Catalyst" },
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
      name: "${{ inputs.platform == 'tvos' && 'tvOS' || inputs.platform == 'visionos' && 'visionOS' || 'Mac Catalyst' }}",
      scheme: "${{ inputs.platform == 'tvos' && 'QuakeSignalTV' || inputs.platform == 'visionos' && 'QuakeSignalVision' || 'QuakeSignal' }}",
      destination: "${{ inputs.platform == 'tvos' && 'generic/platform=tvOS' || inputs.platform == 'visionos' && 'generic/platform=visionOS' || 'generic/platform=macOS,variant=Mac Catalyst' }}",
      bundle_identifier: "com.quakesignal.app",
      profile_secret: "${{ inputs.platform == 'tvos' && 'TVOS_APP_STORE_PROVISIONING_PROFILE' || inputs.platform == 'visionos' && 'VISIONOS_APP_STORE_PROVISIONING_PROFILE' || 'MACCATALYST_APP_STORE_PROVISIONING_PROFILE' }}",
      profile_variable: "${{ inputs.platform == 'tvos' && 'TVOS_APP_STORE_PROFILE_NAME' || inputs.platform == 'visionos' && 'VISIONOS_APP_STORE_PROFILE_NAME' || 'MACCATALYST_APP_STORE_PROFILE_NAME' }}",
      profile_platform: "${{ inputs.platform == 'tvos' && 'tvOS' || inputs.platform == 'visionos' && 'visionOS' || 'OSX' }}",
      profile_extension: "${{ inputs.platform == 'maccatalyst' && 'provisionprofile' || 'mobileprovision' }}",
      altool_platform: "${{ inputs.platform == 'tvos' && 'appletvos' || inputs.platform == 'visionos' && 'visionos' || 'macos' }}",
      requires_alert_entitlements: "false",
    },
  ],
};
const PLATFORM_RELEASE_JOB_HEADER = {
  name: "Archive ${{ matrix.name }} and optionally upload to App Store Connect",
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
// archive, export, artifact verification, digest-bound upload, and cleanup).
// A deliberate workflow change must update this reviewed value
// alongside its tests; an unreviewed sibling job, extra post-smoke step, or
// edited signing/upload action fails before release automation can use
// credentials.
const TESTFLIGHT_POST_SMOKE_SEQUENCE_FINGERPRINT = "sha256:2VeW3DO8MbplMJY0o2VH9mUpAgnd1cG6mlbnLP3K0Es";
const WORKFLOW_JOBS_FINGERPRINT = "sha256:mmzDL0fVCsXwnbsK_dXtK3dk10pKXDTe6pLeKEkEack";
const PLATFORM_POST_SMOKE_SEQUENCE_FINGERPRINT = "sha256:t04HndXYLXgik4100K3yBsfGbPtQVy5zn6dogUwq4N8";
const PLATFORM_WORKFLOW_JOBS_FINGERPRINT = "sha256:2P3h47Cp8gfn3ehSqQnOObAmm0yOfdAsWiWqfGP9gDI";
const SCREENSHOT_WORKFLOW_JOBS_FINGERPRINT = "sha256:7uJANY6vWpHWmx_aG3r9Vfm6FN2Kc0Jic68X4kW7AjI";
const SCREENSHOT_RELEASE_WORKFLOW_JOBS_FINGERPRINT = "sha256:nwR_WO2AVbhslCYJYO51gOpS7B9wMaROs8pMHMeXRe0";
const CLOUDFLARE_WORKFLOW_JOBS_FINGERPRINT = "sha256:0idTHVYpJvePMjlGG8MEeN-OmNBwPZ0iwCkeIaFMVR0";
const XCODE_CLOUD_RELEASE_HOOKS_FINGERPRINT = "sha256:kDx1FHD9AQ2pcjiu6R14fNiq5o6ccUeI7Y7FNIwbcJg";
const XCODE_SCHEMES_FINGERPRINT = "sha256:d1cqEp5M_rdKeYqcsAGXC45NKBHJLieE7oLLChhMCqo";
const PLATFORM_CAPABILITIES_FINGERPRINT = "sha256:UApNMP0jmCo5R9enmbbGZxDwszTJTIK96q2nS8o4Nfg";
const RELEASE_CRITICAL_HELPERS_FINGERPRINT = "sha256:bocI3sE5zvOVMAApOs_e8lX36ICrjsWyNAdzJ8aehZI";
const SCREENSHOT_AUTOMATION_HELPERS_FINGERPRINT = "sha256:qhbmHNjXa5zqEro1kc74zoLq6O0HveB9dIDzFq38MKU";
const WORKER_DEPENDENCY_GRAPH_FINGERPRINT = "sha256:uS9cfNUI8Mc1v2znTTE-Loc4GQnRVJycb0fI8PAl9SE";
const WORKER_DEPLOYMENT_CONFIG_FINGERPRINT = "sha256:MGFrBJXA26bnqXfA030H1RdRUqOjGrmH85d7mB2636k";
const CREDENTIAL_WORKFLOWS_FINGERPRINT = "sha256:IFaeA29pNEBjevpDjoRb22AZ2iPt_XC5v93PC7-k424";
const WORKFLOW_DIRECTORY_FINGERPRINT = "sha256:buptEZME5XAxxQ7_2b3qDTJWcQJoYmZJmAOyzJ9unJU";
const WORKFLOW_DIRECTORY_SOURCE_FINGERPRINT = "sha256:lIwWG6dxRVZ0u1Ntir1Or8RyReNBwGJSlHYyP6OpXlU";
const MAC_CATALYST_SCREENSHOT_PLAN_FINGERPRINT = "sha256:_ZwVwcu1DLNzB8gNUjCzxf5A9mCefe483hBvgsOWtGU";

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
const IOS_SIGNED_ARTIFACT_COMMAND = [
  "set -euo pipefail",
  "ios/ci_scripts/verify-signed-apple-artifacts.sh \\",
  "  --platform ios \\",
  "  --archive \"$RUNNER_TEMP/QuakeSignal.xcarchive\" \\",
  "  --exported \"${IPA_PATH:?IPA_PATH is not set after export}\" \\",
  "  --build-number \"$BUILD_NUMBER\" \\",
  "  --marketing-version 1.1 \\",
  "  --team-id 5TT564H883 \\",
  "  --archive-signing strict-distribution \\",
  "  --host-profile-name \"$IOS_PROFILE_NAME\" \\",
  "  --watch-profile-name \"$WATCH_PROFILE_NAME\"",
  "ipa_sha256=\"$(/usr/bin/shasum -a 256 \"$IPA_PATH\")\"",
  "ipa_sha256=\"${ipa_sha256%% *}\"",
  "if [[ ! \"$ipa_sha256\" =~ ^[0-9a-f]{64}$ ]]; then",
  "  echo \"::error::Verified iOS IPA did not produce a valid SHA-256 digest\"",
  "  exit 1",
  "fi",
  "echo \"IPA_SHA256=$ipa_sha256\" >> \"$GITHUB_ENV\"",
  "printf 'Verified `%s` SHA-256: `%s`\\n' \"${IPA_PATH##*/}\" \"$ipa_sha256\" >> \"$GITHUB_STEP_SUMMARY\"",
  "echo 'IPA_VERIFIED=true' >> \"$GITHUB_ENV\"",
  "",
].join("\n");
const IOS_UPLOAD_COMMAND = [
  "set -euo pipefail",
  "if [ \"${IPA_VERIFIED:-false}\" != true ]; then",
  "  echo \"::error::Refusing to upload an iOS IPA that did not pass signed verification\"",
  "  exit 1",
  "fi",
  "upload_sha256=\"$(/usr/bin/shasum -a 256 \"${IPA_PATH:?IPA_PATH is not set after export}\")\"",
  "upload_sha256=\"${upload_sha256%% *}\"",
  "if [ \"$upload_sha256\" != \"${IPA_SHA256:?Verified iOS IPA SHA-256 is missing}\" ]; then",
  "  echo \"::error::iOS IPA changed after signed verification\"",
  "  exit 1",
  "fi",
  "key_dir=\"$RUNNER_TEMP/appstore-private-keys\"",
  "key_path=\"$key_dir/AuthKey_${APP_STORE_CONNECT_KEY_ID}.p8\"",
  "mkdir -p \"$key_dir\"",
  "cleanup() {",
  "  rm -f \"$key_path\"",
  "  rmdir \"$key_dir\" 2>/dev/null || true",
  "}",
  "trap cleanup EXIT",
  "printf '%s' \"$APP_STORE_CONNECT_KEY\" > \"$key_path\"",
  "chmod 600 \"$key_path\"",
  "export API_PRIVATE_KEYS_DIR=\"$key_dir\"",
  "upload_arguments=(",
  "  --platform \"$IOS_ALTOOL_PLATFORM\"",
  "  --apple-id \"$APP_STORE_CONNECT_APPLE_ID\"",
  "  --bundle-id \"$IOS_BUNDLE_IDENTIFIER\"",
  "  --bundle-version \"$BUILD_NUMBER\"",
  "  --bundle-short-version-string 1.1",
  "  --api-key \"$APP_STORE_CONNECT_KEY_ID\"",
  "  --api-issuer \"$APP_STORE_CONNECT_ISSUER\"",
  "  --output-format json",
  ")",
  "xcrun altool --validate-app \"$IPA_PATH\" \"${upload_arguments[@]}\"",
  "xcrun altool --upload-package \"$IPA_PATH\" \"${upload_arguments[@]}\"",
  "",
].join("\n");
const PLATFORM_SIGNED_ARTIFACT_COMMAND = [
  "set -euo pipefail",
  "verifier_arguments=(",
  "  --platform \"$PLATFORM_KEY\"",
  "  --archive \"$RUNNER_TEMP/QuakeSignal-$PLATFORM_KEY.xcarchive\"",
  "  --exported \"${APPLE_ARTIFACT_PATH:?APPLE_ARTIFACT_PATH is not set after export}\"",
  "  --build-number \"$BUILD_NUMBER\"",
  "  --marketing-version 1.1",
  "  --team-id 5TT564H883",
  "  --archive-signing strict-distribution",
  "  --host-profile-name \"$PLATFORM_PROFILE_NAME\"",
  ")",
  "if [ \"$PLATFORM_KEY\" = maccatalyst ]; then",
  "  verifier_arguments+=(--installer-identity \"${PLATFORM_INSTALLER_IDENTITY:?Mac Catalyst installer identity is missing}\")",
  "fi",
  "ios/ci_scripts/verify-signed-apple-artifacts.sh \"${verifier_arguments[@]}\"",
  "artifact_sha256=\"$(/usr/bin/shasum -a 256 \"$APPLE_ARTIFACT_PATH\")\"",
  "artifact_sha256=\"${artifact_sha256%% *}\"",
  "if [[ ! \"$artifact_sha256\" =~ ^[0-9a-f]{64}$ ]]; then",
  "  echo \"::error::Verified Apple artifact did not produce a valid SHA-256 digest\"",
  "  exit 1",
  "fi",
  "echo \"APPLE_ARTIFACT_SHA256=$artifact_sha256\" >> \"$GITHUB_ENV\"",
  "printf 'Verified `%s` SHA-256: `%s`\\n' \"${APPLE_ARTIFACT_PATH##*/}\" \"$artifact_sha256\" >> \"$GITHUB_STEP_SUMMARY\"",
  "echo 'APPLE_ARTIFACT_VERIFIED=true' >> \"$GITHUB_ENV\"",
  "",
].join("\n");

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

const FORBIDDEN_XCODEGEN_EXECUTION_KEYS = new Set([
  "buildRules",
  "buildToolPlugins",
  "include",
  "package",
  "packages",
  "postActions",
  "postBuildScripts",
  "postCompileScripts",
  "preActions",
  "preBuildScripts",
  "projectReferences",
  "schemeTemplates",
  "targetTemplates",
  "templates",
]);

function rejectForbiddenProjectKeys(value, location = "ios/project.yml") {
  if (Array.isArray(value)) {
    value.forEach((item, index) => rejectForbiddenProjectKeys(item, `${location}[${index}]`));
    return;
  }
  if (!isRecord(value)) return;
  for (const [key, child] of Object.entries(value)) {
    if (FORBIDDEN_XCODEGEN_EXECUTION_KEYS.has(key)) {
      fail(`${location}.${key} is an unreviewed executable script, plugin, package, template, or project-reference surface.`);
    }
    rejectForbiddenProjectKeys(child, `${location}.${key}`);
  }
}

function verifyAppleProject(projectSource) {
  const project = parseEffectiveYAML(projectSource, "XcodeGen project", "ios/project.yml");
  rejectForbiddenProjectKeys(project);
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
  if (!sameValue(Object.keys(targets).sort(), RELEASE_TARGET_NAMES)) {
    fail(`ios/project.yml targets must be exactly ${RELEASE_TARGET_NAMES.join(", ")}.`);
  }
  const expectedTargets = {
    QuakeSignal: {
      platform: "iOS",
      type: "application",
      bundleIdentifier: "com.quakesignal.app",
      family: "1,2",
      profileVariable: "$(QUAKESIGNAL_IOS_PROFILE_NAME)",
      entitlements: "QuakeSignal/Supporting/QuakeSignal-Release.entitlements",
      attestedAlerts: true,
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
      attestedAlerts: false,
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
    const configFiles = target.configFiles;
    if (isRecord(configFiles) && (Object.hasOwn(configFiles, "Release") || Object.hasOwn(configFiles, "InternalQA"))) {
      fail(`${name} must not load an unreviewed Release/InternalQA xcconfig.`);
    }
    if (base.PRODUCT_BUNDLE_IDENTIFIER !== expected.bundleIdentifier) {
      fail(`${name} PRODUCT_BUNDLE_IDENTIFIER must be ${expected.bundleIdentifier}.`);
    }
    if (String(base.TARGETED_DEVICE_FAMILY) !== expected.family) {
      fail(`${name} TARGETED_DEVICE_FAMILY must be ${expected.family}.`);
    }
    if (name === "QuakeSignal") {
      if (String(base.SUPPORTS_MACCATALYST) !== "true" ||
          String(base.DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER) !== "false" ||
          String(base.SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD) !== "false" ||
          String(base["ENABLE_APP_SANDBOX[sdk=macosx*]"]) !== "true") {
        fail("QuakeSignal must expose Mac Catalyst, preserve its shared bundle ID, enable the Mac sandbox, and disable Designed for iPad on Mac.");
      }
      for (const [configuration, values] of Object.entries(record(settings.configs, "QuakeSignal config settings"))) {
        if (!isRecord(values) ||
            values["CODE_SIGN_ENTITLEMENTS[sdk=macosx*]"] !== "QuakeSignal/Supporting/QuakeSignal-Catalyst.entitlements") {
          fail(`QuakeSignal ${configuration} must use the reviewed Mac Catalyst entitlements.`);
        }
        if ((configuration === "Release" || configuration === "InternalQA") &&
            values["PROVISIONING_PROFILE_SPECIFIER[sdk=macosx*]"] !== "$(QUAKESIGNAL_CATALYST_PROFILE_NAME)") {
          fail(`QuakeSignal ${configuration} must use the target-scoped Mac Catalyst provisioning profile.`);
        }
      }
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
    const configurations = record(settings.configs, `${name} config settings`);
    if (expected.attestedAlerts) {
      const internalQA = record(configurations.InternalQA, `${name} InternalQA settings`);
      const debug = record(configurations.Debug, `${name} Debug settings`);
      for (const [configuration, values] of [["InternalQA", internalQA], ["Release", release]]) {
        if (values.QUAKESIGNAL_API_BASE_URL !== APPROVED_WORKER_ORIGIN ||
            values.QUAKESIGNAL_APP_ATTEST_MODE !== "production") {
          fail(`${name} ${configuration} must use the reviewed production Worker and App Attest policy.`);
        }
      }
      if (debug.QUAKESIGNAL_APP_ATTEST_MODE !== "development") {
        fail(`${name} Debug must use the reviewed App Attest development policy.`);
      }
    } else {
      for (const [configuration, values] of Object.entries(configurations)) {
        if (isRecord(values) &&
            (Object.hasOwn(values, "QUAKESIGNAL_API_BASE_URL") ||
             Object.hasOwn(values, "QUAKESIGNAL_APP_ATTEST_MODE"))) {
          fail(`${name} ${configuration} is foreground-only and must not configure the notification relay or App Attest.`);
        }
      }
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
  if (iosDependencies.length !== 1) {
    fail("QuakeSignal must have only the reviewed embedded Watch target dependency.");
  }
  for (const name of ["QuakeSignalTV", "QuakeSignalVision", "QuakeSignalWatch"]) {
    if (Object.hasOwn(targets[name], "dependencies") &&
        (!Array.isArray(targets[name].dependencies) || targets[name].dependencies.length !== 0)) {
      fail(`${name} must not acquire an archive-time target, package, framework, or plugin dependency.`);
    }
  }
  const testTarget = record(targets.QuakeSignalTests, "XcodeGen QuakeSignalTests target");
  if (testTarget.platform !== "iOS" || testTarget.type !== "bundle.unit-test") {
    fail("QuakeSignalTests must remain the reviewed iOS unit-test target.");
  }
  if (!sameValue(testTarget.dependencies, [{ target: "QuakeSignal" }])) {
    fail("QuakeSignalTests must depend only on QuakeSignal.");
  }

  const schemes = record(project.schemes, "XcodeGen schemes");
  if (!sameValue(Object.keys(schemes).sort(), ARCHIVE_SCHEME_NAMES)) {
    fail(`ios/project.yml schemes must be exactly ${ARCHIVE_SCHEME_NAMES.join(", ")}.`);
  }
  for (const name of Object.keys(expectedTargets)) {
    const scheme = record(schemes[name], `XcodeGen ${name} scheme`);
    const expectedKeys = name === "QuakeSignal"
      ? ["archive", "build", "test"]
      : ["archive", "build", "run"];
    if (!sameValue(Object.keys(scheme).sort(), expectedKeys)) {
      fail(`${name} scheme must contain only its reviewed build/archive actions.`);
    }
    exactRecord(scheme.build, { targets: { [name]: "all" } }, `${name} scheme build action`);
    exactRecord(scheme.archive, { config: "Release" }, `${name} archive action`);
  }
}

function verifyGeneratedProject(projectFile, buildNumber) {
  for (const forbidden of [
    "PBXAggregateTarget",
    "PBXBuildRule",
    "PBXLegacyTarget",
    "PBXShellScriptBuildPhase",
    "XCRemoteSwiftPackageReference",
    "XCSwiftPackageProductDependency",
    "shellScript =",
  ]) {
    if (projectFile.includes(forbidden)) {
      fail(`generated Xcode project contains forbidden executable surface ${forbidden}.`);
    }
  }
  const targetNames = [...projectFile.matchAll(
    /^\s*[A-F0-9]+ \/\* ([^*]+) \*\/ = \{\s*\n\s*isa = PBXNativeTarget;/gm,
  )].map((match) => match[1]).sort();
  if (!sameValue(targetNames, RELEASE_TARGET_NAMES)) {
    fail(`generated Xcode project native targets must be exactly ${RELEASE_TARGET_NAMES.join(", ")}.`);
  }
  const buildPhaseTypes = [...projectFile.matchAll(/isa = (PBX[A-Za-z0-9]+BuildPhase);/g)]
    .map((match) => match[1]);
  if (buildPhaseTypes.length !== 10 ||
      buildPhaseTypes.filter((type) => type === "PBXSourcesBuildPhase").length !== 5 ||
      buildPhaseTypes.filter((type) => type === "PBXResourcesBuildPhase").length !== 4 ||
      buildPhaseTypes.filter((type) => type === "PBXCopyFilesBuildPhase").length !== 1) {
    fail("generated Xcode project build phases must remain exactly five Sources, four Resources, and one embedded-Watch CopyFiles phase.");
  }
  const dependencyTargets = [...projectFile.matchAll(
    /\/\* PBXTargetDependency \*\/ = \{[\s\S]*?\n\s*target = [A-F0-9]+ \/\* ([^*]+) \*\/;/g,
  )].map((match) => match[1]).sort();
  if (!sameValue(dependencyTargets, ["QuakeSignal", "QuakeSignalWatch"])) {
    fail("generated Xcode project dependencies must remain only Tests→QuakeSignal and iOS→Watch.");
  }
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

function verifyInfoPlist(infoPlist, label, requiresWorkerConfiguration) {
  const effective = infoPlist.replace(/<!--[\s\S]*?-->/g, "");
  exactlyOne([...effective.matchAll(/<key>\s*CFBundleVersion\s*<\/key>/g)], `${label} CFBundleVersion`);
  exactlyOne(
    [...effective.matchAll(/<key>\s*CFBundleVersion\s*<\/key>\s*<string>\s*\$\(CURRENT_PROJECT_VERSION\)\s*<\/string>/g)],
    `${label} CFBundleVersion interpolation`,
  );
  const workerOrigin = [...effective.matchAll(
    /<key>\s*QUAKESIGNAL_API_BASE_URL\s*<\/key>\s*<string>\s*\$\(QUAKESIGNAL_API_BASE_URL\)\s*<\/string>/g,
  )];
  const appAttestMode = [...effective.matchAll(
    /<key>\s*QUAKESIGNAL_APP_ATTEST_MODE\s*<\/key>\s*<string>\s*\$\(QUAKESIGNAL_APP_ATTEST_MODE\)\s*<\/string>/g,
  )];
  if (requiresWorkerConfiguration) {
    exactlyOne(workerOrigin, `${label} Worker origin interpolation`);
    exactlyOne(appAttestMode, `${label} App Attest mode interpolation`);
  } else if (workerOrigin.length > 0 || appAttestMode.length > 0 ||
             /<key>\s*QUAKESIGNAL_(?:API_BASE_URL|APP_ATTEST_MODE)\s*<\/key>/.test(effective)) {
    fail(`${label} is foreground-only and must not embed Worker or App Attest configuration.`);
  }
  if (label === "ios/QuakeSignal/Supporting/Info.plist" &&
      !/<key>\s*LSApplicationCategoryType\s*<\/key>\s*<string>\s*public\.app-category\.weather\s*<\/string>/.test(effective)) {
    fail(`${label} must declare the reviewed native Mac Weather category.`);
  }
  if (label === "ios/QuakeSignalVision/Supporting/Info.plist") {
    const description = [...effective.matchAll(
      /<key>\s*NSLocationWhenInUseUsageDescription\s*<\/key>\s*<string>\s*([^<]*)\s*<\/string>/g,
    )];
    if (description.length !== 1 || description[0][1].trim() !== VISION_LOCATION_USAGE_DESCRIPTION) {
      fail(`${label} must disclose foreground-only location use exactly.`);
    }
  }
}

function verifyVisionPrivacyManifest(source, label) {
  if (typeof source !== "string") {
    fail(`${label} is missing from the foreground-only platform policy inventory.`);
  }
  const effective = source
    .replace(/^\uFEFF/, "")
    .replace(/<\?xml[\s\S]*?\?>/g, "")
    .replace(/<!DOCTYPE[\s\S]*?>/g, "")
    .replace(/<!--[\s\S]*?-->/g, "")
    .trim()
    .replace(/>\s+</g, "><");
  if (effective !== VISION_PRIVACY_MANIFEST_XML) {
    fail(
      `${label} must declare tracking false, no tracking domains or collected data, ` +
      "and only UserDefaults accessed for reason CA92.1.",
    );
  }
}

function parseSimplePlistDictionary(source, label) {
  const document = source
    .replace(/^\uFEFF/, "")
    .replace(/<\?xml[\s\S]*?\?>/g, "")
    .replace(/<!DOCTYPE[\s\S]*?>/g, "")
    .replace(/<!--[\s\S]*?-->/g, "")
    .trim();
  if (/^<plist\s+version="1\.0">\s*<dict\s*\/>\s*<\/plist>$/.test(document)) {
    return {};
  }
  const outer = document.match(/^<plist\s+version="1\.0">\s*<dict>([\s\S]*)<\/dict>\s*<\/plist>$/);
  if (!outer) fail(`${label} must be a simple XML property-list dictionary.`);
  let remainder = outer[1];
  const values = {};
  const pair = /^\s*<key>([^<>&]+)<\/key>\s*(?:<string>([^<>&]*)<\/string>|<(true|false)\s*\/>)/;
  while (remainder.trim()) {
    const match = remainder.match(pair);
    if (!match) fail(`${label} may contain only reviewed string and Boolean entries.`);
    const key = match[1];
    if (Object.hasOwn(values, key)) fail(`${label} contains duplicate key ${key}.`);
    values[key] = match[3] ? match[3] === "true" : match[2];
    remainder = remainder.slice(match[0].length);
  }
  return values;
}

function verifyReleaseEntitlements(sources) {
  if (!Array.isArray(sources) || sources.length !== contractFiles.releaseEntitlements.length) {
    fail("checked-in Release entitlement inventory is incomplete.");
  }
  const expectedEntitlements = [
    RELEASE_ALERT_ENTITLEMENTS,
    RELEASE_CATALYST_ENTITLEMENTS,
    {},
  ];
  sources.forEach((source, index) => {
    const label = contractFiles.releaseEntitlements[index];
    exactRecord(
      parseSimplePlistDictionary(source, label),
      expectedEntitlements[index],
      `${label} effective entitlements`,
    );
  });
}

function verifyMacCatalystScreenshotPlan(source) {
  let manifest;
  try {
    manifest = JSON.parse(source);
  } catch {
    fail(`${contractFiles.macCatalystScreenshotPlan} must be valid JSON.`);
  }
  const expectedSelectors = [
    "maccatalyst-home",
    "maccatalyst-reports",
    "maccatalyst-map",
    "maccatalyst-guide",
    "maccatalyst-alert-preferences",
  ];
  const document = record(manifest, "Mac Catalyst screenshot plan");
  if (document.status !== "planned-unapproved") {
    fail("Mac Catalyst screenshot plan must remain planned-unapproved until exact native captures pass signed-Release review.");
  }
  exactRecord(document.product, {
    appleId: "6800642443",
    platform: "macOS-maccatalyst",
    marketingVersion: "1.1",
    build: 10,
    bundleIdentifier: "com.quakesignal.app",
    scheme: "QuakeSignal",
    destination: "platform=macOS,variant=Mac Catalyst",
    designedForIPadOnMac: false,
  }, "Mac Catalyst screenshot product");
  const evidence = record(document.captureEvidence, "Mac Catalyst screenshot capture evidence");
  if (evidence.sourceBaselineCommit !== null ||
      evidence.debugArtifactSha256 !== null ||
      evidence.signedReleaseArtifactSha256 !== null ||
      evidence.capturedAtUtc !== null ||
      evidence.reviewer !== null ||
      evidence.signedReleaseParityApproved !== false ||
      evidence.uploadApproved !== false) {
    fail("Mac Catalyst screenshot plan must remain source-only, reviewer-null, and unapproved.");
  }
  if (!Array.isArray(document.frames) || document.frames.length !== expectedSelectors.length) {
    fail("Mac Catalyst screenshot plan must contain exactly five reviewed frames.");
  }
  document.frames.forEach((frame, index) => {
    const value = record(frame, `Mac Catalyst screenshot frame ${index + 1}`);
    if (value.captureSelector !== expectedSelectors[index] ||
        !sameValue(value.pixels, [2560, 1600]) ||
        value.captureStatus !== "pending" ||
        value.sha256 !== null) {
      fail(`Mac Catalyst screenshot frame ${index + 1} must keep its exact selector, native 2560x1600 size, pending state, and null digest.`);
    }
  });
  return verifyReviewedFileFingerprint(
    [{ path: contractFiles.macCatalystScreenshotPlan, source }],
    [contractFiles.macCatalystScreenshotPlan],
    MAC_CATALYST_SCREENSHOT_PLAN_FINGERPRINT,
    "Mac Catalyst screenshot source-only plan",
  );
}

function verifyMacCatalystScreenshotRouting(
  rootSource,
  settingsSource,
  quakeRowSource,
  screenshotAutomationSource,
) {
  if (!/ScreenshotAutomation\.rootDestination\(\s*for:\s*ScreenshotAutomation\.selectedFrame\s*\)/s.test(rootSource) ||
      !/case\s+\.settings:\s*\.settings/.test(rootSource) ||
      !/case\s+\.iPhone65AlertPreferences,\s*\.iPad13AlertPreferences,\s*\.visionAlertPreferences,\s*\.macAlertPreferences:\s*\.settings/s.test(screenshotAutomationSource)) {
    fail("Mac Catalyst alert-preferences selector must route through the shared production Settings destination.");
  }
  if (!/if\s+ScreenshotAutomation\.isAlertPreferencesFrame\(\s*ScreenshotAutomation\.selectedFrame\s*\)\s*\{\s*AlertSoundSelectionView\(screenshotSelectedPreference:\s*\.japaneseVoice\)/s.test(settingsSource)) {
    fail("Mac Catalyst alert-preferences selector must open the shared Japanese voice selection view.");
  }
  if (!/reportDate\?\.formatted\(date:\s*\.numeric,\s*time:\s*\.shortened\)/.test(quakeRowSource) ||
      /reportDate\?\.formatted\(date:\s*\.omitted/.test(quakeRowSource)) {
    fail("Mac Catalyst report rows must show a calendar date as well as time for historical fixtures.");
  }
}

function verifyReviewedFileFingerprint(files, expectedPaths, expectedFingerprint, label) {
  if (!Array.isArray(files) || files.length !== expectedPaths.length) {
    fail(`${label} inventory is incomplete.`);
  }
  const normalized = files.map(({ path, source }, index) => {
    if (path !== expectedPaths[index]) fail(`${label} file ${index} must be ${expectedPaths[index]}.`);
    return { path, source };
  });
  const fingerprint = workflowSequenceFingerprint(normalized);
  if (fingerprint !== expectedFingerprint) {
    fail(`${label} must match the reviewed fingerprint (received ${fingerprint}).`);
  }
  return fingerprint;
}

function verifyWorkerReleaseScripts(packageSource) {
  let manifest;
  try {
    manifest = JSON.parse(packageSource);
  } catch {
    fail("backend/cloudflare/package.json must be valid JSON.");
  }
  const scripts = record(manifest.scripts, "Worker package scripts");
  if (Object.hasOwn(manifest, "workspaces")) {
    fail("backend/cloudflare/package.json must not define npm workspaces for a credential-bearing deploy.");
  }
  if (Object.hasOwn(manifest, "overrides")) {
    fail("backend/cloudflare/package.json must not define unreviewed npm dependency overrides.");
  }
  const expected = {
    "render:staging-config": "node scripts/render-staging-config.mjs",
    "verify:apns-secrets": "node scripts/verify-apns-worker-secrets.mjs",
    "verify:production-gates": "node scripts/verify-production-gates.mjs",
    "wait:worker-readiness": "node scripts/wait-for-worker-readiness.mjs",
    "test:remote": "node scripts/smoke-test.mjs",
  };
  for (const forbidden of [
    "install",
    "dependencies",
    "postinstall",
    "postprepare",
    "preinstall",
    "preprepare",
    "prepublish",
    "prepare",
    ...Object.keys(expected).flatMap((name) => [`pre${name}`, `post${name}`]),
  ]) {
    if (Object.hasOwn(scripts, forbidden)) {
      fail(`backend/cloudflare/package.json must not define release-capable npm lifecycle hook ${forbidden}.`);
    }
  }
  for (const [name, command] of Object.entries(expected)) {
    const definitions = [...packageSource.matchAll(new RegExp(`"${name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}"\\s*:`, "g"))];
    exactlyOne(definitions, `backend/cloudflare/package.json script ${name}`);
    if (scripts[name] !== command) {
      fail(`backend/cloudflare/package.json ${name} must invoke exactly ${command}.`);
    }
  }
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

function requireText(value, requiredFragments, label) {
  if (typeof value !== "string") fail(`${label} must be a string.`);
  for (const fragment of requiredFragments) {
    if (!value.includes(fragment)) {
      fail(`${label} must include ${JSON.stringify(fragment)}.`);
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

function verifyExportOptions(source) {
  const document = source
    .replace(/^\uFEFF/, "")
    .replace(/<\?xml[\s\S]*?\?>/g, "")
    .replace(/<!DOCTYPE[\s\S]*?>/g, "")
    .replace(/<!--[\s\S]*?-->/g, "")
    .trim();
  const outer = document.match(/^<plist\s+version="1\.0">\s*<dict>([\s\S]*)<\/dict>\s*<\/plist>$/);
  if (!outer) fail("ios/AppStore/ExportOptions.plist must be a simple XML property-list dictionary.");
  let remainder = outer[1];
  const values = {};
  const pair = /^\s*<key>([A-Za-z][A-Za-z0-9]*)<\/key>\s*<string>([^<>&]*)<\/string>/;
  while (remainder.trim()) {
    const match = remainder.match(pair);
    if (!match) fail("ios/AppStore/ExportOptions.plist may contain only reviewed string entries.");
    if (Object.hasOwn(values, match[1])) {
      fail(`ios/AppStore/ExportOptions.plist contains duplicate key ${match[1]}.`);
    }
    values[match[1]] = match[2];
    remainder = remainder.slice(match[0].length);
  }
  exactRecord(values, APP_STORE_EXPORT_OPTIONS, "App Store export options");
}

function pythonStringConstant(source, name) {
  const matches = [...source.matchAll(new RegExp(`^${name} = "([^"\\r\\n]*)"\\s*$`, "gm"))];
  return exactlyOne(matches, `Xcode Cloud guard ${name}`)[1];
}

function verifyXcodeCloudGuardConstants(files, expected) {
  const guard = exactlyOne(
    files.filter(({ path }) => path === "ios/ci_scripts/xcode-cloud-release-guard.py"),
    "Xcode Cloud Python release guard",
  );
  for (const [name, value] of Object.entries(expected)) {
    const actual = pythonStringConstant(guard.source, name);
    if (actual !== value) {
      fail(`Xcode Cloud guard ${name} must match ${value} (received ${actual}).`);
    }
  }
}

function verifyXcodeCloudReleaseHooks(files) {
  const expectedPaths = [
    ...contractFiles.xcodeCloudHooks,
    contractFiles.signedArtifactVerifier,
  ];
  if (!Array.isArray(files) || files.length !== expectedPaths.length) {
    fail("Xcode Cloud release hook inventory is incomplete.");
  }
  const normalized = files.map(({ path, source, mode }, index) => {
    if (path !== expectedPaths[index]) {
      fail(`Xcode Cloud release hook ${index} must be ${expectedPaths[index]}.`);
    }
    const mustBeExecutable = path.endsWith(".sh") || path.endsWith(".py");
    const executable = (mode & 0o111) !== 0;
    if (mustBeExecutable && !executable) {
      fail(`${path} must be executable for Xcode Cloud and GitHub-hosted macOS runners.`);
    }
    return { executable, path, source };
  });
  const fingerprint = workflowSequenceFingerprint(normalized);
  if (fingerprint !== XCODE_CLOUD_RELEASE_HOOKS_FINGERPRINT) {
    fail(`Xcode Cloud release hooks must match the reviewed fingerprint (received ${fingerprint}).`);
  }
  return fingerprint;
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

function collectWorkflowStrings(value, output = []) {
  if (typeof value === "string") {
    output.push(value);
  } else if (Array.isArray(value)) {
    value.forEach((item) => collectWorkflowStrings(item, output));
  } else if (isRecord(value)) {
    Object.values(value).forEach((item) => collectWorkflowStrings(item, output));
  }
  return output;
}

function collectLocalActionReferences(value, output = []) {
  if (Array.isArray(value)) {
    value.forEach((item) => collectLocalActionReferences(item, output));
  } else if (isRecord(value)) {
    for (const [key, child] of Object.entries(value)) {
      if (key === "uses" && typeof child === "string" && child.trim().startsWith("./")) {
        output.push(child);
      }
      collectLocalActionReferences(child, output);
    }
  }
  return output;
}

function collectWritePermissions(value, workflowPath, output = []) {
  if (Array.isArray(value)) {
    value.forEach((item) => collectWritePermissions(item, workflowPath, output));
  } else if (isRecord(value)) {
    for (const [key, child] of Object.entries(value)) {
      if (key === "permissions") {
        if (!isRecord(child)) {
          fail(`${workflowPath} must use an explicit permission mapping; scalar write-all/read-all permissions are forbidden.`);
        }
        for (const [permission, access] of Object.entries(child)) {
          if (!new Set(["read", "write", "none"]).has(access)) {
            fail(`${workflowPath} has unsupported ${permission} permission ${JSON.stringify(access)}.`);
          }
          if (access === "write") output.push(`${workflowPath}:${permission}`);
        }
      }
      collectWritePermissions(child, workflowPath, output);
    }
  }
  return output;
}

async function readReviewedWorkflowInventory(root) {
  const directory = resolve(root, ".github/workflows");
  const entries = await readdir(directory, { withFileTypes: true });
  const workflowEntries = entries
    .filter((entry) => /\.ya?ml$/i.test(entry.name))
    .sort((left, right) => left.name < right.name ? -1 : left.name > right.name ? 1 : 0);
  if (workflowEntries.some((entry) => !entry.isFile())) {
    fail(".github/workflows must not contain symlinked or non-regular YAML workflow entries.");
  }
  const paths = workflowEntries.map((entry) => `.github/workflows/${entry.name}`);
  if (!sameValue(paths, REVIEWED_WORKFLOW_FILES)) {
    fail(`workflow inventory must be exactly the reviewed set (received ${paths.join(", ")}).`);
  }
  return Promise.all(paths.map(async (workflowPath) => ({
    path: workflowPath,
    source: await readFile(resolve(root, workflowPath), "utf8"),
  })));
}

async function verifyAbsentNpmControlFiles(root) {
  for (const relativePath of [
    ".npmrc",
    "backend/cloudflare/.npmrc",
    "backend/cloudflare/npm-shrinkwrap.json",
  ]) {
    try {
      await lstat(resolve(root, relativePath));
      if (relativePath.endsWith("npm-shrinkwrap.json")) {
        fail(`${relativePath} is forbidden because it overrides the reviewed package-lock.json dependency graph.`);
      }
      fail(`${relativePath} is forbidden because npm script-shell/node-options can bypass reviewed release commands.`);
    } catch (error) {
      if (error && typeof error === "object" && error.code === "ENOENT") continue;
      throw error;
    }
  }
}

async function readReviewedRegularFile(root, relativePath) {
  let file;
  try {
    file = await lstat(resolve(root, relativePath));
  } catch (error) {
    if (error && typeof error === "object" && error.code === "ENOENT") {
      fail(`${relativePath} must exist as a regular checked-in file.`);
    }
    throw error;
  }
  if (!file.isFile()) {
    fail(`${relativePath} must be a regular checked-in file.`);
  }
  return readFile(resolve(root, relativePath), "utf8");
}

async function readReviewedCiScriptInventory(root) {
  const directory = resolve(root, "ios/ci_scripts");
  const entries = (await readdir(directory, { withFileTypes: true }))
    .sort((left, right) => left.name < right.name ? -1 : left.name > right.name ? 1 : 0);
  if (entries.some((entry) => !entry.isFile())) {
    fail("ios/ci_scripts must contain only the exact reviewed regular files; directories and symlinks are forbidden.");
  }
  const expectedNames = REVIEWED_CI_SCRIPT_FILES
    .map((relativePath) => relativePath.slice(relativePath.lastIndexOf("/") + 1))
    .sort();
  const actualNames = entries.map((entry) => entry.name);
  if (!sameValue(actualNames, expectedNames)) {
    fail(`ios/ci_scripts inventory must be exactly the reviewed set (received ${actualNames.join(", ")}).`);
  }
  return Promise.all(REVIEWED_CI_SCRIPT_FILES.map(async (relativePath) => {
    const file = await lstat(resolve(root, relativePath));
    if (!file.isFile()) fail(`${relativePath} must be a regular checked-in file.`);
    return {
      path: relativePath,
      source: await readFile(resolve(root, relativePath), "utf8"),
      mode: file.mode,
    };
  }));
}

async function readReviewedScreenshotAutomationInventory(root) {
  const directory = resolve(root, "ios/ScreenshotAutomation");
  const entries = (await readdir(directory, { withFileTypes: true }))
    .sort((left, right) => left.name < right.name ? -1 : left.name > right.name ? 1 : 0);
  if (entries.some((entry) => !entry.isFile())) {
    fail("ios/ScreenshotAutomation must contain only the exact reviewed regular files; directories and symlinks are forbidden.");
  }
  const expectedNames = contractFiles.screenshotAutomationHelpers
    .map((relativePath) => relativePath.slice(relativePath.lastIndexOf("/") + 1))
    .sort();
  const actualNames = entries.map((entry) => entry.name);
  if (!sameValue(actualNames, expectedNames)) {
    fail(`ios/ScreenshotAutomation inventory must be exactly the reviewed set (received ${actualNames.join(", ")}).`);
  }
  return Promise.all(contractFiles.screenshotAutomationHelpers.map(async (relativePath) => {
    const file = await lstat(resolve(root, relativePath));
    if (!file.isFile()) fail(`${relativePath} must be a regular checked-in file.`);
    return {
      path: relativePath,
      source: await readFile(resolve(root, relativePath), "utf8"),
      mode: file.mode,
    };
  }));
}

function verifyScreenshotAutomationHelpers(files) {
  const expectedPaths = contractFiles.screenshotAutomationHelpers;
  if (!Array.isArray(files) || files.length !== expectedPaths.length) {
    fail("native screenshot automation helper inventory is incomplete.");
  }
  const normalized = files.map(({ path, source, mode }, index) => {
    if (path !== expectedPaths[index]) {
      fail(`native screenshot automation helper ${index} must be ${expectedPaths[index]}.`);
    }
    const executable = (mode & 0o111) !== 0;
    if (executable !== EXECUTABLE_SCREENSHOT_AUTOMATION_FILES.has(path)) {
      fail(`${path} executable mode must match the reviewed native screenshot harness.`);
    }
    return { executable, path, source };
  });
  const fingerprint = workflowSequenceFingerprint(normalized);
  if (fingerprint !== SCREENSHOT_AUTOMATION_HELPERS_FINGERPRINT) {
    fail(`native screenshot automation helpers must match the reviewed fingerprint (received ${fingerprint}).`);
  }
  return fingerprint;
}

function verifyWorkflowDirectoryPolicy(workflowFiles) {
  const mobileReleaseFiles = new Set([
    contractFiles.iosWorkflow,
    contractFiles.platformWorkflow,
    contractFiles.screenshotReleaseWorkflow,
    ".github/workflows/xcode-cloud-signing-inspect.yml",
  ]);
  const appleUploadFiles = new Set([
    ...mobileReleaseFiles,
    ".github/workflows/desktop-release.yml",
  ]);
  const cloudflareCredentialFiles = new Set([
    ".github/workflows/apns-incident-disposition.yml",
    ".github/workflows/cloudflare-staging.yml",
    contractFiles.cloudflareWorkflow,
    ".github/workflows/terminal-dlq-fallback-monitor.yml",
    ".github/workflows/terminal-dlq-monitor.yml",
  ]);
  const configuredWorkerDeployFiles = new Set([
    ".github/workflows/cloudflare-staging.yml",
    ".github/workflows/terminal-dlq-monitor.yml",
  ]);
  const observedWritePermissions = [];
  const credentialWorkflows = [];
  const parsedWorkflows = [];

  for (const { path: workflowPath, source } of workflowFiles) {
    const workflow = parseEffectiveWorkflow(source, `workflow ${workflowPath}`, workflowPath);
    parsedWorkflows.push({ path: workflowPath, workflow });
    if (workflowPath === ".github/workflows/workflow-lint.yml") {
      const jobs = record(workflow.jobs, "workflow-lint jobs");
      const actionlintJob = record(jobs.actionlint, "workflow-lint actionlint job");
      if (actionlintJob["runs-on"] !== "macos-latest") {
        fail("the workflow-lint native Apple screenshot harness must run on macos-latest.");
      }
      if (!Array.isArray(actionlintJob.steps)) {
        fail("workflow-lint actionlint job steps must be a sequence.");
      }
      const checkout = stepByName(
        actionlintJob.steps,
        "Check out repository",
        "workflow-lint full-history checkout step",
      );
      exactRecord(checkout, {
        name: "Check out repository",
        uses: "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1",
        with: {
          "fetch-depth": 0,
        },
      }, "workflow-lint full-history checkout step");
      const setupGo = stepByName(
        actionlintJob.steps,
        "Set up Go",
        "workflow-lint pinned Go setup step",
      );
      exactRecord(setupGo, {
        name: "Set up Go",
        uses: "actions/setup-go@924ae3a1cded613372ab5595356fb5720e22ba16",
        with: {
          "go-version": "1.25.0",
          cache: false,
        },
      }, "workflow-lint pinned Go setup step");
      const runActionlint = stepByName(
        actionlintJob.steps,
        "Run actionlint",
        "workflow-lint actionlint execution step",
      );
      if (actionlintJob.steps.indexOf(setupGo) >= actionlintJob.steps.indexOf(runActionlint)) {
        fail("workflow-lint pinned Go setup step must run before actionlint.");
      }
    }
    const trigger = workflow.on ?? workflow.true;
    if (
      trigger === "workflow_call" ||
      (Array.isArray(trigger) && trigger.includes("workflow_call")) ||
      (isRecord(trigger) && Object.hasOwn(trigger, "workflow_call"))
    ) {
      fail(`${workflowPath} must not expose a reusable workflow_call release bypass.`);
    }
    const localActions = collectLocalActionReferences(workflow);
    if (localActions.length > 0) {
      fail(`${workflowPath} invokes unbound local action ${localActions[0]}; release-critical local code must be fingerprinted directly.`);
    }
    collectWritePermissions(workflow, workflowPath, observedWritePermissions);
    const workflowStrings = collectWorkflowStrings(workflow);
    if (workflowStrings.some((value) => /\$\{\{\s*secrets(?:\.|\[)/.test(value))) {
      credentialWorkflows.push({ path: workflowPath, workflow });
    }

    for (const value of workflowStrings) {
      const mobileSurface =
        value === "ios-app-store-release" ||
        /(?:^|[^A-Z0-9_])(?:IOS|WATCHOS|TVOS|VISIONOS|MACCATALYST)_APP_STORE_[A-Z0-9_]+/.test(value) ||
        /(?:^|[^A-Z0-9_])APP_STORE_CONNECT_API_(?:KEY|KEY_ID|ISSUER)\b/.test(value) ||
        /generic\/platform=(?:iOS|tvOS|visionOS|watchOS|macOS,variant=Mac Catalyst)/.test(value) ||
        /\bxcodebuild\s+(?:archive|-exportArchive)\b/.test(value);
      if (mobileSurface && !mobileReleaseFiles.has(workflowPath)) {
        fail(`${workflowPath} contains a protected mobile Apple signing/archive surface outside the reviewed release lanes.`);
      }
      if (/\bxcrun\s+altool\s+--upload-package\b/.test(value) && !appleUploadFiles.has(workflowPath)) {
        fail(`${workflowPath} contains an App Store upload command outside a reviewed Apple release lane.`);
      }
      if (value === "cloudflare-production" && workflowPath !== contractFiles.cloudflareWorkflow) {
        fail(`${workflowPath} names the protected production Worker environment outside the reviewed deploy lane.`);
      }
      if (/\$\{\{\s*secrets\.CLOUDFLARE_(?:API_TOKEN|ACCOUNT_ID)\s*\}\}/.test(value) &&
          !cloudflareCredentialFiles.has(workflowPath)) {
        fail(`${workflowPath} reads production-capable Cloudflare credentials outside the reviewed Cloudflare lanes.`);
      }
      for (const line of value.split(/\r?\n/)) {
        if (!/\bwrangler\s+deploy\b/.test(line) || /--dry-run\b/.test(line)) continue;
        if (workflowPath === contractFiles.cloudflareWorkflow) continue;
        if (!configuredWorkerDeployFiles.has(workflowPath) || !/--config(?:=|\s)/.test(line)) {
          fail(`${workflowPath} contains an unreviewed production-capable Worker deploy command.`);
        }
      }
    }
  }

  const expectedWritePermissions = [
    ".github/workflows/desktop-release.yml:contents",
    ".github/workflows/terminal-dlq-fallback-monitor.yml:issues",
  ];
  if (!sameValue(observedWritePermissions.sort(), expectedWritePermissions)) {
    fail(`workflow write permissions must remain exactly ${expectedWritePermissions.join(", ")}.`);
  }
  const expectedCredentialWorkflowPaths = [
    ".github/workflows/apns-incident-disposition.yml",
    ".github/workflows/apple-platforms.yml",
    ".github/workflows/cloudflare-staging.yml",
    ".github/workflows/cloudflare.yml",
    ".github/workflows/desktop-release.yml",
    ".github/workflows/homebrew-tap.yml",
    ".github/workflows/ios.yml",
    ".github/workflows/terminal-dlq-fallback-monitor.yml",
    ".github/workflows/terminal-dlq-monitor.yml",
    ".github/workflows/xcode-cloud-signing-inspect.yml",
  ];
  const observedCredentialWorkflowPaths = credentialWorkflows.map(({ path }) => path);
  if (!sameValue(observedCredentialWorkflowPaths, expectedCredentialWorkflowPaths)) {
    fail(`credential-bearing workflow inventory must be exactly ${expectedCredentialWorkflowPaths.join(", ")}.`);
  }
  const credentialFingerprint = workflowSequenceFingerprint(credentialWorkflows);
  if (credentialFingerprint !== CREDENTIAL_WORKFLOWS_FINGERPRINT) {
    fail(`credential-bearing workflows must match the reviewed fingerprint (received ${credentialFingerprint}).`);
  }
  const directoryFingerprint = workflowSequenceFingerprint(parsedWorkflows);
  if (directoryFingerprint !== WORKFLOW_DIRECTORY_FINGERPRINT) {
    fail(`the complete workflow directory must match the reviewed parsed-content fingerprint (received ${directoryFingerprint}).`);
  }
  const directorySourceFingerprint = workflowSequenceFingerprint(workflowFiles);
  if (directorySourceFingerprint !== WORKFLOW_DIRECTORY_SOURCE_FINGERPRINT) {
    fail(`the complete workflow directory must match the reviewed raw path-and-source fingerprint (received ${directorySourceFingerprint}).`);
  }
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

function verifySignedReleaseArtifactRetentionPolicy(steps, label) {
  const retained = steps.filter((step) =>
    isRecord(step) &&
    typeof step.uses === "string" &&
    /^actions\/upload-artifact@/.test(step.uses)
  );
  if (retained.length !== 1 || retained[0]?.name !== "Upload signed release attestation only") {
    fail(`${label} must not retain signed release binaries as GitHub Actions artifacts; it may retain exactly one machine-readable attestation.`);
  }
  const retainedSource = JSON.stringify(retained[0]);
  if (/\.(?:ipa|pkg|dmg|xcarchive)\b|IPA_PATH|APPLE_ARTIFACT_PATH/.test(retainedSource)) {
    fail(`${label} must not retain signed release binaries as GitHub Actions artifacts in this public repository.`);
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
    description: "Archive, verify, and hash a signed IPA without retaining or uploading it",
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
  exactRecord(record(dispatch.source_commit, "iOS workflow source_commit input"), {
    description: "Exact 40-character lowercase protected-main commit to sign",
    required: true,
    type: "string",
  }, "iOS workflow source_commit input");

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
  verifySignedReleaseArtifactRetentionPolicy(steps, "iOS TestFlight job");
  const expectedPrelude = [
    "Check out repository",
    "Validate immutable signed source",
    "Verify iOS and Worker release contract",
    "Verify production notification origin readiness and contract",
  ];
  if (steps.length < expectedPrelude.length ||
      steps.slice(0, expectedPrelude.length).some((step, index) => step?.name !== expectedPrelude[index])) {
    fail("testflight must run exact checkout, immutable-source validation, static release contract, and remote policy smoke consecutively before all other steps.");
  }
  exactRecord(steps[0], {
    name: "Check out repository",
    uses: CHECKOUT_ACTION,
    with: {
      ref: "${{ inputs.source_commit }}",
      "fetch-depth": 0,
      "persist-credentials": false,
    },
  }, "testflight checkout step");
  exactRecord(steps[1], {
    name: "Validate immutable signed source",
    env: {
      REF_PROTECTED: "${{ github.ref_protected }}",
      SOURCE_COMMIT: "${{ inputs.source_commit }}",
    },
    run: steps[1].run,
  }, "iOS immutable signed source step");
  requireText(steps[1].run, [
    "test \"$GITHUB_REPOSITORY\" = TastyHeadphones/QuakeSignal",
    "test \"$GITHUB_REF\" = refs/heads/main",
    "[[ \"$SOURCE_COMMIT\" =~ ^[0-9a-f]{40}$ ]]",
    "test \"$SOURCE_COMMIT\" = \"$GITHUB_SHA\"",
    "test \"$(git rev-parse --verify HEAD)\" = \"$SOURCE_COMMIT\"",
  ], "iOS immutable signed source command");
  exactRecord(steps[2], {
    name: "Verify iOS and Worker release contract",
    id: "release-contract",
    env: { BUILD_NUMBER: "${{ inputs.build_number }}" },
    run: PRE_SIGNING_COMMAND,
  }, "pre-signing release-contract step");
  exactRecord(steps[3], {
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
  const exportedIpa = stepByName(
    steps,
    "Export App Store Connect IPA",
    "iOS workflow exported IPA step",
  );
  exactRecordWithAllowedKeys(exportedIpa, {
    name: "Export App Store Connect IPA",
    env: {
      IOS_PROFILE_NAME: "${{ vars.IOS_APP_STORE_PROFILE_NAME }}",
      WATCH_PROFILE_NAME: "${{ vars.WATCHOS_APP_STORE_PROFILE_NAME }}",
    },
  }, ["run"], "iOS workflow exported IPA step");
  requireText(exportedIpa.run, [
    "Add :manageAppVersionAndBuildNumber bool false",
    'shopt -s nullglob',
    'ipas=("$export_path"/*.ipa)',
    'unexpected=("$export_path"/*.pkg)',
    '[ "${#ipas[@]}" -ne 1 ]',
    '[ "${#unexpected[@]}" -ne 0 ]',
    '[ ! -f "${ipas[0]:-}" ]',
    '[ -L "${ipas[0]:-}" ]',
    'echo "IPA_PATH=${ipas[0]}" >> "$GITHUB_ENV"',
    "echo 'IPA_VERIFIED=false' >> \"$GITHUB_ENV\"",
  ], "iOS workflow exported IPA step.run");
  const signedArtifacts = stepByName(
    steps,
    "Verify signed iOS archive and exported IPA",
    "iOS workflow signed artifact verifier step",
  );
  exactRecord(signedArtifacts, {
    name: "Verify signed iOS archive and exported IPA",
    shell: "bash",
    env: {
      BUILD_NUMBER: "${{ inputs.build_number }}",
      IOS_PROFILE_NAME: "${{ vars.IOS_APP_STORE_PROFILE_NAME }}",
      WATCH_PROFILE_NAME: "${{ vars.WATCHOS_APP_STORE_PROFILE_NAME }}",
    },
    run: IOS_SIGNED_ARTIFACT_COMMAND,
  }, "iOS signed artifact verifier step");
  const upload = stepByName(
    steps,
    "Upload build to TestFlight",
    "iOS App Store Connect upload step",
  );
  exactRecord(upload, {
    name: "Upload build to TestFlight",
    if: "${{ inputs.upload_to_testflight && !inputs.archive_only }}",
    env: {
      BUILD_NUMBER: "${{ inputs.build_number }}",
      IOS_ALTOOL_PLATFORM: "ios",
      APP_STORE_CONNECT_APPLE_ID: "6800642443",
      IOS_BUNDLE_IDENTIFIER: "com.quakesignal.app",
      APP_STORE_CONNECT_KEY: "${{ secrets.APP_STORE_CONNECT_API_KEY }}",
      APP_STORE_CONNECT_KEY_ID: "${{ vars.APP_STORE_CONNECT_API_KEY_ID }}",
      APP_STORE_CONNECT_ISSUER: "${{ vars.APP_STORE_CONNECT_API_ISSUER }}",
    },
    run: IOS_UPLOAD_COMMAND,
  }, "iOS App Store Connect upload step");
  const cleanup = stepByName(steps, "Remove signing material", "iOS signing cleanup step");
  const attestation = stepByName(steps, "Write signed release attestation", "iOS signed release attestation step");
  requireText(attestation.run, [
    '"workflowFile" => ".github/workflows/ios.yml"',
    '"platforms" => %w[ios-ipados watchos]',
    '"kind" => "ipa"',
    '"distributionMode" => ENV.fetch("ARCHIVE_ONLY") == "true" ? "archive-only" : "testflight-upload"',
    '"sourceCommit" => ENV.fetch("SOURCE_COMMIT")',
  ], "iOS signed release attestation command");
  const attestationUpload = stepByName(steps, "Upload signed release attestation only", "iOS signed release attestation upload");
  exactRecord(attestationUpload, {
    name: "Upload signed release attestation only",
    uses: UPLOAD_ARTIFACT_ACTION,
    with: {
      name: "signed-release-attestation-ios-ipados-watchos-${{ inputs.source_commit }}-${{ github.run_id }}-${{ github.run_attempt }}",
      path: "${{ runner.temp }}/signed-release-attestation-ios-ipados-watchos/signed-release-attestation.json",
      "if-no-files-found": "error",
      "include-hidden-files": false,
      "compression-level": 0,
      overwrite: false,
      "retention-days": 30,
    },
  }, "iOS signed release attestation upload");
  const orderedSteps = [archive, exportedIpa, signedArtifacts, upload, cleanup, attestation, attestationUpload];
  if (orderedSteps.some((step, index) => index > 0 && steps.indexOf(step) <= steps.indexOf(orderedSteps[index - 1]))) {
    fail("iOS archive, export, verification, digest-bound upload, and cleanup steps must remain in reviewed order.");
  }
  const postSmokeFingerprint = workflowSequenceFingerprint(steps.slice(expectedPrelude.length));
  if (postSmokeFingerprint !== TESTFLIGHT_POST_SMOKE_SEQUENCE_FINGERPRINT) {
    fail(`testflight post-remote signing sequence must match the reviewed fingerprint (received ${postSmokeFingerprint}).`);
  }
  const jobsFingerprint = workflowSequenceFingerprint(jobs);
  if (jobsFingerprint !== WORKFLOW_JOBS_FINGERPRINT) {
    fail(`iOS workflow jobs must match the reviewed release-job graph fingerprint (received ${jobsFingerprint}).`);
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
    options: ["tvos", "visionos", "maccatalyst"],
  }, "native platform workflow platform input");
  exactRecord(record(dispatch.archive_only, "native platform workflow archive_only input"), {
    description: "Archive, verify, and hash a signed IPA or PKG without retaining or uploading it",
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
    description: "Exact coordinated CFBundleVersion from ios/project.yml",
    required: false,
    default: buildNumber,
    type: "string",
  }, "native platform workflow build_number input");
  exactRecord(record(dispatch.source_commit, "native platform workflow source_commit input"), {
    description: "Exact 40-character lowercase protected-main commit to sign",
    required: true,
    type: "string",
  }, "native platform workflow source_commit input");

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
  verifySignedReleaseArtifactRetentionPolicy(steps, "native platform release job");
  const expectedPrelude = [
    "Check out repository",
    "Validate immutable signed source",
    "Verify frozen Apple platform release contract",
  ];
  if (steps.length < expectedPrelude.length ||
      steps.slice(0, expectedPrelude.length).some((step, index) => step?.name !== expectedPrelude[index])) {
    fail("native platform release must run exact checkout, immutable-source validation, and its frozen static release contract consecutively before all credential-bearing steps.");
  }
  exactRecord(steps[0], {
    name: "Check out repository",
    uses: CHECKOUT_ACTION,
    with: {
      ref: "${{ inputs.source_commit }}",
      "fetch-depth": 0,
      "persist-credentials": false,
    },
  }, "native platform checkout step");
  exactRecord(steps[1], {
    name: "Validate immutable signed source",
    env: {
      REF_PROTECTED: "${{ github.ref_protected }}",
      SOURCE_COMMIT: "${{ inputs.source_commit }}",
    },
    run: steps[1].run,
  }, "native platform immutable signed source step");
  requireText(steps[1].run, [
    "test \"$GITHUB_REPOSITORY\" = TastyHeadphones/QuakeSignal",
    "test \"$GITHUB_REF\" = refs/heads/main",
    "[[ \"$SOURCE_COMMIT\" =~ ^[0-9a-f]{40}$ ]]",
    "test \"$SOURCE_COMMIT\" = \"$GITHUB_SHA\"",
    "test \"$(git rev-parse --verify HEAD)\" = \"$SOURCE_COMMIT\"",
  ], "native platform immutable signed source command");
  exactRecord(steps[2], {
    name: "Verify frozen Apple platform release contract",
    id: "release-contract",
    env: { BUILD_NUMBER: "${{ inputs.build_number }}" },
    run: PRE_SIGNING_COMMAND,
  }, "native platform pre-signing release-contract step");

  const signingConfiguration = stepByName(
    steps,
    "Validate selected protected signing configuration",
    "native platform selected signing configuration step",
  );
  exactRecordWithAllowedKeys(signingConfiguration, {
    name: "Validate selected protected signing configuration",
    env: {
      PLATFORM_KEY: "${{ matrix.key }}",
      PLATFORM_SCHEME: "${{ matrix.scheme }}",
      PLATFORM_DESTINATION: "${{ matrix.destination }}",
      PLATFORM_BUNDLE_IDENTIFIER: "${{ matrix.bundle_identifier }}",
      PLATFORM_PROFILE_PLATFORM: "${{ matrix.profile_platform }}",
      PLATFORM_PROFILE_EXTENSION: "${{ matrix.profile_extension }}",
      PLATFORM_ALTOOL_PLATFORM: "${{ matrix.altool_platform }}",
      PLATFORM_REQUIRES_ALERT_ENTITLEMENTS: "${{ matrix.requires_alert_entitlements }}",
      PLATFORM_PROFILE: "${{ secrets[matrix.profile_secret] }}",
      PLATFORM_PROFILE_NAME: "${{ vars[matrix.profile_variable] }}",
      PLATFORM_INSTALLER_IDENTITY: "${{ inputs.platform == 'maccatalyst' && vars.MACCATALYST_APP_STORE_INSTALLER_IDENTITY || '' }}",
      PLATFORM_AUTOMATIC_SIGNING_KEY: "${{ inputs.platform == 'maccatalyst' && secrets.APP_STORE_CONNECT_API_KEY || '' }}",
      PLATFORM_AUTOMATIC_SIGNING_KEY_ID: "${{ inputs.platform == 'maccatalyst' && vars.APP_STORE_CONNECT_API_KEY_ID || '' }}",
      PLATFORM_AUTOMATIC_SIGNING_ISSUER: "${{ inputs.platform == 'maccatalyst' && vars.APP_STORE_CONNECT_API_ISSUER || '' }}",
      IOS_CERTIFICATE: "${{ secrets.IOS_APP_STORE_CERTIFICATE }}",
      IOS_CERTIFICATE_PASSWORD: "${{ secrets.IOS_APP_STORE_CERTIFICATE_PASSWORD }}",
      ARCHIVE_ONLY: "${{ inputs.archive_only }}",
      UPLOAD_TO_TESTFLIGHT: "${{ inputs.upload_to_testflight }}",
    },
  }, ["run"], "native platform selected signing configuration step");
  requireText(signingConfiguration.run, [
    "required+=(\n    PLATFORM_INSTALLER_IDENTITY\n    PLATFORM_AUTOMATIC_SIGNING_KEY\n    PLATFORM_AUTOMATIC_SIGNING_KEY_ID\n    PLATFORM_AUTOMATIC_SIGNING_ISSUER\n  )",
    "test \"$PLATFORM_DESTINATION\" = 'generic/platform=macOS,variant=Mac Catalyst'",
    "test \"$PLATFORM_PROFILE_PLATFORM\" = OSX",
    "test \"$PLATFORM_PROFILE_EXTENSION\" = provisionprofile",
    "test \"$PLATFORM_ALTOOL_PLATFORM\" = appletvos",
    "test \"$PLATFORM_ALTOOL_PLATFORM\" = visionos",
    "test \"$PLATFORM_ALTOOL_PLATFORM\" = macos",
    "Mac Installer Distribution: '*' (5TT564H883)",
    "3rd Party Mac Developer Installer: '*' (5TT564H883)",
  ], "native platform selected signing configuration step.run");

  const signingImport = stepByName(
    steps,
    "Import Apple Distribution certificate and selected App Store profile",
    "native platform signing import step",
  );
  exactRecordWithAllowedKeys(signingImport, {
    name: "Import Apple Distribution certificate and selected App Store profile",
    env: {
      PLATFORM_KEY: "${{ matrix.key }}",
      PLATFORM_PROFILE_EXTENSION: "${{ matrix.profile_extension }}",
      PLATFORM_PROFILE: "${{ secrets[matrix.profile_secret] }}",
      IOS_CERTIFICATE: "${{ secrets.IOS_APP_STORE_CERTIFICATE }}",
      IOS_CERTIFICATE_PASSWORD: "${{ secrets.IOS_APP_STORE_CERTIFICATE_PASSWORD }}",
    },
  }, ["run"], "native platform signing import step");
  requireText(signingImport.run, [
    'profile="$profile_dir/quakesignal-$PLATFORM_KEY.$PLATFORM_PROFILE_EXTENSION"',
    'security import "$certificate" -k "$keychain" -P "$IOS_CERTIFICATE_PASSWORD" -T /usr/bin/codesign',
    'security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain"',
  ], "native platform signing import step.run");

  const archive = stepByName(steps, "Archive selected signed App Store build", "native platform signed archive step");
  exactRecordWithAllowedKeys(archive, {
    name: "Archive selected signed App Store build",
    env: {
      BUILD_NUMBER: "${{ inputs.build_number }}",
      PLATFORM_KEY: "${{ matrix.key }}",
      PLATFORM_SCHEME: "${{ matrix.scheme }}",
      PLATFORM_DESTINATION: "${{ matrix.destination }}",
      PLATFORM_PROFILE_NAME: "${{ vars[matrix.profile_variable] }}",
      PLATFORM_AUTOMATIC_SIGNING_KEY: "${{ inputs.platform == 'maccatalyst' && secrets.APP_STORE_CONNECT_API_KEY || '' }}",
      PLATFORM_AUTOMATIC_SIGNING_KEY_ID: "${{ inputs.platform == 'maccatalyst' && vars.APP_STORE_CONNECT_API_KEY_ID || '' }}",
      PLATFORM_AUTOMATIC_SIGNING_ISSUER: "${{ inputs.platform == 'maccatalyst' && vars.APP_STORE_CONNECT_API_ISSUER || '' }}",
    },
  }, ["run"], "native platform signed archive step");
  requireText(archive.run, [
    "set -euo pipefail",
    "code_sign_style=Manual",
    'if [ "$PLATFORM_KEY" = maccatalyst ]; then',
    'automatic_key="$RUNNER_TEMP/quakesignal-maccatalyst-automatic-signing.p8"',
    'printf \'%s\' "$PLATFORM_AUTOMATIC_SIGNING_KEY" > "$automatic_key"',
    "code_sign_style=Automatic",
    "-allowProvisioningUpdates",
    '-authenticationKeyPath "$automatic_key"',
    '-authenticationKeyID "$PLATFORM_AUTOMATIC_SIGNING_KEY_ID"',
    '-authenticationKeyIssuerID "$PLATFORM_AUTOMATIC_SIGNING_ISSUER"',
    "PROVISIONING_PROFILE_SPECIFIER=",
    "CODE_SIGN_IDENTITY=",
    "xcodebuild archive",
    'CODE_SIGN_STYLE="$code_sign_style"',
    "CODE_SIGN_IDENTITY='Apple Distribution'",
    '"${signing_arguments[@]}"',
  ], "native platform signed archive step.run");

  const exportedArtifact = stepByName(
    steps,
    "Export selected App Store Connect artifact",
    "native platform exported artifact step",
  );
  exactRecordWithAllowedKeys(exportedArtifact, {
    name: "Export selected App Store Connect artifact",
    env: {
      PLATFORM_KEY: "${{ matrix.key }}",
      PLATFORM_BUNDLE_IDENTIFIER: "${{ matrix.bundle_identifier }}",
      PLATFORM_PROFILE_NAME: "${{ vars[matrix.profile_variable] }}",
      PLATFORM_INSTALLER_IDENTITY: "${{ inputs.platform == 'maccatalyst' && vars.MACCATALYST_APP_STORE_INSTALLER_IDENTITY || '' }}",
      PLATFORM_AUTOMATIC_SIGNING_KEY_ID: "${{ inputs.platform == 'maccatalyst' && vars.APP_STORE_CONNECT_API_KEY_ID || '' }}",
      PLATFORM_AUTOMATIC_SIGNING_ISSUER: "${{ inputs.platform == 'maccatalyst' && vars.APP_STORE_CONNECT_API_ISSUER || '' }}",
    },
  }, ["run"], "native platform exported artifact step");
  requireText(exportedArtifact.run, [
    "Add :manageAppVersionAndBuildNumber bool false",
    "Set :signingStyle automatic",
    "-allowProvisioningUpdates",
    '-authenticationKeyPath "$automatic_key"',
    '-authenticationKeyID "$PLATFORM_AUTOMATIC_SIGNING_KEY_ID"',
    '-authenticationKeyIssuerID "$PLATFORM_AUTOMATIC_SIGNING_ISSUER"',
    "Add :provisioningProfiles dict",
    'artifacts=("$export_path"/*.pkg)',
    'unexpected=("$export_path"/*.ipa)',
    'artifacts=("$export_path"/*.ipa)',
    'unexpected=("$export_path"/*.pkg)',
    '[ "${#artifacts[@]}" -ne 1 ]',
    '[ "${#unexpected[@]}" -ne 0 ]',
    '[ ! -f "${artifacts[0]:-}" ]',
    '[ -L "${artifacts[0]:-}" ]',
    'echo "APPLE_ARTIFACT_PATH=${artifacts[0]}" >> "$GITHUB_ENV"',
    "echo 'APPLE_ARTIFACT_VERIFIED=false' >> \"$GITHUB_ENV\"",
  ], "native platform exported artifact step.run");

  const signedArtifacts = stepByName(
    steps,
    "Verify selected signed archive and exported artifact",
    "native platform signed artifact verifier step",
  );
  exactRecord(signedArtifacts, {
    name: "Verify selected signed archive and exported artifact",
    shell: "bash",
    env: {
      BUILD_NUMBER: "${{ inputs.build_number }}",
      PLATFORM_KEY: "${{ matrix.key }}",
      PLATFORM_PROFILE_NAME: "${{ vars[matrix.profile_variable] }}",
      PLATFORM_INSTALLER_IDENTITY: "${{ inputs.platform == 'maccatalyst' && vars.MACCATALYST_APP_STORE_INSTALLER_IDENTITY || '' }}",
    },
    run: PLATFORM_SIGNED_ARTIFACT_COMMAND,
  }, "native platform signed artifact verifier step");

  const upload = stepByName(
    steps,
    "Upload selected build to TestFlight",
    "native platform App Store Connect upload step",
  );
  exactRecordWithAllowedKeys(upload, {
    name: "Upload selected build to TestFlight",
    if: "${{ inputs.upload_to_testflight && !inputs.archive_only }}",
    env: {
      BUILD_NUMBER: "${{ inputs.build_number }}",
      PLATFORM_KEY: "${{ matrix.key }}",
      PLATFORM_ALTOOL_PLATFORM: "${{ matrix.altool_platform }}",
      PLATFORM_BUNDLE_IDENTIFIER: "${{ matrix.bundle_identifier }}",
      APP_STORE_CONNECT_APPLE_ID: "6800642443",
      APP_STORE_CONNECT_KEY: "${{ secrets.APP_STORE_CONNECT_API_KEY }}",
      APP_STORE_CONNECT_KEY_ID: "${{ vars.APP_STORE_CONNECT_API_KEY_ID }}",
      APP_STORE_CONNECT_ISSUER: "${{ vars.APP_STORE_CONNECT_API_ISSUER }}",
    },
  }, ["run"], "native platform App Store Connect upload step");
  requireText(upload.run, [
    'if [ "${APPLE_ARTIFACT_VERIFIED:-false}" != true ]; then',
    'upload_sha256="$(/usr/bin/shasum -a 256 "$APPLE_ARTIFACT_PATH")"',
    'if [ "$upload_sha256" != "${APPLE_ARTIFACT_SHA256:?Verified Apple artifact SHA-256 is missing}" ]; then',
    '--platform "$PLATFORM_ALTOOL_PLATFORM"',
    '--apple-id "$APP_STORE_CONNECT_APPLE_ID"',
    '--bundle-id "$PLATFORM_BUNDLE_IDENTIFIER"',
    '--bundle-version "$BUILD_NUMBER"',
    '--bundle-short-version-string 1.1',
    'xcrun altool --validate-app "$APPLE_ARTIFACT_PATH" "${upload_arguments[@]}"',
    'xcrun altool --upload-package "$APPLE_ARTIFACT_PATH" "${upload_arguments[@]}"',
  ], "native platform App Store Connect upload step.run");

  const cleanup = stepByName(steps, "Remove signing material", "native platform signing cleanup step");
  requireText(cleanup.run, [
    'rm -f "$RUNNER_TEMP/quakesignal-maccatalyst-automatic-signing.p8"',
    'rm -f "$HOME/Library/MobileDevice/Provisioning Profiles/quakesignal-$PLATFORM_KEY.$PLATFORM_PROFILE_EXTENSION"',
  ], "native platform signing cleanup step.run");

  const attestation = stepByName(steps, "Write signed release attestation", "native platform signed release attestation step");
  requireText(attestation.run, [
    '"workflowFile" => ".github/workflows/apple-platforms.yml"',
    '"platforms" => [platform]',
    '"kind" => platform == "maccatalyst" ? "pkg" : "ipa"',
    '"distributionMode" => ENV.fetch("ARCHIVE_ONLY") == "true" ? "archive-only" : "testflight-upload"',
    '"sourceCommit" => ENV.fetch("SOURCE_COMMIT")',
  ], "native platform signed release attestation command");
  const attestationUpload = stepByName(steps, "Upload signed release attestation only", "native platform signed release attestation upload");
  exactRecord(attestationUpload, {
    name: "Upload signed release attestation only",
    uses: UPLOAD_ARTIFACT_ACTION,
    with: {
      name: "signed-release-attestation-${{ matrix.key }}-${{ inputs.source_commit }}-${{ github.run_id }}-${{ github.run_attempt }}",
      path: "${{ runner.temp }}/signed-release-attestation-${{ matrix.key }}/signed-release-attestation.json",
      "if-no-files-found": "error",
      "include-hidden-files": false,
      "compression-level": 0,
      overwrite: false,
      "retention-days": 30,
    },
  }, "native platform signed release attestation upload");

  const orderedSteps = [
    signingConfiguration,
    signingImport,
    archive,
    exportedArtifact,
    signedArtifacts,
    upload,
    cleanup,
    attestation,
    attestationUpload,
  ];
  if (orderedSteps.some((step, index) => index > 0 && steps.indexOf(step) <= steps.indexOf(orderedSteps[index - 1]))) {
    fail("native platform signing, export, verification, digest-bound upload, and cleanup steps must remain in reviewed order.");
  }

  const postContractFingerprint = workflowSequenceFingerprint(steps.slice(expectedPrelude.length));
  if (postContractFingerprint !== PLATFORM_POST_SMOKE_SEQUENCE_FINGERPRINT) {
    fail(`native platform post-contract signing sequence must match the reviewed fingerprint (received ${postContractFingerprint}).`);
  }
  const jobsFingerprint = workflowSequenceFingerprint(jobs);
  if (jobsFingerprint !== PLATFORM_WORKFLOW_JOBS_FINGERPRINT) {
    fail(`native platform workflow jobs must match the reviewed protected-release graph fingerprint (received ${jobsFingerprint}).`);
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
  const jobsFingerprint = workflowSequenceFingerprint(jobs);
  if (jobsFingerprint !== CLOUDFLARE_WORKFLOW_JOBS_FINGERPRINT) {
    fail(`Cloudflare workflow jobs must match the reviewed production-release graph fingerprint (received ${jobsFingerprint}).`);
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
  if (!sameValue(Object.keys(jobs), ["capture", "capture_maccatalyst"])) {
    fail("native screenshot candidate workflow must expose exactly its reviewed simulator matrix and distinct Mac Catalyst hierarchy jobs.");
  }
  const simulatorCaptureJob = record(jobs.capture, "native simulator screenshot capture job");
  if (simulatorCaptureJob["runs-on"] !== "macos-latest") {
    fail("native simulator screenshot capture must run on macos-latest.");
  }
  const catalystCaptureJob = record(jobs.capture_maccatalyst, "native Mac Catalyst screenshot capture job");
  if (catalystCaptureJob["runs-on"] !== "macos-26-intel") {
    fail("native Mac Catalyst screenshot capture must run on macos-26-intel for exact live-window geometry.");
  }
  if (catalystCaptureJob["timeout-minutes"] !== 90) {
    fail("native Mac Catalyst screenshot capture timeout must remain 90 minutes.");
  }
  exactRecord(
    catalystCaptureJob.env,
    { DEVELOPER_DIR: "/Applications/Xcode_26.6.app/Contents/Developer" },
    "native Mac Catalyst screenshot capture toolchain",
  );
  if (!Array.isArray(catalystCaptureJob.steps)) {
    fail("native Mac Catalyst screenshot capture steps must be a sequence.");
  }
  const capacityPreflight = stepByName(
    catalystCaptureJob.steps,
    "Prove hosted Catalyst capture capacity",
    "native Mac Catalyst screenshot capacity preflight",
  );
  const harnessValidation = stepByName(
    catalystCaptureJob.steps,
    "Validate credential-free Mac Catalyst harness",
    "native Mac Catalyst screenshot harness validation",
  );
  const cleanSourceProof = stepByName(
    catalystCaptureJob.steps,
    "Prove exact clean source immediately before Catalyst capture",
    "native Mac Catalyst screenshot clean-source proof",
  );
  if (catalystCaptureJob.steps.indexOf(capacityPreflight) !== catalystCaptureJob.steps.indexOf(harnessValidation) + 1 ||
      catalystCaptureJob.steps.indexOf(capacityPreflight) >= catalystCaptureJob.steps.indexOf(cleanSourceProof)) {
    fail("native Mac Catalyst screenshot capacity preflight must run immediately after harness validation and before the clean-source proof.");
  }
  const jobsFingerprint = workflowSequenceFingerprint(jobs);
  if (jobsFingerprint !== SCREENSHOT_WORKFLOW_JOBS_FINGERPRINT) {
    fail(`native screenshot candidate workflow jobs must match the reviewed capture graph fingerprint (received ${jobsFingerprint}).`);
  }
}

function verifyScreenshotReleaseWorkflow(workflowSource) {
  const label = "Apple screenshot release-ready workflow";
  const workflow = parseEffectiveWorkflow(
    workflowSource,
    label,
    ".github/workflows/apple-screenshot-release-ready.yml",
  );
  if (Object.hasOwn(workflow, "defaults")) {
    fail(`${label} workflow-level defaults are forbidden.`);
  }
  exactRecord(workflow.permissions, SCREENSHOT_RELEASE_ROOT_PERMISSIONS, `${label} permissions`);
  exactRecord(workflow.concurrency, SCREENSHOT_RELEASE_ROOT_CONCURRENCY, `${label} concurrency`);
  const inputs = workflowDispatch(workflow, label);
  const stringInputs = [
    "capture_run_id",
    "source_commit",
    "visual_reviewer",
    "privacy_reviewer",
    "signed_parity_reviewer",
    "signed_release_evidence",
  ];
  const booleanInputs = [
    "visual_review_approved",
    "privacy_review_approved",
    "signed_release_parity_approved",
  ];
  const expectedInputOrder = [
      "capture_run_id",
      "source_commit",
      "visual_reviewer",
      "visual_review_approved",
      "privacy_reviewer",
      "privacy_review_approved",
      "signed_parity_reviewer",
      "signed_release_parity_approved",
      "signed_release_evidence",
  ];
  if (!sameValue(Object.keys(inputs), expectedInputOrder)) {
    fail(`${label} input order must be exactly ${expectedInputOrder.join(", ")}.`);
  }
  for (const name of stringInputs) {
    exactRecordWithAllowedKeys(
      inputs[name],
      { required: true, type: "string" },
      ["description"],
      `${label} ${name} input`,
    );
  }
  for (const name of booleanInputs) {
    exactRecordWithAllowedKeys(
      inputs[name],
      { required: true, default: false, type: "boolean" },
      ["description"],
      `${label} ${name} input`,
    );
  }
  if (/\$\{\{\s*secrets(?:\.|\[)/i.test(JSON.stringify(workflow))) {
    fail(`${label} must use only the built-in read-only token and never repository secrets.`);
  }
  const jobs = record(workflow.jobs, `${label} jobs`);
  if (!sameValue(Object.keys(jobs), ["assemble_and_validate"])) {
    fail(`${label} must expose exactly one reviewed assembly job.`);
  }
  const job = record(jobs.assemble_and_validate, `${label} assembly job`);
  exactRecordWithAllowedKeys(
    job,
    {
      name: "Assemble approved 26-frame upload evidence",
      "runs-on": "macos-latest",
      "timeout-minutes": 45,
      environment: { name: "ios-app-store-release" },
    },
    ["env", "steps"],
    `${label} assembly job header`,
  );
  const steps = job.steps;
  if (!Array.isArray(steps)) fail(`${label} steps must be a sequence.`);
  const dispatchPreflight = stepByName(
    steps,
    "Validate exact protected dispatch inputs",
    `${label} canonical repository dispatch preflight`,
  );
  requireText(dispatchPreflight.run, [
    'ENV.fetch("GITHUB_REPOSITORY") == "TastyHeadphones/QuakeSignal"',
    'ENV.fetch("GITHUB_REF") == "refs/heads/main"',
    'ENV.fetch("REF_PROTECTED") == "true"',
    "reviewer == reviewer.strip",
    "reviewer.match?(/[<>]/)",
    "reviewer.match?(/\\b(?:tbd|todo|unknown|placeholder)\\b/i)",
    'abort "#{kind} approval reviewer is a placeholder" if placeholder',
    'signed_evidence.keys.sort == %w[reviewedAtUtc signedRunIds]',
    'run_ids.fetch("ios-ipados") == run_ids.fetch("watchos")',
    'run_ids.values.uniq.length == 4',
    'parsed.utc.iso8601 == raw',
  ], `${label} canonical repository dispatch preflight command`);
  const reviewerBinding = stepByName(
    steps,
    "Bind named reviewers to protected environment approval",
    `${label} protected environment reviewer binding`,
  );
  requireText(reviewerBinding.run, [
    "repos/TastyHeadphones/QuakeSignal/actions/runs/$GITHUB_RUN_ID/approvals",
    '[expected, "#{expected}@main"].include?(actual)',
    'expected_workflow_path?(run.fetch("path"), ".github/workflows/apple-screenshot-release-ready.yml")',
    'environment.fetch("name") == "ios-app-store-release"',
    'review.fetch("state") == "approved"',
    'approved_logins.include?(login)',
    'login.casecmp?(ENV.fetch("GITHUB_ACTOR"))',
    "finalizer-environment-approval.json",
  ], `${label} protected environment reviewer binding command`);
  const checkout = stepByName(steps, "Check out exact source commit", `${label} checkout`);
  exactRecord(checkout, {
    name: "Check out exact source commit",
    uses: CHECKOUT_ACTION,
    with: {
      ref: "${{ inputs.source_commit }}",
      "fetch-depth": 0,
      "persist-credentials": false,
    },
  }, `${label} checkout`);
  const initialSignedRuns = stepByName(
    steps,
    "Verify exact successful signed release runs and attestation artifacts",
    `${label} signed release run verification`,
  );
  requireText(initialSignedRuns.run, [
    "repos/TastyHeadphones/QuakeSignal/actions/runs/$run_id",
    '[expected, "#{expected}@main"].include?(actual)',
    'expected_workflow_path?(run.fetch("path"), workflow_file)',
    'run.fetch("status") == "completed"',
    'run.fetch("conclusion") == "success"',
    'run.fetch("head_sha") == source',
    'specs.values.map(&:first).uniq.length == 4',
    "signed-runs-api-attestation.json",
  ], `${label} signed release run verification command`);
  const signedDownloads = [
    [
      "Download exact iOS and watchOS signed attestation",
      "signed-release-attestation-ios-ipados-watchos-${{ inputs.source_commit }}-${{ steps.dispatch-evidence.outputs.ios_run_id }}-${{ steps.signed-runs.outputs.ios_run_attempt }}",
      "${{ env.SIGNED_DOWNLOAD_ROOT }}/ios-ipados-watchos",
      "${{ steps.dispatch-evidence.outputs.ios_run_id }}",
    ],
    [
      "Download exact tvOS signed attestation",
      "signed-release-attestation-tvos-${{ inputs.source_commit }}-${{ steps.dispatch-evidence.outputs.tvos_run_id }}-${{ steps.signed-runs.outputs.tvos_run_attempt }}",
      "${{ env.SIGNED_DOWNLOAD_ROOT }}/tvos",
      "${{ steps.dispatch-evidence.outputs.tvos_run_id }}",
    ],
    [
      "Download exact visionOS signed attestation",
      "signed-release-attestation-visionos-${{ inputs.source_commit }}-${{ steps.dispatch-evidence.outputs.visionos_run_id }}-${{ steps.signed-runs.outputs.visionos_run_attempt }}",
      "${{ env.SIGNED_DOWNLOAD_ROOT }}/visionos",
      "${{ steps.dispatch-evidence.outputs.visionos_run_id }}",
    ],
    [
      "Download exact Mac Catalyst signed attestation",
      "signed-release-attestation-maccatalyst-${{ inputs.source_commit }}-${{ steps.dispatch-evidence.outputs.maccatalyst_run_id }}-${{ steps.signed-runs.outputs.maccatalyst_run_attempt }}",
      "${{ env.SIGNED_DOWNLOAD_ROOT }}/maccatalyst",
      "${{ steps.dispatch-evidence.outputs.maccatalyst_run_id }}",
    ],
  ].map(([name, artifactName, path, runId]) => {
    const step = stepByName(steps, name, `${label} ${name}`);
    exactRecord(step, {
      name,
      uses: DOWNLOAD_ARTIFACT_ACTION,
      with: {
        name: artifactName,
        path,
        repository: "${{ github.repository }}",
        "run-id": runId,
        "github-token": "${{ github.token }}",
      },
    }, `${label} ${name}`);
    return step;
  });
  const signedTopology = stepByName(
    steps,
    "Validate four signed attestations and exact release topology",
    `${label} signed release topology validation`,
  );
  requireText(signedTopology.run, [
    'attestation.fetch("distributionMode") == "testflight-upload"',
    'attestation.fetch("headSha") == source',
    'records.values.map { |run, _artifact| run.fetch("runId") }.uniq.length == 4',
    'records.values.map { |run, _artifact| run.fetch("artifact").fetch("id") }.uniq.length == 4',
    'records.values.map { |run, _artifact| run.fetch("artifact").fetch("digest") }.uniq.length == 4',
    'records.values.map { |_run, artifact| artifact.fetch("sha256") }.uniq.length == 4',
    'platform_rows.fetch(0).fetch("signedReleaseRunId") == platform_rows.fetch(2).fetch("signedReleaseRunId")',
    'platform_rows.fetch(0).fetch("signedReleaseArtifactSha256") == platform_rows.fetch(2).fetch("signedReleaseArtifactSha256")',
    "validated-signed-release-evidence.json",
  ], `${label} signed release topology validation command`);
  const initialRunAttestation = stepByName(
    steps,
    "Verify exact successful capture run and five artifacts",
    `${label} canonical capture-run attestation`,
  );
  requireText(initialRunAttestation.run, [
    "repos/TastyHeadphones/QuakeSignal/actions/runs/$CAPTURE_RUN_ID",
    '[expected, "#{expected}@main"].include?(actual)',
    'expected_workflow_path?(run.fetch("path"), ".github/workflows/apple-platform-screenshots.yml")',
    'repository = "TastyHeadphones/QuakeSignal"',
    'ENV.fetch("GITHUB_REPOSITORY") == repository',
    'run.dig("repository", "full_name") == repository',
    'run.dig("head_repository", "full_name") == repository',
  ], `${label} canonical capture-run attestation command`);
  const download = stepByName(steps, "Download exact candidate artifacts", `${label} artifact download`);
  exactRecord(download, {
    name: "Download exact candidate artifacts",
    uses: DOWNLOAD_ARTIFACT_ACTION,
    with: {
      pattern: "UNAPPROVED-debug-*-${{ inputs.source_commit }}",
      path: "${{ env.DOWNLOAD_ROOT }}",
      "merge-multiple": false,
      repository: "${{ github.repository }}",
      "run-id": "${{ inputs.capture_run_id }}",
      "github-token": "${{ github.token }}",
    },
  }, `${label} artifact download`);
  const postDownloadReverify = stepByName(
    steps,
    "Reverify run and artifact identities after download",
    `${label} post-download run revalidation`,
  );
  exactRecordWithAllowedKeys(
    postDownloadReverify,
    {
      name: "Reverify run and artifact identities after download",
      env: { GH_TOKEN: "${{ github.token }}" },
    },
    ["run"],
    `${label} post-download run revalidation`,
  );
  requireText(postDownloadReverify.run, [
    "repos/TastyHeadphones/QuakeSignal/actions/runs/$CAPTURE_RUN_ID",
    '[expected, "#{expected}@main"].include?(actual)',
    'expected_workflow_path?(run.fetch("path"), attestation.fetch("workflowFile"))',
    "actions/runs/$CAPTURE_RUN_ID",
    "actions/runs/$CAPTURE_RUN_ID/artifacts?per_page=100",
    "capture-run-attestation.json",
    'run.fetch("status") == "completed"',
    'run.fetch("conclusion") == "success"',
    "second_artifacts == expected_records",
    "JSON.generate(second_artifacts) == JSON.generate(expected_records)",
  ], `${label} post-download run revalidation command`);
  const safeInventory = stepByName(
    steps,
    "Safely inventory five packages and all 26 frames",
    `${label} safe downloaded inventory`,
  );
  const recordApproval = stepByName(
    steps,
    "Record named reviews and signed Release parity",
    `${label} release approval recorder`,
  );
  requireText(recordApproval.run, [
    '"schemaVersion" => 3',
    "finalizer-environment-approval.json",
    "validated-signed-release-evidence.json",
    'parsed_review_times.fetch("signedReleaseParity") < latest_signed_run',
    'reviewed_at = parsed_review_times.values.max.utc.iso8601',
    '"signedReleaseParityApproved" => true',
  ], `${label} release approval recorder command`);
  const upload = stepByName(
    steps,
    "Upload one short-lived approved screenshot artifact",
    `${label} final upload`,
  );
  exactRecord(upload, {
    name: "Upload one short-lived approved screenshot artifact",
    uses: UPLOAD_ARTIFACT_ACTION,
    with: {
      name: "APPROVED-build10-apple-screenshots-${{ inputs.source_commit }}",
      path: "${{ env.EVIDENCE_ROOT }}/ios/AppStore/screenshot-set-index-v1.1-build10.json\n${{ env.EVIDENCE_ROOT }}/ios/AppStore/screenshot-release-sets-v1.1-build10/${{ inputs.source_commit }}\n",
      "if-no-files-found": "error",
      "include-hidden-files": false,
      "compression-level": 0,
      overwrite: false,
      "retention-days": 3,
    },
  }, `${label} final upload`);
  const allRunSource = steps
    .filter((step) => isRecord(step) && typeof step.run === "string")
    .map((step) => step.run)
    .join("\n");
  for (const required of [
    ".github/workflows/apple-platform-screenshots.yml",
    "UNAPPROVED-debug-simulator-ios-ipados-#{source}",
    "UNAPPROVED-debug-simulator-tvos-#{source}",
    "UNAPPROVED-debug-simulator-watchos-#{source}",
    "UNAPPROVED-debug-simulator-visionos-#{source}",
    "UNAPPROVED-debug-maccatalyst-direct-uikit-#{source}",
    "--release-evidence-root=$EVIDENCE_ROOT",
    "--require-build10-screenshot-release-ready",
    "--expected-source-commit=\"$SOURCE_COMMIT\"",
    "--screenshot-release-evidence-root=\"$EVIDENCE_ROOT\"",
    "release-approval.json",
    "visual",
    "privacy",
    "signedReleaseParity",
    "signedRunIds",
    "reviewedAtUtc",
    "validated-signed-release-evidence.json",
    "finalizer-environment-approval.json",
    "signedReleaseRunId",
    "signedReleaseRunAttempt",
    "signedMarketingVersion",
    "signedBuildNumber",
    "signedDistributionMode",
    "signedReleaseAttestedAtUtc",
    "signedRunCompletedAtUtc",
    "post-download capture verification failed",
    "TastyHeadphones/QuakeSignal",
  ]) {
    if (!allRunSource.includes(required)) {
      fail(`${label} must retain ${JSON.stringify(required)}.`);
    }
  }
  if (/\bxcodebuild\s+(?:archive|-exportArchive)\b|\bxcrun\s+altool\b/.test(allRunSource)) {
    fail(`${label} must never build, sign, retain, or upload an Apple binary.`);
  }
  if (steps.indexOf(dispatchPreflight) >= steps.indexOf(reviewerBinding) ||
      steps.indexOf(reviewerBinding) >= steps.indexOf(checkout) ||
      steps.indexOf(checkout) >= steps.indexOf(initialSignedRuns) ||
      signedDownloads.some((step, index) =>
        steps.indexOf(step) <= steps.indexOf(index === 0 ? initialSignedRuns : signedDownloads[index - 1])) ||
      steps.indexOf(signedDownloads.at(-1)) >= steps.indexOf(signedTopology) ||
      steps.indexOf(signedTopology) >= steps.indexOf(initialRunAttestation) ||
      steps.indexOf(checkout) >= steps.indexOf(download) ||
      steps.indexOf(download) >= steps.indexOf(postDownloadReverify) ||
      steps.indexOf(postDownloadReverify) >= steps.indexOf(safeInventory) ||
      steps.indexOf(safeInventory) >= steps.indexOf(recordApproval) ||
      steps.indexOf(recordApproval) >= steps.indexOf(upload) ||
      steps.indexOf(safeInventory) >= steps.indexOf(upload)) {
    fail(`${label} reviewer binding, four signed-run downloads, capture download, validation, approval, and final upload order drifted.`);
  }
  const jobsFingerprint = workflowSequenceFingerprint(jobs);
  if (jobsFingerprint !== SCREENSHOT_RELEASE_WORKFLOW_JOBS_FINGERPRINT) {
    fail(`${label} jobs must match the reviewed hosted approval graph fingerprint (received ${jobsFingerprint}).`);
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
  await verifyAbsentNpmControlFiles(root);
  const [
    project,
    projectFile,
    infoPlists,
    releaseEntitlements,
    schemes,
    platformCapabilityPolicy,
    workerConfig,
    workerPackage,
    workerPackageLock,
    exportOptions,
    iosWorkflow,
    platformWorkflow,
    screenshotWorkflow,
    screenshotReleaseWorkflow,
    macCatalystScreenshotPlan,
    cloudflareWorkflow,
    releaseHooks,
    releaseCriticalHelpers,
    screenshotAutomationHelpers,
    workflowFiles,
  ] = await Promise.all([
    readFile(path(contractFiles.project), "utf8"),
    readFile(path(contractFiles.projectFile), "utf8"),
    Promise.all(contractFiles.infoPlists.map((relativePath) => readFile(path(relativePath), "utf8"))),
    Promise.all(contractFiles.releaseEntitlements.map((relativePath) => readFile(path(relativePath), "utf8"))),
    Promise.all(contractFiles.schemes.map(async (relativePath) => ({
      path: relativePath,
      source: await readFile(path(relativePath), "utf8"),
    }))),
    Promise.all(contractFiles.platformCapabilityPolicy.map(async (relativePath) => ({
      path: relativePath,
      source: await readFile(path(relativePath), "utf8"),
    }))),
    readFile(path(contractFiles.workerConfig), "utf8"),
    readReviewedRegularFile(root, contractFiles.workerPackage),
    readReviewedRegularFile(root, contractFiles.workerPackageLock),
    readFile(path(contractFiles.exportOptions), "utf8"),
    readFile(path(contractFiles.iosWorkflow), "utf8"),
    readFile(path(contractFiles.platformWorkflow), "utf8"),
    readFile(path(contractFiles.screenshotWorkflow), "utf8"),
    readFile(path(contractFiles.screenshotReleaseWorkflow), "utf8"),
    readFile(path(contractFiles.macCatalystScreenshotPlan), "utf8"),
    readFile(path(contractFiles.cloudflareWorkflow), "utf8"),
    readReviewedCiScriptInventory(root),
    Promise.all(contractFiles.releaseCriticalHelpers.map(async (relativePath) => ({
      path: relativePath,
      source: await readReviewedRegularFile(root, relativePath),
    }))),
    readReviewedScreenshotAutomationInventory(root),
    readReviewedWorkflowInventory(root),
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
  const xcodeSourceGraphFingerprint = workflowSequenceFingerprint([
    { path: contractFiles.project, source: project },
    { path: contractFiles.projectFile, source: projectFile },
  ]);
  for (const [index, infoPlist] of infoPlists.entries()) {
    verifyInfoPlist(infoPlist, contractFiles.infoPlists[index], index === 0);
  }
  verifyReleaseEntitlements(releaseEntitlements);
  const xcodeSchemesFingerprint = verifyReviewedFileFingerprint(
    schemes,
    contractFiles.schemes,
    XCODE_SCHEMES_FINGERPRINT,
    "shared archive schemes",
  );
  const platformCapabilitySources = Object.fromEntries(
    platformCapabilityPolicy.map(({ path, source }) => [path, source]),
  );
  for (const privacyManifestPath of FOREGROUND_PRIVACY_MANIFEST_PATHS) {
    verifyVisionPrivacyManifest(
      platformCapabilitySources[privacyManifestPath],
      privacyManifestPath,
    );
  }
  verifyMacCatalystScreenshotRouting(
    platformCapabilitySources["ios/QuakeSignal/Features/Root/RootView.swift"],
    platformCapabilitySources["ios/QuakeSignal/Features/Settings/SettingsView.swift"],
    platformCapabilitySources["ios/QuakeSignal/Features/Home/QuakeRowView.swift"],
    platformCapabilitySources["ios/QuakeSignalShared/ScreenshotAutomation.swift"],
  );
  const platformCapabilitiesFingerprint = verifyReviewedFileFingerprint(
    platformCapabilityPolicy,
    contractFiles.platformCapabilityPolicy,
    PLATFORM_CAPABILITIES_FINGERPRINT,
    "foreground-only Apple platform policy",
  );
  verifyWorkerReleaseScripts(workerPackage);
  const workerDependencyGraphFingerprint = verifyReviewedFileFingerprint(
    [
      { path: contractFiles.workerPackage, source: workerPackage },
      { path: contractFiles.workerPackageLock, source: workerPackageLock },
    ],
    [contractFiles.workerPackage, contractFiles.workerPackageLock],
    WORKER_DEPENDENCY_GRAPH_FINGERPRINT,
    "Worker npm dependency graph",
  );
  const releaseCriticalHelpersFingerprint = verifyReviewedFileFingerprint(
    releaseCriticalHelpers,
    contractFiles.releaseCriticalHelpers,
    RELEASE_CRITICAL_HELPERS_FINGERPRINT,
    "release-critical Worker helpers",
  );
  const screenshotAutomationHelpersFingerprint = verifyScreenshotAutomationHelpers(
    screenshotAutomationHelpers,
  );
  const macCatalystScreenshotPlanFingerprint = verifyMacCatalystScreenshotPlan(
    macCatalystScreenshotPlan,
  );
  verifyExportOptions(exportOptions);
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
  const policyFingerprint = appAttestPolicyFingerprint(
    workerVars,
    allowedBundleVersions,
    appIdentityRoutes,
  );
  const xcodeCloudReleaseHooksFingerprint = verifyXcodeCloudReleaseHooks(releaseHooks);
  verifyXcodeCloudGuardConstants(releaseHooks, {
    BUILD_NUMBER: buildNumber,
    MARKETING_VERSION: "1.1",
    TEAM_ID: "5TT564H883",
    RELEASE_REF: "refs/heads/main",
    RELEASE_WORKFLOW: `QuakeSignal 1.1 (${buildNumber}) Native Release`,
    PRODUCT_NAME: "QuakeSignal",
    WORKER_ORIGIN: APPROVED_WORKER_ORIGIN,
    APP_ATTEST_FINGERPRINT: policyFingerprint,
    XCODE_SOURCE_GRAPH_FINGERPRINT: xcodeSourceGraphFingerprint,
    XCODE_SCHEMES_FINGERPRINT: xcodeSchemesFingerprint,
    PLATFORM_CAPABILITIES_FINGERPRINT: platformCapabilitiesFingerprint,
  });
  const workerDeploymentConfigFingerprint = verifyReviewedFileFingerprint(
    [{ path: contractFiles.workerConfig, source: workerConfig }],
    [contractFiles.workerConfig],
    WORKER_DEPLOYMENT_CONFIG_FINGERPRINT,
    "production Worker deployment configuration",
  );
  verifyArchiveWorkflow(iosWorkflow, buildNumber);
  verifyPlatformArchiveWorkflow(platformWorkflow, buildNumber);
  verifyScreenshotCandidateWorkflow(screenshotWorkflow);
  verifyScreenshotReleaseWorkflow(screenshotReleaseWorkflow);
  verifyProductionDeploymentSerialization(cloudflareWorkflow);
  verifyWorkflowDirectoryPolicy(workflowFiles);
  return {
    buildNumber,
    allowedBundleVersions,
    appIdentityRoutes,
    generatedProjectEntries,
    xcodeSourceGraphFingerprint,
    xcodeSchemesFingerprint,
    platformCapabilitiesFingerprint,
    releaseCriticalHelpersFingerprint,
    screenshotAutomationHelpersFingerprint,
    macCatalystScreenshotPlanFingerprint,
    workerDependencyGraphFingerprint,
    workerDeploymentConfigFingerprint,
    xcodeCloudReleaseHooksFingerprint,
    appAttestPolicyFingerprint: policyFingerprint,
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
        `app_attest_policy_fingerprint=${verified.appAttestPolicyFingerprint}\nbuild_number=${verified.buildNumber}\n`,
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
