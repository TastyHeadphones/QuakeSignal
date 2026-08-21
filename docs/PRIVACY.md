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
| Created and updated timestamps | Housekeeping |
| App Attest integrity record: opaque key identifier, public verification key, Apple attestation receipt, assertion counter, integrity timestamps, and any Apple-supplied build/version distribution category | Proving that a registration, removal, or test-push request came from the signed app instance and preventing forged or replayed requests |
| Production training-test claim: opaque App Attest key identifier and UTC claim/expiry timestamps after an immediate or reviewed delayed production test | Enforcing one clearly labelled production training attempt per App Attest key per UTC day; this contains no APNs token, proof, or request body |
| Optional delayed-training scheduler record: opaque App Attest key identifier, fixed due time, and at-most-once attempted state | Scheduling one reviewed background training notification. It contains no APNs token, request body, App Attest proof, preferences, location, or earthquake payload, and is deleted after its one attempt or cancellation; an alarm more than 30 seconds late is deleted without delivery. |

While the app is inactive, its last successfully registered bounded alert area
remains in use until the next foreground renewal, removal, or retention cleanup.

The subscription data is stored in the `devices` table and the integrity data
in the `app_attest_keys` and short-lived `app_attest_challenges` tables in
[`backend/cloudflare/migrations/`](../backend/cloudflare/migrations/), which
you can read yourself. The service also keeps bounded operational delivery and
deduplication records. An operational delivery failure contains a token hash,
event/delivery metadata, APNs status, and reason—not a raw request body—and
becomes eligible for deletion after 14 days. It is removed by the next
successful routine cleanup; an operational cleanup failure can delay deletion.

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
attempt per key per UTC day. Its optional
fixed-delay check creates a private scheduler record containing only that key
ID, a due time, and an at-most-once attempted state. It is deleted after the
one scheduled attempt or cancellation, and an alarm more than 30 seconds late
is deleted without delivery. APNs also removes invalidated tokens. When
QuakeSignal is next active, losing a current-location fix replaces it with the
saved city fallback when available; without a fallback, the app attempts to
delete the stale relay row and reports a failed registration if deletion cannot
be confirmed. Registrations
become eligible for deletion after they have not been refreshed for 90 days,
together with those orphaned integrity records; the next successful daily
cleanup removes them, and an operational cleanup failure can delay deletion.
Delivery-failure token hashes become eligible for deletion after 14 days and
are removed by the next successful routine cleanup; an operational cleanup
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
