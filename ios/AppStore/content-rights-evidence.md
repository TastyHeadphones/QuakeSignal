# Third-party content-rights evidence

This record supports an accurate Apple Content Rights answer. It documents the
release owner's published-terms basis and the product behavior reviewed against
it. It is not legal advice, does not expand a third party's terms, and does not
by itself authorize an App Store submission.

## Current status

**JMA-ONLY PUBLISHED-TERMS BASIS RECORDED — FINAL ARTIFACT RECHECK STILL
REQUIRED.** On 20 August 2026, the release owner chose not to contact Wolfx and
narrowed the Apple build-8 release contract to exactly these two Wolfx feed
identifiers:

- `jma_eew`
- `jma_eqlist`

Build 8 disables `cenc_eew`, `cenc_eqlist`, `sc_eew`, `fj_eew`, and `cq_eew`
in the Apple clients and notification relay. Those sources are not optional
defaults or hidden settings for this release. The decision is retained in
[`release-owner-decisions-2026-08-20.md`](./release-owner-decisions-2026-08-20.md).

QuakeSignal being free and MIT-licensed describes the product but is **not**
permission to use a third-party service or its data. No private Wolfx license
or upstream-agency authorization is claimed. The intended JMA-only build must
still be checked against the final signed artifacts, deployed relay, current
terms, attribution, and selected territories immediately before any Apple
Content Rights certification or submission.

## Published terms and statutory boundary

