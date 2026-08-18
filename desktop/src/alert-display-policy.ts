import type { NormalizedEvent } from "./types";

export const MAX_ACTIVE_WARNING_AGE_MS = 10 * 60 * 1000;
export const MAX_RECENT_EVENT_AGE_MS = 30 * 60 * 1000;
export const MAX_FUTURE_CLOCK_SKEW_MS = 60 * 1000;

function eventAgeMs(event: NormalizedEvent, nowMs: number): number | null {
  const timestamp = event.reportTimeUtc ?? event.originTimeUtc;
  if (!timestamp) return null;
  const eventTimeMs = Date.parse(timestamp);
  return Number.isFinite(eventTimeMs) ? nowMs - eventTimeMs : null;
}

/**
 * The desktop status banner is safety-facing UI, so it must use the same
 * terminal-state gates as notification delivery and must not leave an old EEW
 * painted as an active warning indefinitely.
 */
export function isFreshActiveWarningForDisplay(
  event: NormalizedEvent,
  nowMs = Date.now(),
): boolean {
  if (
    event.kind !== "eew" ||
    !event.isWarn ||
    event.isFinal ||
    event.isCancel ||
    event.isTraining
  ) {
    return false;
  }

  const ageMs = eventAgeMs(event, nowMs);
  if (ageMs == null) return false;
  return ageMs >= -MAX_FUTURE_CLOCK_SKEW_MS && ageMs <= MAX_ACTIVE_WARNING_AGE_MS;
}

export function isRecentEventForDisplay(event: NormalizedEvent, nowMs = Date.now()): boolean {
  if (event.isTraining || event.isCancel) return false;
  const ageMs = eventAgeMs(event, nowMs);
  return (
    ageMs != null &&
    ageMs >= -MAX_FUTURE_CLOCK_SKEW_MS &&
    ageMs <= MAX_RECENT_EVENT_AGE_MS
  );
}
