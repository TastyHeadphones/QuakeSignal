# Release-owner decisions — 2026-08-20

This record captures product and compliance choices made by the release owner
after the read-only App Store Connect audit on 20 August 2026. It does not
authorize a build upload, App Review submission, public release, or production
deployment. Those actions retain their separate signed-artifact, QA, metadata,
and action-time approval gates.

## Apple build and signing route

- Use **Xcode Cloud** with automatic signing for the coordinated native Apple
  release. Do not require manually supplied provisioning-profile secrets in the
  Cloud workflow when Xcode-managed signing can resolve the registered App IDs
  and capabilities.
- The Watch App ID `com.quakesignal.app.watchkitapp` is registered to team
  `5TT564H883`. The shared App ID `com.quakesignal.app` has Push Notifications,
  App Attest, and Time Sensitive Notifications enabled.
- The first Xcode Cloud workflow still requires Apple's one-time Xcode desktop
  onboarding. Configure the reviewed workflow before build 8, retain its real
  product/workflow identifiers, and verify every signed archive and embedded
  entitlement. Automatic signing is not itself signed-artifact evidence.

## Mac storefront route

- Ship the repository's **SwiftUI Mac Catalyst** target as the sole QuakeSignal
  Mac storefront experience for this release.
- Use the shared native record, Apple ID `6800642443`, and bundle ID
  `com.quakesignal.app`. Do not enable the simultaneous **Designed for iPad on
  Mac** route.
- Do not use or attach the separate Tauri package in Apple ID `6800642853` for
  this release. Leave that record unchanged unless the release owner makes a
  later, separately reviewed product decision.
- Mac Catalyst still requires its own signed build-8 archive evidence, Mac QA,
  exact screenshots, metadata, signed-Release parity, and named approval.

## Third-party earthquake data

- Do not send the prepared Wolfx permission email as a release prerequisite.
- The release owner chooses a published-terms route rather than private Wolfx
  correspondence and narrows Apple build 8 to exactly `jma_eew` and
  `jma_eqlist`. Disable `cenc_eew`, `cenc_eqlist`, `sc_eew`, `fj_eew`, and
  `cq_eew` in every submitted Apple target and the developer-operated
  notification relay. A hidden setting, stale preference, combined upstream
  route, or relay default must not widen this source inventory.
- The JMA-only application uses documented public endpoints for JMA-issued
  factual earthquake information, attributes JMA, identifies QuakeSignal's
  presentation as normalized/edited, and does not reproduce Wolfx
  documentation, logos, or JMA `OriginalText`. It does not resell or expose a
  public secondary earthquake-data API.
- Magnitude and epicentral-distance settings are notification-delivery filters,
  not a prediction of local intensity or ground-motion arrival. Build 8 must
  not present a QuakeSignal-authored forecast or official warning; it provides
  a filtered, best-effort relay of JMA-issued information and directs users to
  official guidance. Any later predictive feature requires separate regulatory
  review before implementation or release.
- The notification relay's normalized event rows and revision history become
  eligible for deletion after 89 days for deduplication and delivery. The next
  successful daily cleanup removes them; an operational cleanup failure can
  delay deletion. The relay remains private, has no customer-facing
  earthquake-feed endpoint, and must retire disabled-source queued/outbox work
  without APNs delivery.
- Open-source licensing of QuakeSignal does **not** by itself grant rights in a
  third-party service or its data. The detailed terms-to-product mapping and
  residual risk are retained in `content-rights-evidence.md`.
- If Wolfx or an upstream source changes its terms, objects to the use, or Apple
  requests additional authorization, pause the affected distribution and
  provide the published terms plus the retained mapping; narrow the affected
  source or territories or obtain further authorization if that evidence is
  not accepted. Recheck the final signed source inventory, deployed relay,
  current terms, attribution, and selected territories at action time.

These are release-owner decisions, not legal advice or a representation that a
third party has issued a private written license.
