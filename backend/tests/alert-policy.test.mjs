import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";

test("legacy SQLite upgrades old registrations and persists exact alert sounds", async (t) => {
  const directory = await mkdtemp(join(tmpdir(), "quakesignal-legacy-alert-sound-"));
  const databasePath = join(directory, "legacy.sqlite");
  t.after(() => rm(directory, { recursive: true, force: true }));

  const legacy = new DatabaseSync(databasePath);
  legacy.exec(`
    CREATE TABLE devices (
      token TEXT PRIMARY KEY,
      environment TEXT NOT NULL DEFAULT 'production',
      locale TEXT,
      sources TEXT NOT NULL,
      min_magnitude REAL NOT NULL DEFAULT 0,
      critical_alerts_enabled INTEGER NOT NULL DEFAULT 0,
      city_name TEXT,
      latitude REAL,
      longitude REAL,
      radius_km REAL,
      include_test_alerts INTEGER NOT NULL DEFAULT 0,
      utc_offset_minutes REAL,
      notify_at_night INTEGER NOT NULL DEFAULT 1,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
    INSERT INTO devices (
      token, sources, created_at, updated_at
    ) VALUES (
      'legacy-device-token', '["jma_eew"]',
      '2026-08-18T00:00:00.000Z', '2026-08-18T00:00:00.000Z'
    );
  `);
  legacy.close();

  process.env.DB_PATH = databasePath;
  const { db, getDevice, getEvent, listDevicesForSource, upsertDevice, upsertEvent } = await import(
    `../src/db.ts?alert-sound-test=${Date.now()}`
  );
  t.after(() => db.close());

  assert.equal(getDevice("legacy-device-token")?.alertSound, "system");
  const columns = db.prepare("PRAGMA table_info(devices)").all();
  assert.ok(columns.some(({ name }) => name === "alert_sound"));

  const stored = upsertDevice({
    token: "custom-sound-device-token",
    environment: "production",
    locale: "ja",
    sources: ["jma_eew"],
    minMagnitude: 0,
    criticalAlertsEnabled: false,
    alertSound: "urgent-tone",
    cityName: null,
    latitude: null,
    longitude: null,
    radiusKm: null,
    includeTestAlerts: false,
    utcOffsetMinutes: 540,
    notifyAtNight: true,
  });
  assert.equal(stored.alertSound, "urgent-tone");
  assert.deepEqual(
    {
      ...db.prepare("SELECT alert_sound FROM devices WHERE token = ?")
        .get("custom-sound-device-token"),
    },
    { alert_sound: "urgent-tone" },
  );
  assert.throws(
    () => db.prepare(
      `UPDATE devices SET alert_sound = 'official-j-alert' WHERE token = ?`,
    ).run("custom-sound-device-token"),
    /constraint/i,
  );

  const distanceFilterEvent = {
    magnitude: 5.5,
    latitude: 35,
    longitude: 135,
    isTraining: false,
    isRoutineReport: false,
  };
  assert.deepEqual(
    listDevicesForSource("jma_eew", distanceFilterEvent),
    [],
    "legacy registrations without a radius filter must not receive automatic alerts",
  );
  upsertDevice({
    token: "nearby-device-token",
    environment: "production",
    locale: "ja",
    sources: ["jma_eew"],
    minMagnitude: 0,
    criticalAlertsEnabled: false,
    alertSound: "system",
    cityName: "Test City",
    latitude: 35,
    longitude: 135,
    radiusKm: 100,
    includeTestAlerts: false,
    utcOffsetMinutes: 540,
    notifyAtNight: true,
  });
  assert.deepEqual(
    listDevicesForSource("jma_eew", distanceFilterEvent).map(({ token }) => token),
    ["nearby-device-token"],
  );

  const activeWarning = {
    id: "jma_eew:legacy-terminal-regression",
    sourceId: "jma_eew",
    eventId: "legacy-terminal-regression",
    serial: 1,
    kind: "eew",
    originTimeUtc: "2026-08-19T00:00:00.000Z",
    reportTimeUtc: "2026-08-19T00:00:05.000Z",
    hypocenter: "Test Region",
    latitude: 35,
    longitude: 135,
    magnitude: 5.5,
    depth: 10,
    maxIntensity: "5-",
    isWarn: true,
    isFinal: false,
    isCancel: false,
    isTraining: false,
    tsunami: null,
    raw: null,
  };
  assert.equal(upsertEvent(activeWarning).acceptedEvent?.isFinal, false);

  const finalWarning = { ...activeWarning, isFinal: true };
  assert.equal(upsertEvent(finalWarning).acceptedEvent?.isFinal, true);
  assert.equal(
    upsertEvent({ ...activeWarning, hypocenter: "same-serial replay" }).acceptedEvent,
    null,
  );
  assert.equal(getEvent(activeWarning.id)?.hypocenter, "Test Region");
  assert.equal(getEvent(activeWarning.id)?.isFinal, true);
  assert.equal(
    upsertEvent({ ...activeWarning, serial: 0, magnitude: 9.9 }).acceptedEvent,
    null,
  );
  assert.equal(getEvent(activeWarning.id)?.magnitude, 5.5);

  const higherAfterFinal = upsertEvent({
    ...activeWarning,
    serial: 2,
    hypocenter: "newer corrected region",
  }).acceptedEvent;
  assert.equal(higherAfterFinal?.serial, 2);
  assert.equal(higherAfterFinal?.hypocenter, "newer corrected region");
  assert.equal(higherAfterFinal?.isFinal, true);

  const cancellation = upsertEvent({
    ...activeWarning,
    serial: 3,
    isCancel: true,
  }).acceptedEvent;
  assert.equal(cancellation?.isFinal, true);
  assert.equal(cancellation?.isCancel, true);
  assert.equal(
    upsertEvent({ ...activeWarning, serial: 3 }).acceptedEvent,
    null,
  );
  const higherAfterCancellation = upsertEvent({
    ...activeWarning,
    serial: 4,
  }).acceptedEvent;
  assert.equal(higherAfterCancellation?.serial, 4);
  assert.equal(higherAfterCancellation?.isFinal, true);
  assert.equal(higherAfterCancellation?.isCancel, true);
  assert.equal(getEvent(activeWarning.id)?.isCancel, true);
});

