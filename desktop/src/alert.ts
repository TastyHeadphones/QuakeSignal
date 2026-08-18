import { getCurrentWindow } from "@tauri-apps/api/window";
import { listen } from "@tauri-apps/api/event";
import { api } from "./api";
import { createSerialTaskQueue } from "./alert-refresh.js";
import { setLanguage, t } from "./i18n";
import type { LocaleKey } from "./locales/en";
import type { NotifyReason, PendingAlert } from "./types";

const badgeKeyFor: Record<NotifyReason, LocaleKey> = {
  new: "alert.badge.new",
  updated: "alert.badge.updated",
  final: "alert.badge.final",
  cancelled: "alert.badge.cancelled",
  report: "alert.badge.report",
  training: "alert.badge.training",
};

function classFor(reason: NotifyReason): string {
  if (reason === "cancelled") return "cancelled";
  if (reason === "training") return "training";
  return "";
}

async function render(alert: PendingAlert) {
  setLanguage(alert.lang);
  const { event, reason } = alert;

  const root = document.getElementById("alert")!;
  root.className = classFor(reason);

  const badgeText = t(badgeKeyFor[reason]);
  document.getElementById("badge")!.textContent = badgeText;
  document.getElementById("hypocenter")!.textContent = event.hypocenter;
  document.title = `${t("app.name")} — ${badgeText}`;

  const magText = event.magnitude != null ? `M${event.magnitude.toFixed(1)}` : "M?";
  const depthText = event.depth != null ? ` · ${Math.round(event.depth)} km` : "";
  document.getElementById("meta")!.textContent = `${magText}${depthText}`;

  document.getElementById("tip")!.textContent = t("alert.dropCoverHoldOn");
  document.getElementById("dismiss")!.textContent = t("alert.dismiss");

  const guidance = document.getElementById("guidance")!;
  if (reason === "training") {
    guidance.textContent = t("alert.guidance.training");
  } else if (reason === "cancelled") {
    guidance.textContent = t("alert.guidance.cancelled");
  } else {
    guidance.textContent = t("alert.guidance.active");
  }

  document.getElementById("dismiss")!.focus({ preventScroll: true });
}

async function load() {
  const pending = await api.getPendingAlert();
  if (pending) {
    await render(pending);
  }
}

const enqueueLoad = createSerialTaskQueue(load);

function reportRefreshFailure(error: unknown) {
  console.error("Unable to refresh the emergency alert window", error);
}

document.getElementById("dismiss")?.addEventListener("click", () => {
  getCurrentWindow().close();
});

async function initialize() {
  // Register first, then perform the initial read. If an update arrives while
  // that read is in flight, the serial queue performs a second read afterward
  // and guarantees the newest accepted pending revision renders last.
  await listen("alert-updated", () => {
    void enqueueLoad().catch(reportRefreshFailure);
  });
  await enqueueLoad();
}

void initialize().catch(reportRefreshFailure);
