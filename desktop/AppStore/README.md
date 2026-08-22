# QuakeSignal for macOS — App Store listing kit

This folder holds local App Store submission material for the macOS edition.
Nothing here is uploaded automatically.

> **NOT SELECTED FOR THE CURRENT APPLE RELEASE.** On 20 August 2026, the
> release owner selected the repository's SwiftUI Mac Catalyst target in shared
> Apple ID `6800642443` as the sole Mac storefront route. Leave this separate
> Tauri record (`6800642853`) and its draft/build/assets unchanged. The material
> below is preserved only as a dormant future-release kit.

## English (U.S.) copy

| App Store Connect field | Source file |
| --- | --- |
| Subtitle | `en-US/subtitle.txt` |
| Promotional Text | `en-US/promotional_text.txt` |
| Description | `en-US/description.txt` |
| Keywords | `en-US/keywords.txt` |
| App Review notes | `review-notes.txt` |
| Submission-answer worksheet | `submission-answers.md` |
| Pre-submission checklist | `submission-checklist.md` |
| Screenshot provenance / signed-build approval | `screenshot-provenance.json` |

The approved primary product-page name is **QuakeSignal for macOS** and the
intended primary category is **Weather**. App Store Connect requires unique
names within the team's catalogue, so the separate iOS record retains the
shorter **QuakeSignal** name.

## App Store Connect record checklist

The separate macOS App Store Connect record has been created as
**QuakeSignal for macOS** (Apple ID `6800642853`). Confirm that the
UniSphereco LLC Account Holder has accepted the current agreements and that
the Apple Developer App ID and App Store provisioning profile for
`com.quakesignal.desktop` are ready before uploading a build. The iOS app
uses `com.quakesignal.app`; because the bundle IDs differ, these apps cannot
be one multi-platform/Universal Purchase record.

| New App field | Planned value / decision |
| --- | --- |
| Name and primary language | `QuakeSignal for macOS` — English (U.S.) |
| Bundle ID | `com.quakesignal.desktop` (UniSphereco LLC, Team ID `5TT564H883`) |
| SKU | `quakesignal-macos` |
| User Access | Full Access |
| Price | Free |
| Primary category | Weather |
| Copyright | `2026 UniSphereco LLC` |

The read-only 2026-08-19 portal audit found an editable `1.0.0` draft with its
old `1.0.0` build Ready to Submit, four older screenshot assets, and zero
installs. That package and imagery predate the current reliability and
desktop-layout work and must not be selected for review. Preserve the existing
draft and portal evidence without changing the version, attaching a build, or
uploading assets for the current release. If a later release owner reactivates
this separate product, revalidate every instruction in this dormant kit,
complete the shared published-terms/source review in
[`content-rights-evidence.md`](../../ios/AppStore/content-rights-evidence.md),
and use a newly signed sandboxed package and current screenshots. Do not send
the contingency Wolfx request unless the evidence record's stop conditions are
triggered.

The iOS multi-platform record (Apple ID `6800642443`) also contains a macOS
`1.1` draft for the canonical Swift-native Mac Catalyst route. Do not attach
this Tauri app or modify that draft with Tauri metadata: the shared record
expects `com.quakesignal.app`, while this dormant Mac app uses
`com.quakesignal.desktop`. The current portal state and safe sequence are in
[`ios/AppStore/app-store-connect-portal-audit-2026-08-22.md`](../../ios/AppStore/app-store-connect-portal-audit-2026-08-22.md).

### Final public URLs

Enter these user-approved public Cloudflare Workers values; never substitute a
different personal, preview, or staging Worker URL:

| Purpose | Exact URL |
| --- | --- |
| Privacy Policy URL | `https://quakesignal-api.hopeso.workers.dev/privacy` |
| Support URL | `https://quakesignal-api.hopeso.workers.dev/support` |
| Customer-facing Terms of Use URL | `https://quakesignal-api.hopeso.workers.dev/terms` |

The Privacy Policy and Support URLs are the App Store Connect values. Use the
Terms URL only if a release-owner-approved customer-facing terms link or custom
license agreement calls for it; its presence does not approve a custom EULA.
The approved Worker hostname uses public Cloudflare TLS. Verify its live HTTPS
responses for these URLs before release; do not add a private CA, private root,
or client-mTLS configuration.

### Localized product-page names require approval

No localized macOS App Store display name has been approved. Do not infer one
from the iOS app's resource labels or metadata. Before adding any macOS App
Store localization, the release owner must approve each exact customer-facing
name after availability and trademark review; otherwise retain the approved
English primary name `QuakeSignal for macOS`.

## Screenshots

All four PNGs are 1280 × 800 staged listing assets rendered by QuakeSignal's
real Tauri frontend with the Mac App Store build flag enabled, using a
controlled local snapshot of finalized historical reports. They show the 1.1.0
desktop layout and contain no artificial artwork or AI-generated imagery. No
active warning, training alert, or test alert is shown.

