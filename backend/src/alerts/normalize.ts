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
