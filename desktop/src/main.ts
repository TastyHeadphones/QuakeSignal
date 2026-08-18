import { listen } from "@tauri-apps/api/event";
import { isPermissionGranted, requestPermission } from "@tauri-apps/plugin-notification";
import { api } from "./api";
import { setLanguage, t } from "./i18n";
import { CITIES, cityLocalizedName, findCity } from "./cities";
import { ALL_SOURCE_IDS, EEW_SOURCE_IDS, REPORT_SOURCE_IDS } from "./types";
import type { LocaleKey } from "./locales/en";
import type { NormalizedEvent, Settings } from "./types";

let settings: Settings;
let recentEvents: NormalizedEvent[] = [];
let connectionStatus: Record<string, boolean> = {};
let databasePersistenceAvailable = true;
let expandedEventId: string | null = null;
const revisionsCache: Record<string, NormalizedEvent[]> = {};
const isMacAppStoreBuild = import.meta.env.VITE_MAC_APP_STORE === "true";

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;

async function main() {
  settings = await api.getSettings();
  setLanguage(settings.language);

  const [, , persistenceAvailable] = await Promise.all([
    refreshEvents(),
    refreshStatus(),
    api.getDatabasePersistenceAvailable(),
  ]);
  databasePersistenceAvailable = persistenceAvailable;

  wireTabBar();
  wireSettingsForm();
  applyStaticStrings();
  $("storage-warning").hidden = databasePersistenceAvailable;
  renderHome();
  renderEvents();
  renderSettingsForm();

  void ensureNotificationPermission();

  listen("quake-event", async () => {
    await refreshEvents();
    renderHome();
    renderEvents();
  });
  listen("quake-db-updated", async () => {
    await refreshEvents();
    renderHome();
    renderEvents();
  });
  listen("quake-status", async () => {
    await refreshStatus();
    renderHome();
  });

  window.setInterval(async () => {
    await refreshStatus();
    renderHome();
  }, 15_000);
}

async function ensureNotificationPermission() {
  try {
    if (!(await isPermissionGranted())) {
      await requestPermission();
    }
  } catch {
    // notification permission API not available on this platform build; ignore
  }
}

async function refreshEvents() {
  recentEvents = await api.listRecentEvents(100);
}

async function refreshStatus() {
  connectionStatus = await api.getConnectionStatus();
}

// ---------------------------------------------------------------- tab bar --

function wireTabBar() {
  document.querySelectorAll<HTMLButtonElement>(".tabbar button").forEach((btn) => {
    btn.addEventListener("click", () => switchTab(btn.dataset.tab!));
  });
}

function switchTab(tab: string) {
  document.querySelectorAll<HTMLButtonElement>(".tabbar button").forEach((b) => {
    b.classList.toggle("active", b.dataset.tab === tab);
  });
  document.querySelectorAll<HTMLElement>(".panel").forEach((p) => {
    p.classList.toggle("active", p.id === `panel-${tab}`);
  });
}

// ------------------------------------------------------------------ home --

function statusLevel(): { level: "normal" | "caution" | "alert"; event?: NormalizedEvent } {
  const activeWarning = recentEvents.find(
    (e) => e.kind === "eew" && e.isWarn && !e.isCancel && !e.isTraining,
  );
  if (activeWarning) {
    return { level: "alert", event: activeWarning };
  }
  const mostRecent = recentEvents[0];
  if (mostRecent) {
    const stamp = mostRecent.reportTimeUtc ?? mostRecent.originTimeUtc;
    const ageMs = stamp ? Date.now() - Date.parse(stamp) : Number.POSITIVE_INFINITY;
    if (ageMs < 30 * 60 * 1000) {
      return { level: "caution", event: mostRecent };
    }
  }
  return { level: "normal" };
}

