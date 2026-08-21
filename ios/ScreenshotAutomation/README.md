# Apple screenshot automation harness

This directory contains the source-addressed Debug capture harnesses for all
five Apple listing platforms. They capture real Simulator output or directly
render the exact live Mac Catalyst UIWindow hierarchy; they do not fabricate,
decorate, commit, upload, or approve a frame.
The checked-in plans require these exact English (U.S.) inventories:

| Platform | Planned frames | Native pixels |
| --- | ---: | --- |
| iPhone 6.5-inch | 5: home, reports, map, guide, alert sound | `1242x2688` |
| iPad 13-inch | 5: home, reports, map, guide, alert sound | `2064x2752` |
| Apple TV | 3: dashboard, recent reports, event detail | `1920x1080` |
| Apple Vision Pro | 5: home, reports, map, guide, alert sound | `3840x2160` |
| Apple Watch | 3: headline, recent reports, event detail | `410x502` |
| Mac Catalyst | 5: home, reports, map, guide, alert sound | `2560x1600` |

`ios-screenshot-plan.rb`, `platform-screenshot-plan.rb`, and
`maccatalyst-screenshot-plan.rb` validate the 10/3/5/3/5 inventories directly
against their platform manifests. A removed, reordered, renamed,
pre-approved, pre-hashed, wrong-size, or unknown frame fails before capture.

The ten exact iOS/iPadOS selectors are:

```text
ios-iphone-6.5-home
ios-iphone-6.5-reports
ios-iphone-6.5-map
ios-iphone-6.5-guide
ios-iphone-6.5-alert-preferences
ios-ipad-13-home
ios-ipad-13-reports
ios-ipad-13-map
ios-ipad-13-guide
ios-ipad-13-alert-preferences
```

The five exact Mac Catalyst selectors are `maccatalyst-home`,
`maccatalyst-reports`, `maccatalyst-map`, `maccatalyst-guide`, and
`maccatalyst-alert-preferences`.

## Fail-closed app routing

The app-side fixture and frame routes are available only to the gated Debug
capture configuration: Simulator builds for iOS/iPadOS, tvOS, watchOS, and
visionOS, or the native Mac Catalyst capture process. Activation requires all
of the following to agree:

- `--quakesignal-screenshot-automation`
- `QUAKESIGNAL_SCREENSHOT_AUTOMATION=1`
- `--quakesignal-screenshot-frame=<reviewed-selector>`
- `QUAKESIGNAL_SCREENSHOT_FRAME=<the-same-reviewed-selector>`

The fixture supplies fixed finalized historical reports, bypasses onboarding,
and prevents startup earthquake-feed, notification, APNs, App Attest, and
location activity. Ordinary Debug launches, physical devices, InternalQA, and
Release builds remain on production behavior. The visionOS selectors choose
the real Home, Reports, Map, Guide, and Alert Sound destinations. TV and Watch
use their real report rows and event-detail views; the recent-report selectors
move genuine focus/scroll state instead of drawing a marketing composite.
Mac Catalyst image publication has an additional independent gate:
`--quakesignal-catalyst-hierarchy-capture` must appear exactly once and
`QUAKESIGNAL_CATALYST_HIERARCHY_CAPTURE` must equal `1`.

## Native dimensions

Apple's current screenshot specification accepts:

- iPhone: this plan selects the `1242x2688` 6.5-inch portrait class.
- iPad: this plan selects the `2064x2752` 13-inch portrait class.
- Apple TV: `1920x1080` or `3840x2160`; this plan selects `1920x1080`.
- Apple Vision Pro: exactly `3840x2160`.
- Apple Watch: several device classes, but this plan selects exactly `410x502`
  from Apple Watch Ultra 2 / Ultra. The harness no longer falls back to a
  different Watch class because that would contradict every planned frame.
- Mac Catalyst: this plan directly rasterizes the exact live `1280x800`-point
  UIKit window hierarchy at 2 pixels per point into `2560x1600`; the runner's
  actual display scale is recorded separately and no resize or crop is allowed.

Source: [Apple screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/).

## Capture execution

