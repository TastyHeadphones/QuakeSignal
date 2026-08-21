# Apple platform targets

QuakeSignal has four shared Xcode schemes generated from `project.yml`:

| Scheme | Experience | Background alert registration |
| --- | --- | --- |
| `QuakeSignal` | Full iPhone/iPad app; the same target also supports Mac Catalyst | iPhone/iPad only. Catalyst and an iOS app running on Mac are foreground-only because App Attest is unavailable on Mac. |
| `QuakeSignalVision` | Full native visionOS app | No. Apple does not list Push Notifications or Time Sensitive Notifications as supported visionOS provisioning capabilities, so Vision is foreground-only. |
| `QuakeSignalTV` | Focus-friendly foreground earthquake dashboard | No APNs, App Attest, or background work. |
| `QuakeSignalWatch` | Compact foreground companion embedded in the iOS app | No independent APNs until the backend has a watch profile, ownership, and deduplication contract. |

The TV and Watch targets share `ForegroundQuakeStore`, `EEWEvent`,
`IntensityScale`, `WolfxClient`, localization files, and color assets. They do
not compile the iOS notification, App Attest, or device-registration modules.
The Watch target bundles only the two reviewed short custom sounds and mirrors
the iPhone's selected sound with WatchConnectivity; this preference bridge is
not an earthquake-event or background-notification route.

## Generate and verify

Install the iOS, tvOS, watchOS, and visionOS platform components for the active
Xcode before running the full matrix. The iOS scheme embeds the Watch app, so
the watchOS component is also required when building or testing that scheme.

For a release-frozen regeneration, first close Xcode and use the exact XcodeGen
2.46.0 GitHub release archive pinned by `.github/workflows/ios.yml` (archive
SHA-256 `4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806`).
Do not substitute an arbitrary package-manager binary that merely reports the
same version. Xcode 26.6 can rewrite an open Watch scheme immediately after the
generator exits, so keep Xcode closed until the generated project and schemes
have passed the repository diff gate. The command below assumes that pinned
binary is first in `PATH`.

```sh
cd ios
xcodegen generate --spec project.yml

xcodebuild -project QuakeSignal.xcodeproj -scheme QuakeSignal \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO test

xcodebuild -project QuakeSignal.xcodeproj -scheme QuakeSignal \
  -destination 'generic/platform=macOS,variant=Mac Catalyst' \
  CODE_SIGNING_ALLOWED=NO build

# The unit-test bundle also supports Catalyst. This is a useful logic-test
# destination when a development Mac does not have the watchOS runtime needed
# by the embedded-watch iOS scheme.
xcodebuild -project QuakeSignal.xcodeproj -scheme QuakeSignal \
  -destination 'platform=macOS,arch=arm64,variant=Mac Catalyst' \
  CODE_SIGNING_ALLOWED=NO test

xcodebuild -project QuakeSignal.xcodeproj -scheme QuakeSignalVision \
  -destination 'generic/platform=visionOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -project QuakeSignal.xcodeproj -scheme QuakeSignalTV \
  -destination 'generic/platform=tvOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -project QuakeSignal.xcodeproj -scheme QuakeSignalWatch \
  -destination 'generic/platform=watchOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Use an installed simulator name instead of `iPhone 17 Pro` when that runtime is
not present. Action-time inspection on 2026-08-22 found no configured Xcode
Cloud workflow, and this release forbids local Xcode. The current App Store
route is therefore the protected GitHub archive workflow, pinned to one frozen
source commit. It uses the target-scoped `QUAKESIGNAL_IOS_PROFILE_NAME`,
`QUAKESIGNAL_CATALYST_PROFILE_NAME`, `QUAKESIGNAL_VISION_PROFILE_NAME`,
`QUAKESIGNAL_TV_PROFILE_NAME`, and `QUAKESIGNAL_WATCH_PROFILE_NAME` values to
prevent a host profile from signing the wrong target.

The coordinated automatic-signing Xcode Cloud specification remains a future
alternative. If it is later onboarded by an authorized owner, leave all manual
profile-name variables absent there and re-audit its server-side workflow.

TV, Watch, and Vision intentionally carry no alert entitlements. Catalyst uses
`QuakeSignal-Catalyst.entitlements` for App Sandbox, outbound network access,
and foreground location only; Vision's referenced entitlement files are empty.
Only the iPhone/iPad target uses the protected App Attest + APNs registration
path.

## Distribution assets

The platform catalogs faithfully adapt the checked-in QuakeSignal artwork
without introducing a new mark:

- Watch uses the official 1024×1024 icon as a single-size watchOS app icon.
- Vision uses a two-layer 1024×1024 stack: the existing diagonal blue field
  behind the existing signal glyph.
- TV uses two-layer 400×240 and 1280×768 app icons plus standard and wide
  Top Shelf images at both required scales.

The catalog JSON passes `actool --print-asset-tag-combinations`, every image's
dimensions and alpha requirements have been checked, and the composited layers
have been visually compared with the official icon. A full `actool` compile and
platform screenshot pass still require the tvOS, watchOS, and visionOS runtime
components; Xcode stops at asset thinning when those runtimes are absent.
