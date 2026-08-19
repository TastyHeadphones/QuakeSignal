# App Store Connect portal audit — 2026-08-19

This handoff records portal facts and the bounded draft-preparation changes
verified through `2026-08-19T09:37:26Z`. It is not live state. Re-verify every
row immediately before any later portal action.

## Draft-preparation actions completed

- Created the editable iOS `1.1` version under Apple ID `6800642443`.
- Removed the five iPhone screenshots that App Store Connect automatically
  copied from live iOS `1.0`. The live `1.0` listing was not changed. No iPhone,
  iPad, or Apple Watch screenshot is currently attached to the `1.1` draft.
- Saved the reviewed English (U.S.) description, promotional text, `What's New`,
  and iOS review notes from this repository. No build or review attachment was
  selected.
- Changed the existing tvOS and visionOS editable drafts from `1.0` to `1.1`,
  saved their reviewed English (U.S.) metadata and platform-specific review
  notes, and changed both from automatic to manual release.
- Did not add any platform for review, submit a version, select a build, upload a
  screenshot, answer visionOS App Motion, change availability, or modify either
  macOS draft.

## Observed records

| Apple ID | Record | Read-only observation | Release interpretation |
| --- | --- | --- | --- |
| `6800642443` | QuakeSignal | iOS `1.0` is live. iOS, tvOS, and visionOS each have a `1.1` manual-release draft with reviewed English metadata and no selected build or screenshots. The visionOS App Motion answer and App Review contact fields remain incomplete. A macOS `1.0` draft also exists in this record and was not changed. | Canonical for iOS/iPadOS, the embedded Watch companion, tvOS, and visionOS. Do not use its macOS draft for the separate Tauri app. |
| `6800642853` | QuakeSignal for macOS | macOS `1.0.0` is an editable draft. Four older screenshot assets and a `1.0.0` build are present; the build is Ready to Submit. The record reports zero installs. | Canonical for the Tauri Mac app with bundle ID `com.quakesignal.desktop`. The old build and images are not evidence for 1.1.0 and must not be submitted. |

The exact portal filenames and hashes of the four older Mac screenshots were
not exported into this repository. Record them in the release evidence before
replacing any assets; do not assume they are identical to the redesigned local
files.

## Offline screenshot-evidence addendum

Separately, a source-frozen ten-image English
iPhone/iPad build-8 Debug Simulator candidate was captured and recorded in the
repository's versioned candidate manifest/provenance. It remains unsigned,
`uploadApproved: false`, `signedReleaseEvidence: false`, and `reviewer: null`.
This resolves the mechanical recapture task only; it does not resolve named
visual approval, signed public-Release parity, physical QA, or any portal gate.

## Contradictions to resolve without deleting drafts

1. The native iOS, tvOS, and visionOS drafts now match the coordinated `1.1`
   marketing version, but none has a selected build or approved screenshots.
   Do not use **Add for Review** until every platform's signed build-8 archive,
   screenshot, rights, QA, and portal-answer gates are complete.
2. The historical 30-image iOS screenshot set was captured from build 7 and
   cannot establish build-8 appearance. Preserve it as historical evidence.
   The separate source-frozen ten-image English build-8 Debug Simulator
   candidate resolves mechanical recapture only; obtain named visual approval
   and signed public-Release parity before any upload.
3. Apple ID `6800642443` contains a macOS draft, but the shipping Tauri Mac app
   has a different bundle ID and canonical record (`6800642853`). Do not attach
   `com.quakesignal.desktop` artifacts or metadata to the macOS draft in
   `6800642443`, do not claim that the Tauri app is part of that Universal
   Purchase, and do not delete the draft during this release.
4. Apple ID `6800642853` still presents version/build 1.0.0 and older images,
   while the checked-in candidate is 1.1.0. Do not select or submit the old
   build. If App Store Connect permits editing the unreleased version number,
   change the existing draft to 1.1.0 after the signed candidate is ready. If
   it does not, stop and ask App Store Connect Support; do not create a third
   app record.
5. Current review notes are saved from the checked-in platform sources, but
   missing contact fields still conflict with a review-ready submission. The
   release owner must enter a real accountable contact before Add for Review.

Apple explains that platforms in a shared record keep the same Apple ID, SKU,
and bundle ID; platform versions are submitted separately. See
[Add platforms](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-platforms/)
and
[Overview of submitting for review](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/overview-of-submitting-for-review/).

## Safe portal action sequence

No step below is authorized until its corresponding offline, signing, QA,
rights, and release-owner gate is complete.

1. Export a read-only snapshot of both records, including version states,
   selected builds, screenshot filenames, App Review fields, availability, and
   submission state. Preserve the existing drafts; perform no deletion.
2. Freeze the build-8 native source and 1.1.0 Mac source. Complete unsigned CI,
   signed archive verification, target profiles, platform icons, new
   screenshots/provenance, and required physical/platform QA.
3. Deploy and verify the matching production Worker migration/policy before the
   iOS/iPadOS build that relies on protected App Attest registration is
   uploaded. visionOS is foreground-only and has no relay registration path.
4. Upload the iOS host with embedded Watch, tvOS, and visionOS build-8 archives
   through their protected lanes. Upload the signed Mac 1.1.0 package only to
   Apple ID `6800642853`. Processing/TestFlight readiness is not release proof.
5. In Apple ID `6800642443`, verify the existing iOS, tvOS, and visionOS `1.1`
   metadata against the frozen release; attach each matching build; and upload
   only approved platform screenshots. Add Watch screenshots in the Apple Watch
   section of iOS 1.1 and ensure the shared iOS description explains its
   foreground-only behavior.
6. In Apple ID `6800642853`, retain the same canonical record, replace the
   selected build with the signed 1.1.0 candidate, and replace screenshots only
   after their signed-build provenance is approved. Leave the other record's
   macOS draft untouched and escalate its eventual disposition to the Account
   Holder/App Store Connect Support after this release.
7. Re-verify the saved platform review notes and enter an accountable contact.
   Complete Content Rights, Age Rating, App Privacy, Export Compliance,
   availability, price, localized-name approvals, and visionOS App Motion from
   final evidence.
8. Review each platform submission independently. Only a named release owner
   may choose Add for Review, Submit for Review, phased/manual release, and
   territories. Do not submit any platform merely because another platform is
   accepted.

## Non-negotiable claim boundaries

- QuakeSignal is independent and non-official. Wolfx-aggregated information can
  be delayed, incomplete, revised, or inaccurate. Customers must follow
  official local emergency guidance.
- iOS/iPadOS use protected optional notifications. Time Sensitive is not
  Critical, is user-controlled, and does not guarantee delivery.
- tvOS, visionOS, and Watch are foreground-only experiences with no independent
  background emergency alerts. A qualifying Vision warning can appear in-app
  with the selected local sound only while the app is open.
- The Mac app evaluates feed updates and plays local foreground alarms while it
  is running. It does not use App Attest or APNs and is not a background
  emergency-alert service.
- Do not certify Wolfx content rights until `content-rights-evidence.md` records
  the exact platform, storage, relay, territory, condition, duration, and
  termination permission, plus either Wolfx authority over every underlying
  feed or every separately required source permission.
