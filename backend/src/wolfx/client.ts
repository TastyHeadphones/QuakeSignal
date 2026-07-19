import WebSocket from "ws";
import { createLogger } from "../logger.js";
import type { WolfxSourceId } from "../types/wolfx.js";

const WS_BASE = "wss://ws-api.wolfx.jp";
const RECONNECT_MIN_MS = 1000;
const RECONNECT_MAX_MS = 30_000;

export type WolfxConnectionStatus = "connecting" | "open" | "closed";

export interface WolfxClientOptions {
  endpoint: WolfxSourceId | "all_eew";
  onMessage: (data: unknown) => void;
  onStatusChange?: (status: WolfxConnectionStatus) => void;
}

/** One persistent, self-reconnecting WebSocket to a single Wolfx endpoint. */
export class WolfxClient {
  private readonly options: WolfxClientOptions;
  private readonly log: ReturnType<typeof createLogger>;
  private ws: WebSocket | null = null;
  private closedByCaller = false;
  private reconnectDelay = RECONNECT_MIN_MS;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;

  constructor(options: WolfxClientOptions) {
    this.options = options;
    this.log = createLogger(`wolfx:${options.endpoint}`);
  }

  start(): void {
    this.closedByCaller = false;
    this.connect();
  }

  stop(): void {
    this.closedByCaller = true;
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.ws?.close();
  }

  private connect(): void {
    const url = `${WS_BASE}/${this.options.endpoint}`;
    this.options.onStatusChange?.("connecting");
    this.log.info(`connecting to ${url}`);

    const socket = new WebSocket(url);
    this.ws = socket;

    socket.on("open", () => {
      this.reconnectDelay = RECONNECT_MIN_MS;
      this.log.info("connected");
      this.options.onStatusChange?.("open");
    });

    socket.on("message", (data) => {
      try {
        const parsed = JSON.parse(data.toString());
        this.options.onMessage(parsed);
      } catch (err) {
        this.log.warn("failed to parse message", err);
      }
    });

    socket.on("close", (code) => {
      this.log.warn(`closed (code ${code})`);
      this.options.onStatusChange?.("closed");
      this.scheduleReconnect();
    });

    socket.on("error", (err) => {
      this.log.warn("socket error", (err as Error).message);
    });
  }

  private scheduleReconnect(): void {
    if (this.closedByCaller || this.reconnectTimer) return;
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.connect();
    }, this.reconnectDelay);
    this.reconnectDelay = Math.min(this.reconnectDelay * 2, RECONNECT_MAX_MS);
  }
}