Use an already-installed runtime whenever possible. If a required runtime is
absent, the harness exits before building and names the missing platform; it
never downloads a runtime, changes resolution, or fabricates an image. An
operator who deliberately chooses to install a missing component can use
Xcode Settings or Apple's `xcodebuild -downloadPlatform` command separately.

Start from a clean, source-frozen checkout and use the checked-in generated
project. If the project graph intentionally changed, regenerate and review it
before freezing the capture commit; do not regenerate as part of capture.
Use a new external worktree or clone that has never been opened interactively
in Xcode: ignored per-user `xcuserdata` is deliberately rejected as an
unarchived working input, even when ordinary Git status reports a clean tree.
Every set command refuses a destination inside the repository and publishes a
new output directory only after the full planned inventory validates.

For the exact ten-frame iOS/iPadOS set, create only the destination parent and
let the harness build once in fresh temporary DerivedData, use exactly one
iPhone 11 Pro Max plus one iPad Pro 13-inch (M4), and capture all ten routes:

```sh
capture_parent="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/QuakeSignalScreenshotCandidates"
mkdir -p "$capture_parent"
bash ios/ScreenshotAutomation/capture-ios-screenshot-set.sh \
  "$capture_parent/ios-ipados"
```

The iOS build is unsigned and credential-free. It materializes the exact Git
commit into a temporary build source, removes only the two reviewed main-target
Watch embedding/dependency references, retains the Watch target definition,
and binds the built `QuakeSignal.app`, build settings/log/list, retained
`.xcresult.zip`, installed app container, launch gates, native PNG, JPEG
transformation, semantic evidence, and source bytes into each frame record.
The prepared source also contains exactly three empty `0755` workspace
directories at `project.xcworkspace/xcshareddata/swiftpm/configuration` and its
two parents. Xcode 26.6 otherwise creates that empty chain during project
listing and makes an unchanged source tree appear to drift. Binding the chain
in the initial materialized-source manifest keeps project listing, building,
and build-settings inspection stable; a missing path, different mode, symlink,
file, or any other entry beneath `xcshareddata` still fails closed.
The temporary source and build outputs never become release inputs.
For every selector, the accepted package retains separate
`semantic-evidence/<selector>-raw.json` and
`semantic-evidence/<selector>-final.json` reports. When the one allowed
semantic retry is used, it also retains the rejected first attempt as
`semantic-rejections/<selector>-attempt-1.json` and the exact paired
`semantic-rejections/<selector>-attempt-1.png` raster.

Mac Catalyst uses a distinct GitHub-hosted macOS job in
`.github/workflows/apple-platform-screenshots.yml`. The job invokes the same
set harness against one exact clean `GITHUB_SHA`; no signing, Screen Recording,
Accessibility, or App Store Connect credential is supplied:

```sh
capture_parent="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/QuakeSignalScreenshotCandidates"
mkdir -p "$capture_parent"
QUAKESIGNAL_CATALYST_SCREENSHOT_DERIVED_DATA="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/QuakeSignalScreenshotDerived/maccatalyst" \
  bash ios/ScreenshotAutomation/capture-maccatalyst-screenshot-set.sh \
    "$capture_parent/maccatalyst"
```

The host first observes exactly one visible layer-zero window for the launched
PID and exact 1280x800 frame. It then atomically publishes a schema-exact
request bound to PID, Core Graphics window ID, reviewed selector, and a fresh
64-hex nonce. On the main actor, the app requires that its attached UIWindow is
visible, key, foreground-active, and still exactly 1280x800, then uses
`UIGraphicsImageRenderer` with scale 2 and
`UIView.drawHierarchy(afterScreenUpdates: true)`. A false draw result, a pixel
result other than 2560x1600, request mutation, or geometry/visibility drift
publishes no successful response. Core Graphics must observe the same unique
PID/window/frame afterward. The retained response distinguishes the runner's
actual `sourceDisplayScale` from `rasterizationScale: 2`, identifies
`UIKit.UIView.drawHierarchy` and `live-catalyst-uiwindow-hierarchy`, and records
that no resize occurred. The raw renderer PNG, black-alpha-composited final PNG,
request, response, before/after observations, and their hashes all remain in
the explicitly unapproved package.

