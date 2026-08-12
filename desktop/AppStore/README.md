# QuakeSignal for macOS — App Store listing kit

This folder holds local App Store submission material for the macOS edition.
Nothing here is uploaded automatically.

## English (U.S.) copy

| App Store Connect field | Source file |
| --- | --- |
| Subtitle | `en-US/subtitle.txt` |
| Promotional Text | `en-US/promotional_text.txt` |
| Description | `en-US/description.txt` |
| Keywords | `en-US/keywords.txt` |
| App Review notes | `review-notes.txt` |

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

Before uploading a build or submitting the macOS version, create the `1.0.0`
platform version to match `desktop/src-tauri/tauri.conf.json`, then complete
the age rating, content rights, export-compliance and App Privacy answers.
Upload the signed Mac App Store build, the icon, this directory's approved
screenshots, and the localized metadata. For a later upload, first increase the
checked-in desktop version and use a higher App Store build. Confirm the Mac
App Store sandbox build does not expose the direct-distribution-only Launch at
Login feature.

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
controlled local snapshot of finalized historical reports. Native screen
capture was unavailable in this workspace, so no artificial artwork or
AI-generated imagery was used. No active warning, training alert, or test alert
is shown.

| Position | File | Intended message |
| --- | --- | --- |
| 1 | `screenshots/en-US/01-home-all-clear.png` | Normal monitoring state and source connectivity |
| 2 | `screenshots/en-US/02-event-history.png` | Local report history |
| 3 | `screenshots/en-US/03-monitoring-preferences.png` | Location, threshold, and source choices |
| 4 | `screenshots/en-US/04-notification-preferences.png` | Alarm and notification preferences plus independent-app disclosure |

Before upload, visually compare every frame with the signed, sandboxed Mac App
Store build on a supported Mac and record the approval. Recapture and replace
any frame that differs; the controlled-harness render alone is not confirmation
of the final signed build. Then upload the approved set in the listed order and
confirm App Store Connect's current screenshot validation rules at upload time.

## Content guardrails

- Describe QuakeSignal as an independent monitoring app, not an official or
  government emergency-alert service.
- Earthquake information can be delayed, incomplete, revised, or inaccurate;
  users must follow official local emergency guidance.
- Do not use a real active-warning screen or an OS notification as Store
  artwork. The sandboxed build intentionally hides its local Test Alarm control.
- The Mac App Store build does not offer Launch at Login; that feature belongs
  only to the direct-distribution build.
- Before release, verify live foreground updates against the Wolfx WebSocket
  service on a signed build. A prolonged socket outage intentionally falls back
  to slow HTTPS history snapshots after 90 seconds; those snapshots refresh the
  local UI/history only and must never create an alarm or notification.
