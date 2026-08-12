import { invoke } from "@tauri-apps/api/core";
import type { NormalizedEvent, PendingAlert, Settings } from "./types";

export const api = {
  getSettings: () => invoke<Settings>("get_settings"),
  saveSettings: (settings: Settings) => invoke<void>("save_settings", { settings }),
  listRecentEvents: (limit = 100) => invoke<NormalizedEvent[]>("list_recent_events", { limit }),
  listRevisions: (eventId: string) => invoke<NormalizedEvent[]>("list_revisions", { eventId }),
  getConnectionStatus: () => invoke<Record<string, boolean>>("get_connection_status"),
  getPendingAlert: () => invoke<PendingAlert | null>("get_pending_alert"),
};
