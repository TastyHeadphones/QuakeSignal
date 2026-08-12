# App Store Connect release kit

This directory is the source of truth for QuakeSignal's localized App Store
metadata and screenshot plan. Upload only assets captured from the signed,
shipping build; never use a system permission prompt, a real device token, an
exact current location, or a test-push result in product-page imagery.

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
- Version: `1.0`
- Copyright: `2026 UniSphereco LLC`

The bundle ID must be registered to the selected Apple Developer team before
archiving. If `com.quakesignal.app` is unavailable in that team, change it in
`project.yml`, regenerate the Xcode project, and update the APNs Worker secret.

### Build-number rule

The initial upload uses `CFBundleVersion` `1`. App Store Connect will reject a
repeat upload with the same build number. Before any later TestFlight upload,
update `CURRENT_PROJECT_VERSION` in `project.yml` and the production
`APP_ATTEST_ALLOWED_BUNDLE_VERSIONS` value in `backend/cloudflare/wrangler.jsonc`
in the same reviewed release, then update the intentional `1` guard in
`.github/workflows/ios.yml`. Deploy that Worker configuration through the
protected Cloudflare workflow before using the same numeric `build_number`
input in **iOS → Run workflow**. Do not override only the workflow input: the
current workflow intentionally accepts only the checked-in initial build.

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
approved merely because this endpoint exists. This exact `workers.dev` hostname
is approved for the production release; verify its public TLS and the HTTPS
responses for all three URLs immediately before submission. The app uses
Cloudflare's public certificate; do not ship a private CA, a private root, or
an iOS client-mTLS certificate.

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

QuakeSignal is an independent, non-official earthquake information app. It
aggregates third-party public seismic data from the Wolfx Open API and
prominently directs users to official announcements. The app does not claim
government affiliation, and notification delivery is described as
best-effort.

No account or review credentials are required. Onboarding can be completed
without granting notifications or location. The app remains useful with a
selected city or with no location permission. Background push delivery can be
tested only after the production APNs secrets are configured.

## Required release assets

- 1024 × 1024 App Store icon: already in `Assets.xcassets`
- 1–10 iPhone screenshots per localization; the five planned frames are in
  [`screenshot-manifest.json`](./screenshot-manifest.json)
- Primary product-page set: 6.5-inch portrait, at `1242 × 2688` pixels
- Optional QA/reference sets: 6.9-inch portrait, at `1260 × 2736`,
  `1290 × 2796`, or `1320 × 2868` pixels; or 6.3-inch portrait, at
  `1179 × 2556` or `1206 × 2622` pixels
- JPEG or PNG only, with no alpha channel or transparency. The capture helper
  emits high-quality JPEG files to guarantee an uploadable, opaque asset.

The existing files in `docs/screenshots/` are 6.3-inch reference images only.
They contain an alpha channel and must not be uploaded as-is.

### Capture workflow

1. Build and install the exact Release candidate on an iPhone 6.5-inch
   Simulator. If only the current `QuakeSignal Test` simulator is available,
   capture an optional 6.3-inch QA set and create the primary set later on a
   supported 6.5-inch simulator.
2. For each locale, launch the installed app with the matching language and
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
3. Navigate manually to the screen named by the manifest. Do not capture
   notification permission dialogs, a test notification, an active emergency
   alert, or private details.
4. From that visible screen, run the helper. It refuses to overwrite an
   existing approved asset and validates the rendered device size:

   ```sh
   ios/AppStore/scripts/capture-screenshot.sh \
     --device booted --class 6.5 en-US 01-home
   ```

   Use `--class 6.9` or `--class 6.3` only for optional QA/reference sets. The
   helper writes `ios/AppStore/screenshots/<locale>/iphone-<class>/<frame>.jpg`.
5. Review every capture at full size, then upload one consistent 6.5-inch
   sequence per localization to the iOS version in App Store Connect. Do not
   mix display classes within one uploaded localization.

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
   complete the draft `1.0` metadata.
6. Archive with Xcode 26.6 or another currently supported stable release.
7. Validate the archive, then upload it to TestFlight and App Store Connect.
8. Complete age rating, content rights, privacy, export compliance, localized
   metadata, and screenshot fields.
9. Test the uploaded build in TestFlight on physical hardware before submitting
   it to App Review. Verify the production App Attest registration, refresh,
   token-bound unsubscribe, and controlled test-push path against
   `https://quakesignal-api.hopeso.workers.dev`; a Simulator or staging-bypass result is
   insufficient. Also test unsubscribe after a registered launch in which APNs
   has not supplied a token: its exact empty (`{}`) assertion must remove only
   the subscription owned by the current App Attest key. Also verify that a
   fresh production attestation plus the exact APNs token can rebind after a
   Keychain reset/reinstall, while an assertion or empty body from a different
   key is refused. Verify the support deletion path when APNs has not supplied
   the token after a reset. Verify foreground live updates after the Wolfx
   WebSocket service has recovered. When a socket route is unavailable, also
   confirm that the app waits 90 seconds and then refreshes its display-only
   HTTPS snapshot at most once every five minutes, without presenting a local
   emergency alert for the recovered history.
10. Have a release reviewer promote
    `APP_ATTEST_PRODUCTION_ENFORCED=true` and run the protected Cloudflare
    launch deployment with `bootstrap_testflight` disabled. Only after that
    launch promotion may the build be submitted to App Review or released
    publicly.
