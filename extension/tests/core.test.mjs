import test from "node:test";
import assert from "node:assert/strict";
import { DEFAULT_SETTINGS, determineReason, mergeEvents, normalizeMessage, passesFilters } from "../core.js";

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
  const previous = { id: "jma_eew:1", kind: "eew", serial: 1, isFinal: false, isCancel: false };
  const update = { ...previous, serial: 2 };
  const final = { ...update, isFinal: true };
  assert.equal(determineReason(update, previous), "updated");
  assert.equal(determineReason(final, update), "final");
  assert.equal(determineReason(final, final), null);
  assert.deepEqual(mergeEvents([previous], [update]), [update]);
});

test("applies source, notification, training, and magnitude filters", () => {
  const event = { sourceId: "jma_eew", magnitude: 5, isTraining: false };
  assert.equal(passesFilters(event, DEFAULT_SETTINGS), true);
  assert.equal(passesFilters({ ...event, magnitude: 4 }, DEFAULT_SETTINGS), false);
  assert.equal(passesFilters({ ...event, isTraining: true }, DEFAULT_SETTINGS), false);
  assert.equal(passesFilters(event, { ...DEFAULT_SETTINGS, notificationsEnabled: false }), false);
});
