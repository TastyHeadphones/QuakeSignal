# QuakeSignal 1.1 App Store release

This checklist is the release-specific source of truth for marketing version
`1.1`, build `8`. It does not replace the legal and physical-device approvals
recorded in the existing submission documents.

> Do not use the legacy unversioned screenshot paths for this release; they
> describe the earlier iPhone-only 1.0 asset set.

- Preserve `screenshot-manifest-v1.1-build8.template.json` as planning history;
  it is not release evidence and must not be uploaded.
- The ten English (U.S.) iPhone/iPad files in `screenshots-v1.1-build8/` now
  have an exact source-frozen Debug Simulator manifest, provenance, build-input
  evidence, and hashes. They remain unsigned and explicitly unapproved with
  `reviewer: null`, and they are historical after the later JMA-only/Mac
  Catalyst source changes. Recapture the exact final build-8 commit; named
  visual approval and signed public-Release parity are still pending. Keep `ja`
  and `zh-Hans` unpublished until the product-page name, availability, and
  trademark approvals are recorded.
- Copy the matching nonempty `whats_new_v1.1.txt` only into each approved
  localization. Hosted listing validation enforces the 4,000-character limit;
  the final authenticated portal pass must verify the saved What's New and
  promotional-text values rather than treating checked-in copy as save evidence.
- Preserve `screenshot-provenance-v1.1.json` as truthful build-7 simulator
  evidence. Its 30 matching hashes do not authorize a build-8 upload. The
  separate build-8 candidate hashes are historical and permanently
  non-uploadable for the current source. Apply named review and signed-Release
  parity gates only to the final-commit recapture.
- No current iPhone or iPad screenshot is approved for a build-8 upload.
- Keep `screenshot-set-index-v1.1-build8.json` at `activeReleaseSet: null` in
  ordinary listing CI until one exact final commit has all 26 required Apple
  frames under `screenshot-release-sets-v1.1-build8/<source-commit>/`. Never
  reuse or mutate an occupied historical path.
- Before screenshot upload, build attachment to version `1.1`, or App Review
  submission, require the source-addressed screenshot release gate as well as
  the ordinary listing checks. The protected finalizer, not a workstation,
  executes this job-internal command:

  ```sh
  ruby .github/scripts/verify-store-assets.rb \
    --require-build8-screenshot-release-ready \
    --expected-source-commit=<40-character-source-commit> \
    --screenshot-release-evidence-root="$EVIDENCE_ROOT"
  ```

  This must remain blocked until the active set is complete and source-current
  and a separate named approval records signed-Release parity for iOS/iPadOS,
  tvOS, watchOS, visionOS, and Mac Catalyst.
- Deploy all D1 migrations through 0013 and the build-8 Worker contract first.
  Confirm the production health endpoint accepts App Attest bundle versions
  1–8 and reports exactly `jma_eew` and `jma_eqlist` as its upstream source
  inventory.
- Upload only the public `Release` archive. Never submit the `InternalQA`
  configuration, whose controlled delayed training control is intentionally
  excluded from the public build.
- After the exact source/Worker policy, distribution credentials/profiles, and
  store-complete icon gates pass, use the four protected GitHub upload lanes to
  stage build 8 in TestFlight for internal/physical QA. This prerequisite upload
  is not permission to select or attach a build to version `1.1`, add it to App
  Review, submit it, or release it. Archive-only rehearsals are not final signed
  evidence; the finalizer requires the four successful upload-run attestations.
- Complete physical-device App Attest, APNs foreground/background/terminated,
  notification-sound, Silent Mode/Focus, location, and iPad QA before public
  submission.
- Use the published-terms content-rights basis in
  `content-rights-evidence.md`. The release owner decided on 20 August 2026 not
  to send the Wolfx permission request. Build 8 enables only `jma_eew` and
  `jma_eqlist`; CENC, Sichuan, Fujian, and Chongqing feeds are excluded from
  every submitted Apple target and the notification relay. Preserve JMA source
  attribution, the normalized/edited statement, the no-resale/no-public-feed
  boundary, and independent/non-official product behavior. Relay events and
  revisions become eligible for deletion after 89 days; the next successful
  daily cleanup removes them, and operational failure can delay deletion.
- Before submission, recheck the current Wolfx/Open API/JMA/PDL terms and
  notices, exact signed source inventory, direct relay routes, attribution,
  deployed 89-day-cutoff cleanup, and intended territories. Confirm that magnitude
  and epicentral-distance settings only filter delivery and that build 8 does
  not calculate predicted local intensity or arrival time or present a
  QuakeSignal-authored official warning. If Apple or a source requests more
  evidence, pause the affected scope rather than claiming a private written
  license. Separately confirm the App Review contact fields.
- Follow `apple-platform-release.md` for the iOS+embedded-Watch, tvOS,
  visionOS, and Mac Catalyst protected GitHub archive/upload actions. Xcode
  Cloud remains a future lane until an authorized owner creates its first
  workflow. Do not attach a native build to version `1.1` or submit it until its
  screenshots, signing, metadata, privacy/legal checks, and platform QA are
  approved. This 2026-08-22 operational direction supersedes the historical
  Xcode Cloud execution choice in `release-owner-decisions-2026-08-20.md`; it
  does not supersede that record's Mac storefront or content-rights decisions.
- The Watch catalog is mechanically valid and intentionally carries the
  canonical signal artwork. Obtain named visual approval against SHA-256
  `b792fccc4c08645fb6485ab96c1882c069229246162b02ebdbb605157a5bc65f`;
  structural reuse is not a substitute for that human storefront review.
- Apply the recorded Mac choice in
  `release-owner-decisions-2026-08-20.md`: ship the SwiftUI Mac Catalyst target
  through shared Apple ID `6800642443`, disable Designed for iPad on Mac, and
  leave the separate Tauri record `6800642853` unused for this release. Mac
  Catalyst still needs a signed build-8 archive, Mac QA, screenshots, signed
  parity, metadata, and named approval.
- Use `platforms/` for the platform-specific copy, review notes, planned
  screenshot manifests, and capture checklist. Use
  `app-store-connect-portal-audit-2026-08-22.md` for current planning. Retain
  `app-store-connect-portal-audit-2026-08-19.md` and
  `app-store-connect-portal-audit-2026-08-20.md` as historical audits only.
  The shared iOS, tvOS, and visionOS `1.1` drafts still have no selected build
  or screenshots; do not delete or duplicate them.
