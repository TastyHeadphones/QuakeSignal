# QuakeSignal — Privacy Policy

Effective date: 12 August 2026

This policy covers every QuakeSignal client: the **Windows and macOS desktop
app**, the **iOS app**, and the **Chrome extension**. QuakeSignal is a free,
MIT-licensed open source project; its complete source code is public at
<https://github.com/TastyHeadphones/QuakeSignal>.

QuakeSignal has no advertising SDK, behavioural analytics, crash-reporting SDK,
tracking, or data brokers. It never sells personal data. Cloudflare may process
ordinary network and security logs while operating the opt-in notification
service; those logs are configured for limited operational sampling and are not
used to build user profiles or for advertising. Nothing described below is used
for any purpose other than delivering earthquake information you asked for.

---

## At a glance

| | Desktop (Windows / macOS) | Chrome extension | iOS |
|---|---|---|---|
| User account | None | None | None |
| Data sent to a QuakeSignal server | **None** | **None** | Only if you enable notifications |
| Third-party services contacted | Wolfx | Wolfx | Wolfx, Cloudflare, and Apple APNs/App Attest for notifications |
| Where your data lives | Your computer | Your browser profile | Your device, plus notification settings and an integrity record on Cloudflare |

The desktop app and the Chrome extension are entirely local-first. Only the
iOS app transmits anything to infrastructure operated by this project, and only
when you turn on push notifications.

---

## Desktop app (Windows and macOS)

**What leaves your computer.** Only requests to the public Wolfx earthquake
service:

- `wss://ws-api.wolfx.jp` — live earthquake feeds over encrypted WebSockets
- `https://api.wolfx.jp` — recent earthquake history over HTTPS

The desktop app does **not** contact the QuakeSignal notification backend at
all. There is no account, no device registration and no telemetry. Your chosen
city or location is never transmitted anywhere — filtering by distance happens
entirely on your own computer.

**What is stored on your computer.** Event history and preferences, in a local
SQLite database and a settings file under the application data directory for
`com.quakesignal.desktop`:

- macOS — `~/Library/Application Support/com.quakesignal.desktop/`
- Windows — `%APPDATA%\com.quakesignal.desktop\`

**How to delete it.** Uninstall the app and delete that directory. See
[Uninstalling](../README.md#uninstalling) for the exact steps.

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

## iOS app

**Earthquake data.** The app fetches history and live updates directly from
Wolfx (`https://api.wolfx.jp`, `wss://ws-api.wolfx.jp`), the same as the other
clients.

**Push notifications — the only case where data reaches our server.** iOS
cannot receive alerts while the app is closed unless a server sends them, so
enabling notifications registers your device with the QuakeSignal notification
service at `https://quakesignal-api.hopeso.workers.dev` (Cloudflare Workers,
with a Cloudflare D1 database). This exact public Workers hostname is the
user-approved production origin and uses Cloudflare-managed public TLS. Debug
and Simulator testing must use a separate isolated Worker with no shared
production data or credentials before physical Debug testing.

If, and only if, you enable QuakeSignal's alert registration, the following is
stored for your device:

| Stored | Purpose |
|---|---|
| APNs device token | Addressing the notification to your device |
| An approximate coordinate on a 0.1° grid, derived from either the current location or a selected city's coordinate | Deciding whether an event is near enough to alert you |
| Optional chosen city name | Showing and matching the selected alert area |
| Alert radius, minimum magnitude, selected sources | Matching your alert thresholds |
| Locale, UTC offset, night-notification preference | Localizing text and honouring quiet hours |
| Test-alert preference | Respecting your alert choices |
| Created and updated timestamps | Housekeeping |
| App Attest integrity record: opaque key identifier, public verification key, Apple attestation receipt, assertion counter, integrity timestamps, and any Apple-supplied build/version distribution category | Proving that a registration, removal, or test-push request came from the signed app instance and preventing forged or replayed requests |
| Production training-test claim: opaque App Attest key identifier and UTC claim/expiry timestamps after an immediate or reviewed delayed production test | Enforcing one clearly labelled production training attempt per App Attest key per UTC day; this contains no APNs token, proof, or request body |
| Optional delayed-training scheduler record: opaque App Attest key identifier, fixed due time, and at-most-once attempted state | Scheduling one reviewed background training notification. It contains no APNs token, request body, App Attest proof, preferences, location, or earthquake payload, and is deleted after its one attempt or cancellation; an alarm more than 30 seconds late is deleted without delivery. |

The subscription data is stored in the `devices` table and the integrity data
in the `app_attest_keys` and short-lived `app_attest_challenges` tables in
[`backend/cloudflare/migrations/`](../backend/cloudflare/migrations/), which
you can read yourself. The service also keeps bounded operational delivery and
deduplication records. An operational delivery failure contains a token hash,
event/delivery metadata, APNs status, and reason—not a raw request body—and is
purged after 14 days.

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
or use the support deletion path. Each App Attest challenge expires in no more
than five minutes and expired records are removed by routine cleanup.
When the last associated registration is removed, that App Attest verifier,
receipt, and assertion-counter record is deleted too. A production training
test creates a separate token-free claim containing only the opaque
App Attest key ID and UTC timestamps; it is retained for at most 14 days to
enforce one production training attempt per key per UTC day. Its optional
fixed-delay check creates a private scheduler record containing only that key
ID, a due time, and an at-most-once attempted state. It is deleted after the
one scheduled attempt or cancellation, and an alarm more than 30 seconds late
is deleted without delivery. APNs also removes invalidated tokens, and the
daily retention job removes registrations that have not been refreshed for 90
days along with those orphaned integrity records; delivery-failure token hashes
are purged after 14 days. You can also open an issue to request deletion.
Deleting the app or switching off iOS notifications alone cannot reliably
communicate a deletion request to the service, so use the in-app control before
deleting the app or resetting its Keychain state.

**If the app's integrity key is reset.** Apple can replace an App Attest key
after reinstall or device restore. A newly attested signed app instance that
possesses the exact APNs token may atomically rebind that one token and retire
the old key record. Assertions and tokenless requests cannot transfer a
different key's subscription. If APNs has not supplied the token after a reset,
contact support for deletion rather than repeatedly trying to claim the old
registration.

---

## Data we never collect, on any platform

No names, email addresses, passwords or accounts. No contacts, photos,
calendars, messages or files. No browsing history or website content. No
advertising identifiers or cross-app tracking. No behavioural analytics or
usage profiling. No payment information — QuakeSignal is free and has no
purchases.

## Third-party services

| Service | Used by | What it receives |
|---|---|---|
| [Wolfx](https://wolfx.jp) | All clients | Ordinary connection metadata such as your IP address, under [its own policies](https://wolfx.jp) |
| Cloudflare (Workers, D1) | iOS notifications only | The device registration and App Attest integrity record described above |
| Apple APNs and App Attest | iOS notifications only | Notification delivery and Apple-managed app-instance attestation material under Apple's policies |
| GitHub | Downloads | Standard web-server logs when you download a release |

QuakeSignal is not affiliated with JMA, CENC, Wolfx, or any government
emergency agency.

## Children

QuakeSignal is not directed at children and collects no information intended to
identify anyone, of any age.

## Changes

Material changes will be reflected in this document, and its effective date
updated. Because the project is open source, every revision is visible in the
[file's history](https://github.com/TastyHeadphones/QuakeSignal/commits/main/docs/PRIVACY.md).

## Contact

Questions or deletion requests can be raised on the public
[issue tracker](https://github.com/TastyHeadphones/QuakeSignal/issues).