function renderHome() {
  const { level, event } = statusLevel();
  const banner = $("status-banner");
  banner.className = `status-banner ${level === "normal" ? "" : level}`.trim();

  const title = $("status-title");
  const detail = $("status-detail");
  const mag = event?.magnitude != null ? event.magnitude.toFixed(1) : "?";

  if (level === "alert" && event) {
    title.textContent = t("home.status.alert.title");
    detail.textContent = t("home.status.alert.detail", { mag, hypocenter: event.hypocenter });
  } else if (level === "caution" && event) {
    title.textContent = t("home.status.caution.title");
    detail.textContent = t("home.status.caution.detail", { mag, hypocenter: event.hypocenter });
  } else {
    title.textContent = t("home.status.normal.title");
    detail.textContent = t("home.status.normal.detail");
  }

  const connected = Object.values(connectionStatus).filter(Boolean).length;
  $("sources-label").textContent = t("home.sources.label", {
    connected,
    total: ALL_SOURCE_IDS.length,
  });
  const dots = $("sources-dots");
  dots.innerHTML = "";
  for (const id of ALL_SOURCE_IDS) {
    const dot = document.createElement("span");
    dot.className = "dot" + (connectionStatus[id] ? " on" : "");
    dot.title = id;
    dots.appendChild(dot);
  }

  const list = $("home-recent-list");
  list.innerHTML = "";
  const preview = recentEvents.slice(0, 5);
  if (preview.length === 0) {
    list.appendChild(emptyState(t("home.lastEvent.none")));
  } else {
    for (const e of preview) list.appendChild(renderEventItem(e, false));
  }
}

// ---------------------------------------------------------------- events --

function renderEvents() {
  const list = $("events-list");
  list.innerHTML = "";
  if (recentEvents.length === 0) {
    list.appendChild(emptyState(t("events.empty")));
    return;
  }
  for (const e of recentEvents) list.appendChild(renderEventItem(e, true));
}

function magClass(event: NormalizedEvent): string {
  if (event.isTraining) return "training";
  const m = event.magnitude ?? 0;
  if (m >= 7) return "m7";
  if (m >= 6) return "m6";
  if (m >= 5) return "m5";
  return "m3";
}

