import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import test from "node:test";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";

import { verifyDesktopReleaseContract } from "./verify-desktop-release-contract.mjs";

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

async function fixture(t, {
  mutateDesktop = (source) => source,
  mutateDesktopConfig = (source) => source,
  mutateHomebrew = (source) => source,
} = {}) {
  const root = await mkdtemp(join(tmpdir(), "quakesignal-desktop-release-contract-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const [desktop, desktopConfig, homebrew] = await Promise.all([
    readFile(join(repositoryRoot, ".github/workflows/desktop-release.yml"), "utf8"),
    readFile(join(repositoryRoot, "desktop/src-tauri/tauri.conf.json"), "utf8"),
    readFile(join(repositoryRoot, ".github/workflows/homebrew-tap.yml"), "utf8"),
  ]);
  for (const [path, source] of [
    [".github/workflows/desktop-release.yml", mutateDesktop(desktop)],
    ["desktop/src-tauri/tauri.conf.json", mutateDesktopConfig(desktopConfig)],
    [".github/workflows/homebrew-tap.yml", mutateHomebrew(homebrew)],
  ]) {
    const target = join(root, path);
    await mkdir(dirname(target), { recursive: true });
    await writeFile(target, source, "utf8");
  }
  return root;
}

async function expectFailure(t, options, expression) {
  const root = await fixture(t, options);
  await assert.rejects(verifyDesktopReleaseContract({ root }), expression);
}

function replaceOnce(source, from, to, label) {
  if (!source.includes(from)) throw new Error(`fixture could not locate ${label}`);
  return source.replace(from, to);
}

function replaceInMacosDirect(source, from, to, label) {
  const marker = "  macos-direct:\n";
  const offset = source.indexOf(marker);
  if (offset < 0) throw new Error("fixture could not locate macos-direct job");
  return `${source.slice(0, offset)}${replaceOnce(source.slice(offset), from, to, label)}`;
}

function replaceInMacosAppStore(source, from, to, label) {
  const marker = "  macos-app-store:\n";
  const offset = source.indexOf(marker);
  if (offset < 0) throw new Error("fixture could not locate macos-app-store job");
  return `${source.slice(0, offset)}${replaceOnce(source.slice(offset), from, to, label)}`;
}

test("the checked-in direct macOS and Homebrew release contracts are coherent", async () => {
  const verified = await verifyDesktopReleaseContract({ root: repositoryRoot });
  assert.deepEqual(verified, {
    directStepsFingerprint: "sha256:9_cZ-KeTzLZFiOlAwbIJw4av4Zlihs9Xr2eXsQfnbmA",
    macAppStoreStepsFingerprint: "sha256:RfLhsMpFJdK9JCx7AT0KvvvfuHb2YSV1YwWonSaPgAE",
    releaseStepsFingerprint: "sha256:3dX8Og0fyNOioMHFK-Jt8FiTZTqwkc8dhXjbovwV2qI",
    homebrewStepsFingerprint: "sha256:NuwuAFiTLY6LC19V3jx8XcjFSwpafYQVpgHgnveCywY",
  });
});

test("fails closed if any desktop release build skips the frontend safety-policy tests", async (t) => {
  for (const jobMarker of ["  windows:\n", "  macos-direct:\n", "  macos-app-store:\n"]) {
    await expectFailure(t, {
      mutateDesktop: (source) => {
        const offset = source.indexOf(jobMarker);
        assert.notEqual(offset, -1, `fixture must contain ${jobMarker.trim()}`);
        const before = source.slice(0, offset);
        const after = source.slice(offset);
        return `${before}${replaceOnce(
          after,
          "      - name: Test frontend safety policy\n        working-directory: desktop\n        run: npm test\n\n",
          "",
          "frontend safety-policy test gate",
        )}`;
      },
    }, /frontend safety-policy test gate/i);
  }
});

