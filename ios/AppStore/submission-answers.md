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
| Bundle ID | `com.quakesignal.app` | `ios/project.yml` |
| SKU | `quakesignal-ios` | `README.md` |
| Version | `1.1` | `ios/project.yml` |
| Release candidate | Version `1.0 (6)` is already Ready for Distribution. A processed `1.1 (7)` build is historical TestFlight evidence only. The coordinated native candidate is `1.1 (8)` and remains **PENDING** matching Worker migration/policy deployment, protected uploads and processing, platform/physical-device QA, public attachment, and App Review. Builds `1.0 (2)` through `1.0 (5)` remain historical QA or superseded. | App Store Connect record `6800642443`; prior submission `295fd2ba-11c4-4dc9-945b-2bf6a9fc7bbe`; `README.md` build-number rule |
| TestFlight build 2 | Legacy QA-only; never attach it to App Review | `README.md`, `docs/IOS_TESTFLIGHT_PHYSICAL_QA.md` |
| Primary / secondary category | Weather / Utilities | `README.md` |
| Price / availability | Free; **PENDING** release-owner territory decision | release owner |
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

Before submission, the release owner must compare these entries with the
current binary and App Privacy questionnaire wording. Do not choose “Data Not
Collected” merely because the app has no account.

## Review information

| Field | Value / source |
| --- | --- |
| Demo account | Not required |
| Sign-in required | No |
| Review notes | `review-notes.txt` |
| Contact name, email, phone | **PENDING**: release owner must enter an accountable UniSphereco LLC contact |
| Review route | Start the app, choose **Skip** for notification and location onboarding, then inspect Home, List, Map, Guide, and Settings; no account or review credential is required |
| Notes for background/notification behavior | Optional notifications are best-effort. A public Release exposes an ordinary foreground Send Test Alert control only after authorization, opt-in registration, and an APNs token; it has no delayed background-training control |

## Native platform drafts in this record

| Platform | Intended 1.1 (8) behavior | Portal / evidence status |
| --- | --- | --- |
| Apple Watch companion | Foreground-only compact dashboard embedded in the iOS upload; no independent APNs, App Attest, alert audio, or background emergency alerts | **PENDING** signed host + Watch profile, paired-device QA, Watch screenshots, and shared iOS description/review approval |
| tvOS | Foreground-only large-screen dashboard; no APNs, App Attest, alert audio, or background emergency alerts | Portal has an empty `1.0` draft; **PENDING** edit to 1.1 where permitted, build 8, profile, platform QA, metadata, and 1920 × 1080 screenshots |
| visionOS | Full native windowed foreground app; no APNs, App Attest, Time Sensitive, Critical Alerts, or background emergency delivery. Qualifying live warnings may appear in-app and play the selected local sound only while the app is open. | Portal has an empty `1.0` draft; **PENDING** edit to 1.1 where permitted, build 8, profile, platform QA, App Motion answer, metadata, and 3840 × 2160 screenshots |

Use `platforms/` for exact copy, review notes, and pending screenshot manifests.
Use `app-store-connect-portal-audit-2026-08-19.md` for the read-only portal
contradictions and safe action order. Do not delete or repurpose an existing
draft from this worksheet.

## Required human/legal decisions — do not infer these answers

| App Store Connect area | Required decision/evidence | Current status |
| --- | --- | --- |
| Content Rights | Affirmative written Wolfx permission covering the exact Apple platforms, persistent normalized-event/client-local storage, developer-operated relay, territories, attribution, restrictions, duration, and termination, plus either Wolfx authority over every underlying feed or each separately required source permission | **PENDING / SUBMISSION BLOCKER** — `docs/WOLFX_PERMISSION_REQUEST.md` is a ready-to-send request draft only. No affirmative Wolfx reply or separately required source permission is retained in the release record. See `content-rights-evidence.md`; do not complete Apple's rights certification or submit any platform until the complete evidence is obtained and reviewed. |
| Age Rating | Answer Apple's current questionnaire from the final public build/content | **PENDING** release-owner review |
| Export Compliance | Answer Apple's current encryption/export questions for the final signed archive | **PENDING** legal/release-owner confirmation |
| Availability / pricing schedule | Select approved territories and distribution timing | **PENDING** release-owner decision |
| Japanese / Simplified Chinese listing | Exact product-page names, availability, and trademark review | **PENDING**; keep English-only until approved |
| Screenshots | Five 6.5-inch iPhone and five 13-inch iPad frames for each approved locale, recaptured from frozen build-8 source | **PARTIAL** — a source-frozen ten-image English Debug Simulator candidate is recorded with exact hashes and build evidence, but remains unsigned, unapproved, and reviewer-null. Named visual approval and signed public-Release parity are still **PENDING**. The existing 30-file provenance truthfully records build 7 and must not be relabeled or uploaded as build-8 evidence. |
| Physical QA / launch | Complete TestFlight proof, production health/readiness proof, and App Attest launch promotion; terminal-DLQ monitoring remains an optional operational control | **PENDING** — see `docs/IOS_TESTFLIGHT_PHYSICAL_QA.md` and `docs/CLOUDFLARE_PRODUCTION.md` |
