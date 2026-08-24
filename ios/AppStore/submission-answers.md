# iOS App Store Connect submission record

This is the reviewed-source worksheet for the existing **QuakeSignal** iOS
record (Apple ID `6800642443`). It is not a substitute for App Store Connect
fields, legal review, or the release owner's final confirmation. Copy values
only after the listed evidence is complete. Use it together with
[`submission-checklist.md`](./submission-checklist.md): every row marked
**PENDING** is a non-submission condition, not a value to infer or certify.

## Record and version

| Field | Intended value / status | Evidence |
| --- | --- | --- |
| Name | `QuakeSignal` — approved English (U.S.) name | `README.md` |
| Subtitle | `Earthquake Reports & Safety` — exact English (U.S.) draft, 27 characters | `en-US/subtitle.txt` |
| Bundle ID | `com.quakesignal.app` | `ios/project.yml` |
| SKU | `quakesignal-ios` | `README.md` |
| Version | `1.1` | `ios/project.yml` |
| Release candidate | Version `1.0 (6)` is already Ready for Distribution. Builds `1.1 (7)` through `1.1 (16)` are historical TestFlight or superseded evidence. The coordinated native candidate is `1.1 (17)`: its source-bound protected uploads have processed, are Ready to Submit, and are selected in their native drafts with source-controlled B17 review notes saved. Platform/physical-device QA, approved screenshots, accountable contact verification, final portal answers, and App Review remain **PENDING**. Builds `1.0 (2)` through `1.0 (5)` remain historical QA or superseded. | App Store Connect record `6800642443`; `app-store-connect-build17-handoff-2026-08-24.md`; `README.md` build-number rule |
| TestFlight build 2 | Legacy QA-only; never attach it to App Review | `README.md`, `docs/IOS_TESTFLIGHT_PHYSICAL_QA.md` |
| Primary / secondary category | Weather / Utilities | `README.md` |
| Price / availability | Free; public distribution is configured for 175 countries or regions; final release timing remains **PENDING** | App Store Connect audit 2026-08-22 |
| Copyright | `2026 UniSphereco LLC` | `README.md` |

## Customer-facing URLs

| Field | Exact value | Release check |
| --- | --- | --- |
| Privacy Policy URL | `https://quakesignal-api.hopeso.workers.dev/privacy` | GET 200 over public HTTPS immediately before submission |
| Support URL | `https://quakesignal-api.hopeso.workers.dev/support` | GET 200 over public HTTPS immediately before submission |
| Terms URL, if requested | `https://quakesignal-api.hopeso.workers.dev/terms` | Use only with release-owner approval for a customer-facing terms link/EULA; it is not currently linked from the app's Settings page |

The approved endpoint uses Cloudflare-managed public Web-PKI TLS. Do not add a
private CA, an origin certificate, or an iOS client certificate.

## Privacy questionnaire source answers

| Apple data type | Collected | Linked | Tracking | Purpose | Source evidence |
| --- | --- | --- | --- | --- | --- |
| Coarse Location | Yes, only for opted-in nearby-alert matching | Yes, when stored with alert preferences | No | App Functionality | `ios/QuakeSignal/Resources/PrivacyInfo.xcprivacy`, `docs/PRIVACY.md` |
| Device ID (APNs token) | Yes, only for opted-in push delivery | Yes | No | App Functionality | `ios/QuakeSignal/Resources/PrivacyInfo.xcprivacy`, `docs/PRIVACY.md` |
| Other Data (alert preferences and App Attest integrity record) | Yes | Yes | No | App Functionality | `ios/QuakeSignal/Resources/PrivacyInfo.xcprivacy`, `docs/PRIVACY.md` |
| Names, account data, contacts, advertising ID, analytics | No | N/A | No | N/A | `docs/PRIVACY.md` |

Only an opted-in iPhone or iPad registration sends the three declared data
categories to QuakeSignal-operated infrastructure. Watch, TV, Vision, and Mac
Catalyst do not independently register or upload those values. Their direct
Wolfx requests and public support/privacy-page loads expose ordinary connection
metadata to the relevant network providers under those providers' policies;
the final App Privacy questionnaire classification remains a release-owner and
legal review item. The shared iOS/Catalyst product currently packages the
conservative universal privacy manifest; Catalyst behavior itself follows the
zero-registration scope documented above and in `docs/PRIVACY.md`.

Before submission, the release owner must compare these entries with the
current binary and App Privacy questionnaire wording. Do not choose “Data Not
Collected” merely because the app has no account.

## Review information

| Field | Value / source |
| --- | --- |
| Demo account | Not required |
| Sign-in required | No |
| Review notes | `review-notes.txt` |
| Contact name, email, phone | Saved from the authenticated Apple Developer Account Holder membership record without copying personal values into source; **PENDING** final visual confirmation in the pre-submission portal pass |
| Review route | Start the app, choose **Skip** for notification and location onboarding, then inspect Home, List, Map, Guide, and Settings; no account or review credential is required |
| Notes for background/notification behavior | Optional notifications are best-effort. A public Release exposes an ordinary foreground Send Test Alert control only after authorization, opt-in registration, and an APNs token; it has no delayed background-training control |

## Native platform drafts in this record

