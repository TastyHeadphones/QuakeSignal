# Mac Catalyst screenshot source plan — 1.1 (8)

This directory is a source-only, unapproved capture plan for the Swift-native
Mac Catalyst build of `QuakeSignal`. It contains no captured screenshots and
does not authorize an App Store Connect upload.

The English (U.S.) description, promotional text, keywords, and review notes
are source drafts for the same shared-record macOS platform version. They must
be checked against the signed build and copied to App Store Connect only after
the remaining gates below pass.

The public Mac route is the `QuakeSignal` scheme built for **My Mac (Mac
Catalyst)** with bundle ID `com.quakesignal.app` in shared Apple ID
`6800642443`. It is not the separate Tauri app (`com.quakesignal.desktop`) and
it is not the iPhone/iPad binary offered as **Designed for iPad on Mac**.

## Required capture

Capture the five exact selectors in
[`screenshot-manifest-v1.1-build8.json`](./screenshot-manifest-v1.1-build8.json)
from a native Mac Catalyst window at `1280 × 800` logical points on a 2×
renderer scale. `UIGraphicsImageRenderer` must directly rasterize that exact
live UIWindow hierarchy into `2560 × 1600` pixels; never resize or crop the
result. The runner's actual finite display scale is recorded honestly as
`sourceDisplayScale`, separately from `rasterizationScale: 2`; it is never used
to claim that the host itself is a 2× display. The Debug-only fixture path
requires both:

- launch argument `--quakesignal-screenshot-automation`
- environment value `QUAKESIGNAL_SCREENSHOT_AUTOMATION=1`

Pass the same selector through both the
`--quakesignal-screenshot-frame=<selector>` launch argument and
`QUAKESIGNAL_SCREENSHOT_FRAME=<selector>` environment value. A missing,
mismatched, duplicate, or unreviewed selector must leave fixture mode off.
Publishing hierarchy bytes additionally requires exactly one
`--quakesignal-catalyst-hierarchy-capture` argument and
`QUAKESIGNAL_CATALYST_HIERARCHY_CAPTURE=1`.

Trigger the distinct `macos-26-intel` Mac Catalyst job in
`.github/workflows/apple-platform-screenshots.yml` on GitHub. It pins Xcode
26.6 build 17F113 and fails before building unless the x86_64 host exposes at
least 1280 x 800 visible logical display points for the exact live UIWindow.
It captures an exact clean `GITHUB_SHA`; the following
command is a job-internal detail and is not a supported local capture path:

```bash
ios/ScreenshotAutomation/capture-maccatalyst-screenshot-set.sh "$RUNNER_TEMP/quakesignal-maccatalyst-build8"
```

The app writes a selector- and process-bound geometry record atomically under
an ephemeral root supplied by the harness. The harness accepts only `ready`
evidence for the launched PID, then requires exactly one visible layer-zero
Core Graphics window for that PID and an exact 1280 × 800 frame. After its
first observation it writes a request bound to PID, Core Graphics window ID,
reviewed selector, exact logical/raster geometry, and a fresh 64-hex nonce. The
app accepts only that schema-exact request, rechecks its attached live UIWindow
on the main actor, and fails closed unless the window is visible, key,
foreground-active, and unchanged at 1280 × 800. It renders with
`UIGraphicsImageRenderer` scale 2 and
`UIView.drawHierarchy(afterScreenUpdates: true)`, rejects a false draw or any
result other than 2560 × 1600, revalidates the request, and atomically writes
the raw PNG followed by its request-bound response. The response records the
API, live hierarchy surface, source display scale, rasterization scale, logical
points, pixels, visibility state, before/after system frames, renderer policy,
and no-resize guarantee. The host then requires an identical second Core
Graphics PID/window/frame observation. Geometry readiness is followed by a
fixed 10-second
content settle, or 25 seconds for Map. A universal committed-view gate and
selector-specific text checks then reject launch, blank, placeholder, and
wrong-route frames; Map also requires chromatic map content. Only semantic
status 65 may relaunch and recapture the same selector once. Operational
validator failures use status 70 and never retry. The accepted validator
record, settle duration, attempt count, and validator hash are retained in
provenance. After a successful retry, the first rejection's reason/metric JSON
and its exact hash are also retained under `semantic-rejections/`; the rejected
PNG is never made an upload candidate. Build, helper, capture, validation, and
app PIDs are explicitly tracked so INT/TERM cleanup stops them before the
temporary package is removed. This path does not require macOS Accessibility
or Screen Recording access and does not use ScreenCaptureKit, `screencapture`,
`CALayer.render`, SwiftUI `ImageRenderer`, or a reconstructed Map snapshot.

Raw renderer bytes and their observed alpha state are retained and hashed. A
Core Graphics/ImageIO transform composites those same 2560 × 1600 pixels over
`[0, 0, 0, 255]`, emits opaque PNG without resize or crop, and records both
hashes.

The set package also records the full clean Git commit ID, exact manifest hash,
Debug app-bundle tree and executable hashes, launched process/window identity,
actual source display scale, fixed rasterization scale, host/Xcode versions,
per-frame logs, and aggregate provenance.
Every reviewer and approval field remains `null`; capture never constitutes
upload approval. The GitHub-hosted job has no signing or App Store credentials.

The checked-in selector code is available only in Debug on a simulator or a
native Mac Catalyst host. `InternalQA` and `Release` builds cannot activate
fixtures. Before upload, a named reviewer must compare every Debug candidate
with the matching signed Release build 8 behavior, record the signed artifact
hash and capture provenance, verify an opaque image with no private location
or user-entered preparedness details, and explicitly approve the final bytes.

## Privacy manifest scope

Mac Catalyst shares the `QuakeSignal` target and therefore packages the same
conservative product privacy manifest as iPhone/iPad. That manifest declares
the optional iPhone/iPad notification-registration categories for the shared
store record even though Catalyst does not invoke that registration path.
Catalyst itself connects to Wolfx only while open, keeps its preferences and
guide details locally, and sends no APNs token, App Attest record, alert
preference, or location to QuakeSignal-operated infrastructure. Confirm this
universal-manifest decision against the signed Catalyst archive and final App
Privacy questionnaire; do not infer a Catalyst upload merely from the broader
manifest declaration.

## Store constraints

Apple currently accepts 1–10 Mac screenshots per localization as opaque JPG or
PNG files at one of `1280 × 800`, `1440 × 900`, `2560 × 1600`, or
`2880 × 1800` pixels. This plan selects direct `2560 × 1600` @2x UIKit
hierarchy renders consistently for all five English (U.S.) frames. The capture
harness losslessly composites the raw hierarchy alpha over fixed black without
resizing, records the raw and final hashes, and publishes only an unapproved
atomic evidence package. See Apple's
[screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/).

Do not reuse the existing images under `desktop/AppStore/screenshots/`. Their
provenance is for the separate Tauri product and bundle ID
`com.quakesignal.desktop`; they are not build-8 evidence for this Catalyst
binary. Keep them as historical evidence unless the release owner separately
authorizes cleanup.