test("legacy notification wrapper uses the shared typed payload policy", async () => {
  const { buildNotification } = await import("../src/push/payload.ts");
  const now = new Date().toISOString();
  const event = {
    id: "jma_eew:legacy-payload",
    sourceId: "jma_eew",
    eventId: "legacy-payload",
    serial: 3,
    kind: "eew",
    originTimeUtc: now,
    reportTimeUtc: now,
    hypocenter: "Test Region",
    latitude: 35,
    longitude: 135,
    magnitude: 5.8,
    depth: 20,
    maxIntensity: "5+",
    isWarn: true,
    isFinal: false,
    isCancel: false,
    isTraining: false,
    tsunami: null,
    raw: null,
  };
  const notification = buildNotification(event, "new", "japanese-voice");
  assert.equal(notification.expiry, 0);
  assert.equal(notification.headers()["apns-expiration"], 0);
  assert.deepEqual(notification.rawPayload.aps.sound, {
    critical: 1,
    name: "quakesignal_japanese_voice.caf",
    volume: 1.0,
  });
  assert.equal(notification.rawPayload.aps["interruption-level"], "critical");
  assert.deepEqual(notification.rawPayload.event, {
    sourceId: "jma_eew",
    eventId: "legacy-payload",
    serial: 3,
    kind: "eew",
    originTimeUtc: now,
    reportTimeUtc: now,
    hypocenter: "Test Region",
    latitude: 35,
    longitude: 135,
    magnitude: 5.8,
    depth: 20,
    maxIntensity: "5+",
    isWarn: true,
    isFinal: false,
    isCancel: false,
    isTraining: false,
    tsunami: null,
  });
});

function jmaEewWarningPayload(nowMs) {
  const announced = new Date(nowMs);
  const pad = (value) => String(value).padStart(2, "0");
  const jst = new Date(nowMs + 9 * 60 * 60_000);
  const stamp =
    `${jst.getUTCFullYear()}/${pad(jst.getUTCMonth() + 1)}/${pad(jst.getUTCDate())} ` +
    `${pad(jst.getUTCHours())}:${pad(jst.getUTCMinutes())}:${pad(jst.getUTCSeconds())}`;
  return {
    Title: "Earthquake Early Warning",
    CodeType: "E",
    Issue: { Source: "JMA", Status: "Warning" },
    EventID: `${announced.getUTCFullYear()}0801120000`,
    Serial: 2,
    AnnouncedTime: stamp,
    OriginTime: stamp,
    Hypocenter: "Noto Peninsula",
    Latitude: 37.5,
    Longitude: 137.3,
    Magunitude: 6.2,
    Depth: 10,
    MaxIntensity: "6-",
    Accuracy: { Epicenter: "1", Depth: "1", Magnitude: "1" },
    MaxIntChange: { String: "0", Reason: "" },
    WarnArea: [],
    isSea: true,
    isTraining: false,
    isAssumption: false,
    isWarn: true,
    isFinal: false,
    isCancel: false,
    OriginalText: "warning",
  };
}

