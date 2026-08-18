# Native-platform screenshot checklist — 1.1 (8)

Apple requires one to ten opaque JPEG/JPG/PNG screenshots per supported device
family. The current accepted sizes are documented in Apple's
[Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/).
This checklist creates no approval by itself.

## Common capture gate

- [ ] Freeze a full 40-character source commit and verify all four schemes are
  version `1.1`, build `8`.
- [ ] Capture a source-frozen Debug Simulator candidate with
  `ios/ScreenshotAutomation/capture-platform-screenshot.sh`. This gated fixture
  cannot run in InternalQA, Release, or a physical-device build; never describe
  its output as a signed Release or build-8 binary capture.
- [ ] Record the matching signed Release artifact SHA-256 separately when it is
  available. Before upload, obtain named visual approval and complete any
  signed-Release parity comparison required by the platform runbook.
- [ ] Install the exact platform runtime or use physical hardware. Record Xcode,
  OS/runtime, device model, device identifier where appropriate, capture time,
  and reviewer. For automated Simulator candidates, verify
  `candidate-metadata.json` contains the harness-recorded
  `selectedSimulator.runtimeIdentifier`, `deviceTypeIdentifier`, and
  `deviceModel`; the full runtime inventory log alone is not capture evidence.
- [ ] Use English (U.S.) only until localized names and listings are approved.
- [ ] Use a benign finalized historical report. Never stage an active warning,
  a training/test notification, a system permission prompt, an exact user
  location, an APNs token, App Attest material, or personal data.
- [ ] Capture the actual platform UI; do not stretch iOS screenshots or create
  marketing composites that imply unsupported functionality.
- [ ] Confirm every file is opaque, in JPEG/JPG/PNG, at the exact selected
  dimensions, and visually free of clipping, focus, localization, or safe-area
  defects.
- [ ] Replace each manifest's `null` evidence and hash values only from the
  completed capture. Keep automation outputs outside the repository and change
  a manifest's status to approved only after named human review and required
  Release-parity evidence.

## Apple TV

- [ ] Capture all three planned frames at exactly `1920 × 1080` landscape.
  (`3840 × 2160` is also accepted, but do not mix sizes in this release set.)
- [ ] Verify focus appearance and Siri Remote navigation on Apple TV hardware
  or the matching simulator runtime.
- [ ] Ensure the visible copy says foreground only and no screenshot implies a
  background alert, notification, alert sound, App Attest, or location feature.
- [ ] Update `tvos/screenshot-manifest-v1.1-build8.json` with evidence and
  SHA-256 values.

## Apple Vision Pro

- [ ] Capture all five planned frames at exactly `3840 × 2160` landscape.
- [ ] Verify the full window is legible and no private surroundings, account
  identifiers, or precise location are visible.
- [ ] Complete Apple Vision Pro QA and approve the required App Motion answer;
  a screenshot does not prove notification or motion behavior.
- [ ] Update `visionos/screenshot-manifest-v1.1-build8.json` with evidence and
  SHA-256 values.

## Apple Watch

- [ ] Use exactly `410 × 502` portrait for this planned set, from Apple Watch
  Ultra 2 / Ultra. If the release owner selects another accepted class, update
  every frame and every localization before capture; Apple requires one
  consistent Watch size across all localizations.
- [ ] Verify the Watch app is installed from the signed iOS host, refreshes when
  opened, scrolls correctly, and opens event details on a paired Apple Watch.
- [ ] Ensure the screenshots make no independent background-alert claim.
- [ ] Update `watchos/screenshot-manifest-v1.1-build8.json` with host/watch
  evidence and SHA-256 values.

## Existing iOS/iPad screenshot set is not build-8 evidence

The existing `../../screenshot-manifest-v1.1.json`,
`../../screenshot-provenance-v1.1.json`, and 30 images truthfully record a
build-7 simulator capture. Do not relabel or upload them as build-8 screenshots.
Recapture the iPhone and iPad sets after the build-8 source is frozen, then
create new truthful hashes and provenance. The current
`../../screenshot-manifest-v1.1-build8.template.json` is planning data only;
there is no approved build-8 manifest or capture directory yet.

The build-8 recapture sequence is:

1. Freeze the full source commit, generate the build-8 project, and run the iOS
   tests and unsigned public Release build.
2. Launch the source-matching Debug Simulator build with both screenshot gates
   (`--quakesignal-screenshot-automation` and
   `QUAKESIGNAL_SCREENSHOT_AUTOMATION=1`) so the finalized historical fixture
   is deterministic and startup network/permission activity is disabled.
3. Recreate all five planned frames for both the selected iPhone class and the
   13-inch iPad class in each approved locale. Write them only to the future
   `screenshots-v1.1-build8/` set; do not overwrite or relabel build-7 files.
4. Create build-8 manifest and provenance records from the template, exact
   source commit, native device/runtime evidence, and new SHA-256 hashes.
5. Obtain named visual review and any signed-Release parity evidence required
   by the release runbook before marking or uploading an asset.

No current iPhone, iPad, Apple TV, Apple Vision Pro, or Apple Watch screenshot
asset is approved for a build-8 App Store upload.
