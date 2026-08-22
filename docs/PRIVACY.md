# QuakeSignal — Privacy Policy

Effective date: 22 August 2026

This policy covers every QuakeSignal client: the **Windows desktop app** and
legacy **Tauri macOS desktop builds** (dormant for Apple release 1.1 build 8),
the **Chrome extension**, the **iPhone and iPad app**, its
embedded **Apple Watch companion**, the **Apple TV** and **Apple Vision Pro**
apps, and the shared iPhone/iPad target when it runs through **Mac Catalyst**.
QuakeSignal is a free, MIT-licensed open source
project; its complete source code is public at
<https://github.com/TastyHeadphones/QuakeSignal>.

QuakeSignal has no advertising SDK, behavioural analytics, crash-reporting SDK,
tracking, or data brokers. It never sells personal data. Cloudflare may process
ordinary network and security logs while serving public legal/support pages and
operating the opt-in notification service; those logs are configured
for limited operational sampling and are not used to build user profiles or for
advertising. QuakeSignal uses the information described below only to provide
the features you choose, secure the opt-in iPhone/iPad notification service,
and keep that service reliable.

---

## At a glance

| Client | App registration or telemetry sent to the QuakeSignal notification service | Direct services contacted | Local state |
|---|---|---|---|
| Windows / legacy Tauri macOS desktop | **None** | Wolfx | Event history and preferences on your computer; the Tauri Mac storefront route is dormant for Apple release 1.1 build 8 |
| Chrome extension | **None** | Wolfx | Preferences and recent events in the browser profile |
| iPhone / iPad | Only if you enable alert registration | Wolfx; Apple Maps and Location Services when used; Cloudflare and Apple APNs/App Attest for opted-in alerts | Preferences, guide details, and current display state on your device; the opted-in registration described below is also held by Cloudflare |
| Embedded Apple Watch / Apple TV | **None** | Wolfx over encrypted WebSocket and HTTPS connections while the app is open | Current report state in memory for the foreground session; selected alert presentation mode in local storage |
| Apple Vision Pro / Mac Catalyst | **None** | Wolfx while the app is open; Apple Maps and Location Services when used | Preferences and guide details in local app storage; current report and location state are not sent to Wolfx or the QuakeSignal relay |

There is no QuakeSignal account on any platform. Only the iPhone/iPad alert
path transmits registration data to infrastructure operated by this project,
and only after alert registration is enabled. The Watch, TV, Vision, Catalyst,
native desktop, and Chrome experiences do not
independently register with that service.

Opening a public QuakeSignal privacy, support, or terms page is an ordinary web
request to Cloudflare, which may process an IP address, browser details, and
other network/security metadata. The app does not attach its preferences,
guide details, current location, device token, or App Attest proof to those
page requests. Following a GitHub download, source, or issue link is likewise
subject to GitHub's own policies.

---

## Desktop app (Windows and legacy Tauri macOS builds)

**What leaves your computer.** Only requests to the public Wolfx earthquake
service:

- `wss://ws-api.wolfx.jp` — live earthquake feeds over encrypted WebSockets
- `https://api.wolfx.jp` — recent earthquake history over HTTPS

The desktop app does **not** contact the QuakeSignal notification backend at
all. There is no account, no device registration and no telemetry. Your chosen
city or location is not sent to QuakeSignal-operated infrastructure or included
in Wolfx earthquake requests — filtering by distance happens entirely on your
own computer.

**What is stored on your computer.** Event history and preferences, in a local
SQLite database and a settings file under the application data directory for
`com.quakesignal.desktop`:

- macOS direct/Homebrew build —
  `~/Library/Application Support/com.quakesignal.desktop/`
- macOS App Store build — inside the app sandbox at
  `~/Library/Containers/com.quakesignal.desktop/Data/Library/Application Support/com.quakesignal.desktop/`
- Windows — `%APPDATA%\com.quakesignal.desktop\`

Diagnostic messages are written only to the running process's standard output;
QuakeSignal does not create a separate persistent diagnostic-log file.

**How to delete it.** Uninstall the app and delete the matching distribution
variant's data directory. For the Mac App Store build, deleting the enclosing
`~/Library/Containers/com.quakesignal.desktop/` sandbox container removes its
remaining local data. See [Uninstalling](../README.md#uninstalling) for the
exact paths and steps.

---

## Chrome extension

**What leaves your browser.** Only encrypted WebSocket connections to
`wss://ws-api.wolfx.jp` for public earthquake data. No earthquake data is
routed through a QuakeSignal server.

