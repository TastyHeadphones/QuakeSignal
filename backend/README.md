# QuakeSignal Notification Service

An always-on notification watcher: it holds persistent WebSocket connections to the [Wolfx
Open API](https://wolfx.jp) (JMA / CENC / Sichuan / Fujian / Chongqing
earthquake early-warning + earthquake-list feeds), normalizes whatever comes
in, and pushes life-safety alerts to registered iOS devices via Apple Push
Notification service (APNs).

It is not an application-data backend. iOS and desktop clients fetch history
and foreground live updates directly from Wolfx. Cloudflare only stores
notification preferences, evaluates alert rules, and sends APNs notifications.

**Why this exists at all:** iOS does not allow an app to keep a WebSocket
connection open while backgrounded or terminated. There is no way to get a
"the ground is about to shake" alert to a phone that isn't in the foreground
without a server-side watcher pushing through APNs. This service is that watcher.
See [`docs/WOLFX_API.md`](../docs/WOLFX_API.md) for the upstream data
contracts it depends on.

## Architecture

```text
Wolfx HTTP + WebSockets ---> normalize + deduplicate ---> notification rules
                                                             |          |
                                                      D1 preferences    APNs
                                                                        |
                                                               background iOS

Wolfx HTTP + WebSockets --------------------------------> foreground iOS
                                                   (direct client access)
```

## Prerequisites

- Node.js 20+
- An Apple Developer Program membership (for APNs + Push Notifications
  capability + optionally the Critical Alerts entitlement)

## Cloudflare production deployment

The production implementation is deployed at
[`quakesignal-api.hopeso.workers.dev`](https://quakesignal-api.hopeso.workers.dev).
It lives in [`cloudflare/`](cloudflare/) and uses
only services available on Cloudflare's free plan for a small launch:

- a Worker for notification registration, legal pages, and health checks;
- one Durable Object with three upstream watcher connections;
- D1 for device subscriptions and internal alert deduplication state;
- Worker secrets for APNs token-based authentication.

```bash
cd backend/cloudflare
npm install
npx wrangler login
npx wrangler d1 create quakesignal-production
# Put the returned database_id in wrangler.jsonc.
npx wrangler d1 migrations apply quakesignal-production --remote
npx wrangler deploy
```

Verify the public deployment:

```bash
npm run test:remote -- https://quakesignal-api.hopeso.workers.dev
```

The smoke test requires a healthy notification watcher, validates registration
input, and confirms that history, detail, and public live-relay routes return
`410 Gone`.

### Cloudflare APNs secrets

APNs is optional for watcher health testing, but required before publishing a
notification-capable iOS build:

```bash
npx wrangler secret put APNS_PRIVATE_KEY
npx wrangler secret put APNS_KEY_ID
npx wrangler secret put APNS_TEAM_ID
npx wrangler secret put APNS_BUNDLE_ID
```

Paste the complete contents of the Apple `.p8` key for
`APNS_PRIVATE_KEY`. The other values are the associated key ID, Apple
Developer team ID, and iOS bundle identifier. Secrets are never stored in
`wrangler.jsonc` or committed to git.

## Setup

```bash
cd backend
cp .env.example .env
npm install
```

### APNs credentials

1. In the [Apple Developer portal](https://developer.apple.com/account/resources/authkeys/list),
   create an **APNs Auth Key** (.p8). One key works for both sandbox and
   production. Note the **Key ID** and your **Team ID**.
2. Save the downloaded `AuthKey_<KEYID>.p8` under `backend/secrets/` (this
   folder is gitignored — never commit it).
3. Fill in `.env`:
   ```
   APNS_KEY_PATH=./secrets/AuthKey_XXXXXXXXXX.p8
   APNS_KEY_ID=XXXXXXXXXX
   APNS_TEAM_ID=XXXXXXXXXX
   APNS_BUNDLE_ID=com.quakesignal.app   # must match the iOS app's bundle id
   APNS_PRODUCTION=false                 # true only for TestFlight/App Store builds
   ```
   Without these four values set, the server still runs and stores events —
   it just logs a warning and skips the push step, which is enough to develop
   against the REST API alone.

### Critical Alerts (optional but recommended for this app)

By default, push notifications respect Focus modes and can still be silenced.
For a life-safety app, request the `com.apple.developer.usernotifications.critical-alerts`
entitlement from Apple (Apple grants this case-by-case for apps like public
safety / health / EEW — see the "Request the Critical Alerts entitlement"
link inside the Certificates, Identifiers & Profiles section of the Developer
portal). Until it's approved, the app degrades gracefully to `time-sensitive`
interruption level, which needs no special approval and still breaks through
most Focus filters.

## Run

```bash
npm run dev        # tsx watch, auto-reload
npm run typecheck  # tsc --noEmit
npm run build       # emit to dist/
npm start           # run the built output
```

The server listens on `PORT` (default 8080) and immediately starts one
WebSocket connection per source in `WOLFX_SOURCES` (defaults to all seven).

### Docker

```bash
docker compose up --build
```
Mounts `./data` (SQLite file) and `./secrets` (the .p8 key) as volumes.

## Production HTTP surface

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/v1/devices` | Register/update a device: `{ token, environment, locale, sources[], minMagnitude, criticalAlertsEnabled, cityName?, latitude?, longitude?, radiusKm?, includeTestAlerts?, utcOffsetMinutes?, notifyAtNight? }` |
| `DELETE` | `/v1/devices/:token` | Unregister a device |
| `POST` | `/v1/devices/:token/test` | Send one real push through APNs to this device (Settings screen "send test alert") |
| `GET` | `/healthz` | Notification watcher + per-source connection status |
| `GET` | `/privacy`, `/terms`, `/support` | App Store legal and support pages |

`/v1/quakes/recent`, `/v1/quakes/:id`, and `/v1/live` are intentionally
disabled in production. Clients use Wolfx directly.

`sources` values are any of: `jma_eew`, `sc_eew`, `cenc_eew`, `fj_eew`,
`cq_eew`, `cenc_eqlist`, `jma_eqlist`.

`latitude`/`longitude`/`radiusKm` are optional: if set, push delivery for
that device also requires the event's epicenter to be within `radiusKm` km
(great-circle distance) in addition to clearing `minMagnitude` -- this is
what backs the app's "subscribe to a city, get alerts within N km" setting.
Omit them to fall back to magnitude-only filtering.

## Notes on correctness

- **Dedup/update logic** (`alerts/pipeline.ts`): EEW messages for the same
  `EventID` arrive repeatedly as the estimate refines. A push is sent again
  only when `Serial`/`ReportNum` increases or the event transitions to
  final/cancelled — not on every re-broadcast of unchanged data.
- **Cold-start backfill**: on boot, each source is seeded once via its plain
  HTTP GET endpoint (silently, no push) before the WebSocket takes over, so a
  restart doesn't replay recent history as if it were breaking news.
- **Localization is on-device**: push payloads use APNs `loc-key`/`loc-args`
  pointing at keys in the iOS app's `Localizable.strings`, so this server
  never needs to know a device's language — see `ios/QuakeSignal/Resources/*.lproj/Localizable.strings`
  for the matching keys (`eew.push.new.title`, `eew.push.new.body`, etc.).
