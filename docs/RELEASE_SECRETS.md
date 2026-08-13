# Release secrets and protected environments

QuakeSignal's release workflows intentionally contain no certificates, private
keys, APNs tokens, or Cloudflare credentials. Add the following values as
**environment-scoped GitHub secrets**, never as repository files, Actions
variables, source code, issues, or pull-request comments.

Create the eight GitHub Environments below, restrict them to their intended
release or monitoring scope, and require approval before use **except** the
dedicated read-only `cloudflare-terminal-dlq-monitor` Environment described
below. Configure a protected `main` rule and a protected `v*` tag rule: the
workflows use `github.ref_protected` and will intentionally skip production
lanes until those controls exist. Allow the matching protected branch/tag to
deploy to each environment. The workflows fail with a named missing-value
error until their secrets are present. The required Apple, Cloudflare, APNs,
DNS, and notarization credentials are external prerequisites; none is
represented in this repository.

## `ios-app-store-release`

| Name | Kind | Value |
| --- | --- | --- |
| `IOS_APP_STORE_CERTIFICATE` | Secret | Base64-encoded Apple Distribution `.p12` for `com.quakesignal.app` |
| `IOS_APP_STORE_CERTIFICATE_PASSWORD` | Secret | Password used when exporting that `.p12` |
| `IOS_APP_STORE_PROVISIONING_PROFILE` | Secret | Base64-encoded App Store provisioning profile with production Push Notifications, Time Sensitive Notifications, and App Attest support |
| `IOS_APP_STORE_PROFILE_NAME` | Environment variable | Exact provisioning-profile name |
| `APP_STORE_CONNECT_API_KEY` | Secret | Team App Store Connect API private `.p8` key contents |
| `APP_STORE_CONNECT_API_KEY_ID` | Environment variable | App Store Connect API key ID |
| `APP_STORE_CONNECT_API_ISSUER` | Environment variable | App Store Connect API issuer UUID |
| `CLOUDFLARE_WORKER_URL` | Environment variable | Exactly `https://quakesignal-api.hopeso.workers.dev`; the Release archive verifies this user-approved public Workers.dev production origin |

The Account Holder must first enable App Store Connect API access. Use a
least-privilege team key. The workflow only uploads when a trusted maintainer
starts **iOS → Run workflow** with `upload_to_testflight` enabled.

## `macos-direct-release`

