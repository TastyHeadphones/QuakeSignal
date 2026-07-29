import {
  extractEqlistEntries,
  normalizeCencCqEew,
  normalizeCencEqlistEntry,
  normalizeJmaEew,
  normalizeJmaEqlistEntry,
  normalizeScFjEew,
} from "../../src/alerts/normalize";
import type {
  DeviceRecord,
  NormalizedEvent,
  NotifyReason,
} from "../../src/types/domain";
import {
  ALL_WOLFX_SOURCES,
  isHeartbeat,
  isPong,
  type CencCqEewMessage,
  type CencEqlistEntry,
  type JmaEewMessage,
  type JmaEqlistEntry,
  type ScFjEewMessage,
  type WolfxEqlistMessage,
  type WolfxSourceId,
} from "../../src/types/wolfx";

interface Env {
  DB: D1Database;
  RELAY: DurableObjectNamespace;
  APNS_PRIVATE_KEY?: string;
  APNS_KEY_ID?: string;
  APNS_TEAM_ID?: string;
  APNS_BUNDLE_ID?: string;
}

interface EventRow {
  id: string;
  source_id: WolfxSourceId;
  event_id: string;
  serial: number;
  kind: "eew" | "report";
  origin_time_utc: string | null;
  report_time_utc: string | null;
  hypocenter: string | null;
  latitude: number | null;
  longitude: number | null;
  magnitude: number | null;
  depth: number | null;
  max_intensity: string | null;
  is_warn: number;
  is_final: number;
  is_cancel: number;
  is_training: number;
  tsunami: string | null;
  raw_json: string | null;
}

interface DeviceRow {
  token: string;
  environment: "sandbox" | "production";
  locale: string | null;
  sources: string;
  min_magnitude: number;
  critical_alerts_enabled: number;
  city_name: string | null;
  latitude: number | null;
  longitude: number | null;
  radius_km: number | null;
  include_test_alerts: number;
  utc_offset_minutes: number | null;
  notify_at_night: number;
  created_at: string;
  updated_at: string;
}

const HTTP_BASE = "https://api.wolfx.jp";
const WS_BASE = "wss://ws-api.wolfx.jp";
const EEW_SOURCES: WolfxSourceId[] = [
  "jma_eew",
  "sc_eew",
  "cenc_eew",
  "fj_eew",
  "cq_eew",
];
const UPSTREAM_ROUTES = ["all_eew", "cenc_eqlist", "jma_eqlist"] as const;
type UpstreamRoute = (typeof UPSTREAM_ROUTES)[number];
const SOURCE_LABEL: Record<string, string> = {
  jma_eew: "JMA",
  sc_eew: "Sichuan EQA",
  cenc_eew: "CENC",
  fj_eew: "Fujian EQA",
  cq_eew: "Chongqing EQA",
  cenc_eqlist: "CENC",
  jma_eqlist: "JMA",
};
const LOC_KEYS: Record<NotifyReason, { title: string; body: string }> = {
  new: { title: "eew.push.new.title", body: "eew.push.new.body" },
  updated: {
    title: "eew.push.updated.title",
    body: "eew.push.updated.body",
  },
  final: { title: "eew.push.final.title", body: "eew.push.final.body" },
  cancelled: {
    title: "eew.push.cancelled.title",
    body: "eew.push.cancelled.body",
  },
  report: {
    title: "quake.push.report.title",
    body: "quake.push.report.body",
  },
  training: {
    title: "eew.push.training.title",
    body: "eew.push.training.body",
  },
};

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "Content-Type",
  "Access-Control-Allow-Methods": "GET,POST,DELETE,OPTIONS",
};

function json(
  value: unknown,
  status = 200,
  headers: Record<string, string> = {},
): Response {
  return Response.json(value, {
    status,
    headers: { ...corsHeaders, ...headers },
  });
}

