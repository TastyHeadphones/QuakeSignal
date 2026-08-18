import assert from "node:assert/strict";
import test from "node:test";

import {
  MAX_ACTIVE_WARNING_AGE_MS,
  MAX_FUTURE_CLOCK_SKEW_MS,
  isFreshActiveWarningForDisplay,
  isRecentEventForDisplay,
} from "./alert-display-policy.ts";

const now = Date.parse("2026-08-18T12:00:00Z");
const warning = {
  kind: "eew",
  isWarn: true,
  isFinal: false,
  isCancel: false,
  isTraining: false,
  reportTimeUtc: "2026-08-18T11:59:00Z",
  originTimeUtc: null,
};

test("only a fresh genuine warning can drive the active status banner", () => {
  assert.equal(isFreshActiveWarningForDisplay(warning, now), true);

  for (const patch of [
    { kind: "report" },
    { isWarn: false },
    { isFinal: true },
    { isCancel: true },
    { isTraining: true },
  ]) {
    assert.equal(isFreshActiveWarningForDisplay({ ...warning, ...patch }, now), false);
  }
});

test("stale, malformed, and implausibly future warnings are not shown as active", () => {
  assert.equal(
    isFreshActiveWarningForDisplay(
      {
        ...warning,
        reportTimeUtc: new Date(now - MAX_ACTIVE_WARNING_AGE_MS - 1).toISOString(),
      },
      now,
    ),
    false,
  );
  assert.equal(
    isFreshActiveWarningForDisplay({ ...warning, reportTimeUtc: "not-a-date" }, now),
    false,
  );
  assert.equal(
    isFreshActiveWarningForDisplay(
      { ...warning, reportTimeUtc: new Date(now + MAX_FUTURE_CLOCK_SKEW_MS).toISOString() },
      now,
    ),
    true,
  );
  assert.equal(
    isFreshActiveWarningForDisplay(
      {
        ...warning,
        reportTimeUtc: new Date(now + MAX_FUTURE_CLOCK_SKEW_MS + 1).toISOString(),
      },
      now,
    ),
    false,
  );
});

test("the recent-event banner ignores drills, cancellations, and bad clocks", () => {
  assert.equal(isRecentEventForDisplay({ ...warning, kind: "report", isWarn: false }, now), true);
  assert.equal(isRecentEventForDisplay({ ...warning, isTraining: true }, now), false);
  assert.equal(isRecentEventForDisplay({ ...warning, isCancel: true }, now), false);
  assert.equal(
    isRecentEventForDisplay({ ...warning, reportTimeUtc: "2026-08-18T10:00:00Z" }, now),
    false,
  );
  assert.equal(
    isRecentEventForDisplay({ ...warning, reportTimeUtc: "2026-08-18T12:06:00Z" }, now),
    false,
  );
});
