# Wolfx permission request for App Store distribution

QuakeSignal must not certify in App Store Connect that UniSphereco LLC holds
all required rights to third-party earthquake content until Wolfx has confirmed
the intended use in writing. Wolfx's current [Terms of Service](https://wolfx.jp/tos_en)
prohibit re-providing API data as a programmatically accessible secondary API
and reserve rights in Wolfx original content. The app does not expose such an
API, but its private alert relay and worldwide App Store distribution require a
clear upstream answer.

Send this request from a UniSphereco LLC-controlled address to Wolfx before
finishing the iOS or macOS **Content Rights** certification. Preserve Wolfx's
written reply with the release records.

## Ready-to-send request

**Subject:** Permission request — QuakeSignal iOS/macOS App Store use of Wolfx Open API

Hello Wolfx Project,

UniSphereco LLC is preparing **QuakeSignal**, a free, independent iOS and macOS
earthquake-information application for global App Store distribution. The app
will clearly state that it is not an official government warning service and
will direct people to official local emergency guidance.

Could you please confirm whether the following use of the Wolfx Open API is
permitted, and tell us any required attribution, source-agency, licensing, or
regional restrictions?

1. The iOS and macOS clients fetch and display normalized current/historical
   earthquake and EEW information directly from Wolfx's documented public HTTP
   and WebSocket endpoints.
2. A private Cloudflare backend receives Wolfx updates only to match opted-in
   users' alert settings and sends best-effort Apple Push Notification service
   alerts derived from those updates while the iOS app is backgrounded.
3. The app will be distributed globally through Apple App Store Connect without
   charging for Wolfx data.

QuakeSignal does **not** expose Wolfx data through a public secondary API,
does not sell or sublicense the data, and does not make the backend relay
available to third parties. We will follow any attribution and link
requirements you specify.

Thank you,

GENG YANG
UniSphereco LLC
kurtbun@outlook.com
+81 80 6218 6994

## Release gate

- Answer **Yes** in App Store Connect to the question that the app contains,
  shows, or accesses third-party content.
- Do **not** complete the certification that UniSphereco LLC has all necessary
  rights in every selected App Store country or region until the written Wolfx
  confirmation has been received and reviewed.
- Treat the reply as a legal/business release record; this document is a
  request template, not legal advice.