**What is stored in your browser.** In Chrome's local extension storage only:
alert preferences (notification, alarm and magnitude settings), recent public
earthquake events, and connection-status information.

**Chrome permissions and why.** *Storage* keeps preferences and recent events
locally. *Notifications* displays the alerts you enabled. *Offscreen* plays the
alarm sound and is not used to inspect websites or browsing activity. *Alarms*
periodically checks that the feed connection is alive. *Host access to
`ws-api.wolfx.jp`* is limited to receiving public earthquake data.

The extension does not read browsing history, website content, cookies,
account information or precise location.

**How to delete it.** Remove the extension, or clear its local storage.

**Limited Use.** Information received through Chrome or Google APIs is used
only to provide QuakeSignal's single user-facing purpose. It is not used for
advertising, profiling or creditworthiness, is not sold to third parties, and
humans do not read it.

---

## iPhone and iPad app

**Earthquake data.** The app fetches history and live updates directly from
Wolfx (`https://api.wolfx.jp`, `wss://ws-api.wolfx.jp`), the same as the other
clients.

**What stays on your device.** Alert preferences, the chosen city, the
preparedness-kit checklist, and any optional family contact name and telephone
number you enter are stored in local app storage. The current GPS fix and recent
earthquake display/revision state remain in app memory. Apple provides the map
and system Location Services under its own policies. QuakeSignal does not send
the checklist or family contact details to Wolfx or to infrastructure operated
by this project. Direct Wolfx earthquake requests do not include your chosen
city or device location, and the exact GPS fix is not sent to the notification
service.

**Alert registration — the only app-data path to our notification service.**
The iPhone and iPad app cannot receive new live earthquake events while closed
unless a server sends them, so enabling alert registration registers your
device with the QuakeSignal notification service at
`https://quakesignal-api.hopeso.workers.dev` (Cloudflare Workers, with a
Cloudflare D1 database). This exact public Workers hostname is the user-approved
production origin and uses Cloudflare-managed public TLS. Debug and Simulator
testing must use a separate isolated Worker with no shared production data or
credentials before physical Debug testing.

If, and only if, you enable QuakeSignal's alert registration, the following is
stored for your device:

| Stored | Purpose |
|---|---|
| APNs device token | Addressing the notification to your device |
| An approximate coordinate on a 0.1° grid, derived from either a selected city's coordinate or the most recent current-device location that the app successfully registered while open | Deciding whether an event is near enough to alert you |
| Optional chosen city name | Showing and matching the selected alert area |
| Alert radius, minimum magnitude, selected JMA feed types | Filtering JMA-issued information against your alert choices; QuakeSignal does not create a new local-intensity or arrival-time forecast |
| Locale, UTC offset, night-notification preference | Localizing text and honouring quiet hours |
| Test-alert preference | Respecting your alert choices |
| Created and updated timestamps plus a fresh opaque registration revision | Housekeeping and ensuring a stale APNs response can act only on the exact registration snapshot that was sent |
| App Attest integrity record: opaque key identifier, public verification key, Apple attestation receipt, assertion counter, integrity timestamps, and any Apple-supplied build/version distribution category | Proving that a registration, removal, or test-push request came from the signed app instance and preventing forged or replayed requests |
| Alert-lifecycle evidence: event reference, SHA-256 APNs-token hash, optional opaque App Attest key identifier, opaque registration revision, accepted or possible-contact evidence kind, and first/last evidence timestamps; pre-contact possible evidence additionally carries a random bounded attempt identifier | Sending a later final or cancellation to a current, still-consenting registration when APNs accepted an earlier active warning or a crash left provider acceptance unknowable, even if revised magnitude/location estimates or an ordinary APNs token rotation would no longer match; neither kind proves display on the device, and the registration revision prevents an older removal fence from suppressing later accepted evidence after a new opt-in |
| Pseudonymous per-device delivery-failure record: event/delivery/source reference, SHA-256 APNs-token hash, APNs status/reason, disposition/status/count/timestamps, and the opaque sent registration revision when applicable | Excluding an invalid token across alert deliveries and resolving it after the documented recovery boundary; it contains no raw APNs token, location, proof, or request body |
| Processed registration-revision fence: opaque sent revision, optional SHA-256 APNs-token hash, optional opaque App Attest key identifier, random decision identifier, decision kind, lifecycle-replay blocking flag, and processing timestamp | Preventing a duplicate stale APNs response from acting on a re-registered token and preserving or ending the authenticated continuity lineage according to an ordinary rotation versus explicit removal/retention decision; it contains no raw APNs token, location, proof, or request body |
| Temporary Durable Object APNs-delivery journal: the exact queued event/delivery data and one sent registration snapshot including raw APNs token and SHA-256 hash, opaque current and original-lineage registration revisions, a stable original-recipient index, and optional App Attest key identifier, server-selected environment/topic/platform route, coarse matching area, selected sources and alert preferences, registration timestamps, per-recipient bounded provider-attempt counts and retry times, latest attempt-observation time, and conservative-evidence marker; an observed batch can additionally contain the nullable APNs response identifier, HTTP status/reason, accepted or invalidation timestamp, Retry-After value, and bounded cleanup/disposition flags | Persisting intent before APNs, establishing possible-contact lifecycle evidence before every provider contact, and recovering or reconciling a process stop with an at-least-once, collapse-ID-bounded request; known acceptance and definitive rejection are reconciled separately and never inferred from an intent |
| Token-free delivery incident record: event/delivery/source reference, notification reason, APNs status/reason when applicable, occurrence count, status, and first/last/resolution timestamps | Keeping a provider-page failure visible until a confirmed later page automatically resolves it, or a terminal-Queue failure visible until an operator explicitly resolves it; it contains no APNs token, location preference, App Attest proof, or raw request/upstream body |
| Production training-test claim: opaque App Attest key identifier and UTC claim/expiry timestamps after an immediate or reviewed delayed production test | Enforcing one clearly labelled production training attempt per App Attest key per UTC day; this contains no APNs token, proof, or request body |
| Production training provider-attempt fence: random attempt identifier, exact opaque registration revision, SHA-256 APNs-token hash, synthetic training event/outbox references, and admission/reconciliation timestamps | Serializing an exact production training registration across provider contact so a concurrent renewal or removal cannot be confused with that response; it contains no raw APNs token, proof, request body, preferences, or location |
| Optional delayed-training scheduler record: opaque App Attest key identifier, fixed due time, and at-most-once attempted state | Scheduling one reviewed background training notification. It contains no APNs token, request body, App Attest proof, preferences, location, or earthquake payload, and is deleted after its one attempt or cancellation; the relay rechecks its absolute deadline inside the serialized provider lane immediately before contact, and an alarm more than 30 seconds late is deleted without delivery. |

While the app is inactive, its last successfully registered bounded alert area
remains in use until the next foreground renewal, removal, or retention cleanup.

The subscription data is stored in the `devices` table and the integrity data
in the `app_attest_keys` and short-lived `app_attest_challenges` tables in
[`backend/cloudflare/migrations/`](../backend/cloudflare/migrations/), which
you can read yourself. A legacy registration whose stored source list is
explicitly empty is deleted rather than silently assigned a feed; its
raw-token deduplication and orphaned App Attest key state are removed too.
An already-existing delivery-failure row contains only a one-way token hash,
so it cannot be safely joined to that migration cleanup and instead remains on
the ordinary/resolved 14-day or active `BadDeviceToken` retention described
below. During rolling deployment, revisionless legacy invalid-token evidence
is conservatively pinned to the newest registration clock until authenticated
new-Worker recovery can resolve the matching hash; this avoids silently
re-contacting a token APNs rejected. The service also keeps bounded operational delivery and
deduplication records. A per-device operational delivery failure contains a
token hash, event/delivery metadata, APNs status, and reason—not a raw request
body. Ordinary and resolved rows become eligible for deletion 14 days after
they were last seen; the active `BadDeviceToken` exception is described below. An
alert-lifecycle recipient record contains only the pseudonymous fields listed
above and becomes eligible for deletion 14 days after its latest accepted or
possible-contact active-warning evidence. This continuity bypasses only revised magnitude and
location matching; removing a JMA feed from the current registration prevents
later lifecycle notifications from that feed. A provider-page incident is
automatically resolved by confirmed later processing of that page; a
terminal-Queue incident remains active until an operator verifies recovery and
explicitly sets its resolution status and timestamp. Either becomes eligible
for deletion 14 days after `resolved_at_utc`. An expired alert alone cannot
silently hide an unresolved APNs, Queue, or persistence problem. Eligible rows are
removed by the next successful routine cleanup, and an operational cleanup
failure can delay deletion.

