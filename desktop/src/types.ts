// Mirrors src-tauri/src/domain.rs's NormalizedEvent / NotifyReason exactly
// (serde(rename_all = "camelCase") on the Rust side).

export type EventKind = "eew" | "report";

export type NotifyReason =
  | "new"
  | "updated"
  | "final"
  | "cancelled"
  | "report"
  | "training";

export interface NormalizedEvent {
  id: string;
  sourceId: string;
  eventId: string;
  serial: number;
  kind: EventKind;
  originTimeUtc: string | null;
  reportTimeUtc: string | null;
  hypocenter: string;
  latitude: number | null;
  longitude: number | null;
  magnitude: number | null;
  depth: number | null;
  maxIntensity: string | null;
  isWarn: boolean;
  isFinal: boolean;
  isCancel: boolean;
  isTraining: boolean;
  tsunami: string | null;
  raw: unknown;
}

// Mirrors src-tauri/src/settings.rs's Settings struct.
export interface Settings {
  language: string; // "system" | "en" | "ja" | "zh-Hans"
  sources: string[];
  minMagnitude: number;
  locationLabel: string | null;
  latitude: number | null;
  longitude: number | null;
  radiusKm: number | null;
  includeTestAlerts: boolean;
  notifyAtNight: boolean;
  alarmEnabled: boolean;
  alarmVolume: number;
  launchAtLogin: boolean;
}

export const EEW_SOURCE_IDS = ["jma_eew", "sc_eew", "cenc_eew", "fj_eew", "cq_eew"] as const;
export const REPORT_SOURCE_IDS = ["cenc_eqlist", "jma_eqlist"] as const;
export const ALL_SOURCE_IDS = [...EEW_SOURCE_IDS, ...REPORT_SOURCE_IDS];

export interface QuakeEventPayload {
  event: NormalizedEvent;
  reason: NotifyReason;
}

export interface PendingAlert {
  event: NormalizedEvent;
  reason: NotifyReason;
  lang: string;
}
