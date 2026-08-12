import { DatabaseSync } from "node:sqlite";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { config } from "./config.js";
import type { DeviceRecord, DeviceRegistrationInput, EventRevision, NormalizedEvent } from "./types/domain.js";
import type { WolfxSourceId } from "./types/wolfx.js";
import { createLogger } from "./logger.js";
import { haversineDistanceKm } from "./util/geo.js";
import { isQuietHours } from "./util/time.js";

const log = createLogger("db");

mkdirSync(dirname(config.dbPath), { recursive: true });

// Node's built-in sqlite module (stable since Node 22.5, no native/prebuilt
// binary to fetch or compile) -- chosen over better-sqlite3 specifically
// because better-sqlite3's native addon doesn't yet build against very new
// Node/V8 releases; this sidesteps that entirely.
export const db = new DatabaseSync(config.dbPath);
db.exec("PRAGMA journal_mode = WAL");

db.exec(`
  CREATE TABLE IF NOT EXISTS devices (
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

  CREATE TABLE IF NOT EXISTS event_revisions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    event_ref TEXT NOT NULL,
    serial INTEGER NOT NULL,
    magnitude REAL,
    max_intensity TEXT,
    is_warn INTEGER NOT NULL DEFAULT 0,
    is_final INTEGER NOT NULL DEFAULT 0,
    is_cancel INTEGER NOT NULL DEFAULT 0,
    report_time_utc TEXT,
    recorded_at_utc TEXT NOT NULL
  );
  CREATE INDEX IF NOT EXISTS idx_revisions_event ON event_revisions(event_ref);

  CREATE TABLE IF NOT EXISTS events (
    id TEXT PRIMARY KEY,
    source_id TEXT NOT NULL,
    event_id TEXT NOT NULL,
    serial INTEGER NOT NULL DEFAULT 1,
    kind TEXT NOT NULL,
    origin_time_utc TEXT,
    report_time_utc TEXT,
    hypocenter TEXT,
    latitude REAL,
    longitude REAL,
    magnitude REAL,
    depth REAL,
    max_intensity TEXT,
    is_warn INTEGER NOT NULL DEFAULT 0,
    is_final INTEGER NOT NULL DEFAULT 0,
    is_cancel INTEGER NOT NULL DEFAULT 0,
    is_training INTEGER NOT NULL DEFAULT 0,
    tsunami TEXT,
    raw_json TEXT,
    first_seen_utc TEXT NOT NULL,
    last_updated_utc TEXT NOT NULL
  );
  CREATE INDEX IF NOT EXISTS idx_events_last_updated ON events(last_updated_utc DESC);
  CREATE INDEX IF NOT EXISTS idx_events_source ON events(source_id);
`);

log.info(`sqlite ready at ${config.dbPath}`);

