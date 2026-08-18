import test from "node:test";
import assert from "node:assert/strict";
import {
  ACTIVE_WARNING_MAX_AGE_MS,
  DEFAULT_SETTINGS,
  determineReason,
  enqueueRecovering,
  isActiveWarning,
  isUrgentNotification,
  mergeEvents,
  normalizeMessage,
  passesFilters,
} from "../core.js";

test("normalizes the upstream JMA magnitude typo and JST timestamps", () => {
  const [event] = normalizeMessage("jma_eew", {
    EventID: "20260718094827", Serial: 6, AnnouncedTime: "2026/07/18 09:48:59",
    OriginTime: "2026/07/18 09:48:24", Hypocenter: "Amami", Latitude: 28.3,
    Longitude: 129.7, Magunitude: 3.7, Depth: 10, MaxIntensity: "3", isWarn: true, isFinal: true,
  });
  assert.equal(event.magnitude, 3.7);
  assert.equal(event.reportTimeUtc, "2026-07-18T00:48:59.000Z");
  assert.equal(event.serial, 6);
});

test("extracts and orders ranked earthquake list entries", () => {
  const events = normalizeMessage("cenc_eqlist", {
    No2: { EventID: "second", type: "automatic", time: "2026-07-18 12:00:00", location: "B", magnitude: "4.0", depth: "10" },
    No1: { EventID: "first", type: "reviewed", time: "2026-07-18 13:00:00", location: "A", magnitude: "5.2", depth: "20" },
    md5: "ignored",
  });
  assert.deepEqual(events.map((event) => event.eventId), ["first", "second"]);
  assert.equal(events[0].isFinal, true);
});

test("deduplicates revisions and identifies meaningful alert reasons", () => {
  const now = Date.parse("2026-08-19T01:00:00.000Z");
  const previous = {
    id: "jma_eew:1",
    kind: "eew",
    serial: 1,
    isWarn: true,
    isFinal: false,
    isCancel: false,
    isTraining: false,
    reportTimeUtc: new Date(now - 30_000).toISOString(),
  };
  const update = { ...previous, serial: 2 };
  const final = { ...update, isFinal: true };
  assert.equal(determineReason(update, previous, now), "updated");
  assert.equal(determineReason(final, update, now), "final");
  assert.equal(determineReason(final, final, now), null);
  assert.deepEqual(mergeEvents([previous], [update]), [update]);
});

test("informational EEW frames stay stored without urgent notification or audio", () => {
  const now = Date.parse("2026-08-19T01:00:00.000Z");
  const informational = {
    id: "jma_eew:informational",
    kind: "eew",
    serial: 1,
    isWarn: false,
    isFinal: false,
    isCancel: false,
    isTraining: false,
    reportTimeUtc: new Date(now - 30_000).toISOString(),
  };
  assert.equal(determineReason(informational, null, now), null);
  assert.equal(isUrgentNotification(informational, "new", now), false);

  const promotedWarning = { ...informational, isWarn: true };
  assert.equal(determineReason(promotedWarning, informational, now), "new");
  assert.equal(isUrgentNotification(promotedWarning, "new", now), true);

  const [sameSerialReplay] = mergeEvents(
    [promotedWarning],
    [{ ...informational }],
  );
  assert.equal(sameSerialReplay.isWarn, true);

  const final = { ...promotedWarning, isFinal: true };
  assert.equal(determineReason(final, promotedWarning, now), "final");
  assert.equal(isUrgentNotification(final, "final", now), false);
  assert.equal(
    determineReason({ ...promotedWarning, serial: 2 }, final, now),
    null,
  );
  const cancelled = { ...final, isCancel: true };
  assert.equal(determineReason(cancelled, final, now), "cancelled");
  assert.equal(isUrgentNotification(cancelled, "cancelled", now), false);
});

test("does not regress event serials or terminal status", () => {
  const base = {
    id: "jma_eew:1",
    kind: "eew",
    serial: 4,
    magnitude: 5,
    isWarn: true,
    isFinal: true,
    isCancel: false,
    isTraining: false,
    reportTimeUtc: "2026-08-19T00:00:00.000Z",
  };

  assert.deepEqual(
    mergeEvents([base], [{ ...base, serial: 3, magnitude: 9, isFinal: false }]),
    [base],
  );

  const [newer] = mergeEvents(
    [base],
    [{ ...base, serial: 5, magnitude: 5.5, isFinal: false }],
  );
  assert.equal(newer.serial, 5);
  assert.equal(newer.magnitude, 5.5);
  assert.equal(newer.isFinal, true);
  assert.equal(determineReason(newer, base), null);

  const [cancelled] = mergeEvents([newer], [{ ...newer, isCancel: true }]);
  assert.equal(cancelled.isCancel, true);
  assert.equal(determineReason(cancelled, newer), "cancelled");

  const [replayed] = mergeEvents([cancelled], [{ ...cancelled, isCancel: false }]);
  assert.equal(replayed.isCancel, true);
  assert.equal(determineReason(replayed, cancelled), null);
});

test("active warning excludes final, cancelled, training, missing-time, and stale events", () => {
  const now = Date.parse("2026-08-19T01:00:00.000Z");
  const active = {
    kind: "eew",
    isWarn: true,
    isFinal: false,
    isCancel: false,
    isTraining: false,
    reportTimeUtc: new Date(now - ACTIVE_WARNING_MAX_AGE_MS).toISOString(),
  };
  assert.equal(isActiveWarning(active, now), true);
  assert.equal(isActiveWarning({ ...active, isFinal: true }, now), false);
  assert.equal(isActiveWarning({ ...active, isCancel: true }, now), false);
  assert.equal(isActiveWarning({ ...active, isTraining: true }, now), false);
  assert.equal(isActiveWarning({ ...active, reportTimeUtc: null }, now), false);
  assert.equal(
    isActiveWarning(
      { ...active, reportTimeUtc: new Date(now - ACTIVE_WARNING_MAX_AGE_MS - 1).toISOString() },
      now,
    ),
    false,
  );
});

test("recovering queue processes the item after a rejection", async () => {
  const processed = [];
  const errors = [];
  let tail = Promise.resolve();
  tail = enqueueRecovering(
    tail,
    async () => {
      processed.push("failed");
      throw new Error("storage unavailable");
    },
    (error) => errors.push(error.message),
  );
  await assert.rejects(tail, /storage unavailable/);

  tail = enqueueRecovering(tail, async () => {
    processed.push("continued");
  });
  await tail;

  assert.deepEqual(processed, ["failed", "continued"]);
  assert.deepEqual(errors, ["storage unavailable"]);
});

test("applies source, notification, training, and magnitude filters", () => {
  const event = { sourceId: "jma_eew", magnitude: 5, isTraining: false };
  assert.equal(passesFilters(event, DEFAULT_SETTINGS), true);
  assert.equal(passesFilters({ ...event, magnitude: 4 }, DEFAULT_SETTINGS), false);
  assert.equal(passesFilters({ ...event, isTraining: true }, DEFAULT_SETTINGS), false);
  assert.equal(passesFilters(event, { ...DEFAULT_SETTINGS, notificationsEnabled: false }), false);
});
