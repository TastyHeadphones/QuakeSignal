import {
  DEFAULT_SETTINGS,
  determineReason,
  enqueueRecovering,
  isUrgentNotification,
  mergeEventRevision,
  mergeEvents,
  normalizeMessage,
  passesFilters,
  routeSource,
} from "./core.js";

const ROUTES = [
  {
    path: "all_eew",
    sources: ["jma_eew", "sc_eew", "cenc_eew", "fj_eew", "cq_eew"],
    queries: ["query_jmaeew", "query_sceew", "query_cenceew", "query_fjeew", "query_cqeew"],
  },
  { path: "cenc_eqlist", sources: ["cenc_eqlist"], queries: ["query_cenceqlist"] },
  { path: "jma_eqlist", sources: ["jma_eqlist"], queries: ["query_jmaeqlist"] },
];

const sockets = new Map();
const seededSources = new Set();
let ingestQueue = Promise.resolve();
let connectionQueue = Promise.resolve();
let offscreenCreationPromise = null;

async function initialize() {
  const stored = await chrome.storage.local.get(["settings", "events", "connectionStatus"]);
  await chrome.storage.local.set({
    settings: { ...DEFAULT_SETTINGS, ...(stored.settings || {}) },
    events: stored.events || [],
    connectionStatus: stored.connectionStatus || {},
  });
  chrome.alarms.create("ensure-sockets", { periodInMinutes: 1 });
  connectAll();
}

function connectAll() {
  for (const route of ROUTES) connectRoute(route);
}

function connectRoute(route) {
  const existing = sockets.get(route.path);
  if (existing && (existing.socket.readyState === WebSocket.OPEN || existing.socket.readyState === WebSocket.CONNECTING)) return;

  const socket = new WebSocket(`wss://ws-api.wolfx.jp/${route.path}`);
  const state = { socket, retryMs: existing?.retryMs || 1_000, retryTimer: null, pingTimer: null };
  sockets.set(route.path, state);

  socket.addEventListener("open", () => {
    state.retryMs = 1_000;
    updateConnection(route.sources, true);
    for (const query of route.queries) socket.send(query);
    state.pingTimer = setInterval(() => {
      if (socket.readyState === WebSocket.OPEN) socket.send("ping");
    }, 20_000);
  });

  socket.addEventListener("message", (message) => {
    let payload;
    try {
      payload = JSON.parse(message.data);
    } catch {
      return;
    }
    if (payload.type === "heartbeat" || payload.type === "pong") return;
    const sourceId = route.path === "all_eew" ? routeSource(payload) : route.sources[0];
    if (!sourceId) return;
    const isBackfill = !seededSources.has(sourceId);
    seededSources.add(sourceId);
    ingestQueue = enqueueRecovering(
      ingestQueue,
      () => ingest(sourceId, payload, isBackfill),
      (error) => console.warn("QuakeSignal ingest failed; later messages will continue", error),
    );
  });

  const reconnect = () => {
    clearInterval(state.pingTimer);
    updateConnection(route.sources, false);
    if (state.retryTimer) return;
    const wait = state.retryMs;
    state.retryMs = Math.min(state.retryMs * 2, 30_000);
    state.retryTimer = setTimeout(() => {
      state.retryTimer = null;
      connectRoute(route);
    }, wait);
  };
  socket.addEventListener("close", reconnect);
  socket.addEventListener("error", () => socket.close());
}

async function updateConnection(sourceIds, connected) {
  connectionQueue = enqueueRecovering(
    connectionQueue,
    async () => {
      const { connectionStatus = {} } = await chrome.storage.local.get("connectionStatus");
      for (const sourceId of sourceIds) connectionStatus[sourceId] = connected;
      await chrome.storage.local.set({ connectionStatus });
      chrome.runtime.sendMessage({ type: "stateUpdated" }).catch(() => {});
    },
    (error) => console.warn("QuakeSignal connection status update failed; later updates will continue", error),
  );
  return connectionQueue;
}

async function ingest(sourceId, payload, isBackfill) {
  const incoming = normalizeMessage(sourceId, payload);
  if (!incoming.length) return;
  const { events = [], settings = DEFAULT_SETTINGS } = await chrome.storage.local.get(["events", "settings"]);
  const previousById = new Map(events.map((event) => [event.id, event]));
  const notifications = [];
  const reconciledIncoming = [];
  for (const event of incoming) {
    const previous = previousById.get(event.id);
    const reconciled = mergeEventRevision(previous, event);
    previousById.set(event.id, reconciled);
    reconciledIncoming.push(reconciled);
    const reason = determineReason(reconciled, previous);
    if (!isBackfill && reason && passesFilters(reconciled, settings)) {
      notifications.push({ event: reconciled, reason });
    }
  }
  await chrome.storage.local.set({ events: mergeEvents(events, reconciledIncoming) });
  chrome.runtime.sendMessage({ type: "stateUpdated" }).catch(() => {});
  for (const notification of notifications) {
    try {
      await notify(notification.event, notification.reason, settings);
    } catch (error) {
      // Persistence is authoritative. A browser notification or speaker
      // failure must not reject the ingest queue and block later earthquakes.
      console.warn("QuakeSignal notification delivery failed", error);
    }
  }
}