test("keeps artifact-only mechanical validation separate from the upload-only exact-source approval gate", async (t) => {
  await expectFailure(t, {
    mutateDesktop: (source) => replaceOnce(
      source,
      "      - name: Validate Mac App Store listing assets\n        run: ruby .github/scripts/verify-store-assets.rb\n",
      "      - name: Validate Mac App Store listing assets\n        run: ruby .github/scripts/verify-store-assets.rb --require-macos-release-ready --expected-source-commit=\"$GITHUB_SHA\"\n",
      "Mac App Store artifact-only listing-assets gate",
    ),
  }, /artifact-only listing-assets gate/i);
  await expectFailure(t, {
    mutateDesktop: (source) => replaceInMacosAppStore(
      source,
      "            --require-macos-release-ready \\\n            --expected-source-commit=\"$baseline\"",
      "            --expected-source-commit=\"$baseline\"",
      "Mac App Store upload screenshot approval",
    ),
  }, /upload screenshot release gate/i);
});

test("fails closed if Mac App Store dispatch defaults or protected upload conditions widen", async (t) => {
  await expectFailure(t, {
    mutateDesktop: (source) => replaceOnce(
      source,
      "      upload_macos_to_app_store_connect:\n        description: Build, validate, and upload only after exact-source screenshot approval\n        required: false\n        default: false\n",
      "      upload_macos_to_app_store_connect:\n        description: Build, validate, and upload only after exact-source screenshot approval\n        required: false\n        default: true\n",
      "Mac App Store upload default",
    ),
  }, /workflow_dispatch inputs/i);
  await expectFailure(t, {
    mutateDesktop: (source) => replaceInMacosAppStore(
      source,
      "      github.ref_protected &&\n",
      "      true &&\n",
      "Mac App Store protected-main condition",
    ),
  }, /macos-app-store job/i);
  await expectFailure(t, {
    mutateDesktop: (source) => replaceInMacosAppStore(
      source,
      "        if: github.event_name == 'workflow_dispatch' && inputs.upload_macos_to_app_store_connect\n",
      "        if: true\n",
      "Mac App Store explicit upload consent",
    ),
  }, /upload screenshot release gate|upload key step must remain conditional|macos-app-store steps/i);
  await expectFailure(t, {
    mutateDesktop: (source) => replaceInMacosAppStore(
      source,
      "          if [ \"$BUILD_ARTIFACT_ONLY\" = \"true\" ] && [ \"$UPLOAD_TO_APP_STORE_CONNECT\" = \"true\" ]; then\n",
      "          if false; then\n",
      "Mac App Store mutually exclusive mode gate",
    ),
  }, /mutually exclusive mode gate/i);
});

test("fails closed if a Mac App Store post-provenance or credential-ordering step changes", async (t) => {
  await expectFailure(t, {
    mutateDesktop: (source) => replaceInMacosAppStore(
      source,
      "xcrun altool --upload-package \"$MACOS_APP_STORE_PACKAGE\"",
      "echo upload-was-skipped \"$MACOS_APP_STORE_PACKAGE\"",
      "Mac App Store package upload command",
    ),
  }, /macos-app-store steps must match the reviewed/i);
  await expectFailure(t, {
    mutateDesktop: (source) => replaceInMacosAppStore(
      source,
      "      - name: Set up Node.js\n",
      "      - name: Set up Node.js\n        env:\n          EARLY_KEY: ${{ secrets.MACOS_APP_STORE_CONNECT_API_KEY }}\n",
      "Mac App Store pre-credential setup",
    ),
  }, /macos-app-store pre-credential step Set up Node\.js/i);
});

test("fails closed if the Mac App Store source or signed artifact version/build drifts from 1.1.0", async (t) => {
  await expectFailure(t, {
    mutateDesktopConfig: (source) => source.replace('"version": "1.1.0"', '"version": "1.0.0"'),
  }, /tauri\.conf\.json version must be exactly 1\.1\.0/i);
  for (const [from, to] of [
    ['expected_short_version="1.1.0"', 'expected_short_version="1.0.0"'],
    [
      '"CFBundleVersion" "$expected_bundle_version" "Mac App Store Info.plist"',
      '"CFBundleVersion" "1.0.0" "Mac App Store Info.plist"',
    ],
  ]) {
    await expectFailure(t, {
      mutateDesktop: (source) => replaceInMacosAppStore(
        source,
        from,
        to,
        "Mac App Store signed artifact version/build assertion",
      ),
    }, /signed artifact version\/build verification/i);
  }
});

