# Native platform screenshot harness

This harness captures real Simulator output for the tvOS, watchOS, and
visionOS targets. It does not generate, resize, decorate, commit, upload, or
approve screenshots. The checked-in plans require these exact English (U.S.)
inventories:

| Platform | Planned frames | Native pixels |
| --- | ---: | --- |
| Apple TV | 3: dashboard, recent reports, event detail | `1920x1080` |
| Apple Vision Pro | 5: home, reports, map, guide, alert sound | `3840x2160` |
| Apple Watch | 3: headline, recent reports, event detail | `410x502` |

`platform-screenshot-plan.rb` validates those 3/5/3 inventories directly
against the platform manifests. A removed, reordered, renamed, pre-approved,
pre-hashed, wrong-size, or unknown frame fails before Simulator launch.

## Fail-closed app routing

The app-side fixture and frame routes are available only in a Debug Simulator
build. Activation requires all of the following to agree:

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

## Native dimensions

Apple's current screenshot specification accepts:

- Apple TV: `1920x1080` or `3840x2160`; this plan selects `1920x1080`.
- Apple Vision Pro: exactly `3840x2160`.
- Apple Watch: several device classes, but this plan selects exactly `410x502`
  from Apple Watch Ultra 2 / Ultra. The harness no longer falls back to a
  different Watch class because that would contradict every planned frame.

Source: [Apple screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/).

## Local capture

Use an already-installed runtime whenever possible. If a required runtime is
absent, the harness exits before building and names the missing platform; it
never downloads a runtime, changes resolution, or fabricates an image. An
operator who deliberately chooses to install a missing component can use
Xcode Settings or Apple's `xcodebuild -downloadPlatform` command separately.

Start from a clean, source-frozen checkout and use the checked-in generated
project. If the project graph intentionally changed, regenerate and review it
before freezing the capture commit; do not regenerate as part of capture.
Capture into a new directory outside the repository, with temporary data and
the reusable unsigned build cache on a disk with adequate space:

```sh
TMPDIR=/Volumes/RC20 \
QUAKESIGNAL_SCREENSHOT_DERIVED_DATA=/Volumes/RC20/QuakeSignalScreenshotDerived/tvos \
  ios/ScreenshotAutomation/capture-platform-screenshot-set.sh \
    tvos /Volumes/RC20/QuakeSignalScreenshotCandidates/tvos
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
ios/ScreenshotAutomation/capture-platform-screenshot.sh \
  tvos tvos-event-detail /Volumes/RC20/QuakeSignalScreenshotDebug/tv-detail.png
```

The lower-level command writes a sidecar only when
`QUAKESIGNAL_SCREENSHOT_PROVENANCE_OUTPUT` names a new absolute JSON path
outside the repository.

## Vision map readiness protection

MapKit readiness is nondeterministic even after the Vision process becomes
launchable. The exact `visionos-map` selector therefore receives a 25-second
bounded initial settle. After native capture, `sips` creates a temporary BMP
copy solely for semantic inspection; the original 4K PNG is never converted,
resized, or modified. The validator samples the central app-panel region and
requires all of the reviewed map signals: luma variance, quantized color
diversity, saturated pixels, and blue/cyan map content, plus bright content or
meaningful edges. A uniform gray launch placeholder fails even though its PNG
dimensions and opacity are valid.

Only semantic status 65 triggers recovery. The rejected raster is quarantined
inside the disposable capture directory, the exact dual-gated `visionos-map`
route is relaunched, and one further 25-second settle/capture/validation is
allowed. Operational validator, conversion, launch, or path failures never
retry. A second semantic rejection is also quarantined and aborts the atomic
set before provenance or artifact publication.

## Watch foreground protection

For watchOS the harness also creates and boots a disposable paired iPhone
Simulator; no existing personal pair is reused. CoreSimulator may take longer
than watchOS's two-minute return-to-clock interval to service its first
screenshot. While that request is pending, the harness restarts QuakeSignal in
the foreground every 45 seconds with the same dual-gated frame selector. The
screenshot and restart children share a five-minute hard deadline and are both
stopped with bounded TERM-to-KILL cleanup on timeout or interruption.

Each Watch frame contains the orange foreground-only badge. A temporary BMP
validation copy is inspected in the reviewed frame-specific upper content
band; dashboard/list use a text-sized marker while detail uses a filled banner
with a disjoint density contract. The detail scan includes the full upper 45%
so navigation safe-area changes cannot hide that fixed banner; rejection logs
also report the full-frame orange count for diagnosis. The native PNG is never
converted or modified. A clock-face, wrong-density, or stale-route capture is rejected.
Because a foreground restart can race an
already-pending CoreSimulator request, one rejected raster is quarantined in
the temporary capture directory and the exact route receives one bounded
retry. A second rejection aborts the complete atomic set without an upload.

Credential-free tests cover the exact plan, aggregate provenance, Watch
process supervision, selector preservation, and badge validation:

```sh
/usr/bin/ruby ios/ScreenshotAutomation/platform-screenshot-plan.test.rb
/usr/bin/ruby ios/ScreenshotAutomation/assemble-platform-screenshot-provenance.test.rb
bash ios/ScreenshotAutomation/capture-platform-screenshot-interface.test.sh
bash ios/ScreenshotAutomation/watch-capture-guard.test.sh
/usr/bin/ruby ios/ScreenshotAutomation/validate-watch-foreground-badge.test.rb
bash ios/ScreenshotAutomation/vision-map-capture-guard.test.sh
/usr/bin/ruby ios/ScreenshotAutomation/validate-vision-map-content.test.rb
```

## Provenance and CI artifacts

`capture-provenance.json` is schema-2 aggregate evidence. It binds the exact
plan-manifest hash and every planned filename to the untouched PNG hash,
dimensions, capture time, exact runtime, device type/model, disposable UDID,
and per-frame evidence hash. It is always marked
`unapproved-debug-simulator-capture-set-evidence`, with
`uploadApproved: false`, `reviewer: null`, and no signed Release evidence.

`.github/workflows/apple-platform-screenshots.yml` runs one credential-free
matrix job per platform, captures all 3/5/3 frames, verifies the aggregate,
and adds schema-3 `candidate-metadata.json` plus a runtime inventory. It proves
that checked-out `HEAD` equals `GITHUB_SHA` and that the repository has zero
tracked or untracked changes immediately before and after the complete set
capture. The short-lived artifact name remains explicitly `UNAPPROVED`. No
workflow step has signing or App Store Connect credentials.

A named reviewer must compare every candidate to the source-frozen UI and
approve it. Where the release runbook requires binary parity evidence, compare
the reviewed candidate with the signed Release artifact before metadata
upload. A Debug-only fixture must never be described as a signed Release or
build-8 binary capture.