function localizedNotification(event, reason) {
  const locale = chrome.i18n.getUILanguage().toLowerCase();
  const magnitude = event.magnitude == null ? "?" : event.magnitude.toFixed(1);
  const reasonText = {
    en: { new: "Earthquake early warning", updated: "Earthquake warning updated", final: "Final earthquake warning", cancelled: "Earthquake warning cancelled", report: "Earthquake report", training: "Training alert" },
    ja: { new: "緊急地震速報", updated: "緊急地震速報（更新）", final: "緊急地震速報（最終）", cancelled: "緊急地震速報（取消）", report: "地震情報", training: "訓練通知" },
    zh: { new: "地震预警", updated: "地震预警更新", final: "地震预警最终报", cancelled: "地震预警已取消", report: "地震速报", training: "演练通知" },
  };
  const language = locale.startsWith("ja") ? "ja" : locale.startsWith("zh") ? "zh" : "en";
  return {
    title: reasonText[language][reason] || "QuakeSignal",
    message: language === "ja"
      ? `${event.hypocenter} · M${magnitude}${event.depth == null ? "" : ` · 深さ ${Math.round(event.depth)} km`}`
      : language === "zh"
        ? `${event.hypocenter} · M${magnitude}${event.depth == null ? "" : ` · 深度 ${Math.round(event.depth)} km`}`
        : `${event.hypocenter} · M${magnitude}${event.depth == null ? "" : ` · ${Math.round(event.depth)} km deep`}`,
  };
}

async function notify(event, reason, settings) {
  const copy = localizedNotification(event, reason);
  const urgent = isUrgentNotification(event, reason);
  await chrome.notifications.create(event.id, {
    type: "basic",
    iconUrl: "icons/128.png",
    title: copy.title,
    message: copy.message,
    priority: urgent ? 2 : 0,
  });
  await chrome.action.setBadgeBackgroundColor({ color: "#E53935" });
  await chrome.action.setBadgeText({ text: "!" });
  // Lifecycle notifications remain visible but silent. The explicit training
  // button may still exercise the opted-in alarm without pretending to be a
  // live warning.
  if (settings.alarmEnabled && (urgent || reason === "training")) {
    await playAlarm(settings.alarmVolume);
  }
}

async function playAlarm(volume) {
  const url = chrome.runtime.getURL("offscreen.html");
  if (!offscreenCreationPromise) {
    offscreenCreationPromise = (async () => {
      const contexts = await chrome.runtime.getContexts({
        contextTypes: ["OFFSCREEN_DOCUMENT"],
        documentUrls: [url],
      });
      if (!contexts.length) {
        await chrome.offscreen.createDocument({
          url: "offscreen.html",
          reasons: ["AUDIO_PLAYBACK"],
          justification: "Play the user-enabled earthquake alarm sound",
        });
      }
    })().finally(() => {
      offscreenCreationPromise = null;
    });
  }
  await offscreenCreationPromise;
  await chrome.runtime.sendMessage({ target: "offscreen", type: "playAlarm", volume });
}

chrome.runtime.onInstalled.addListener(() => void initialize());
chrome.runtime.onStartup.addListener(connectAll);
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === "ensure-sockets") connectAll();
});
chrome.notifications.onClicked.addListener(() => {
  chrome.tabs.create({ url: chrome.runtime.getURL("popup.html") });
});
chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.target === "offscreen") return false;
  if (message?.type === "getState") {
    chrome.storage.local.get(["events", "settings", "connectionStatus"]).then(sendResponse);
    return true;
  }
  if (message?.type === "saveSettings") {
    chrome.storage.local.set({ settings: { ...DEFAULT_SETTINGS, ...message.settings } }).then(() => sendResponse({ ok: true }));
    return true;
  }
  if (message?.type === "clearBadge") {
    chrome.action.setBadgeText({ text: "" }).then(() => sendResponse({ ok: true }));
    return true;
  }
  if (message?.type === "testAlert") {
    chrome.storage.local.get("settings").then(async ({ settings = DEFAULT_SETTINGS }) => {
      const event = { id: `test-${Date.now()}`, hypocenter: chrome.i18n.getMessage("testLocation"), magnitude: 5.2, depth: 10 };
      await notify(event, "training", { ...settings, alarmEnabled: settings.alarmEnabled });
      sendResponse({ ok: true });
    });
    return true;
  }
  return false;
});

void initialize();