function legalPage(
  title: string,
  summary: string,
  sections: Array<{ heading: string; body: string }>,
): Response {
  const content = sections
    .map(
      ({ heading, body }) =>
        `<section><h2>${heading}</h2><p>${body}</p></section>`,
    )
    .join("");
  return new Response(
    `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>${title} · QuakeSignal</title>
  <style>
    :root{color-scheme:light dark;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
    body{margin:0;background:#f2f2f7;color:#1c1c1e}
    main{max-width:720px;margin:0 auto;padding:64px 24px}
    header,section{background:#fff;border-radius:20px;padding:24px;margin:0 0 16px}
    .mark{display:inline-grid;place-items:center;width:48px;height:48px;border-radius:14px;background:#0e63c4;color:#fff;font-size:24px}
    h1{font-size:34px;margin:20px 0 8px}h2{font-size:19px}p{line-height:1.6;color:#54545a}
    a{color:#0e63c4}.meta{font-size:13px;color:#8e8e93}
    @media(prefers-color-scheme:dark){body{background:#000;color:#f2f2f7}header,section{background:#1c1c1e}p{color:#c7c7cc}}
  </style>
</head>
<body><main>
  <header><span class="mark">⌁</span><h1>${title}</h1><p>${summary}</p><p class="meta">QuakeSignal · Effective July 29, 2026</p></header>
  ${content}
  <section><h2>Contact</h2><p>For privacy, safety, or support questions, open an issue in the <a href="https://github.com/TastyHeadphones/QuakeSignal/issues">QuakeSignal GitHub repository</a>.</p></section>
</main></body></html>`,
    {
      headers: {
        "content-type": "text/html; charset=utf-8",
        "cache-control": "public, max-age=3600",
      },
    },
  );
}

function rowToEvent(row: EventRow): NormalizedEvent {
  return {
    id: row.id,
    sourceId: row.source_id,
    eventId: row.event_id,
    serial: row.serial,
    kind: row.kind,
    originTimeUtc: row.origin_time_utc,
    reportTimeUtc: row.report_time_utc,
    hypocenter: row.hypocenter ?? "",
    latitude: row.latitude,
    longitude: row.longitude,
    magnitude: row.magnitude,
    depth: row.depth,
    maxIntensity: row.max_intensity,
    isWarn: !!row.is_warn,
    isFinal: !!row.is_final,
    isCancel: !!row.is_cancel,
    isTraining: !!row.is_training,
    tsunami: row.tsunami,
    raw: row.raw_json ? JSON.parse(row.raw_json) : null,
  };
}

