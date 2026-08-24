# App Store Connect build-17 handoff — 2026-08-24

This is the source-bound handoff for the native **QuakeSignal** release
candidate, version `1.1 (17)`. It records completed GitHub evidence, the
saved App Store Connect draft configuration, and the remaining release gates.
It does not grant third-party rights, approve screenshots, or authorize App
Review submission.

## Source and protected release evidence

All entries in this handoff are bound to protected `main` commit
`917ed41db29178ffe7e184d0b52ce4484d86d97e`.

| Surface | Successful protected upload run | Authenticated portal status |
| --- | --- | --- |
| iOS / iPadOS with embedded Apple Watch | [32673331369](https://github.com/TastyHeadphones/QuakeSignal/actions/runs/32673331369) | Build `1.1 (17)` is **Ready to Submit** and selected in the iOS draft |
| tvOS | [32673806654](https://github.com/TastyHeadphones/QuakeSignal/actions/runs/32673806654) | Build `1.1 (17)` is **Ready to Submit** and selected in the tvOS draft |
| visionOS | [32673333522](https://github.com/TastyHeadphones/QuakeSignal/actions/runs/32673333522) | Build `1.1 (17)` is **Ready to Submit** and selected in the visionOS draft |
| Mac Catalyst | [32673334959](https://github.com/TastyHeadphones/QuakeSignal/actions/runs/32673334959) | Build `1.1 (17)` is **Ready to Submit** and selected in the Mac Catalyst draft |

The four workflow runs completed successfully on protected `main` at the
source commit above. Their signed-release attestations are the evidence for the
exact build; a successful upload run does not prove App Store Connect
processing, TestFlight availability, physical-device behavior, portal field
values, or App Review readiness. Processing and TestFlight availability were
subsequently confirmed by the authenticated, read-only portal inspection below.

The native product uses the existing shared App Store Connect record, Apple ID
`6800642443`. The separate desktop/Tauri record, Apple ID `6800642853`, is not
part of this native release.

## Authenticated portal configuration

The following state was saved and then re-opened for verification on 24 August
2026. The change was limited to the selected B17 build and the checked-in B17
App Review note for each native platform:

- Every native `1.1 (17)` build is **Ready to Submit** in TestFlight. The
  shared iOS/iPadOS/Watch upload and the Mac Catalyst, tvOS, and visionOS
  uploads are all present in Apple ID `6800642443`.
- The iOS, Mac Catalyst, tvOS, and visionOS version drafts now each select
  their exact native `1.1 (17)` build. The iOS draft association was changed
  from build 8; this did not delete the build-8 TestFlight archive.
- All iPhone, iPad, Apple Watch, Mac, Apple TV, and Apple Vision Pro screenshot
  slots are empty. No screenshot is attached.
- The phone and email contact fields are empty. Their accountable values must
  be entered and visually verified in the portal, never copied into source.
- Each App Review note now matches its checked-in B17 source: the shared iOS
  note and the Mac Catalyst, tvOS, and visionOS platform notes. Their saved
  values were re-opened after the change.
- Manual release remains selected. The visionOS App Motion answer is not yet
  configured.
- Every version remains **Prepare for Submission**. This work did not select
  Content Rights or App Motion, enter contact data, attach screenshots, or use
  **Add for Review**.

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

## Authenticated Add-for-Review validation

After the release owner expressly authorized an App Review submission attempt
on 24 August 2026, App Store Connect validated every native `1.1 (17)` draft
and rejected each request without changing its **Prepare for Submission**
status. No version entered **Waiting for Review** or **In Review**. This is
validation evidence, not an authorization to invent metadata, attach the
unapproved screenshot candidate, or change any accountable/legal answer.

| Platform | Exact portal requirements reported by App Store Connect |
| --- | --- |
| iOS / iPadOS with embedded Apple Watch | A 13-inch iPad screenshot, a 6.5-inch iPhone screenshot, an Apple Watch screenshot, the Apple TV Privacy Policy in App Privacy, and `What's New in This Version` for Japanese and Simplified Chinese. |
| Mac Catalyst | At least one screenshot, the Apple TV Privacy Policy in App Privacy, and the Japanese description. |
| tvOS | At least one screenshot, the Apple TV Privacy Policy in App Privacy, and descriptions for Japanese and Simplified Chinese. |
| visionOS | At least one screenshot, the required App Motion answer, the Apple TV Privacy Policy in App Privacy, and descriptions for Japanese and Simplified Chinese. |

The policy field is a separately reviewed Apple TV privacy-policy text field,
not a substitute for the public Privacy Policy URL. The versioned source keeps
its draft marker until legal/release-owner approval. Likewise, the Japanese
and Simplified Chinese localizations must not be completed or uploaded until
their exact product-page names, availability, and trademark review are
approved. The source-bound 26-frame screenshot set remains unapproved pending
the protected independent-review finalizer.

## Required action-time completion

- Keep only the confirmed, exact `1.1 (17)` build associated with each
  platform draft unless a new source-bound release audit authorizes a change.
- Complete platform and physical-device QA, including the required App Attest
  and opted-in APNs checks where applicable.
- Complete the protected screenshot finalizer and upload only its approved
  source-addressed artifact.
- Reconcile App Privacy, Age Rating, Export Compliance, App Motion,
  availability, and localization choices with the selected signed builds.
- Enter and visually verify the accountable App Review contact. Re-open every
  saved value in App Store Connect immediately before review submission.
- Recheck the final JMA-only source scope, current third-party terms, intended
  territories, and Content Rights answer with the responsible release owner.

Only after these checks are complete may an authorized release owner attach the
builds and submit the version for App Review.
