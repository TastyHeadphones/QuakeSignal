# Cloudflare alert-delivery operations

QuakeSignal separates upstream event ingestion from APNs fan-out:

```text
Wolfx watcher Durable Object
        │ D1 transactional outbox
        ▼
quakesignal-alert-delivery Queue ──► bounded Queue consumer ──► relay Durable Object ──► APNs
        │                                      │
        └── after 5 retries ──► quakesignal-alert-delivery-dlq ──► D1 incident record
                                                       │ D1 unavailable
                                                       ▼
                                      token-free Durable Object fallback ──► replay D1 incident
                                                       │ Durable Object unavailable
                                                       ▼
                            quakesignal-alert-delivery-dlq-fallback (consumerless, independent Cron Queue monitor)
```

The Queue messages contain a normalized earthquake snapshot, notification
reason, and an internal SQLite cursor. They never contain an APNs device token.
The consumer has one configured concurrent invocation, and the relay sends at
most two APNs requests concurrently. Confirmed deliveries are recorded for 14 days so a
retry does not intentionally duplicate a particular event revision for a
device; APNs collapse IDs cover the small response/write race.

Live WebSocket events first enter a small Durable Object journal; it coalesces
each event's revisions safely and reports source freshness only after the D1
event and outbox transaction commits. The event revision and its first
`alert_delivery_outbox` row are written in one D1 batch, and its outbox insert
is conditional on no newer committed serial. That same batch retires pending
lower-serial pages; the relay rechecks the authoritative event serial before
each small APNs batch, terminalizing a delayed older Queue page as
`superseded` before it can reach APNs. Before `Queue.send()`, the relay conditionally claims the row in D1,
so concurrent alarms, delivery requests, and health checks cannot duplicate an
event fan-out. Once Queues accepts it, the row receives a 72-hour hand-off
lease while Queues owns its configured five retry attempts and DLQ routing. A
successful delivery or atomically recorded DLQ incident terminally finalizes
the row. This is deliberately at-least-once: a crash between Queue acceptance
and its D1 hand-off timestamp can produce one recovery replay after the short
claim lease, but cannot silently lose a deduplicated alert. Later recipient
pages are durably inserted before their parent message is acknowledged.

The Worker also imports any legacy Durable Object or Queue hand-off found
during this upgrade into the D1 outbox before acknowledging the old copy.

Fresh `new`/`updated` EEW warning work has a ten-minute event/creation deadline.
Reports and meaningful final/cancel lifecycle notices retain a one-hour
nonurgent window; training keeps its separate thirty-minute window. Only a
fresh `isWarn && !isFinal && !isCancel && !isTraining` EEW receives Time
Sensitive interruption and the registration's allow-listed bundled sound
(`system`, `urgent-tone`, or `japanese-voice`). The APNs payload includes a
bounded typed event snapshot and remains below the regular 4 KB payload limit.

All four APNs Worker secrets are mandatory. A missing secret, provider-token,
topic, payload, transport, or APNs-service failure retries the exact outbox
page through the bounded Queue policy and then records a DLQ incident if it
cannot recover. Each APNs request has a 20-second Worker-side timeout; a hung
connection is aborted and follows this same page-level retry/DLQ path. These
page failures are held in
`alert_delivery_page_failures`, never copied into per-device quarantine rows.
`InvalidProviderToken`, `MissingProviderToken`, `TopicDisallowed`, and—in this
single-topic service—`DeviceTokenNotForTopic` therefore remain visible
provider incidents rather than silently suppressing recipients. APNs `429
TooManyRequests` and `BadDeviceToken` remain recipient-scoped; provider-token
update throttling remains page-scoped. An `ExpiredProviderToken` clears the
relay's cached JWT before a later retry. Only an APNs `410` with a valid
invalidation timestamp removes a subscription, and the Worker preserves a
registration refreshed after that timestamp. A malformed 410 is quarantined
instead of risking deletion.

