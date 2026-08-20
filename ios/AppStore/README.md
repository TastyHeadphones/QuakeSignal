# App Store Connect release kit

This directory is the source of truth for QuakeSignal's localized App Store
metadata and screenshot plan. A reproducible Debug Simulator capture is only
an unapproved visual candidate, even when its exact source, runtime, build
settings, and hashes are recorded. Upload only after a named marketing/release
owner approves the images and the required signed public-`Release` parity has
been recorded separately. Never use a system permission prompt, a real device
token, an exact current location, or a test-push result in product-page imagery.

| App Store Connect field | Versioned source |
| --- | --- |
| English subtitle / description / promotional text / keywords | `en-US/` |
| Japanese and Simplified Chinese subtitle and other draft copy | `ja/`, `zh-Hans/` (do not upload without name approval) |
| App Review notes | `review-notes.txt` |
| Submission-answer worksheet | `submission-answers.md` |
| Pre-submission checklist | `submission-checklist.md` |
| Historical build-7 screenshot evidence | `screenshot-manifest-v1.1.json`, `screenshot-provenance-v1.1.json` |
| Historical, superseded build-8 candidate manifest/provenance | `screenshot-manifest-v1.1-build8.json`, `screenshot-provenance-v1.1-build8.json` |
| Historical, superseded build-8 English candidate images | `screenshots-v1.1-build8/en-US/` |
| Immutable historical screenshot catalog and final-set pointer | `screenshot-set-index-v1.1-build8.json` |
| Future complete final-commit Apple release sets | `screenshot-release-sets-v1.1-build8/<source-commit>/` |
| Coordinated native-platform release runbook | `apple-platform-release.md` |
| tvOS / visionOS / Watch / Mac Catalyst metadata and screenshot plans | `platforms/` |
| Historical, superseded tvOS / visionOS / Watch candidate packages | `platforms/screenshot-candidates-v1.1-build8/` |
| Release-owner Xcode Cloud, Mac, and content-rights decisions | `release-owner-decisions-2026-08-20.md` |
| Read-only App Store Connect state and safe portal sequence | Historical `app-store-connect-portal-audit-2026-08-19.md` plus latest `app-store-connect-portal-audit-2026-08-20.md` addendum |

## App record

The native iOS/iPadOS, tvOS, visionOS, and Mac Catalyst products share the
existing **QuakeSignal** App Store Connect record (Apple ID `6800642443`) and
`com.quakesignal.app` bundle ID, forming Apple's multi-platform Universal
Purchase relationship. The embedded Watch companion also belongs to the iOS
product in that record. The release owner selected the SwiftUI Mac Catalyst
target as the sole Mac storefront route and decided to disable Designed for
iPad on Mac; the live App Store Connect availability checkbox still must be
cleared and saved during the authorized portal reconciliation step.
Do not attach or submit the separate Tauri package from Apple ID `6800642853`
for this release.

The latest read-only portal state is in
[`app-store-connect-portal-audit-2026-08-20.md`](./app-store-connect-portal-audit-2026-08-20.md).
The later product decisions are recorded in
[`release-owner-decisions-2026-08-20.md`](./release-owner-decisions-2026-08-20.md).
Mac Catalyst still requires its own signed build-8 evidence, QA, screenshots,
metadata, and named approval before the shared macOS draft is used.

- Name: `QuakeSignal`
- English (U.S.) subtitle: `Earthquake Reports & Safety`
- Primary language: English (U.S.)
- Team: `UniSphereco LLC` (`5TT564H883`)
- Bundle ID: `com.quakesignal.app`
- SKU: `quakesignal-ios`
- Primary category: Weather
- Secondary category: Utilities
- Price: Free
- Version: `1.1`
- Copyright: `2026 UniSphereco LLC`

The bundle ID must be registered to the selected Apple Developer team before
archiving. If `com.quakesignal.app` is unavailable in that team, change it in
`project.yml`, regenerate the Xcode project, and update the APNs Worker secret.

### Build-number rule

Version `1.0` build `6` is already Ready for Distribution. Builds `2` through
`5` are historical QA or superseded archives and must not be attached to the
1.1 submission.

