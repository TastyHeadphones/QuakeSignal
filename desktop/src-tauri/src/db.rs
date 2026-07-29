use crate::domain::{EventKind, NormalizedEvent};
use chrono::Utc;
use rusqlite::{params, Connection, Row};
use std::path::PathBuf;
use tauri::{AppHandle, Manager};

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS events (
    id TEXT PRIMARY KEY,
    source_id TEXT NOT NULL,
    event_id TEXT NOT NULL,
    serial INTEGER NOT NULL,
    kind TEXT NOT NULL,
    origin_time_utc TEXT,
    report_time_utc TEXT,
    hypocenter TEXT NOT NULL,
    latitude REAL,
    longitude REAL,
    magnitude REAL,
    depth REAL,
    max_intensity TEXT,
    is_warn INTEGER NOT NULL,
    is_final INTEGER NOT NULL,
    is_cancel INTEGER NOT NULL,
    is_training INTEGER NOT NULL,
    tsunami TEXT,
    raw TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_events_updated_at ON events(updated_at);

CREATE TABLE IF NOT EXISTS event_revisions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id TEXT NOT NULL,
    serial INTEGER NOT NULL,
    reason TEXT NOT NULL,
    snapshot TEXT NOT NULL,
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_revisions_event_id ON event_revisions(event_id);
";

pub fn open(app: &AppHandle) -> Result<Connection, String> {
    let dir = app.path().app_data_dir().map_err(|e| e.to_string())?;
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let path: PathBuf = dir.join("quakesignal.db");
    let conn = Connection::open(path).map_err(|e| e.to_string())?;
    conn.execute_batch(SCHEMA).map_err(|e| e.to_string())?;
    Ok(conn)
}

fn kind_to_str(kind: EventKind) -> &'static str {
    match kind {
        EventKind::Eew => "eew",
        EventKind::Report => "report",
    }
}

fn kind_from_str(s: &str) -> EventKind {
    if s == "report" {
        EventKind::Report
    } else {
        EventKind::Eew
    }
}

fn row_to_event(row: &Row) -> rusqlite::Result<NormalizedEvent> {
    let raw_str: String = row.get("raw")?;
    let kind_str: String = row.get("kind")?;
    Ok(NormalizedEvent {
        id: row.get("id")?,
        source_id: row.get("source_id")?,
        event_id: row.get("event_id")?,
        serial: row.get("serial")?,
        kind: kind_from_str(&kind_str),
        origin_time_utc: row.get("origin_time_utc")?,
        report_time_utc: row.get("report_time_utc")?,
        hypocenter: row.get("hypocenter")?,
        latitude: row.get("latitude")?,
        longitude: row.get("longitude")?,
        magnitude: row.get("magnitude")?,
        depth: row.get("depth")?,
        max_intensity: row.get("max_intensity")?,
        is_warn: row.get("is_warn")?,
        is_final: row.get("is_final")?,
        is_cancel: row.get("is_cancel")?,
        is_training: row.get("is_training")?,
        tsunami: row.get("tsunami")?,
        raw: serde_json::from_str(&raw_str).unwrap_or(serde_json::Value::Null),
    })
}

pub fn get_event(conn: &Connection, id: &str) -> Option<NormalizedEvent> {
    conn.query_row(
        "SELECT * FROM events WHERE id = ?1",
        params![id],
        row_to_event,
    )
    .ok()
}

/// Upserts the event row and, if `is_meaningful_revision` (checked by the
/// caller so it can also be used to decide push behavior), appends a
/// revision snapshot. Returns the previous row, if any, so the caller can
/// run `determine_reason` against it — mirrors backend/src/db.ts::upsertEvent.
pub fn upsert_event(
    conn: &Connection,
    event: &NormalizedEvent,
    meaningful_revision: bool,
    reason: &str,
) -> Result<Option<NormalizedEvent>, String> {
    let previous = get_event(conn, &event.id);
    let raw_str = serde_json::to_string(&event.raw).map_err(|e| e.to_string())?;
    let now = Utc::now().to_rfc3339();

    conn.execute(
        "INSERT INTO events (
            id, source_id, event_id, serial, kind, origin_time_utc, report_time_utc,
            hypocenter, latitude, longitude, magnitude, depth, max_intensity,
            is_warn, is_final, is_cancel, is_training, tsunami, raw, updated_at
        ) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20)
        ON CONFLICT(id) DO UPDATE SET
            serial = excluded.serial,
            kind = excluded.kind,
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
            raw = excluded.raw,
            updated_at = excluded.updated_at",
        params![
            event.id,
            event.source_id,
            event.event_id,
            event.serial,
            kind_to_str(event.kind),
            event.origin_time_utc,
            event.report_time_utc,
            event.hypocenter,
            event.latitude,
            event.longitude,
            event.magnitude,
            event.depth,
            event.max_intensity,
            event.is_warn,
            event.is_final,
            event.is_cancel,
            event.is_training,
            event.tsunami,
            raw_str,
            now,
        ],
    )
    .map_err(|e| e.to_string())?;

    if meaningful_revision {
        conn.execute(
            "INSERT INTO event_revisions (event_id, serial, reason, snapshot, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![
                event.id,
                event.serial,
                reason,
                serde_json::to_string(event).map_err(|e| e.to_string())?,
                now,
            ],
        )
        .map_err(|e| e.to_string())?;
    }

    Ok(previous)
}

pub fn list_recent_events(conn: &Connection, limit: i64) -> Vec<NormalizedEvent> {
    let mut stmt = match conn.prepare("SELECT * FROM events ORDER BY updated_at DESC LIMIT ?1") {
        Ok(s) => s,
        Err(_) => return Vec::new(),
    };
    let rows = stmt.query_map(params![limit], row_to_event);
    match rows {
        Ok(mapped) => mapped.filter_map(|r| r.ok()).collect(),
        Err(_) => Vec::new(),
    }
}

pub fn list_revisions(conn: &Connection, event_id: &str) -> Vec<NormalizedEvent> {
    let mut stmt = match conn
        .prepare("SELECT snapshot FROM event_revisions WHERE event_id = ?1 ORDER BY created_at ASC")
    {
        Ok(s) => s,
        Err(_) => return Vec::new(),
    };
    let rows = stmt.query_map(params![event_id], |row| row.get::<_, String>(0));
    match rows {
        Ok(mapped) => mapped
            .filter_map(|r| r.ok())
            .filter_map(|snapshot| serde_json::from_str(&snapshot).ok())
            .collect(),
        Err(_) => Vec::new(),
    }
}
