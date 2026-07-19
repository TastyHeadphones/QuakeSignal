import "dotenv/config";
import { ALL_WOLFX_SOURCES, type WolfxSourceId } from "./types/wolfx.js";

function parseSources(raw: string | undefined): WolfxSourceId[] {
  if (!raw || raw.trim() === "") return ALL_WOLFX_SOURCES;
  const requested = raw.split(",").map((s) => s.trim());
  const valid = requested.filter((s): s is WolfxSourceId =>
    (ALL_WOLFX_SOURCES as string[]).includes(s),
  );
  return valid.length > 0 ? valid : ALL_WOLFX_SOURCES;
}

export const config = {
  port: Number(process.env.PORT ?? 8080),
  dbPath: process.env.DB_PATH ?? "./data/quakesignal.sqlite",
  apns: {
    keyPath: process.env.APNS_KEY_PATH ?? "",
    keyId: process.env.APNS_KEY_ID ?? "",
    teamId: process.env.APNS_TEAM_ID ?? "",
    bundleId: process.env.APNS_BUNDLE_ID ?? "com.quakesignal.app",
    production: (process.env.APNS_PRODUCTION ?? "false").toLowerCase() === "true",
  },
  wolfxSources: parseSources(process.env.WOLFX_SOURCES),
  logLevel: process.env.LOG_LEVEL ?? "info",
} as const;

export const isApnsConfigured =
  config.apns.keyPath !== "" && config.apns.keyId !== "" && config.apns.teamId !== "";
