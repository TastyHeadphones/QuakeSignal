# Legacy local Node notification-service harness

> [!WARNING]
> This `backend/` Node service is retained only for local development and
> historical compatibility. It is **not** a release component and must never
> receive a production APNs key, host the public iOS API, or be used for
> TestFlight/App Store delivery. The release notification service is the
> Cloudflare Worker in [`cloudflare/`](cloudflare/), deployed only through the
> protected GitHub Actions workflow described in
> [`docs/CLOUDFLARE_PRODUCTION.md`](../docs/CLOUDFLARE_PRODUCTION.md) and
> [`docs/RELEASE_SECRETS.md`](../docs/RELEASE_SECRETS.md).

This local harness holds persistent WebSocket connections to the [Wolfx Open
API](https://wolfx.jp) (JMA / CENC / Sichuan / Fujian / Chongqing earthquake
early-warning + earthquake-list feeds) and exposes a development HTTP API. It
is useful for local client development, but it has none of the production
Cloudflare Worker controls: approved `workers.dev` public TLS, App Attest
enforcement, native rate-limit bindings, durable outbox/Queue delivery, or
protected secret handling.

It is not an application-data backend. iOS and desktop clients fetch history
and foreground live updates directly from Wolfx. In a release, Cloudflare alone
stores notification preferences, evaluates alert rules, and sends APNs
notifications. See [`docs/WOLFX_API.md`](../docs/WOLFX_API.md) for the upstream
data contracts.

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
- An Apple Developer Program membership (for APNs + the Push Notifications
  and production App Attest capabilities)

## Production release service: Cloudflare Worker

The only production notification origin is
[`https://quakesignal-api.hopeso.workers.dev`](https://quakesignal-api.hopeso.workers.dev).
This is UniSphereco LLC's approved public `workers.dev` release endpoint. Debug
still fails closed until its owner supplies an isolated staging Worker, and a
Release build never falls back to a Debug/staging origin. Cloudflare serves the
approved origin with normal public Web PKI TLS; it needs no Custom Domain, DNS
zone, private CA, Cloudflare origin certificate, or client mTLS configuration.

The implementation lives in [`cloudflare/`](cloudflare/) and uses:

- a Worker for notification registration, legal pages, and health checks;
- one Durable Object with three upstream watcher connections;
- D1 for device subscriptions and internal alert deduplication state;
- Cloudflare Queues for bounded APNs delivery and a dead-letter path;
- Worker secrets for APNs token-based authentication.

For local validation only:

```bash
cd backend/cloudflare
npm install
npm run check
npx wrangler d1 migrations apply quakesignal-production --local
npx wrangler deploy --dry-run
```

The protected **Cloudflare Worker → Run workflow → deploy_production** job on
`main` is the sole normal route for remote D1 migrations and `wrangler deploy`.
It verifies the required APNs secret names plus the App Attest and native
rate-limit release gates, then migrates, deploys, and smoke-tests the exact
approved `workers.dev` production origin. Do not use this Node harness, a
workstation `wrangler deploy`, or a remote migration as a routine production
release.

The one-time first deployment uses the protected workflow's
`bootstrap_testflight=true` input while the reviewer-set
`APP_ATTEST_PRODUCTION_ENFORCED` environment variable is exactly `false`. It
still enforces production App Attest, APNs-secret, approved `workers.dev`
origin, and native rate-limit requirements; it exists only so an unlisted
TestFlight build can validate the real production path. After physical
verification, set the variable to `true` and run the normal launch phase before
public App Review or release.

Before enabling public iOS registration, enable App Attest for
`com.quakesignal.app`, refresh the production provisioning profile, and keep
the Worker in required App Attest enforcement. Debug and Simulator clients must
use a separate staging Worker with no shared production D1, APNs credentials,
or production origin. Complete physical-device APNs/App Attest and TestFlight
APNs tests against the approved `workers.dev` production origin before a public
release.

After that protected workflow succeeds, verify the public deployment:

```bash
npm run test:remote -- https://quakesignal-api.hopeso.workers.dev
```

See [`../docs/CLOUDFLARE_PRODUCTION.md`](../docs/CLOUDFLARE_PRODUCTION.md) for
the Workers.dev TLS/origin policy, required Queues setup, protected GitHub
environment, production APNs test plan, and monitoring requirements. Cloudflare
manages public Web PKI TLS for the approved `workers.dev` origin; do not install
a private CA in the app or use client mTLS for public iOS traffic.

The smoke test requires a healthy notification watcher, verifies the App Store
privacy/support/terms pages, validates registration input, and confirms that
history, detail, and public live-relay routes return `410 Gone`.

### Cloudflare APNs secrets

APNs is mandatory for a notification-capable iOS release. The production
deployment workflow verifies the four Worker secret names before it migrates
or deploys, and `/healthz` is unhealthy until all four exist:

```bash
npx wrangler secret put APNS_PRIVATE_KEY
npx wrangler secret put APNS_KEY_ID
npx wrangler secret put APNS_TEAM_ID
npx wrangler secret put APNS_BUNDLE_ID
```

Paste the complete contents of the Apple `.p8` key for
`APNS_PRIVATE_KEY`. The other values are the associated key ID, Apple
Developer team ID, and iOS bundle identifier. Secrets are never stored in
`wrangler.jsonc`, this Node service's `.env`/`secrets` directory, or committed
to git.

## Setup

```bash
cd backend
cp .env.example .env
npm install
```

### Local-only APNs experiments

For ordinary local development, leave the `APNS_*` entries in `.env` unset.
The harness will run, store local events, and skip push delivery. If a
maintainer deliberately performs a disposable sandbox-only experiment, keep
any temporary credential outside this repository and never set
`APNS_PRODUCTION=true`. Do not create, copy, or place a UniSphereco production
`.p8` key in `backend/secrets/` or `.env`.

Production APNs key creation, recovery storage, and the four Worker secret
names are governed exclusively by the Cloudflare release runbook:
[`docs/RELEASE_SECRETS.md`](../docs/RELEASE_SECRETS.md#cloudflare-production).

### Notification behavior

The public QuakeSignal release sends standard or Time Sensitive
notifications. It does not request, declare, or send Apple Critical Alerts.
That restricted capability must remain disabled unless Apple separately grants
the entitlement and the product, privacy disclosures, and user controls are
reviewed for it.

## Run

```bash
npm run dev        # tsx watch, auto-reload
npm run typecheck  # tsc --noEmit
npm run build       # emit to dist/
npm start           # run the built output
```

The server listens on `PORT` (default 8080) and immediately starts one
WebSocket connection per source in `WOLFX_SOURCES` (defaults to all seven).

### Docker (local-only)

```bash
docker compose up --build
```
Mounts `./data` (SQLite file) and an optional local-only `./secrets` directory
as volumes. Never deploy this Compose service or mount a production APNs key.

## Local development HTTP surface

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/v1/devices` | Register/update a device: `{ token, environment, locale, sources[], minMagnitude, cityName?, latitude?, longitude?, radiusKm?, includeTestAlerts?, utcOffsetMinutes?, notifyAtNight? }` |
| `DELETE` | `/v1/devices` | Unregister a device: `{ token }` in the JSON body |
| `POST` | `/v1/devices/test` | Local-only training-push experiment: `{ token }` in the JSON body |
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
The iOS app quantizes a GPS coordinate to a 0.1° grid before sending it;
the service must never receive an exact device location. Omit all three values
to fall back to magnitude-only filtering.

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
