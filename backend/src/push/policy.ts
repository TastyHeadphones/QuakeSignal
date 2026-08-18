import {
  ALERT_SOUND_IDS,
  type AlertSound,
  type NormalizedEvent,
  type NotifyReason,
} from "../types/domain.js";

export const DEFAULT_ALERT_SOUND: AlertSound = "system";
export const URGENT_EEW_DELIVERY_TTL_MS = 10 * 60_000;
export const APNS_REGULAR_PAYLOAD_LIMIT_BYTES = 4_096;

const MAX_SOURCE_FUTURE_SKEW_MS = 60_000;
const MAX_EVENT_ID_BYTES = 256;
const MAX_HYPOCENTER_BYTES = 384;
const MAX_SHORT_TEXT_BYTES = 96;

const SOURCE_LABEL: Record<string, string> = {
  jma_eew: "JMA",
  sc_eew: "Sichuan EQA",
  cenc_eew: "CENC",
  fj_eew: "Fujian EQA",
  cq_eew: "Chongqing EQA",
  cenc_eqlist: "CENC",
  jma_eqlist: "JMA",
};

const LOC_KEYS: Record<NotifyReason, { title: string; body: string }> = {
  new: { title: "eew.push.new.title", body: "eew.push.new.body" },
  updated: { title: "eew.push.updated.title", body: "eew.push.updated.body" },
  final: { title: "eew.push.final.title", body: "eew.push.final.body" },
  cancelled: {
    title: "eew.push.cancelled.title",
    body: "eew.push.cancelled.body",
  },
  report: { title: "quake.push.report.title", body: "quake.push.report.body" },
  training: {
    title: "eew.push.training.title",
    body: "eew.push.training.body",
  },
};

const CUSTOM_ALERT_SOUND_FILES: Record<Exclude<AlertSound, "system">, string> = {
  "urgent-tone": "quakesignal_urgent.caf",
  "japanese-voice": "quakesignal_japanese_voice.caf",
};

export interface PushEventSnapshot {
  sourceId: NormalizedEvent["sourceId"];
  eventId: string;
  serial: number;
  kind: NormalizedEvent["kind"];
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
}

export interface QuakeSignalPushPayload {
  aps: {
    alert: {
      "title-loc-key": string;
      "title-loc-args": string[];
      "loc-key": string;
      "loc-args": string[];
    };
    sound: string;
    "interruption-level": "active" | "time-sensitive";
    "relevance-score": number;
    category: "EEW_ALERT" | "EEW_TRAINING";
  };
  /** Typed snapshot used when a notification opens after the live feed moved on. */
  event: PushEventSnapshot;
  // Retained for clients released before the typed snapshot was introduced.
  eventId: string;
  sourceId: NormalizedEvent["sourceId"];
  kind: NormalizedEvent["kind"];
  reason: NotifyReason;
  magnitude: number | null;
  maxIntensity: string | null;
  latitude: number | null;
  longitude: number | null;
  originTimeUtc: string | null;
}

export function isAlertSound(value: unknown): value is AlertSound {
  return (
    typeof value === "string" &&
    (ALERT_SOUND_IDS as readonly string[]).includes(value)
  );
}

export function normalizedAlertSound(value: unknown): AlertSound {
  return isAlertSound(value) ? value : DEFAULT_ALERT_SOUND;
}

export function isGenuineActiveEewWarning(
  event: Pick<
    NormalizedEvent,
    "kind" | "isWarn" | "isFinal" | "isCancel" | "isTraining"
  >,
): boolean {
  return (
    event.kind === "eew" &&
    event.isWarn &&
    !event.isFinal &&
    !event.isCancel &&
    !event.isTraining
  );
}

function eventTimestampMs(
  event: Pick<NormalizedEvent, "reportTimeUtc" | "originTimeUtc">,
): number | null {
  for (const timestamp of [event.reportTimeUtc, event.originTimeUtc]) {
    if (timestamp === null) continue;
    const parsed = Date.parse(timestamp);
    if (Number.isFinite(parsed)) return parsed;
  }
  return null;
}

export function isFreshGenuineActiveEewWarning(
  event: Pick<
    NormalizedEvent,
    | "kind"
    | "reportTimeUtc"
    | "originTimeUtc"
    | "isWarn"
    | "isFinal"
    | "isCancel"
    | "isTraining"
  >,
  nowMs = Date.now(),
): boolean {
  if (!isGenuineActiveEewWarning(event)) return false;
  const timestampMs = eventTimestampMs(event);
  if (timestampMs === null) return false;
  const ageMs = nowMs - timestampMs;
  return ageMs >= -MAX_SOURCE_FUTURE_SKEW_MS && ageMs <= URGENT_EEW_DELIVERY_TTL_MS;
}

/**
 * Reconcile one source snapshot against the committed event lifecycle.
 *
 * Serial is the primary ordering key. A same-serial payload may still promote
 * an informational frame into a warning or advance it to final/cancelled, but
 * it cannot erase a terminal state. A higher serial may improve ordinary event
 * fields after a terminal frame; the terminal flags remain monotonic so that
 * downstream presentation and delivery code cannot treat it as a new warning.
 */
export function reconcileEventRevision(
  event: NormalizedEvent,
  previous: NormalizedEvent | null,
): NormalizedEvent | null {
  if (previous === null || previous.id !== event.id) return event;
  if (event.serial < previous.serial) return null;

  if (event.serial === previous.serial) {
    if (previous.isCancel && !event.isCancel) return null;
    if (previous.isFinal && !event.isFinal && !event.isCancel) return null;
  }

  return {
    ...event,
    // Warning promotion can arrive without a serial increment. Do not let a
    // same-serial informational replay erase that safety escalation.
    isWarn:
      event.serial === previous.serial
        ? previous.isWarn || event.isWarn
        : event.isWarn,
    isFinal: previous.isFinal || event.isFinal,
    isCancel: previous.isCancel || event.isCancel,
  };
}

