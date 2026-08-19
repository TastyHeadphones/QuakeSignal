# Third-party content-rights evidence

This record exists to support an accurate Apple Content Rights answer. It does
not grant rights, replace legal review, or authorize an App Store submission.

## Current status

**PENDING / SUBMISSION BLOCKER.** No affirmative written Wolfx permission is
retained in the release record for QuakeSignal's intended Apple-platform
distribution, storage, developer-operated notification relay, territories,
duration, or underlying-source rights.

[`docs/WOLFX_PERMISSION_REQUEST.md`](../../docs/WOLFX_PERMISSION_REQUEST.md) is
a ready-to-send request draft. A draft, a sent request without an affirmative
reply, Wolfx's published terms or API documentation, and an App Store Connect
portal selection are not evidence that UniSphereco LLC has the necessary
rights.

A historical portal observation on 15 August 2026 recorded Content Rights as
selected affirmatively. That selection must not be copied forward or treated
as authorization. If the portal still contains that answer, reconcile it only
after the written reply below has been received and reviewed; do not make a
false certification merely to preserve the prior value.

## Material and use covered by the request

QuakeSignal reads factual earthquake fields from Wolfx's public HTTP and
WebSocket endpoints and normalizes them into source, event identifier, times,
hypocenter, coordinates, magnitude, depth, intensity, warning status, and
tsunami status. The developer-operated Cloudflare backend persistently stores
normalized event rows with no fixed automatic deletion deadline and uses those
records for deduplication and alert delivery. Native macOS persists local event
and revision history in its app data; other Apple clients keep recent display
history in memory. It does not intentionally reproduce Wolfx documentation,
logos, images, or JMA `OriginalText`.

In this release, only iOS/iPadOS may use the developer-operated Cloudflare/APNs
relay for opted-in, derived best-effort notifications. Its
registration, health, support, privacy, and terms endpoints are public HTTPS,
but it has no public earthquake-feed or normalized-event endpoint. Apple Watch,
tvOS, visionOS, Mac Catalyst, Designed for iPad on Mac, and native macOS are
foreground/local-only and do not register independently with that relay or
receive its APNs alerts.

The requested scope covers iOS, iPadOS, watchOS, tvOS, visionOS, Mac Catalyst,
Designed for iPad on Mac, and native macOS, including TestFlight, App Review,
and worldwide App Store distribution. The request also asks Wolfx to identify
any required source-specific authorization, attribution, restrictions, rate or
caching limits, regional limits, duration, and termination conditions.

## Evidence register

| Evidence | Status | Required release record |
| --- | --- | --- |
| Request text | **READY TO SEND** | `docs/WOLFX_PERMISSION_REQUEST.md` |
| Sent request | **PENDING** | Full sent message, sender, recipient, timestamp, and message headers from a UniSphereco LLC-controlled mailbox |
| Wolfx reply | **PENDING** | Complete affirmative written reply and headers from an authenticated Wolfx contact covering the exact platforms, storage, relay, territories, conditions, duration, and termination |
| Underlying-source rights | **PENDING** | Wolfx expressly confirms authority to permit every underlying feed, or complete affirmative separate permissions are retained for every source Wolfx cannot authorize |
| Scope review | **PENDING** | Named reviewer and date; platforms, storage, relay, territories, duration, attribution, restrictions, termination, and underlying-source authority or separate permissions mapped to the intended release |
| Product/compliance changes | **PENDING** | Any changes required by the reply applied and verified before certification |
| Apple Content Rights certification | **BLOCKED** | Complete only after every preceding row is satisfied |

Do not mark a row complete based on silence, an automated acknowledgement, a
request being sent, or an internal release-owner opinion. If Wolfx declines,
does not answer, or grants narrower or conditional permission, keep submission
blocked until the app, territories, attribution, relay, and release plan are
changed as necessary and the resulting scope is supported by written evidence.
If Wolfx cannot authorize an underlying feed, keep submission blocked until an
affirmative permission from that source's rights holder is obtained and
reviewed; identifying a separate permission is not the same as obtaining it.

Do not commit private correspondence to the public repository. Store the
complete reply and headers in the organization's approved private release
record, then record only a non-sensitive evidence reference, scope summary,
reviewer, and review date here.

## Bundled alert-audio evidence

The Wolfx gate above is separate from the rights record for QuakeSignal's two
bundled notification sounds. The urgent two-note waveform is original
UniSphereco LLC work. The Japanese safety message is original QuakeSignal text
synthesized with the HTS Voice “Mei”; that voice model is distributed under
Creative Commons Attribution 3.0. Exact generator versions, license notices,
durations, and reviewed output hashes are retained in
`../QuakeSignal/Resources/Audio/ATTRIBUTION.md` and are displayed from the app's
alert-sound disclosure. Neither sound copies or claims to be J-Alert, JMA, a
carrier, broadcaster, or government recording.

This audio provenance does not cure or replace the pending Wolfx permission.
Before submission, the release owner must verify that the attribution file and
the two reviewed CAF hashes are present in the final signed artifact and that
the App Store metadata does not imply official endorsement.

## Reviewed evidence

| Field | Verified value |
| --- | --- |
| Private evidence reference | **PENDING** |
| Wolfx representative / reply date | **PENDING** |
| Reviewed by / review date | **PENDING** |
| Approved platforms and distribution channels | **PENDING** |
| Approved territories | **PENDING** |
| Storage and client-local history | **PENDING** |
| Developer-operated relay / derived notifications | **PENDING** |
| Required attribution | **PENDING** |
| Restrictions, duration, and termination | **PENDING** |
| Underlying-source authorization or additional permissions | **PENDING** |
