import { createPrivateKey, createSign } from "node:crypto";
import { readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const API = "https://api.appstoreconnect.apple.com";
const APP_ID = "6800642443";
const SUPPORT_URL = "https://quakesignal-api.hopeso.workers.dev/support";
const PRIVACY_URL = "https://quakesignal-api.hopeso.workers.dev/privacy";
const ALLOWED_PLATFORMS = ["IOS", "MAC_OS", "TV_OS", "VISION_OS"];
const BUILD_WAIT_MS = 20 * 60_000;
const BUILD_POLL_MS = 15_000;
const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

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

async function readOptional(relativePath) {
  try {
    return (await readFile(resolve(repositoryRoot, relativePath), "utf8")).replace(/\r?\n$/, "");
  } catch (error) {
    if (error && error.code === "ENOENT") return null;
    throw error;
  }
}

function notesForPlatform(platform) {
  switch (platform) {
    case "MAC_OS":
      return "ios/AppStore/platforms/maccatalyst/review-notes.txt";
    case "TV_OS":
      return "ios/AppStore/platforms/tvos/review-notes.txt";
    case "VISION_OS":
      return "ios/AppStore/platforms/visionos/review-notes.txt";
    default:
      return "ios/AppStore/review-notes.txt";
  }
}

function listingDirectory(platform) {
  switch (platform) {
    case "MAC_OS":
      return "ios/AppStore/platforms/maccatalyst";
    case "TV_OS":
      return "ios/AppStore/platforms/tvos";
    case "VISION_OS":
      return "ios/AppStore/platforms/visionos";
    default:
      return "ios/AppStore";
  }
}

function localeFolder(locale) {
  return locale === "en-US" ? "en-US" : locale;
}

function whatsNewPath(locale) {
  return `ios/AppStore/${localeFolder(locale)}/whats_new_v1.2.txt`;
}

function markdownSection(markdown, heading) {
  const start = markdown.indexOf(heading);
  if (start < 0) return null;
  const after = markdown.slice(start + heading.length).replace(/^\n+/, "");
  const next = after.search(/\n## /);
  return (next >= 0 ? after.slice(0, next) : after).trim() || null;
}

function selectedPlatforms() {
  const raw = process.env.PLATFORMS || ALLOWED_PLATFORMS.join(",");
  const requested = raw.split(",").map((value) => value.trim()).filter(Boolean);
  if (requested.length === 0) fail("PLATFORMS must list at least one platform.");
  for (const platform of requested) {
    if (!ALLOWED_PLATFORMS.includes(platform)) fail(`unsupported App Store Connect platform ${platform}.`);
  }
  return requested;
}

const EDITABLE_VERSION_STATES = [
  "PREPARE_FOR_SUBMISSION",
  "REJECTED",
  "METADATA_REJECTED",
  "DEVELOPER_REJECTED",
  "READY_FOR_REVIEW",
  "INVALID_BINARY",
];
const OPEN_REVIEW_STATES = ["READY_FOR_REVIEW", "WAITING_FOR_REVIEW", "IN_REVIEW"];
const PENDING_RELEASE_STATES = ["PENDING_DEVELOPER_RELEASE", "PENDING_APPLE_RELEASE", "ACCEPTED"];

function summarizeVersions(versions) {
  return versions
    .map((version) => `${version.attributes?.versionString}:${versionState(version)}`)
    .join(", ") || "none";
}

async function cancelOpenReviewSubmissions(token, platform) {
  const submissions = await collect(
    token,
    `/v1/reviewSubmissions?filter[app]=${APP_ID}&filter[platform]=${platform}&filter[state]=${OPEN_REVIEW_STATES.join(",")}`,
  );
  for (const submission of submissions) {
    console.log(`${platform}: canceling review submission ${submission.id} state=${submission.attributes?.state}`);
    const { status, payload } = await api(token, "PATCH", `/v1/reviewSubmissions/${submission.id}`, {
      data: {
        type: "reviewSubmissions",
        id: submission.id,
        attributes: { canceled: true },
      },
    });
    if (status !== 200 && status !== 409) {
      fail(`could not cancel ${platform} review submission ${submission.id} (${status}): ${errorDetail(payload)}`);
    }
  }
}

async function releasePendingVersion(token, version) {
  const platformNote = version.attributes?.platform || "unknown";
  console.log(`${platformNote}: releasing ${version.attributes?.versionString} from ${versionState(version)} so 1.2 can be created.`);
  const { status, payload } = await api(token, "POST", "/v1/appStoreVersionReleaseRequests", {
    data: {
      type: "appStoreVersionReleaseRequests",
      relationships: {
        appStoreVersion: { data: { type: "appStoreVersions", id: version.id } },
      },
    },
  });
  if (status !== 201 && status !== 409) {
    fail(`could not release ${platformNote} ${version.attributes?.versionString} (${status}): ${errorDetail(payload)}`);
  }
  const deadline = Date.now() + BUILD_WAIT_MS;
  while (Date.now() <= deadline) {
    const current = await api(token, "GET", `/v1/appStoreVersions/${version.id}`);
    const state = versionState(current.payload?.data ?? {});
    if (state === "READY_FOR_DISTRIBUTION") return;
    console.log(`${platformNote} ${version.attributes?.versionString} release state=${state}; waiting.`);
    await sleep(BUILD_POLL_MS);
  }
  fail(`${platformNote} ${version.attributes?.versionString} did not reach READY_FOR_DISTRIBUTION after release.`);
}

async function retargetVersion(token, version, marketingVersion) {
  if (version.attributes?.versionString === marketingVersion) return version;
  const { status, payload } = await api(token, "PATCH", `/v1/appStoreVersions/${version.id}`, {
    data: {
      type: "appStoreVersions",
      id: version.id,
      attributes: { versionString: marketingVersion, releaseType: "MANUAL" },
    },
  });
  if (status !== 200) {
    fail(`could not retarget ${version.attributes?.platform} ${version.attributes?.versionString} to ${marketingVersion} (${status}): ${errorDetail(payload)}`);
  }
  return payload.data;
}

async function listVersions(token, platform) {
  return collect(
    token,
    `/v1/apps/${APP_ID}/appStoreVersions?filter[platform]=${platform}&limit=50`,
  );
}

async function findOrCreateVersion(token, platform, marketingVersion) {
  let versions = await listVersions(token, platform);
  console.log(`${platform} existing versions: ${summarizeVersions(versions)}`);
  const exact = versions.find((version) => version.attributes?.versionString === marketingVersion);
  if (exact) return exact;

  const pending = versions.find((version) => PENDING_RELEASE_STATES.includes(versionState(version)));
  if (pending) {
    await releasePendingVersion(token, pending);
    versions = await listVersions(token, platform);
  }

  const inReview = versions.find((version) =>
    version.attributes?.versionString !== marketingVersion && OPEN_REVIEW_STATES.includes(versionState(version)),
  );
  if (inReview) {
    await cancelOpenReviewSubmissions(token, platform);
    versions = await listVersions(token, platform);
  }

  const exactAfter = versions.find((version) => version.attributes?.versionString === marketingVersion);
  if (exactAfter) return exactAfter;

  const editable = versions.find((version) => EDITABLE_VERSION_STATES.includes(versionState(version)));
  if (editable) return retargetVersion(token, editable, marketingVersion);

  const { status, payload } = await api(token, "POST", "/v1/appStoreVersions", {
    data: {
      type: "appStoreVersions",
      attributes: {
        platform,
        versionString: marketingVersion,
        releaseType: "MANUAL",
      },
      relationships: {
        app: { data: { type: "apps", id: APP_ID } },
      },
    },
  });
  if (status !== 201) {
    fail(`could not create ${platform} ${marketingVersion} (${status}): ${errorDetail(payload)} [${summarizeVersions(versions)}]`);
  }
  return payload.data;
}

async function findBuild(token, platform, marketingVersion, bundleVersion) {
  const query = `/v1/builds?filter[app]=${APP_ID}&filter[version]=${encodeURIComponent(bundleVersion)}&include=preReleaseVersion&sort=-uploadedDate&limit=50`;
  const deadline = Date.now() + BUILD_WAIT_MS;
  let lastStates = "none";
  while (Date.now() <= deadline) {
    const { status, payload } = await api(token, "GET", query);
    if (status !== 200) fail(`listing builds failed (${status}): ${errorDetail(payload)}`);
    const versions = new Map((payload.included ?? [])
      .filter((item) => item.type === "preReleaseVersions")
      .map((item) => [item.id, item.attributes]));
    const matches = (payload.data ?? []).filter((build) => {
      const pre = versions.get(build.relationships?.preReleaseVersion?.data?.id);
      return pre?.version === marketingVersion && pre?.platform === platform;
    });
    if (matches.length === 0) {
      lastStates = "missing";
    } else {
      lastStates = matches.map((item) => `${item.id}:${item.attributes?.processingState}`).join(", ");
      const build = matches.find((item) => item.attributes?.processingState === "VALID" && !item.attributes?.expired);
      if (build) return build;
    }
    if (Date.now() + BUILD_POLL_MS > deadline) break;
    console.log(`${platform} ${marketingVersion} (${bundleVersion}) not VALID yet (${lastStates}); waiting.`);
    await sleep(BUILD_POLL_MS);
  }
  if (lastStates === "missing") {
    fail(`no ${platform} build ${marketingVersion} (${bundleVersion}) is in App Store Connect yet.`);
  }
  fail(`${platform} ${marketingVersion} (${bundleVersion}) is not VALID (${lastStates}).`);
}

async function attachBuild(token, version, build) {
  const { status, payload } = await api(token, "PATCH", `/v1/appStoreVersions/${version.id}`, {
    data: {
      type: "appStoreVersions",
      id: version.id,
      relationships: {
        build: { data: { type: "builds", id: build.id } },
      },
    },
  });
  if (status !== 200 && status !== 409) {
    fail(`could not attach ${build.id} to ${version.id} (${status}): ${errorDetail(payload)}`);
  }
  if (build.attributes?.usesNonExemptEncryption !== false) {
    const encryption = await api(token, "PATCH", `/v1/builds/${build.id}`, {
      data: {
        type: "builds",
        id: build.id,
        attributes: { usesNonExemptEncryption: false },
      },
    });
    if (encryption.status !== 200) {
      console.log(`usesNonExemptEncryption update returned ${encryption.status}: ${errorDetail(encryption.payload)}`);
    }
  }
}

async function upsertReviewDetail(token, version, notes) {
  const { status, payload } = await api(token, "GET", `/v1/appStoreVersions/${version.id}/appStoreReviewDetail`);
  const attributes = {
    notes,
    demoAccountRequired: false,
    demoAccountName: null,
    demoAccountPassword: null,
  };
  if (status === 200 && payload.data?.id) {
    const existing = payload.data.attributes ?? {};
    const merged = {
      ...attributes,
      contactFirstName: existing.contactFirstName || undefined,
      contactLastName: existing.contactLastName || undefined,
      contactPhone: existing.contactPhone || undefined,
      contactEmail: existing.contactEmail || undefined,
    };
    const patch = await api(token, "PATCH", `/v1/appStoreReviewDetails/${payload.data.id}`, {
      data: { type: "appStoreReviewDetails", id: payload.data.id, attributes: merged },
    });
    if (patch.status !== 200) {
      fail(`could not update review notes for ${version.id} (${patch.status}): ${errorDetail(patch.payload)}`);
    }
    return;
  }
  const created = await api(token, "POST", "/v1/appStoreReviewDetails", {
    data: {
      type: "appStoreReviewDetails",
      attributes,
      relationships: {
        appStoreVersion: { data: { type: "appStoreVersions", id: version.id } },
      },
    },
  });
  if (created.status !== 201) {
    fail(`could not create review details for ${version.id} (${created.status}): ${errorDetail(created.payload)}`);
  }
}

async function updateLocalizations(token, version, platform) {
  const root = listingDirectory(platform);
  const localizations = await collect(token, `/v1/appStoreVersions/${version.id}/appStoreVersionLocalizations`);
  if (localizations.length === 0) {
    fail(`${platform} version ${version.id} has no App Store localizations.`);
  }
  for (const localization of localizations) {
    const locale = localization.attributes?.locale;
    const folder = localeFolder(locale);
    const whatsNew = await readOptional(whatsNewPath(locale));
    const attributes = {
      supportUrl: SUPPORT_URL,
    };
    if (whatsNew) attributes.whatsNew = whatsNew;
    const description = await readOptional(`${root}/${folder}/description.txt`);
    const promotionalText = await readOptional(`${root}/${folder}/promotional_text.txt`);
    const keywords = await readOptional(`${root}/${folder}/keywords.txt`);
    if (description) attributes.description = description;
    if (promotionalText) attributes.promotionalText = promotionalText;
    if (keywords) attributes.keywords = keywords;
    const { status, payload } = await api(token, "PATCH", `/v1/appStoreVersionLocalizations/${localization.id}`, {
      data: {
        type: "appStoreVersionLocalizations",
        id: localization.id,
        attributes,
      },
    });
    if (status !== 200) {
      fail(`could not update ${platform} ${locale} localization (${status}): ${errorDetail(payload)}`);
    }
  }
}

async function assertScreenshotSets(token, version, platform) {
  const localizations = await collect(token, `/v1/appStoreVersions/${version.id}/appStoreVersionLocalizations`);
  const empty = [];
  for (const localization of localizations) {
    const locale = localization.attributes?.locale;
    const sets = await collect(token, `/v1/appStoreVersionLocalizations/${localization.id}/appScreenshotSets`);
    const withImages = [];
    for (const set of sets) {
      const shots = await collect(token, `/v1/appScreenshotSets/${set.id}/appScreenshots`);
      if (shots.length > 0) withImages.push(`${set.attributes?.screenshotDisplayType || set.id}:${shots.length}`);
    }
    if (withImages.length === 0) empty.push(`${locale}`);
    else console.log(`${platform} ${locale} screenshot sets: ${withImages.join(", ")}`);
  }
  if (empty.length === localizations.length) {
    fail(`${platform} has no App Store screenshots in any localization. Upload approved screenshots before review.`);
  }
  if (empty.length > 0) {
    console.log(`${platform} locales without their own screenshots (primary-language fallback may apply): ${empty.join(", ")}`);
  }
}

async function updateAppleTvPrivacy(token) {
  const markdown = await readOptional("ios/AppStore/apple-tv-privacy-policy.md");
  if (!markdown) return;
  const texts = {
    "en-US": markdownSection(markdown, "## English (U.S.)"),
    ja: markdownSection(markdown, "## Japanese"),
    "zh-Hans": markdownSection(markdown, "## Chinese (Simplified)"),
  };
  const infos = await collect(token, `/v1/apps/${APP_ID}/appInfos`);
  const current = infos.find((info) =>
    ["PREPARE_FOR_SUBMISSION", "READY_FOR_DISTRIBUTION", "WAITING_FOR_REVIEW", "IN_REVIEW"]
      .includes(info.attributes?.appStoreState || info.attributes?.state),
  ) ?? infos[0];
  if (!current) return;
  const localizations = await collect(token, `/v1/appInfos/${current.id}/appInfoLocalizations`);
  for (const localization of localizations) {
    const locale = localization.attributes?.locale;
    const privacyPolicyText = texts[locale];
    const attributes = { privacyPolicyUrl: PRIVACY_URL };
    if (privacyPolicyText) attributes.privacyPolicyText = privacyPolicyText;
    const { status, payload } = await api(token, "PATCH", `/v1/appInfoLocalizations/${localization.id}`, {
      data: {
        type: "appInfoLocalizations",
        id: localization.id,
        attributes,
      },
    });
    if (status !== 200) {
      console.log(`Apple TV privacy-policy update for ${locale} returned ${status}: ${errorDetail(payload)}`);
    }
  }
}

function versionState(version) {
  return version.attributes?.appVersionState || version.attributes?.appStoreState || "";
}

async function submitPlatform(token, platform, version) {
  const state = versionState(version);
  if (["WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_APPLE_RELEASE", "PENDING_DEVELOPER_RELEASE", "READY_FOR_DISTRIBUTION"].includes(state)) {
    return { platform, ok: true, state, id: version.id, alreadyOpen: true };
  }
  const existing = await collect(
    token,
    `/v1/reviewSubmissions?filter[app]=${APP_ID}&filter[platform]=${platform}&filter[state]=READY_FOR_REVIEW,WAITING_FOR_REVIEW,IN_REVIEW`,
  );
  let submission = existing[0];
  if (!submission) {
    const created = await api(token, "POST", "/v1/reviewSubmissions", {
      data: {
        type: "reviewSubmissions",
        attributes: { platform },
        relationships: {
          app: { data: { type: "apps", id: APP_ID } },
        },
      },
    });
    if (created.status !== 201) {
      return { platform, ok: false, detail: errorDetail(created.payload), status: created.status };
    }
    submission = created.payload.data;
  }
  if (submission.attributes?.state === "READY_FOR_REVIEW") {
    const item = await api(token, "POST", "/v1/reviewSubmissionItems", {
      data: {
        type: "reviewSubmissionItems",
        relationships: {
          reviewSubmission: { data: { type: "reviewSubmissions", id: submission.id } },
          appStoreVersion: { data: { type: "appStoreVersions", id: version.id } },
        },
      },
    });
    if (item.status !== 201 && item.status !== 409) {
      return { platform, ok: false, detail: errorDetail(item.payload), status: item.status };
    }
    const submitted = await api(token, "PATCH", `/v1/reviewSubmissions/${submission.id}`, {
      data: {
        type: "reviewSubmissions",
        id: submission.id,
        attributes: { submitted: true },
      },
    });
    if (submitted.status !== 200) {
      return { platform, ok: false, detail: errorDetail(submitted.payload), status: submitted.status };
    }
    return {
      platform,
      ok: true,
      state: submitted.payload.data?.attributes?.state,
      id: submission.id,
    };
  }
  return {
    platform,
    ok: true,
    state: submission.attributes?.state,
    id: submission.id,
    alreadyOpen: true,
  };
}

const marketingVersion = required("MARKETING_VERSION");
const bundleVersion = required("BUILD_NUMBER");
const sourceCommit = required("SOURCE_COMMIT");
const keyId = required("APP_STORE_CONNECT_KEY_ID");
const issuer = required("APP_STORE_CONNECT_ISSUER");
const pem = required("APP_STORE_CONNECT_KEY");
const platforms = selectedPlatforms();

console.log(`Preparing App Store Review for ${marketingVersion} (${bundleVersion}) at ${sourceCommit}: ${platforms.join(", ")}.`);
let token = jwt(keyId, issuer, pem);
await updateAppleTvPrivacy(token);

const results = [];
for (const platform of platforms) {
  token = jwt(keyId, issuer, pem);
  try {
    const notes = await readOptional(notesForPlatform(platform));
    if (!notes) throw new Error(`missing review notes for ${platform}`);
    const version = await findOrCreateVersion(token, platform, marketingVersion);
    const alreadySubmitted = ["WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_APPLE_RELEASE", "PENDING_DEVELOPER_RELEASE", "READY_FOR_DISTRIBUTION"].includes(versionState(version));
    if (alreadySubmitted) {
      console.log(`${platform}: version ${version.id} already ${versionState(version)}`);
      results.push({ platform, ok: true, state: versionState(version), id: version.id, alreadyOpen: true });
      continue;
    }
    const build = await findBuild(token, platform, marketingVersion, bundleVersion);
    console.log(`${platform}: version ${version.id} state=${versionState(version)} build=${build.id}`);
    await attachBuild(token, version, build);
    await upsertReviewDetail(token, version, notes);
    await updateLocalizations(token, version, platform);
    await assertScreenshotSets(token, version, platform);
    results.push(await submitPlatform(token, platform, version));
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    console.error(`::error::${platform} failed: ${detail}`);
    results.push({ platform, ok: false, detail });
  }
}

const failed = results.filter((result) => !result.ok);
for (const result of results) {
  console.log(JSON.stringify(result));
}
if (failed.length > 0) {
  fail(`App Store Review submission failed: ${failed.map((item) => `${item.platform}: ${item.detail}`).join(" | ")}`);
}
console.log(`Submitted ${marketingVersion} (${bundleVersion}) for ${results.length} Apple platforms.`);