The exact macOS direct-download and notarization secrets are in
[`SIGNING.md`](SIGNING.md#direct-download-and-homebrew). This lane needs a
Developer ID Application certificate plus an App Store Connect API key that is
authorized for notarization. It signs, notarizes, and staples the downloadable
DMG before a Homebrew cask may point at it.

## `homebrew-tap-release`

This protected environment mirrors only a release that has already passed the
notarized direct macOS lane into the public `TastyHeadphones/homebrew-tap`
repository. Create that public repository first; the workflow refuses to
create it, refuses `v0.1.0`, and verifies the published universal DMG,
`SHA256SUMS.txt`, Developer ID signature, notarization ticket, Gatekeeper
assessment, and the cask's Homebrew audit before it can push.

| Name | Kind | Value |
| --- | --- | --- |
| `HOMEBREW_TAP_TOKEN` | Secret | Fine-grained token restricted to **Contents: Read and write** on `TastyHeadphones/homebrew-tap` only. It is exposed only to the final validated push step. |

Run **Publish Homebrew cask → Run workflow** from protected `main`, enter the
numeric version from the already-published protected tag, and explicitly set
`publish_to_tap=true`. The tag's `desktop-release.yml` run must already have
published `QuakeSignal_<version>_universal.dmg` and `SHA256SUMS.txt`; this is
not a build, notarization, or bypass lane.

## `macos-app-store-release`

The exact Mac App Store credentials are in
[`SIGNING.md`](SIGNING.md#mac-app-store). This lane needs distinct Apple
Distribution and Mac Installer Distribution certificates plus the sandboxed
Mac App Store provisioning profile. To validate and upload a package, it also
needs the `MACOS_APP_STORE_CONNECT_API_KEY` secret (the team API private `.p8`
contents) and `MACOS_APP_STORE_CONNECT_API_KEY_ID` plus
`MACOS_APP_STORE_CONNECT_API_ISSUER` protected environment variables. The
workflow only uploads when a trusted maintainer starts **Desktop release → Run
workflow** with `upload_macos_to_app_store_connect` enabled. Its signed `.pkg`
is never a public GitHub Release asset.

## `microsoft-store-release`

The existing Windows lane is not part of the macOS/iOS launch, but its Partner
Center publication is also a protected external action. Configure required
reviewers before adding these environment-scoped values:

| Name | Kind | Value |
| --- | --- | --- |
| `MICROSOFT_STORE_PRODUCT_ID` | Environment variable | Partner Center product ID |
| `AZURE_AD_TENANT_ID` | Secret | Partner Center Azure AD tenant ID |
| `AZURE_AD_APPLICATION_CLIENT_ID` | Secret | Partner Center application/client ID |
| `AZURE_AD_APPLICATION_SECRET` | Secret | Partner Center application secret |
| `SELLER_ID` | Secret | Partner Center seller ID |

The workflow publishes only when a trusted maintainer starts **Desktop release
→ Run workflow** from protected `main` with `publish_to_store` enabled.

## `cloudflare-staging`

This is a separate, Debug-only notification service. It is not interchangeable
with the user-approved production Workers.dev origin and it must not receive
any `cloudflare-production` secret, production resource ID, Apple distribution
credential, or App Store release variable. Before adding its values, a
UniSphereco LLC release owner must verify that the selected Cloudflare account
is authorized to host this service. If a token cannot be constrained away from
production resources in a shared account, use a separately controlled staging
account instead.

| Name | Kind | Value |
| --- | --- | --- |
| `CLOUDFLARE_API_TOKEN` | Secret | A staging-only deployment token permitted to edit/list only the isolated Worker, its Durable Object, staging D1 database, derived staging Queues, and that Worker's secret names. It must not be able to deploy the production Worker or alter its D1/Queues. |
| `CLOUDFLARE_ACCOUNT_ID` | Secret | Account ID that owns the isolated staging resources. |
| `CLOUDFLARE_STAGING_WORKER_NAME` | Environment variable | Lowercase Worker name beginning `quakesignal-` and containing a `staging` segment, for example `quakesignal-api-staging`. It is never `quakesignal-api`. |
| `CLOUDFLARE_STAGING_D1_DATABASE_NAME` | Environment variable | Separate, staging-named D1 database, for example `quakesignal-api-staging`; never `quakesignal-production`. |
| `CLOUDFLARE_STAGING_D1_DATABASE_ID` | Environment variable | UUID of that separate D1 database. |
| `CLOUDFLARE_STAGING_DEVICE_API_RATE_LIMIT_NAMESPACE_ID` | Environment variable | New, account-unique namespace ID for the staging `DEVICE_API_RATE_LIMIT` binding. |
| `CLOUDFLARE_STAGING_DEVICE_MUTATION_RATE_LIMIT_NAMESPACE_ID` | Environment variable | A different new, account-unique namespace ID for the staging `DEVICE_MUTATION_RATE_LIMIT` binding. |
| `CLOUDFLARE_STAGING_APP_ATTEST_CHALLENGE_RATE_LIMIT_NAMESPACE_ID` | Environment variable | A third, different account-unique namespace ID for the staging route-wide `APP_ATTEST_CHALLENGE_RATE_LIMIT` binding. |
| `CLOUDFLARE_STAGING_ALLOWED_BUNDLE_VERSIONS` | Environment variable (optional) | Comma-separated Debug `CFBundleVersion` allowlist. Omit or leave blank to use the isolated baseline `1`; set `1,2` for the current build-2 client while build 1 remains installed. |
| `CLOUDFLARE_STAGING_WORKER_URL` | Environment variable (required only for readiness verification) | Bare `https://<worker>.<account-subdomain>.workers.dev` URL. Set it after the first deployment before running the workflow with `verify_staging_apns=true`. |

The checked-in staging template and renderer derive all three Queue names from
the Worker name:

```text
<CLOUDFLARE_STAGING_WORKER_NAME>-alert-delivery
<CLOUDFLARE_STAGING_WORKER_NAME>-alert-delivery-dlq
<CLOUDFLARE_STAGING_WORKER_NAME>-alert-delivery-dlq-fallback
```

Create the separate D1 database and all three derived Queues in the verified account
before the first protected staging deployment. Record only their non-secret
name/ID values in this environment. The renderer rejects the committed
production D1 ID, production database name, production rate-limit namespace
IDs, production Worker names, shared staging rate-limit IDs, routes, and
custom domains. It intentionally produces a `workers.dev` configuration with
public Cloudflare TLS; no private CA, custom origin certificate, or client mTLS
credential is required or allowed.

Start **Cloudflare Staging Worker → Run workflow** from protected `main` with
`deploy_staging=true`. It generates its configuration in the runner's temporary
directory, validates it, applies migrations only to the named staging D1
database, and deploys only the derived staging Worker. The first deployment
does not claim APNs readiness. After it exists, set these four values as
**Worker secrets on that staging Worker**, using the sandbox APNs topic and
credentials approved for the Debug build. `APNS_BUNDLE_ID` remains
`com.quakesignal.app`; device-token environment selects Apple's sandbox APNs
endpoint:

```text
APNS_PRIVATE_KEY
APNS_KEY_ID
APNS_TEAM_ID
APNS_BUNDLE_ID
```

Store the APNs `.p8` recovery copy in the organization's approved secret
manager before entering it. The Apple signing key may be the same Apple team
key where Apple permits it, but the four values must be entered and managed as
separate Cloudflare Worker secrets; never read, copy, or reference the
production Worker's secret store. Set `CLOUDFLARE_STAGING_WORKER_URL`, then
rerun the protected workflow with both `deploy_staging=true` and
`verify_staging_apns=true`. That optional phase verifies only secret *names*,
checks `/healthz`, legal URLs, and the remote smoke suite against the staging
`workers.dev` origin.

The rendered staging configuration fixes `APP_ATTEST_ENFORCEMENT=development`
and `APP_ATTEST_DEVELOPMENT_ENVIRONMENT=true`, and deliberately omits
`APP_ATTEST_DEVELOPMENT_BYPASS`. Use it to prove real development App Attest
and sandbox APNs on a physical Debug device. Simulator-only bypass testing, if
needed, belongs to a short-lived local setup; it must not be enabled in this
protected environment. The exact physical-device steps are in
[`CLOUDFLARE_PRODUCTION.md`](CLOUDFLARE_PRODUCTION.md#isolated-debug-staging-worker).

## `cloudflare-terminal-dlq-monitor`

This dedicated Environment lets the five-minute **Monitor terminal DLQ
fallback** workflow obtain only the aggregate-metrics credential without
exposing the production deployment credential to an unattended run. Restrict it
to protected `main`, but do **not** require reviewers: a reviewer-gated
Environment causes scheduled runs to remain pending and is not a monitor. It
must contain no APNs key, Worker deployment token, D1 credential, or production
release secret.

| Name | Kind | Value |
| --- | --- | --- |
| `CLOUDFLARE_MONITOR_API_TOKEN` | Secret | Separate Cloudflare API token restricted to **Queues Read** for the account that owns `quakesignal-alert-delivery-dlq-fallback`. It is used only to list Queues and read the terminal Queue's aggregate metrics; do not grant Workers Scripts, D1, Durable Object, Queue write, or message-recovery permissions. |
| `CLOUDFLARE_ACCOUNT_ID` | Secret | Cloudflare account ID that owns the exact terminal fallback Queue. |

After a manual protected-`main` run and a subsequent unattended scheduled run
both complete successfully, a release operator may review the staffed response
path and set the separate `cloudflare-production`
`ALERT_DELIVERY_DLQ_FALLBACK_MONITOR_RECOVERY_VERIFIED=true` deployment
attestation. The monitor Environment never contains that attestation or any
deployment credential.

## `cloudflare-production`

| Name | Kind | Value |
| --- | --- | --- |
| `CLOUDFLARE_API_TOKEN` | Secret | Scoped deployment token limited to this Worker, its Durable Object, D1 database/migrations, all three delivery/incident Queues, Worker-secret-name listing, and Workers Scripts Read/Write needed to verify and deploy the `hopeso.workers.dev` Worker. It is never used by the scheduled terminal-DLQ monitor. |
| `CLOUDFLARE_ACCOUNT_ID` | Secret | Cloudflare account ID that owns those resources |
| `CLOUDFLARE_WORKER_URL` | Environment variable | Exactly `https://quakesignal-api.hopeso.workers.dev`; this is the user-approved public Workers.dev production origin |
| `APP_ATTEST_PRODUCTION_ENFORCED` | Environment variable | Exactly `false` for the one-time protected TestFlight bootstrap, then exactly `true` only after a reviewer has completed the physical-device/TestFlight App Attest test plan |
| `ALERT_DELIVERY_DLQ_FALLBACK_MONITOR_RECOVERY_VERIFIED` | Environment variable | Exactly `true` only after a release operator has verified the scheduled, staffed terminal-DLQ Queue monitor for `quakesignal-alert-delivery-dlq-fallback` and reviewed its retention-aware recovery procedure. Required for both TestFlight bootstrap and launch; it is an explicit attestation, not telemetry. |

The manual **Cloudflare Worker → Run workflow** deployment is the sole normal
production route for remote D1 migrations and Worker deployment. Include
permission to list this Worker's secret names (never values), **Workers
Queues: Edit** for `quakesignal-alert-delivery`,
`quakesignal-alert-delivery-dlq`, and
`quakesignal-alert-delivery-dlq-fallback` in that
token's scope, plus only the Worker, Durable Object, and D1 permissions needed
by this service. The three native rate-limit bindings remain checked-in,
mandatory production configuration; the protected workflow validates them with
Wrangler and verifies that the selected account owns `hopeso.workers.dev`; it
does not require a Custom Domain, zone ID, or zone-WAF ruleset.
Do not run a routine production `wrangler deploy` or remote migration from a
workstation. Keep delivery credentials in Cloudflare itself:

The following interactive secret commands act on the account selected by the
local Wrangler login. Before entering any APNs value, run `npx wrangler
whoami` and verify that the selected account owns both
`hopeso.workers.dev` and the production `quakesignal-api` Worker. Stop if it
does not; do not place the APNs key in a previously authenticated personal or
staging account. These commands set secrets only—they are not a replacement
for the protected production migration/deploy workflow.

The terminal `quakesignal-alert-delivery-dlq-fallback` Queue intentionally has
no Worker consumer. The separate read-only monitor Environment invokes the
checked-in Queue-metrics workflow; Workers cannot reliably query Queue depth.
A nonzero backlog means both D1 and Durable Object fallback persistence were
unavailable long enough to exhaust DLQ retries, so preserve and recover the
retained message through the approved incident procedure before the
consumerless Queue's retention period expires.

Before changing
`ALERT_DELIVERY_DLQ_FALLBACK_MONITOR_RECOVERY_VERIFIED` to `true`, the release
operator must verify that the separate monitor targets the exact terminal Queue,
has passed one manual and one unattended scheduled run, reaches a staffed
responder, and has a documented, retention-aware recovery path. The protected
deployment gate deliberately does **not** inspect Queue depth, retention, or
GitHub Environment wiring; it only fails closed unless this protected
Environment attestation is exactly `true`. Set it back to `false` while the
monitor or recovery procedure is unverified. This is required even for the
TestFlight bootstrap because that deployment can create terminal fallback
evidence.

```bash
cd backend/cloudflare
npx wrangler secret put APNS_PRIVATE_KEY
npx wrangler secret put APNS_KEY_ID
npx wrangler secret put APNS_TEAM_ID
npx wrangler secret put APNS_BUNDLE_ID
```

`APNS_PRIVATE_KEY` is the complete one-time-download Apple APNs `.p8` key.
Store a recovery copy in the organization's approved password manager before
entering it. Do not create a key in the Apple portal until its secure storage
is ready. `ENABLE_PRODUCTION_TEST_PUSH` stays `false`; production training
pushes must be a deliberate, separately reviewed deployment setting. If it is
temporarily set to `true`, each existing App Attest key can make only one
clearly labelled training push to its owned production subscription per UTC
day. The Worker returns `429` with `Retry-After` until the next UTC day after
that slot is claimed, including when APNs later rejects the attempted training
push. The delayed background/locked/terminated training check uses the same
claim and requires TestFlight build `1.0 (2)` or later containing **Schedule
Background Test Alert**. Build `1.0 (2)` is assigned to the internal QA group,
but its physical-device evidence is still required before launch promotion.

For the first production Worker deployment, run the protected workflow from
`main` with `deploy_production=true` and `bootstrap_testflight=true` while
`APP_ATTEST_PRODUCTION_ENFORCED=false`. The deployment still checks the APNs
secret names, exact approved public Workers.dev origin, native rate-limit
configuration, and App Attest gate; the extra input only records that
TestFlight evidence cannot exist until the real origin exists. Keep the app
unlisted, perform physical TestFlight App Attest/APNs verification, then set
the variable to `true` and run the same protected workflow with the bootstrap
input disabled before public App Review or release.

There is deliberately no private CA, Cloudflare origin certificate, or iOS
client-mTLS secret in any environment. The user-approved public production
origin is `https://quakesignal-api.hopeso.workers.dev`; Cloudflare serves it
with normal public TLS when `workers_dev=true`. It requires no Custom Domain,
DNS-zone activation, private CA, or client mTLS configuration. Do not
substitute a different Workers.dev URL in either release environment.

Before public iOS registration is enabled, keep both native Cloudflare
rate-limit bindings for the device endpoints and complete Apple App Attest
challenge/assertion verification with replay protection. These controls
deliberately are not replaced by a client-shipped static secret; see
[`CLOUDFLARE_PRODUCTION.md`](CLOUDFLARE_PRODUCTION.md#production-deployment-order).
The production verifier configuration is versioned in `wrangler.jsonc` and
must remain `APP_ATTEST_ENFORCEMENT=required`. Never add
`APP_ATTEST_DEVELOPMENT_BYPASS=true` to `cloudflare-production`; that setting
is only for a short-lived local test setup. Physical Debug testing uses the
protected, isolated `cloudflare-staging` Worker in real development App Attest
mode. It has its own D1, Queues, rate-limit namespace IDs, Worker secrets, and
`workers.dev` hostname; it never shares the production Worker resources or
release App Attest configuration.

## Certificate and account prerequisites

- Renew the UniSphereco LLC Apple Developer Program membership before its
  current expiration. Do not start a submission with an expired membership.
- Use the registered IDs `com.quakesignal.app` and
  `com.quakesignal.desktop`. The iOS distribution profile must contain
  `aps-environment=production` and
  `com.apple.developer.usernotifications.time-sensitive`; refresh it after
  enabling App Attest and confirm the signed release archive contains
  `com.apple.developer.devicecheck.appattest-environment=production`.
- Do not request or enable Critical Alerts until Apple grants that separate
  restricted entitlement. QuakeSignal ships standard/time-sensitive alerts.
- Rotate or revoke any credential immediately if it has been exposed. Delete
  expired certificates and old provisioning profiles from the protected
  environment after a successful rotation.