const USGS_FEATURE_COLLECTION = {
  type: "FeatureCollection",
  metadata: { count: 1 },
  features: [
    {
      type: "Feature",
      id: "us7000abcd",
      properties: {
        mag: 6.1,
        place: "32 km WSW of Ovalle, Chile",
        time: Date.parse("2026-08-30T01:00:00.000Z"),
        updated: Date.parse("2026-08-30T01:02:00.000Z"),
        tsunami: 0,
        type: "earthquake",
        title: "M 6.1 - 32 km WSW of Ovalle, Chile",
        status: "reviewed",
      },
      geometry: { type: "Point", coordinates: [-71.3, -30.6, 40] },
    },
  ],
};

const EMSC_FEATURE_COLLECTION = {
  type: "FeatureCollection",
  features: [
    {
      type: "Feature",
      id: "20260830_0000123",
      properties: {
        time: "2026-08-30T02:15:00.000Z",
        lastupdate: "2026-08-30T02:16:00.000Z",
        mag: 5.4,
        flynn_region: "Greece",
      },
      geometry: { type: "Point", coordinates: [21.7, 38.4, 12] },
    },
  ],
};

test("shipped normalize-to-notify path maps Wolfx EEW and new catalogs", async () => {
  const {
    normalizeJmaEew,
    normalizeCatalogGeoJSON,
  } = await import("../src/alerts/normalize.ts");
  const {
    buildPushPayload,
    notificationReasonForEvent,
  } = await import("../src/push/policy.ts");

  const nowMs = Date.parse("2026-08-30T03:00:00.000Z");
  const wolfxEvent = normalizeJmaEew(jmaEewWarningPayload(nowMs));
  assert.equal(wolfxEvent.sourceId, "jma_eew");
  assert.equal(notificationReasonForEvent(wolfxEvent, null), "new");
  const wolfxPayload = buildPushPayload(wolfxEvent, "new", "urgent-tone", nowMs);
  assert.equal(wolfxPayload.aps["interruption-level"], "critical");
  assert.deepEqual(wolfxPayload.aps.sound, {
    critical: 1,
    name: "quakesignal_urgent.caf",
    volume: 1.0,
  });

  const usgsEvents = normalizeCatalogGeoJSON("usgs_eqlist", USGS_FEATURE_COLLECTION);
  assert.equal(usgsEvents.length, 1);
  assert.equal(usgsEvents[0].id, "usgs_eqlist:us7000abcd");
  assert.equal(usgsEvents[0].kind, "report");
  assert.equal(notificationReasonForEvent(usgsEvents[0], null), "report");
  const usgsPayload = buildPushPayload(usgsEvents[0], "report", "system", nowMs);
  assert.equal(usgsPayload.aps["interruption-level"], "active");
  assert.equal(usgsPayload.aps.sound, "default");
  assert.equal(usgsPayload.aps.alert["title-loc-args"][0], "USGS");

  const emscEvents = normalizeCatalogGeoJSON("emsc_eqlist", EMSC_FEATURE_COLLECTION);
  assert.equal(emscEvents.length, 1);
  assert.equal(emscEvents[0].sourceId, "emsc_eqlist");
  assert.equal(notificationReasonForEvent(emscEvents[0], null), "report");
  const emscPayload = buildPushPayload(emscEvents[0], "report", "system", nowMs);
  assert.equal(emscPayload.aps["interruption-level"], "active");
  assert.equal(emscPayload.sourceId, "emsc_eqlist");
});

test("training and stale warnings are not Apple emergency alerts", async () => {
  const { normalizeJmaEew } = await import("../src/alerts/normalize.ts");
  const { buildPushPayload, notificationReasonForEvent } = await import("../src/push/policy.ts");
  const nowMs = Date.parse("2026-08-30T03:00:00.000Z");
  const training = normalizeJmaEew({
    ...jmaEewWarningPayload(nowMs),
    isTraining: true,
    isWarn: false,
  });
  assert.equal(notificationReasonForEvent(training, null), "training");
  const trainingPayload = buildPushPayload(training, "training", "urgent-tone", nowMs);
  assert.equal(trainingPayload.aps["interruption-level"], "active");
  assert.equal(trainingPayload.aps.sound, "default");

  const stale = buildPushPayload(
    normalizeJmaEew(jmaEewWarningPayload(nowMs)),
    "new",
    "urgent-tone",
    nowMs + 11 * 60_000,
  );
  assert.equal(stale.aps["interruption-level"], "active");
});
