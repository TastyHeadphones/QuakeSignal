# iOS App Store Connect pre-submission checklist

This is a version-controlled handoff checklist for the existing **QuakeSignal**
iOS record. It does not create a build, change App Store Connect, grant rights,
or authorize a submission. A checked box needs contemporaneous evidence in the
release record; do not check it merely because a source file contains an intended
value.

## Public-build and service gate

- [ ] Identify the exact signed public `Release` 1.1 archive/IPA, source
  commit, SHA-256, and `CFBundleVersion` `8`, including the embedded Watch app.
- [ ] Confirm that this is not the legacy TestFlight `1.0 (2)` InternalQA-only
  evidence build and that it contains no delayed background-training control.
- [ ] Confirm the App Attest version policy admits exactly that public build and
  record the live production `/healthz` policy-fingerprint proof from the
  protected archive workflow.
- [ ] Complete the required physical-device/TestFlight evidence, including the
  production App Attest and APNs checks, then obtain the required protected
  production health/readiness proof before public launch promotion. Terminal-DLQ
  monitoring is an optional operational control, not a deployment attestation.
- [ ] Confirm the approved production endpoint, `/privacy`, `/support`, and
  any intended `/terms` URL respond over public Cloudflare Web-PKI TLS. Do not
  use a private CA, origin certificate, or client certificate.

## Product page and review information

- [ ] Open the existing iOS record (Apple ID `6800642443`) and verify its
  current portal state; do not create a duplicate record or a Universal Purchase
  claim for the distinct macOS bundle ID.
- [x] Record the release owner's Mac route: SwiftUI Mac Catalyst in shared
  Apple ID `6800642443`, with Designed for iPad on Mac disabled and the Tauri
  record left unused. See `release-owner-decisions-2026-08-20.md`.
- [ ] Complete Mac Catalyst automatic signing, Mac QA, exact screenshots,
  metadata, signed-Release parity, availability, and named approval.
- [ ] Verify the English name, category, bundle ID, SKU, version, copyright,
  exact `en-US/subtitle.txt`, and current build against
  `submission-answers.md` and the signed archive.
- [ ] Enter an accountable UniSphereco LLC App Review contact name, email, and
  phone number.
- [ ] Copy the exact current `review-notes.txt` content only after checking it
  against the selected public archive.
- [ ] Choose price, territories, availability timing, and any customer-facing
  Terms/EULA option only after release-owner approval.
- [ ] Keep Japanese and Simplified Chinese localizations unpublished until the
  exact display names, availability, and trademark review are approved.
- [ ] Freeze `screenshot-provenance-v1.1.json`, verify all 30 hashes, and
  preserve it as historical build-7 evidence. Do not relabel those 30 images as
  build 8. Validate the separate ten-file English build-8 Debug Simulator
  candidate manifest, build-input evidence, and hashes as historical capture
  evidence only. It predates the current source. Recapture the exact final
  build-8 commit, then separately obtain named visual approval and signed
  public-Release parity before any upload.
- [ ] Complete the Apple Watch, tvOS, visionOS, and Mac Catalyst metadata,
  screenshot, icon, signing, and platform-QA gates in `platforms/` before
  submitting those experiences. tvOS, visionOS, Watch, and Mac Catalyst must
  remain foreground-only in every independent-notification claim.
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
- [x] Record build 8's exact source inventory as `jma_eew` and `jma_eqlist`,
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
