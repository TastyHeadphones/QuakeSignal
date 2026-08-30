import type { EarthquakeSourceId } from "./wolfx.js";

export type EventKind = "eew" | "report";

/**
 * Unified shape every Wolfx source gets normalized into, so the rest of the
 * backend (dedupe, storage, push dispatch, REST API) never has to branch on
 * which upstream agency a payload came from.
 */
export interface NormalizedEvent {
  /** Stable key: `${sourceId}:${eventId}`. */
  id: string;
  sourceId: EarthquakeSourceId;
  eventId: string;
  /** EEW `Serial`/`ReportNum`, or the eqlist rank ("No<n>") for report-kind events. */
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
  /** JMA-only flag for drill/training broadcasts -- excluded from push by default (see DeviceRecord.includeTestAlerts). */
  isTraining: boolean;
  tsunami: string | null;
  raw: unknown;
}

export type DeviceEnvironment = "sandbox" | "production";

/** Exact wire/storage identifiers accepted for an alert sound preference. */
export const ALERT_SOUND_IDS = [
  "system",
  "urgent-tone",
  "japanese-voice",
] as const;

export type AlertSound = (typeof ALERT_SOUND_IDS)[number];

export interface DeviceRecord {
  token: string;
  environment: DeviceEnvironment;
  /** BCP-47 tag reported by the app, e.g. "ja", "zh-Hans", "en". Informational only --
   *  push text localization relies on APNs loc-key, not this field. */
  locale: string | null;
  sources: EarthquakeSourceId[];
  minMagnitude: number;
  criticalAlertsEnabled: boolean;
  /** Bundled notification sound selected for fresh active EEW warnings. */
  alertSound: AlertSound;
  /** Subscribed city, e.g. "成都市" -- display label; latitude/longitude/radiusKm are what actually drive filtering. */
  cityName: string | null;
  latitude: number | null;
  longitude: number | null;
  /** Only push events within this radius of (latitude, longitude). Null is retained for legacy rows but fails closed for automatic delivery. */
  radiusKm: number | null;
  /** Whether to push JMA drill/training broadcasts. Defaults to false so a training message never reads as a real warning. */
  includeTestAlerts: boolean;
  /** Minutes east of UTC (e.g. JST = 540), used only for the notifyAtNight quiet-hours check below. Null = quiet hours not enforced. */
  utcOffsetMinutes: number | null;
  /**
   * If false, suppress push for reason "report" (routine informational
   * quake reports) between 22:00-07:00 device-local time. Never applies to
   * fresh "new"/"updated" active EEW warnings. Final/cancel lifecycle notices
   * also bypass this preference so a warning is not left visibly active.
   */
  notifyAtNight: boolean;
  createdAt: string;
  updatedAt: string;
}

export type DeviceRegistrationInput = Omit<DeviceRecord, "createdAt" | "updatedAt">;

/** Why a NormalizedEvent is being (re-)pushed, drives which loc-key pair gets used. */
export type NotifyReason = "new" | "updated" | "final" | "cancelled" | "report" | "training";

/** One snapshot of a NormalizedEvent at a point in time -- powers the Detail screen's report-revision timeline. */
export interface EventRevision {
  eventRef: string;
  serial: number;
  magnitude: number | null;
  maxIntensity: string | null;
  isWarn: boolean;
  isFinal: boolean;
  isCancel: boolean;
  reportTimeUtc: string | null;
  recordedAtUtc: string;
}
