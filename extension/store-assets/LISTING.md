# Chrome Web Store listing

## Summary

Free, open-source earthquake monitoring with direct feeds, local history,
browser notifications, and optional alarm sounds.

## Detailed description

QuakeSignal is a free and open-source earthquake monitor for Chrome.

It connects directly to public Wolfx earthquake feeds, keeps recent events in
local browser storage, and can show browser notifications and play an alarm
sound when an event matches your selected minimum magnitude.

Features:

- Direct earthquake feeds with no QuakeSignal data backend
- Recent earthquake history stored only in Chrome local storage
- Browser notifications and optional audible alarms
- Configurable minimum-magnitude filter
- English, Japanese, and Simplified Chinese interface
- Free and open-source under the MIT License
- No account, advertising, analytics, or tracking

QuakeSignal is independent and is not an official warning service. Aggregated
third-party information can be delayed, incomplete, revised, or inaccurate.
Always follow official announcements and local emergency instructions.

Source code: https://github.com/TastyHeadphones/QuakeSignal

## Category

News & Weather

## Single purpose

Monitor public earthquake feeds and notify the user about matching earthquake
events through a browser notification and optional alarm sound.

## Permission justifications

- `storage`: Stores alert preferences, recent public earthquake events, and
  connection status locally in Chrome.
- `notifications`: Displays user-enabled earthquake alerts and test alerts.
- `offscreen`: Plays the user-enabled earthquake alarm sound using Web Audio;
  it does not access websites or browsing activity.
- `alarms`: Periodically wakes the service worker to verify and restore direct
  earthquake-feed connections.
- Host access to `https://ws-api.wolfx.jp/*`: Establishes secure WebSocket
  connections to the public Wolfx earthquake feeds. No other website is read or
  modified.

## Data-use answers

- Collects or uses personal or sensitive user data: **No**
- Uses remote code: **No**
- Uses data for advertising, analytics, profiling, or sale: **No**
- Privacy policy:
  https://github.com/TastyHeadphones/QuakeSignal/blob/main/extension/PRIVACY.md

## Distribution

- Visibility: Public
- Regions: All regions
- Pricing: Free
- In-app purchases: No

## Reviewer test instructions

1. Install the extension and open the QuakeSignal toolbar popup.
2. Confirm that the source indicator begins connecting and recent public
   earthquake events populate from Wolfx.
3. Open Alert settings and click **Test alarm & notification**.
4. Confirm that Chrome displays a test notification and plays the alarm when
   alarm sound is enabled.
5. Change the minimum-magnitude setting and reopen the popup to confirm the
   preference is retained locally.

No account or test credentials are required.
