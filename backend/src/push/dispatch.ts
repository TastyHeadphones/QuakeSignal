import { getApnsProvider } from "./apns.js";
import { buildNotification } from "./payload.js";
import { deleteDevice, listDevicesForSource } from "../db.js";
import { createLogger } from "../logger.js";
import type { DeviceRecord, NormalizedEvent, NotifyReason } from "../types/domain.js";

const log = createLogger("dispatch");

/** Fan out a push to every device subscribed to this event's source and passing its magnitude threshold. */
export async function dispatchPush(event: NormalizedEvent, reason: NotifyReason): Promise<void> {
  const provider = getApnsProvider();
  if (!provider) {
    log.warn("APNs not configured (set APNS_* env vars); event stored but no push sent");
    return;
  }

  const devices = listDevicesForSource(event.sourceId, {
    magnitude: event.magnitude,
    latitude: event.latitude,
    longitude: event.longitude,
    isTraining: event.isTraining,
    isRoutineReport: reason === "report",
  });
  if (devices.length === 0) return;

  for (const device of devices) {
    const notification = buildNotification(event, reason);
    const result = await provider.send(notification, device.token);
    for (const failure of result.failed) {
      const why = failure.response?.reason ?? failure.error?.message ?? "unknown";
      log.warn(`push failed for ${failure.device}: ${why}`);
      if (failure.response?.reason === "BadDeviceToken" || failure.response?.reason === "Unregistered") {
        deleteDevice(failure.device);
      }
    }
  }
  log.info(`dispatched "${reason}" push for ${event.id} to ${devices.length} device(s)`);
}

/** Send to exactly one device, bypassing subscription/threshold filtering -- used by the Settings "send test alert" button. */
export async function sendDirectPush(event: NormalizedEvent, reason: NotifyReason, device: DeviceRecord): Promise<void> {
  const provider = getApnsProvider();
  if (!provider) {
    throw new Error("APNs is not configured on the server (set APNS_* env vars)");
  }

  const notification = buildNotification(event, reason);
  const result = await provider.send(notification, device.token);
  if (result.failed.length > 0) {
    const failure = result.failed[0];
    throw new Error(`APNs rejected the token: ${failure.response?.reason ?? failure.error?.message ?? "unknown"}`);
  }
}