function formatTime(iso: string | null): string {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  return d.toLocaleString(undefined, {
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

function renderEventItem(event: NormalizedEvent, expandable: boolean): HTMLElement {
  const item = document.createElement("div");
  item.className = "event-item";

  const top = document.createElement("div");
  top.className = "event-top";

  const badge = document.createElement("span");
  badge.className = `mag-badge ${magClass(event)}`;
  badge.textContent =
    event.magnitude != null ? `${t("events.magnitudeShort")}${event.magnitude.toFixed(1)}` : "?";
  top.appendChild(badge);

  const name = document.createElement("span");
  name.className = "event-hypocenter";
  name.textContent = event.hypocenter;
  top.appendChild(name);

  const time = document.createElement("span");
  time.className = "event-time";
  time.textContent = formatTime(event.reportTimeUtc ?? event.originTimeUtc);
  top.appendChild(time);

  item.appendChild(top);

  const meta = document.createElement("div");
  meta.className = "event-meta";
  const parts: string[] = [];
  if (event.depth != null) parts.push(t("events.depth", { depth: Math.round(event.depth) }));
  parts.push(event.sourceId);
  meta.textContent = parts.join(" · ");
  item.appendChild(meta);

  if (expandable) {
    item.addEventListener("click", () => {
      expandedEventId = expandedEventId === event.id ? null : event.id;
      renderEvents();
    });
    if (expandedEventId === event.id) {
      const detail = document.createElement("div");
      detail.className = "event-detail";
      detail.textContent = "…";
      item.appendChild(detail);
      void loadRevisions(event.id).then((revs) => {
        detail.innerHTML = "";
        const heading = document.createElement("div");
        heading.className = "event-detail-heading";
        heading.textContent = t("events.revisions.title");
        detail.appendChild(heading);
        for (const rev of revs) {
          const row = document.createElement("div");
          row.className = "rev";
          const left = document.createElement("span");
          left.textContent = `#${rev.serial} · ${rev.magnitude != null ? rev.magnitude.toFixed(1) : "?"}`;
          const right = document.createElement("span");
          right.textContent = formatTime(rev.reportTimeUtc ?? rev.originTimeUtc);
          row.appendChild(left);
          row.appendChild(right);
          detail.appendChild(row);
        }
      });
    }
  }

  return item;
}

async function loadRevisions(eventId: string): Promise<NormalizedEvent[]> {
  if (!revisionsCache[eventId]) {
    revisionsCache[eventId] = await api.listRevisions(eventId);
  }
  return revisionsCache[eventId];
}

function emptyState(message: string): HTMLElement {
  const div = document.createElement("div");
  div.className = "empty-state";
  div.textContent = message;
  return div;
}

// -------------------------------------------------------------- settings --

function wireSettingsForm() {
  const testAlertButton = $("test-alert-btn");
  // A Store listing must represent the normal monitoring experience, not a
  // locally generated alarm. Keep the direct-download diagnostic available,
  // but do not surface it in the sandboxed Mac App Store build.
  testAlertButton.hidden = isMacAppStoreBuild;
  if (!isMacAppStoreBuild) {
    testAlertButton.addEventListener("click", async () => {
      const { sendTestAlert } = await import("./direct-api");
      await sendTestAlert();
    });
  }

  const citySelect = $<HTMLSelectElement>("f-city");
  const noneOpt = document.createElement("option");
  noneOpt.value = "";
  citySelect.appendChild(noneOpt);
  for (const city of CITIES) {
    const opt = document.createElement("option");
    opt.value = city.id;
    opt.textContent = cityLocalizedName(city, settings.language === "system" ? "en" : settings.language);
    citySelect.appendChild(opt);
  }
  citySelect.addEventListener("change", () => {
    const city = findCity(citySelect.value);
    if (city) {
      $<HTMLInputElement>("f-lat").value = String(city.latitude);
      $<HTMLInputElement>("f-lon").value = String(city.longitude);
    }
  });

  const eewList = $("sources-eew-list");
  for (const id of EEW_SOURCE_IDS) eewList.appendChild(sourceCheckbox(id));
  const reportsList = $("sources-reports-list");
  for (const id of REPORT_SOURCE_IDS) reportsList.appendChild(sourceCheckbox(id));

  $<HTMLSelectElement>("f-language").addEventListener("change", (e) => {
    setLanguage((e.target as HTMLSelectElement).value);
    applyStaticStrings();
    renderSettingsForm();
    renderHome();
    renderEvents();
  });
  $<HTMLInputElement>("f-alarm-volume").addEventListener("input", () => {
    renderAlarmVolume();
  });

  $<HTMLFormElement>("settings-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    settings = collectSettingsFromForm();
    await api.saveSettings(settings);
    showToast(t("settings.saved"));
  });
}

function sourceCheckbox(id: string): HTMLElement {
  const label = document.createElement("label");
  label.className = "source-checkbox";
  const input = document.createElement("input");
  input.type = "checkbox";
  input.dataset.sourceId = id;
  const span = document.createElement("span");
  span.textContent = t(`settings.source.${id}` as LocaleKey);
  label.appendChild(input);
  label.appendChild(span);
  return label;
}

function renderSettingsForm() {
  $<HTMLSelectElement>("f-language").value = settings.language;
  $<HTMLSelectElement>("f-city").value = settings.locationLabel
    ? (CITIES.find((c) => c.nameEn === settings.locationLabel)?.id ?? "")
    : "";
  $<HTMLInputElement>("f-lat").value = settings.latitude != null ? String(settings.latitude) : "";
  $<HTMLInputElement>("f-lon").value = settings.longitude != null ? String(settings.longitude) : "";
  $<HTMLInputElement>("f-radius").value = settings.radiusKm != null ? String(settings.radiusKm) : "";
  $<HTMLInputElement>("f-min-magnitude").value = String(settings.minMagnitude);
  $<HTMLInputElement>("f-include-test-alerts").checked = settings.includeTestAlerts;
  $<HTMLInputElement>("f-notify-at-night").checked = settings.notifyAtNight;
  $<HTMLInputElement>("f-alarm-enabled").checked = settings.alarmEnabled;
  $<HTMLInputElement>("f-alarm-volume").value = String(settings.alarmVolume);
  renderAlarmVolume();
  const launchAtLogin = $<HTMLInputElement>("f-launch-at-login");
  launchAtLogin.checked = !isMacAppStoreBuild && settings.launchAtLogin;
  $("launch-at-login-row").hidden = isMacAppStoreBuild;

  document
    .querySelectorAll<HTMLInputElement>("#sources-eew-list input, #sources-reports-list input")
    .forEach((cb) => {
      cb.checked = settings.sources.includes(cb.dataset.sourceId!);
    });
}

function renderAlarmVolume() {
  const volume = Number($<HTMLInputElement>("f-alarm-volume").value);
  const detailKey = isMacAppStoreBuild
    ? "settings.alarmVolume.storeDetail"
    : "settings.alarmVolume.detail";
  $("d-alarm-volume").textContent = t(detailKey, {
    volume: Math.round(volume * 100),
  });
}

function collectSettingsFromForm(): Settings {
  const cityId = $<HTMLSelectElement>("f-city").value;
  const city = cityId ? findCity(cityId) : undefined;
  const latRaw = $<HTMLInputElement>("f-lat").value.trim();
  const lonRaw = $<HTMLInputElement>("f-lon").value.trim();
  const radiusRaw = $<HTMLInputElement>("f-radius").value.trim();

  const sources = Array.from(
    document.querySelectorAll<HTMLInputElement>("#sources-eew-list input, #sources-reports-list input"),
  )
    .filter((cb) => cb.checked)
    .map((cb) => cb.dataset.sourceId!);

  return {
    language: $<HTMLSelectElement>("f-language").value,
    sources,
    minMagnitude: Number($<HTMLInputElement>("f-min-magnitude").value || "0"),
    locationLabel: city?.nameEn ?? null,
    latitude: latRaw ? Number(latRaw) : null,
    longitude: lonRaw ? Number(lonRaw) : null,
    radiusKm: radiusRaw ? Number(radiusRaw) : null,
    includeTestAlerts: $<HTMLInputElement>("f-include-test-alerts").checked,
    notifyAtNight: $<HTMLInputElement>("f-notify-at-night").checked,
    alarmEnabled: $<HTMLInputElement>("f-alarm-enabled").checked,
    alarmVolume: Number($<HTMLInputElement>("f-alarm-volume").value),
    launchAtLogin: !isMacAppStoreBuild && $<HTMLInputElement>("f-launch-at-login").checked,
  };
}

let toastTimer: number | undefined;
function showToast(message: string) {
  const toast = $("toast");
  toast.textContent = message;
  toast.classList.add("show");
  if (toastTimer) window.clearTimeout(toastTimer);
  toastTimer = window.setTimeout(() => toast.classList.remove("show"), 1800);
}

// ------------------------------------------------------------ static i18n --

function applyStaticStrings() {
  $("app-title").textContent = t("app.name");
  document.title = t("app.name");
  $("tab-home-label").textContent = t("tab.home");
  $("tab-events-label").textContent = t("tab.events");
  $("tab-settings-label").textContent = t("tab.settings");
  $("test-alert-btn").textContent = t("home.testAlert.button");
  $("recent-title").textContent = t("tab.events");
  $("storage-warning").textContent = t("storage.persistenceUnavailable");

  $("s-title-language").textContent = t("settings.section.language");
  const langSelect = $<HTMLSelectElement>("f-language");
  langSelect.options[0].textContent = t("settings.language.system");
  langSelect.options[1].textContent = t("settings.language.en");
  langSelect.options[2].textContent = t("settings.language.ja");
  langSelect.options[3].textContent = t("settings.language.zh-Hans");

  $("s-title-location").textContent = t("settings.section.location");
  $("l-city").textContent = t("settings.location.city");
  $("l-lat").textContent = t("settings.location.customLat");
  $("l-lon").textContent = t("settings.location.customLon");
  $("l-radius").textContent = t("settings.location.radius");
  $("hint-radius").textContent = t("settings.location.radius.hint");

  $("s-title-threshold").textContent = t("settings.section.threshold");
  $("hint-threshold").textContent = t("settings.threshold.hint");

  $("s-title-sources").textContent = t("settings.section.sources");
  $("label-sources-eew").textContent = t("settings.sources.eew");
  $("label-sources-reports").textContent = t("settings.sources.reports");
  document
    .querySelectorAll<HTMLElement>(
      "#sources-eew-list .source-checkbox span, #sources-reports-list .source-checkbox span",
    )
    .forEach((span) => {
      const input = span.previousElementSibling as HTMLInputElement;
      span.textContent = t(`settings.source.${input.dataset.sourceId}` as LocaleKey);
    });

  $("s-title-notifications").textContent = t("settings.section.notifications");
  $("l-alarm-enabled").textContent = t("settings.alarmEnabled");
  $("d-alarm-enabled").textContent = t("settings.alarmEnabled.detail");
  $("l-alarm-volume").textContent = t("settings.alarmVolume");
  renderAlarmVolume();
  $("l-test-alerts").textContent = t("settings.includeTestAlerts");
  $("d-test-alerts").textContent = t("settings.includeTestAlerts.detail");
  $("l-notify-night").textContent = t("settings.notifyAtNight");
  $("d-notify-night").textContent = t("settings.notifyAtNight.detail");
  $("l-launch-login").textContent = t("settings.launchAtLogin");
  $("d-launch-login").textContent = t("settings.launchAtLogin.detail");

  $("s-title-about").textContent = t("settings.section.about");
  $("about-data-source").textContent = t("settings.about.dataSource");
  $("about-disclaimer").textContent = t("disclaimer.notOfficial");
  $("about-repo-link").textContent = t("settings.about.repo");
  $("save-btn").textContent = t("settings.save");
}

main();
