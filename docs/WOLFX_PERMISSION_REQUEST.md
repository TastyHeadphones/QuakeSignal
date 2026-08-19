# Wolfx permission request for App Store distribution

QuakeSignal must not certify in App Store Connect that UniSphereco LLC holds
all required rights to third-party earthquake content until the intended use is
supported by written evidence. Wolfx's current
[Terms of Service](https://wolfx.jp/en/legal/terms) state that reasonable caching,
ordinary automated access, and public-interest development are not prohibited
merely because they are automated, but make reuse subject to service-specific
documentation and applicable data-source terms. They reserve rights in Wolfx
original content and do not warrant the rights or permission scope granted by
third-party sources. QuakeSignal does not expose a public earthquake-feed
endpoint, but its developer-operated notification relay, persistent normalized
event storage, client-local history, and worldwide App Store distribution need
a clear written rights answer.

Send this request from a UniSphereco LLC-controlled address to Wolfx before
finishing **Content Rights** certification for any Apple platform. Preserve the
complete written reply, message headers, and any stated conditions with the
release records.

## Ready-to-send request

**To:** contact@mtf.edu.kg

**Subject:** Written permission request — QuakeSignal use of Wolfx Open API on Apple platforms

Hello Wolfx Project,

UniSphereco LLC is preparing **QuakeSignal**, a free, independent
earthquake-information app distributed through Apple App Store Connect. We
request written confirmation that the following use of the Wolfx Open API is
permitted.

QuakeSignal may be distributed worldwide on iOS, iPadOS, watchOS, tvOS,
visionOS, Mac Catalyst, Designed for iPad on Mac, and native macOS, including
TestFlight and Apple's review and testing systems.

In the current release, only iOS/iPadOS can use the notification relay described
below. The Apple Watch companion, tvOS, visionOS, Mac Catalyst, Designed for
iPad on Mac, and native macOS experiences are foreground/local-only: they do not
have an independent relay registration or push-delivery path. This request does
not seek relay permission for those foreground/local-only experiences; any
later expansion requires a new written scope confirmation.

The app:

1. Connects to Wolfx's documented public HTTP and WebSocket endpoints to receive
   current and historical earthquake and earthquake early-warning information,
   including feeds originating from JMA, CENC, Sichuan, Fujian, and Chongqing
   sources.
2. Normalizes factual fields such as source, event identifier, time, location,
   coordinates, magnitude, depth, intensity, warning status, and tsunami status.
   It may deduplicate, filter, format, and translate app labels. The
   developer-operated Cloudflare backend persistently stores normalized event
   rows for deduplication and alert delivery; those rows currently have no fixed
   automatic deletion deadline. Delivery and outbox records have separate
   operational retention. Native macOS persists local event and revision history
   in its app data, while the other Apple clients keep recent display history in
   memory.
3. Displays those normalized facts directly in QuakeSignal and may generate
   derived, best-effort safety notifications. It does not reproduce Wolfx
   documentation, logos, images, or JMA `OriginalText`.
4. Uses a developer-operated Cloudflare service for opted-in iOS/iPadOS
   notifications after that registration path is validated.
   The service has public HTTPS registration, health, support, privacy, and terms
   endpoints. It receives Wolfx updates, performs limited validation,
   deduplication, persistent normalized-event storage, and preference matching,
   then sends derived alerts through Apple Push Notification service (APNs). It
   has no public earthquake-feed or normalized-event endpoint, is not a public
   secondary API, and does not provide the Wolfx feed to third parties.
5. Does not charge users for Wolfx data, sell the data, or operate a data-resale
   service. QuakeSignal identifies Wolfx and the underlying public agencies,
   states that it is independent and unofficial, and directs users to official
   emergency guidance.

Please confirm whether Wolfx grants UniSphereco LLC non-exclusive, worldwide,
royalty-free permission for this use, including the limited rights needed to
receive, process, normalize, store, cache, display, and redistribute factual data
within QuakeSignal and its derived notifications. Please also confirm that Apple
and its review, hosting, and delivery providers may reproduce and process the
app and included content solely as necessary to test, review, host, and
distribute it through TestFlight and the App Store.

Because Wolfx republishes information originating from other organizations,
please state whether Wolfx has authority to permit this use of those source
feeds. If separate authorization, attribution, or source-specific terms are
required from JMA, CENC, or any provincial source, please identify them.

Please also specify:

- Required attribution, notices, or links
- Prohibited uses, rate limits, caching limits, or regional restrictions
- Whether the permission applies for as long as QuakeSignal remains distributed
- Any revocation or termination procedure, notice period, and required treatment
  of existing installations or cached factual records
- Whether prior approval is required for future QuakeSignal updates that remain
  within this scope

For the requested scope to be sufficient, please expressly confirm both Wolfx's
permission and Wolfx's authority to permit use of the underlying feeds. If
Wolfx cannot authorize one or more underlying feeds, please identify each
separate permission that UniSphereco LLC must obtain. Please include every
applicable condition, attribution requirement, restriction, duration, and
termination term. Silence on an underlying source or condition will not be
treated as permission for it.

Thank you,

GENG YANG
UniSphereco LLC

Send this request from, and retain the complete reply at, a
UniSphereco LLC-controlled business address. Do not commit the sender's private
email address or telephone number to the public repository.

## Release gate

- Answer **Yes** in App Store Connect to the question that the app contains,
  shows, or accesses third-party content.
- Do **not** complete the certification that UniSphereco LLC has all necessary
  rights in every selected App Store country or region until an affirmative
  written Wolfx reply has been received and reviewed for the exact platforms,
  storage, relay, territories, attribution, restrictions, duration, and
  termination described above, and either Wolfx has confirmed its authority to
  permit every underlying feed or every separately required source permission
  has also been obtained and reviewed.
- Treat the reply as a legal/business release record; this document is a
  request template, not legal advice.
