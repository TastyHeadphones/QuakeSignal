# Native platform App Store metadata — 1.1 (8)

This directory contains offline, English (U.S.) review drafts for the native
Apple TV, Apple Vision Pro, Apple Watch, and Mac Catalyst experiences in
QuakeSignal 1.1, build 8. Nothing here changes App Store Connect, uploads a
build, certifies a questionnaire, or authorizes release.

The canonical App Store Connect record for these targets is **QuakeSignal**,
Apple ID `6800642443`:

| Experience | Store placement | Version / build | Metadata source |
| --- | --- | --- | --- |
| iPhone and iPad | iOS platform version | `1.1 (8)` | `../../en-US/` and the root iOS review files |
| Apple Watch companion | Apple Watch section of the iOS version; embedded in the iOS upload | `1.1 (8)` | `watchos/` plus the shared iOS description/review notes |
| Apple TV | tvOS platform version | `1.1 (8)` | `tvos/` |
| Apple Vision Pro | visionOS platform version | `1.1 (8)` | `visionos/` |
| Mac Catalyst | macOS platform version in the shared native record | `1.1 (8)` | `maccatalyst/`; source-current copy is present, screenshots and signed approval remain pending |

Apple documents that tvOS and visionOS platform versions in a multi-platform
record use the record's existing Apple ID, SKU, and bundle ID, while an Apple
Watch companion is uploaded from the same Xcode project as its iOS host. See
[Add platforms](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-platforms/)
and
[Add watchOS app information](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-watchos-app-information).

The release owner selected the repository's SwiftUI Mac Catalyst target as the
sole Mac storefront experience in shared Apple ID `6800642443`. Designed for
iPad on Mac must be disabled. Do not attach or submit the separate Tauri
package from Apple ID `6800642853` for this release; leave that record
unchanged.

## Truthful platform scope

| Platform | Customer-visible behavior | Notification capability in this release |
| --- | --- | --- |
| iPhone / iPad | Full reports, map, preparedness guide, settings, and optional nearby notifications | Protected App Attest + APNs registration. Qualifying fresh warnings may use **Time Sensitive**, subject to system/user settings. There is no Critical Alerts entitlement. |
| Apple Vision Pro | Full native windowed app with reports, map, guide, settings, and local foreground warning presentation while open | Foreground only. Apple does not list Push Notifications or Time Sensitive Notifications as supported visionOS provisioning capabilities, so this target has no APNs, App Attest, Time Sensitive, Critical Alerts, or background emergency-alert path. |
| Apple TV | Large-screen headline, recent-report list, event details, active-only live-warning guidance, and a three-choice sound screen | Foreground only. No APNs, App Attest, automatic alert audio, or background emergency alerts. System is visual-only; custom sounds play only after an explicit Siri Remote action. |
| Apple Watch | Compact headline, recent-report list, event details, active-warning guidance, native warning haptic, and the selected mirrored custom sound while open | Foreground only. The Watch app does not independently register for APNs, App Attest, Time Sensitive/Critical Alerts, or background emergency delivery. Paired-iPhone alerts remain the background path. |
| Mac Catalyst | Native SwiftUI reports, map, preparedness guide, and settings in a Mac window | Foreground/local only. No independent APNs, App Attest, or background emergency-alert path in this release. |

