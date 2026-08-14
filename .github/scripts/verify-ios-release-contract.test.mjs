import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import test from "node:test";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";

import { verifyIOSReleaseContract } from "./verify-ios-release-contract.mjs";

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const approvedOrigin = "https://quakesignal-api.hopeso.workers.dev";

function fixtureFiles({
  buildNumber = "3",
  projectFileVersions = [buildNumber, buildNumber, buildNumber],
  infoBundleVersion = "$(CURRENT_PROJECT_VERSION)",
  allowedVersions = `1,2,${buildNumber}`,
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
    "ios/project.yml": `settings:\n  base:\n    CURRENT_PROJECT_VERSION: "${buildNumber}"\n`,
    "ios/QuakeSignal.xcodeproj/project.pbxproj": projectFileVersions
      .map((version) => `\t\t\t\tCURRENT_PROJECT_VERSION = ${version};`)
      .join("\n"),
    "ios/QuakeSignal/Supporting/Info.plist": `<?xml version="1.0"?>\n<plist><dict>\n<key>CFBundleVersion</key>\n<string>${infoBundleVersion}</string>\n</dict></plist>\n`,
    "backend/cloudflare/wrangler.jsonc": `{\n  "vars": {\n    "APP_ATTEST_ENFORCEMENT": "required",\n    "APP_ATTEST_APP_ID": "5TT564H883.com.quakesignal.app",\n    "APP_ATTEST_ALLOWED_BUNDLE_VERSIONS": "${allowedVersions}",\n    "APP_ATTEST_REQUIRE_RELEASE_METADATA": "false"\n  }\n}${workerConfigSuffix}\n`,
    ".github/workflows/ios.yml": `name: iOS\non:\n  workflow_dispatch:\n    inputs:\n      build_number:\n        default: "${workflowDefault}"\n        type: string\nenv:\n  XCODE_PROJECT: ios/QuakeSignal.xcodeproj\n  XCODE_SCHEME: QuakeSignal\n  XCODEGEN_VERSION: 2.46.0\n  XCODEGEN_SHA256: 4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806\njobs:\n  testflight:\n    steps:\n      - name: Check out repository\n        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1\n      - name: Verify iOS and Worker release contract\n        id: release-contract\n        env:\n          BUILD_NUMBER: \${{ inputs.build_number }}\n        run: node .github/scripts/verify-ios-release-contract.mjs --build-number "$BUILD_NUMBER"\n      - name: Verify production notification origin readiness and contract\n        working-directory: backend/cloudflare\n        env:\n          IOS_RELEASE_API_BASE_URL: ${remoteOrigin}\n          BUILD_NUMBER: \${{ inputs.build_number }}\n          APP_ATTEST_POLICY_FINGERPRINT: \${{ steps.release-contract.outputs.app_attest_policy_fingerprint }}\n        run: |\n${remoteRun}\n      - name: Archive signed App Store build\n        env:\n          BUILD_NUMBER: \${{ inputs.build_number }}\n          IOS_PROFILE_NAME: \${{ vars.IOS_APP_STORE_PROFILE_NAME }}\n          IOS_RELEASE_API_BASE_URL: \${{ vars.CLOUDFLARE_WORKER_URL }}\n        run: >-\n          xcodebuild archive\n          -project "$XCODE_PROJECT"\n          -scheme "$XCODE_SCHEME"\n          -configuration ${archiveConfiguration}\n          -destination 'generic/platform=iOS'\n          -archivePath "$RUNNER_TEMP/QuakeSignal.xcarchive"\n          DEVELOPMENT_TEAM=5TT564H883\n          CODE_SIGN_STYLE=Manual\n          CODE_SIGN_IDENTITY='Apple Distribution'\n          PROVISIONING_PROFILE_SPECIFIER="$IOS_PROFILE_NAME"\n          CURRENT_PROJECT_VERSION="$BUILD_NUMBER"\n          QUAKESIGNAL_API_BASE_URL="$IOS_RELEASE_API_BASE_URL"\n`,
  };
  files[".github/workflows/ios.yml"] = files[".github/workflows/ios.yml"]
    .replace(
      "        type: string\nenv:\n",
      `        type: string
      archive_only:
        description: Archive, export, and validate a signed IPA without uploading it to App Store Connect
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
  workflowDefault = "3",
  remoteOrigin = "${{ vars.CLOUDFLARE_WORKER_URL }}",
  remoteRunPrefix = "",
  archiveConfiguration = "Release",
} = {}) {
  let workflow = await readFile(join(repositoryRoot, ".github/workflows/ios.yml"), "utf8");
  const replaceOnce = (from, to, label) => {
    if (!workflow.includes(from)) throw new Error(`fixture could not locate ${label}`);
    workflow = workflow.replace(from, to);
  };

  if (workflowDefault !== "2") {
    replaceOnce(
      '        default: "2"\n        type: string\n',
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

async function writeFixture(options = {}) {
  const root = await mkdtemp(join(tmpdir(), "quakesignal-ios-release-contract-"));
  const files = fixtureFiles(options);
  files[".github/workflows/ios.yml"] = await fixtureWorkflow(options);
  files[".github/workflows/cloudflare.yml"] = await readFile(
    join(repositoryRoot, ".github/workflows/cloudflare.yml"),
    "utf8",
  );
  for (const [relativePath, contents] of Object.entries(files)) {
    const path = join(root, relativePath);
    await mkdir(dirname(path), { recursive: true });
    await writeFile(path, contents, "utf8");
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
  assert.equal(verified.buildNumber, "2");
  assert.deepEqual(verified.allowedBundleVersions, ["1", "2"]);
  assert.match(verified.appAttestPolicyFingerprint, /^sha256:[A-Za-z0-9_-]{43}$/);
});

test("a coordinated future build 3 contract passes without hardcoding its version", async (t) => {
  await withFixture(t, { buildNumber: "3" }, async (root) => {
    const verified = await verifyIOSReleaseContract({ root });
    assert.deepEqual(verified, {
      buildNumber: "3",
      allowedBundleVersions: ["1", "2", "3"],
      generatedProjectEntries: 3,
      appAttestPolicyFingerprint: "sha256:3vuP0dLgyorNEbQhOYncY7BnDCbwLG5giJl7le8P2EU",
    });
  });
});

test("fails closed on source/version drift", async (t) => {
  await withFixture(t, { buildNumber: "3" }, async (root) => {
    await assert.rejects(
      verifyIOSReleaseContract({ root, expectedBuildNumber: "2" }),
      /requested build_number 2 does not match ios\/project\.yml 3/i,
    );
  });
  await expectFailure(t, { projectFileVersions: ["3", "2", "3"] }, /does not match ios\/project\.yml 3/i);
  await expectFailure(t, { allowedVersions: "1,2" }, /must include ios\/project\.yml build 3/i);
  await expectFailure(t, { infoBundleVersion: "3" }, /Info\.plist CFBundleVersion interpolation/i);
  await expectFailure(t, { workflowDefault: "2" }, /build_number default 2 does not match ios\/project\.yml 3/i);
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
    await assert.rejects(verifyIOSReleaseContract({ root }), /must run checkout, static release contract, and remote policy smoke consecutively/i);
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
      "      archive_only:\n        description: Archive, export, and validate a signed IPA without uploading it to App Store Connect\n        required: false\n        default: false\n        type: boolean\n",
      "      archive_only:\n        description: Archive, export, and validate a signed IPA without uploading it to App Store Connect\n        required: false\n        default: true\n        type: boolean\n",
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

test("fails closed when a JSONC comment impersonates the Worker allow-list", async (t) => {
  await withFixture(t, { workerConfigSuffix: "\n// \"APP_ATTEST_ALLOWED_BUNDLE_VERSIONS\": \"1,2,3\"" }, async (root) => {
    const path = join(root, "backend/cloudflare/wrangler.jsonc");
    const contents = await readFile(path, "utf8");
    await writeFile(path, contents.replace('    "APP_ATTEST_ALLOWED_BUNDLE_VERSIONS": "1,2,3",\n', ""), "utf8");
    await assert.rejects(verifyIOSReleaseContract({ root }), /must be defined exactly once outside comments/i);
  });
});
