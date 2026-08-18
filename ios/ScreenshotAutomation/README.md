# Native platform screenshot harness

This harness captures real simulator output for the tvOS, watchOS, and
visionOS targets. It does not generate, resize, decorate, commit, upload, or
approve screenshots.

The app-side fixture is available only in a Debug Simulator build and requires
both `--quakesignal-screenshot-automation` and
`QUAKESIGNAL_SCREENSHOT_AUTOMATION=1`. It supplies fixed finalized historical
reports, bypasses onboarding, and prevents startup network, notification, APNs,
and location activity. Ordinary Debug launches, physical devices, InternalQA,
and Release builds remain on production behavior.

Apple's current screenshot specification accepts:

- Apple TV: 1920x1080 or 3840x2160. This harness selects the 1080p simulator
  and requires exactly 1920x1080.
- Apple Vision Pro: exactly 3840x2160. This harness selects the 4K simulator.
- Apple Watch: 422x514 (Ultra 3), 410x502 (Ultra 2/Ultra), 416x496 (Series
  11/10), 396x484 (Series 9/8/7), 368x448 (Series 6/5/4 and SE), or 312x390
  (Series 3). The build-8 plan uses 410x502, so the harness prefers an Ultra 2
  or Ultra simulator, then falls back to another accepted large device and
  validates that device's matching native size. If fallback occurs, update the
  plan before review and use one Watch size consistently across every
  localization.

Source: [Apple screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/).

## Local commands

From the repository root, first install only the runtime needed for a capture:

```sh
xcodebuild -downloadPlatform tvOS -architectureVariant arm64
xcodebuild -downloadPlatform watchOS -architectureVariant arm64
xcodebuild -downloadPlatform visionOS -architectureVariant arm64
```

Regenerate the project, then capture into a temporary/artifact directory
outside the repository:

```sh
cd ios
xcodegen generate --spec project.yml
cd ..

ios/ScreenshotAutomation/capture-platform-screenshot.sh \
  tvos /tmp/quakesignal-screenshots/tvos-en.png
ios/ScreenshotAutomation/capture-platform-screenshot.sh \
  watchos /tmp/quakesignal-screenshots/watchos-en.png
ios/ScreenshotAutomation/capture-platform-screenshot.sh \
  visionos /tmp/quakesignal-screenshots/visionos-en.png
```

Set `QUAKESIGNAL_SCREENSHOT_LOCALE=ja` or `zh-Hans` to capture another
localization. Every invocation creates a disposable simulator, builds and
installs the native target without signing credentials, launches the gated
fixture, captures an untouched PNG, checks pixel size and alpha, prints its
SHA-256, and deletes the simulator. Set
`QUAKESIGNAL_SCREENSHOT_KEEP_SIMULATOR=1` only for manual visual debugging.
For watchOS, it also creates and boots a disposable paired iPhone Simulator;
no existing personal simulator pair is reused.

## CI artifact use

The same commands are credential-free on a macOS runner. Point the output at
`$RUNNER_TEMP`, then use the CI provider's ordinary artifact-upload step. Keep
the artifact separate from signing and App Store Connect upload jobs. A named
reviewer must compare the candidate to the source-frozen UI and approve it;
where the release runbook requires binary parity evidence, compare it with the
signed Release artifact before metadata upload. The Debug-only fixture must
never be described as having run in a signed Release binary.

If the required runtime is unavailable, the script exits before building and
prints the exact `xcodebuild -downloadPlatform` command. It never substitutes a
different resolution or fabricates a capture.