test("fails closed if the protected tag or protected-main ancestry boundary widens", async (t) => {
  await expectFailure(t, {
    mutateDesktop: (source) => replaceOnce(
      source,
      "      github.ref_protected &&\n      github.repository == 'TastyHeadphones/QuakeSignal'",
      "      true &&\n      github.repository == 'TastyHeadphones/QuakeSignal'",
      "protected tag condition",
    ),
  }, /verify-release-provenance job/i);
  await expectFailure(t, {
    mutateDesktop: (source) => replaceOnce(
      source,
      "git merge-base --is-ancestor",
      "git merge-base --is-not-ancestor",
      "main ancestry command",
    ),
  }, /protected-main ancestry step/i);
});

test("fails closed if a direct macOS secret arrives before the unsigned build is complete", async (t) => {
  await expectFailure(t, {
    mutateDesktop: (source) => replaceInMacosDirect(
      source,
      "      - name: Set up Node.js\n",
      "      - name: Set up Node.js\n        env:\n          LEAK: ${{ secrets.MACOS_DEVELOPER_ID_CERTIFICATE }}\n",
      "pre-credential setup step",
    ),
  }, /pre-credential step Set up Node\.js/i);
});

test("fails closed if another job requests the direct-release credential environment", async (t) => {
  await expectFailure(t, {
    mutateDesktop: (source) => replaceOnce(
      source,
      "  windows:\n    name: Windows MSIX\n",
      "  windows:\n    name: Windows MSIX\n    environment:\n      name: macos-direct-release\n",
      "direct-release environment reuse",
    ),
  }, /only macos-direct may request the macos-direct-release environment/i);
});

test("fails closed if an unreviewed sibling job or dynamic environment could bypass release isolation", async (t) => {
  await expectFailure(t, {
    mutateDesktop: (source) => replaceOnce(
      source,
      "  windows:\n",
      "  unreviewed-release:\n    runs-on: macos-latest\n    steps: []\n\n  windows:\n",
      "unreviewed sibling job",
    ),
  }, /reviewed job graph/i);
  await expectFailure(t, {
    mutateDesktop: (source) => replaceOnce(
      source,
      "  windows:\n    name: Windows MSIX\n",
      "  windows:\n    name: Windows MSIX\n    environment: ${{ inputs.build_macos_direct && 'macos-direct-release' || 'windows-store-release' }}\n",
      "dynamic sibling environment",
    ),
  }, /non-direct release job windows must not select a dynamic environment/i);
});

test("fails closed if direct signing loses its protected environment or notarization configuration", async (t) => {
  await expectFailure(t, {
    mutateDesktop: (source) => replaceOnce(
      source,
      "      name: macos-direct-release\n",
      "      name: unprotected-release\n",
      "direct release environment",
    ),
  }, /macos-direct job/i);
  await expectFailure(t, {
    mutateDesktop: (source) => replaceOnce(
      source,
      "          NOTARY_API_ISSUER: ${{ secrets.MACOS_NOTARY_API_ISSUER }}\n",
      "          NOTARY_API_ISSUER: ${{ vars.MACOS_NOTARY_API_ISSUER }}\n",
      "notary issuer secret",
    ),
  }, /direct credential validation env/i);
});

test("fails closed if Developer ID, universal, staple, or Gatekeeper verification changes", async (t) => {
  for (const [from, to, label, expected] of [
    ["Authority=Developer ID Application", "Authority=Apple Distribution", "Developer ID authority", /direct artifact verification step\.run/i],
    ["for architecture in arm64 x86_64; do", "for architecture in arm64; do", "universal architecture check", /direct artifact verification step\.run/i],
    ["xcrun stapler validate \"$mounted_app\"", "true # stapler skipped", "mounted staple check", /direct artifact verification step\.run/i],
    ["spctl --assess --type execute --verbose=4 \"$mounted_app\"", "true # Gatekeeper skipped", "Gatekeeper check", /direct artifact verification step\.run/i],
  ]) {
    await expectFailure(t, {
      mutateDesktop: (source) => replaceOnce(source, from, to, label),
    }, expected);
  }
});

test("fails closed if the GitHub Release does not publish the direct artifact SHA256", async (t) => {
  await expectFailure(t, {
    mutateDesktop: (source) => replaceOnce(
      source,
      "sha256sum -- * > SHA256SUMS.txt",
      "true # checksum omitted",
      "SHA256 command",
    ),
  }, /SHA256 publication step/i);
  await expectFailure(t, {
    mutateDesktop: (source) => replaceOnce(
      source,
      "gh release upload \"$tag\" dist/* --clobber",
      "gh release upload \"$tag\" QuakeSignal.dmg --clobber",
      "release checksum upload",
    ),
  }, /GitHub Release publication step\.run/i);
});