App Store Connect rejects a repeat upload with the same build number. The
checked-in release candidate is coordinated as version `1.1`,
`CFBundleVersion` `8`: `CURRENT_PROJECT_VERSION` is `8`, the Worker App Attest
allow-list is `1,2,3,4,5,6,7,8`, and the protected archive workflows default
to `8`. Older allowlisted versions remain deliberately available to installed
clients. Deploy all migrations through `0012` and the matching Worker policy
before uploading build `8`; each protected archive lane then proves the live
`/healthz` fingerprint admits that build before certificate import.

Upload, processing, and internal group assignment do not by themselves
establish physical-device evidence, Content Rights, protected launch
promotion, App Review, or public release. The checked-in verifier rejects a
mismatched manual `build_number`, Xcode project, Worker policy, or archive
command before signing material is used. Do not override only the workflow
input or reuse a historical build number.
The protected TestFlight archive and production Worker deployment share a
non-cancelling concurrency lock, so the checked live policy cannot change
between that smoke proof and IPA upload.

## Localized product-page names require release-owner approval

The English (U.S.) primary product-page name is `QuakeSignal`. Before adding
Japanese or Simplified Chinese App Store localizations, the release owner must
approve the exact localized product-page name after an App Store availability
and trademark review. Do **not** infer that decision from the existing in-app
resource labels (`QuakeSignal` in English and `震息` in Japanese/Simplified
Chinese) or from the localized descriptions.

Until that approval is recorded, create the English primary record only and
keep `QuakeSignal` as its name. The Japanese and Simplified Chinese copy and
screenshots in this directory remain review-ready drafts, not authorization to
set a different customer-facing App Store name. Apple permits localized app
names, but they are App Store record fields rather than a by-product of the
bundle's display-name resources; see Apple's
[App information reference](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information).

## Final public URLs

Use the user-approved public Cloudflare Workers production endpoint below. Do
not substitute another personal, preview, or staging Worker hostname:

- Privacy Policy URL: `https://quakesignal-api.hopeso.workers.dev/privacy`
- Support URL: `https://quakesignal-api.hopeso.workers.dev/support`
- Customer-facing Terms of Use URL: `https://quakesignal-api.hopeso.workers.dev/terms`

The Privacy Policy and Support URLs are the App Store Connect values. Use the
Terms URL only where a release-owner-approved customer-facing terms link or
custom license agreement requires it; do not imply that a custom EULA has been
approved merely because this endpoint exists. The current Settings screen links
only to Privacy Policy and Support, so do not describe the Terms endpoint as an
in-app Settings link unless a separately reviewed UI change adds one. This exact
`workers.dev` hostname is approved for the production release; verify its public
TLS and the HTTPS responses for all three URLs immediately before submission.
The app uses Cloudflare's public certificate; do not ship a private CA, a private
root, or an iOS client-mTLS certificate.

## App privacy answers

QuakeSignal does not track users or display advertising. Data used for App
Functionality:

- Coarse Location — one coordinate derived from the current location or a
  selected city's coordinate, rounded to a 0.1° grid before registration. It
  is used for distance/radius filtering when the person opts into alerts and is
  not used for tracking.
- Device ID — an APNs device token is used only to deliver opted-in
  notifications. It is not used for tracking.
- Other Data — alert sources, threshold, radius, city label, locale, and quiet
  hours preferences are stored with the device token to match and localize the
  alerts the person requested. They are not used for tracking.
- Other Data — the App Attest integrity record (opaque key identifier, public
  verification key, Apple receipt, assertion counter, integrity timestamps,
  and any Apple-supplied release category/version) is stored with the device
  registration to prevent forged or replayed notification requests. It is not
  used for tracking.

For the App Privacy questionnaire, confirm the final implementation with the
release owner before submitting. An APNs device token is tied to a device, so
it should be declared as an **Identifier collected for App Functionality** and
marked as **linked to the user/device** if it is stored with alert preferences.
Coarse Location stored with that token should be assessed the same way. Neither
data type is used for tracking. Do not select "Data Not Collected" simply
because the app has no account. Declare the linked **Other Data** category for
the alert-preference and App Attest integrity inventories as App Functionality
too; it matches the privacy manifest and policy.

The app has no user account, analytics SDK, advertising SDK, purchases, or
third-party login.

## Review notes

