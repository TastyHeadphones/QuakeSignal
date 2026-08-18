import { upsertEvent } from "../db.js";
import { createLogger } from "../logger.js";
import type { NormalizedEvent } from "../types/domain.js";
import { dispatchPush } from "../push/dispatch.js";
import { broadcastEvent } from "../api/liveSocket.js";
import { notificationReasonForEvent } from "../push/policy.js";

const log = createLogger("pipeline");

/**
 * Single entry point for every normalized Wolfx message, whether it came from
 * the one-shot HTTP seed on startup or a live WebSocket push. `isBackfill`
 * suppresses notifications so a fresh server boot doesn't replay history as
 * if it were new alerts.
 */
export function ingestEvent(event: NormalizedEvent, isBackfill: boolean): void {
  const { previous, acceptedEvent } = upsertEvent(event);
  if (acceptedEvent === null) return;

  if (isBackfill) return;

  const reason = notificationReasonForEvent(acceptedEvent, previous);
  if (!reason) return;

  log.info(`${reason}: ${acceptedEvent.id} (M${acceptedEvent.magnitude ?? "?"})`);
  broadcastEvent(acceptedEvent, reason);
  dispatchPush(acceptedEvent, reason).catch((err) => log.error("push dispatch failed", err));
}