| Position | File | Intended message |
| --- | --- | --- |
| 1 | `screenshots/en-US/01-home-all-clear.png` | Normal monitoring state and source connectivity |
| 2 | `screenshots/en-US/02-event-history.png` | Local report history |
| 3 | `screenshots/en-US/03-monitoring-preferences.png` | Location, threshold, and source choices |
| 4 | `screenshots/en-US/04-notification-preferences.png` | Selectable alarm sound, Japanese-voice license disclosure, and notification preferences |

Before upload, visually compare every frame with the signed, sandboxed Mac App
Store build on a supported Mac and record the approval in
[`screenshot-provenance.json`](./screenshot-provenance.json), including the
signed app/package SHA-256, source commit, Mac/OS, capture time, and reviewer.
Recapture and replace any frame that differs; the controlled-harness render
alone is not confirmation of the final signed build. Then upload the approved
set in the listed order and confirm App Store Connect's current screenshot
validation rules at upload time.

The protected Mac App Store lane has two mutually exclusive manual modes. Both
inputs default to `false`; setting both to `true` is an explicit failure rather
than an upload or a silent skip.

First, freeze protected main at baseline commit `A` and run signed package
verification without contacting App Store Connect:

```sh
gh workflow run desktop-release.yml --ref main \
  -f build_macos_app_store=true \
  -f upload_macos_to_app_store_connect=false
```

This hash/log-only mode runs mechanical listing checks, builds and verifies the
signed sandboxed package, records its SHA-256 digest and verification log, and
deletes the package during cleanup. Because this repository is public, the
package is never retained as a GitHub Actions artifact. Hash/log-only evidence
cannot be installed or visually compared and therefore cannot satisfy the
signed-build approval required by `screenshot-provenance.json`.

The Tauri lane remains blocked and dormant until a release owner approves a
separate private handoff mechanism for the exact signed package and updates this
procedure and its frozen contract. After that private comparison, record the
package SHA-256, full baseline commit `A`, timestamps, and named reviewer in
`screenshot-provenance.json`. Commit only the resulting `desktop/AppStore`
provenance, approved assets, and metadata at protected-main commit `B`; any Mac
application, configuration, icon, lockfile, packaging script, or
release-workflow change requires a new hash/log-only baseline and review.

Only after the separately approved private handoff and that evidence commit may
the protected upload mode run:

```sh
gh workflow run desktop-release.yml --ref main \
  -f build_macos_app_store=false \
  -f upload_macos_to_app_store_connect=true
```

Before credentials, the upload gate proves that `A` is an ancestor of `B`, that
all Mac binary/release-relevant paths are byte-unchanged from `A` through `B`,
and that only the excluded App Store provenance/assets/metadata account for the
review commit. It then runs the release-ready validator with
`--expected-source-commit=A`. The App Store Connect API key is not materialized
in hash/log-only mode and appears only immediately before the approved upload. The
upload step rechecks the verified package digest and binds both modern `altool`
commands to platform `macos`, Apple ID `6800642853`, bundle ID
`com.quakesignal.desktop`, short version `1.1.0`, and bundle version `1.1.0`.

To pass, provenance must use top-level status
`approved`, set `capture.sourceBaselineCommit` to the full frozen 40-character
commit, set `currentSet.status` to `signed-build-approved`, and record:

```json
"releaseApproval": {
  "signedBuildComparison": "approved",
  "sourceBaselineCommit": "<same 40-character commit>",
  "signedArtifactSha256": "<64-character SHA-256>",
  "signedBuildComparedAtUtc": "<UTC ISO-8601 timestamp>",
  "reviewedAtUtc": "<UTC ISO-8601 timestamp>",
  "reviewer": "<named reviewer>"
}
```

The ordinary listing-assets check intentionally permits the current pending
record for mechanical image review; that green check is not upload approval.

## Content guardrails

- Describe QuakeSignal as an independent monitoring app, not an official or
  government emergency-alert service.
- Earthquake information can be delayed, incomplete, revised, or inaccurate;
  users must follow official local emergency guidance.
- Do not use a real active-warning screen or an OS notification as Store
  artwork. The sandboxed build intentionally hides its local Test Alarm control.
- The Mac App Store build does not offer Launch at Login; that feature belongs
  only to the direct-distribution build.
- The Mac app evaluates reports locally while it is running. It has no App
  Attest or APNs registration and must not be described as a background
  emergency-alert service.
- Before release, verify live foreground updates against the Wolfx WebSocket
  service on a signed build. A prolonged socket outage intentionally falls back
  to slow HTTPS history snapshots after 90 seconds; those snapshots refresh the
  local UI/history only and must never create an alarm or notification.