Use the versioned [`review-notes.txt`](./review-notes.txt) file when filling
the App Review notes field. The auditable
[`submission-answers.md`](./submission-answers.md) worksheet keeps the
privacy inventory, URLs, and deliberately pending legal/release-owner answers
in one place. Complete the companion
[`submission-checklist.md`](./submission-checklist.md) before copying any
value into App Store Connect; neither artifact authorizes completion of a
pending field.

## Required release assets

> **Build-8 screenshot block:** the existing 30-file
> `screenshot-manifest-v1.1.json` / `screenshot-provenance-v1.1.json` set
> truthfully records a build-7 simulator capture. Preserve it as historical
> evidence. Do not relabel or upload it for build 8. The separate build-8
> manifest, provenance, and ten English iPhone/iPad files are source-frozen
> Debug Simulator candidates only: their status is
> `unapproved-debug-simulator-candidate`, `uploadApproved` and
> `signedReleaseEvidence` are `false`, and `reviewer` is `null`. Those bytes
> predate the current JMA-only and Mac Catalyst source changes, so they are now
> historical evidence and intentionally fail the current-source guard.
> Recapture the complete final build-8 commit; never rewrite their provenance.

[`screenshot-set-index-v1.1-build8.json`](./screenshot-set-index-v1.1-build8.json)
locks all four historical byte trees independently of current-source
eligibility. Its `activeReleaseSet` is deliberately `null` until one exact
final source commit has a complete 26-frame set: 10 iPhone/iPad, 3 Apple TV,
3 Apple Watch, 5 Apple Vision Pro, and 5 Mac Catalyst images. A future set
belongs only under
`screenshot-release-sets-v1.1-build8/<40-character-source-commit>/`; do not
reuse any occupied historical directory.

- 1024 × 1024 App Store icon: already in `Assets.xcassets`
- Historical build-7 screenshot inventory: exactly the 30 files declared by
  [`screenshot-manifest-v1.1.json`](./screenshot-manifest-v1.1.json) and
  [`screenshot-provenance-v1.1.json`](./screenshot-provenance-v1.1.json)
- Historical build-8 candidate inventory: exactly five English (U.S.) 6.5-inch iPhone
  portraits at `1242 × 2688` and five English (U.S.) 13-inch iPad portraits at
  `2064 × 2752`, as declared by
  [`screenshot-manifest-v1.1-build8.json`](./screenshot-manifest-v1.1-build8.json)
  and
  [`screenshot-provenance-v1.1-build8.json`](./screenshot-provenance-v1.1-build8.json)
- Historical native build-8 candidate inventory: exactly three Apple TV PNGs at
  `1920 × 1080`, three Apple Watch PNGs at `410 × 502`, and five Apple Vision
  Pro PNGs at `3840 × 2160`, with full unapproved provenance under
  [`platforms/screenshot-candidates-v1.1-build8/`](./platforms/screenshot-candidates-v1.1-build8/).
  These packages are bound to b461 and do not satisfy the current-source gate.
- No build-8 Japanese or Simplified Chinese screenshot set is captured or
  publishable until its localized name, trademark, and availability approvals
  are recorded.
- JPEG or PNG only, with no alpha channel or transparency. The capture helper
  emits high-quality JPEG files to guarantee an uploadable, opaque asset.

Do not upload the legacy `screenshot-manifest.json`, `screenshot-provenance.json`,
`screenshots/`, or `docs/screenshots/` sets for release 1.1. They predate the
iPad-capable target and the final map/alert-preference UI.

### Capture workflow

1. Freeze and commit the complete product, capture harness, plan, and release
   contract. Capture only when `HEAD` is that exact full commit, the worktree is
   clean, and the ignored `ios/QuakeSignal/Supporting/Debug.local.xcconfig`
   override is absent. Never alter or relabel any historical screenshot tree.
2. Validate the explicit ten-frame English (U.S.) plan. Every entry binds one
   reviewed selector to either the 6.5-inch iPhone or 13-inch iPad display
   class; a missing, duplicate, reordered, cross-class, or pre-approved entry
   fails before a build or Simulator launch:

   ```sh
   ruby ios/ScreenshotAutomation/ios-screenshot-plan.test.rb
   ruby ios/ScreenshotAutomation/ios-screenshot-plan.rb --json
   ```

