# App Review resubmission checklist

This checklist preserves relevant history from the App Review Guideline 2.1
resubmission of version `1.0 (6)` on 15 August 2026. Historical completion of a
binary, attachment, contact, or portal action does not satisfy the Content
Rights gate for version `1.1 (8)` or any newly added Apple platform.

## Content Rights gate for every current submission

- [x] Prepared the ready-to-send request in
  `docs/WOLFX_PERMISSION_REQUEST.md`.
- [ ] Send the request from a UniSphereco LLC-controlled mailbox and retain the
  sent message and headers in the approved private release record.
- [ ] Receive and retain an affirmative written Wolfx reply covering the exact
  Apple platforms, persistent normalized-event/client-local storage,
  developer-operated notification relay, App Store territories, attribution,
  restrictions, duration, and termination intended for release.
- [ ] Confirm that Wolfx expressly has authority to permit every underlying
  feed, or obtain and retain an affirmative separate permission from every
  source rights holder that Wolfx identifies as outside its authority.
- [ ] Have an accountable reviewer record the reply's scope, attribution,
  restrictions, duration, termination, underlying-source authority or separate
  permissions, evidence reference, and review date in
  `content-rights-evidence.md`.
- [ ] Apply and verify any product, attribution, relay, caching, territory, or
  distribution changes required by the reply.
- [ ] Only after the preceding items are complete, reconcile and complete the
  Apple Content Rights certification for each submission.

**Current result: PENDING / SUBMISSION BLOCKER.** No affirmative written Wolfx
reply or separately required source permission is retained in the release
record. Published terms, public API documentation, an internal material-scope
rationale, a referral to another source without its permission, or a prior
affirmative portal selection must not be substituted for the required evidence.

## Historical 1.0 (6) review evidence

The following items describe the earlier Guideline 2.1 resubmission only:

- [x] Debug and Release simulator builds succeeded for version `1.0 (6)`.
- [x] All 26 automated tests passed on 15 August 2026.
- [x] Production health/readiness and customer-facing HTTPS endpoints passed.
- [x] A fresh-launch iPhone 17 Pro Simulator video on iOS 26.5 was captured and
  reviewed for framing and decoding errors.
- [ ] A physical-device video on the latest public iOS was not available; the
  simulator attachment did not establish physical-device behavior.
- [x] The accountable App Review email and phone number were confirmed for that
  historical submission.

Historical attachment:
`review-attachments/quakesignal-simulator-ios26.5-review.mp4`

- App: local simulator build, version `1.0 (6)`
- Captured: 15 August 2026
- Duration: 143.767 seconds
- Video: H.264, 1206 x 2622, 30 fps, yuv420p, no audio
- SHA-256:
  `8e3426687471690cb4816cd5856037dacb8c4a204008d29c2b8eac916b5a6169`

The recording showed launch, permission prompts, onboarding, live data, event
details, List, Map, Guide, Settings, and Sources & Disclaimer. It did not prove
TestFlight signing, physical-device APNs delivery, App Attest behavior, Wolfx
permission, or the version `1.1 (8)` release state.

The historical submission later displayed **Waiting for Review** with manual
release and submission ID `295fd2ba-11c4-4dc9-945b-2bf6a9fc7bbe`. Preserve
that as history only. Do not reuse its build, attachment, answers, checked
actions, or portal state as current release evidence.

## Version 1.1 (8) resubmission decision

- [ ] Complete every gate in `submission-checklist.md` and
  `release-v1.1-checklist.md` using the final signed build and current portal
  state.
- [ ] Confirm that `content-rights-evidence.md` contains the reviewed written
  permission described above.
- [ ] Obtain explicit action-time release-owner approval only after all
  required gates are complete.
- [ ] Only then attach and submit the intended platform build for App Review.
