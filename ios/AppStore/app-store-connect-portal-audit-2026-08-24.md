# App Store Connect portal and build-12 handoff — 2026-08-24

This is a read-only action-time handoff for the native **QuakeSignal** record,
Apple ID `6800642443`. It records the portal state observed on 24 August 2026
after the protected GitHub release jobs finished. It did not save metadata,
upload screenshots, attach a build, change a questionnaire, or submit any
platform to App Review. Re-check every portal value immediately before a
future portal action.

## Source and signed uploads

All native release inputs are bound to source commit
`93a5055e95551a39f89b771fa01cf44eea0fb62d`, version `1.1 (12)`.

| Surface | Protected GitHub upload run | App Store Connect status observed |
| --- | --- | --- |
| iOS / iPadOS with embedded Apple Watch | [`32645910571`](https://github.com/TastyHeadphones/QuakeSignal/actions/runs/32645910571) | TestFlight upload **Complete** |
| tvOS | [`32647013219`](https://github.com/TastyHeadphones/QuakeSignal/actions/runs/32647013219) | TestFlight **Ready to Submit** |
| visionOS | [`32647282533`](https://github.com/TastyHeadphones/QuakeSignal/actions/runs/32647282533) | TestFlight **Ready to Submit** |
| Mac Catalyst | [`32647537011`](https://github.com/TastyHeadphones/QuakeSignal/actions/runs/32647537011) | TestFlight **Ready to Submit** |

The matching production Worker deployment is
[`32645478443`](https://github.com/TastyHeadphones/QuakeSignal/actions/runs/32645478443).
Its release smoke proof admitted App Attest version `12` with policy fingerprint
`sha256:amK5ZAK_TKYyYlrhEsNj0srkasOsUVIxEQuE5zlEkXI`.

## Current iOS draft state

- The shared native iOS version is `1.1`, **Prepare for Submission**, with
  manual release selected.
- The draft still has superseded build `8` selected. Build `12` must be
  selected only after all remaining gates below are complete.
- iPhone, iPad, and Apple Watch screenshot counts are each `0`. No current
  screenshot is attached.
- The visible App Review contact email and phone fields are blank. Do not put
  personal contact data in this repository; an accountable release contact must
  enter and verify those fields in App Store Connect.
- The visible App Review notes still describe build `8`; reconcile them with
  [`review-notes.txt`](./review-notes.txt), which is the build-12 source, when
  performing the final authenticated portal pass.

The separate desktop/Tauri record, Apple ID `6800642853`, remains outside this
native release. Mac Catalyst build `12` belongs to the shared native record.

## Screenshot evidence

Hosted run
[`32647878229`](https://github.com/TastyHeadphones/QuakeSignal/actions/runs/32647878229)
captured the complete iOS/iPadOS, tvOS, watchOS, visionOS, and Mac Catalyst
candidate set from the same source commit. Every package is explicitly
`UNAPPROVED-debug-*`; it is neither signed-Release screenshot evidence nor an
Apple upload authorization.

Before any screenshot download for upload, the protected
`apple-screenshot-release-ready.yml` finalizer must receive all required true
reviews and validate the four source-matching signed-upload attestations. The
finalizer requires a GitHub reviewer who is approved for
`ios-app-store-release` and differs from the dispatch actor. It must record
genuine visual, privacy, and signed-Release-parity completion times. Do not
invent a reviewer, approval, timestamp, hash, or finalization artifact.

## Remaining action-time gates

1. Have an independent authorized reviewer complete the required screenshot
   reviews and dispatch the protected finalizer with the genuine review data.
2. Complete the platform QA and the outstanding App Privacy, Age Rating,
   Export Compliance, content-rights, visionOS App Motion, availability, and
   localization decisions using the selected build-12 archives.
3. Enter and verify the real App Review contact. Reconcile the current source
   metadata and review notes with each native platform draft.
4. At the moment of a portal mutation, download only the finalizer's approved
   artifact, upload the matching screenshots, attach build `12` to each
   platform, save and visually re-open every field, then use **Add for Review**
   only with fresh release-owner confirmation.

Until every gate is completed, the correct portal state is **Prepare for
Submission**. This record does not authorize an App Store submission.