On iPhone and iPad, Time Sensitive notifications are not Critical Alerts and
remain under user and system control. Apple states that users can disable Time
Sensitive interruptions, while Critical alerts require a separately approved
entitlement. Apple Vision Pro remains foreground-only in this release; see
Apple's current
[visionOS capability table](https://developer.apple.com/help/account/reference/supported-capabilities-visionos/).
See Apple's documentation for
[Time Sensitive notifications](https://developer.apple.com/documentation/usernotifications/unnotificationinterruptionlevel/timesensitive)
and
[Critical notifications](https://developer.apple.com/documentation/usernotifications/unnotificationinterruptionlevel/critical).

## Copy and asset map

Each platform directory contains:

- English platform-version copy in `description.txt`, `promotional_text.txt`,
  and `keywords.txt`. The app name and subtitle belong to the shared app record;
  the exact English subtitle is versioned in `../../en-US/subtitle.txt`, so this
  kit does not invent platform-specific replacements for it.
- Reviewer instructions in `review-notes.txt`.
- An immutable screenshot capture plan. Its pending/null fields are deliberate:
  the source-frozen capture packages hash that exact plan, so recording results
  in place would invalidate their provenance.

The complete source-frozen Debug Simulator packages from successful workflow
run `32347549322` are preserved under
`screenshot-candidates-v1.1-build8/`. They contain all 3 Apple TV, 3 Apple
Watch, and 5 Apple Vision Pro PNGs, per-frame evidence, aggregate provenance,
runtime inventory, and schema-3 candidate metadata. Every package is bound to
commit `b461083bb5bff21eb4f1f4a8b5ef8f0764d89dd2` and remains explicitly
unapproved (`uploadApproved: false`, `reviewer: null`, and no signed Release
evidence). The capture-run receipt retains the short-lived GitHub artifact IDs
and archive digests; the checked-in validator proves the full local hash chain.
These files are durable historical evidence, not permission to upload them.
They are also historical relative to the current JMA-only and Mac Catalyst
source changes made after `b461083bb5bff21eb4f1f4a8b5ef8f0764d89dd2`.
The final build-8 commit must be recaptured as a complete iPhone, iPad, Apple
TV, Apple Watch, Apple Vision Pro, and Mac Catalyst set; do not weaken or
rewrite the source guard to make these older packages pass.

The cross-platform catalog is
[`../screenshot-set-index-v1.1-build8.json`](../screenshot-set-index-v1.1-build8.json).
Normal listing CI verifies its immutable historical locks and allows
`activeReleaseSet: null`. Once the final commit is frozen, integrate exactly
one complete package below
`../screenshot-release-sets-v1.1-build8/<40-character-source-commit>/` and
point the index at its hashed `release-set.json`. The set is indivisible: 10
iPhone/iPad, 3 Apple TV, 3 Apple Watch, 5 Apple Vision Pro, and 5 Mac Catalyst
frames. Partial, mixed-commit, or historically copied sets are rejected.

Release readiness additionally requires a separately hashed
`release-approval.json` with a named reviewer and approved signed-Release
parity for every platform. Each signed build commit must be product-source
equivalent to the screenshot commit. Validate that gate with:

```sh
ruby .github/scripts/verify-store-assets.rb \
  --require-build8-screenshot-release-ready \
  --expected-source-commit=<40-character-source-commit>
```

Apple Watch has no separate platform description field for this companion.
Apple requires the iOS description to explain the Watch functionality. The
Watch `description.txt` is therefore a source paragraph, and its exact meaning
is incorporated into `../../en-US/description.txt`.

Only the approved English (U.S.) listing is ready for portal review. Do not add
Japanese or Simplified Chinese product-page localizations until the release
owner approves each exact display name, availability, and trademark review.

## Required human gates

- [ ] Freeze the exact source commit and build 8 archives.
- [ ] Use the currently defined protected GitHub signing workflows at the
  frozen source commit, then validate every signed archive/profile/entitlement,
  the embedded Watch signature, and each machine-readable signed-run
  attestation. Xcode Cloud remains unconfigured as of 2026-08-22.
- [ ] Recapture the complete screenshot set at the exact final build-8 commit,
  then compare those source-matching Debug candidates with the matching signed
  Release uploads, preserve the four exact upload-run IDs, and obtain named
  visual approval before screenshot upload, version attachment, or submission.
  The preserved b461 packages are historical and do
  not satisfy the current source, signed-parity, or reviewer gates.
- [ ] Complete platform QA. Generic compilation and source inspection are not
  simulator, Apple TV, Apple Vision Pro, Apple Watch, or signed-device evidence.
  App Attest, APNs, Focus, Silent Mode, remote-focus, and background-delivery
  checks apply to the iPhone/iPad notification path only.
- [ ] Recheck the published-terms Content Rights basis in
  `../content-rights-evidence.md` for the exact final sources, product behavior,
  attribution, relay retention, territories, and current Wolfx/Open API/source
  terms. Map every enabled non-JMA feed or disable it. No Wolfx email is
  required by the recorded release-owner decision; if Apple or a source asks
  for more evidence, pause and narrow or obtain it.
- [ ] Complete current Age Rating, App Privacy, Export Compliance, Content
  Rights, availability, and accountable App Review contact fields.
- [ ] Obtain legal/release-owner approval for the expanded privacy source and
  publish it through the separately approved Worker deployment. The checked-in
  policy and Worker copy now distinguish iPhone/iPad alert registration from
  the foreground-only Apple TV, Apple Watch, Apple Vision Pro, and selected Mac
  Catalyst experience, as well as the separate desktop and Chrome clients; a
  source change is not a publication or legal approval. Apple also requires a
  separate Apple TV Privacy Policy text field
  for tvOS; review the draft in
  `tvos/en-US/apple-tv-privacy-policy-draft.txt`, remove its draft marker only
  after legal/release-owner approval, and keep it consistent with the published
  policy. See Apple's
  [App information reference](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information).
- [ ] For visionOS, assess the final experience and set the required App Motion
  answer. Source inspection suggests a windowed interface with no virtual-camera
  movement, but only final-platform QA can authorize the portal answer.
- [ ] Follow `../app-store-connect-portal-audit-2026-08-22.md`; retain the
  2026-08-19 and 2026-08-20 audits as history without repurposing drafts.

Apple's current field limits are 4,000 characters for descriptions, 170
characters for promotional text, and 100 bytes for keywords. The source files
are checked against those limits before handoff. See
[Platform version information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/).
