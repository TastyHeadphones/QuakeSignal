import express from "express";
import cors from "cors";
import { devicesRouter } from "./routes/devices.js";
import { quakesRouter } from "./routes/quakes.js";
import { healthRouter } from "./routes/health.js";
import { createLogger } from "../logger.js";

const log = createLogger("http");

export function createServer() {
  const app = express();
  app.use(cors());
  app.use(express.json());

  app.use((req, _res, next) => {
    log.debug(`${req.method} ${req.path}`);
    next();
  });

  app.use("/v1/devices", devicesRouter);
  app.use("/v1/quakes", quakesRouter);
  app.use("/healthz", healthRouter);

  app.use((_req, res) => res.status(404).json({ error: "not found" }));

  return app;
}