Before routing every public request—including public pages, health, `OPTIONS`,
disabled endpoints, and normalized unmatched paths—
the Worker derives a route-scoped SHA-256 pseudonym from Cloudflare's
authenticated client-IP header for a per-location, 60-second native rate-limit
counter that admits at most 60 requests for that normalized method/route family. A missing
or malformed header shares one bounded fallback bucket. Only admitted requests
consume the separate 300-per-minute route-wide circuit breaker, so one client
cannot consume more than 60 of that route budget.
QuakeSignal does not write the raw IP or this pseudonym to D1 or application
logs. Cloudflare may separately process ordinary raw request/security metadata
under its own policies and configured log retention, as described above.

APNs and D1 cannot participate in one transaction. Before each small APNs
batch, the global relay therefore stores its exact event/delivery and sent
registration snapshots in a bounded Durable Object journal. It removes that
intent only after possible-contact lifecycle evidence is durable for each
reserved contact and every observed outcome is durable. A known APNs 2xx also
writes exact delivery deduplication and promotes the evidence kind. If the
process stops after provider contact, startup or alarm recovery can contact
APNs again with the same stable collapse ID. This is an at-least-once request and
can repeat provider contact; APNs acceptance still does not prove device
display or user receipt. Each record contains only the fields listed in the
table above and covers one recipient. The relay retains at most 128
combined pre-send and rolling accepted records of at most 64 KiB each. Recovery
allows the initial contact plus at most five later contacts per original recipient, persists the next
eligible retry time, and honors a longer provider `Retry-After`; unrelated
alerts are not blocked while one intent waits. Valid, integrity-matched records
become eligible for safe retirement after 14 days, but a D1 outage or consent
race can delay deletion until evidence reconciliation succeeds. It reconciles
them before outbox acknowledgement, expiry, supersession, or terminal-Queue
finalization and during startup/alarm. Malformed records or records whose
recomputed token hash/storage identity does not match are preserved for
operator repair, can exceed 14 days until repaired, and make readiness degraded
rather than being silently discarded. Replay requires a current registration
that still selects the same JMA feed and still passes its current
magnitude/location/training/quiet-hour eligibility. Ordinary token rotation and
a fresh exact-token key rebind may preserve continuity, but an explicit removal,
empty-source remediation, or stale-registration retention fence blocks the
retired authenticated lineage. The temporary raw APNs token is required for
that current-consent mapping and is never logged or copied into D1 failure or
lifecycle evidence. A persisted delivery deadline still prevents stale
redispatch while retaining possible-contact continuity for a still-consenting
active-warning recipient.

**What is not stored.** No name, no email address, no account, no contacts, no
advertising identifier, exact GPS fix, unrounded selected-city coordinate, or
history of movements. Before either a current-location or selected-city
coordinate leaves the app, it is rounded to a 0.1° grid (roughly 11 km north to
south). The service receives one coarse alert-matching coordinate, not a
location trail. The App Attest private key remains hardware-protected on the
device and is never sent to, or stored by, QuakeSignal.

**Third parties in the notification path.** Cloudflare (Workers and D1) hosts
the service; Apple's APNs delivers the notification and Apple's App Attest
service supplies the platform integrity proof. Notification text is localized
on your device using APNs `loc-key` values, so translated copy is not stored on
the server.

