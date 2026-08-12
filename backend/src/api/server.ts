import express from "express";
import { devicesRouter } from "./routes/devices.js";
import { quakesRouter } from "./routes/quakes.js";
import { healthRouter } from "./routes/health.js";
import { createLogger } from "../logger.js";

const log = createLogger("http");

export function createServer() {
  const app = express();
  // This server is a local/development implementation. The public release
  // uses the Cloudflare Worker, whose native-client API intentionally has no
  // browser CORS surface.
  app.use(express.json({ limit: "8kb", strict: true }));

  app.use((req, _res, next) => {
    log.debug(`${req.method} ${req.path}`);
    next();
  });

  app.use("/v1/devices", devicesRouter);
  app.use("/v1/quakes", quakesRouter);
  app.use("/healthz", healthRouter);

  app.use((_req, res) => res.status(404).json({ error: "not found" }));

  app.use((error: unknown, _req: express.Request, res: express.Response, _next: express.NextFunction) => {
    const details = error as { type?: string; status?: number };
    if (details.type === "entity.too.large" || details.status === 413) {
      return res.status(413).json({ error: "request body too large" });
    }
    if (details.type === "entity.parse.failed" || details.status === 400) {
      return res.status(400).json({ error: "invalid JSON" });
    }
    log.error("request processing failed");
    return res.status(500).json({ error: "request processing failed" });
  });

  return app;
}
