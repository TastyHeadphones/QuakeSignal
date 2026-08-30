/**
 * Wire types for the Wolfx Open API (https://wolfx.jp). Field names/casing
 * (including the upstream "Magunitude" typo on jma_eew/sc_eew/fj_eew) are kept
 * verbatim — see docs/WOLFX_API.md for the verified schema this was built from.
 */

import type { CatalogSourceId } from "./catalog.js";

export type WolfxSourceId =
  | "jma_eew"
  | "sc_eew"
  | "cenc_eew"
  | "fj_eew"
  | "cq_eew"
  | "cenc_eqlist"
  | "jma_eqlist"
  | CatalogSourceId;

/** Every earthquake origin the relay and clients may name, including catalogs. */
export type EarthquakeSourceId = WolfxSourceId;

export const ALL_WOLFX_SOURCES: WolfxSourceId[] = [
  "jma_eew",
  "sc_eew",
  "cenc_eew",
  "fj_eew",
  "cq_eew",
  "cenc_eqlist",
  "jma_eqlist",
];

export interface WolfxIssue {
  Source: string;
  Status: string;
}

export interface WolfxAccuracy {
  Epicenter: string;
  Depth: string;
  Magnitude: string;
}

export interface WolfxMaxIntChange {
  String: string;
  Reason: string;
}

export interface WolfxWarnArea {
  Chiiki: string;
  Shindo1: string;
  Shindo2: string;
  Time: string;
  Type: string; // "Forecast" | "Warning"
  Arrive: boolean;
}

export interface JmaEewMessage {
  type?: "jma_eew";
  Title: string;
  CodeType: string;
  Issue: WolfxIssue;
  EventID: string;
  Serial: number;
  AnnouncedTime: string; // JST, "yyyy/MM/dd HH:mm:ss"
  OriginTime: string; // JST, "yyyy/MM/dd HH:mm:ss"
  Hypocenter: string;
  Latitude: number;
  Longitude: number;
  Magunitude: number;
  Depth: number;
  MaxIntensity: string; // JMA shindo scale, e.g. "3", "5-", "5+"
  Accuracy: WolfxAccuracy;
  MaxIntChange: WolfxMaxIntChange;
  WarnArea: WolfxWarnArea[];
  isSea: boolean;
  isTraining: boolean;
  isAssumption: boolean;
  isWarn: boolean;
  isFinal: boolean;
  isCancel: boolean;
  OriginalText: string;
}

/** Sichuan (sc_eew) and Fujian (fj_eew) share this shape; Fujian omits Depth/MaxIntensity. */
export interface ScFjEewMessage {
  type?: "sc_eew" | "fj_eew";
  ID: number;
  EventID: string;
  ReportTime: string; // UTC+8, "yyyy-MM-dd HH:mm:ss"
  ReportNum: number;
  OriginTime: string; // UTC+8
  HypoCenter: string;
  Latitude: number;
  Longitude: number;
  Magunitude: number;
  Depth?: number | null;
  MaxIntensity?: number | null;
  isFinal?: boolean;
}

/** CENC (cenc_eew) and Chongqing (cq_eew) share this shape. */
export interface CencCqEewMessage {
  type?: "cenc_eew" | "cq_eew";
  ID: string;
  EventID: string;
  ReportTime: string; // UTC+8
  ReportNum: number;
  OriginTime: string; // UTC+8
  HypoCenter: string;
  Latitude: number;
  Longitude: number;
  Magnitude: number;
  Depth?: number | null;
  MaxIntensity?: number | null;
}

export type WolfxEewMessage = JmaEewMessage | ScFjEewMessage | CencCqEewMessage;

/** One entry inside a cenc_eqlist "No1".."No50" object. All values are strings on the wire. */
export interface CencEqlistEntry {
  type: "automatic" | "reviewed";
  EventID: string;
  time: string; // UTC+8
  ReportTime: string;
  location: string;
  placeName: string;
  magnitude: string;
  depth: string;
  latitude: string;
  longitude: string;
  intensity: string;
}

/** One entry inside a jma_eqlist "No1".."No50" object. All values are strings on the wire. */
export interface JmaEqlistEntry {
  Title: string;
  EventID: string;
  time: string; // JST, "yyyy/MM/dd HH:mm"
  time_full: string; // JST, "yyyy/MM/dd HH:mm:ss"
  location: string;
  magnitude: string;
  shindo: string;
  depth: string; // e.g. "20km" -- unit baked into the string
  latitude: string;
  longitude: string;
  info: string; // tsunami advisory text, usually only on the newest entry
}

/**
 * cenc_eqlist / jma_eqlist top-level shape is `{ "No1": {...}, "No2": {...}, ...,
 * "md5": "..." }` -- an object keyed by rank, not an array. Use the
 * `extractEqlistEntries` helper in alerts/normalize.ts rather than typing the
 * "No<n>" keys directly (TS template-literal index signatures for this are
 * more trouble than they're worth for a handful of call sites).
 */
export interface WolfxEqlistMessage {
  type?: "cenc_eqlist" | "jma_eqlist";
  md5?: string;
  [key: string]: unknown;
}

export interface WolfxHeartbeatMessage {
  type: "heartbeat";
  ver: string | number;
  id: string;
  timestamp: string;
}

export interface WolfxPongMessage {
  type: "pong";
  timestamp: string;
}

export function isHeartbeat(msg: unknown): msg is WolfxHeartbeatMessage {
  return !!msg && typeof msg === "object" && (msg as { type?: unknown }).type === "heartbeat";
}

export function isPong(msg: unknown): msg is WolfxPongMessage {
  return !!msg && typeof msg === "object" && (msg as { type?: unknown }).type === "pong";
}