**How to delete it.** In the app, open **Settings → Remove Alert
Registration** and confirm. That deletes the matching server-side device
registration and its now-orphaned App Attest integrity record without changing
the iPhone-level notification permission. If APNs has not supplied a token in
that launch, the app sends an empty (`{}`), App Attest-bound deletion request.
That form can remove only a subscription already owned by the current integrity
key; it cannot claim or remove a legacy/unbound subscription. If the app has a
new integrity key or the server does not yet associate that key with a device,
it must supply the exact current APNs token for a token-bound recovery request
and cannot identify the old registration from the new key alone. Each App
Attest challenge becomes invalid in no more than five minutes. Its expired row
is removed by the next successful routine cleanup; an operational cleanup
failure can delay deletion.
When the last associated registration is removed, that App Attest verifier,
receipt, and assertion-counter record is deleted too. A production training
test creates a separate token-free claim containing only the opaque
App Attest key ID and UTC timestamps; it becomes eligible for deletion after
14 days and is removed by the next successful routine cleanup. An operational
cleanup failure can delay deletion. The claim enforces one production training
attempt per key per UTC day. Immediately before either production training
contact, the relay also writes the separate pseudonymous provider-attempt fence
listed above. Device mutation fails closed while the exact marker is unresolved;
provider settlement resolves it, while a crashed request releases it after 60
seconds without claiming APNs acceptance. A resolved marker becomes eligible
for deletion 14 days after admission, and an operational cleanup failure can
delay deletion. Its optional
fixed-delay check creates a private scheduler record containing only that key
ID, a due time, and an at-most-once attempted state. It is deleted after the
one scheduled attempt or cancellation, and an alarm more than 30 seconds late
is deleted without delivery. If APNs returns its documented `BadDeviceToken`
response, the Worker conditionally removes only the exact opaque registration
revision sent to APNs, together with
its now-orphaned verifier and active per-token evidence. A separate processed
revision fence retains the opaque revision, optional SHA-256 token hash,
optional opaque App Attest key identifier, random decision identifier,
decision kind, replay-blocking flag, and timestamp for 14 days so a duplicate
old response cannot act on a reincarnated registration; it retains no raw APNs
token. A
same-token registration serialized before the APNs cleanup transaction is
preserved but its SHA-256 token hash is quarantined across later alerts and
makes readiness degraded unless the sent revision was already processed. An
authenticated same-token renewal serialized after that transaction resolves
the active state while preserving the processed fence. An immediate APNs 2xx
resolves only matching evidence whose captured provider-response time is no
later than that acceptance; a delayed journal replay can restore
deduplication/lifecycle state but does not clear active failure evidence merely
because its D1 write runs later. If
neither recovery happens, the active
pseudonymous row normally follows a 90-day last-seen window aligned with stale
registration cleanup, and its last-seen timestamp is never earlier than the
preserved registration update time. Revisionless evidence written by a
lingering old Worker is conservatively pinned to the newest registration clock
during rollout because SQLite cannot join its one-way hash back to one raw
token; authenticated same-token renewal resolves the matching row. Processed fences instead follow the
ordinary 14-day evidence period. If D1 cleanup or
evidence storage fails, a bounded Queue attempt may contact APNs again because
there is no separate cleanup-only record. On the next foreground registration
after an automatic removal, the client can replace its locally stored integrity
key once and retry with a fresh Apple attestation if the server no longer has
that key's verifier. When
QuakeSignal is next active, losing a current-location fix replaces it with the
saved city fallback when available; without a fallback, the app attempts to
delete the stale relay row and reports a failed registration if deletion cannot
be confirmed. Registrations
become eligible for deletion after they have not been refreshed for 90 days,
together with those orphaned integrity records; the next successful daily
cleanup first places a blocking, revision-only fence and upgrades older
continuity fences for the same opaque App Attest lineage, then removes them.
An operational cleanup failure can delay deletion.
Ordinary/resolved delivery-failure token hashes and alert-lifecycle recipient
records, plus processed-revision fences, become eligible for deletion 14 days
after their respective last-seen, latest accepted-or-possible evidence, or
processing timestamps.
Active `BadDeviceToken` quarantine/retry hashes
instead follow the 90-day last-seen window above unless resolved first.
Resolved provider-page and terminal-Queue incident metadata becomes eligible
14 days after resolution. Confirmed later page processing can set the former
automatically; the latter remains active until an operator records both the
resolved status and UTC resolution timestamp. Eligible rows are
removed by the next successful routine cleanup, and an operational cleanup
failure can delay deletion. Normalized earthquake event rows and their revision
history become eligible for deletion after 89 days and are removed by the next
successful daily cleanup; an operational cleanup failure can delay deletion.
A public support issue cannot privately identify an
old registration after its App Attest key and APNs token are unavailable.
Deleting the app or switching off iOS notifications or location access alone
cannot reliably communicate a deletion request to the service, so use the
in-app control before deleting the app or resetting its Keychain state.

