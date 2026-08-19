# App Store Connect portal audit — 2026-08-19

This is a read-only handoff record of portal facts observed for offline release
preparation. It is not live state, and this work did not change App Store
Connect. Re-verify every row immediately before any portal action.

## Observed records

| Apple ID | Record | Read-only observation | Release interpretation |
| --- | --- | --- | --- |
| `6800642443` | QuakeSignal | iOS `1.0` is live. tvOS `1.0` and visionOS `1.0` are empty drafts with no selected build or screenshots. The iOS review notes are stale and App Review contact fields are incomplete. A macOS `1.0` draft also exists in this record. | Canonical for iOS/iPadOS, the embedded Watch companion, tvOS, and visionOS. Do not use its macOS draft for the separate Tauri app. |
| `6800642853` | QuakeSignal for macOS | macOS `1.0.0` is an editable draft. Four older screenshot assets and a `1.0.0` build are present; the build is Ready to Submit. The record reports zero installs. | Canonical for the Tauri Mac app with bundle ID `com.quakesignal.desktop`. The old build and images are not evidence for 1.1.0 and must not be submitted. |

The exact portal filenames and hashes of the four older Mac screenshots were
not exported into this repository. Record them in the release evidence before
replacing any assets; do not assume they are identical to the redesigned local
files.

## Offline screenshot-evidence addendum

After this read-only portal observation, a source-frozen ten-image English
iPhone/iPad build-8 Debug Simulator candidate was captured and recorded in the
repository's versioned candidate manifest/provenance. It remains unsigned,
`uploadApproved: false`, `signedReleaseEvidence: false`, and `reviewer: null`.
This resolves the mechanical recapture task only; it does not resolve named
visual approval, signed public-Release parity, physical QA, or any portal gate.

## Contradictions to resolve without deleting drafts

1. The native release is coordinated as `1.1 (8)`, but the empty tvOS and
   visionOS platform drafts still show their default `1.0` version number.
   Apple documents that a newly added platform starts at 1.0 and that the
   version number can be changed under App Information. Update each existing
   editable draft to `1.1` only after its build-8 archive and metadata are
   frozen; do not add another platform record.
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
5. Stale review notes and missing contact fields conflict with a review-ready
   submission. Replace notes only from the final platform-specific source and
   have the release owner enter a real accountable contact before Add for
   Review.

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
5. In Apple ID `6800642443`, edit the existing tvOS and visionOS drafts to 1.1
   where permitted; attach each matching build; add only approved English
   metadata and newly captured platform screenshots. Add Watch screenshots in
   the Apple Watch section of iOS 1.1 and ensure the shared iOS description
   explains its foreground-only behavior.
6. In Apple ID `6800642853`, retain the same canonical record, replace the
   selected build with the signed 1.1.0 candidate, and replace screenshots only
   after their signed-build provenance is approved. Leave the other record's
   macOS draft untouched and escalate its eventual disposition to the Account
   Holder/App Store Connect Support after this release.
7. Enter current platform review notes and an accountable contact. Complete
   Content Rights, Age Rating, App Privacy, Export Compliance, availability,
   price, localized-name approvals, and visionOS App Motion from final evidence.
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
