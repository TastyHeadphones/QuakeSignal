# Independent terminal-DLQ monitor

This is a separate, cron-only Cloudflare Worker for the deliberately
consumerless `quakesignal-alert-delivery-dlq-fallback` Queue. It has no public
route (`workers_dev: false`) and no D1, Queue, APNs, delivery, Durable Object,
or service binding.

Every five minutes it:

1. Uses a **Queues Read** token only to list Queues and read aggregate metrics
   for the one fixed terminal Queue.
2. Validates its GitHub App's repository/permission scope on every run, but
   does not open or update an issue when both aggregate values are zero.
3. When either value is nonzero, creates or updates one labelled, token-free
   GitHub recovery issue through a GitHub App installation limited to
   **Issues: write** on `TastyHeadphones/QuakeSignal` only.
4. When its Queue probe fails, creates or updates a separate monitor-failure
   issue when GitHub remains reachable, then records the Cron failure.

It never requests Queue messages and never logs provider responses, access
tokens, app JWTs, private keys, device data, or message contents. The existing
GitHub Actions monitor remains a best-effort secondary check; GitHub documents
that scheduled workflow runs can be delayed or dropped, so it is not the sole
five-minute production control.

## Required least-privilege setup

Create a **separate Cloudflare account** for this monitor Worker, then create a
protected GitHub Environment named `cloudflare-terminal-dlq-monitor-worker`,
restricted to protected `main` with trusted reviewers. A Workers Scripts: Edit
token is account-wide: deploying this Worker into the same account as the
production API would let that token modify the API Worker. The monitor account
must be distinct; it reaches the production Queue only through its separate
read-only Queue token.

The Environment needs these environment-scoped secrets:

| Name | Required scope / value |
| --- | --- |
| `CLOUDFLARE_API_TOKEN` | Deployment token in the separate monitor account: **Workers Scripts: Edit** only. It must not have access to the production account. |
| `CLOUDFLARE_DEPLOY_ACCOUNT_ID` | Separate account ID where `quakesignal-terminal-dlq-monitor` is deployed. It must differ from the production Queue account. |
| `CLOUDFLARE_TARGET_ACCOUNT_ID` | Production account ID owning `quakesignal-alert-delivery-dlq-fallback`. It is stored as a runtime Worker secret so the target cannot be changed from source. |
| `CLOUDFLARE_MONITOR_API_TOKEN` | Separate runtime token: account-scoped **Queues: Read** only. It can list Queues and read aggregate metrics, but cannot read, acknowledge, retry, purge, or redrive messages. |
| `TERMINAL_DLQ_GITHUB_APP_ID` | Numeric GitHub App ID; the protected workflow maps it to runtime `GITHUB_APP_ID`. GitHub reserves the `GITHUB_` Environment-secret namespace. |
| `TERMINAL_DLQ_GITHUB_APP_INSTALLATION_ID` | Numeric installation ID for an installation limited to this one repository; mapped to runtime `GITHUB_APP_INSTALLATION_ID`. |
| `TERMINAL_DLQ_GITHUB_APP_PRIVATE_KEY_PKCS8` | Unencrypted PKCS#8 RSA private-key PEM for that GitHub App; mapped to runtime `GITHUB_APP_PRIVATE_KEY_PKCS8`. |

Create a dedicated GitHub App with repository selection **Only select
repositories → `TastyHeadphones/QuakeSignal`** and only the repository
permission **Issues: Read and write** (Metadata read is implicit). Do not grant
Actions, Contents, Deployments, Administration, Checks, or organization
permissions; no webhook is required. The Worker requests a fresh, scoped
installation token for every alert/failure operation and verifies that its
returned scope is this repository with `issues: write`.

GitHub commonly downloads App private keys as PKCS#1 PEM. Cloudflare Web Crypto
imports PKCS#8, so convert the file locally without adding it to this repository:

```bash
openssl pkcs8 -topk8 -nocrypt \
  -in github-app-private-key.pem \
  -out github-app-private-key-pkcs8.pem
```

Store the complete output (including `BEGIN PRIVATE KEY` / `END PRIVATE KEY`)
as the `TERMINAL_DLQ_GITHUB_APP_PRIVATE_KEY_PKCS8` Environment secret, then
securely remove the local converted copy. GitHub does not allow custom secret
names beginning with `GITHUB_`; the protected workflow maps this value to the
Worker-only runtime name. Do not use a personal access token or an
Actions-write GitHub App for this monitor.

## Deploy and verify

Use **Deploy terminal DLQ monitor → Run workflow → `deploy_monitor=true`** from
protected `main`. The protected job submits all five runtime values using one
`wrangler deploy --secrets-file` invocation, so the first version has both
`workers_dev:false` and all required secrets before its `*/5 * * * *` Cron
Trigger becomes active. Cloudflare documents that Cron changes can take up to
15 minutes to propagate.

Before treating it as release evidence:

1. Confirm the protected deploy job and its focused type, JWT, Queue-metric,
   issue-escalation, and no-public-route checks are green.
2. Wait for propagation, then confirm at least three on-cadence Cloudflare Cron
   Events and corresponding token-free `terminal_dlq_monitor_completed` logs.
   Each normal run also mints a fresh GitHub App installation token and verifies
   its repository/`issues:write` scope, even while the Queue is empty.
3. Configure an independent missed-heartbeat/Cron-failure alert outside this
   Worker (for example, a Cloudflare observability integration or external
   heartbeat monitor). A Worker cannot alert when its own scheduled invocation
   never starts. Exercise that escalation in an isolated nonproduction monitor;
   never add test evidence to the production terminal Queue.
4. Confirm the labelled GitHub recovery issue reaches a staffed responder and
   rehearse the retention-aware procedure in
   [`docs/CLOUDFLARE_PRODUCTION.md`](../../../docs/CLOUDFLARE_PRODUCTION.md#terminal-dlq-fallback-recovery).

To prove the full issue-creation path without adding evidence to production,
run **Deploy terminal DLQ monitor** with `monitor_target=staging` in the
separately reviewer-protected `cloudflare-terminal-dlq-monitor-worker-staging`
Environment. It deploys `wrangler.staging.jsonc` with a staging Queue-account
Read token and the same repository-limited GitHub App. The source fixes the
staging Queue and a distinct `quakesignal-staging-terminal-dlq-fallback` label;
it cannot be pointed at an arbitrary Queue or repository. Exercise that test
issue, notify the responder, then manually close it before production
attestation.

Only after those records exist may a release operator re-affirm
`ALERT_DELIVERY_DLQ_FALLBACK_MONITOR_RECOVERY_VERIFIED=true` for a launch
promotion. The current GitHub-only schedule history alone is not sufficient.