test("fails closed if Homebrew no longer requires manual protected-main consent", async (t) => {
  await expectFailure(t, {
    mutateHomebrew: (source) => replaceOnce(
      source,
      "on:\n  workflow_dispatch:\n",
      "on:\n  push:\n    branches: [main]\n  workflow_dispatch:\n",
      "manual trigger",
    ),
  }, /manual-only/i);
  await expectFailure(t, {
    mutateHomebrew: (source) => replaceOnce(
      source,
      "      github.ref_protected &&\n      github.repository == 'TastyHeadphones/QuakeSignal'",
      "      true &&\n      github.repository == 'TastyHeadphones/QuakeSignal'",
      "Homebrew protected main condition",
    ),
  }, /Homebrew publish job/i);
});

test("fails closed if Homebrew provenance or checksum validation is weakened", async (t) => {
  await expectFailure(t, {
    mutateHomebrew: (source) => replaceOnce(
      source,
      "--commit \"$tag_commit\" --event push --limit 100",
      "--commit \"$tag_commit\" --event workflow_dispatch --limit 100",
      "workflow provenance event",
    ),
  }, /Homebrew release provenance step\.run/i);
  await expectFailure(t, {
    mutateHomebrew: (source) => replaceOnce(
      source,
      "Downloaded DMG does not match SHA256SUMS.txt",
      "Downloaded DMG may not match SHA256SUMS.txt",
      "checksum comparison",
    ),
  }, /Homebrew checksum and notarization step\.run/i);
});

test("fails closed if the cross-repository token appears before the final validated push", async (t) => {
  await expectFailure(t, {
    mutateHomebrew: (source) => replaceOnce(
      source,
      "          GH_TOKEN: ${{ github.token }}\n        run: |\n          set -euo pipefail\n          version=\"$INPUT_VERSION\"",
      "          GH_TOKEN: ${{ secrets.HOMEBREW_TAP_TOKEN }}\n        run: |\n          set -euo pipefail\n          version=\"$INPUT_VERSION\"",
      "Homebrew provenance token",
    ),
  }, /Homebrew pre-push step Verify the requested direct-release provenance/i);
  await expectFailure(t, {
    mutateHomebrew: (source) => replaceOnce(
      source,
      "          GH_TOKEN: ${{ secrets.HOMEBREW_TAP_TOKEN }}\n",
      "          GH_TOKEN: ${{ github.token }}\n",
      "final Homebrew token",
    ),
  }, /Homebrew final push env/i);
});

test("fails closed on duplicate keys and escaped secret references in effective YAML", async (t) => {
  await expectFailure(t, {
    mutateHomebrew: (source) => `${source}\npermissions:\n  contents: write\n`,
  }, /safe, duplicate-free effective YAML/i);
  await expectFailure(t, {
    mutateHomebrew: (source) => replaceOnce(
      source,
      "          GH_TOKEN: ${{ github.token }}\n        run: |\n          set -euo pipefail\n          version=\"$INPUT_VERSION\"",
      "          GH_TOKEN: \"${{ secre\\u0074s.HOMEBREW_TAP_TOKEN }}\"\n        run: |\n          set -euo pipefail\n          version=\"$INPUT_VERSION\"",
      "escaped Homebrew token",
    ),
  }, /Homebrew pre-push step Verify the requested direct-release provenance/i);
  await expectFailure(t, {
    mutateHomebrew: (source) => {
      const withAnchor = replaceOnce(
        source,
        "name: Publish Homebrew cask\n",
        "name: Publish Homebrew cask\ntap_token: &tap_token \"${{ secrets.HOMEBREW_TAP_TOKEN }}\"\n",
        "Homebrew token anchor",
      );
      return replaceOnce(
        withAnchor,
        "          GH_TOKEN: ${{ github.token }}\n        run: |\n          set -euo pipefail\n          version=\"$INPUT_VERSION\"",
        "          GH_TOKEN: *tap_token\n        run: |\n          set -euo pipefail\n          version=\"$INPUT_VERSION\"",
        "aliased Homebrew token",
      );
    },
  }, /Homebrew pre-push step Verify the requested direct-release provenance/i);
});
