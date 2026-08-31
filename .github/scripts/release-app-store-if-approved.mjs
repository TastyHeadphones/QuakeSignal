import { createPrivateKey, createSign } from "node:crypto";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const API = "https://api.appstoreconnect.apple.com";
const APP_ID = "6800642443";
export const ALLOWED_PLATFORMS = ["IOS", "MAC_OS", "TV_OS", "VISION_OS"];
const RELEASE_WAIT_MS = 20 * 60_000;
const RELEASE_POLL_MS = 15_000;

export const IN_REVIEW_STATES = ["WAITING_FOR_REVIEW", "IN_REVIEW", "READY_FOR_REVIEW"];
export const REJECTED_STATES = ["REJECTED", "METADATA_REJECTED", "DEVELOPER_REJECTED"];
export const APPROVED_STATES = ["PENDING_DEVELOPER_RELEASE", "ACCEPTED"];
export const LIVE_STATES = ["READY_FOR_DISTRIBUTION"];
export const APPLE_ROLLOUT_STATES = ["PENDING_APPLE_RELEASE"];

const SELECT_PRIORITY = [
  ...APPROVED_STATES,
  ...APPLE_ROLLOUT_STATES,
  ...IN_REVIEW_STATES,
  ...REJECTED_STATES,
  ...LIVE_STATES,
];

function fail(message) {
  throw new Error(message);
}

function required(name) {
  const value = process.env[name];
  if (typeof value !== "string" || value.trim() === "") fail(`${name} is required.`);
  return value.trim();
}

function pemFromSecret(raw) {
  const trimmed = raw.trim().replace(/\\n/g, "\n");
  if (trimmed.includes("BEGIN")) return trimmed.endsWith("\n") ? trimmed : `${trimmed}\n`;
  return `-----BEGIN PRIVATE KEY-----\n${trimmed}\n-----END PRIVATE KEY-----\n`;
}

function jwt(keyId, issuer, pem) {
  const encode = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
  const now = Math.floor(Date.now() / 1000);
  const signingInput = `${encode({ alg: "ES256", kid: keyId, typ: "JWT" })}.${encode({
    iss: issuer,
    iat: now,
    exp: now + 19 * 60,
    aud: "appstoreconnect-v1",
  })}`;
  const key = createPrivateKey(pemFromSecret(pem));
  const signature = createSign("SHA256").update(signingInput).sign({ key, dsaEncoding: "ieee-p1363" });
  return `${signingInput}.${Buffer.from(signature).toString("base64url")}`;
}

function sleep(ms) {
  return new Promise((resolveSleep) => setTimeout(resolveSleep, ms));
}

