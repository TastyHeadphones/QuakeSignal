# App Store Connect release checklist

## App record

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

## URLs

Use the deployed Cloudflare Worker origin:

- Privacy Policy: `https://quakesignal-api.hopeso.workers.dev/privacy`
- Support URL: `https://quakesignal-api.hopeso.workers.dev/support`
- Terms of Use: `https://quakesignal-api.hopeso.workers.dev/terms`

## App privacy answers

QuakeSignal does not track users or display advertising. Data used for App
Functionality:

- Coarse Location — used for distance/radius filtering; not linked to an
  account and not used for tracking.
- Device ID — APNs device token used only to deliver opted-in notifications;
  not linked to an account and not used for tracking.

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
- 1–10 iPhone screenshots per localization
- Preferred 6.9-inch portrait sizes: 1260 × 2736, 1290 × 2796, or
  1320 × 2868 pixels
- Existing 1206 × 2622 captures are valid 6.3-inch screenshots, but a
  6.9-inch set should be uploaded as the primary product-page set.

## Signing and upload

1. Sign in to an Apple Developer Program account in Xcode.
2. Select its Team for the QuakeSignal target and confirm the bundle ID.
3. Enable Push Notifications for the App ID. Do not add Critical Alerts
   unless Apple has granted that restricted entitlement.
4. Create the app record in App Store Connect.
5. Archive with Xcode 26.6 or another currently supported stable release.
6. Validate the archive, then upload it to TestFlight and App Store Connect.
7. Complete age rating, content rights, privacy, export compliance, localized
   metadata, and screenshot fields.
8. Test the uploaded build in TestFlight before submitting it to App Review.
