# Cloudflare production and Debug staging runbook

QuakeSignal uses Cloudflare only for opt-in iOS alert subscriptions and APNs
delivery. The iOS and desktop clients obtain earthquake data directly from the
Wolfx Open API; the Cloudflare Worker is not a public earthquake-data relay.

## Production origin, TLS, and certificate authority

UniSphereco LLC explicitly approved the public production notification origin
`https://quakesignal-api.hopeso.workers.dev`. The checked-in
`wrangler.jsonc` uses the `quakesignal-api` Worker name, sets
`workers_dev=true`, and deliberately has no Custom Domain or route. The
protected production workflow must use the Cloudflare account that owns the
`hopeso.workers.dev` subdomain; `CLOUDFLARE_WORKER_URL` must be exactly the
approved URL. Debug uses a separate, generated `workers.dev` staging Worker;
it is not interchangeable with this release origin and must never be placed in
a Release archive, App Store URL, or production environment variable.

This is an intentional public `workers.dev` production endpoint, not a
temporary custom-domain fallback. Cloudflare serves `workers.dev` over normal
public Web PKI TLS, so there is no DNS-zone, Custom Domain, private CA,
Cloudflare origin certificate, private root, or client-mTLS prerequisite. Do
**not** add a client certificate to the iOS app. iOS App Transport Security and
the Worker-to-APNs connection use normal public Web PKI trust. Production App
Attest plus the native Worker rate-limit bindings provide the required
application-instance and abuse controls for public launch.

## Isolated Debug staging Worker

The protected **Cloudflare Staging Worker** workflow creates the configuration
for the physical Debug test service from
[`backend/cloudflare/staging/wrangler.staging.template.json`](../backend/cloudflare/staging/wrangler.staging.template.json).
It is deliberately separate from production: a staging-named Worker with
`workers_dev=true`, its own D1 database, three derived Queue names, three distinct
account-unique rate-limit namespace IDs, and no routes or Custom Domain. The
`workers.dev` endpoint receives ordinary Cloudflare-managed public TLS. Do not
create a private CA, add a private root to an iPhone, use a Cloudflare origin
certificate as a client trust anchor, or use client mTLS.

