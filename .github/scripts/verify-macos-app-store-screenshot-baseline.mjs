import { execFileSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
export const repositoryRoot = resolve(scriptDirectory, "../..");

const COMMIT_PATTERN = /^[0-9a-f]{40}$/;

// A privately handed-off signed package and the later upload build must use the
// same Mac application and packaging source. App Store listing
// metadata/provenance is deliberately excluded so a reviewer can record that
// separately approved comparison in a later protected-main commit without
// creating a self-referential SHA gate.
export const MAC_APP_STORE_RELEASE_RELEVANT_PATHS = [
  ".github/workflows/desktop-release.yml",
  ".github/scripts/verify-desktop-release-contract.mjs",
  ".github/scripts/verify-macos-app-store-screenshot-baseline.mjs",
  ".github/scripts/verify-store-assets.rb",
  "desktop",
  ":(exclude)desktop/AppStore",
];

function fail(message) {
  throw new Error(`Mac App Store screenshot baseline: ${message}`);
}

function commit(value, label) {
  const normalized = String(value ?? "").trim();
  if (!COMMIT_PATTERN.test(normalized)) {
    fail(`${label} must be a full lowercase 40-character commit SHA.`);
  }
  return normalized;
}

function git(root, arguments_, { allowFailure = false } = {}) {
  try {
    execFileSync("git", ["-C", root, ...arguments_], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    });
    return true;
  } catch (error) {
    if (allowFailure) return false;
    const detail = error && typeof error === "object" && "stderr" in error
      ? String(error.stderr).trim()
      : "";
    fail(`git ${arguments_[0]} failed${detail ? `: ${detail}` : "."}`);
  }
}

export function verifyMacAppStoreScreenshotBaseline({
  root = repositoryRoot,
  baselineCommit,
  currentCommit,
} = {}) {
  const baseline = commit(baselineCommit, "baseline");
  const current = commit(currentCommit, "current commit");
  if (!git(root, ["merge-base", "--is-ancestor", baseline, current], { allowFailure: true })) {
    fail("baseline commit must be an ancestor of the protected-main upload commit.");
  }
  if (!git(root, [
    "diff",
    "--quiet",
    baseline,
    current,
    "--",
    ...MAC_APP_STORE_RELEASE_RELEVANT_PATHS,
  ], { allowFailure: true })) {
    fail("Mac application or packaging source changed after the signed screenshot-comparison baseline.");
  }
  return { baselineCommit: baseline, currentCommit: current };
}

function parseArguments(arguments_) {
  if (
    arguments_.length !== 4 ||
    arguments_[0] !== "--baseline" ||
    arguments_[2] !== "--current"
  ) {
    fail("usage is --baseline <full commit> --current <full commit>.");
  }
  return { baselineCommit: arguments_[1], currentCommit: arguments_[3] };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const verified = verifyMacAppStoreScreenshotBaseline(parseArguments(process.argv.slice(2)));
    console.log(`Verified unchanged Mac App Store release source from ${verified.baselineCommit} through ${verified.currentCommit}.`);
  } catch (error) {
    console.error(`::error::${error instanceof Error ? error.message : "Mac App Store screenshot baseline verification failed."}`);
    process.exitCode = 1;
  }
}
