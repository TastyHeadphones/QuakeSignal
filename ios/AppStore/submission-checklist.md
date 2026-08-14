# iOS App Store Connect pre-submission checklist

This is a version-controlled handoff checklist for the existing **QuakeSignal**
iOS record. It does not create a build, change App Store Connect, grant rights,
or authorize a submission. A checked box needs contemporaneous evidence in the
release record; do not check it merely because a source file contains an intended
value.

## Public-build and service gate

- [ ] Identify the exact signed public `Release` archive/IPA, source commit,
  SHA-256, and `CFBundleVersion` of at least `3`.
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
- [ ] Verify the English name, category, bundle ID, SKU, version, copyright,
  and current build against `submission-answers.md` and the signed archive.
- [ ] Enter an accountable UniSphereco LLC App Review contact name, email, and
  phone number.
- [ ] Copy the exact current `review-notes.txt` content only after checking it
  against the selected public archive.
- [ ] Choose price, territories, availability timing, and any customer-facing
  Terms/EULA option only after release-owner approval.
- [ ] Keep Japanese and Simplified Chinese localizations unpublished until the
  exact display names, availability, and trademark review are approved.
- [ ] Replace the draft screenshot provenance with signed-public-build evidence
  and visually approve one consistent 6.5-inch set for every uploaded locale.

## Privacy, rights, and Apple questionnaires

- [ ] Reconcile the final binary, privacy manifest, and current Apple App
  Privacy questionnaire wording. Do not select “Data Not Collected” solely
  because the app has no account.
- [ ] Complete the current Age Rating questionnaire from the final public build
  and product-page content.
- [ ] Complete Export Compliance for the final signed archive with the
  responsible legal/release owner.
- [ ] **Content Rights — PENDING:** obtain and retain written Wolfx permission
  for the intended App Store territories using
  `docs/WOLFX_PERMISSION_REQUEST.md`. Do not certify rights to Wolfx-supplied
  earthquake data before that written evidence exists.

## Final submission decision

- [ ] Have a release owner verify that every item above is complete, every
  required App Store Connect field matches the selected archive, and no
  protected production gate remains false.
- [ ] Only then attach the new public Release build to version `1.0` and submit
  it for App Review.
