# Wolfx Open API — Field Reference

Source: https://wolfx.jp (usage guide), https://wolfx.jp/wsapi_en (WebSocket guide),
verified against live responses on 2026-07-19. Not an official Wolfx document —
this is our own distillation for QuakeSignal's implementation. Re-check
`https://wolfx.jp` if Wolfx bumps their doc version (footer shows `Doc version`).

Wolfx is an unofficial relay whose broader API includes JMA, CENC, and
provincial earthquake-administration data. Review the current
[Wolfx Terms of Service](https://wolfx.jp/en/legal/terms/) and
[Open API documentation](https://wolfx.jp/en/docs/open-api/) before shipping an
app that depends on it. No Wolfx email is planned for Apple build 8.

For App Store distribution, use the reviewed published-terms mapping in
[`content-rights-evidence.md`](../ios/AppStore/content-rights-evidence.md).
The release owner decided on 20 August 2026 not to send the contingency request
in [`WOLFX_PERMISSION_REQUEST.md`](WOLFX_PERMISSION_REQUEST.md). Open-source
licensing of QuakeSignal is not itself permission for a third-party service:
recheck the current Wolfx Terms of Service, this API document version,
applicable source terms, enabled feeds, attribution, product behavior, and
territories at action time. The app must never expose a public secondary API or
resell Wolfx data. If Apple or a source asks for additional authorization,
pause and narrow the affected scope or obtain it instead of claiming a private
license.

## Apple build-8 release scope

The coordinated Apple build-8 contract enables exactly:

- `jma_eew`
- `jma_eqlist`

It disables `cenc_eew`, `cenc_eqlist`, `sc_eew`, `fj_eew`, and `cq_eew` in
every submitted Apple target and the developer-operated notification relay.
The Apple clients and relay must connect to the two direct JMA routes; the
combined `all_eew` route is outside this release contract. The wider endpoint
and schema inventory below remains implementation/reference history and must
not be read as a claim that every documented Wolfx feed ships in build 8.

JMA content is mapped through JMA's
[website terms](https://www.jma.go.jp/jma/en/copyright.html) and the
[Public Data License 1.0](https://www.digital.go.jp/en/resources/open_data/public_data_license_v1.0),
including source citation, normalized/edited-content identification, and
non-endorsement requirements. JMA's
[earthquake-motion forecasting FAQ](https://www.jma.go.jp/jma/kishou/minkan/q_a_s.html)
and [application guide](https://www.jma.go.jp/jma/kishou/minkan/tebiki/jishin_tebiki.pdf)
define the statutory boundary used by this release: QuakeSignal formats,
deduplicates, and filters delivery of JMA-issued facts, but does not calculate
predicted local intensity or ground-motion arrival and does not issue a
QuakeSignal-authored official warning. Relay events and revisions become
eligible for deletion after 89 days and are removed by the next successful
daily cleanup; operational failures can delay deletion. The relay exposes no
public secondary data API.

Every endpoint is available two ways:
- **HTTP GET**, returns the current/latest snapshot as JSON — good for polling
  and for the app's direct foreground "pull to refresh".
- **WebSocket**, pushes a new JSON message whenever the upstream source
  publishes an update — this is what the backend relay should use, since EEW
  latency matters.

## WebSocket connection contract

- Base host: `wss://ws-api.wolfx.jp/<endpoint>`
- The published v20260415 table describes heartbeat `ver` as a number, `id` as
  a connection UUID, and the millisecond `timestamp` as a string. Direct-route
  observations on 2026-08-21 instead returned a positive decimal connection
  ID and numeric millisecond timestamps for both heartbeat and pong. The relay
  accepts only canonical forms of either documented or observed representation;
  arbitrary text or objects fail closed. There is no requirement to respond,
  but a client may send the literal string `ping` for a pong liveness check.
- A client may also send one of the manual query commands below to force a
  fresh push of current data without waiting for the next natural update:
  `query_sceew`, `query_jmaeew`, `query_fjeew`, `query_cqeew`, `query_cenceew`,
  `query_cenceqlist`, `query_jmaeqlist`.
- Every real data message includes a `"type"` field (WebSocket-only — the HTTP
  JSON responses omit it since the endpoint already disambiguates) equal to
  the endpoint name, e.g. `"jma_eew"`. Use it to route the payload to the
  right decoder on the combined `all_eew` feed.

## Full upstream endpoint reference

| Source | HTTP GET | WebSocket | Purpose |
|---|---|---|---|
| JMA EEW | `https://api.wolfx.jp/jma_eew.json` | `wss://ws-api.wolfx.jp/jma_eew` | Japan early warning |
| Sichuan EEW | `https://api.wolfx.jp/sc_eew.json` | `wss://ws-api.wolfx.jp/sc_eew` | Sichuan bureau early warning |
| CENC EEW | `https://api.wolfx.jp/cenc_eew.json` | `wss://ws-api.wolfx.jp/cenc_eew` | China Earthquake Networks Center early warning |
| Fujian EEW | `https://api.wolfx.jp/fj_eew.json` | `wss://ws-api.wolfx.jp/fj_eew` | Fujian bureau early warning |
| Chongqing EEW | `https://api.wolfx.jp/cq_eew.json` | `wss://ws-api.wolfx.jp/cq_eew` | Chongqing bureau early warning |
| CENC earthquake list | `https://api.wolfx.jp/cenc_eqlist.json` | `wss://ws-api.wolfx.jp/cenc_eqlist` | Last 50 reviewed CENC earthquakes |
| JMA earthquake list | `https://api.wolfx.jp/jma_eqlist.json` | `wss://ws-api.wolfx.jp/jma_eqlist` | Last 50 JMA earthquake info reports |
| Combined | — | `wss://ws-api.wolfx.jp/all_eew` | All EEW sources multiplexed on one socket, disambiguated by `type` |

**Important field-name quirk (verified live, keep exactly as-is when decoding):**
JMA, Sichuan and Fujian payloads spell the magnitude field **`Magunitude`**
(typo in the upstream API, not ours). CENC and Chongqing spell it correctly,
**`Magnitude`**. Do not "fix" the typo in DTOs — it will break decoding.

### `jma_eew` (flat object)

```json
{
  "Title": "緊急地震速報（予報）",
  "CodeType": "Ｍ、最大予測震度及び主要動到達予測時刻の緊急地震速報",
  "Issue": { "Source": "大阪", "Status": "通常" },
  "EventID": "20260718094827",
  "Serial": 6,
  "AnnouncedTime": "2026/07/18 09:48:59",
  "OriginTime": "2026/07/18 09:48:24",
  "Hypocenter": "奄美大島近海",
  "Latitude": 28.3,
  "Longitude": 129.7,
  "Magunitude": 3.7,
  "Depth": 10,
  "MaxIntensity": "3",
  "Accuracy": { "Epicenter": "...", "Depth": "...", "Magnitude": "..." },
  "MaxIntChange": { "String": "ほとんど変化なし", "Reason": "..." },
  "WarnArea": [
    { "Chiiki": "...", "Shindo1": "...", "Shindo2": "...", "Time": "...", "Type": "Forecast", "Arrive": false }
  ],
  "isSea": true,
  "isTraining": false,
  "isAssumption": false,
  "isWarn": false,
  "isFinal": true,
  "isCancel": false,
  "OriginalText": "37 04 00 260718094859 C11 ..."
}
```
`AnnouncedTime`/`OriginTime` are in JST (UTC+9), formatted `yyyy/MM/dd HH:mm:ss`.
`MaxIntensity` is JMA shindo scale, string, e.g. `"3"`, `"5-"`, `"5+"`, `"6-"`, `"6+"`.

### `sc_eew` / `fj_eew` (Sichuan / Fujian, flat object)

```json
{
  "ID": 12345, "EventID": "...", "ReportTime": "2026-07-18 13:47:20",
  "ReportNum": 1, "OriginTime": "2026-07-18 13:47:20",
  "HypoCenter": "...", "Latitude": 38.7, "Longitude": 75.0,
  "Magunitude": 4.8, "Depth": 5, "MaxIntensity": 6.2
}
```
Fujian's payload omits `Depth`/`MaxIntensity` and instead carries `isFinal`
(boolean) per the published field list — treat those fields as optional across
all EEW DTOs and don't assume every source populates every column.
`ReportTime`/`OriginTime` are UTC+8, same `yyyy-MM-dd HH:mm:ss` format.

### `cenc_eew` / `cq_eew` (CENC / Chongqing, flat object, verified live)

```json
{"ID":"b3i6pz76gqcyy","EventID":"202607181347.0001","ReportTime":"2026-07-18 13:47:20",
 "ReportNum":1,"OriginTime":"2026-07-18 13:47:20","HypoCenter":"新疆克孜勒苏州阿克陶县",
 "Latitude":38.747,"Longitude":75.088,"Magnitude":4.8,"Depth":5,"MaxIntensity":6.2}
```
`MaxIntensity` here is a continuous instrumental-style number (not an integer
step scale) — format to 1 decimal place in the UI.

### `cenc_eqlist` (object keyed `No1..No50` + `md5`, verified live)

```json
{
  "No1": {
    "type": "reviewed",
    "EventID": "CC.20260718185522.2",
    "time": "2026-07-18 18:36:17",
    "ReportTime": "2026-07-18 18:55:26",
    "location": "塔吉克斯坦",
    "placeName": "塔吉克斯坦",
    "magnitude": "5.3",
    "depth": "140",
    "latitude": "37.70",
    "longitude": "72.55",
    "intensity": "5"
  },
  "md5": "..."
}
```
Every value here is a **string**, including numerics — parse before use.
`type` per-entry is `"automatic"` or `"reviewed"` (not to be confused with the
outer WebSocket envelope `"type": "cenc_eqlist"`, which only exists on the WS
transport, one level up, not per-entry).

### `jma_eqlist` (object keyed `No1..No50` + `md5`, verified live)

```json
{
  "No1": {
    "Title": "震源・震度情報",
    "EventID": "20260718094827",
    "time": "2026/07/18 09:48",
    "time_full": "2026/07/18 09:48:00",
    "location": "奄美大島近海",
    "magnitude": "3.4",
    "shindo": "1",
    "depth": "20km",
    "latitude": "28.5",
    "longitude": "129.7",
    "info": "この地震による津波の心配はありません。"
  },
  "md5": "..."
}
```
`depth` includes the `km` unit inside the string (e.g. `"20km"`) — strip it
before parsing as a number. `info` (tsunami advisory text) is usually only
non-empty on the first entry. `EventID` contains the earthquake's origin time,
whereas `time`/`time_full` contain the published report time; current valid
snapshots can differ by one or more minutes. Validate both calendars, but do
not require those two distinct timestamps to share a minute.

## Practical notes for QuakeSignal

- **Dedup / update tracking**: for EEW endpoints, the same physical event is
  re-published multiple times as `Serial`/`ReportNum` increases (magnitude and
  area estimates get refined in near-real time) until `isFinal`/`isCancel`.
  Key alert state by `EventID`, and re-notify only when the serial number
  increases or the state flips to `isWarn`/`isFinal`/`isCancel` — never treat
  every message as a brand-new event.
- **No documented rate limit** was published; be a good citizen anyway — one
  persistent WebSocket per endpoint from the backend, not per-device polling.
  If a required backend WebSocket source remains unavailable for 90 seconds,
  the private relay polls only the affected stale JMA source or sources through
  a bounded emergency HTTP alternate transport: one source request at a time,
  at least 600 ms apart. It validates and deduplicates each snapshot before
  durable ingestion. A recovered source leaves alternate polling once its
  WebSocket is current again; aggregate health reports WebSocket transport only
  after all required routes recover. This is not a public secondary API.
- **No auth/API key required** for any of the endpoints used here.