Each accepted Catalyst semantic record binds its OCR and pixel metrics to the
exact final PNG SHA-256 and image format. If the single allowed retry is used,
the package also retains and hash-binds the rejected JSON/PNG pair at
`semantic-rejections/<selector>-attempt-1.{json,png}`; the aggregate rejects a
missing pair, a stale semantic record, or swapped image bytes.

For tvOS, visionOS, and watchOS, capture into a new directory outside the
repository, with temporary data and the reusable unsigned build cache on a
disk with adequate space:

```sh
capture_parent="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/QuakeSignalScreenshotCandidates"
mkdir -p "$capture_parent"
QUAKESIGNAL_SCREENSHOT_DERIVED_DATA="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/QuakeSignalScreenshotDerived/tvos" \
  ios/ScreenshotAutomation/capture-platform-screenshot-set.sh \
    tvos "$capture_parent/tvos"
```

Run the same set command with `visionos` or `watchos` and a distinct, new
output directory. The command refuses to overwrite an artifact directory and
publishes it atomically only after every planned frame validates. Its layout is:

```text
en-US/<all planned native PNGs>
frame-capture-evidence/<one schema-1 sidecar per frame>.json
capture-provenance.json
```

The aggregate builder rejects extra files, symlinks, unknown evidence fields,
and any non-empty preexisting approval/evidence field in the checked-in plan.

Every frame capture creates a disposable simulator, builds and installs the
native target without signing credentials, launches the gated fixture,
captures an untouched PNG, checks native dimensions and opacity, hashes it,
and deletes the simulator. `QUAKESIGNAL_SCREENSHOT_DERIVED_DATA` may point to
an absolute directory outside the repository so later frames reuse unsigned
build products. `QUAKESIGNAL_SCREENSHOT_KEEP_SIMULATOR=1` is only for manual
visual debugging.

For a diagnostic single frame, call the lower-level command with an exact
selector and absolute PNG path:

```sh
debug_parent="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/QuakeSignalScreenshotDebug"
mkdir -p "$debug_parent"
ios/ScreenshotAutomation/capture-platform-screenshot.sh \
  tvos tvos-event-detail "$debug_parent/tv-detail.png"
```

The lower-level command writes a sidecar only when
`QUAKESIGNAL_SCREENSHOT_PROVENANCE_OUTPUT` names a new absolute JSON path
outside the repository.

## Vision frame readiness protection

Vision frame readiness is nondeterministic even after the process becomes
launchable. Every exact reviewed selector (`visionos-home`, `visionos-reports`,
`visionos-map`, `visionos-guide`, and `visionos-alert-preferences`) therefore
receives a 25-second bounded initial settle. After native capture, `sips`
creates a temporary BMP copy solely for semantic inspection; the original 4K
PNG is never converted, resized, or modified. The validator samples the
central app-panel region and requires both calibrated luma variance and
meaningful edge structure for every route. The map additionally requires its
reviewed quantized color diversity, saturated pixels, blue/cyan content, and
bright-content-or-edge evidence. A gray launch panel, including one with the
centered blue app logo, fails even when its PNG dimensions and opacity are
valid.

Only semantic status 65 triggers recovery. The rejected raster is quarantined
inside the disposable capture directory, the same exact dual-gated selector
is relaunched, and one further 25-second settle/capture/validation is allowed.
Operational validator, conversion, launch, or path failures never retry. A
second semantic rejection is also quarantined and aborts the atomic set before
provenance or artifact publication.

## Watch foreground protection

For watchOS the harness also creates and boots a disposable paired iPhone
Simulator; no existing personal pair is reused. CoreSimulator may take longer
than watchOS's two-minute return-to-clock interval to service its first
screenshot. While that request is pending, the harness restarts QuakeSignal in
the foreground every 45 seconds with the same dual-gated frame selector. The
screenshot and restart children share a five-minute hard deadline and are both
stopped with bounded TERM-to-KILL cleanup on timeout or interruption.
Before settling or requesting that first screenshot, the initial exact-frame
launch uses the same tracked helper as semantic recovery: at most two launch
attempts with the identical environment-plus-argument selector gates and a
five-second backoff. One transient launch failure may recover; two failures
return operational status 70 before any candidate or provenance can be
published. INT/TERM during either tracked launch or its backoff preserves the
caller trap's 130/143 status and likewise cannot publish an artifact.

