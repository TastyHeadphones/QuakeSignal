import assert from "node:assert/strict";
import test from "node:test";

import {
  decideApprovedVersionRelease,
  releaseApprovedPlatforms,
  selectVersionForPlatform,
  versionState,
} from "./release-app-store-if-approved.mjs";

function version({ platform, versionString, state, id, stateKey = "appVersionState" }) {
  return {
    id,
    type: "appStoreVersions",
    attributes: {
      platform,
      versionString,
      [stateKey]: state,
    },
  };
}

test("PENDING_DEVELOPER_RELEASE and ACCEPTED decide to request a release", () => {
  for (const state of ["PENDING_DEVELOPER_RELEASE", "ACCEPTED"]) {
    const decision = decideApprovedVersionRelease(version({
      platform: "IOS",
      versionString: "1.2",
      state,
      id: `approved-${state}`,
    }));
    assert.equal(decision.shouldRelease, true);
    assert.equal(decision.shouldCancel, false);
    assert.equal(decision.action, "released");
    assert.equal(decision.preState, state);
  }
});

test("in-review states do not release or cancel", () => {
  for (const state of ["WAITING_FOR_REVIEW", "IN_REVIEW", "READY_FOR_REVIEW"]) {
    const decision = decideApprovedVersionRelease(version({
      platform: "TV_OS",
      versionString: "1.2",
      state,
      id: `review-${state}`,
      stateKey: "appStoreState",
    }));
    assert.equal(decision.shouldRelease, false);
    assert.equal(decision.shouldCancel, false);
    assert.equal(decision.action, "still_in_review");
    assert.equal(decision.preState, state);
  }
});

test("rejected states do not release or cancel", () => {
  for (const state of ["REJECTED", "METADATA_REJECTED", "DEVELOPER_REJECTED"]) {
    const decision = decideApprovedVersionRelease(version({
      platform: "MAC_OS",
      versionString: "1.2",
      state,
      id: `rejected-${state}`,
    }));
    assert.equal(decision.shouldRelease, false);
    assert.equal(decision.shouldCancel, false);
    assert.equal(decision.action, "rejected");
  }
});

test("READY_FOR_DISTRIBUTION is a no-op already_live success", () => {
  const decision = decideApprovedVersionRelease(version({
    platform: "VISION_OS",
    versionString: "1.1",
    state: "READY_FOR_DISTRIBUTION",
    id: "live",
  }));
  assert.equal(decision.shouldRelease, false);
  assert.equal(decision.shouldCancel, false);
  assert.equal(decision.action, "already_live");
});

test("PREPARE_FOR_SUBMISSION is not releasable and does not cancel", () => {
  const decision = decideApprovedVersionRelease(version({
    platform: "IOS",
    versionString: "1.2",
    state: "PREPARE_FOR_SUBMISSION",
    id: "draft",
  }));
  assert.equal(decision.shouldRelease, false);
  assert.equal(decision.shouldCancel, false);
  assert.equal(decision.action, "not_releasable");
});

test("PENDING_APPLE_RELEASE is already requested and is not released again", () => {
  const decision = decideApprovedVersionRelease(version({
    platform: "IOS",
    versionString: "1.2",
    state: "PENDING_APPLE_RELEASE",
    id: "rolling-out",
  }));
  assert.equal(decision.shouldRelease, false);
  assert.equal(decision.action, "already_live");
});

test("selectVersionForPlatform prefers 1.2 in review over live 1.1", () => {
  const selected = selectVersionForPlatform([
    version({ platform: "IOS", versionString: "1.1", state: "READY_FOR_DISTRIBUTION", id: "v11" }),
    version({ platform: "IOS", versionString: "1.2", state: "WAITING_FOR_REVIEW", id: "v12" }),
  ], "IOS");
  assert.equal(selected.id, "v12");
  assert.equal(versionState(selected), "WAITING_FOR_REVIEW");
});

test("shipped release path requests only Apple-approved platforms", async () => {
  const released = [];
  const results = await releaseApprovedPlatforms({
    platforms: ["IOS", "MAC_OS", "TV_OS", "VISION_OS"],
    async listVersions(platform) {
      if (platform === "IOS") {
        return [
          version({ platform: "IOS", versionString: "1.1", state: "READY_FOR_DISTRIBUTION", id: "ios-11" }),
          version({ platform: "IOS", versionString: "1.2", state: "PENDING_DEVELOPER_RELEASE", id: "ios-12" }),
        ];
      }
      if (platform === "MAC_OS") {
        return [
          version({ platform: "MAC_OS", versionString: "1.2", state: "WAITING_FOR_REVIEW", id: "mac-12" }),
        ];
      }
      if (platform === "TV_OS") {
        return [
          version({ platform: "TV_OS", versionString: "1.2", state: "REJECTED", id: "tv-12" }),
        ];
      }
      return [
        version({ platform: "VISION_OS", versionString: "1.2", state: "READY_FOR_DISTRIBUTION", id: "vision-12" }),
      ];
    },
    async requestRelease(selected) {
      released.push(`${selected.attributes.platform}:${selected.id}`);
      assert.equal(versionState(selected), "PENDING_DEVELOPER_RELEASE");
      return "READY_FOR_DISTRIBUTION";
    },
  });

  assert.deepEqual(released, ["IOS:ios-12"]);
  assert.deepEqual(results.map((result) => [result.platform, result.action, result.postState]), [
    ["IOS", "released", "READY_FOR_DISTRIBUTION"],
    ["MAC_OS", "still_in_review", "WAITING_FOR_REVIEW"],
    ["TV_OS", "rejected", "REJECTED"],
    ["VISION_OS", "already_live", "READY_FOR_DISTRIBUTION"],
  ]);
  assert.equal(results.every((result) => result.shouldCancel === false), true);
});

test("in-review and rejected versions never invoke requestRelease", async () => {
  const results = await releaseApprovedPlatforms({
    platforms: ["IOS", "MAC_OS"],
    async listVersions(platform) {
      return [
        version({
          platform,
          versionString: "1.2",
          state: platform === "IOS" ? "IN_REVIEW" : "METADATA_REJECTED",
          id: platform,
        }),
      ];
    },
    async requestRelease() {
      throw new Error("requestRelease must not run for in-review or rejected versions");
    },
  });
  assert.deepEqual(results.map((result) => result.action), ["still_in_review", "rejected"]);
});