3. Capture the complete iPhone/iPad set atomically into a new absolute
   directory outside the repository. The harness builds the source-matching
   Debug Simulator app once, creates exactly two disposable reviewed devices,
   captures all ten ordered frames, validates the real pixels and visible
   route, records build/install/runtime evidence, seals the complete package,
   and refuses partial or preexisting output:

   ```sh
   SOURCE_COMMIT="$(git rev-parse HEAD)"
   IOS_CAPTURE_PARENT="/Volumes/RC20/QuakeSignalScreenshotCandidates"
   mkdir -p "$IOS_CAPTURE_PARENT"
   IOS_CAPTURE_ROOT="$IOS_CAPTURE_PARENT/ios-ipados-${SOURCE_COMMIT}"
   TMPDIR=/Volumes/RC20 \
     ios/ScreenshotAutomation/capture-ios-screenshot-set.sh "$IOS_CAPTURE_ROOT"
   ```

   Do not navigate manually or substitute the legacy visible-screen helper.
   Each app launch must contain all four matching fixture inputs, which the
   harness supplies and verifies:

   - `--quakesignal-screenshot-automation`
   - `QUAKESIGNAL_SCREENSHOT_AUTOMATION=1`
   - `--quakesignal-screenshot-frame=<reviewed-selector>`
   - `QUAKESIGNAL_SCREENSHOT_FRAME=<the-same-reviewed-selector>`

   An invalid or wrong-device selector fails closed instead of falling back to
   Home. The fixed reports are finalized historical JMA records; the fixture
   performs no live networking, onboarding, permission prompt, location read,
   notification registration, or emergency-alert simulation.
4. Inspect every full-resolution JPEG and its retained native PNG, semantic
   evidence, logs, source/build binding, and aggregate provenance. Keep
   `uploadApproved: false`, `reviewer: null`, and all signed-Release fields
   empty. Capture English (U.S.) only until Japanese and Simplified Chinese
   localized-name, trademark, and availability approvals are recorded.
5. Archive the sealed directory without changing it. The final assembler
   independently parses the ZIP and requires its complete path and byte
   inventory to equal the sealed raw package; an arbitrary, partial, mutated,
   symlinked, or extra-entry archive is rejected:

   ```sh
   ditto -c -k --norsrc --keepParent \
     "$IOS_CAPTURE_ROOT" "${IOS_CAPTURE_ROOT}.zip"
   ```

6. Capture and seal the exact tvOS, watchOS, visionOS, and Mac Catalyst sets
   from the same source commit using their reviewed atomic harnesses. When all
   five raw packages and independent archives pass, use
   `.github/scripts/assemble-apple-screenshot-release-set.rb` to create the
   new canonical source-addressed 26-frame directory and a *separate* proposed
   index file outside the repository. The assembler never creates approval,
   never overwrites the checked-in index, and never touches historical bytes.
7. Separately compare every candidate with the matching signed public
   `Release` archive. Only after five signed-artifact hashes, platform parity
   evidence, and a later named marketing/release-owner approval may an
   operator activate the proposed index and upload the complete sequences.
   Do not mix source commits, display classes, candidates, or signed builds.

Ordinary listing validation locks the historical catalog and permits the final
pointer to remain null:

```sh
ruby .github/scripts/verify-apple-screenshot-release-set.rb
```

The protected release handoff must instead name the exact commit and fails
unless the complete source-current set plus a separate named, signed-Release
parity approval for all five platforms is present:

```sh
ruby .github/scripts/verify-store-assets.rb \
  --require-build8-screenshot-release-ready \
  --expected-source-commit="$SOURCE_COMMIT"
```

Apple's current [screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)
allow one to ten screenshots and list the accepted display-size resolutions.

## Signing and upload

1. Sign in to an Apple Developer Program account in Xcode.
2. Select its Team for the QuakeSignal target and confirm the bundle ID.
3. Enable Push Notifications, App Attest, and Time Sensitive Notifications for
   the shared App ID as required by the iPhone/iPad product. Complete the
   one-time Xcode Cloud onboarding in Xcode, use automatic signing, and leave
   every `QUAKESIGNAL_*_PROFILE_NAME` workflow variable absent. Validate the
   Apple-managed profile and signed archive rather than adding a manual profile
   secret to Xcode Cloud.
   visionOS remains foreground-only and its signed target must not contain
   APNs, App Attest, Time Sensitive, or Critical Alerts entitlements. Do not add
   Critical Alerts anywhere unless Apple has granted that restricted
   entitlement.