Each Watch frame contains the orange foreground-only badge. A temporary BMP
validation copy is inspected in the reviewed frame-specific upper content
band; dashboard/list use a text-sized marker while detail uses a filled banner
with a disjoint density contract. The detail scan includes the full upper 45%
so navigation safe-area changes cannot hide that fixed banner; rejection logs
also report the full-frame orange count for diagnosis. Headline and recent-report
pagers extend through the bottom container safe area so each page matches the
complete visible Watch viewport. Their raster contracts reject next-page content
in the bottom central band. Recent reports allow the early two-fifths of that
band to contain the complete second-row tail, but require the final three-fifths
at the physical screen edge to remain clean; they also require the full orange
foreground label to reach its reviewed rightmost extent. The icon-only refresh
control has a 44-by-44-point accessible hit target so that label retains its
production layout width. Both context labels share that single 44-point header
row beside the control. Report locations use a compact reserved two-line title
so both complete hypocenter names and their status/source/time metadata remain
visible in the first two production rows without entering the final review band.
Event-detail bottom content remains outside those first-page checks. The native
PNG is never converted or modified. A clock-face, wrong-density, clipped-page,
truncated-label, or stale-route capture is rejected.
Because a foreground restart can race an
already-pending CoreSimulator request, one rejected raster is quarantined in
the temporary capture directory and the exact route receives one bounded
capture retry. That semantic recovery reuses the initial launch's shared
two-attempt, five-second-backoff helper, and a successful relaunch keeps the
existing settle before the second and final capture.
Validator argument/selector failures use status 64, semantic pixel
rejections use status 65, and bitmap read/layout failures use status 70. Only
status 65 is eligible for quarantine and retry; every other validator failure
is returned as operational status 70 without relaunch. A second semantic
rejection aborts the complete atomic set without an upload.

Credential-free tests cover the exact plans, build/source binding, aggregate
provenance, atomic interfaces, semantic validation, process supervision,
selector preservation, package sealing, and native-window evidence:

```sh
/usr/bin/ruby ios/ScreenshotAutomation/ios-screenshot-plan.test.rb
/usr/bin/ruby ios/ScreenshotAutomation/ios-screenshot-simulator-lease.test.rb
/usr/bin/ruby ios/ScreenshotAutomation/ios-screenshot-swift-inputs.test.rb
/usr/bin/ruby ios/ScreenshotAutomation/parse-ios-screenshot-build-settings.test.rb
/usr/bin/ruby ios/ScreenshotAutomation/prepare-ios-screenshot-build-source.test.rb
/usr/bin/ruby ios/ScreenshotAutomation/resolve-ios-screenshot-simulator.test.rb
/usr/bin/ruby ios/ScreenshotAutomation/ios-screenshot-build-binding.test.rb
/usr/bin/ruby ios/ScreenshotAutomation/assemble-ios-screenshot-provenance.test.rb
/usr/bin/ruby ios/ScreenshotAutomation/seal-screenshot-capture-package.test.rb
/usr/bin/ruby ios/ScreenshotAutomation/safe-zip-tree.test.rb
bash ios/ScreenshotAutomation/ios-screenshot-capture-interface.test.sh
bash ios/ScreenshotAutomation/ios-screenshot-content-validator.test.sh
bash ios/ScreenshotAutomation/screenshot-process-guard.test.sh
/usr/bin/ruby ios/ScreenshotAutomation/maccatalyst-screenshot-plan.test.rb
/usr/bin/ruby ios/ScreenshotAutomation/assemble-maccatalyst-screenshot-provenance.test.rb
bash ios/ScreenshotAutomation/maccatalyst-capture-interface.test.sh
bash ios/ScreenshotAutomation/maccatalyst-capture-retry-policy.test.sh
bash ios/ScreenshotAutomation/maccatalyst-content-validator.test.sh
bash ios/ScreenshotAutomation/maccatalyst-process-guard.test.sh
/usr/bin/ruby ios/ScreenshotAutomation/platform-screenshot-plan.test.rb
/usr/bin/ruby ios/ScreenshotAutomation/assemble-platform-screenshot-provenance.test.rb
bash ios/ScreenshotAutomation/capture-platform-screenshot-interface.test.sh
bash ios/ScreenshotAutomation/watch-capture-guard.test.sh
/usr/bin/ruby ios/ScreenshotAutomation/validate-watch-foreground-badge.test.rb
bash ios/ScreenshotAutomation/vision-map-capture-guard.test.sh
/usr/bin/ruby ios/ScreenshotAutomation/validate-vision-map-content.test.rb
```

