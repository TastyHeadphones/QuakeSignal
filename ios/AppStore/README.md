# App Store Connect release kit

This directory is the source of truth for QuakeSignal's localized App Store
metadata and screenshot plan. Upload only assets captured from the frozen
public `Release` UI that matches the shipping build; a simulator capture is
acceptable only when its exact runtime and source are recorded in the release
provenance. Never use a system permission prompt, a real device token, an exact
current location, or a test-push result in product-page imagery.

| App Store Connect field | Versioned source |
| --- | --- |
| English description / promotional text / keywords | `en-US/` |
| Japanese and Simplified Chinese draft copy | `ja/`, `zh-Hans/` (do not upload without name approval) |
| App Review notes | `review-notes.txt` |
| Submission-answer worksheet | `submission-answers.md` |
| Pre-submission checklist | `submission-checklist.md` |
| Release 1.1 screenshot provenance | `screenshot-provenance-v1.1.json` |

## App record

The **separate iOS App Store Connect record** for this client has been created
as **QuakeSignal** (Apple ID `6800642443`). The macOS client uses
`com.quakesignal.desktop`, while Apple permits a single multi-platform
purchase record only when every platform shares the same bundle ID. Do not
select macOS for this record, create a duplicate record, or imply a Universal
Purchase.

- Name: `QuakeSignal`
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
`CFBundleVersion` `7`: `CURRENT_PROJECT_VERSION` is `7`, the Worker App Attest
allow-list is `1,2,3,4,5,6,7`, and the protected archive workflow defaults to
`7`. Older allowlisted versions remain deliberately available to installed
clients. Deploy migration `0010` and the matching Worker policy before
uploading build `7`; the protected archive lane then proves the live
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

- 1024 × 1024 App Store icon: already in `Assets.xcassets`
- Release 1.1 screenshot inventory: exactly the 30 files declared by
  [`screenshot-manifest-v1.1.json`](./screenshot-manifest-v1.1.json) and
  [`screenshot-provenance-v1.1.json`](./screenshot-provenance-v1.1.json)
- Five 6.5-inch iPhone portrait screenshots per localization at
  `1242 × 2688` pixels
- Five 13-inch iPad portrait screenshots per localization at
  `2064 × 2752` pixels
- JPEG or PNG only, with no alpha channel or transparency. The capture helper
  emits high-quality JPEG files to guarantee an uploadable, opaque asset.

Do not upload the legacy `screenshot-manifest.json`, `screenshot-provenance.json`,
`screenshots/`, or `docs/screenshots/` sets for release 1.1. They predate the
iPad-capable target and the final map/alert-preference UI.

### Capture workflow

1. Build and install the exact public `Release` candidate for version 1.1,
   build 7, on the devices named in
   [`screenshot-manifest-v1.1.json`](./screenshot-manifest-v1.1.json). Before
   uploading, verify that
   [`screenshot-provenance-v1.1.json`](./screenshot-provenance-v1.1.json)
   records the frozen release commit and that every listed SHA-256 still
   matches.
2. Capture both the primary 6.5-inch iPhone and 13-inch iPad sets. Do not
   substitute a legacy 6.3-inch QA/reference set for either upload family.
3. For each locale, launch the installed app with the matching language and
   locale. For example, after the app has been installed:

   ```sh
   xcrun simctl terminate booted com.quakesignal.app || true
   xcrun simctl launch booted com.quakesignal.app \
     -AppleLanguages '(ja)' -AppleLocale ja_JP
   ```

   Use `en_US` / `(en)` and `zh_CN` / `(zh-Hans)` for the other two localizations.
   Complete onboarding with a selected city rather than precise current
   location. Wait for the content to finish loading, and use the same city and
   benign report state for every frame in that locale.
4. Navigate manually to the screen named by the manifest. Do not capture
   notification permission dialogs, a test notification, an active emergency
   alert, or private details.
5. From that visible screen, run the helper. It refuses to overwrite an
   existing approved asset and validates the rendered device size:

   ```sh
   ios/AppStore/scripts/capture-screenshot.sh \
     --device booted --class 6.5 en-US 01-home

   ios/AppStore/scripts/capture-screenshot.sh \
     --device booted --class ipad-13 en-US 01-home
   ```

   The helper defaults to `screenshots-v1.1` and writes each frame under the
   matching locale and device-family directory.
6. Review every capture at full size, then upload the complete iPhone and iPad
   sequence for each localization to the iOS version in App Store Connect. Do
   not mix display classes within one uploaded localization.

Apple's current [screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)
allow one to ten screenshots and list the accepted display-size resolutions.

## Signing and upload

1. Sign in to an Apple Developer Program account in Xcode.
2. Select its Team for the QuakeSignal target and confirm the bundle ID.
3. Enable Push Notifications and App Attest for the App ID, then refresh the
   App Store provisioning profile so the signed archive contains production
   App Attest support. Do not add Critical Alerts unless Apple has granted
   that restricted entitlement.
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
6. Upload `1.1 (7)` through the protected TestFlight workflow. Historical 1.0
   builds are not evidence for this release and must not be attached to the 1.1
   App Store version.
7. Complete age rating, content rights, privacy, export compliance, localized
   metadata, and screenshot fields.
   Before certifying content rights for Wolfx-supplied earthquake data, obtain
   and preserve written upstream permission using
   [`docs/WOLFX_PERMISSION_REQUEST.md`](../../docs/WOLFX_PERMISSION_REQUEST.md).
8. After protected upload and processing, test release candidate `1.1 (7)` on
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
10. Only after build `1.1 (7)` is uploaded, processed, physically verified,
    launch promotion and every other public-release gate are complete, attach
    it to the App Store version if it remains the accurate reviewed candidate.
    If the iOS
    source, Worker policy, or signing inputs change after this upload, increment
    the build number, coordinate the policy, sign, upload, and validate a new
    Release candidate instead. Do not attach build `2` to the App Store version
    before App Review or public release.