1. [Wolfx Project Terms of Service](https://wolfx.jp/en/legal/terms/), last
   updated 28 July 2026, define the public APIs and WebSocket services as
   Services, permit no-charge use subject to the terms and service-specific
   documentation, and do not prohibit reasonable caching, ordinary automated
   access, or public-interest development merely because it is automated.
   They prohibit unauthorized re-provision/resale and use contrary to
   applicable source terms, retain upstream rights with the respective rights
   holders, and do not warrant a third party's permission scope.
2. [Wolfx Open API Usage](https://wolfx.jp/en/docs/open-api/), document version
   `v20260729`, documents the two JMA HTTP and WebSocket endpoints used by build
   8 and requires the service to remain identified as unofficial and not a
   substitute for official emergency information.
3. [JMA's English website terms](https://www.jma.go.jp/jma/en/copyright.html)
   and [Japanese website terms](https://www.jma.go.jp/jma/kishou/info/coment.html)
   apply the [Public Data License 1.0](https://www.digital.go.jp/en/resources/open_data/public_data_license_v1.0)
   unless a specific rights notice applies. PDL 1.0 permits use, copying,
   public transmission, translation, modification, and commercial use of
   covered content. JMA requires source citation, an editing statement for
   edited content, and presentation that cannot be mistaken for unedited
   Government of Japan material. Specific-law and third-party-rights caveats
   remain in force.
4. JMA's current
   [earthquake-motion forecasting FAQ](https://www.jma.go.jp/jma/kishou/minkan/q_a_s.html)
   distinguishes explaining or transmitting JMA-issued forecasts and warnings
   from creating a new earthquake-motion prediction. The former is not itself
   licensed forecasting; repeatedly providing a new prediction for a specific
   place and future shaking is. JMA's
   [forecasting-service application guide](https://www.jma.go.jp/jma/kishou/minkan/tebiki/jishin_tebiki.pdf)
   states that the latter rule applies regardless of whether the activity is
   commercial or noncommercial.

Apple requires apps that access third-party content to have necessary rights
or another lawful basis in each territory. See Apple's
[App information reference](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information)
and [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/).
If Apple asks, provide the current published terms and this exact product
mapping; do not claim a private Wolfx license, JMA endorsement, or blanket
permission extending to a disabled source.

## Reviewed JMA-only product use

Build 8 reads only `jma_eew` and `jma_eqlist` from Wolfx's documented public
HTTP and WebSocket endpoints. It normalizes factual fields such as source,
event identifier, issue/origin time, hypocenter, coordinates, magnitude,
depth, source-issued intensity, source-issued warning status, and tsunami
status. It does not reproduce Wolfx documentation, logos, images, branding, or
JMA `OriginalText`.

QuakeSignal may format, localize, deduplicate, and route those JMA-issued facts.
Magnitude and epicentral-distance preferences select recipients; they do not
calculate predicted local intensity, ground-motion arrival time, or another
QuakeSignal forecast. Customer copy and notification presentation must identify
JMA as the source, disclose that QuakeSignal normalized/edited the information,
remain independent and non-official, and direct users to official emergency
guidance. A push is a filtered, best-effort relay of JMA-issued information,
not a QuakeSignal-authored government warning.

Only iOS/iPadOS may use the developer-operated Cloudflare/APNs relay. Its
normalized event rows and revision history become eligible for deletion after
89 days; the next successful daily ordered cleanup removes revision rows before
their canonical event rows, and an operational cleanup failure can delay
deletion. It exposes no public
earthquake-feed or normalized-event API and neither sells nor licenses the
feed. Apple Watch, tvOS, visionOS, and Mac Catalyst are foreground/local-only
and do not independently register for APNs or App Attest. The separate Tauri
client and Designed-for-iPad-on-Mac route are outside this release.

The clients and relay use bounded connections and retries and do not bypass
access controls or documented limits. The release is free, contains no
advertising, and does not monetize access to Wolfx data. These facts narrow the
reviewed behavior; they are not substitutes for the published terms.

## Why the non-JMA feeds are excluded

The following official-source review records why build 8 narrows its source
inventory. It does not assert that every conceivable use of the source is
prohibited; it records that the current public writing does not establish the
exact QuakeSignal/Wolfx relay use sufficiently for this release.

| Disabled feed | Official published source reviewed | Build-8 conclusion |
| --- | --- | --- |
| `cenc_eew`, `cenc_eqlist` | CENC/National Earthquake Science Data Center [sharing rules](https://data.earthquake.cn/sjgxgz/info/2016/2344.html), current [service flow](https://data.earthquake.cn/fwlc/info/2024/334672344.html), [rapid-catalog product](https://data.earthquake.cn/datashare/report.shtml?PAGEID=datasourcelist&dt=40280d0453e414e40153e44861dd0001), and [2026 service notice](https://data.earthquake.cn/tzgg/info/2026/334674434.html) | The rapid catalog has a plausible direct-download/attribution basis, but the published material grants only a limited, non-exclusive use and does not specifically map Wolfx redistribution, app normalization, relay storage, or notification fanout. No comparable public grant was located for CENC EEW. Both feeds are disabled. |
| `sc_eew` | [Sichuan Order 363](https://www.sc.gov.cn/10462/zfwjts/2024/2/5/1ae6d9f0fc5d4100b14fcc01ecb07028.shtml), [official PDF](https://www.sc.gov.cn/10462/c108923/2024/2/2/9941dab4914b42e3964b56e3ab472c64/files/cee9b1afdc8641ae8796054ddc0405ae.pdf), and the earthquake administration's [2025 technical-service guide](https://www.scdzj.gov.cn/zwgk/tzgg/202503/P020250325504637186338.pdf) | The order reserves unified publication to the provincial authority and permits value-added services only lawfully; the service guide maps third-party forwarding platforms to technical assessment and local authorization. No QuakeSignal/Wolfx authorization is retained. The feed is disabled. |
| `fj_eew` | [Fujian Government Order 162](https://zfgb.fujian.gov.cn/533) | The order bars public EEW publication in any form without authorization, reserves public broadcast to designated media, and provides a request route for special service. It contains no free/noncommercial exception applicable to QuakeSignal. The feed is disabled. |
| `cq_eew` | Chongqing Earthquake Administration's current [authorized-platform announcement](https://www.cqdzj.gov.cn/content.php?id=137687) and [technical standard](https://www.cqdzj.gov.cn/upimg/2025072917575831179200.pdf) | The announcement names two authorized companies, requires verbatim forwarding and the prescribed source label, and forbids authorizing another third party. QuakeSignal and Wolfx are not named. The feed is disabled. |

## Evidence register

| Evidence | Status | Reviewed release record |
| --- | --- | --- |
| Release-owner decision | **RECORDED — 2026-08-20** | `release-owner-decisions-2026-08-20.md`; use the published-terms route, send no Wolfx email, and enable only the two JMA feeds |
| Wolfx Terms of Service | **REVIEWED — 2026-08-20** | Current English terms, last updated `2026-07-28`; no-charge use, reasonable automation/caching/public-interest development, prohibitions, upstream-rights reservation, and change/suspension terms |
| Wolfx Open API documentation | **REVIEWED — 2026-08-20** | Current English usage page, document version `v20260729`; exact JMA endpoints and unofficial/reference-only warning |
| JMA content terms | **REVIEWED — 2026-08-20** | PDL 1.0 use/public-transmission/modification basis; attribution, editing, non-endorsement, third-party-rights, and specific-law conditions |
| JMA statutory product boundary | **REVIEWED — 2026-08-20** | Relay/explanation of JMA-issued information only; no QuakeSignal calculation of predicted local intensity or arrival time and no QuakeSignal-authored official warning |
| Build-8 source scope | **RECORDED / IMPLEMENTED IN SOURCE — FINAL ARTIFACT CHECK PENDING** | `jma_eew` and `jma_eqlist` only; all five non-JMA identifiers disabled in Apple clients and relay policy |
| Product-scope mapping | **REVIEWED — 2026-08-20** | Factual fields only; normalized/edited JMA attribution; independent/non-official warnings; no logos/docs/`OriginalText`; no public secondary API, resale, advertising, or paywall |
| Relay event-row retention | **IMPLEMENTED — 2026-08-20** | Normalized events and revisions become eligible for deletion after 89 days; the next successful daily cleanup removes revisions before events, operational failures may delay deletion, and the D1 migration indexes both cutoff columns |
| Apple Content Rights worksheet basis | **MAPPED FOR THE INTENDED JMA-ONLY BUILD 8** | Final signed-artifact/source-inventory proof, current-term/territory recheck, accountable review, and portal reconciliation remain pending; the previously observed portal **Yes** is not evidence by itself |

[`docs/WOLFX_PERMISSION_REQUEST.md`](../../docs/WOLFX_PERMISSION_REQUEST.md)
remains an unused JMA-only contingency template. Do not send it for this
release merely because it exists, and do not treat the template as evidence.

## Ongoing conditions and stop triggers

- Immediately before submission, verify that the signed Apple artifacts and
  deployed relay expose and connect only `jma_eew` and `jma_eqlist`, and recheck
  the Wolfx terms, Open API document version, JMA terms/notices, attribution,
  product behavior, App Store territories, and 89-day-cutoff cleanup evidence.
- Preserve the JMA source citation and normalized/edited statement in app and
  store copy. Do not claim endorsement or describe a QuakeSignal presentation
  as an official government warning.
- Do not add a local-intensity, ground-motion-arrival, or other earthquake-motion
  prediction without a separate regulatory review. The current radius and
  magnitude controls must remain delivery filters, not forecast calculations.
- If terms change, Wolfx or JMA objects, Apple requests evidence not satisfied
  by the published terms, a disabled source reappears, or the product begins
  reselling/re-providing the feed, pause the affected source or territories and
  narrow the release or obtain additional authorization.
- No private outreach is planned. If it becomes necessary later, obtain a new
  release-owner decision, use the refreshed contingency template, and retain
  any correspondence privately rather than committing it to this repository.

## Bundled alert-audio evidence

The third-party data basis above is separate from QuakeSignal's two bundled
notification sounds. The urgent two-note waveform is original UniSphereco LLC
work. The Japanese safety message is original QuakeSignal text synthesized
with the HTS Voice “Mei”; that voice model is distributed under Creative
Commons Attribution 3.0. Exact generator versions, license notices, durations,
and reviewed output hashes are retained in
`../QuakeSignal/Resources/Audio/ATTRIBUTION.md` and are displayed from the
app's alert-sound disclosure. Neither sound copies or claims to be J-Alert,
JMA, a carrier, broadcaster, or government recording.

Before submission, verify that the attribution file and the two reviewed CAF
hashes are present in every applicable final signed artifact and that App Store
metadata does not imply official endorsement.
