# macOS App Store Connect submission record

This is the reviewed-source worksheet for **QuakeSignal for macOS** (Apple ID
`6800642853`). It does not submit anything automatically and deliberately
leaves legal and App Store Connect decisions pending until the release owner
has evidence. Use it together with
[`submission-checklist.md`](./submission-checklist.md): a **PENDING** row is a
non-submission condition, not a value to infer or certify.

## Record and version

| Field | Intended value / status | Evidence |
| --- | --- | --- |
| Name | `QuakeSignal for macOS` — approved English (U.S.) name | `README.md` |
| Bundle ID | `com.quakesignal.desktop` | `desktop/src-tauri/tauri.conf.json` |
| SKU | `quakesignal-macos` | `README.md` |
| Version | `1.1.0` | `desktop/src-tauri/tauri.conf.json` |
| Build | **PENDING**: current signed sandboxed 1.1.0 App Store archive accepted by App Store Connect. The portal's existing 1.0.0 build is Ready to Submit but is superseded and must not be selected. | protected Mac App Store workflow; read-only portal audit |
| Category | Weather | `README.md` |
| Price / availability | Free; **PENDING** release-owner territory decision | release owner |
| Copyright | `2026 UniSphereco LLC` | `README.md` |

## Customer-facing URLs and review access

| Field | Exact value / status |
| --- | --- |
| Privacy Policy URL | `https://quakesignal-api.hopeso.workers.dev/privacy` |
| Support URL | `https://quakesignal-api.hopeso.workers.dev/support` |
| Terms URL, if requested | `https://quakesignal-api.hopeso.workers.dev/terms` |
| Demo account / sign-in | Not required |
| Review notes | `review-notes.txt` |
| Review contact | **PENDING**: release owner must enter an accountable UniSphereco LLC contact |

The 2026-08-19 read-only portal audit found this canonical record still in an
editable 1.0.0 draft with four older screenshot assets, a 1.0.0 build Ready to
Submit, and zero installs. Preserve the draft and evidence. Update that draft
to 1.1.0 only if App Store Connect permits; otherwise stop and contact support.
Do not submit the old build, delete a record, or create another Mac record.

The approved Worker URL uses public Cloudflare Web-PKI TLS. Do not add a
private CA, origin certificate, or client-mTLS configuration.

## App Privacy questionnaire source inventory

This source inventory is not a completed App Privacy questionnaire. Apple’s
current wording and any third-party-service disclosure must be checked by the
release owner against the final signed sandboxed package before a portal answer
is selected.

| Observed source behavior | Source evidence | Required App Store Connect action |
| --- | --- | --- |
| Event history, preferences, and any manually entered location/radius are stored locally in the app sandbox | `desktop/src-tauri/src/settings.rs`, `desktop/src-tauri/src/db.rs` | Confirm whether any final-binary behavior changes this local-only design |
| The desktop client connects directly to Wolfx HTTPS/WebSocket feeds; it does not send these settings to a QuakeSignal backend | `desktop/src-tauri/src/wolfx_client.rs`, `docs/PRIVACY.md` | Confirm the applicable current Apple answer for Wolfx’s independent connection metadata; do not guess from this worksheet |
| No account, advertising, analytics SDK, purchase, or third-party login is represented by the checked-in desktop source | `desktop/src/`, `desktop/src-tauri/` | Reconfirm the final signed package and every included dependency before answering “Data Not Collected” |

## Review behavior

| Field | Value / source |
| --- | --- |
| Permission-free route | If macOS asks for notification permission at launch, decline it; Home, Events, and Settings remain reviewable without an account or credentials |
| Manual location | Settings accepts a manually selected city or optional coordinates; the Mac App Store build does not request macOS Location Services access |
| Store-only feature scope | The sandboxed build omits the direct-distribution Test Alarm and Launch at Login controls |
| Alarm delivery | Local foreground evaluation while the Mac app is running; no App Attest or APNs registration and no background emergency-alert service |

## Required human/legal decisions — do not infer these answers

| App Store Connect area | Required decision/evidence | Current status |
| --- | --- | --- |
| Content Rights | Affirmative written Wolfx permission covering native macOS, persistent client-local event/revision history, intended App Store territories, attribution, restrictions, duration, and termination, plus either Wolfx authority over every underlying feed or each separately required source permission | **PENDING / SUBMISSION BLOCKER** — `docs/WOLFX_PERMISSION_REQUEST.md` is a request draft only. No affirmative Wolfx reply or separately required source permission is retained. Use `ios/AppStore/content-rights-evidence.md`; do not certify or submit before the complete evidence is obtained and reviewed. |
| Age Rating | Complete Apple's current questionnaire from the final build/content | **PENDING** release-owner review |
| Export Compliance | Answer Apple's current encryption/export questions for final signed package | **PENDING** legal/release-owner confirmation |
| Availability / pricing | Select approved territories and timing | **PENDING** release-owner decision |
| Localized listing names | Exact names, availability, and trademark review | **PENDING**; retain English-only until approved |
| Screenshots | Compare/recapture four frames from the signed sandboxed Mac App Store build | **PENDING** signed-build visual approval |
| Foreground Wolfx proof | Confirm live foreground updates on a signed sandboxed build | **PENDING** physical/signed-build evidence |
| App Privacy questionnaire | Reconcile current Apple wording, final package behavior, and any Wolfx third-party-service disclosure | **PENDING** release-owner/legal review |
