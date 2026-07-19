import "./db.js"; // ensure schema exists before anything else touches it
import { config } from "./config.js";
import { createLogger } from "./logger.js";
import { createServer } from "./api/server.js";
import { attachLiveSocket } from "./api/liveSocket.js";
import { startWolfxManager, stopWolfxManager } from "./wolfx/manager.js";

const log = createLogger("main");

async function main(): Promise<void> {
  const app = createServer();
  const server = app.listen(config.port, () => {
    log.info(`HTTP API listening on :${config.port}`);
  });
  attachLiveSocket(server);

  await startWolfxManager();

  const shutdown = (signal: string) => {
    log.info(`${signal} received, shutting down`);
    stopWolfxManager();
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 5000).unref();
  };
  process.on("SIGINT", () => shutdown("SIGINT"));
  process.on("SIGTERM", () => shutdown("SIGTERM"));
}

main().catch((err) => {
  log.error("fatal startup error", err);
  process.exit(1);
});
