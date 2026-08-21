# Native-platform screenshot checklist — 1.1 (8)

Apple requires one to ten opaque JPEG/JPG/PNG screenshots per supported device
family. The current accepted sizes are documented in Apple's
[Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/).
This checklist creates no approval by itself.

All build-8 capture, validation, and packaging commands in this checklist are
hosted-workflow-internal. Release operators dispatch the canonical GitHub
Actions workflows and must not run Xcode, Simulator, Ruby, shell, or repository
scripts on a workstation.

## Common capture gate

- [ ] Freeze a full 40-character source commit and verify all four schemes are
  version `1.1`, build `8`.
- [ ] Dispatch the hosted `apple-platform-screenshots.yml` workflow at the
  frozen source commit. It captures source-frozen Debug Simulator candidates
  with the platform harness; those candidates cannot run in InternalQA, Release,
  or a physical-device build and must never be described as signed Release or
  build-8 binary captures.
- [ ] Preserve the matching successful signed-upload run ID when it is
  available. Before screenshot upload, version attachment, or submission,
  obtain named visual approval and complete the signed-Release parity comparison
  required by the platform runbook. The finalizer derives the artifact SHA-256
  from the run attestation.
- [ ] Confirm the hosted artifact records the exact Xcode, OS/runtime, device
  model, device identifier where appropriate, capture time, and reviewer. An
  automated unapproved candidate intentionally keeps `reviewer: null` until
  named review. For Simulator candidates, verify the hosted
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
- [x] Preserve each planned manifest byte-for-byte. The completed capture
  packages hash those exact pending/null plans; changing a plan in place would
  invalidate the provenance chain. Store results in the separate fail-closed
  candidate package and keep it unapproved. Record any later named approval and
  signed-Release parity in separately reviewed release evidence unless the
  schema and validator are deliberately extended together.

## Apple TV

- [ ] Capture all three planned frames at exactly `1920 × 1080` landscape.
  (`3840 × 2160` is also accepted, but do not mix sizes in this release set.)
- [ ] Verify focus appearance and Siri Remote navigation on Apple TV hardware
  or the matching simulator runtime.
- [ ] Ensure the visible copy says foreground only and no screenshot implies a
  background alert, notification, automatic alert sound, App Attest, or
  location feature.
- [ ] Exercise the Alert Sound screen, focus containment, all three choices,
  explicit-Remote-only custom playback, and inactive-scene stop behavior on the
  signed Apple TV build. The fixed three-frame store set intentionally does not
  market a fabricated live warning or imply automatic audio.
- [x] Preserve the Apple TV plan and retain the separate candidate metadata,
  aggregate/per-frame evidence, runtime inventory, and PNG SHA-256 values.

## Apple Vision Pro

- [ ] Capture all five planned frames at exactly `3840 × 2160` landscape.
- [ ] Verify the full window is legible and no private surroundings, account
  identifiers, or precise location are visible.
- [ ] Complete Apple Vision Pro QA and approve the required App Motion answer;
  a screenshot does not prove notification or motion behavior.
- [ ] Ensure the visible copy is truthful about foreground-only monitoring and
  does not imply APNs, App Attest, Time Sensitive, Critical Alerts, or
  background emergency delivery on visionOS.
- [x] Preserve the Apple Vision Pro plan and retain the separate candidate
  metadata, aggregate/per-frame evidence, runtime inventory, and PNG SHA-256
  values.

## Apple Watch

- [ ] Use exactly `410 × 502` portrait for this planned set, from Apple Watch
  Ultra 2 / Ultra. If the release owner selects another accepted class, update
  every frame and every localization before capture; Apple requires one
  consistent Watch size across all localizations.
- [ ] Confirm the capture log says `Validated Watch foreground-only badge`.
  Reject any artifact that shows a clock face or lacks the orange `Foreground
  only` badge, even if its dimensions, hash, and provenance metadata pass.
- [ ] Confirm Watch capture finished before the harness's five-minute hard
  deadline. A foreground-restart failure or timeout is a rejected capture, not
  permission to reuse the last PNG.
- [ ] Verify the Watch app is installed from the signed iOS host, refreshes when
  opened, scrolls correctly, and opens event details on a paired Apple Watch.
- [ ] Ensure the screenshots make no independent background-alert claim.
- [x] Preserve the Apple Watch plan and retain the separate candidate metadata,
  aggregate/per-frame evidence, runtime inventory, and PNG SHA-256 values.

## Source-addressed final-set integration

- [ ] Leave every historical path byte-for-byte unchanged. The locked catalog
  is `../screenshot-set-index-v1.1-build8.json`; its normal pending state is
  `activeReleaseSet: null`.
- [ ] Capture all 26 frames from one frozen 40-character commit: 10 iPhone/iPad,
  3 Apple TV, 3 Apple Watch, 5 Apple Vision Pro, and 5 Mac Catalyst. Do not
  activate a partial package or combine commits.
