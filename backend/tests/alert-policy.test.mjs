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
  assert.equal(notification.rawPayload.aps.sound, "quakesignal_japanese_voice.caf");
  assert.equal(notification.rawPayload.aps["interruption-level"], "time-sensitive");
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
