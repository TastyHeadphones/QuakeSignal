import type { Server } from "node:http";
import { WebSocket, WebSocketServer } from "ws";
import { createLogger } from "../logger.js";
import type { NormalizedEvent, NotifyReason } from "../types/domain.js";

const log = createLogger("live-ws");
let wss: WebSocketServer | null = null;

/**
 * Lightweight fan-out socket so the foreground app gets sub-second updates
 * without polling and without re-implementing Wolfx parsing on-device --
 * the app's only integration surface is this backend, both for history
 * (REST) and for live deltas (this socket). Same events that trigger a push
 * notification are broadcast here, already normalized.
 */
export function attachLiveSocket(server: Server): void {
  wss = new WebSocketServer({ server, path: "/v1/live" });
  wss.on("connection", (socket) => {
    log.info(`client connected (${wss?.clients.size ?? 0} total)`);
    socket.on("close", () => log.info(`client disconnected (${wss?.clients.size ?? 0} total)`));
    socket.on("error", (err) => log.warn("client socket error", err.message));
  });
}

export function broadcastEvent(event: NormalizedEvent, reason: NotifyReason): void {
  if (!wss) return;
  const payload = JSON.stringify({ type: "quake", reason, event });
  for (const client of wss.clients) {
    if (client.readyState === WebSocket.OPEN) client.send(payload);
  }
}
