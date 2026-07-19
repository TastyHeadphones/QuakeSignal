import { Router } from "express";
import { deleteDevice, getDevice, upsertDevice } from "../../db.js";
import { ALL_WOLFX_SOURCES, type WolfxSourceId } from "../../types/wolfx.js";
import type { DeviceEnvironment, NormalizedEvent } from "../../types/domain.js";
import { sendDirectPush } from "../../push/dispatch.js";
import { createLogger } from "../../logger.js";

const log = createLogger("api:devices");
export const devicesRouter = Router();

function isValidSources(value: unknown): value is WolfxSourceId[] {
  return Array.isArray(value) && value.every((v) => (ALL_WOLFX_SOURCES as string[]).includes(v));
}

devicesRouter.post("/", (req, res) => {
  const {
    token,
    environment,
    locale,
    sources,
    minMagnitude,
    criticalAlertsEnabled,
    cityName,
    latitude,
    longitude,
    radiusKm,
    includeTestAlerts,
    utcOffsetMinutes,
    notifyAtNight,
  } = req.body ?? {};

  if (typeof token !== "string" || token.length < 10) {
    return res.status(400).json({ error: "token is required" });
  }

  const validSources = isValidSources(sources) ? sources : ALL_WOLFX_SOURCES;
  const env: DeviceEnvironment = environment === "sandbox" ? "sandbox" : "production";

  const device = upsertDevice({
    token,
    environment: env,
    locale: typeof locale === "string" ? locale : null,
    sources: validSources,
    minMagnitude: typeof minMagnitude === "number" ? minMagnitude : 0,
    criticalAlertsEnabled: !!criticalAlertsEnabled,
    cityName: typeof cityName === "string" ? cityName : null,
    latitude: typeof latitude === "number" ? latitude : null,
    longitude: typeof longitude === "number" ? longitude : null,
    radiusKm: typeof radiusKm === "number" ? radiusKm : null,
    includeTestAlerts: !!includeTestAlerts,
    utcOffsetMinutes: typeof utcOffsetMinutes === "number" ? utcOffsetMinutes : null,
    notifyAtNight: notifyAtNight === undefined ? true : !!notifyAtNight,
  });

  log.info(`registered device ${token.slice(0, 8)}... sources=${validSources.join(",")} city=${device.cityName ?? "-"}`);
  res.status(201).json(device);
});

devicesRouter.delete("/:token", (req, res) => {
  deleteDevice(req.params.token);
  res.status(204).end();
});

/** Exercises the full push pipeline for one device -- backs the Settings "send test alert" button. */
devicesRouter.post("/:token/test", async (req, res) => {
  const device = getDevice(req.params.token);
  if (!device) return res.status(404).json({ error: "device not found" });

  const now = new Date().toISOString();
  const testEvent: NormalizedEvent = {
    id: "test:0",
    sourceId: device.sources[0] ?? "jma_eew",
    eventId: "TEST-EVENT",
    serial: 1,
    kind: "eew",
    originTimeUtc: now,
    reportTimeUtc: now,
    hypocenter: "Test Region",
    latitude: 35.0,
    longitude: 135.0,
    magnitude: 5.5,
    depth: 10,
    maxIntensity: "5-",
    isWarn: true,
    isFinal: false,
    isCancel: false,
    isTraining: false,
    tsunami: null,
    raw: null,
  };

  try {
    await sendDirectPush(testEvent, "new", device);
    res.json({ ok: true });
  } catch (err) {
    res.status(502).json({ error: (err as Error).message });
  }
});