- [ ] Let the protected `apple-screenshot-release-ready.yml` workflow integrate
  the packages only below its external
  `ios/AppStore/screenshot-release-sets-v1.1-build8/<source-commit>/`. Each platform
  directory contains `package-provenance.json`, its exact planned frame paths,
  and all recorded `evidence/` files. `release-set.json` hashes every package
  byte and remains `source-frozen-unapproved` with `uploadApproved: false`.
- [ ] Archive the exact Debug capture artifact as the provenance
  `artifactFile`, bind its actual bytes to `artifactSha256`, and retain at
  least one separate nonempty capture-evidence file. A digest string without
  the archived artifact bytes is not evidence.
- [ ] Confirm all 26 frame SHA-256 values are distinct and none equals a locked
  historical screenshot SHA-256. Renaming, relabelling, resizing metadata, or
  recomputing outer manifests must never turn an old/collapsed frame into a
  final-set frame.
- [ ] Keep the checked-in `activeReleaseSet` null. The hosted workflow creates
  an ephemeral active index only after all 26 frames exist. The validator binds
  each plan both to its current
  bytes and the same bytes at the source commit, and retains the full native
  product-source guard, including tracked, untracked, ignored, and
  `Debug.local.xcconfig` drift checks.
- [ ] After named full-size visual review, named privacy review, and named signed
  public-Release comparison for every platform, dispatch the protected workflow
  with all three approvals, the exact capture run ID/source SHA, four successful
  upload-run IDs, and the three actual UTC review completion times. It adds the
  separate hashed `release-approval.json`. The job derives each artifact kind,
  hash, exact signed source commit, workflow/run/attempt, attestation digest, and
  signed-run completion time from the four machine-readable attestations. It
  requires iOS/iPadOS and embedded watchOS to share one run and IPA, and exactly
  four distinct runs/hashes overall. Every reviewer identifier must equal an
  approved `ios-app-store-release` GitHub login distinct from the dispatch actor.
  Each parity-review time must follow both capture and signed-upload completion;
  the overall review time is the latest supplied real review completion.
- [ ] Require the hosted strict mode to fail until the complete exact-commit set,
  successful capture-run binding, and all three named approvals are present:

  ```sh
  ruby .github/scripts/verify-store-assets.rb \
    --require-build8-screenshot-release-ready \
    --expected-source-commit=<40-character-source-commit> \
    --screenshot-release-evidence-root="$EVIDENCE_ROOT"
  ```

  Run this strict mode only in the hosted release-ready workflow. Its final
  artifact retains the active evidence for three days; no generated image or
  active index is committed.

## Historical build-7 and superseded build-8 candidate evidence

The existing `../screenshot-manifest-v1.1.json`,
`../screenshot-provenance-v1.1.json`, and 30 images truthfully record a
build-7 simulator capture. Do not relabel or upload them as build-8 screenshots.
The preserved `../screenshot-manifest-v1.1-build8.json`,
`../screenshot-provenance-v1.1-build8.json`, and ten files under
`../screenshots-v1.1-build8/en-US/` truthfully record a source-frozen Debug
Simulator candidate. It remains unsigned, unapproved, and reviewer-null; its
existence is not permission to upload. It is now historical because the
JMA-only and Mac Catalyst source changes postdate its capture; the final
build-8 commit requires a complete recapture rather than a provenance rewrite.
The
`../screenshot-manifest-v1.1-build8.template.json` file remains planning
history, not evidence.

The hosted build-8 recapture sequence is:

1. Freeze the full source commit and dispatch the hosted
   `apple-platform-screenshots.yml` workflow. It generates the complete
   iPhone/iPad, Apple TV, Apple Watch, Apple Vision Pro, and Mac Catalyst
   candidate set with the exact source, plan, runtime, and SHA-256 evidence.
2. Preserve the workflow artifacts without downloading, rewriting, or
   relabelling them on a workstation. Japanese and Simplified Chinese remain
   unpublished pending localized-name, trademark, and availability approval.
3. Separately compare every candidate with the matching signed public Release
   upload, then dispatch the protected `apple-screenshot-release-ready.yml`
   workflow with the exact capture run, source SHA, four upload-run IDs, and
   named visual, privacy, and signed-parity approvals.
4. Let the protected workflow validate the build-8 manifest/provenance and
   assemble the approved upload package in its hosted temporary directory.

No current iPhone, iPad, Apple TV, Apple Vision Pro, Apple Watch, or Mac
Catalyst screenshot asset is approved for a build-8 App Store upload.

The exact native candidates captured from commit
`b461083bb5bff21eb4f1f4a8b5ef8f0764d89dd2` by successful workflow run
`32347549322` are preserved under
`screenshot-candidates-v1.1-build8/`. The directory contains three exact
`UNAPPROVED-debug-simulator-*` packages plus `capture-run-receipt.json`. The
packages collectively contain 3 Apple TV, 3 Apple Watch, and 5 Apple Vision
Pro frames. Their source, plan, runtime, dimensions, opacity, per-frame hashes,
aggregate provenance, and unapproved status must pass
`.github/scripts/verify-native-apple-screenshot-candidates.rb`; this still does
not supply current-source evidence, a signed Release comparison, or named
upload approval. Preserve the packages as historical evidence and recapture
all native selectors at the final build-8 commit.
