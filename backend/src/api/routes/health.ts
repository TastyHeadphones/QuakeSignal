import { Router } from "express";
import { getConnectionStatuses } from "../../wolfx/manager.js";
import { isApnsConfigured } from "../../config.js";

export const healthRouter = Router();

healthRouter.get("/", (_req, res) => {
  res.json({
    ok: true,
    apnsConfigured: isApnsConfigured,
    sources: getConnectionStatuses(),
    time: new Date().toISOString(),
  });
});
