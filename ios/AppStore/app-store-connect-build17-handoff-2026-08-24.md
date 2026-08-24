# App Store Connect build-17 handoff — 2026-08-24

This is the source-bound handoff for the native **QuakeSignal** release
candidate, version `1.1 (17)`. It records completed GitHub evidence and the
remaining release gates; it does not modify App Store Connect, grant
third-party rights, approve screenshots, or authorize App Review submission.

## Source and protected release evidence

All entries in this handoff are bound to protected `main` commit
`917ed41db29178ffe7e184d0b52ce4484d86d97e`.

| Surface | Successful protected upload run | Authenticated portal status |
| --- | --- | --- |
| iOS / iPadOS with embedded Apple Watch | [32673331369](https://github.com/TastyHeadphones/QuakeSignal/actions/runs/32673331369) | Build `1.1 (17)` is **Ready to Submit**; the iOS draft still selects build 8 |
| tvOS | [32673806654](https://github.com/TastyHeadphones/QuakeSignal/actions/runs/32673806654) | Build `1.1 (17)` is **Ready to Submit**; no draft build is selected |
| visionOS | [32673333522](https://github.com/TastyHeadphones/QuakeSignal/actions/runs/32673333522) | Build `1.1 (17)` is **Ready to Submit**; no draft build is selected |
| Mac Catalyst | [32673334959](https://github.com/TastyHeadphones/QuakeSignal/actions/runs/32673334959) | Build `1.1 (17)` is **Ready to Submit**; no draft build is selected |

The four workflow runs completed successfully on protected `main` at the
source commit above. Their signed-release attestations are the evidence for the
exact build; a successful upload run does not prove App Store Connect
processing, TestFlight availability, physical-device behavior, portal field
values, or App Review readiness. Processing and TestFlight availability were
subsequently confirmed by the authenticated, read-only portal inspection below.

The native product uses the existing shared App Store Connect record, Apple ID
`6800642443`. The separate desktop/Tauri record, Apple ID `6800642853`, is not
part of this native release.

## Authenticated portal inspection

The following state was observed on 24 August 2026 without changing App Store
Connect:

- Every native `1.1 (17)` build is **Ready to Submit** in TestFlight. The
  shared iOS/iPadOS/Watch upload and the Mac Catalyst, tvOS, and visionOS
  uploads are all present in Apple ID `6800642443`.
- The iOS version draft still selects the superseded build `8`. The Mac
  Catalyst, tvOS, and visionOS drafts each show **Add Build**, with no build
  selected.
- All iPhone, iPad, Apple Watch, Mac, Apple TV, and Apple Vision Pro screenshot
  slots are empty. No screenshot is attached.
- The phone and email contact fields are empty. Their accountable values must
  be entered and visually verified in the portal, never copied into source.
- Each App Review note still identifies build 8. The checked-in build-17 review
  notes are ready to replace those stale portal values, but no note was saved
  during this inspection.
- Manual release remains selected. The visionOS App Motion answer is not yet
  configured.

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

- Select only the confirmed, exact `1.1 (17)` build for each platform draft.
- Complete platform and physical-device QA, including the required App Attest
  and opted-in APNs checks where applicable.
- Complete the protected screenshot finalizer and upload only its approved
  source-addressed artifact.
- Reconcile App Privacy, Age Rating, Export Compliance, App Motion,
  availability, and localization choices with the selected signed builds.
- Enter and visually verify the accountable App Review contact, replace the
  stale build-8 review notes with the checked-in build-17 notes, and re-open
  every saved value in App Store Connect.
- Recheck the final JMA-only source scope, current third-party terms, intended
  territories, and Content Rights answer with the responsible release owner.

Only after these checks are complete may an authorized release owner attach the
builds and submit the version for App Review.
