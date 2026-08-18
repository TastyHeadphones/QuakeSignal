import apn from "@parse/node-apn";
import type {
  AlertSound,
  NormalizedEvent,
  NotifyReason,
} from "../types/domain.js";
import { config } from "../config.js";
import { buildPushPayload } from "./policy.js";

export { buildPushPayload } from "./policy.js";

export function buildNotification(
  event: NormalizedEvent,
  reason: NotifyReason,
  alertSound: AlertSound,
): apn.Notification {
  const note = new apn.Notification();
  note.topic = config.apns.bundleId;
  note.priority = 10;
  note.expiry = 0;
  note.pushType = "alert";
  note.rawPayload = buildPushPayload(event, reason, alertSound);
  return note;
}