function rowToDevice(row: any): DeviceRecord {
  return {
    token: row.token,
    environment: row.environment,
    locale: row.locale,
    sources: JSON.parse(row.sources),
    minMagnitude: row.min_magnitude,
    // Legacy schema column; the public bundle is not approved for Critical
    // Alerts, so a persisted or forged preference can never enable them.
    criticalAlertsEnabled: false,
    cityName: row.city_name,
    latitude: row.latitude,
    longitude: row.longitude,
    radiusKm: row.radius_km,
    includeTestAlerts: !!row.include_test_alerts,
    utcOffsetMinutes: row.utc_offset_minutes,
    notifyAtNight: !!row.notify_at_night,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

const upsertDeviceStmt = db.prepare(`
  INSERT INTO devices (
    token, environment, locale, sources, min_magnitude, critical_alerts_enabled,
    city_name, latitude, longitude, radius_km, include_test_alerts,
    utc_offset_minutes, notify_at_night, created_at, updated_at
  )
  VALUES (
    @token, @environment, @locale, @sources, @minMagnitude, @criticalAlertsEnabled,
    @cityName, @latitude, @longitude, @radiusKm, @includeTestAlerts,
    @utcOffsetMinutes, @notifyAtNight, @now, @now
  )
  ON CONFLICT(token) DO UPDATE SET
    environment = excluded.environment,
    locale = excluded.locale,
    sources = excluded.sources,
    min_magnitude = excluded.min_magnitude,
    critical_alerts_enabled = excluded.critical_alerts_enabled,
    city_name = excluded.city_name,
    latitude = excluded.latitude,
    longitude = excluded.longitude,
    radius_km = excluded.radius_km,
    include_test_alerts = excluded.include_test_alerts,
    utc_offset_minutes = excluded.utc_offset_minutes,
    notify_at_night = excluded.notify_at_night,
    updated_at = excluded.updated_at
`);

export function upsertDevice(input: DeviceRegistrationInput): DeviceRecord {
  const now = new Date().toISOString();
  upsertDeviceStmt.run({
    token: input.token,
    environment: input.environment,
    locale: input.locale,
    sources: JSON.stringify(input.sources),
    minMagnitude: input.minMagnitude,
    criticalAlertsEnabled: 0,
    cityName: input.cityName,
    latitude: input.latitude,
    longitude: input.longitude,
    radiusKm: input.radiusKm,
    includeTestAlerts: input.includeTestAlerts ? 1 : 0,
    utcOffsetMinutes: input.utcOffsetMinutes,
    notifyAtNight: input.notifyAtNight ? 1 : 0,
    now,
  });
  return getDevice(input.token)!;
}

export function getDevice(token: string): DeviceRecord | null {
  const row = db.prepare("SELECT * FROM devices WHERE token = ?").get(token);
  return row ? rowToDevice(row) : null;
}

export function deleteDevice(token: string): void {
  db.prepare("DELETE FROM devices WHERE token = ?").run(token);
}

export interface DistanceFilterEvent {
  magnitude: number | null;
  latitude: number | null;
  longitude: number | null;
  isTraining: boolean;
  /** Only "report" is subject to the quiet-hours check; active EEW warnings always go through. */
  isRoutineReport: boolean;
}

/**
 * Devices subscribed to `sourceId` whose magnitude threshold this event
 * clears, AND (if the device has a city/radius subscription) that fall
 * within that radius of the event's epicenter, AND (for drill/training
 * broadcasts) that have opted in to receiving them, AND (for routine
 * reports, at night, if quiet hours are enabled) aren't currently in their
 * quiet-hours window. A device with no latitude/longitude/radiusKm set gets
 * no distance filtering -- magnitude threshold alone still applies.
 */
export function listDevicesForSource(sourceId: WolfxSourceId, event: DistanceFilterEvent): DeviceRecord[] {
  const rows = db.prepare("SELECT * FROM devices").all() as any[];
  return rows.map(rowToDevice).filter((d) => {
    if (!d.sources.includes(sourceId)) return false;
    if (event.isTraining && !d.includeTestAlerts) return false;
    if ((event.magnitude ?? 0) < d.minMagnitude) return false;
    if (event.isRoutineReport && !d.notifyAtNight && d.utcOffsetMinutes != null) {
      if (isQuietHours(d.utcOffsetMinutes)) return false;
    }
    if (d.radiusKm != null && d.latitude != null && d.longitude != null) {
      if (event.latitude == null || event.longitude == null) return false;
      const distance = haversineDistanceKm(d.latitude, d.longitude, event.latitude, event.longitude);
      if (distance > d.radiusKm) return false;
    }
    return true;
  });
}

export function listAllDevices(): DeviceRecord[] {
  return (db.prepare("SELECT * FROM devices").all() as any[]).map(rowToDevice);
}

export function getEvent(id: string): NormalizedEvent | null {
  const row = db.prepare("SELECT * FROM events WHERE id = ?").get(id) as any;
  return row ? rowToEvent(row) : null;
}

function rowToEvent(row: any): NormalizedEvent {
  return {
    id: row.id,
    sourceId: row.source_id,
    eventId: row.event_id,
    serial: row.serial,
    kind: row.kind,
    originTimeUtc: row.origin_time_utc,
    reportTimeUtc: row.report_time_utc,
    hypocenter: row.hypocenter,
    latitude: row.latitude,
    longitude: row.longitude,
    magnitude: row.magnitude,
    depth: row.depth,
    maxIntensity: row.max_intensity,
    isWarn: !!row.is_warn,
    isFinal: !!row.is_final,
    isCancel: !!row.is_cancel,
    isTraining: !!row.is_training,
    tsunami: row.tsunami,
    raw: row.raw_json ? JSON.parse(row.raw_json) : null,
  };
}

const upsertEventStmt = db.prepare(`
  INSERT INTO events (
    id, source_id, event_id, serial, kind, origin_time_utc, report_time_utc,
    hypocenter, latitude, longitude, magnitude, depth, max_intensity,
    is_warn, is_final, is_cancel, is_training, tsunami, raw_json, first_seen_utc, last_updated_utc
  ) VALUES (
    @id, @sourceId, @eventId, @serial, @kind, @originTimeUtc, @reportTimeUtc,
    @hypocenter, @latitude, @longitude, @magnitude, @depth, @maxIntensity,
    @isWarn, @isFinal, @isCancel, @isTraining, @tsunami, @rawJson, @now, @now
  )
  ON CONFLICT(id) DO UPDATE SET
    serial = excluded.serial,
    origin_time_utc = excluded.origin_time_utc,
    report_time_utc = excluded.report_time_utc,
    hypocenter = excluded.hypocenter,
    latitude = excluded.latitude,
    longitude = excluded.longitude,
    magnitude = excluded.magnitude,
    depth = excluded.depth,
    max_intensity = excluded.max_intensity,
    is_warn = excluded.is_warn,
    is_final = excluded.is_final,
    is_cancel = excluded.is_cancel,
    is_training = excluded.is_training,
    tsunami = excluded.tsunami,
    raw_json = excluded.raw_json,
    last_updated_utc = excluded.last_updated_utc
`);

/** Insert-or-update and report back whether the row was new / what changed, so callers can decide whether to push. */
export function upsertEvent(event: NormalizedEvent): { previous: NormalizedEvent | null } {
  const previous = getEvent(event.id);
  const now = new Date().toISOString();
  upsertEventStmt.run({
    id: event.id,
    sourceId: event.sourceId,
    eventId: event.eventId,
    serial: event.serial,
    kind: event.kind,
    originTimeUtc: event.originTimeUtc,
    reportTimeUtc: event.reportTimeUtc,
    hypocenter: event.hypocenter,
    latitude: event.latitude,
    longitude: event.longitude,
    magnitude: event.magnitude,
    depth: event.depth,
    maxIntensity: event.maxIntensity,
    isWarn: event.isWarn ? 1 : 0,
    isFinal: event.isFinal ? 1 : 0,
    isCancel: event.isCancel ? 1 : 0,
    isTraining: event.isTraining ? 1 : 0,
    tsunami: event.tsunami,
    rawJson: JSON.stringify(event.raw ?? null),
    now,
  });

  if (isMeaningfulRevision(event, previous)) {
    insertRevisionStmt.run({
      eventRef: event.id,
      serial: event.serial,
      magnitude: event.magnitude,
      maxIntensity: event.maxIntensity,
      isWarn: event.isWarn ? 1 : 0,
      isFinal: event.isFinal ? 1 : 0,
      isCancel: event.isCancel ? 1 : 0,
      reportTimeUtc: event.reportTimeUtc,
      now,
    });
  }

  return { previous };
}

export function listRecentEvents(limit = 50, sourceId?: string): NormalizedEvent[] {
  const rows = sourceId
    ? db
        .prepare("SELECT * FROM events WHERE source_id = ? ORDER BY last_updated_utc DESC LIMIT ?")
        .all(sourceId, limit)
    : db.prepare("SELECT * FROM events ORDER BY last_updated_utc DESC LIMIT ?").all(limit);
  return (rows as any[]).map(rowToEvent);
}

/** Same "did this actually change" test the push pipeline uses, so the revision timeline lines up with what got (or would have) notified. */
function isMeaningfulRevision(event: NormalizedEvent, previous: NormalizedEvent | null): boolean {
  if (previous === null) return true;
  if (event.isCancel && !previous.isCancel) return true;
  if (event.isFinal && !previous.isFinal) return true;
  return event.serial > previous.serial;
}

const insertRevisionStmt = db.prepare(`
  INSERT INTO event_revisions (
    event_ref, serial, magnitude, max_intensity, is_warn, is_final, is_cancel, report_time_utc, recorded_at_utc
  ) VALUES (
    @eventRef, @serial, @magnitude, @maxIntensity, @isWarn, @isFinal, @isCancel, @reportTimeUtc, @now
  )
`);

function rowToRevision(row: any): EventRevision {
  return {
    eventRef: row.event_ref,
    serial: row.serial,
    magnitude: row.magnitude,
    maxIntensity: row.max_intensity,
    isWarn: !!row.is_warn,
    isFinal: !!row.is_final,
    isCancel: !!row.is_cancel,
    reportTimeUtc: row.report_time_utc,
    recordedAtUtc: row.recorded_at_utc,
  };
}

/** Oldest-first revision history for one event -- the Detail screen's report timeline. */
export function listRevisions(eventRef: string): EventRevision[] {
  const rows = db
    .prepare("SELECT * FROM event_revisions WHERE event_ref = ? ORDER BY serial ASC, id ASC")
    .all(eventRef) as any[];
  return rows.map(rowToRevision);
}