function rowToDevice(row: DeviceRow): DeviceRecord {
  return {
    token: row.token,
    environment: row.environment,
    locale: row.locale,
    sources: JSON.parse(row.sources) as WolfxSourceId[],
    minMagnitude: row.min_magnitude,
    criticalAlertsEnabled: !!row.critical_alerts_enabled,
    cityName: row.city_name,
    latitude: row.latitude,
    longitude: row.longitude,
    radiusKm: row.radius_km,
    includeTestAlerts: !!row.include_test_alerts,
    utcOffsetMinutes: row.utc_offset_minutes,
    notifyAtNight: !!row.notify_at_night,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function normalizeMessages(
  sourceId: WolfxSourceId,
  message: unknown,
): NormalizedEvent[] {
  if (
    isHeartbeat(message) ||
    isPong(message) ||
    !message ||
    typeof message !== "object"
  ) {
    return [];
  }

  switch (sourceId) {
    case "jma_eew":
      return "EventID" in message
        ? [normalizeJmaEew(message as JmaEewMessage)]
        : [];
    case "sc_eew":
    case "fj_eew":
      return "EventID" in message
        ? [normalizeScFjEew(message as ScFjEewMessage, sourceId)]
        : [];
    case "cenc_eew":
    case "cq_eew":
      return "EventID" in message
        ? [normalizeCencCqEew(message as CencCqEewMessage, sourceId)]
        : [];
    case "cenc_eqlist":
      return extractEqlistEntries<CencEqlistEntry>(
        message as WolfxEqlistMessage,
      ).map(({ entry }) => normalizeCencEqlistEntry(entry));
    case "jma_eqlist":
      return extractEqlistEntries<JmaEqlistEntry>(
        message as WolfxEqlistMessage,
      ).map(({ entry }) => normalizeJmaEqlistEntry(entry));
  }
}

function sourceFromMessage(message: unknown): WolfxSourceId | null {
  if (!message || typeof message !== "object" || !("type" in message)) {
    return null;
  }
  const type = (message as { type?: unknown }).type;
  return typeof type === "string" &&
    EEW_SOURCES.includes(type as WolfxSourceId)
    ? (type as WolfxSourceId)
    : null;
}

function determineReason(
  event: NormalizedEvent,
  previous: NormalizedEvent | null,
): NotifyReason | null {
  if (event.isTraining) return previous === null ? "training" : null;
  if (event.kind === "report") return previous === null ? "report" : null;
  if (event.isCancel) return previous?.isCancel ? null : "cancelled";
  if (previous === null) return "new";
  if (event.isFinal && !previous.isFinal) return "final";
  if (event.serial > previous.serial) return "updated";
  return null;
}

async function getEvent(
  db: D1Database,
  id: string,
): Promise<NormalizedEvent | null> {
  const row = await db
    .prepare("SELECT * FROM events WHERE id = ?")
    .bind(id)
    .first<EventRow>();
  return row ? rowToEvent(row) : null;
}

async function upsertEvent(
  db: D1Database,
  event: NormalizedEvent,
): Promise<NormalizedEvent | null> {
  const previous = await getEvent(db, event.id);
  const now = new Date().toISOString();
  const eventWrite = db
    .prepare(
      `INSERT INTO events (
        id, source_id, event_id, serial, kind, origin_time_utc,
        report_time_utc, hypocenter, latitude, longitude, magnitude, depth,
        max_intensity, is_warn, is_final, is_cancel, is_training, tsunami,
        raw_json, first_seen_utc, last_updated_utc
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        serial = excluded.serial,
        origin_time_utc = excluded.origin_time_utc,
        report_time_utc = excluded.report_time_utc,
        hypocenter = excluded.hypocenter,
        latitude = excluded.latitude,
        longitude = excluded.longitude,
        magnitude = excluded.magnitude,
        depth = excluded.depth,
        max_intensity = excluded.max_intensity,
        is_warn = excluded.is_warn,
        is_final = excluded.is_final,
        is_cancel = excluded.is_cancel,
        is_training = excluded.is_training,
        tsunami = excluded.tsunami,
        raw_json = excluded.raw_json,
        last_updated_utc = excluded.last_updated_utc`,
    )
    .bind(
      event.id,
      event.sourceId,
      event.eventId,
      event.serial,
      event.kind,
      event.originTimeUtc,
      event.reportTimeUtc,
      event.hypocenter,
      event.latitude,
      event.longitude,
      event.magnitude,
      event.depth,
      event.maxIntensity,
      event.isWarn ? 1 : 0,
      event.isFinal ? 1 : 0,
      event.isCancel ? 1 : 0,
      event.isTraining ? 1 : 0,
      event.tsunami,
      null,
      now,
      now,
    );
  await eventWrite.run();
  return previous;
}

function isValidSources(value: unknown): value is WolfxSourceId[] {
  return (
    Array.isArray(value) &&
    value.every(
      (source) =>
        typeof source === "string" &&
        (ALL_WOLFX_SOURCES as string[]).includes(source),
    )
  );
}

function haversineDistanceKm(
  lat1: number,
  lon1: number,
  lat2: number,
  lon2: number,
): number {
  const radians = (degrees: number) => (degrees * Math.PI) / 180;
  const dLat = radians(lat2 - lat1);
  const dLon = radians(lon2 - lon1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(radians(lat1)) *
      Math.cos(radians(lat2)) *
      Math.sin(dLon / 2) ** 2;
  return 6371 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

function isQuietHours(offsetMinutes: number): boolean {
  const local = new Date(Date.now() + offsetMinutes * 60_000);
  const hour = local.getUTCHours();
  return hour >= 22 || hour < 7;
}

function shouldNotify(
  device: DeviceRecord,
  event: NormalizedEvent,
  reason: NotifyReason,
): boolean {
  if (!device.sources.includes(event.sourceId)) return false;
  if (event.isTraining && !device.includeTestAlerts) return false;
  if ((event.magnitude ?? 0) < device.minMagnitude) return false;
  if (
    reason === "report" &&
    !device.notifyAtNight &&
    device.utcOffsetMinutes != null &&
    isQuietHours(device.utcOffsetMinutes)
  ) {
    return false;
  }
  if (
    device.radiusKm != null &&
    device.latitude != null &&
    device.longitude != null
  ) {
    if (event.latitude == null || event.longitude == null) return false;
    return (
      haversineDistanceKm(
        device.latitude,
        device.longitude,
        event.latitude,
        event.longitude,
      ) <= device.radiusKm
    );
  }
  return true;
}

function base64URL(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary)
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");
}

function utf8Base64URL(value: string): string {
  return base64URL(new TextEncoder().encode(value));
}

async function createApnsJWT(env: Env): Promise<string> {
  if (!env.APNS_PRIVATE_KEY || !env.APNS_KEY_ID || !env.APNS_TEAM_ID) {
    throw new Error("APNs credentials are not configured");
  }
  const keyBytes = Uint8Array.from(
    atob(
      env.APNS_PRIVATE_KEY.replace(/-----BEGIN PRIVATE KEY-----/, "")
        .replace(/-----END PRIVATE KEY-----/, "")
        .replace(/\s/g, ""),
    ),
    (character) => character.charCodeAt(0),
  );
  const key = await crypto.subtle.importKey(
    "pkcs8",
    keyBytes,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const header = utf8Base64URL(
    JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID }),
  );
  const claims = utf8Base64URL(
    JSON.stringify({
      iss: env.APNS_TEAM_ID,
      iat: Math.floor(Date.now() / 1000),
    }),
  );
  const unsigned = `${header}.${claims}`;
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(unsigned),
  );
  return `${unsigned}.${base64URL(new Uint8Array(signature))}`;
}

function buildPushPayload(
  event: NormalizedEvent,
  reason: NotifyReason,
  useCritical: boolean,
): Record<string, unknown> {
  const keys = LOC_KEYS[reason];
  const sourceLabel = SOURCE_LABEL[event.sourceId] ?? event.sourceId;
  const severe =
    reason !== "cancelled" &&
    reason !== "training" &&
    (event.magnitude ?? 0) >= 5.5;
  return {
    aps: {
      alert: {
        "title-loc-key": keys.title,
        "title-loc-args": [sourceLabel],
        "loc-key": keys.body,
        "loc-args": [
          event.hypocenter || sourceLabel,
          event.magnitude?.toFixed(1) ?? "--",
          event.maxIntensity ?? "--",
        ],
      },
      sound:
        useCritical && severe
          ? { critical: 1, name: "default", volume: 1 }
          : "default",
      "interruption-level":
        reason === "training"
          ? "active"
          : useCritical && severe
            ? "critical"
            : "time-sensitive",
      "relevance-score":
        reason === "cancelled" || reason === "training" ? 0.3 : 1,
      category: reason === "training" ? "EEW_TRAINING" : "EEW_ALERT",
    },
    eventId: event.eventId,
    sourceId: event.sourceId,
    kind: event.kind,
    reason,
    magnitude: event.magnitude,
    maxIntensity: event.maxIntensity,
    latitude: event.latitude,
    longitude: event.longitude,
    originTimeUtc: event.originTimeUtc,
  };
}

async function sendPush(
  env: Env,
  device: DeviceRecord,
  event: NormalizedEvent,
  reason: NotifyReason,
): Promise<void> {
  const token = await createApnsJWT(env);
  const host =
    device.environment === "sandbox"
      ? "api.sandbox.push.apple.com"
      : "api.push.apple.com";
  const response = await fetch(
    `https://${host}/3/device/${encodeURIComponent(device.token)}`,
    {
      method: "POST",
      headers: {
        authorization: `bearer ${token}`,
        "apns-topic": env.APNS_BUNDLE_ID ?? "com.quakesignal.app",
        "apns-push-type": "alert",
        "apns-priority": "10",
        "content-type": "application/json",
      },
      body: JSON.stringify(
        buildPushPayload(
          event,
          reason,
          device.criticalAlertsEnabled,
        ),
      ),
    },
  );
  if (!response.ok) {
    const body = await response.text();
    throw new Error(`APNs ${response.status}: ${body || response.statusText}`);
  }
}

async function dispatchPushes(
  env: Env,
  event: NormalizedEvent,
  reason: NotifyReason,
): Promise<void> {
  if (!env.APNS_PRIVATE_KEY || !env.APNS_KEY_ID || !env.APNS_TEAM_ID) return;
  const rows = await env.DB.prepare("SELECT * FROM devices").all<DeviceRow>();
  const devices = rows.results
    .map(rowToDevice)
    .filter((device) => shouldNotify(device, event, reason));
  await Promise.allSettled(
    devices.map((device) => sendPush(env, device, event, reason)),
  );
}

export class QuakeRelay {
  private readonly state: DurableObjectState;
  private readonly env: Env;
  private readonly upstreams = new Map<UpstreamRoute, WebSocket>();
  private readonly statuses = new Map<WolfxSourceId, string>();

  constructor(state: DurableObjectState, env: Env) {
    this.state = state;
    this.env = env;
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    await this.ensureStarted();

    if (url.pathname === "/status") {
      return Response.json({
        ok: true,
        mode: "notification-only",
        upstreams: Object.fromEntries(
          ALL_WOLFX_SOURCES.map((source) => [
            source,
            this.statuses.get(source) ?? "connecting",
          ]),
        ),
      });
    }
    return Response.json({ error: "not found" }, { status: 404 });
  }

  async alarm(): Promise<void> {
    try {
      await this.seedFromHttp();
      this.ensureUpstreams();
    } finally {
      await this.state.storage.setAlarm(Date.now() + 60_000);
    }
  }

  private async ensureStarted(): Promise<void> {
    this.ensureUpstreams();
    const alarm = await this.state.storage.getAlarm();
    if (alarm === null) {
      await this.seedFromHttp();
      await this.state.storage.setAlarm(Date.now() + 60_000);
    }
  }

  private ensureUpstreams(): void {
    for (const route of UPSTREAM_ROUTES) {
      const current = this.upstreams.get(route);
      if (current && (current.readyState === 0 || current.readyState === 1)) {
        continue;
      }
      this.connect(route);
    }
  }

  private connect(route: UpstreamRoute): void {
    this.setRouteStatus(route, "connecting");
    const socket = new WebSocket(`${WS_BASE}/${route}`);
    this.upstreams.set(route, socket);

    socket.addEventListener("open", () => {
      this.setRouteStatus(route, "open");
      const queries =
        route === "all_eew"
          ? [
              "query_jmaeew",
              "query_sceew",
              "query_cenceew",
              "query_fjeew",
              "query_cqeew",
            ]
          : route === "cenc_eqlist"
            ? ["query_cenceqlist"]
            : ["query_jmaeqlist"];
      for (const query of queries) socket.send(query);
    });
    socket.addEventListener("message", (event) => {
      if (typeof event.data !== "string") return;
      try {
        const message: unknown = JSON.parse(event.data);
        if (isHeartbeat(message) || isPong(message)) return;
        const source =
          route === "all_eew"
            ? sourceFromMessage(message)
            : route;
        if (!source) return;
        for (const normalized of normalizeMessages(source, message)) {
          void this.ingest(normalized, false);
        }
      } catch (error) {
        console.warn(`Unable to handle ${route} message`, error);
      }
    });
    socket.addEventListener("close", () => {
      this.setRouteStatus(route, "closed");
      this.upstreams.delete(route);
      void this.state.storage.setAlarm(Date.now() + 1_000);
    });
    socket.addEventListener("error", () => {
      this.setRouteStatus(route, "error");
    });
  }

  private setRouteStatus(route: UpstreamRoute, status: string): void {
    const sources: WolfxSourceId[] =
      route === "all_eew" ? EEW_SOURCES : [route];
    for (const source of sources) this.statuses.set(source, status);
  }

  private async seedFromHttp(): Promise<void> {
    await Promise.all(
      ALL_WOLFX_SOURCES.map(async (source) => {
        try {
          const response = await fetch(`${HTTP_BASE}/${source}.json`);
          if (!response.ok) return;
          const message: unknown = await response.json();
          for (const event of normalizeMessages(source, message)) {
            await this.ingest(event, true);
          }
        } catch (error) {
          console.warn(`Unable to seed ${source}`, error);
        }
      }),
    );
  }

  private async ingest(
    event: NormalizedEvent,
    isBackfill: boolean,
  ): Promise<void> {
    const previous = await upsertEvent(this.env.DB, event);
    if (isBackfill) return;
    const reason = determineReason(event, previous);
    if (!reason) return;

    await dispatchPushes(this.env, event, reason);
  }
}

async function handleDeviceRegistration(
  request: Request,
  env: Env,
): Promise<Response> {
  let body: Record<string, unknown>;
  try {
    body = (await request.json()) as Record<string, unknown>;
  } catch {
    return json({ error: "invalid JSON body" }, 400);
  }
  const token = body.token;
  if (typeof token !== "string" || token.length < 10) {
    return json({ error: "token is required" }, 400);
  }
  const sources = isValidSources(body.sources)
    ? body.sources
    : ALL_WOLFX_SOURCES;
  const environment = body.environment === "sandbox" ? "sandbox" : "production";
  const now = new Date().toISOString();
  await env.DB.prepare(
    `INSERT INTO devices (
      token, environment, locale, sources, min_magnitude,
      critical_alerts_enabled, city_name, latitude, longitude, radius_km,
      include_test_alerts, utc_offset_minutes, notify_at_night, created_at,
      updated_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(token) DO UPDATE SET
      environment = excluded.environment,
      locale = excluded.locale,
      sources = excluded.sources,
      min_magnitude = excluded.min_magnitude,
      critical_alerts_enabled = excluded.critical_alerts_enabled,
      city_name = excluded.city_name,
      latitude = excluded.latitude,
      longitude = excluded.longitude,
      radius_km = excluded.radius_km,
      include_test_alerts = excluded.include_test_alerts,
      utc_offset_minutes = excluded.utc_offset_minutes,
      notify_at_night = excluded.notify_at_night,
      updated_at = excluded.updated_at`,
  )
    .bind(
      token,
      environment,
      typeof body.locale === "string" ? body.locale : null,
      JSON.stringify(sources),
      typeof body.minMagnitude === "number" ? body.minMagnitude : 0,
      body.criticalAlertsEnabled ? 1 : 0,
      typeof body.cityName === "string" ? body.cityName : null,
      typeof body.latitude === "number" ? body.latitude : null,
      typeof body.longitude === "number" ? body.longitude : null,
      typeof body.radiusKm === "number" ? body.radiusKm : null,
      body.includeTestAlerts ? 1 : 0,
      typeof body.utcOffsetMinutes === "number"
        ? body.utcOffsetMinutes
        : null,
      body.notifyAtNight === false ? 0 : 1,
      now,
      now,
    )
    .run();
  const row = await env.DB.prepare("SELECT * FROM devices WHERE token = ?")
    .bind(token)
    .first<DeviceRow>();
  return json(row ? rowToDevice(row) : { error: "registration failed" }, 201);
}

async function handleRequest(
  request: Request,
  env: Env,
  context: ExecutionContext,
): Promise<Response> {
  if (request.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  const url = new URL(request.url);
  const relay = env.RELAY.get(env.RELAY.idFromName("global"));
  context.waitUntil(relay.fetch("https://relay.internal/status"));

  if (url.pathname === "/") {
    return json({
      name: "QuakeSignal Notification Service",
      runtime: "Cloudflare Workers + Durable Objects + D1",
      purpose: "APNs alert delivery only",
      earthquakeData: "Clients fetch directly from Wolfx",
      health: "/healthz",
    });
  }
  if (url.pathname === "/privacy" && request.method === "GET") {
    return legalPage(
      "Privacy Policy",
      "QuakeSignal is designed to collect only the information required to provide location-aware earthquake notifications.",
      [
        {
          heading: "Data we process",
          body: "If you enable notifications, the service stores the APNs device token, app locale, selected earthquake sources, magnitude threshold, notification preferences, and either your selected city's coordinates or your approximate device coordinates and alert radius. The app does not require an account, name, email address, contacts, photos, or advertising identifier.",
        },
        {
          heading: "How data is used",
          body: "Subscription data is used only to decide whether an earthquake event matches your preferences and to send the requested Apple Push Notification. Location is not used for advertising, profiling, or sale.",
        },
        {
          heading: "Storage and deletion",
          body: "Subscription settings are stored in Cloudflare D1. Removing notification registration from the app deletes the matching device token. You can also stop all collection by disabling notifications and location access in iOS Settings.",
        },
        {
          heading: "Third-party services",
          body: "The app fetches earthquake information directly from the Wolfx Open API. Cloudflare is used only to store notification subscriptions, watch upstream alerts, and request delivery through Apple Push Notification service. Their handling of network metadata is governed by their own policies.",
        },
        {
          heading: "Safety notice",
          body: "QuakeSignal is not an official government warning platform. Data and notifications can be delayed, incomplete, or inaccurate. Follow official announcements and local emergency instructions.",
        },
      ],
    );
  }
  if (url.pathname === "/terms" && request.method === "GET") {
    return legalPage(
      "Terms of Use",
      "By using QuakeSignal, you acknowledge the limitations of third-party earthquake data and mobile notification delivery.",
      [
        {
          heading: "Informational service",
          body: "QuakeSignal provides aggregated earthquake information and preparedness guidance for general informational purposes. It is not an official emergency warning system and does not replace government alerts, emergency services, or professional advice.",
        },
        {
          heading: "No delivery guarantee",
          body: "Earthquake data may be revised or cancelled. Internet connectivity, upstream providers, Cloudflare, Apple Push Notification service, iOS settings, Focus modes, and device state can delay or prevent delivery.",
        },
        {
          heading: "Your responsibility",
          body: "Use official sources for authoritative information and follow local emergency instructions. Do not rely on QuakeSignal as the sole basis for safety-critical decisions.",
        },
        {
          heading: "Open-source software",
          body: "The application source is offered under the MIT License. These service terms do not expand the warranties or liabilities in that license.",
        },
      ],
    );
  }
  if (url.pathname === "/support" && request.method === "GET") {
    return legalPage(
      "Support",
      "Get help with notifications, data sources, localization, or earthquake subscription settings.",
      [
        {
          heading: "Before reporting a problem",
          body: "Confirm that notifications and location access are enabled in iOS Settings, your selected source and magnitude threshold match the event, and the device has a working network connection.",
        },
        {
          heading: "Report an issue",
          body: "Open a GitHub issue with your app version, iOS version, language, selected data source, and a description of what happened. Never include an APNs device token or precise home address.",
        },
      ],
    );
  }
  if (url.pathname === "/healthz" && request.method === "GET") {
    const response = await relay.fetch("https://relay.internal/status");
    return json(await response.json());
  }
  if (
    url.pathname === "/v1/live" ||
    url.pathname === "/v1/quakes/recent" ||
    url.pathname.startsWith("/v1/quakes/")
  ) {
    return json({
      error: "earthquake data endpoints are disabled; fetch directly from Wolfx",
    }, 410);
  }
  if (url.pathname === "/v1/devices" && request.method === "POST") {
    return handleDeviceRegistration(request, env);
  }
  if (
    url.pathname.startsWith("/v1/devices/") &&
    request.method === "DELETE"
  ) {
    const token = decodeURIComponent(
      url.pathname.slice("/v1/devices/".length),
    );
    await env.DB.prepare("DELETE FROM devices WHERE token = ?")
      .bind(token)
      .run();
    return new Response(null, { status: 204, headers: corsHeaders });
  }
  if (
    url.pathname.startsWith("/v1/devices/") &&
    url.pathname.endsWith("/test") &&
    request.method === "POST"
  ) {
    const token = decodeURIComponent(
      url.pathname.slice("/v1/devices/".length, -"/test".length),
    );
    const row = await env.DB.prepare("SELECT * FROM devices WHERE token = ?")
      .bind(token)
      .first<DeviceRow>();
    if (!row) return json({ error: "device not found" }, 404);
    if (!env.APNS_PRIVATE_KEY || !env.APNS_KEY_ID || !env.APNS_TEAM_ID) {
      return json({ error: "APNs credentials are not configured" }, 503);
    }
    const now = new Date().toISOString();
    const event: NormalizedEvent = {
      id: "test:0",
      sourceId: rowToDevice(row).sources[0] ?? "jma_eew",
      eventId: "TEST-EVENT",
      serial: 1,
      kind: "eew",
      originTimeUtc: now,
      reportTimeUtc: now,
      hypocenter: "Test Region",
      latitude: 35,
      longitude: 135,
      magnitude: 5.5,
      depth: 10,
      maxIntensity: "5-",
      isWarn: true,
      isFinal: false,
      isCancel: false,
      isTraining: false,
      tsunami: null,
      raw: null,
    };
    await sendPush(env, rowToDevice(row), event, "new");
    return json({ ok: true });
  }
  return json({ error: "not found" }, 404);
}

export default {
  fetch: handleRequest,
};
