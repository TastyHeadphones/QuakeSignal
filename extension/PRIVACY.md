# QuakeSignal for Chrome — Privacy Policy

Effective date: July 31, 2026

QuakeSignal for Chrome is a free and open-source earthquake monitor published
by UniSphereco LLC. Its single purpose is to monitor public earthquake data and
show user-configured browser notifications and alarm sounds.

## Data collection

QuakeSignal does not collect, sell, share, or transmit personal or sensitive
user data to QuakeSignal, UniSphereco LLC, advertising services, analytics
services, or data brokers. It does not read browsing history, website content,
cookies, account information, or precise location.

The extension stores only these items in Chrome's local extension storage:

- alert preferences, such as notification, alarm, and magnitude settings;
- recent public earthquake events received from the upstream data provider;
- connection-status information needed to show whether feeds are online.

This data remains on the user's device. Users can delete it by removing the
extension or clearing the extension's local storage.

## Network access

The extension connects directly over encrypted WebSocket connections to
`ws-api.wolfx.jp` to receive public earthquake information. No earthquake data
is routed through a QuakeSignal server. As with any direct network request, the
upstream provider may receive ordinary connection metadata such as an IP
address according to its own policies.

## Chrome permissions

- **Storage** keeps preferences and recent public earthquake events locally.
- **Notifications** displays user-enabled earthquake alerts.
- **Offscreen** plays the user-enabled alarm sound; it is not used to inspect
  websites or browsing activity.
- **Alarms** periodically verifies that direct earthquake-feed connections are
  available.
- **Host access to `ws-api.wolfx.jp`** is limited to receiving public earthquake
  data directly from that provider.

## Limited use

Any information received through Chrome or Google APIs is used only to provide
or improve QuakeSignal's single user-facing purpose. It is not used for
advertising, profiling, creditworthiness, or sale to third parties, and humans
do not read user data.

## Changes and contact

Material changes will be reflected in this policy and, when required, disclosed
inside the extension. Questions can be filed through the public
[QuakeSignal issue tracker](https://github.com/TastyHeadphones/QuakeSignal/issues).
