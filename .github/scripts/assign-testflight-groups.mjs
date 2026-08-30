import { createPrivateKey, createSign } from "node:crypto";

const API = "https://api.appstoreconnect.apple.com";
const POLL_MS = 15_000;
const WAIT_MS = 20 * 60_000;

function fail(message) {
  console.error(`::error::${message}`);
  process.exit(1);
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
    try { payload = JSON.parse(text); } catch { payload = { raw: text.slice(0, 2000) }; }
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
    next = payload.links?.next ?? null;
  }
  return items;
}

async function waitForBuild(token, appId, bundleVersion, marketingVersion) {
  const deadline = Date.now() + WAIT_MS;
  const query = `/v1/builds?filter[app]=${encodeURIComponent(appId)}&filter[version]=${encodeURIComponent(bundleVersion)}&include=preReleaseVersion&sort=-uploadedDate&limit=50`;
  while (Date.now() < deadline) {
    const { status, payload } = await api(token, "GET", query);
    if (status !== 200) fail(`listing builds failed (${status}): ${errorDetail(payload)}`);
    const versions = new Map((payload.included ?? [])
      .filter((item) => item.type === "preReleaseVersions")
      .map((item) => [item.id, item.attributes?.version]));
    const matches = (payload.data ?? []).filter((build) => {
      const versionId = build.relationships?.preReleaseVersion?.data?.id;
      return versions.get(versionId) === marketingVersion;
    });
    if (matches.length === 0) {
      console.log(`Waiting for App Store Connect to list ${marketingVersion} (${bundleVersion}).`);
    } else {
      const build = matches[0];
      const state = build.attributes?.processingState;
      console.log(`Build ${build.id} processingState=${state}`);
      if (state === "VALID") {
        if (build.attributes?.expired) fail(`build ${build.id} is expired.`);
        return build;
      }
      if (state === "FAILED" || state === "INVALID") {
        fail(`build ${build.id} processingState is ${state}.`);
      }
    }
    await new Promise((resolve) => setTimeout(resolve, POLL_MS));
  }
  fail(`timed out waiting for ${marketingVersion} (${bundleVersion}) to become VALID.`);
}

async function ensureEncryptionDeclaration(token, build) {
  if (build.attributes?.usesNonExemptEncryption === false) return;
  const { status, payload } = await api(token, "PATCH", `/v1/builds/${build.id}`, {
    data: {
      type: "builds",
      id: build.id,
      attributes: { usesNonExemptEncryption: false },
    },
  });
  if (status !== 200) {
    console.log(`Could not set usesNonExemptEncryption=false (${status}): ${errorDetail(payload)}`);
  }
}

async function submitExternalReview(token, buildId) {
  const { status, payload } = await api(token, "POST", "/v1/betaAppReviewSubmissions", {
    data: {
      type: "betaAppReviewSubmissions",
      relationships: {
        build: { data: { type: "builds", id: buildId } },
      },
    },
  });
  if (status === 201 || status === 409) return;
  console.log(`Beta App Review submission returned ${status}: ${errorDetail(payload)}`);
}

async function assignGroups(token, buildId, groups) {
  const assigned = [];
  const skipped = [];
  const failed = [];
  for (const group of groups) {
    const name = group.attributes?.name ?? group.id;
    const { status, payload } = await api(token, "POST", `/v1/builds/${buildId}/relationships/betaGroups`, {
      data: [{ type: "betaGroups", id: group.id }],
    });
    if (status === 204 || status === 201 || status === 200) {
      assigned.push(name);
      continue;
    }
    const detail = errorDetail(payload);
    if (status === 409 && /already|duplicate|exists/i.test(detail)) {
      skipped.push(name);
      continue;
    }
    if (!group.attributes?.isInternalGroup && /review|compliance|missing/i.test(detail)) {
      await submitExternalReview(token, buildId);
      const retry = await api(token, "POST", `/v1/builds/${buildId}/relationships/betaGroups`, {
        data: [{ type: "betaGroups", id: group.id }],
      });
      if (retry.status === 204 || retry.status === 201 || retry.status === 200 || retry.status === 409) {
        assigned.push(name);
        continue;
      }
      failed.push(`${name}: ${errorDetail(retry.payload)}`);
      continue;
    }
    failed.push(`${name}: ${detail}`);
  }
  return { assigned, skipped, failed };
}

const appId = required("APP_STORE_CONNECT_APPLE_ID");
const bundleVersion = required("BUILD_NUMBER");
const marketingVersion = required("MARKETING_VERSION");
const token = jwt(
  required("APP_STORE_CONNECT_KEY_ID"),
  required("APP_STORE_CONNECT_ISSUER"),
  required("APP_STORE_CONNECT_KEY"),
);

const build = await waitForBuild(token, appId, bundleVersion, marketingVersion);
await ensureEncryptionDeclaration(token, build);
const groups = await collect(token, `/v1/apps/${appId}/betaGroups?limit=200`);
if (groups.length === 0) fail("App Store Connect returned no TestFlight tester groups.");
console.log(`Assigning ${marketingVersion} (${bundleVersion}) / ${build.id} to ${groups.length} group(s): ${
  groups.map((group) => group.attributes?.name ?? group.id).join(", ")
}`);
const { assigned, skipped, failed } = await assignGroups(token, build.id, groups);
console.log(`Assigned: ${assigned.join(", ") || "(none)"}`);
if (skipped.length > 0) console.log(`Already present: ${skipped.join(", ")}`);
if (failed.length > 0) fail(`Failed to assign groups: ${failed.join(" | ")}`);
if (assigned.length + skipped.length !== groups.length) {
  fail("Not every TestFlight tester group received the build.");
}
console.log(`All ${groups.length} TestFlight tester groups have ${marketingVersion} (${bundleVersion}).`);
