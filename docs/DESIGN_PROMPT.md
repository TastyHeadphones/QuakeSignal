# QuakeSignal — English Design/Build Prompt

> **Note on source design (superseded):** this prompt was originally written
> when the linked Claude design canvas (`claude.ai/design/p/78c53605-...`)
> wasn't reachable without the owner's login. Access has since been granted,
> and the real design project ("震息 · QuakeSignal iOS App Design") turned out
> to be a full design system — icon concepts, color/type/spacing tokens, a
> component sheet, and high-fidelity mockups for onboarding, a 5-tab
> home/list/map/guide/settings structure, a full-screen alert with a
> drop-cover-hold-on illustration and countdown, a report-revision timeline,
> a disaster-prep guide, empty/error states, and en/ja/zh-Hans localization
> of the key screens. That real design is richer than — and in places
> different from — the spec below (e.g. it adds a List tab and a Disaster
> Guide tab, and frames everything around distance from the user's
> subscribed city). This document is kept as-is for reference/history. The
> app has since been rebuilt to follow the real design closely (5 tabs,
> location/distance framing, the drop-cover-hold-on alert, the report
> timeline, the disaster guide, the exact color tokens) — see the root
> [README](../README.md) for current status.

---

## Prompt

Design and build a native iOS app called **QuakeSignal** — a real-time earthquake
early-warning (EEW) and seismic-information client for users in Japan, mainland
China, and English-speaking regions.

### Purpose

The app's single most important job is to get a life-safety alert in front of the
user **within seconds** of an earthquake early-warning being issued, even if the
app is closed or the phone is locked or muted. Everything else (history browsing,
settings, maps) is secondary to that core promise.

### Data source

All seismic data comes from the Wolfx Open API (`https://wolfx.jp`), which
republishes official feeds from:
- Japan Meteorological Agency (JMA) — earthquake early warnings + earthquake list
- China Earthquake Networks Center (CENC) — earthquake early warnings + earthquake list
- Sichuan / Fujian / Chongqing provincial earthquake administrations — early warnings

See `docs/WOLFX_API.md` for the exact endpoints and JSON field contracts.

### Languages

Full UI localization in three languages, selected by system locale with an
in-app override:
- **English (en)**
- **Japanese (ja)** — for JMA-sourced alerts and JP-based users
- **Simplified Chinese (zh-Hans)** — for CENC/Sichuan/Fujian/Chongqing-sourced
  alerts and CN-based users

Place names and original agency text (e.g. `Hypocenter` / `HypoCenter` /
`location` fields) are always shown **as published by the source agency**
(Japanese place names from JMA, Chinese place names from CENC) — these are not
machine-translated, matching how real EEW apps behave. Only the app's own UI
chrome (labels, buttons, units, alert copy) is localized.

### Information architecture

1. **Onboarding** (first launch only)
   - 2–3 short screens explaining what the app does and why it needs
     Notifications (and ideally Critical Alerts) permission, then a system
     permission prompt.
2. **Home** (tab 1)
   - Big status header: monitoring is active, which sources are subscribed,
     last time data was refreshed.
   - "Latest event" card if a recent quake/EEW exists.
   - Scrollable feed of recent alerts/quakes, grouped by day, sourced from
     the combined history (CENC + JMA lists, most recent first).
   - Tapping a card opens Detail.
3. **Alert (full-screen, system-presented over anything)**
   - Triggered the instant a push notification for a live EEW is tapped, or
     automatically foregrounded if the app is already open when one arrives.
   - Full-bleed color-coded background by severity (see palette below).
   - Huge magnitude number, estimated/observed max intensity, hypocenter name,
     origin time, and — for JMA PLUM/EEW forecasts that include target-area
     lead times — a countdown ring to estimated shaking arrival for the user's
     area if determinable.
   - "This is an early warning / this is a final report / this has been
     cancelled" state banner (`isWarn` / `isFinal` / `isCancel`).
   - Primary action: dismiss. Secondary: view on map, view details.
4. **Detail**
   - Full data readout for one event: all fields from the source payload,
     formatted (magnitude, depth, coordinates, accuracy notes for JMA,
     per-area intensity breakdown for JMA `WarnArea`), plus a small map.
5. **Map** (tab 2, or reachable from Home/Detail)
   - MapKit view centered on Japan+China region, pins for recent epicenters,
     pin size/color scaled by magnitude, tap for a mini detail card.
6. **Settings** (tab 3)
   - Language override (System / English / 日本語 / 简体中文).
   - Source toggles: JMA EEW, CENC EEW, Sichuan EEW, Fujian EEW, Chongqing EEW,
     CENC earthquake list, JMA earthquake list — each independently on/off.
   - Minimum magnitude / minimum intensity threshold below which no push is sent.
   - Notification style: sound on/off, "Critical Alert" opt-in explainer (with a
     link to enable it in system Settings if the entitlement is granted).
   - "Send test alert" button that exercises the full push pipeline end to end.
   - About / data-source attribution (Wolfx is a relay of JMA/CENC/provincial
     bureaus — link their ToS/Privacy Policy per Wolfx's usage terms), app
     version, links to Privacy Policy and open-source licenses.

### Visual design direction

- Dark-mode-first (earthquakes happen at night too; a bright white full-screen
  alert is the wrong choice at 3am) but must support Light Mode cleanly.
- Severity palette drives the whole app's accent color, not just the alert
  screen:
  - Advisory / low intensity → blue/teal
  - Moderate → amber
  - Strong → orange
  - Severe/major → red
  - Cancelled report → gray
- Large, legible numerals for magnitude and intensity (this is read in a
  stressful moment — optimize for a glance, not for density).
- Respect Dynamic Type and VoiceOver; the alert screen in particular must be
  fully readable by screen reader since not all users can read a screen in a
  panic.
- SF Symbols for iconography, SF Pro / system font, standard iOS
  navigation patterns (tab bar + stack navigation), no custom chrome that
  fights the platform.

### Non-functional requirements

- Because iOS apps cannot hold an open WebSocket connection indefinitely in
  the background, delivery of alerts while the app is not in the foreground
  **must** go through Apple Push Notification service (APNs), fed by a small
  always-on backend service that maintains the persistent WebSocket
  connections to Wolfx. See `backend/README.md`.
- Target iOS 17+, SwiftUI, Swift 6 (strict concurrency).
- Push payloads use APNs `loc-key`/`loc-args` so the notification text is
  localized on-device from the user's own language setting without the
  backend needing to know it.
- The app's only server integration surface is our own backend, never Wolfx
  directly: `GET /v1/quakes/recent` for history and a `/v1/live` WebSocket
  for sub-second foreground updates, both already normalized. This keeps
  Wolfx's field quirks (see `docs/WOLFX_API.md`) parsed in exactly one place.
  Background delivery relies on the backend + APNs path.

### Explicitly out of scope for v1

- Machine translation of agency-published place names.
- Any prediction/forecasting beyond what the source agencies publish (this
  app is a **relay and alerting client**, not a seismology product).
- Account system / social features.