These tests place temporary fixtures under `QUAKESIGNAL_TEST_TEMP_ROOT` when
set, then `RUNNER_TEMP`, `TMPDIR`, or the platform temporary directory. CI sets
the first three names to the runner-owned temporary directory, so no checkout
or machine-specific volume path is used for test scratch data.

## Provenance and CI artifacts

Each `capture-provenance.json` binds the exact plan-manifest hash and every
planned filename to its original capture, dimensions, capture time, runtime or
host, device/window identity, source/build evidence, and per-frame hashes. Its
platform-specific schema is always explicitly unapproved, with
`uploadApproved: false`, `reviewer: null`, and no signed Release evidence.

`.github/workflows/apple-platform-screenshots.yml` runs credential-free jobs
for iOS/iPadOS, tvOS, visionOS, watchOS, and the distinct Mac Catalyst live
hierarchy path. It captures the exact 10/3/5/3/5 sets, verifies the first atomic
seal, temporarily removes only that
manifest, adds `candidate-metadata.json` plus the runtime inventory, creates a
new final seal, and validates it. It then creates a conventional
`ditto -c -k --norsrc --keepParent` ZIP outside the raw capture root and proves
the ZIP file inventory and bytes equal the sealed directory before uploading
both together. No later step writes into the raw root. The workflow also proves
that checked-out `HEAD` equals `GITHUB_SHA` and that the repository has zero
tracked or untracked changes immediately before and after capture. Artifact
names remain explicitly `UNAPPROVED`; no step has signing or App Store Connect
credentials.

## Sealed archive and release-set handoff

Treat a successful set directory as immutable. If an operator must attach
metadata, delete only its existing `capture-package-manifest.json`, add all
metadata first, then run the seal helper once more. After that final seal, make
no further writes in the raw root. Create an independent conventional archive:

```sh
/usr/bin/ditto -c -k --norsrc --keepParent \
  "$IOS_CAPTURE_ROOT" "$IOS_CAPTURE_ZIP"
```

Use a distinct raw-root/ZIP pair for each of `ios-ipados`, `tvos`, `watchos`,
`visionos`, and `maccatalyst`, all from the same full source commit. The final
assembler requires all five pairs, all 26 byte-distinct frames, an output at
the canonical source-addressed repository path, and a separate new index
candidate outside the repository:

```sh
/usr/bin/ruby .github/scripts/assemble-apple-screenshot-release-set.rb \
  "$SOURCE_COMMIT" \
  "$PWD/ios/AppStore/screenshot-release-sets-v1.1-build8/$SOURCE_COMMIT" \
  "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/QuakeSignalScreenshotCandidates/index-candidate.json" \
  "$IOS_CAPTURE_ROOT" "$IOS_CAPTURE_ZIP" \
  "$TVOS_CAPTURE_ROOT" "$TVOS_CAPTURE_ZIP" \
  "$WATCHOS_CAPTURE_ROOT" "$WATCHOS_CAPTURE_ZIP" \
  "$VISIONOS_CAPTURE_ROOT" "$VISIONOS_CAPTURE_ZIP" \
  "$MACCATALYST_CAPTURE_ROOT" "$MACCATALYST_CAPTURE_ZIP"
```

The assembler creates only an unapproved release-set candidate. It never
overwrites the checked-in index and does not supply named review or signed
Release parity evidence.

A named reviewer must compare every candidate to the source-frozen UI and
approve it. Where the release runbook requires binary parity evidence, compare
the reviewed candidate with the signed Release artifact before metadata
upload. A Debug-only fixture must never be described as a signed Release or
build-8 binary capture.
