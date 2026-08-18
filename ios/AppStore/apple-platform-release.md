# Coordinated Apple platform release 1.1 (8)

This runbook covers the protected archive automation for the native Apple
targets. It prepares uploads; it does not authorize an App Store submission or
public release.

| Store surface | Scheme | Bundle ID | Upload lane |
| --- | --- | --- | --- |
| iPhone and iPad | `QuakeSignal` | `com.quakesignal.app` | `.github/workflows/ios.yml` |
| Apple Watch companion | `QuakeSignalWatch` | `com.quakesignal.app.watchkitapp` | Embedded in the `QuakeSignal` iOS IPA |
| Apple TV | `QuakeSignalTV` | `com.quakesignal.app` | `.github/workflows/apple-platforms.yml`, select `tvos` |
| Apple Vision Pro | `QuakeSignalVision` | `com.quakesignal.app` | `.github/workflows/apple-platforms.yml`, select `visionos` |

The native TV and Vision uploads use the existing iOS App Store Connect record
(Apple ID `6800642443`) and matching bundle ID. Watch metadata and screenshots
belong to that iOS record; there is no separate Watch IPA. The Tauri Mac app
uses its existing separate record and `.github/workflows/desktop-release.yml`.
Use [`platforms/`](./platforms/) for reviewed copy and screenshot plans. The
read-only portal contradictions and non-destructive action order are recorded in
[`app-store-connect-portal-audit-2026-08-19.md`](./app-store-connect-portal-audit-2026-08-19.md).

## Version contract

All four Xcode targets use marketing version `1.1` and coordinated integer
build `8`. The checked-in XcodeGen project, generated project, four Info.plists,
workflow defaults, and Worker App Attest allow-list must agree before any
signing secret is materialized. Never reuse build `7` after adding the embedded
Watch product.

Run the offline contract before requesting a protected archive:

```sh
node --test .github/scripts/verify-ios-release-contract.test.mjs
node .github/scripts/verify-ios-release-contract.mjs --build-number 8
```

## Protected environment configuration

The existing protected GitHub environment `ios-app-store-release` must contain
all selected signing inputs. An absent or empty value fails the job before
certificate/profile import.

Shared certificate and upload configuration:

- Secret `IOS_APP_STORE_CERTIFICATE`
- Secret `IOS_APP_STORE_CERTIFICATE_PASSWORD`
- Secret `APP_STORE_CONNECT_API_KEY` (required only for upload)
- Variable `APP_STORE_CONNECT_API_KEY_ID` (required only for upload)
- Variable `APP_STORE_CONNECT_API_ISSUER` (required only for upload)
- Variable `CLOUDFLARE_WORKER_URL`, exactly
  `https://quakesignal-api.hopeso.workers.dev`

Target profiles:

- Secret `IOS_APP_STORE_PROVISIONING_PROFILE` and variable
  `IOS_APP_STORE_PROFILE_NAME`
- Secret `WATCHOS_APP_STORE_PROVISIONING_PROFILE` and variable
  `WATCHOS_APP_STORE_PROFILE_NAME`
- Secret `TVOS_APP_STORE_PROVISIONING_PROFILE` and variable
  `TVOS_APP_STORE_PROFILE_NAME`
- Secret `VISIONOS_APP_STORE_PROVISIONING_PROFILE` and variable
  `VISIONOS_APP_STORE_PROFILE_NAME`

The Watch profile must authorize `com.quakesignal.app.watchkitapp`; the host,
TV, and Vision profiles authorize `com.quakesignal.app` for their respective
platforms. The signed verifier checks the team, profile name, application ID,
platform, build number, and capability policy in both the archive and exported
IPA. TV and Watch are deliberately foreground-only and must not acquire APS,
App Attest, or Time Sensitive Notification entitlements. iOS and Vision require
their reviewed production alert entitlements.

## CI and archive commands

Ordinary push and pull-request CI performs credential-free generic Release
builds for all schemes with `CODE_SIGNING_ALLOWED=NO`. Hosted runners install
the selected Xcode platform component first because tvOS, watchOS, and visionOS
components are not guaranteed to be preinstalled.

The release workflows are manual-only for signed artifacts. Their signing jobs
also require protected `main`, the protected environment, exactly one of
`archive_only` or `upload_to_testflight`, and the shared non-cancelling Worker
policy lock. Do not dispatch these commands until the Worker build-8 policy and
profiles are approved:

```sh
gh workflow run ios.yml --ref main \
  -f archive_only=true \
  -f upload_to_testflight=false \
  -f build_number=8

gh workflow run apple-platforms.yml --ref main \
  -f platform=tvos \
  -f archive_only=true \
  -f upload_to_testflight=false \
  -f build_number=8

gh workflow run apple-platforms.yml --ref main \
  -f platform=visionos \
  -f archive_only=true \
  -f upload_to_testflight=false \
  -f build_number=8
```

After the signed archives, platform QA, metadata, screenshots, and legal gates
pass, repeat each run with `archive_only=false` and
`upload_to_testflight=true`. Archive-only runs never contact App Store Connect.

## Distribution blockers outside workflow automation

- Create and review store-complete icon assets: layered Vision icon, Apple TV
  brand/top-shelf assets, and Watch icon set. Do not manufacture these by
  blindly reusing the flat iOS icon.
- Capture and hash screenshots from the frozen build-8 binaries at Apple’s
  accepted sizes.
- Exercise iOS/Vision notifications and App Attest on physical hardware or
  TestFlight. Simulator/generic builds are not evidence for APNs, App Attest,
  background delivery, Focus, Silent Mode, or alert sounds.
- Exercise TV focus/remote behavior and Watch foreground behavior on their
  actual platforms.
- Complete content-rights, privacy, export, age-rating, review-contact, and
  platform-metadata approvals before submission.

The current App Store Connect audit found empty tvOS `1.0` and visionOS `1.0`
drafts in Apple ID `6800642443`. Reuse those drafts and change their editable
version number to `1.1` only after the corresponding build-8 release evidence
is frozen. Do not delete the drafts or create duplicate platforms. The same
record also contains a macOS draft that must not receive the separate Tauri
Mac app (`com.quakesignal.desktop`); leave it untouched and use Apple ID
`6800642853` for Mac 1.1.0.

The existing iPhone/iPad screenshot provenance records build 7. Preserve it as
historical evidence and capture a new build-8 set. tvOS requires a new
`1920 × 1080` set, visionOS requires `3840 × 2160`, and the planned Watch set
uses `410 × 502` consistently. No native-platform screenshot has been claimed
as captured or approved by the offline metadata kit.
