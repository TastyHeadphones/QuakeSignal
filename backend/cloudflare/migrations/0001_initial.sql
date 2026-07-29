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

CREATE INDEX IF NOT EXISTS idx_revisions_event
  ON event_revisions(event_ref);

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

CREATE INDEX IF NOT EXISTS idx_events_last_updated
  ON events(last_updated_utc DESC);

CREATE INDEX IF NOT EXISTS idx_events_source
  ON events(source_id);
