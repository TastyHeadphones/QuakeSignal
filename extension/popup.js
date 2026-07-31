import { DEFAULT_SETTINGS, SOURCE_IDS } from "./core.js";

const $ = (id) => document.getElementById(id);
const message = (key, substitutions) => chrome.i18n.getMessage(key, substitutions) || key;

function localize() {
  document.documentElement.lang = chrome.i18n.getUILanguage();
  document.querySelectorAll("[data-i18n]").forEach((element) => {
    element.textContent = message(element.dataset.i18n);
  });
  document.querySelectorAll("[data-i18n-title]").forEach((element) => {
    const value = message(element.dataset.i18nTitle);
    element.title = value;
    element.setAttribute("aria-label", value);
  });
}

function formatTime(raw) {
  if (!raw) return "";
  const date = new Date(raw);
  return Number.isNaN(date.getTime()) ? "" : new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" }).format(date);
}

function render(state) {
  const events = state.events || [];
  const settings = { ...DEFAULT_SETTINGS, ...(state.settings || {}) };
  const status = state.connectionStatus || {};
  const connected = SOURCE_IDS.filter((source) => status[source]).length;
  $("connection").textContent = message("sourcesConnected", [String(connected), String(SOURCE_IDS.length)]);
  $("connection").classList.toggle("online", connected > 0);

  const warning = events.find((event) => event.kind === "eew" && event.isWarn && !event.isCancel && !event.isTraining);
  const card = $("status-card");
  if (warning) {
    card.classList.add("warning");
    $("status-title").textContent = message("activeWarning");
    $("status-detail").textContent = message("eventSummary", [warning.hypocenter, warning.magnitude == null ? "?" : warning.magnitude.toFixed(1)]);
  } else {
    card.classList.remove("warning");
    $("status-title").textContent = message("noActiveWarning");
    $("status-detail").textContent = message("monitoringSources");
  }

  const list = $("events");
  list.replaceChildren();
  if (!events.length) {
    const empty = document.createElement("p");
    empty.className = "empty";
    empty.textContent = message("waitingForData");
    list.appendChild(empty);
  } else {
    for (const event of events.slice(0, 12)) {
      const item = document.createElement("article");
      const magnitude = document.createElement("strong");
      magnitude.className = `magnitude m${Math.min(7, Math.floor(event.magnitude || 0))}`;
      magnitude.textContent = event.magnitude == null ? "M?" : `M${event.magnitude.toFixed(1)}`;
      const content = document.createElement("div");
      const title = document.createElement("h3");
      title.textContent = event.hypocenter;
      const meta = document.createElement("p");
      const depth = event.depth == null ? "" : ` · ${Math.round(event.depth)} km`;
      meta.textContent = `${formatTime(event.reportTimeUtc || event.originTimeUtc)}${depth} · ${event.sourceId}`;
      content.append(title, meta);
      item.append(magnitude, content);
      list.appendChild(item);
    }
  }

  $("notifications").checked = settings.notificationsEnabled;
  $("alarm").checked = settings.alarmEnabled;
  $("magnitude").value = String(settings.minMagnitude);
}

async function load() {
  render(await chrome.runtime.sendMessage({ type: "getState" }));
}

async function save() {
  const current = await chrome.runtime.sendMessage({ type: "getState" });
  await chrome.runtime.sendMessage({
    type: "saveSettings",
    settings: {
      ...DEFAULT_SETTINGS,
      ...(current.settings || {}),
      notificationsEnabled: $("notifications").checked,
      alarmEnabled: $("alarm").checked,
      minMagnitude: Number($("magnitude").value),
    },
  });
}

localize();
$("refresh").addEventListener("click", load);
$("notifications").addEventListener("change", save);
$("alarm").addEventListener("change", save);
$("magnitude").addEventListener("change", save);
$("test-alert").addEventListener("click", async () => {
  await chrome.runtime.sendMessage({ type: "testAlert" });
  $("test-alert").textContent = message("testSent");
  setTimeout(() => { $("test-alert").textContent = message("testAlert"); }, 1_500);
});
chrome.runtime.onMessage.addListener((event) => {
  if (event?.type === "stateUpdated") void load();
});
chrome.runtime.sendMessage({ type: "clearBadge" }).catch(() => {});
void load();
