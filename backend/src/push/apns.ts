import apn from "@parse/node-apn";
import { config, isApnsConfigured } from "../config.js";
import { createLogger } from "../logger.js";

const log = createLogger("apns");

let provider: apn.Provider | null = null;

/** Lazily creates the singleton APNs provider. Returns null if APNS_* env vars aren't set. */
export function getApnsProvider(): apn.Provider | null {
  if (!isApnsConfigured) return null;
  if (provider) return provider;

  provider = new apn.Provider({
    token: {
      key: config.apns.keyPath,
      keyId: config.apns.keyId,
      teamId: config.apns.teamId,
    },
    production: config.apns.production,
  });
  // Provider is an EventEmitter; an unhandled "error" event (e.g. the .p8 key
  // file being missing/unreadable) would otherwise crash the whole process.
  provider.on("error", (err: Error) => log.error("APNs provider error", err.message));
  log.info(`APNs provider initialized (production=${config.apns.production})`);
  return provider;
}