async function api(token, method, path, body) {
  const response = await fetch(`${API}${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: "application/json",
      ...(body ? { "Content-Type": "application/json" } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await response.text();
  let payload = null;
  if (text) {
    try {
      payload = JSON.parse(text);
    } catch {
      payload = { raw: text.slice(0, 4000) };
    }
  }
  return { status: response.status, payload };
}

function errorDetail(payload) {
  const errors = payload?.errors;
  if (!Array.isArray(errors) || errors.length === 0) return JSON.stringify(payload ?? {});
  return errors.map((error) => error?.detail || error?.title || JSON.stringify(error)).join("; ");
}

async function collect(token, path) {
  const items = [];
  let next = path;
  while (next) {
    const relative = next.startsWith("http") ? next.slice(API.length) : next;
    const { status, payload } = await api(token, "GET", relative);
    if (status !== 200) fail(`GET ${relative} failed (${status}): ${errorDetail(payload)}`);
    if (Array.isArray(payload.data)) items.push(...payload.data);
    else if (payload.data) items.push(payload.data);
    next = payload.links?.next ?? null;
  }
  return items;
}

export function selectedPlatforms(raw = process.env.PLATFORMS) {
  const requested = String(raw || ALLOWED_PLATFORMS.join(","))
    .split(",")
    .map((value) => value.trim())
    .filter(Boolean);
  if (requested.length === 0) fail("PLATFORMS must list at least one platform.");
  for (const platform of requested) {
    if (!ALLOWED_PLATFORMS.includes(platform)) fail(`unsupported App Store Connect platform ${platform}.`);
  }
  return requested;
}

export function versionState(version) {
  return version?.attributes?.appVersionState || version?.attributes?.appStoreState || "";
}

export function selectVersionForPlatform(versions, platform) {
  const matching = (versions ?? []).filter((version) => {
    const recorded = version?.attributes?.platform;
    return recorded == null || recorded === "" || recorded === platform;
  });
  for (const state of SELECT_PRIORITY) {
    const found = matching.find((version) => versionState(version) === state);
    if (found) return found;
  }
  return matching[0] ?? null;
}

export function decideApprovedVersionRelease(version) {
  if (!version) {
    return {
      action: "no_approved_version",
      shouldRelease: false,
      shouldCancel: false,
      platform: null,
      versionString: null,
      id: null,
      preState: null,
    };
  }
  const state = versionState(version);
  const base = {
    platform: version.attributes?.platform ?? null,
    versionString: version.attributes?.versionString ?? null,
    id: version.id ?? null,
    preState: state,
    shouldCancel: false,
  };
  if (APPROVED_STATES.includes(state)) {
    return { ...base, action: "released", shouldRelease: true };
  }
  if (LIVE_STATES.includes(state) || APPLE_ROLLOUT_STATES.includes(state)) {
    return { ...base, action: "already_live", shouldRelease: false };
  }
  if (IN_REVIEW_STATES.includes(state)) {
    return { ...base, action: "still_in_review", shouldRelease: false };
  }
  if (REJECTED_STATES.includes(state)) {
    return { ...base, action: "rejected", shouldRelease: false };
  }
  return { ...base, action: "not_releasable", shouldRelease: false };
}

export async function releaseApprovedPlatforms({
  platforms,
  listVersions,
  requestRelease,
}) {
  if (typeof listVersions !== "function") fail("listVersions is required.");
  if (typeof requestRelease !== "function") fail("requestRelease is required.");
  const results = [];
  for (const platform of platforms) {
    const versions = await listVersions(platform);
    const selected = selectVersionForPlatform(versions, platform);
    const decision = decideApprovedVersionRelease(selected);
    const platformDecision = {
      ...decision,
      platform: decision.platform || platform,
    };
    if (platformDecision.shouldCancel) {
      fail(`${platform}: release path must not cancel App Store review.`);
    }
    if (!platformDecision.shouldRelease) {
      results.push({
        ...platformDecision,
        postState: platformDecision.preState,
      });
      continue;
    }
    const postState = await requestRelease(selected);
    results.push({
      ...platformDecision,
      action: "released",
      postState,
    });
  }
  return results;
}

async function waitForReleasedState(token, version) {
  const deadline = Date.now() + RELEASE_WAIT_MS;
  let lastState = versionState(version);
  while (Date.now() <= deadline) {
    const current = await api(token, "GET", `/v1/appStoreVersions/${version.id}`);
    if (current.status !== 200) {
      fail(`GET appStoreVersions/${version.id} failed (${current.status}): ${errorDetail(current.payload)}`);
    }
    lastState = versionState(current.payload?.data ?? {});
    if (LIVE_STATES.includes(lastState) || APPLE_ROLLOUT_STATES.includes(lastState)) return lastState;
    console.log(`${version.attributes?.platform} ${version.attributes?.versionString} release state=${lastState}; waiting.`);
    if (Date.now() + RELEASE_POLL_MS > deadline) break;
    await sleep(RELEASE_POLL_MS);
  }
  fail(`${version.attributes?.platform} ${version.attributes?.versionString} did not reach READY_FOR_DISTRIBUTION or PENDING_APPLE_RELEASE (state=${lastState}).`);
}

async function requestAppStoreVersionRelease(token, version) {
  const { status, payload } = await api(token, "POST", "/v1/appStoreVersionReleaseRequests", {
    data: {
      type: "appStoreVersionReleaseRequests",
      relationships: {
        appStoreVersion: { data: { type: "appStoreVersions", id: version.id } },
      },
    },
  });
  if (status !== 201 && status !== 409) {
    fail(`could not release ${version.attributes?.platform} ${version.attributes?.versionString} (${status}): ${errorDetail(payload)}`);
  }
  return waitForReleasedState(token, version);
}

export async function main() {
  const sourceCommit = required("SOURCE_COMMIT");
  const keyId = required("APP_STORE_CONNECT_KEY_ID");
  const issuer = required("APP_STORE_CONNECT_ISSUER");
  const pem = required("APP_STORE_CONNECT_KEY");
  const platforms = selectedPlatforms();
  console.log(`Releasing Apple-approved native platforms at ${sourceCommit}: ${platforms.join(", ")}.`);

  let token = jwt(keyId, issuer, pem);
  const requested = [];
  const results = await releaseApprovedPlatforms({
    platforms,
    async listVersions(platform) {
      token = jwt(keyId, issuer, pem);
      const versions = await collect(
        token,
        `/v1/apps/${APP_ID}/appStoreVersions?filter[platform]=${platform}&limit=50`,
      );
      console.log(
        `${platform} existing versions: ${versions.map((version) => `${version.attributes?.versionString}:${versionState(version)}`).join(", ") || "none"}`,
      );
      return versions;
    },
    async requestRelease(version) {
      requested.push(`${version.attributes?.platform}:${version.attributes?.versionString}:${version.id}`);
      token = jwt(keyId, issuer, pem);
      console.log(`${version.attributes?.platform}: requesting release of ${version.attributes?.versionString} from ${versionState(version)}`);
      return requestAppStoreVersionRelease(token, version);
    },
  });

  for (const result of results) {
    console.log(JSON.stringify({
      platform: result.platform,
      versionString: result.versionString,
      preState: result.preState,
      action: result.action,
      postState: result.postState,
      id: result.id,
    }));
  }

  const approvedReleased = results.filter((result) => result.action === "released");
  const stillWaiting = results.filter((result) => result.action === "still_in_review" || result.action === "no_approved_version");
  if (requested.length === 0 && approvedReleased.length === 0) {
    console.log("Apple has not approved any selected platform; no release request was sent.");
  } else {
    console.log(`Release requests sent: ${requested.join(", ") || "none"}.`);
  }
  if (stillWaiting.length === results.length) {
    console.log(`All ${results.length} selected platforms remain unreleased pending Apple approval.`);
  }
}

const invokedDirectly = process.argv[1] != null
  && fileURLToPath(import.meta.url) === resolve(process.argv[1]);
if (invokedDirectly && process.env.NODE_TEST_CONTEXT == null) {
  await main();
}
