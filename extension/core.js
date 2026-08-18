export const SOURCE_IDS = [
  "jma_eew",
  "sc_eew",
  "cenc_eew",
  "fj_eew",
  "cq_eew",
  "cenc_eqlist",
  "jma_eqlist",
];

export const DEFAULT_SETTINGS = {
  notificationsEnabled: true,
  alarmEnabled: true,
  alarmVolume: 0.8,
  minMagnitude: 4.5,
  includeTestAlerts: false,
  sources: [...SOURCE_IDS],
};

function parseLocalDateTime(raw, offsetHours) {
  if (!raw) return null;
  const match = /(\d{4})[/-](\d{2})[/-](\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?/.exec(raw);
  if (!match) return null;
  const [, year, month, day, hour, minute, second = "0"] = match;
  const utc = Date.UTC(+year, +month - 1, +day, +hour, +minute, +second) - offsetHours * 3_600_000;
  return new Date(utc).toISOString();
}

function toNumber(value) {
  if (value === null || value === undefined || value === "") return null;
  const number = typeof value === "string" ? Number(value.replace(/[^\d.+-]/g, "")) : Number(value);
  return Number.isFinite(number) ? number : null;
}

function baseEvent(sourceId, message) {
  const chinaFeed = sourceId !== "jma_eew";
  const eventId = String(message.EventID ?? message.ID ?? "");
  return {
    id: `${sourceId}:${eventId}`,
    sourceId,
    eventId,
    serial: Number(message.Serial ?? message.ReportNum ?? 1),
    kind: "eew",
    originTimeUtc: parseLocalDateTime(message.OriginTime, chinaFeed ? 8 : 9),
    reportTimeUtc: parseLocalDateTime(message.AnnouncedTime ?? message.ReportTime, chinaFeed ? 8 : 9),
    hypocenter: String(message.Hypocenter ?? message.HypoCenter ?? "Unknown"),
    latitude: toNumber(message.Latitude),
    longitude: toNumber(message.Longitude),
    magnitude: toNumber(message.Magunitude ?? message.Magnitude),
    depth: toNumber(message.Depth),
    maxIntensity: message.MaxIntensity == null ? null : String(message.MaxIntensity),
    isWarn: sourceId === "jma_eew" ? Boolean(message.isWarn) : true,
    isFinal: Boolean(message.isFinal),
    isCancel: Boolean(message.isCancel),
    isTraining: Boolean(message.isTraining),
    tsunami: null,
  };
}

function reportEvent(sourceId, entry) {
  const isJma = sourceId === "jma_eqlist";
  const eventId = String(entry.EventID ?? "");
  const rawTime = isJma ? entry.time_full || entry.time : entry.ReportTime || entry.time;
  return {
    id: `${sourceId}:${eventId}`,
    sourceId,
    eventId,
    serial: sourceId === "cenc_eqlist" && entry.type === "reviewed" ? 2 : 1,
    kind: "report",
    originTimeUtc: parseLocalDateTime(entry.time_full || entry.time, isJma ? 9 : 8),
    reportTimeUtc: parseLocalDateTime(rawTime, isJma ? 9 : 8),
    hypocenter: String(entry.placeName || entry.location || "Unknown"),
    latitude: toNumber(entry.latitude),
    longitude: toNumber(entry.longitude),
    magnitude: toNumber(entry.magnitude),
    depth: toNumber(entry.depth),
    maxIntensity: entry.shindo || entry.intensity || null,
    isWarn: false,
    isFinal: isJma || entry.type === "reviewed",
    isCancel: false,
    isTraining: false,
    tsunami: entry.info || null,
  };
}

export function normalizeMessage(sourceId, payload) {
  if (!payload || typeof payload !== "object") return [];
  if (sourceId.endsWith("_eqlist")) {
    return Object.entries(payload)
      .filter(([key, value]) => /^No\d+$/.test(key) && value && typeof value === "object")
      .sort(([a], [b]) => Number(a.slice(2)) - Number(b.slice(2)))
      .map(([, entry]) => reportEvent(sourceId, entry))
      .filter((event) => event.eventId);
  }
  if (!payload.EventID) return [];
  return [baseEvent(sourceId, payload)];
}

export function determineReason(event, previous, nowMs = Date.now()) {
  // Terminal states are monotonic. A retained or out-of-order snapshot must
  // never reopen an alert that was already cancelled or finalized.
  if (previous?.isCancel) return null;
  if (event.isTraining) return previous ? null : "training";
  if (event.kind === "report") return previous ? null : "report";
  const previousBelongedToWarning = Boolean(
    previous?.kind === "eew" && previous.isWarn && !previous.isTraining,
  );
  if (event.isCancel) {
    return previousBelongedToWarning && !previous.isCancel ? "cancelled" : null;
  }
  if (event.isFinal) {
    return previousBelongedToWarning && !previous.isFinal ? "final" : null;
  }
  if (previous?.isFinal) return null;
  if (!isActiveWarning(event, nowMs)) return null;
  if (!previous || !isActiveWarning(previous, nowMs)) return "new";
  return event.serial > previous.serial ? "updated" : null;
}

export function passesFilters(event, settings) {
  if (!settings.notificationsEnabled) return false;
  if (!settings.sources.includes(event.sourceId)) return false;
  if (event.isTraining && !settings.includeTestAlerts) return false;
  return (event.magnitude ?? 0) >= settings.minMagnitude;
}

/**
 * Reconciles one event without allowing an out-of-order revision or terminal
 * status to move backwards. A newer payload may still improve the event data,
 * but once final/cancelled those flags remain set.
 */
export function mergeEventRevision(previous, incoming) {
  if (!previous) return incoming;

  const previousSerial = Number.isFinite(Number(previous.serial)) ? Number(previous.serial) : 0;
  const incomingSerial = Number.isFinite(Number(incoming.serial)) ? Number(incoming.serial) : 0;
  if (incomingSerial < previousSerial) return previous;

  return {
    ...incoming,
    serial: Math.max(previousSerial, incomingSerial),
    isWarn: incomingSerial === previousSerial
      ? Boolean(previous.isWarn || incoming.isWarn)
      : Boolean(incoming.isWarn),
    isFinal: Boolean(previous.isFinal || incoming.isFinal),
    isCancel: Boolean(previous.isCancel || incoming.isCancel),
  };
}

export function mergeEvents(existing, incoming, limit = 200) {
  const byId = new Map(existing.map((event) => [event.id, event]));
  for (const event of incoming) {
    byId.set(event.id, mergeEventRevision(byId.get(event.id), event));
  }
  return [...byId.values()]
    .sort((a, b) => Date.parse(b.reportTimeUtc || b.originTimeUtc || 0) - Date.parse(a.reportTimeUtc || a.originTimeUtc || 0))
    .slice(0, limit);
}

export const ACTIVE_WARNING_MAX_AGE_MS = 10 * 60 * 1_000;

export function isActiveWarning(event, nowMs = Date.now()) {
  if (
    event?.kind !== "eew" ||
    !event.isWarn ||
    event.isFinal ||
    event.isCancel ||
    event.isTraining
  ) {
    return false;
  }

  const timestamp = Date.parse(event.reportTimeUtc || event.originTimeUtc || "");
  if (!Number.isFinite(timestamp)) return false;
  const ageMs = nowMs - timestamp;
  return ageMs >= -60_000 && ageMs <= ACTIVE_WARNING_MAX_AGE_MS;
}

export function isUrgentNotification(event, reason, nowMs = Date.now()) {
  return (
    (reason === "new" || reason === "updated") &&
    isActiveWarning(event, nowMs)
  );
}

/**
 * Appends work to a promise tail while ensuring a rejected item cannot poison
 * every item queued after it. The returned promise still reflects this item's
 * result, and an attached rejection observer prevents unhandled rejections.
 */
export function enqueueRecovering(tail, operation, onError = () => {}) {
  const next = Promise.resolve(tail)
    .catch(() => undefined)
    .then(operation);
  void next.catch((error) => {
    try {
      onError(error);
    } catch {
      // Error reporting must not become another unhandled rejection.
    }
  });
  return next;
}

export function routeSource(payload) {
  const source = payload?.type;
  return SOURCE_IDS.includes(source) ? source : null;
}