Before a first staging deployment, a UniSphereco LLC release owner must verify
that the selected Cloudflare account is authorized for this service and create
the separate D1 database plus its three derived Queues. Add the account, resource
ID/name, rate-limit-ID, and staging URL values only to the protected
`cloudflare-staging` GitHub Environment. Do not add production credentials or
resource IDs to it. The complete variable list, token scope, and first-deploy
order are in [`RELEASE_SECRETS.md`](RELEASE_SECRETS.md#cloudflare-staging).
Nothing in this repository asserts that those account resources or environment
values have already been configured.

The generated Worker accepts development App Attest only when both
`APP_ATTEST_ENFORCEMENT=development` and
`APP_ATTEST_DEVELOPMENT_ENVIRONMENT=true` are present. It does not set the
simulator bypass variable. Thus, a successful physical Debug registration proves
real Apple development attestation, and a successful labelled sandbox training
notification proves sandbox APNs; a simulator result is not equivalent. Start
the protected workflow on protected `main` with
`deploy_staging=true`; after staging APNs secrets have been added to that
Worker, set its bare `https://*.workers.dev` URL and rerun with
`verify_staging_apns=true` for the APNs-name/readiness and remote-smoke phase.

For the device under test, copy
[`ios/QuakeSignal/Supporting/Debug.local.xcconfig.example`](../ios/QuakeSignal/Supporting/Debug.local.xcconfig.example)
to the ignored `Debug.local.xcconfig` and set only the resulting staging
`https://*.workers.dev` URL. Leave the checked-in fail-closed
`https://quakesignal-staging.invalid` default in place for everyone else.
Build a development-signed Debug app on physical hardware, opt in to
notifications, register, refresh the token, remove the registration with both
the token and the key-owned empty-object path where applicable, then exercise a
clearly labelled sandbox training notification. Test reinstall/key rotation as
well. Record the evidence, but do not treat it as TestFlight or App Store
release evidence; repeat the production proof against
`https://quakesignal-api.hopeso.workers.dev`.

## Production deployment order

1. Renew the UniSphereco LLC Apple Developer Program membership.
2. Confirm that the Cloudflare account selected for production owns the
   `hopeso.workers.dev` subdomain and can publish the `quakesignal-api` Worker.
   The user-approved public origin is exactly
   `https://quakesignal-api.hopeso.workers.dev`; there is no Custom Domain,
   route, DNS zone, or zone-WAF prerequisite. After the protected deployment,
   verify its public Cloudflare TLS and `GET /healthz` at that exact URL.
3. Create all three Cloudflare Queue resources named in
   [`backend/cloudflare/wrangler.jsonc`](../backend/cloudflare/wrangler.jsonc)
   before deploying the queue-enabled Worker: the primary delivery Queue, its
   DLQ, and the intentionally consumerless
   `quakesignal-alert-delivery-dlq-fallback` terminal-evidence Queue. Use a
   Workers plan that supports the expected alert volume and add billing/usage
   alerts. The checked-in **Monitor terminal DLQ fallback** workflow runs every
   five minutes and can also be dispatched manually. It uses the separate,
   least-privilege `cloudflare-terminal-dlq-monitor` Environment to list the
   exact Queue and read its aggregate Cloudflare metrics; it never reads, logs,
   acknowledges, retries, purges, or redrives Queue messages. A nonzero backlog
   or oldest-message timestamp opens or updates one labelled GitHub recovery
   issue and makes the workflow fail. Before either the TestFlight bootstrap or
   launch deployment, a release operator must verify that the monitor can reach
   a staffed responder and review the retention-aware recovery procedure below,
   then set protected
   Environment variable `ALERT_DELIVERY_DLQ_FALLBACK_MONITOR_RECOVERY_VERIFIED=true`.
   The protected deployment workflow fails closed without that explicit operator
   attestation. The Worker cannot query Queue depth; a nonzero backlog is an
   urgent operator-recovery event before the consumerless Queue retention ends.
4. Configure APNs Worker secrets interactively, as documented in
   [`RELEASE_SECRETS.md`](RELEASE_SECRETS.md#cloudflare-production). Store the
   one-time-download `.p8` key in the organization's password manager first.
5. Keep the three native `ratelimits` namespace IDs in
   [`backend/cloudflare/wrangler.jsonc`](../backend/cloudflare/wrangler.jsonc)
   unique within the Cloudflare account. The Worker then fails closed with a
   `429`/`Cache-Control: no-store` after 300 requests/minute for a public
   method/path (including `GET /healthz`) at a Cloudflare location, or 8
   requests/minute for a device mutation path and SHA-256-derived App Attest
   key ID and/or bounded APNs token. A separate 60-requests/minute route-wide
   `APP_ATTEST_CHALLENGE_RATE_LIMIT` uses only the fixed challenge route as its
   key before request parsing or D1 work, so untrusted proposed key rotation
   cannot mint fresh challenge-write quotas. These counters are deliberately
   local and eventually consistent.
   They are mandatory public-endpoint controls alongside App Attest, and their
   binding configuration is validated by the protected workflow's Wrangler dry
   run. This approved `workers.dev` design has no mandatory Custom Domain, zone
   `http_ratelimit` rule, zone ID, or WAF ruleset gate. There is intentionally
   no client-embedded shared secret to substitute for these controls.
6. Keep the checked-in App Attest verifier fail-closed
   (`APP_ATTEST_ENFORCEMENT=required`). It creates a five-minute one-time
   challenge bound to the exact request bytes/method/path, validates Apple's
   production attestation or assertion, and commits the replay/counter update
   with the device mutation. Do not put a development bypass variable in this
   environment. The Debug/Simulator client must use a separate staging Worker
   configured for the development App Attest mode; its bypass is never a
   production setting. Use the protected isolated staging Worker described
   above for any physical Debug test.

   A first Worker deployment cannot wait for a TestFlight proof that itself
   requires a live production origin. Set protected Environment variable
   `APP_ATTEST_PRODUCTION_ENFORCED=false` and run **Cloudflare Worker → Run
   workflow** with both `deploy_production` and `bootstrap_testflight` enabled.
   This is a one-purpose, reviewer-approved **TestFlight bootstrap**: it still
   requires the APNs secret names, exact approved public `workers.dev` origin,
   protected `main`, real App Attest enforcement, and the terminal-DLQ monitor
   and recovery attestation. It does not weaken the
   Worker, enable a simulator bypass, or authorize a public App Store
   submission. Keep the app unlisted while the proof is performed.

   Then test on physical iOS hardware and TestFlight; Simulator-only validation
   is insufficient. Verify token ownership, token-bound and empty-body
   key-owned unsubscription, reinstall/key-rotation recovery, and the reviewed
   training-push controls. Only after that evidence is recorded may a reviewer
   set `APP_ATTEST_PRODUCTION_ENFORCED=true` and re-run the protected workflow
   with `bootstrap_testflight` disabled for the **launch promotion**. That
   variable records an approved test; it is not an App Attest credential.
7. After the separate `cloudflare-terminal-dlq-monitor` Environment has passed
   both its protected-`main` manual probe and an unattended scheduled probe,
   put `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`,
   `CLOUDFLARE_WORKER_URL=https://quakesignal-api.hopeso.workers.dev`, the App
   Attest review gate, and
   `ALERT_DELIVERY_DLQ_FALLBACK_MONITOR_RECOVERY_VERIFIED=true` (only after
   explicit operator verification) in the protected `cloudflare-production`
   GitHub Environment. Grant the token only the Worker, Durable Object, D1, Queue,
   and Worker-secret-list permissions needed by this service, including the
   read access necessary to verify that the selected account owns
   `hopeso.workers.dev`. Require trusted reviewers for that environment and
   permit deployment only from the protected `main` branch before adding its
   secrets.
8. Run **Cloudflare Worker → Run workflow → deploy_production** in the phase
   selected above. It validates TypeScript, the native rate-limit configuration,
   APNs secret names, and the exact Workers.dev/App Attest/terminal-DLQ
   monitor-and-recovery gate for that phase;
   it also confirms the deployment account owns `hopeso.workers.dev`, then
   applies migrations, deploys, and verifies `/healthz`, `/privacy`, `/support`,
   and `/terms` through the exact approved public origin. This protected
   workflow is the sole normal way to apply remote D1 migrations or run
   `wrangler deploy`; do not make a routine production release from a
   workstation. Never use a real earthquake-looking test alert in production.
9. Test sandbox APNs on a physical development device against the isolated
   staging Worker, then use the TestFlight bootstrap at
   `https://quakesignal-api.hopeso.workers.dev` on a separate opted-in device.
   Complete the launch promotion before public App Review/submission or any
   public release.

## Terminal DLQ fallback recovery

The final `quakesignal-alert-delivery-dlq-fallback` Queue is deliberately
consumerless. Its messages are evidence that the normal DLQ could not complete
the D1 incident transaction and the independent Durable Object fallback was
also unavailable. Treat a labelled GitHub recovery issue from **Monitor
terminal DLQ fallback** as a production incident, even when the Cloudflare
metric reports only an oldest-message timestamp.

Before setting
`ALERT_DELIVERY_DLQ_FALLBACK_MONITOR_RECOVERY_VERIFIED=true`, verify all of the
following:

1. The monitor's dedicated `cloudflare-terminal-dlq-monitor` Environment has
   only `CLOUDFLARE_MONITOR_API_TOKEN` (Cloudflare **Queues Read** scope) and
   `CLOUDFLARE_ACCOUNT_ID`, and a manual dispatch from protected `main`
   successfully identifies exactly one
   `quakesignal-alert-delivery-dlq-fallback` Queue and reports aggregate
   metrics. The monitor requires Cloudflare **Queues Read** permission; its
   reviewed script makes only Queue-list and Queue-metrics requests.
2. The dedicated monitor Environment permits protected `main` but has **no
   required reviewers**, so a scheduled run can obtain its two read-only
   values without an unattended approval bottleneck. It must not contain the
   `cloudflare-production` deployment token or any other production secret.
3. The labelled GitHub issue reaches a staffed responder. It contains only the
   Queue name and aggregate count/timestamp; Queue message bodies, device data,
   APNs keys, Cloudflare tokens, and raw API responses must never be added to
   the issue.

When the monitor alerts:

1. Preserve the terminal Queue. Do **not** attach a Worker consumer, purge it,
   or use the monitor workflow/credential to pull, acknowledge, retry, or
   redrive messages. Record the aggregate metric and time only.
2. Restore and verify D1 plus the global Durable Object first. Confirm the
   production Worker is healthy and the underlying storage/configuration cause
   has been addressed; a terminal Queue message must not be allowed to vanish
   merely because the monitor was acknowledged.
3. Use a separately approved, time-bound break-glass Queue credential to
   recover one retained original message at a time. Replay it to the **DLQ**
   (`quakesignal-alert-delivery-dlq`), not the primary delivery Queue, and wait
   for the DLQ handler's durable D1 incident transaction before acknowledging
   the original terminal copy. Do not redeliver the original page to APNs from
   this recovery route.
4. Re-read the terminal Queue metrics until the backlog and oldest timestamp
   are zero. Record the recovery/disposition in the incident, then manually
   close its labelled GitHub issue. The monitor deliberately never auto-closes
   an incident or removes retained evidence.

## Operational controls before public launch

- Configure an external GET monitor for `/healthz` at a normal monitor cadence
  (do not use it as a high-frequency liveness loop); it is route-rate-limited
  before the global relay. Alert on a stale
  upstream timestamp/closed route, missing APNs configuration, pending D1
  outbox growth, DLQ/Durable-Object-persistence-fallback/quarantined-delivery
  incidents, or failed delivery rate. A pending fallback marker is exposed as
  `delivery.pendingDlqPersistenceFallbacks=true`; it means D1 incident
  persistence is awaiting recovery and the Worker has retained only sanitized,
  token-free evidence in Durable Object storage. Do not delete that marker
  manually; the relay replays it before ordinary outbox work. The separate
  scheduled terminal-DLQ monitor alerts on the terminal consumerless Queue's
  aggregate Cloudflare backlog metric—this is not exposed through `/healthz`.
  `ALERT_DELIVERY_DLQ_FALLBACK_MONITOR_RECOVERY_VERIFIED` is a protected
  operator attestation that this monitor and a retention-aware recovery
  procedure were reviewed; it is not a Queue-depth check. If the
  monitor/recovery path is changed or unverified, set it to
  `false` so both bootstrap and launch deployment fail closed.
  A generic HEAD probe is not sufficient. `/healthz` intentionally returns
  `503` for any required stale/closed source.
- Require a real App Attest assertion and enforce both native Cloudflare
  rate-limit bindings before enabling any public registration endpoint. CORS
  is not an abuse control.
- Do not treat a successful TestFlight bootstrap as a public-launch approval.
  The protected variable must be promoted to `true` only after the physical
  production proof, then the normal launch workflow must pass again.
- Test protected deletion both with an APNs token and with the exact empty JSON
  object (`{}`). The empty form requires an assertion from a key that already
  owns the subscription; it can never claim a legacy/unbound row. Also test
  reinstall/restore recovery: a fresh production attestation plus the exact
  APNs token may atomically rebind that token, while an assertion or empty body
  from a different key remains refused.
- Keep `ENABLE_PRODUCTION_TEST_PUSH=false`. If a controlled production test is
  ever enabled, it remains limited to an existing, attested test device and to
  **one clearly labelled training notification per App Attest key per UTC
  calendar day**. The Worker claims that slot in D1 in the same transaction as
  its assertion-counter/challenge update before contacting APNs; concurrent
  valid requests cannot both dispatch. A second request returns `429` with
  `Cache-Control: no-store`, `Retry-After` calculated to the next UTC midnight,
  and a `retryAtUtc` value. The slot counts an accepted outbound attempt even
  when APNs later fails, so do not enable it for an ad-hoc retry loop.
- Review Cloudflare request-log retention and sampling. Operational logs must
  use a token hash rather than raw APNs tokens, location, or response bodies.
- Treat an APNs `410`/`Unregistered` result as deletion and remove stale
  subscriptions on their retention deadline as well. Preserve a registration
  refreshed after the APNs invalidation timestamp; never delete for
  `BadDeviceToken` alone.
- Expired App Attest challenges are deleted within five minutes. When the last
  associated registration is removed, the opaque key ID, public verifier,
  receipt, and counter are deleted; the daily 90-day stale-registration purge
  performs the same cleanup. A production-training claim contains only the
  opaque App Attest key ID plus UTC timestamps (never a device token, proof, or
  request body) and is purged after 14 days. Delivery-failure token hashes are
  also purged after 14 days.
- App Attest keys can rotate after reinstall or device restore. Only a fresh
  production attestation that carries the exact APNs token may rebind that
  single token and retire its old key record. Assertions and tokenless deletes
  remain strictly key-bound; if APNs has not supplied the token after a reset,
  use the support deletion path.
- Do not enable Apple Critical Alerts without Apple's separate written
  entitlement approval and an in-app user opt-in. The shipped build uses
  standard/time-sensitive notification semantics.