/**
 * Classify only notification-worthy transitions. Informational EEW frames are
 * stored and broadcast, but cannot become an urgent notification merely by
 * being the first frame observed for an event.
 */
export function notificationReasonForEvent(
  event: NormalizedEvent,
  previous: NormalizedEvent | null,
): NotifyReason | null {
  const reconciled = reconcileEventRevision(event, previous);
  if (reconciled === null) return null;
  event = reconciled;

  if (event.isTraining) return previous === null ? "training" : null;
  if (event.kind === "report") return previous === null ? "report" : null;

  const previousBelongedToWarning =
    previous !== null &&
    previous.kind === "eew" &&
    previous.isWarn &&
    !previous.isTraining;
  if (event.isCancel) {
    return previousBelongedToWarning && !previous.isCancel ? "cancelled" : null;
  }
  if (event.isFinal) {
    return previousBelongedToWarning && !previous.isFinal && !previous.isCancel
      ? "final"
      : null;
  }
  if (!isGenuineActiveEewWarning(event)) return null;
  if (previous === null || !isGenuineActiveEewWarning(previous)) return "new";
  return event.serial > previous.serial ? "updated" : null;
}

function truncateUtf8(value: string, maximumBytes: number): string {
  const encoder = new TextEncoder();
  if (encoder.encode(value).byteLength <= maximumBytes) return value;
  let result = "";
  let usedBytes = 0;
  for (const character of value) {
    const characterBytes = encoder.encode(character).byteLength;
    if (usedBytes + characterBytes > maximumBytes) break;
    result += character;
    usedBytes += characterBytes;
  }
  return result;
}

function boundedOptionalText(value: string | null, maximumBytes: number): string | null {
  return value === null ? null : truncateUtf8(value, maximumBytes);
}

export function pushEventSnapshot(event: NormalizedEvent): PushEventSnapshot {
  return {
    sourceId: event.sourceId,
    eventId: truncateUtf8(event.eventId, MAX_EVENT_ID_BYTES),
    serial: event.serial,
    kind: event.kind,
    originTimeUtc: boundedOptionalText(event.originTimeUtc, MAX_SHORT_TEXT_BYTES),
    reportTimeUtc: boundedOptionalText(event.reportTimeUtc, MAX_SHORT_TEXT_BYTES),
    hypocenter: truncateUtf8(event.hypocenter, MAX_HYPOCENTER_BYTES),
    latitude: event.latitude,
    longitude: event.longitude,
    magnitude: event.magnitude,
    depth: event.depth,
    maxIntensity: boundedOptionalText(event.maxIntensity, MAX_SHORT_TEXT_BYTES),
    isWarn: event.isWarn,
    isFinal: event.isFinal,
    isCancel: event.isCancel,
    isTraining: event.isTraining,
    tsunami: boundedOptionalText(event.tsunami, MAX_SHORT_TEXT_BYTES),
  };
}

function selectedSoundFile(alertSound: AlertSound, urgent: boolean): string {
  if (!urgent || alertSound === "system") return "default";
  return CUSTOM_ALERT_SOUND_FILES[alertSound];
}

export function pushPayloadSizeBytes(payload: QuakeSignalPushPayload): number {
  return new TextEncoder().encode(JSON.stringify(payload)).byteLength;
}

export function buildPushPayload(
  event: NormalizedEvent,
  reason: NotifyReason,
  alertSound: AlertSound = DEFAULT_ALERT_SOUND,
  nowMs = Date.now(),
): QuakeSignalPushPayload {
  const keys = LOC_KEYS[reason];
  const sourceLabel = SOURCE_LABEL[event.sourceId] ?? event.sourceId;
  const snapshot = pushEventSnapshot(event);
  const urgent =
    (reason === "new" || reason === "updated") &&
    isFreshGenuineActiveEewWarning(snapshot, nowMs);
  const payload: QuakeSignalPushPayload = {
    aps: {
      alert: {
        "title-loc-key": keys.title,
        "title-loc-args": [sourceLabel],
        "loc-key": keys.body,
        "loc-args": [
          snapshot.hypocenter || sourceLabel,
          snapshot.magnitude?.toFixed(1) ?? "--",
          snapshot.maxIntensity ?? "--",
        ],
      },
      // Critical Alerts are not enabled. Only a fresh, genuine active warning
      // gets Time Sensitive interruption and the user's bundled custom sound.
      sound: selectedSoundFile(alertSound, urgent),
      "interruption-level": urgent ? "time-sensitive" : "active",
      "relevance-score": urgent ? 1 : 0.3,
      category: reason === "training" ? "EEW_TRAINING" : "EEW_ALERT",
    },
    event: snapshot,
    eventId: snapshot.eventId,
    sourceId: snapshot.sourceId,
    kind: snapshot.kind,
    reason,
    magnitude: snapshot.magnitude,
    maxIntensity: snapshot.maxIntensity,
    latitude: snapshot.latitude,
    longitude: snapshot.longitude,
    originTimeUtc: snapshot.originTimeUtc,
  };
  const byteLength = pushPayloadSizeBytes(payload);
  if (byteLength > APNS_REGULAR_PAYLOAD_LIMIT_BYTES) {
    throw new RangeError(`APNs payload is ${byteLength} bytes; maximum is 4096`);
  }
  return payload;
}
