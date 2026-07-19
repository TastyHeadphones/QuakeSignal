import { upsertEvent } from "../db.js";
import { createLogger } from "../logger.js";
import type { NormalizedEvent, NotifyReason } from "../types/domain.js";
import { dispatchPush } from "../push/dispatch.js";
import { broadcastEvent } from "../api/liveSocket.js";

const log = createLogger("pipeline");

function determineReason(event: NormalizedEvent, previous: NormalizedEvent | null): NotifyReason | null {
  if (event.isTraining) {
    // Drill/training broadcasts are announced once, like reports -- there's
    // no "final" or "cancelled" concept for a drill.
    return previous === null ? "training" : null;
  }

  if (event.kind === "report") {
    // Report-kind sources (the *_eqlist feeds) republish the same physical
    // earthquake as it moves from "automatic" to "reviewed" -- only the first
    // sighting is push-worthy, the refinement is a silent DB update.
    return previous === null ? "report" : null;
  }

  if (event.isCancel) return previous?.isCancel ? null : "cancelled";
  if (previous === null) return "new";
  if (event.isFinal && !previous.isFinal) return "final";
  if (event.serial > previous.serial) return "updated";
  return null;
}

/**
 * Single entry point for every normalized Wolfx message, whether it came from
 * the one-shot HTTP seed on startup or a live WebSocket push. `isBackfill`
 * suppresses notifications so a fresh server boot doesn't replay history as
 * if it were new alerts.
 */
export function ingestEvent(event: NormalizedEvent, isBackfill: boolean): void {
  const { previous } = upsertEvent(event);

  if (isBackfill) return;

  const reason = determineReason(event, previous);
  if (!reason) return;

  log.info(`${reason}: ${event.id} (M${event.magnitude ?? "?"})`);
  broadcastEvent(event, reason);
  dispatchPush(event, reason).catch((err) => log.error("push dispatch failed", err));
}
