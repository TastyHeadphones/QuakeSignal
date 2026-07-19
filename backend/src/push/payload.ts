import apn from "@parse/node-apn";
import type { NormalizedEvent, NotifyReason } from "../types/domain.js";
import { config } from "../config.js";

const SOURCE_LABEL: Record<string, string> = {
  jma_eew: "JMA",
  sc_eew: "Sichuan EQA",
  cenc_eew: "CENC",
  fj_eew: "Fujian EQA",
  cq_eew: "Chongqing EQA",
  cenc_eqlist: "CENC",
  jma_eqlist: "JMA",
};

/**
 * loc-key pairs. The actual strings live in the iOS app's Localizable.strings
 * (en / ja / zh-Hans) -- APNs only ships the key + args, and iOS resolves the
 * localized text on-device from the user's own language setting.
 */
const LOC_KEYS: Record<NotifyReason, { title: string; body: string }> = {
  new: { title: "eew.push.new.title", body: "eew.push.new.body" },
  updated: { title: "eew.push.updated.title", body: "eew.push.updated.body" },
  final: { title: "eew.push.final.title", body: "eew.push.final.body" },
  cancelled: { title: "eew.push.cancelled.title", body: "eew.push.cancelled.body" },
  report: { title: "quake.push.report.title", body: "quake.push.report.body" },
  training: { title: "eew.push.training.title", body: "eew.push.training.body" },
};

function fmtMagnitude(n: number | null): string {
  return n === null ? "--" : n.toFixed(1);
}

function buildRawPayload(event: NormalizedEvent, reason: NotifyReason, useCritical: boolean) {
  const keys = LOC_KEYS[reason];
  const sourceLabel = SOURCE_LABEL[event.sourceId] ?? event.sourceId;
  const isSevere = reason !== "cancelled" && reason !== "training" && (event.magnitude ?? 0) >= 5.5;

  const aps = {
    alert: {
      "title-loc-key": keys.title,
      "title-loc-args": [sourceLabel],
      "loc-key": keys.body,
      "loc-args": [event.hypocenter || sourceLabel, fmtMagnitude(event.magnitude), event.maxIntensity ?? "--"],
    },
    sound:
      useCritical && isSevere
        ? { critical: 1, name: "default", volume: 1.0 }
        : "default",
    "interruption-level": reason === "training" ? "active" : useCritical && isSevere ? "critical" : "time-sensitive",
    "relevance-score": reason === "cancelled" || reason === "training" ? 0.3 : 1.0,
    category: reason === "training" ? "EEW_TRAINING" : "EEW_ALERT",
  };

  return {
    aps,
    eventId: event.eventId,
    sourceId: event.sourceId,
    kind: event.kind,
    reason,
    magnitude: event.magnitude,
    maxIntensity: event.maxIntensity,
    latitude: event.latitude,
    longitude: event.longitude,
    originTimeUtc: event.originTimeUtc,
  };
}

/**
 * `useCritical` should only be true when the device both opted in (Settings
 * toggle) AND the app holds the com.apple.developer.usernotifications.critical-alerts
 * entitlement -- Apple grants that per-app on request. Falls back to
 * time-sensitive (no special entitlement needed) otherwise.
 */
export function buildNotification(event: NormalizedEvent, reason: NotifyReason, useCritical: boolean): apn.Notification {
  const note = new apn.Notification();
  note.topic = config.apns.bundleId;
  note.priority = 10;
  note.pushType = "alert";
  note.rawPayload = buildRawPayload(event, reason, useCritical);
  return note;
}
