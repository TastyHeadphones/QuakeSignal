# App Store Connect build-17 handoff — 2026-08-24

This is the source-bound handoff for the native **QuakeSignal** release
candidate, version `1.1 (17)`. It records completed GitHub evidence and the
remaining release gates; it does not modify App Store Connect, grant
third-party rights, approve screenshots, or authorize App Review submission.

## Source and protected release evidence

All entries in this handoff are bound to protected `main` commit
`917ed41db29178ffe7e184d0b52ce4484d86d97e`.

| Surface | Successful protected upload run | Status to verify in App Store Connect |
| --- | --- | --- |
| iOS / iPadOS with embedded Apple Watch | [32673331369](https://github.com/TastyHeadphones/QuakeSignal/actions/runs/32673331369) | Processing and selected build for the shared native record |
| tvOS | [32673806654](https://github.com/TastyHeadphones/QuakeSignal/actions/runs/32673806654) | Processing and selected build for the shared native record |
| visionOS | [32673333522](https://github.com/TastyHeadphones/QuakeSignal/actions/runs/32673333522) | Processing and selected build for the shared native record |
| Mac Catalyst | [32673334959](https://github.com/TastyHeadphones/QuakeSignal/actions/runs/32673334959) | Processing and selected build for the shared native record |

The four workflow runs completed successfully on protected `main` at the
source commit above. Their signed-release attestations are the evidence for the
exact build; a successful upload run does not prove App Store Connect
processing, TestFlight availability, physical-device behavior, portal field
values, or App Review readiness.

The native product uses the existing shared App Store Connect record, Apple ID
`6800642443`. The separate desktop/Tauri record, Apple ID `6800642853`, is not
part of this native release.

## Screenshot status

Run [32678113996](https://github.com/TastyHeadphones/QuakeSignal/actions/runs/32678113996)
completed successfully for the same source commit and captured all 26 native
simulator frames: 10 iOS/iPadOS, 3 tvOS, 3 watchOS, 5 visionOS, and 5 Mac
Catalyst. They remain an **unapproved candidate**.

Do not download, relabel, attach, or upload those images to App Store Connect.
Before any upload, `apple-screenshot-release-ready.yml` must run on protected
`main` with a real independent environment reviewer, genuine visual/privacy/
signed-release-parity review times, and the four source-matching signed-release
attestations listed above. The environment reviewer must differ from the
workflow dispatch actor.

## Required action-time completion

- Confirm that every build above has processed in the shared native record and
  select only the exact `1.1 (17)` build for its platform.
- Complete platform and physical-device QA, including the required App Attest
  and opted-in APNs checks where applicable.
- Complete the protected screenshot finalizer and upload only its approved
  source-addressed artifact.
- Reconcile App Privacy, Age Rating, Export Compliance, App Motion,
  availability, and localization choices with the selected signed builds.
- Enter and visually verify the accountable App Review contact and all saved
  review metadata in App Store Connect.
- Recheck the final JMA-only source scope, current third-party terms, intended
  territories, and Content Rights answer with the responsible release owner.

Only after these checks are complete may an authorized release owner attach the
builds and submit the version for App Review.
