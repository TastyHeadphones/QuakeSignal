import { getCurrentWindow } from "@tauri-apps/api/window";
import { listen } from "@tauri-apps/api/event";
import { api } from "./api";
import { setLanguage, t } from "./i18n";
import type { LocaleKey } from "./locales/en";
import type { NormalizedEvent, NotifyReason, PendingAlert } from "./types";

const EARTH_RADIUS_KM = 6371;
/** Typical S-wave speed used for a rough "time until shaking" estimate.
 * This is a consumer-app approximation, not a seismological calculation --
 * labelled as an estimate in the UI (alert.countdown.label). */
const S_WAVE_KM_PER_S = 4.0;

function haversineKm(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const toRad = (d: number) => (d * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLon = toRad(lon2 - lon1);
  const a =
    Math.sin(dLat / 2) ** 2 + Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLon / 2) ** 2;
  return EARTH_RADIUS_KM * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

const badgeKeyFor: Record<NotifyReason, LocaleKey> = {
  new: "alert.badge.new",
  updated: "alert.badge.updated",
  final: "alert.badge.final",
  cancelled: "alert.badge.cancelled",
  report: "alert.badge.report",
  training: "alert.badge.training",
};

let countdownTimer: number | undefined;

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

  document.getElementById("badge")!.textContent = t(badgeKeyFor[reason]);
  document.getElementById("hypocenter")!.textContent = event.hypocenter;

  const magText = event.magnitude != null ? `M${event.magnitude.toFixed(1)}` : "M?";
  const depthText = event.depth != null ? ` · ${Math.round(event.depth)} km` : "";
  document.getElementById("meta")!.textContent = `${magText}${depthText}`;

  document.getElementById("tip")!.textContent = t("alert.dropCoverHoldOn");
  document.getElementById("dismiss")!.textContent = t("alert.dismiss");

  const countdownLabel = document.getElementById("countdown-label")!;
  const countdownNum = document.getElementById("countdown-num")!;

  if (countdownTimer) {
    window.clearInterval(countdownTimer);
    countdownTimer = undefined;
  }

  if (reason === "training") {
    countdownNum.textContent = "";
    countdownLabel.textContent = t("alert.training.note");
    return;
  }
  if (reason === "cancelled") {
    countdownNum.textContent = "";
    countdownLabel.textContent = "";
    return;
  }

  const settings = await api.getSettings();
  const eta = computeEta(event, settings.latitude, settings.longitude);
  if (eta === null) {
    countdownNum.textContent = "—";
    countdownLabel.textContent = t("alert.countdown.unknown");
    return;
  }

  countdownLabel.textContent = t("alert.countdown.label");
  const tick = () => {
    const remaining = Math.max(0, Math.round(eta.etaSeconds - (Date.now() - eta.computedAtMs) / 1000));
    countdownNum.textContent = remaining > 0 ? String(remaining) : "0";
    if (remaining <= 0) {
      countdownLabel.textContent = t("alert.countdown.arrived");
    }
  };
  tick();
  countdownTimer = window.setInterval(tick, 1000);
}

function computeEta(
  event: NormalizedEvent,
  userLat: number | null,
  userLon: number | null,
): { etaSeconds: number; computedAtMs: number } | null {
  if (userLat == null || userLon == null || event.latitude == null || event.longitude == null) {
    return null;
  }
  if (!event.originTimeUtc) return null;
  const distanceKm = haversineKm(userLat, userLon, event.latitude, event.longitude);
  const originMs = Date.parse(event.originTimeUtc);
  if (Number.isNaN(originMs)) return null;
  const elapsedSeconds = (Date.now() - originMs) / 1000;
  const etaSeconds = distanceKm / S_WAVE_KM_PER_S - elapsedSeconds;
  return { etaSeconds, computedAtMs: Date.now() };
}

async function load() {
  const pending = await api.getPendingAlert();
  if (pending) {
    await render(pending);
  }
}

document.getElementById("dismiss")?.addEventListener("click", () => {
  getCurrentWindow().close();
});

listen("alert-updated", () => {
  load();
});

load();
