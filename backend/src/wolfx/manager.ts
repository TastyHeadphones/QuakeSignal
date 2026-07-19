import { WolfxClient, type WolfxConnectionStatus } from "./client.js";
import { config } from "../config.js";
import { createLogger } from "../logger.js";
import type {
  CencCqEewMessage,
  CencEqlistEntry,
  JmaEewMessage,
  JmaEqlistEntry,
  ScFjEewMessage,
  WolfxEqlistMessage,
  WolfxSourceId,
} from "../types/wolfx.js";
import { isHeartbeat, isPong } from "../types/wolfx.js";
import {
  extractEqlistEntries,
  normalizeCencCqEew,
  normalizeCencEqlistEntry,
  normalizeJmaEew,
  normalizeJmaEqlistEntry,
  normalizeScFjEew,
} from "../alerts/normalize.js";
import { ingestEvent } from "../alerts/pipeline.js";

const log = createLogger("wolfx-manager");
const HTTP_BASE = "https://api.wolfx.jp";
const EEW_SOURCES: WolfxSourceId[] = ["jma_eew", "sc_eew", "cenc_eew", "fj_eew", "cq_eew"];

function handleMessage(sourceId: WolfxSourceId, msg: unknown, isBackfill: boolean): void {
  if (isHeartbeat(msg) || isPong(msg)) return;
  if (!msg || typeof msg !== "object") return;

  switch (sourceId) {
    case "jma_eew":
      ingestEvent(normalizeJmaEew(msg as JmaEewMessage), isBackfill);
      break;
    case "sc_eew":
    case "fj_eew":
      ingestEvent(normalizeScFjEew(msg as ScFjEewMessage, sourceId), isBackfill);
      break;
    case "cenc_eew":
    case "cq_eew":
      ingestEvent(normalizeCencCqEew(msg as CencCqEewMessage, sourceId), isBackfill);
      break;
    case "cenc_eqlist":
      for (const { entry } of extractEqlistEntries<CencEqlistEntry>(msg as WolfxEqlistMessage)) {
        ingestEvent(normalizeCencEqlistEntry(entry), isBackfill);
      }
      break;
    case "jma_eqlist":
      for (const { entry } of extractEqlistEntries<JmaEqlistEntry>(msg as WolfxEqlistMessage)) {
        ingestEvent(normalizeJmaEqlistEntry(entry), isBackfill);
      }
      break;
  }
}

/** One-shot HTTP GET seed at boot so the DB has current state without treating history as new alerts. */
async function seedFromHttp(sourceId: WolfxSourceId): Promise<void> {
  try {
    const res = await fetch(`${HTTP_BASE}/${sourceId}.json`);
    if (!res.ok) return;
    const body = await res.json();
    if (!body || typeof body !== "object") return;

    if (EEW_SOURCES.includes(sourceId)) {
      // An idle source (no active warning) won't have a real EventID -- skip it rather
      // than normalizing a placeholder response into a bogus event.
      if ("EventID" in body) handleMessage(sourceId, body, true);
      return;
    }

    // eqlist sources: only seed if it actually carries ranked "No<n>" entries.
    if (Object.keys(body).some((k) => /^No\d+$/.test(k))) {
      handleMessage(sourceId, body, true);
    }
  } catch (err) {
    log.warn(`seed fetch failed for ${sourceId}`, err);
  }
}

const clients: WolfxClient[] = [];
const statusBySource = new Map<WolfxSourceId, WolfxConnectionStatus>();

export async function startWolfxManager(): Promise<void> {
  log.info(`starting relay for sources: ${config.wolfxSources.join(", ")}`);

  await Promise.all(config.wolfxSources.map(seedFromHttp));

  for (const sourceId of config.wolfxSources) {
    const client = new WolfxClient({
      endpoint: sourceId,
      onMessage: (msg) => handleMessage(sourceId, msg, false),
      onStatusChange: (status) => statusBySource.set(sourceId, status),
    });
    clients.push(client);
    client.start();
  }
}

export function stopWolfxManager(): void {
  for (const client of clients) client.stop();
}

export function getConnectionStatuses(): Record<string, WolfxConnectionStatus> {
  return Object.fromEntries(statusBySource);
}