| Platform | Intended 1.1 (17) behavior | Portal / evidence status |
| --- | --- | --- |
| Apple Watch companion | JMA-only foreground compact dashboard embedded in the iOS upload; a fresh active warning can show protective guidance and the native Watch warning haptic, plus the custom sound mirrored from iPhone when selected. No independent APNs, App Attest, Time Sensitive/Critical Alerts, or background emergency delivery | Build `1.1 (12)` is historical evidence for a prior source. The Build-17 signed host upload is Ready to Submit and selected in the iOS draft. **PENDING** paired-device haptic/audio/mirroring QA, signed parity, named independent screenshot review, shared iOS description/review confirmation, and screenshot upload |
| tvOS | JMA-only foreground large-screen dashboard; reads `jma_eew` and `jma_eqlist` while open, with no APNs, App Attest, automatic alert audio, or background emergency alerts. System is visual-only; the Urgent and Japanese Voice sounds play only after an explicit Siri Remote action | Build `1.1 (12)` is historical evidence for a prior source. Build-17 is Ready to Submit and selected in the tvOS draft. **PENDING** approved screenshot upload, platform QA, reviewed privacy text, signed parity, named independent review, and final portal answers |
| visionOS | JMA-only full native windowed foreground app. Apple lists App Attest for visionOS, but not Push Notifications or Time Sensitive Notifications. QuakeSignal's protected alert registration requires App Attest plus APNs, so this target does not start that registration path when APNs is unavailable and has no Time Sensitive, Critical Alerts, or background emergency-delivery path. A qualifying JMA-issued update may appear in-app and play the selected local sound only while the app is open; QuakeSignal does not calculate a new local-intensity or arrival-time forecast. | Build `1.1 (12)` is historical evidence for a prior source. Build-17 is Ready to Submit and selected in the visionOS draft. **PENDING** corrected App Attest/APNs wording in the portal, platform QA, signed parity, named independent review, screenshot upload, App Motion, and final answers |
| Mac Catalyst | JMA-only SwiftUI native Mac storefront build from the shared `QuakeSignal` target; foreground/local reports, map, guide, settings, and full-window fresh-warning presentation with the selected System, Urgent, or Japanese Voice sound. It has no independent APNs, App Attest, background-alert, or Critical Alert path, and stops monitoring/audio when inactive. | **SELECTED** as the sole Mac route. Build `1.1 (12)` is historical evidence for a prior source; the shared draft remains manual release and Tauri record `6800642853` remains unused. Build-17 is Ready to Submit and selected in the Mac Catalyst draft. **PENDING** Mac QA, exact approved screenshots, signed parity, named independent approval, availability, and final portal reconciliation |

Use `platforms/` for exact copy, review notes, immutable screenshot plans, and
the separately retained immutable historical candidate packages. Their own
capture-time README text is part of the locked evidence and does not make those
bytes current or uploadable.
Use the 2026-08-19 and 2026-08-20 audits as historical evidence and
`app-store-connect-build17-handoff-2026-08-24.md` for the current portal/build
handoff and
safe action order. Do not delete or
repurpose an existing draft from this worksheet.

## Required human/legal decisions — do not infer these answers

| App Store Connect area | Required decision/evidence | Current status |
| --- | --- | --- |
| Content Rights | Current Wolfx Terms of Service and Open API documentation; JMA website terms and PDL 1.0; JMA's statutory relay-versus-new-forecast guidance; exact two-source scope; attribution/editing; no-resale/no-public-feed behavior; 89-day event/revision cutoff with next-successful-daily cleanup | **MAPPED FOR THE INTENDED JMA-ONLY BUILD 17; FINAL CHECK PENDING.** Only `jma_eew` and `jma_eqlist` are enabled; CENC/Sichuan/Fujian/Chongqing feeds are disabled. Notifications filter and relay normalized JMA-issued facts and do not calculate predicted local intensity or arrival time. The release owner decided not to send the Wolfx request. Operational cleanup failures can delay deletion. Final signed/deployed source proof, current-term/territory recheck, accountable review, and portal reconciliation remain pending. Do not claim open source grants rights or that a private Wolfx/JMA license or endorsement exists. |
| Age Rating | Answer Apple's current questionnaire from the final public build/content | **PENDING** release-owner review. Current source has no UGC/chat, advertising, purchases, gambling, sexual content, drug content, or unrestricted browser; family check-in fields are local notes rather than messaging. Reconfirm against Apple's then-current questions. |
| Export Compliance | Answer Apple's current encryption/export questions for the final signed archive | **PENDING** legal/release-owner confirmation. All four native platform Info.plists set `ITSAppUsesNonExemptEncryption=false`; the app uses system TLS plus CryptoKit/App Attest hashing and security, not a customer cryptography feature. Verify the signed archives and Apple's current wording before answering. |
| Availability / pricing schedule | Confirm the configured public distribution in 175 countries or regions and choose distribution timing | **TERRITORIES CONFIGURED — 2026-08-22; PENDING** final release-timing decision |
| Japanese / Simplified Chinese listing | Exact product-page names, availability, and trademark review | **PENDING**; keep English-only until approved |
| Mac storefront | SwiftUI Mac Catalyst through the shared native record; no simultaneous Designed-for-iPad route; no Tauri package | **DECIDED — 2026-08-20; PORTAL CONFIGURED — 2026-08-22.** Protected GitHub signing, Mac QA, screenshots, signed parity, availability, and named approval remain **PENDING**. |
| Screenshots | Five 6.5-inch iPhone and five 13-inch iPad frames for each approved locale, captured from the frozen build-17 source | **PENDING** — run `32678113996` captured the 26-frame five-platform candidate from `917ed41db29178ffe7e184d0b52ce4484d86d97e`; it is explicitly unapproved and must not be relabeled or uploaded. The protected finalizer must record independent visual, privacy, and signed-Release-parity approval from four signed build-17 uploads. |
| Physical QA / launch | Complete TestFlight proof, production health/readiness proof, and App Attest launch promotion; terminal-DLQ monitoring remains an optional operational control | **PENDING** — see `docs/IOS_TESTFLIGHT_PHYSICAL_QA.md` and `docs/CLOUDFLARE_PRODUCTION.md` |
