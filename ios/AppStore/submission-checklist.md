# iOS App Store Connect pre-submission checklist

This is a version-controlled handoff checklist for the existing **QuakeSignal**
iOS record. It does not create a build, change App Store Connect, grant rights,
or authorize a submission. A checked box needs contemporaneous evidence in the
release record; do not check it merely because a source file contains an intended
value.

## Public-build and service gate

- [ ] Retain the exact signed public `Release` 1.1 archive/IPA, source
  commit, SHA-256, and `CFBundleVersion` `17`, including the embedded Watch app.
  Build-17 upload run IDs and the current handoff are recorded in
  `app-store-connect-build17-handoff-2026-08-24.md`; verify the selected
  App Store Connect builds against their signed attestations.
- [ ] Confirm that build `1.1 (17)` is not the legacy TestFlight `1.0 (2)`
  InternalQA-only evidence build and that it contains no delayed
  background-training control; retain the build-17 release-contract result.
- [ ] Confirm the App Attest version policy admits build `17` and record the
  live production service-metadata policy-fingerprint proof from the protected
  deployment and archive workflows. Do not substitute a build-12 or later
  unrelated live check for the source-bound proof.
- [ ] Complete the required physical-device/TestFlight evidence, including the
  production App Attest and APNs checks, then obtain the required protected
  production health/readiness proof before public launch promotion. Terminal-DLQ
  monitoring is an optional operational control, not a deployment attestation.
- [ ] Confirm the approved production endpoint, `/privacy`, `/support`, and
  intended `/terms` URL respond over public Cloudflare Web-PKI TLS. The
  build-12 source-bound deployment smoke proof is historical only. Do not use
  a private CA, origin certificate, or client certificate.

## Product page and review information

- [x] Open the existing iOS record (Apple ID `6800642443`) and verify its
  current portal state; do not create a duplicate record or a Universal Purchase
  claim for the distinct macOS bundle ID. See the 2026-08-24 audit.
- [x] Record the release owner's Mac route: SwiftUI Mac Catalyst in shared
  Apple ID `6800642443`, with Designed for iPad on Mac disabled and the Tauri
  record left unused. See `release-owner-decisions-2026-08-20.md`.
- [x] Save the shared Mac draft as `1.1` with exact Catalyst metadata, manual
  release, and Designed for iPad on Mac disabled (2026-08-22 portal audit).
- [ ] Complete Mac Catalyst QA, exact approved screenshots, signed-Release
  parity, availability, named independent approval, and App Store Connect
  processing confirmation. Build-12 signing and TestFlight processing are
  historical only; build-17 signed upload evidence is recorded separately.
- [ ] Verify the English name, category, bundle ID, SKU, version, copyright,
  exact `en-US/subtitle.txt`, and current build against
  `submission-answers.md` and the signed archive.
- [ ] Enter and visually confirm the complete App Review contact block during
  the final portal pass. The 2026-08-24 portal inspection found the email and
  phone fields blank; never copy personal values into source.
- [ ] Copy the exact current `review-notes.txt` content only after checking it
  against the selected public archive.
- [ ] During the final authenticated portal pass, copy and save the exact
  `en-US/whats_new_v1.1.txt` and `en-US/promotional_text.txt`, then visually
  re-open and verify both saved values. Do not infer a successful save from the
  checked-in files. Keep Japanese and Simplified Chinese What's New text
  unpublished with their unapproved localizations.
- [x] Confirm Free public distribution across 175 countries or regions.
- [ ] Choose final availability timing and any customer-facing Terms/EULA
  option only after release-owner approval.
- [ ] Keep Japanese and Simplified Chinese localizations unpublished until the
  exact display names, availability, and trademark review are approved.
- [x] Preserve the historical build-7/build-8 image sets without relabeling
  them. A complete five-platform Debug Simulator candidate was recaptured for
  source `93a5055e95551a39f89b771fa01cf44eea0fb62d` by run `32647878229`.
  It remains historical, explicitly unapproved, and non-uploadable.
- [ ] Retain the complete five-platform Debug Simulator candidate from run
  `32678113996` for the build-17 source as unapproved until the protected
  finalizer records named independent visual, privacy, and signed-Release
  parity review.
- [x] Save the exact tvOS and Mac Catalyst `1.1` copy recorded in the 2026-08-22
  portal audit.
- [ ] Resave the corrected visionOS description and review notes that distinguish
  platform support for App Attest from the unavailable APNs capability; the
  audit saved the superseded wording and is not evidence of this correction.
- [ ] Complete Apple Watch/tvOS/visionOS/Mac screenshot approval, remaining
  privacy/App Motion answers, and platform QA before submission. Build-17
  App Store Connect processing and all platform screenshot approvals remain
  pending; no platform screenshot is approved or attached.
  All four remain foreground-only in every independent-notification claim.
- [ ] Download only the exact source-addressed approved screenshot artifact from
  the successful finalizer run, upload the six source directories in the order
  specified by `apple-platform-release.md`, and retain an external receipt with
  the source SHA, capture/finalizer run URLs and IDs, artifact ID/name/digest,
  active manifest/approval hashes, upload time, and portal evidence showing all
  six saved counts and thumbnail order.
- [ ] Record named visual approval for the exact Watch icon digest pinned by
  `verify-store-assets.rb`; do not infer approval from catalog validity or from
  its deliberate reuse of the canonical iOS signal artwork.
- [ ] Complete the required visionOS App Motion answer from final-platform QA;
  do not infer the portal selection from source inspection alone.

## Privacy, rights, and Apple questionnaires

- [ ] Reconcile the final binary, privacy manifest, and current Apple App
  Privacy questionnaire wording. Do not select “Data Not Collected” solely
  because the app has no account.
- [ ] Complete the current Age Rating questionnaire from the final public build
  and product-page content.
- [ ] Complete Export Compliance for the final signed archive with the
  responsible legal/release owner.
- [x] Record the release owner's published-terms Content Rights basis and
  decision not to send the Wolfx request in `content-rights-evidence.md` and
  `release-owner-decisions-2026-08-20.md`.
- [ ] Record build 17's exact signed/deployed source inventory as `jma_eew` and `jma_eqlist`,
  with CENC, Sichuan, Fujian, and Chongqing feeds disabled in submitted Apple
  clients and relay policy. Record the official-source review supporting that
  narrowing and the implemented 89-day relay event/revision cleanup cutoff.
- [ ] At submission time, recheck the current Wolfx Terms of Service, Open API
  document version, JMA website terms, Public Data License 1.0, any specific
  notices, exact signed/deployed two-source inventory, direct client/relay
  routes, JMA attribution and normalized/edited statement, no-resale/no-public-
  feed behavior, next-successful-daily-cleanup behavior, non-predictive relay behavior, and intended
  territories. Retain **Yes** only for that reviewed JMA-only scope; do not
  claim that open source grants third-party rights, that a private Wolfx
  license exists, or that QuakeSignal issues an official forecast or warning.
  If Apple or a source asks for more, pause and narrow or obtain it.

## Final submission decision

- [ ] Have a release owner verify that every item above is complete, every
  required App Store Connect field matches the selected archive, and no
  protected production gate remains false.
- [ ] Only then attach the new public Release build to version `1.1` and submit
  it for App Review.
