<div align="right">

[简体中文](README.zh-CN.md) · [日本語](README.ja.md)

</div>

<div align="center">

<img src="ios/QuakeSignal/Assets.xcassets/AppIcon.appiconset/icon-1024.png" width="112" alt="QuakeSignal app icon" />

# QuakeSignal

### Earthquake reports, nearby alerts, and preparedness for iPhone, macOS, and Windows.

[![iOS 17+](https://img.shields.io/badge/iOS-17%2B-0E63C4?logo=apple&logoColor=white)](ios/)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](ios/QuakeSignal/)
[![Tauri 2](https://img.shields.io/badge/desktop-Tauri_2-24C8DB?logo=tauri&logoColor=white)](desktop/)
[![Cloudflare Workers](https://img.shields.io/badge/backend-Cloudflare_Workers-F38020?logo=cloudflare&logoColor=white)](backend/cloudflare/)
[![Languages](https://img.shields.io/badge/languages-English_·_日本語_·_简体中文-0A3D73)](#localization)
[![MIT License](https://img.shields.io/badge/license-MIT-30B14F)](LICENSE)

QuakeSignal turns aggregated public seismic data into focused native apps: an
iOS experience with location-aware push alerts and preparedness guidance, plus
a local-first macOS and Windows monitor with direct feeds and audible alarms.

<br />

<img src="docs/screenshots/app-home-en.png" width="210" alt="QuakeSignal home screen in English" />
&nbsp;&nbsp;
<img src="docs/screenshots/app-home-ja.png" width="210" alt="QuakeSignal home screen in Japanese" />
&nbsp;&nbsp;
<img src="docs/screenshots/app-home-zh.png" width="210" alt="QuakeSignal home screen in Simplified Chinese" />

<sub>Real iOS Simulator captures from the same SwiftUI build in English, Japanese, and Simplified Chinese.</sub>

</div>

> [!IMPORTANT]
> QuakeSignal is an independent, non-official app. Earthquake information comes from third-party aggregated sources and may be delayed, incomplete, revised, or inaccurate. Always follow official announcements and local emergency instructions.

## What it does

| | Capability | Details |
|---|---|---|
| 📡 | Live earthquake data | Normalizes seven Wolfx feeds covering JMA, CENC, Sichuan, Fujian, and Chongqing data. |
| 📍 | Nearby context | Frames events by a selected city or current location, with distance, direction, radius, and magnitude controls. |
| ⚠️ | Clear alert states | Separates preliminary, updated, final, cancelled, and training messages so color is never the only signal. |
| 🔔 | Background delivery | Uses APNs for notifications when the app is backgrounded, locked, or terminated. |
| 🖥️ | Local-first desktop | Connects directly to upstream WebSockets, stores data locally, and can sound a native alarm from the tray—without the QuakeSignal backend. |
| 🗺️ | Explore events | Includes a filterable list, epicenter map, event detail, and report-revision timeline. |
| 🧰 | Offline preparedness | Provides drop-cover-hold-on guidance, situation-specific actions, an emergency checklist, and family check-in notes. |
| ♿ | Accessible by design | Supports Dynamic Type, VoiceOver-friendly labels, 44pt targets, system appearance, and high-contrast status treatments. |

## Designed for the moment that matters

The interface follows the [QuakeSignal design artifact](https://claude.ai/code/artifact/f209373f-ec4d-41ee-9c7a-ec315e4861e0): calm blue for normal information, escalating orange and red for severity, and a deliberately distinct purple treatment for drills.

| Normal | Caution | Warning | Training |
|:---:|:---:|:---:|:---:|
| `#30B14F` | `#FF9500` | `#FF3B30` | `#8E5BE0` |
| No significant nearby event | Recent nearby activity | Active protective action | Clearly marked test content |

The complete design notes—including tokens, components, onboarding, empty/error states, dark mode, and localized screen copy—are captured in [`docs/DESIGN_PROMPT.md`](docs/DESIGN_PROMPT.md).

## Architecture

iOS cannot keep an arbitrary WebSocket alive after an app is backgrounded or terminated, so it uses a Cloudflare relay and APNs. The macOS and Windows app stays local-first and connects directly to the upstream feeds.

```mermaid
flowchart LR
    subgraph Sources["Wolfx Open API"]
        JMA["JMA feeds"]
        CENC["CENC feeds"]
        Regional["Sichuan · Fujian · Chongqing"]
    end

    subgraph Edge["Cloudflare free-tier backend"]
        Relay["Durable Object<br/>live WebSocket relay"]
        Normalize["Normalize · deduplicate<br/>track revisions"]
        DB[("D1")]
    end

    subgraph App["QuakeSignal · SwiftUI"]
        Foreground["REST history + live socket"]
        Background["APNs notifications"]
        Guide["Offline safety guide"]
    end

    subgraph Desktop["QuakeSignal · Tauri desktop"]
        Direct["Direct WebSockets"]
        Local[("Local SQLite")]
        NativeAlarm["Native alarm + notification"]
    end

    Sources --> Relay --> Normalize --> DB
    DB --> Foreground
    Normalize --> Background
    Guide --- App
    Sources --> Direct --> Local
    Direct --> NativeAlarm
```

### Repository map

- [`ios/`](ios/) — native SwiftUI app for iOS 17+, built with Swift 6
- [`desktop/`](desktop/) — local-first Tauri app for macOS and Windows, with direct feeds, SQLite, and native alarms
- [`backend/cloudflare/`](backend/cloudflare/) — production Worker, Durable Object relay, D1 migration, APNs delivery, and smoke test
- [`backend/`](backend/) — local Node.js relay for backend development
- [`docs/WOLFX_API.md`](docs/WOLFX_API.md) — field-level upstream data reference verified against live responses
- [`docs/DESIGN_PROMPT.md`](docs/DESIGN_PROMPT.md) — product and visual design specification

## Quick start

### 1. Start the local backend

```bash
cd backend
cp .env.example .env
npm install
npm run dev
```

APNs credentials are optional for local REST/WebSocket development. The server listens on `http://localhost:8080`.

### 2. Run the iOS app

Open [`ios/QuakeSignal.xcodeproj`](ios/QuakeSignal.xcodeproj) in Xcode, choose an iPhone Simulator, and run the `QuakeSignal` scheme.

The app uses the production Cloudflare deployment by default. Set the `QUAKESIGNAL_API_BASE_URL` launch environment variable to `http://localhost:8080` when developing against the local backend. Push notifications require a physical device, an Apple Developer team, and APNs credentials.

### 3. Run the desktop app

The desktop edition connects directly to Wolfx and does not require either
backend:

```bash
cd desktop
npm ci
npm run tauri dev
```

Use **Settings → Test Alarm & Notification** to verify native sound and
notification permissions on the current computer.

### 4. Verify

```bash
cd backend
npm run typecheck
npm run build

cd cloudflare
npm run check
npm run test:remote -- https://quakesignal-api.hopeso.workers.dev

cd ../../desktop
npm run build
cargo test --locked --manifest-path src-tauri/Cargo.toml
```

The remote smoke test checks production health, normalized live data, event detail/revisions, and the public WebSocket upgrade.

## Production backend

The production API is live at [`quakesignal-api.hopeso.workers.dev`](https://quakesignal-api.hopeso.workers.dev). It uses services available on Cloudflare's free plan for a small public launch:

- Workers provides the HTTPS API.
- A Durable Object maintains the upstream relay and fans out live updates.
- D1 stores device subscriptions, normalized events, and revision history.
- APNs uses token-based authentication stored as encrypted Worker secrets.
- A one-minute alarm reseeds HTTP data and repairs disconnected upstream sockets.

Deployment and APNs setup are documented in [`backend/README.md`](backend/README.md).

## Localization

Every user-facing flow is localized in:

- English (`en`)
- Japanese (`ja`)
- Simplified Chinese (`zh-Hans`)

Push notification text is localized on-device with APNs `loc-key` values, so a single event can be delivered in each user’s chosen language without storing translated notification copy on the server.

## Safety and delivery limits

- QuakeSignal aggregates data; it is not affiliated with JMA, CENC, Wolfx, or a government emergency agency.
- Mobile push delivery is best-effort and depends on the upstream provider, network, Cloudflare, APNs, iOS settings, Focus modes, and device state.
- The countdown is an estimate based on event time, distance, and a simplified S-wave velocity—not a seismological guarantee.
- Critical Alerts require a separate entitlement granted by Apple. Without it, QuakeSignal uses standard or time-sensitive notifications.

## License

QuakeSignal is available under the [MIT License](LICENSE).