The DLQ consumer has a separate persistence safety boundary. If D1 cannot
store its sanitized incident record, the consumer sends only the queue ID,
attempt count, delivery/event identifiers, notification reason, and outbox ID
to the global Durable Object—never a device token, raw upstream payload, or
event body. It acknowledges the DLQ message only after that Durable Object
write succeeds. The relay retries that marker into the same atomic D1 incident
and terminal-outbox transaction before normal outbox replay; while any marker
exists, `/healthz` returns `503` with
`delivery.pendingDlqPersistenceFallbacks=true`. If both D1 and Durable Object
storage are unavailable, the DLQ message remains retriable. Its bounded DLQ
consumer policy finally routes the original message to the intentionally
consumerless `quakesignal-alert-delivery-dlq-fallback` Queue. Cloudflare Queue
backlog is not available to this Worker, so the separate cron-only
[`terminal-DLQ monitor`](terminal-dlq-monitor/) reads only the Queue's aggregate
Cloudflare metrics and opens one labelled recovery issue on any retained
evidence. Its GitHub Actions counterpart is a best-effort secondary check, not
the sole cadence control. Configure the independent monitor, its heartbeat
alert, and the recovery runbook before Cloudflare's consumerless-DLQ retention
ends; see
[`docs/CLOUDFLARE_PRODUCTION.md`](../../docs/CLOUDFLARE_PRODUCTION.md#terminal-dlq-fallback-recovery).

Each page has a persisted deadline. New, updated, cancelled, and training EEW
work expires after 30 minutes; final EEW and earthquake reports after 60
minutes. The 30-minute EEW envelope leaves one real retry window after APNs'
15-minute 5XX retry floor. APNs itself still receives `apns-expiration: 0`, so
Apple never retains an old emergency alert for an offline device. The deadline
uses the event report/origin timestamp but is never later than the same cap
after durable creation, so future source-clock skew cannot extend retries. An
expired page is terminalized without making an APNs request; its active provider
incident remains visible for review.

## Production origin and first deployment

UniSphereco LLC explicitly approved the public production origin
`https://quakesignal-api.hopeso.workers.dev`. The checked-in production
configuration uses the `quakesignal-api` Worker name, sets `workers_dev=true`,
and deliberately contains no Custom Domain or route. The account used by the
protected production workflow must own the `hopeso.workers.dev` subdomain; do
not substitute another `workers.dev` URL in a Release archive or protected
environment variable. The generated staging configuration and protected
workflow still use a separate staging Worker for physical Debug testing; see
[Isolated Debug staging](#isolated-debug-staging).

This is an intentional public `workers.dev` production endpoint, not an
unconfigured custom-domain fallback. Cloudflare serves it with normal public
Web PKI TLS. Do not create a private CA, ship a private root certificate, use a
Cloudflare origin certificate as a client trust anchor, or add client mTLS to
the public iOS API. Production App Attest and the native Worker rate-limit
bindings are the application-layer controls instead.

Create the named queues once in the Cloudflare account that owns the Worker.
The commands use the account selected by the local Wrangler login, so first run
`npx wrangler whoami` and confirm it is the UniSphereco production account that
owns `hopeso.workers.dev` and `quakesignal-api`. Stop on any mismatch; never
create these production Queues in a previously authenticated personal or
staging account:

```bash
npx wrangler queues create quakesignal-alert-delivery
npx wrangler queues create quakesignal-alert-delivery-dlq
npx wrangler queues create quakesignal-alert-delivery-dlq-fallback
```

The independent cron-only terminal-DLQ monitor is recommended for the exact
consumerless `quakesignal-alert-delivery-dlq-fallback` Queue. The GitHub
Actions monitor remains a secondary check because GitHub can delay or drop
scheduled workflow runs. The production deployment gate does not inspect Queue
depth or Cloudflare dashboard alert wiring. Deploying without the independent
monitor is an explicit acceptance that terminal-Queue backlog or a missed Cron
run may go unnoticed until manual inspection. See
[`docs/CLOUDFLARE_PRODUCTION.md`](../../docs/CLOUDFLARE_PRODUCTION.md#terminal-dlq-fallback-recovery)
for the recovery runbook.

Run the migrations in filename order; the queue/deduplication schema is in
`0002_delivery_retention.sql` and DLQ incident health requires
`0003_dlq_incidents.sql`; the transactional outbox and APNs-quarantine schema
is `0004_transactional_alert_outbox.sql`; the required hand-off lease/DLQ
finalization columns are in `0005_outbox_queue_leases.sql`; App Attest
challenge/key/ownership records are in `0006_app_attest.sql`; and the
one-active-subscription-per-key constraint is in
`0007_unique_app_attest_subscription.sql`. Do not deploy this Worker revision
after applying only the earlier schema. `0008_alert_delivery_reliability.sql`
adds page-level provider-failure health, delivery deadlines, and terminal-outbox
retention. `0009_production_training_test_push_limit.sql` adds the durable,
token-free UTC-day App Attest claim required before a production training test
push. `0010_alert_sound_and_urgent_eew_deadline.sql` adds the exact alert-sound
preference values and the shorter delivery deadline for urgent EEW warnings.
Migrations `0008` through `0010` are required by this Worker revision.

The protected **Cloudflare Worker → Run workflow → deploy_production** job is
the sole normal route for remote D1 migrations and `wrangler deploy`. It runs
the schema in order after validation, checks APNs secret names, deploys, and
smoke-tests `/healthz`, `/privacy`, `/support`, and `/terms` through the exact
approved public `workers.dev` origin. Do not make a routine production release
by running remote migration or deployment commands from a workstation. Its
Cloudflare token needs permission to deploy this Worker, manage its Durable
Object/D1/Queues, and list Worker secret names (not values). A missing secret
name or App Attest gate blocks deployment. The terminal-DLQ monitor remains an
optional operational control rather than a deployment attestation.

The same protected GitHub Environment provides the exact
`CLOUDFLARE_WORKER_URL` and the App Attest review gate; it no longer needs a
zone ID or a zone-WAF ruleset ID. The three native `ratelimits` bindings in
`wrangler.jsonc` remain mandatory and are checked by the workflow's Wrangler
dry run. Before deploying, the production gate uses the Cloudflare API to
confirm that the selected account owns `hopeso.workers.dev`; it does not query
or require a Custom Domain or WAF zone. For the one-time TestFlight bootstrap,
a reviewer sets
`APP_ATTEST_PRODUCTION_ENFORCED=false` and starts the protected workflow with
`bootstrap_testflight=true`; this still deploys the production fail-closed App
Attest verifier and APNs configuration, but does not authorize a public app
release. After physical TestFlight verification, the reviewer changes that
variable to `true` and runs the normal launch phase with the bootstrap input
disabled. The Worker implements the real
one-time Apple App Attest challenge/attestation/assertion protocol—there is no
static client secret. It binds the exact JSON bytes, method, path, and operation
to a five-minute challenge; validates Apple's certificate chain, nonce, RP ID,
AAGUID, credential ID, signature, and monotonic counter; and records the
public key plus replay state transactionally with the device mutation. A valid
key can delete or trigger a training push only for its own subscription. The
reviewed training action has only two client-selected modes: an immediate
alert, or the fixed 90-second delayed TestFlight check. The latter is available
only to an attested production registration and cannot select an arbitrary
delivery time.

An attested deletion may use the exact empty JSON object (`{}`) when the app no
longer has an APNs token. It requires an assertion from a key that already owns
the active subscription, removes only that key's matching delivery and failure
records, and remains idempotent. A fresh key cannot claim a legacy/unbound row
with `{}`; it must carry the exact APNs token or use the support deletion path.
The tokenless shape is never a development-bypass or unauthenticated
capability: without a valid App Attest proof it receives the normal `token is
required` `400` response.

The checked-in Worker configuration is production fail-closed:
`APP_ATTEST_ENFORCEMENT=required`. Do not add
`APP_ATTEST_DEVELOPMENT_BYPASS=true` to a production environment. That bypass
is honored only when a short-lived local test setup explicitly sets both
`APP_ATTEST_ENFORCEMENT=development` and the bypass variable, allowing the
Simulator's documented unsupported-service path without weakening production.
The protected staging configuration intentionally does not set it.
The current App Attest release-metadata extension is optional for valid iOS
17–26 proofs; when Apple supplies it, the Worker requires exactly the approved
TestFlight/App Store category and a version in
`APP_ATTEST_ALLOWED_BUNDLE_VERSIONS`.

## Isolated Debug staging

`staging/wrangler.staging.template.json` is rendered only by
`scripts/render-staging-config.mjs`; do not hand-copy it over `wrangler.jsonc`
or commit a generated configuration. The renderer requires a staging-named
Worker, a separate D1 name/UUID, and three distinct staging rate-limit namespace
IDs. It derives these Queue names from the Worker name:

```text
<staging-worker>-alert-delivery
<staging-worker>-alert-delivery-dlq
<staging-worker>-alert-delivery-dlq-fallback
```

It rejects production D1 and rate-limit IDs, omits routes and Custom Domains,
uses `workers_dev=true`, and passes the derived queue names to the Worker.
The resulting `workers.dev` host is ordinary public Cloudflare TLS, not a
private-CA or mTLS deployment.

Provision the isolated D1 database and all three derived Queues before running the
manual protected **Cloudflare Staging Worker** workflow from protected `main`.
Set its required GitHub Environment variables and a staging-only Cloudflare
token in `cloudflare-staging`; the full table and token restrictions are in
[`docs/RELEASE_SECRETS.md`](../../docs/RELEASE_SECRETS.md#cloudflare-staging).
That workflow renders into `$RUNNER_TEMP`, validates the bundle, applies only
the named staging D1 migrations, and deploys only the staging Worker. It is not
a production deployment route and must receive no production URL, D1 ID, queue
name, APNs secret, or Cloudflare deployment token.

After the first staging deployment, add `APNS_PRIVATE_KEY`, `APNS_KEY_ID`,
`APNS_TEAM_ID`, and `APNS_BUNDLE_ID` as secrets on that Worker itself. They are
separate from the production Worker's secret store and must target the sandbox
APNs credentials/topic for the Debug build. Set the bare staging `workers.dev`
URL in `CLOUDFLARE_STAGING_WORKER_URL`, then rerun the workflow with
`verify_staging_apns=true` to list only secret names and run readiness/smoke
checks. Do not claim staging is ready until that verification succeeds.

The generated configuration uses real development App Attest and does **not**
enable `APP_ATTEST_DEVELOPMENT_BYPASS`, so use it for a physical Debug device.
Copy `ios/QuakeSignal/Supporting/Debug.local.xcconfig.example` to the ignored
`Debug.local.xcconfig`, set only the isolated `https://*.workers.dev` URL, and
run registration, refresh, protected deletion, reinstall/key-rotation, and a
clearly labelled sandbox training-push test. A Simulator bypass belongs only to
an ephemeral local setup and is never a staging, TestFlight, or production
proof. See [`docs/CLOUDFLARE_PRODUCTION.md`](../../docs/CLOUDFLARE_PRODUCTION.md#isolated-debug-staging-worker)
for the release-owner runbook.

`wrangler.jsonc` is the source of truth for the producer binding, consumer
batch/concurrency limits, retry policy, DLQ, and native device-API rate-limit
bindings. The three rate-limit namespace IDs are account-scoped and must remain
unique in the Cloudflare account; keep them stable after the first production
deployment so their counters are not accidentally replaced. Do not add APNs
credentials to that file. Set the four APNs values only as Worker secrets after
saving the one-time Apple `.p8` download in the organisation's approved secret
manager:

As with Queue creation, these interactive commands target the account selected
by the local Wrangler login. Run `npx wrangler whoami` first and verify the
production `hopeso.workers.dev` account before entering a secret. They do not
authorize or replace a workstation production deployment.

```bash
npx wrangler secret put APNS_PRIVATE_KEY
npx wrangler secret put APNS_KEY_ID
npx wrangler secret put APNS_TEAM_ID
npx wrangler secret put APNS_BUNDLE_ID
```

## Operations and privacy

- The DLQ consumer stores sanitized delivery metadata in
  `alert_delivery_incidents` and then acknowledges the DLQ message. It never
  automatically replays an alert. A nonzero active incident count makes
  `/healthz` return `503` with `delivery.status: "degraded"`; resolve the
  incident deliberately in D1 and only then manually redrive an alert if it is
  still safe and useful to do so.
- If that initial DLQ D1 write fails, the Worker retains token-free incident
  evidence in the global Durable Object and acknowledges the DLQ message only
  after that independent durable write. The relay retries it into D1 before
  ordinary outbox replay. Any pending fallback marker makes `/healthz` return
  `503` with `delivery.pendingDlqPersistenceFallbacks=true`; do not delete the
  marker manually. If both D1 and Durable Object storage fail, the original
  DLQ message remains retriable and ultimately enters the consumerless
  `quakesignal-alert-delivery-dlq-fallback` Queue. `/healthz` cannot inspect
  Queue backlog, so monitor that Queue externally and recover its evidence
  before Cloudflare's consumerless-DLQ retention expires. A production
  deployment does not attest that the monitor is deployed or healthy; it does
  not claim to query Queue depth or dashboard alert wiring automatically.
- Active per-device quarantines or transient retry failures also make
  `/healthz` return `503`. They store only a token hash, delivery/event
  metadata, APNs status, and reason; resolve the underlying
  topic/payload/configuration issue and mark the D1 row resolved only after
  review. A later confirmed delivery resolves its matching failure
  automatically.
- Active `alert_delivery_page_failures` also make `/healthz` return `503`.
  They identify provider/topic/payload failure for one alert page without a
  token hash. A successful later page resolves the record; a final DLQ record
  replaces it with the durable DLQ incident. Expiry does not resolve a provider
  failure automatically, because the underlying configuration may still be
  broken.
- `/healthz` is a readiness endpoint: it is route-rate-limited before entering
  the global relay and returns `503` for missing APNs configuration or invalid
  local signing key, a stale pending outbox row,
  DLQ/Durable-Object-persistence-fallback/retry/quarantine incident, or any
  required Wolfx source with neither a current WebSocket nor a current valid
  HTTP-alternate snapshot. After all three WebSocket routes have been degraded
  for 90 seconds, the relay may report `upstream.transport: "http-polling"`
  (with `websocketStatus: "degraded"`) only while every affected source has a
  structurally valid, durably ingested HTTP snapshot less than three minutes
  old. The emergency fallback begins one full sweep of affected sources per
  minute, with individual source requests at least 600 ms apart. It accepts
  only fresh revisions inside the existing 10-minute alert window and never
  turns a historical backfill into an alert. On the Workers Free plan,
  Cloudflare currently allows 100,000 Durable Object rows written per day. To
  stay within a routine budget, healthy WebSocket and emergency HTTP freshness
  checkpoints are each written at most once per source per minute. Repeated
  unchanged ranked earthquake-list WebSocket frames are committed through one
  bounded snapshot cursor and then deduplicated by a post-D1 fingerprint, so
  they do not create one journal row per list entry. Each list source holds at
  most an active cursor plus two newer accepted snapshots. The third distinct
  frame is made durable before it marks the source overloaded and `/healthz`
  fails closed; only then does the relay close that list socket. Later frames
  after explicit backpressure are not admitted, so the path remains bounded
  rather than spending one write per frame. The relay drains active → latest →
  overflow before a fresh complete resync can clear the overload marker. This
  guarantees durability for frames admitted before the close; it cannot turn a
  finite relay window into an upstream replay log, so health remains failed
  closed until that resync. A bare WebSocket Upgrade does not reset reconnect backoff or
  publish freshness; only valid Wolfx traffic does, and a route must stay live
  for one minute before its exponential reconnect history is cleared. This is
  not an unlimited-capacity claim: unusual sustained changed-event, reconnect, or recovery
  activity can still exhaust the quota. Monitor Durable Object usage; a failed
  durable checkpoint is not treated as fresh and the three-minute stale policy
  makes `/healthz` fail closed.
- Keep `ENABLE_PRODUCTION_TEST_PUSH=false` unless a reviewed delayed
  background-training exercise explicitly requires the InternalQA scheduler.
  The ordinary foreground **Send Test Alert** remains available to an active,
  attested production registration while the flag is false. An existing App
  Attest key may make exactly one **clearly labelled training/drill** push to
  its owned production subscription per UTC calendar day. The Worker atomically
  consumes the one-time App Attest
  assertion/counter and D1 claim before it contacts APNs. A second valid request
  receives `429`, `Cache-Control: no-store`, an exact `Retry-After` to the next
  UTC midnight, and `retryAtUtc`; an APNs failure after a claim still consumes
  that day's single outbound training attempt. The claim retains only the
  opaque App Attest key ID and UTC timestamps—never an APNs token, proof, or
  request body—and is purged after 14 days. The always-available immediate and
  flag-gated delayed modes share this same claim. The delayed mode stores only the opaque key ID, due
  time, and at-most-once state in a private per-key Durable Object; it rechecks
  the current D1 ownership and the production flag before APNs, drops jobs more
  than 30 seconds late, and never retries an APNs result.
- Device registrations are refreshed by the client and expire after 90 days.
  The relay's daily maintenance pass removes stale registrations and matching
  delivery records, plus orphaned App Attest key, public verifier, receipt,
  counter, and challenge records. Expired App Attest challenges are deleted
  within five minutes; when the last registration for a key is removed, that
  integrity record is deleted too. The separate token-free production-training
  claim retains its opaque App Attest key ID for up to 14 days. It also removes 14-day
  delivery-deduplication records, resolved page-failure evidence, terminal
  outbox snapshots, and delivery-failure token hashes after 14 days.
- Device APIs use JSON request bodies and `Cache-Control: no-store`; there is
  intentionally no permissive browser CORS policy. Native iOS networking is
  unaffected. Before parsing device bodies, `DEVICE_API_RATE_LIMIT` allows at
  most 300 requests/minute for each method/path at a Cloudflare location,
  including `GET /healthz` before the relay is activated.
  `DEVICE_MUTATION_RATE_LIMIT` then allows at most 8 requests/minute for each
  method/path plus SHA-256-derived App Attest key ID and/or bounded APNs token
  during the App Attest rollout. Before challenge-body parsing, the dedicated
  `APP_ATTEST_CHALLENGE_RATE_LIMIT` also allows at most 60 requests/minute for
  the fixed `POST /v1/app-attest/challenge` route key, so a caller cannot evade
  its D1-write budget by rotating a proposed key ID. Rate-limit logs contain only the route and
  actor category, never a raw key, token, or IP address. A quota or binding
  failure returns a `429` with `Cache-Control: no-store` and fails the public
  mutation closed. These native counters are per-location and eventually
  consistent, so they are defense in depth alongside the required one-time App
  Attest verification. Do not replace them with a client-shipped static
  secret.
- App Attest proofs, certificates, receipts, APNs tokens, raw locations, and
  assertion bodies are never returned or logged. While a registration is
  active, the database retains only the opaque App Attest key identifier,
  public verification key, Apple receipt, counter, integrity timestamps, and
  any Apple-supplied release category/version needed to prevent replay. The
  verifier pins Apple's public App Attestation trust chain. This is independent
  of the normal public TLS certificate Cloudflare manages for the Worker; no
  private CA or client mTLS certificate is used.
- App Attest keys legitimately rotate after reinstall or device restore. A
  freshly verified production attestation that supplies the exact APNs token
  may atomically rebind that one token and retire its old key record. Assertion
  requests and tokenless deletes cannot transfer another key's subscription;
  if APNs has not supplied the token, use the support deletion path.
