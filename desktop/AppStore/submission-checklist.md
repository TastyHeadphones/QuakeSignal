# macOS App Store Connect pre-submission checklist

This is a version-controlled handoff checklist for **QuakeSignal for macOS**.
It does not create or update the App Store Connect record, upload a package,
grant content rights, or authorize a submission. A checked box requires
contemporaneous release evidence; source text alone is not proof of portal state
or external permission.

## Signed Mac App Store package and reviewer behavior

- [ ] Identify the exact signed sandboxed Mac App Store app/package, source
  commit, SHA-256, version, and build number accepted by App Store Connect.
- [ ] Treat a TestFlight build as beta evidence only. It does not establish
  that a signed sandboxed Mac App Store package is attached to this version or
  eligible for App Review.
- [ ] Verify the final package uses `com.quakesignal.desktop`, the intended
  UniSphereco LLC team, App Sandbox, and only the approved Mac App Store
  distribution path.
- [ ] On a supported Mac, verify the signed sandboxed build starts normally,
  receives foreground Wolfx updates, and behaves safely when feeds are delayed
  or unavailable.
- [ ] Verify the submitted build omits the direct-distribution Test Alarm and
  Launch at Login controls; do not use a direct build as Mac App Store evidence.
- [ ] Verify local alarms occur only from local feed evaluation while the app is
  running, and that the package contains no App Attest or APNs registration.
- [ ] If macOS presents notification permission, test both the optional allowed
  and denied paths. No account or reviewer credential should be required.

## Product page and review information

- [ ] Open the existing macOS record (Apple ID `6800642853`) and verify its
  current portal state; do not create a duplicate record or claim a Universal
  Purchase with the distinct iOS bundle ID.
- [ ] Preserve the editable 1.0.0 draft, existing Ready-to-Submit 1.0.0 build,
  four older screenshots, and their read-only evidence. Do not select the old
  build for review. Change that same draft to version `1.1.0` only if App Store
  Connect permits; otherwise stop and contact support. Do not delete the draft
  or create another Mac record.
- [ ] Leave the macOS draft inside iOS Apple ID `6800642443` untouched. Never
  attach the Tauri `com.quakesignal.desktop` package or metadata to it.
- [ ] Attach only the 1.1.0 package whose frozen source and hashes match this
  release.
- [ ] Verify the English name, category, bundle ID, SKU, version, copyright,
  and current build against `submission-answers.md` and the signed package.
- [ ] Enter an accountable UniSphereco LLC App Review contact name, email, and
  phone number.
- [ ] Copy the exact current `review-notes.txt` content only after checking it
  against the selected sandboxed package.
- [ ] Choose price, territories, availability timing, and any customer-facing
  Terms/EULA option only after release-owner approval.
- [ ] Keep non-English localizations unpublished until the exact display names,
  availability, and trademark review are approved.
- [ ] Replace the draft screenshot provenance with the signed-build evidence
  and approve all four uploaded frames against the selected package.

## Privacy, rights, and Apple questionnaires

- [ ] Reconcile the final package and every included dependency with the
  current Apple App Privacy questionnaire. Check any Wolfx third-party-service
  disclosure with the responsible release owner; do not infer “Data Not
  Collected” solely from the absence of accounts or analytics code.
- [ ] Complete the current Age Rating questionnaire from the final package and
  product-page content.
- [ ] Complete Export Compliance for the final signed package with the
  responsible legal/release owner.
- [ ] **Content Rights — PENDING:** obtain and retain written Wolfx permission
  for the intended App Store territories using
  `docs/WOLFX_PERMISSION_REQUEST.md`. Do not certify rights to Wolfx-supplied
  earthquake data before that written evidence exists.

## Final submission decision

- [ ] Have a release owner verify that every item above is complete and that
  every required App Store Connect field matches the selected signed package.
- [ ] Only then attach the package to the macOS version and submit it for App
  Review.
