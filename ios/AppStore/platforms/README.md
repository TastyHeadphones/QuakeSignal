# Native platform App Store metadata — 1.1 (8)

This directory contains offline, English (U.S.) review drafts for the native
Apple TV, Apple Vision Pro, and Apple Watch experiences in QuakeSignal 1.1,
build 8. Nothing here changes App Store Connect, uploads a build, certifies a
questionnaire, or authorizes release.

The canonical App Store Connect record for these targets is **QuakeSignal**,
Apple ID `6800642443`:

| Experience | Store placement | Version / build | Metadata source |
| --- | --- | --- | --- |
| iPhone and iPad | iOS platform version | `1.1 (8)` | `../../en-US/` and the root iOS review files |
| Apple Watch companion | Apple Watch section of the iOS version; embedded in the iOS upload | `1.1 (8)` | `watchos/` plus the shared iOS description/review notes |
| Apple TV | tvOS platform version | `1.1 (8)` | `tvos/` |
| Apple Vision Pro | visionOS platform version | `1.1 (8)` | `visionos/` |

Apple documents that tvOS and visionOS platform versions in a multi-platform
record use the record's existing Apple ID, SKU, and bundle ID, while an Apple
Watch companion is uploaded from the same Xcode project as its iOS host. See
[Add platforms](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-platforms/)
and
[Add watchOS app information](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-watchos-app-information).

The separate Tauri macOS app remains in **QuakeSignal for macOS**, Apple ID
`6800642853`, because its bundle ID is `com.quakesignal.desktop`. Do not attach
that package to the unused macOS draft inside Apple ID `6800642443` and do not
claim a Universal Purchase for the separate Mac app.

## Truthful platform scope

| Platform | Customer-visible behavior | Notification capability in this release |
| --- | --- | --- |
| iPhone / iPad | Full reports, map, preparedness guide, settings, and optional nearby notifications | Protected App Attest + APNs registration. Qualifying fresh warnings may use **Time Sensitive**, subject to system/user settings. There is no Critical Alerts entitlement. |
| Apple Vision Pro | Full native windowed app with reports, map, guide, settings, and local foreground warning presentation while open | Foreground only. Apple does not list Push Notifications or Time Sensitive Notifications as supported visionOS provisioning capabilities, so this target has no APNs, App Attest, Time Sensitive, Critical Alerts, or background emergency-alert path. |
| Apple TV | Large-screen headline, recent-report list, event details, and manual/active refresh | Foreground only. No APNs, App Attest, alert audio, or background emergency alerts. |
| Apple Watch | Compact headline, recent-report list, event details, and refresh when opened | Foreground only. The Watch app does not independently register for APNs, App Attest, alert audio, or background emergency alerts. Paired-iPhone alerts remain an iPhone feature. |

On iPhone and iPad, Time Sensitive notifications are not Critical Alerts and
remain under user and system control. Apple states that users can disable Time
Sensitive interruptions, while Critical alerts require a separately approved
entitlement. Apple Vision Pro remains foreground-only in this release; see
Apple's current
[visionOS capability table](https://developer.apple.com/help/account/reference/supported-capabilities-visionos/).
See Apple's documentation for
[Time Sensitive notifications](https://developer.apple.com/documentation/usernotifications/unnotificationinterruptionlevel/timesensitive)
and
[Critical notifications](https://developer.apple.com/documentation/usernotifications/unnotificationinterruptionlevel/critical).

## Copy and asset map

Each platform directory contains:

- English platform-version copy in `description.txt`, `promotional_text.txt`,
  and `keywords.txt`. The app name and subtitle belong to the shared app record,
  so this kit does not invent platform-specific replacements for them.
- Reviewer instructions in `review-notes.txt`.
- A planned screenshot manifest for the frozen build-8 binary. Every image is
  still marked pending and has no invented hash or capture evidence.

Apple Watch has no separate platform description field for this companion.
Apple requires the iOS description to explain the Watch functionality. The
Watch `description.txt` is therefore a source paragraph, and its exact meaning
is incorporated into `../../en-US/description.txt`.

Only the approved English (U.S.) listing is ready for portal review. Do not add
Japanese or Simplified Chinese product-page localizations until the release
owner approves each exact display name, availability, and trademark review.

## Required human gates

- [ ] Freeze the exact source commit and build 8 archives.
- [ ] Obtain target-specific App Store provisioning profiles and validate the
  embedded Watch signature.
- [ ] Capture each platform screenshot from the matching signed or Release
  binary at the dimensions in the platform manifest; record hashes and visual
  approval.
- [ ] Complete platform QA. Generic compilation and source inspection are not
  simulator, Apple TV, Apple Vision Pro, Apple Watch, or signed-device evidence.
  App Attest, APNs, Focus, Silent Mode, remote-focus, and background-delivery
  checks apply to the iPhone/iPad notification path only.
- [ ] Complete the Wolfx rights gate in
  `../content-rights-evidence.md`: obtain the exact platform, storage, relay,
  territory, attribution, restriction, duration, and termination permission,
  plus either Wolfx authority over every underlying feed or every separately
  required source permission.
- [ ] Complete current Age Rating, App Privacy, Export Compliance, Content
  Rights, availability, and accountable App Review contact fields.
- [ ] Update the public privacy policy to name Apple TV, Apple Watch, and Apple
  Vision Pro accurately. Apple requires a separate Apple TV Privacy Policy text
  field for tvOS; review the draft in
  `tvos/en-US/apple-tv-privacy-policy-draft.txt`, remove its draft marker only
  after legal/release-owner approval, and keep it consistent with the published
  policy. See Apple's
  [App information reference](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information).
- [ ] For visionOS, assess the final experience and set the required App Motion
  answer. Source inspection suggests a windowed interface with no virtual-camera
  movement, but only final-platform QA can authorize the portal answer.
- [ ] Follow `../app-store-connect-portal-audit-2026-08-19.md` without deleting
  or repurposing existing drafts.

Apple's current field limits are 4,000 characters for descriptions, 170
characters for promotional text, and 100 bytes for keywords. The source files
are checked against those limits before handoff. See
[Platform version information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/).