**If the app's integrity key is reset.** Apple can replace an App Attest key
after reinstall or device restore. A newly attested signed app instance that
possesses the exact APNs token may atomically rebind that one token and retire
the old key record. Assertions and tokenless requests cannot transfer a
different key's subscription. If APNs has not supplied the token after a reset,
the app cannot delete the unreachable old registration. Do not post a token,
key identifier, proof, or location in a public support issue; support can guide
recovery. The old registration and its orphaned integrity record become eligible
for deletion after they have not been refreshed for 90 days and are removed by
the next successful daily cleanup; an operational cleanup failure can delay
deletion.

---

## Foreground-only Apple experiences

**Apple Watch and Apple TV.** These apps request recent public earthquake
reports directly from Wolfx over encrypted WebSocket and HTTPS connections only
while they are open. Current report state is held in memory for that foreground
session. The selected System, Urgent, or Japanese Voice presentation mode is
stored locally and is not uploaded. They do not send a location, alert
preference, device token, App Attest record, account identifier, or usage event
to infrastructure operated by QuakeSignal. They do not independently use APNs
or provide background emergency alerts. If Apple mirrors an iPhone notification
to a paired Watch, that remains part of the iPhone's opted-in registration
rather than a separate Watch registration.

**Apple Vision Pro and Mac Catalyst.** These
full-interface experiences connect directly to Wolfx for public earthquake data
while the app is open. Preferences, the preparedness-kit checklist, and any
optional family contact details stay in local app storage. A current location,
when used for nearby context, is held in app memory and is not sent to
QuakeSignal's notification service or included in Wolfx earthquake requests;
Apple provides the map and system Location Services under its own policies.
These experiences do not independently register for APNs, App Attest, or the
QuakeSignal notification relay and do not provide background emergency alerts.

**Clearing local guide data.** In any full-interface Apple experience, erase
both Family Check-In fields and uncheck each selected preparedness-kit item to
clear those local values. This is separate from removing an iPhone/iPad alert
registration. The Watch and TV experiences do not persist guide details or
their current report state in app storage.

---

## Data QuakeSignal-operated infrastructure does not receive

Except for the opted-in iPhone/iPad registration fields described above and
ordinary network/security metadata processed by Cloudflare, QuakeSignal-operated
infrastructure does not receive names, email addresses, passwords, accounts,
contacts, photos, calendars, messages, files, browsing history, website content,
advertising identifiers, payment information, or exact GPS fixes. An optional
family contact name and telephone number can be stored locally in the full Apple
interface, but those values are not transmitted to QuakeSignal. QuakeSignal has
no behavioural analytics, usage profiling, cross-app tracking, advertising, or
purchases.

## Third-party services

| Service | Used by | What it receives |
|---|---|---|
| [Wolfx](https://wolfx.jp) | All clients; the current Apple release requests only JMA feeds | Ordinary connection metadata such as your IP address, under [its own policies](https://wolfx.jp) |
| [Apple Maps](https://www.apple.com/legal/privacy/data/en/apple-maps/) and [Location Services](https://www.apple.com/legal/privacy/data/en/location-services/) | Full-interface Apple experiences when you use maps or current location | Apple may process associated map, location-service, device, and network data under its own policies; QuakeSignal does not include the exact fix in Wolfx requests or its notification relay |
| Cloudflare (Workers, D1) | Public legal/support pages; opted-in iPhone/iPad alerts | Ordinary web-request and security metadata for public pages; the device registration and App Attest integrity record described above only for opted-in alerts |
| Apple APNs and App Attest | Opted-in iPhone/iPad alerts only | Notification delivery and Apple-managed app-instance attestation material under Apple's policies |
| GitHub | Downloads, source links, and public support issues | Standard web-request and account data under GitHub's policies when you use those services |

QuakeSignal is not affiliated with JMA, Wolfx, or any government
emergency agency.

## Children

QuakeSignal is not directed at children. The notification service does not ask
for a person's name, email address, age, or account. Optional family-contact
details stay in local app storage as described above and are not sent to
QuakeSignal-operated infrastructure.

## Changes

Material changes will be reflected in this document, and its effective date
updated. Because the project is open source, every revision is visible in the
[file's history](https://github.com/TastyHeadphones/QuakeSignal/commits/main/docs/PRIVACY.md).

## Contact

Questions and recovery guidance can be requested on the public
[issue tracker](https://github.com/TastyHeadphones/QuakeSignal/issues). Never
post an APNs token, App Attest key identifier or proof, exact location, or other
private information there. Use the in-app removal control for an immediate
authenticated deletion; an unreachable old registration ages out under its
separate 90-day registration rule described above.
