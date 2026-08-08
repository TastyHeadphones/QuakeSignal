# QuakeSignal — Privacy Policy

Effective date: 8 August 2026

This policy covers every QuakeSignal client: the **Windows and macOS desktop
app**, the **iOS app**, and the **Chrome extension**. QuakeSignal is a free,
MIT-licensed open source project; its complete source code is public at
<https://github.com/TastyHeadphones/QuakeSignal>.

QuakeSignal has no advertising, no analytics, no crash reporting, no tracking
and no data brokers. It never sells or shares personal data. Nothing described
below is used for any purpose other than delivering earthquake information you
asked for.

---

## At a glance

| | Desktop (Windows / macOS) | Chrome extension | iOS |
|---|---|---|---|
| User account | None | None | None |
| Data sent to a QuakeSignal server | **None** | **None** | Only if you enable notifications |
| Third-party services contacted | Wolfx | Wolfx | Wolfx, and Cloudflare + Apple APNs for notifications |
| Where your data lives | Your computer | Your browser profile | Your device, plus notification settings on Cloudflare |

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
with a Cloudflare D1 database).

If, and only if, you enable notifications, the following is stored for your
device:

| Stored | Purpose |
|---|---|
| APNs device token | Addressing the notification to your device |
| Latitude and longitude, or a chosen city name | Deciding whether an event is near enough to alert you |
| Alert radius, minimum magnitude, selected sources | Matching your alert thresholds |
| Locale, UTC offset, night-notification preference | Localizing text and honouring quiet hours |
| Critical-alert and test-alert preferences | Respecting your alert choices |
| Created and updated timestamps | Housekeeping |

This is the complete set — it is the `devices` table in
[`backend/cloudflare/migrations/`](../backend/cloudflare/migrations/), which
you can read yourself.

**What is not stored.** No name, no email address, no account, no contacts, no
advertising identifier, and no history of your movements. Coordinates are
stored as your current alert location, not as a location trail.

**Third parties in the notification path.** Cloudflare (Workers and D1) hosts
the service; Apple's APNs delivers the notification. Notification text is
localized on your device using APNs `loc-key` values, so translated copy is not
stored on the server.

**How to delete it.** Turn off notifications in the app, which removes your
device registration, or delete the app. You can also open an issue to request
deletion.

---

## Data we never collect, on any platform

No names, email addresses, passwords or accounts. No contacts, photos,
calendars, messages or files. No browsing history or website content. No
advertising identifiers or cross-app tracking. No analytics or usage telemetry.
No payment information — QuakeSignal is free and has no purchases.

## Third-party services

| Service | Used by | What it receives |
|---|---|---|
| [Wolfx](https://wolfx.jp) | All clients | Ordinary connection metadata such as your IP address, under [its own policies](https://wolfx.jp) |
| Cloudflare (Workers, D1) | iOS notifications only | The device registration described above |
| Apple APNs | iOS notifications only | The notification payload and your device token |
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
