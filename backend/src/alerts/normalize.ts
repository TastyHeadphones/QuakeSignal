import type {
  CatalogGeoJSONCollection,
  CatalogGeoJSONFeature,
  CatalogSourceId,
} from "../types/catalog.js";
import { isCatalogSourceId } from "../types/catalog.js";
import type {
  CencCqEewMessage,
  CencEqlistEntry,
  JmaEewMessage,
  JmaEqlistEntry,
  ScFjEewMessage,
  WolfxEqlistMessage,
} from "../types/wolfx.js";
import type { NormalizedEvent } from "../types/domain.js";

function parseLocalDateTime(raw: string, offsetHours: number): string | null {
  const m = /(\d{4})[/-](\d{2})[/-](\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?/.exec(raw);
  if (!m) return null;
  const [, y, mo, d, h, mi, s] = m;
  const utcMs =
    Date.UTC(Number(y), Number(mo) - 1, Number(d), Number(h), Number(mi), Number(s ?? "0")) -
    offsetHours * 3600 * 1000;
  return new Date(utcMs).toISOString();
}

/** JMA timestamps are published in JST (UTC+9). */
const parseJst = (raw: string | undefined | null): string | null => (raw ? parseLocalDateTime(raw, 9) : null);
/** CENC / provincial bureau timestamps are published in China Standard Time (UTC+8). */
const parseCst = (raw: string | undefined | null): string | null => (raw ? parseLocalDateTime(raw, 8) : null);

function toNumber(v: unknown): number | null {
  if (v === null || v === undefined || v === "") return null;
  const n = typeof v === "string" ? Number(v.replace(/[^\d.+-]/g, "")) : Number(v);
  return Number.isFinite(n) ? n : null;
}

export function normalizeJmaEew(msg: JmaEewMessage): NormalizedEvent {
  return {
    id: `jma_eew:${msg.EventID}`,
    sourceId: "jma_eew",
    eventId: msg.EventID,
    serial: msg.Serial ?? 1,
    kind: "eew",
    originTimeUtc: parseJst(msg.OriginTime),
    reportTimeUtc: parseJst(msg.AnnouncedTime),
    hypocenter: msg.Hypocenter,
    latitude: toNumber(msg.Latitude),
    longitude: toNumber(msg.Longitude),
    magnitude: toNumber(msg.Magunitude),
    depth: toNumber(msg.Depth),
    maxIntensity: msg.MaxIntensity ?? null,
    isWarn: !!msg.isWarn,
    isFinal: !!msg.isFinal,
    isCancel: !!msg.isCancel,
    isTraining: !!msg.isTraining,
    tsunami: null,
    raw: msg,
  };
}

/** Sichuan (sc_eew) and Fujian (fj_eew) share this wire shape. */
export function normalizeScFjEew(msg: ScFjEewMessage, sourceId: "sc_eew" | "fj_eew"): NormalizedEvent {
  return {
    id: `${sourceId}:${msg.EventID}`,
    sourceId,
    eventId: msg.EventID,
    serial: msg.ReportNum ?? 1,
    kind: "eew",
    originTimeUtc: parseCst(msg.OriginTime),
    reportTimeUtc: parseCst(msg.ReportTime),
    hypocenter: msg.HypoCenter,
    latitude: toNumber(msg.Latitude),
    longitude: toNumber(msg.Longitude),
    magnitude: toNumber(msg.Magunitude),
    depth: toNumber(msg.Depth),
    maxIntensity: msg.MaxIntensity != null ? String(msg.MaxIntensity) : null,
    // These feeds only ever publish while a warning is active, unlike JMA
    // which has an explicit isWarn flag -- presence on this feed *is* the warning.
    isWarn: true,
    isFinal: !!msg.isFinal,
    isCancel: false,
    isTraining: false,
    tsunami: null,
    raw: msg,
  };
}

/** CENC (cenc_eew) and Chongqing (cq_eew) share this wire shape. */
export function normalizeCencCqEew(msg: CencCqEewMessage, sourceId: "cenc_eew" | "cq_eew"): NormalizedEvent {
  return {
    id: `${sourceId}:${msg.EventID}`,
    sourceId,
    eventId: msg.EventID,
    serial: msg.ReportNum ?? 1,
    kind: "eew",
    originTimeUtc: parseCst(msg.OriginTime),
    reportTimeUtc: parseCst(msg.ReportTime),
    hypocenter: msg.HypoCenter,
    latitude: toNumber(msg.Latitude),
    longitude: toNumber(msg.Longitude),
    magnitude: toNumber(msg.Magnitude),
    depth: toNumber(msg.Depth),
    maxIntensity: msg.MaxIntensity != null ? msg.MaxIntensity.toFixed(1) : null,
    isWarn: true,
    isFinal: false,
    isCancel: false,
    isTraining: false,
    tsunami: null,
    raw: msg,
  };
}

export interface EqlistRankedEntry<T> {
  rank: number;
  entry: T;
}

/**
 * cenc_eqlist / jma_eqlist ship as `{ "No1": {...}, "No2": {...}, ..., "md5": "..." }`,
 * an object keyed by rank rather than an array -- pull the ranked entries out generically.
 */
export function extractEqlistEntries<T>(msg: WolfxEqlistMessage): EqlistRankedEntry<T>[] {
  const out: EqlistRankedEntry<T>[] = [];
  for (const [key, value] of Object.entries(msg)) {
    const m = /^No(\d+)$/.exec(key);
    if (m && value && typeof value === "object") {
      out.push({ rank: Number(m[1]), entry: value as T });
    }
  }
  return out.sort((a, b) => a.rank - b.rank);
}

export function normalizeCencEqlistEntry(entry: CencEqlistEntry): NormalizedEvent {
  return {
    id: `cenc_eqlist:${entry.EventID}`,
    sourceId: "cenc_eqlist",
    eventId: entry.EventID,
    serial: entry.type === "reviewed" ? 2 : 1,
    kind: "report",
    originTimeUtc: parseCst(entry.time),
    reportTimeUtc: parseCst(entry.ReportTime),
    hypocenter: entry.placeName || entry.location,
    latitude: toNumber(entry.latitude),
    longitude: toNumber(entry.longitude),
    magnitude: toNumber(entry.magnitude),
    depth: toNumber(entry.depth),
    maxIntensity: entry.intensity || null,
    isWarn: false,
    isFinal: entry.type === "reviewed",
    isCancel: false,
    isTraining: false,
    tsunami: null,
    raw: entry,
  };
}

export function normalizeJmaEqlistEntry(entry: JmaEqlistEntry): NormalizedEvent {
  return {
    id: `jma_eqlist:${entry.EventID}`,
    sourceId: "jma_eqlist",
    eventId: entry.EventID,
    serial: 1,
    kind: "report",
    originTimeUtc: parseJst(entry.time_full || entry.time),
    reportTimeUtc: parseJst(entry.time_full || entry.time),
    hypocenter: entry.location,
    latitude: toNumber(entry.latitude),
    longitude: toNumber(entry.longitude),
    magnitude: toNumber(entry.magnitude),
    depth: toNumber(entry.depth), // "20km" -> 20, the generic numeric strip handles the unit suffix
    maxIntensity: entry.shindo || null,
    isWarn: false,
    isFinal: true,
    isCancel: false,
    isTraining: false,
    tsunami: entry.info || null,
    raw: entry,
  };
}

const MAX_CATALOG_EVENTS = 50;

function isPlainRecord(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === "object" && !Array.isArray(value);
}

function catalogCoordinates(geometry: unknown): {
  longitude: number | null;
  latitude: number | null;
  depth: number | null;
} {
  if (!isPlainRecord(geometry) || geometry.type !== "Point") {
    return { longitude: null, latitude: null, depth: null };
  }
  const coordinates = geometry.coordinates;
  if (!Array.isArray(coordinates) || coordinates.length < 2) {
    return { longitude: null, latitude: null, depth: null };
  }
  return {
    longitude: toNumber(coordinates[0]),
    latitude: toNumber(coordinates[1]),
    depth: coordinates.length > 2 ? toNumber(coordinates[2]) : null,
  };
}

function catalogTimestamp(value: unknown): string | null {
  if (typeof value === "number" && Number.isFinite(value)) {
    const ms = value > 1e12 ? value : value * 1000;
    const date = new Date(ms);
    return Number.isFinite(date.getTime()) ? date.toISOString() : null;
  }
  if (typeof value === "string" && value.trim() !== "") {
    const parsed = Date.parse(value);
    return Number.isFinite(parsed) ? new Date(parsed).toISOString() : null;
  }
  return null;
}

function catalogEventId(feature: CatalogGeoJSONFeature, properties: Record<string, unknown>): string | null {
  if (typeof feature.id === "string" && feature.id.trim() !== "") return feature.id.trim();
  if (typeof feature.id === "number" && Number.isFinite(feature.id)) return String(feature.id);
  for (const key of ["ids", "code", "publicid", "unid", "sourceId"]) {
    const value = properties[key];
    if (typeof value === "string" && value.trim() !== "") return value.trim();
  }
  return null;
}

function catalogPlace(properties: Record<string, unknown>): string {
  for (const key of ["place", "flynn_region", "locality", "title", "region"]) {
    const value = properties[key];
    if (typeof value === "string" && value.trim() !== "") return value.trim();
  }
  return "";
}

function catalogMagnitude(properties: Record<string, unknown>): number | null {
  return toNumber(properties.mag ?? properties.magnitude);
}

function catalogIntensity(properties: Record<string, unknown>): string | null {
  const value = properties.mmi ?? properties.intensity;
  if (value === null || value === undefined || value === "") return null;
  return String(value);
}

function catalogTsunami(properties: Record<string, unknown>): string | null {
  const value = properties.tsunami;
  if (value === 1 || value === true || value === "1") return "tsunami";
  if (typeof value === "string" && value.trim() !== "" && value !== "0") return value.trim();
  return null;
}

function isEarthquakeFeature(properties: Record<string, unknown>, sourceId: CatalogSourceId): boolean {
  if (sourceId === "usgs_eqlist") {
    return properties.type === undefined || properties.type === "earthquake";
  }
  return true;
}

export function normalizeCatalogFeature(
  sourceId: CatalogSourceId,
  feature: CatalogGeoJSONFeature,
): NormalizedEvent | null {
  if (!isPlainRecord(feature) || feature.type !== "Feature") return null;
  const properties = isPlainRecord(feature.properties) ? feature.properties : null;
  if (properties === null || !isEarthquakeFeature(properties, sourceId)) return null;
  const eventId = catalogEventId(feature, properties);
  const hypocenter = catalogPlace(properties);
  const magnitude = catalogMagnitude(properties);
  const originTimeUtc = catalogTimestamp(
    properties.time ?? properties.origintime ?? properties.origin_time,
  );
  const reportTimeUtc = catalogTimestamp(
    properties.updated ?? properties.lastupdate ?? properties.time ?? properties.origintime,
  ) ?? originTimeUtc;
  const { latitude, longitude, depth } = catalogCoordinates(feature.geometry);
  if (
    eventId === null ||
    hypocenter === "" ||
    magnitude === null ||
    originTimeUtc === null ||
    latitude === null ||
    longitude === null
  ) {
    return null;
  }
  return {
    id: `${sourceId}:${eventId}`,
    sourceId,
    eventId,
    serial: 1,
    kind: "report",
    originTimeUtc,
    reportTimeUtc,
    hypocenter,
    latitude,
    longitude,
    magnitude,
    depth,
    maxIntensity: catalogIntensity(properties),
    isWarn: false,
    isFinal: true,
    isCancel: false,
    isTraining: false,
    tsunami: catalogTsunami(properties),
    raw: feature,
  };
}

export function normalizeCatalogGeoJSON(
  sourceId: CatalogSourceId,
  message: unknown,
): NormalizedEvent[] {
  if (!isCatalogSourceId(sourceId) || !isPlainRecord(message)) return [];
  const collection = message as CatalogGeoJSONCollection;
  if (collection.type !== "FeatureCollection" || !Array.isArray(collection.features)) {
    return [];
  }
  const events: NormalizedEvent[] = [];
  for (const feature of collection.features) {
    const event = normalizeCatalogFeature(sourceId, feature as CatalogGeoJSONFeature);
    if (event === null) continue;
    events.push(event);
    if (events.length >= MAX_CATALOG_EVENTS) break;
  }
  return events;
}
