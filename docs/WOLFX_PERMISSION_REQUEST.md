# Wolfx permission request contingency template

**UNUSED — DO NOT SEND FOR THE CURRENT RELEASE.** On 20 August 2026, the
release owner chose the published-terms route recorded in
[`ios/AppStore/content-rights-evidence.md`](../ios/AppStore/content-rights-evidence.md)
and removed written Wolfx outreach as a release prerequisite. This file is
retained only as a contingency if Apple, Wolfx, or an upstream source later
requests additional written authorization.

QuakeSignal being free and open source is not by itself permission to use a
third-party service. Wolfx's current
[Terms of Service](https://wolfx.jp/en/legal/terms/) state that reasonable caching,
ordinary automated access, and public-interest development are not prohibited
merely because they are automated, but make reuse subject to service-specific
documentation and applicable data-source terms. They reserve rights in Wolfx
original content and do not warrant the rights or permission scope granted by
third-party sources. QuakeSignal does not expose a public earthquake-feed
endpoint, but its developer-operated notification relay, persistent normalized
event storage, client-local history, and worldwide App Store distribution must
remain within those published terms and applicable source terms.

The current Apple build-8 scope is JMA-only: `jma_eew` and `jma_eqlist`.
`cenc_eew`, `cenc_eqlist`, `sc_eew`, `fj_eew`, and `cq_eew` are disabled. JMA's
website terms, Public Data License 1.0, and statutory relay-versus-new-forecast
guidance are mapped in the release evidence. Relay events and revisions become
eligible for deletion after 89 days and are removed by the next successful
daily cleanup; operational failures can delay deletion. This contingency must not be
used to imply that the current release includes or seeks permission for a
disabled source.

Do not send this template merely because it exists. If a stop condition in the
reviewed evidence record is triggered, first update the template to the exact
then-current product, platforms, sources, storage, relay, territories, and
terms; obtain release-owner approval; then send it from a controlled address
and preserve the complete reply privately.

## Contingency request — refresh before sending

**To:** contact@mtf.edu.kg

**Subject:** Written permission request — QuakeSignal use of Wolfx Open API on Apple platforms

Hello Wolfx Project,

UniSphereco LLC is preparing **QuakeSignal**, a free, independent
earthquake-information app distributed through Apple App Store Connect. We
request written confirmation that the following use of the Wolfx Open API is
permitted.

QuakeSignal may be distributed worldwide on iOS, iPadOS, watchOS, tvOS,
visionOS, and Mac Catalyst, including TestFlight and Apple's review and testing
systems.

In the current release, only iOS/iPadOS can use the notification relay described
below. The Apple Watch companion, tvOS, visionOS, and Mac Catalyst experiences
are foreground/local-only: they do not have an independent relay registration
or push-delivery path. This request does not seek relay permission for those
foreground/local-only experiences; any later expansion requires a new written
scope confirmation.

The app:

1. Connects to Wolfx's documented public HTTP and WebSocket endpoints to receive
   current and recent JMA earthquake and earthquake early-warning information
   from only the `jma_eew` and `jma_eqlist` feeds.
2. Normalizes factual fields such as source, event identifier, time, location,
   coordinates, magnitude, depth, intensity, warning status, and tsunami status.
   It may deduplicate, filter, format, and translate app labels. The
   developer-operated Cloudflare backend stores normalized event rows and their
   revision history for deduplication and alert delivery. They become eligible
   for deletion after 89 days and are removed by the next successful daily
   cleanup; operational failures can delay deletion. Delivery and outbox
   records have separate, shorter operational retention. Mac Catalyst keeps preferences and guide details in
   its app sandbox, while recent report state remains local to the client.
3. Displays those normalized facts directly in QuakeSignal and may send
   filtered, best-effort notifications of JMA-issued information. Magnitude and
   epicentral-distance preferences route delivery only; QuakeSignal does not
   calculate predicted local intensity or ground-motion arrival and does not
   issue a QuakeSignal-authored official warning. It does not reproduce Wolfx
   documentation, logos, images, or JMA `OriginalText`.
4. Uses a developer-operated Cloudflare service for opted-in iOS/iPadOS
   notifications after that registration path is validated.
   The service has public HTTPS registration, health, support, privacy, and terms
   endpoints. It receives Wolfx updates, performs limited validation,
   deduplication, persistent normalized-event storage, and preference matching,
   then sends filtered JMA-information notifications through Apple Push
   Notification service (APNs). It has no public earthquake-feed or normalized
   event endpoint, is not a public secondary API, and does not provide the Wolfx
   feed to third parties.
5. Does not charge users for Wolfx data, sell the data, or operate a data-resale
   service. QuakeSignal identifies Wolfx and JMA, states that JMA information
   is normalized/edited by an independent and unofficial app, and directs users
   to official emergency guidance.

Please confirm whether Wolfx grants UniSphereco LLC non-exclusive, worldwide,
royalty-free permission for this use, including the limited rights needed to
receive, process, normalize, store, cache, display, and redistribute factual data
within QuakeSignal and its filtered JMA-information notifications. Please also
confirm that Apple and its review, hosting, and delivery providers may reproduce
and process the app and included content solely as necessary to test, review,
host, and distribute it through TestFlight and the App Store.

Because Wolfx relays information originating from JMA, please identify any
Wolfx-specific condition beyond the published Wolfx terms, JMA website terms,
Public Data License 1.0, and statutory guidance already mapped by QuakeSignal.
This request does not seek permission for a disabled CENC or provincial feed.

Please also specify:

- Required attribution, notices, or links
- Prohibited uses, rate limits, caching limits, or regional restrictions
- Whether the permission applies for as long as QuakeSignal remains distributed
- Any revocation or termination procedure, notice period, and required treatment
  of existing installations or cached factual records
- Whether prior approval is required for future QuakeSignal updates that remain
  within this scope

Please include every applicable condition, attribution requirement,
restriction, duration, and termination term. Silence or this unsent template
will not be treated as permission or as an expansion beyond the JMA-only scope.

Thank you,

GENG YANG
UniSphereco LLC

If this contingency is activated and approved, send the updated request from,
and retain the complete reply at, a UniSphereco LLC-controlled business
address. Do not commit the sender's private email address or telephone number
to the public repository.

## Contingency use conditions

- Answer **Yes** in App Store Connect to the question that the app contains,
  shows, or accesses third-party content.
- For the current release, follow the published-terms/source mapping and
  action-time recheck in `../ios/AppStore/content-rights-evidence.md`; this
  contingency request is not a prerequisite.
- If Apple or a source requires additional written authorization, stop the
  affected source or territories until the updated request and response cover
  the exact scope. Do not claim that this template, silence, or open-source
  licensing is permission.
- Treat any reply as a legal/business release record. This document remains a
  request template, not legal advice.