4. Verify the user-approved production Worker
   `https://quakesignal-api.hopeso.workers.dev` and its public Cloudflare TLS,
   then make the protected TestFlight-bootstrap deployment
   before the Release archive. That deployment verifies `/healthz`, `/privacy`,
   `/support`, and `/terms`; the archive workflow pins this exact
   `workers.dev` origin. Do not use a private CA or client mTLS. The
   Debug/Simulator client may use only a different isolated staging Worker in
   App Attest development mode; it is not an archive or release-test
   substitute. Debug defaults to the fail-closed
   `https://quakesignal-staging.invalid`; before physical Debug testing, copy
   `QuakeSignal/Supporting/Debug.local.xcconfig.example` to the ignored
   `Debug.local.xcconfig` and set the owner-controlled isolated Worker URL (or
   pass `QUAKESIGNAL_API_BASE_URL` to `xcodebuild` in CI). That staging host
   uses public `workers.dev` TLS, a separate D1/Queue/rate-limit/APNs sandbox
   resource set, and the protected `cloudflare-staging` workflow described in
   [the Cloudflare runbook](../../docs/CLOUDFLARE_PRODUCTION.md#isolated-debug-staging-worker).
   It must never be copied into a Release archive, TestFlight build, App Store
   Connect URL, or production secret.
5. Open the existing App Store Connect record (Apple ID `6800642443`); do not
   create a duplicate. After the Cloudflare bootstrap has made the final URLs
   live, set its Privacy Policy and Support URLs to the values above and
   complete the draft `1.1` metadata.
6. Build `1.1 (8)` through the single protected Xcode Cloud workflow
   `QuakeSignal 1.1 (8) Native Release` described in
   [`apple-platform-release.md`](./apple-platform-release.md). Historical 1.0
   builds are not evidence for this release and must not be attached to the 1.1
   App Store version.
7. Complete age rating, content rights, privacy, export compliance, localized
   metadata, and screenshot fields. For Content Rights, use the reviewed
   published-terms mapping in
   [`content-rights-evidence.md`](./content-rights-evidence.md). The release
   owner decided not to send the Wolfx request. Recheck current Wolfx/Open API
   and applicable source terms, enabled sources, attribution, product behavior,
   relay event retention, and intended territories at action time. Map official
   terms for every enabled non-JMA feed or disable it; do not represent a
   private license or assume that open-source licensing alone grants
   third-party rights.
8. After protected upload and processing, test release candidate `1.1 (8)` on
   physical hardware
   for the normal production registration, refresh, unsubscribe, re-enrollment,
   and controlled training-push evidence. Follow the exact, privacy-safe
   [`iOS TestFlight physical-device runbook`](../../docs/IOS_TESTFLIGHT_PHYSICAL_QA.md)
   for production App Attest registration, refresh, token-bound unsubscribe,
   key-owned empty-body unsubscribe, re-enrollment, and the controlled
   training-push path against
   `https://quakesignal-api.hopeso.workers.dev`; a Simulator or staging-bypass result is
   insufficient. If deterministic background/terminated evidence requires an
   `InternalQA` build with **Schedule Background Test Alert**, build it from the
   frozen 1.1 source under the reviewed temporary production test window and
   never attach it to App Review. A public `Release` deliberately does not
   contain that control. The evidence remains incomplete until it is exercised
   on a physical device.
   It also identifies the separate controlled evidence needed for a verified
   fresh-key rebind after reinstall/restore. Verify foreground live updates
   after the Wolfx WebSocket service has recovered. When a socket route is
   unavailable, also confirm that the app waits 90 seconds and then refreshes
   its display-only HTTPS snapshot at most once every five minutes, without
   presenting a local emergency alert for the recovered history.
9. Have a release reviewer promote
    `APP_ATTEST_PRODUCTION_ENFORCED=true` and run the protected Cloudflare
    launch deployment with `bootstrap_testflight` disabled.
10. Only after build `1.1 (8)` is uploaded, processed, physically verified,
    launch promotion and every other public-release gate are complete, attach
    it to the App Store version if it remains the accurate reviewed candidate.
    If the iOS
    source, Worker policy, or signing inputs change after this upload, increment
    the build number, coordinate the policy, sign, upload, and validate a new
    Release candidate instead. Do not attach build `2` to the App Store version
    before App Review or public release.
