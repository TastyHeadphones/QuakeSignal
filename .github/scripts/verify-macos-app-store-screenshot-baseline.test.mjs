import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";
import { tmpdir } from "node:os";

import { verifyMacAppStoreScreenshotBaseline } from "./verify-macos-app-store-screenshot-baseline.mjs";

function git(root, ...arguments_) {
  return execFileSync("git", ["-C", root, ...arguments_], { encoding: "utf8" }).trim();
}

async function write(root, relativePath, contents) {
  const path = join(root, relativePath);
  await mkdir(join(path, ".."), { recursive: true });
  await writeFile(path, contents, "utf8");
}

async function repository(t) {
  const root = await mkdtemp(join(tmpdir(), "quakesignal-mac-baseline-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  git(root, "init", "--initial-branch=main");
  git(root, "config", "user.name", "QuakeSignal Test");
  git(root, "config", "user.email", "test@quakesignal.invalid");
  for (const [path, contents] of [
    ["desktop/src/app.ts", "export const release = '1.1.0';\n"],
    ["desktop/src-tauri/tauri.conf.json", '{"version":"1.1.0"}\n'],
    ["desktop/icons/icon.txt", "icon-v1\n"],
    ["desktop/package-lock.json", '{"lockfileVersion":3}\n'],
    ["desktop/AppStore/screenshot-provenance.json", '{"status":"pending"}\n'],
    ["desktop/AppStore/README.md", "pending review\n"],
    [".github/workflows/desktop-release.yml", "name: release-v1\n"],
    [".github/scripts/verify-desktop-release-contract.mjs", "// contract-v1\n"],
    [".github/scripts/verify-macos-app-store-screenshot-baseline.mjs", "// baseline-v1\n"],
    [".github/scripts/verify-store-assets.rb", "# assets-v1\n"],
  ]) await write(root, path, contents);
  git(root, "add", ".");
  git(root, "commit", "-m", "signed evidence baseline");
  return { root, baseline: git(root, "rev-parse", "HEAD") };
}

async function commitChange(root, relativePath, contents) {
  await write(root, relativePath, contents);
  git(root, "add", relativePath);
  git(root, "commit", "-m", `change ${relativePath}`);
  return git(root, "rev-parse", "HEAD");
}

test("allows a later protected-main commit that changes only App Store provenance/metadata", async (t) => {
  const { root, baseline } = await repository(t);
  await write(root, "desktop/AppStore/screenshot-provenance.json", '{"status":"approved","baseline":"recorded"}\n');
  await write(root, "desktop/AppStore/README.md", "named reviewer approved\n");
  git(root, "add", "desktop/AppStore");
  git(root, "commit", "-m", "record signed screenshot review");
  const current = git(root, "rev-parse", "HEAD");
  assert.deepEqual(
    verifyMacAppStoreScreenshotBaseline({ root, baselineCommit: baseline, currentCommit: current }),
    { baselineCommit: baseline, currentCommit: current },
  );
});

test("rejects every Mac binary, configuration, asset, lock, or packaging-input change", async (t) => {
  const relevantChanges = [
    ["desktop/src/app.ts", "export const release = 'changed';\n"],
    ["desktop/src-tauri/tauri.conf.json", '{"version":"1.1.1"}\n'],
    ["desktop/icons/icon.txt", "icon-v2\n"],
    ["desktop/package-lock.json", '{"lockfileVersion":4}\n'],
    [".github/workflows/desktop-release.yml", "name: release-v2\n"],
    [".github/scripts/verify-desktop-release-contract.mjs", "// contract-v2\n"],
    [".github/scripts/verify-macos-app-store-screenshot-baseline.mjs", "// baseline-v2\n"],
    [".github/scripts/verify-store-assets.rb", "# assets-v2\n"],
  ];
  for (const [path, contents] of relevantChanges) {
    await t.test(path, async (subtest) => {
      const { root, baseline } = await repository(subtest);
      const current = await commitChange(root, path, contents);
      assert.throws(
        () => verifyMacAppStoreScreenshotBaseline({ root, baselineCommit: baseline, currentCommit: current }),
        /application or packaging source changed/i,
      );
    });
  }
});
