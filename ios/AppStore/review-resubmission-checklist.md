# App Review resubmission checklist

This checklist preserves relevant history from the App Review Guideline 2.1
resubmission of version `1.0 (6)` on 15 August 2026. Historical completion of a
binary, attachment, contact, or portal action does not satisfy the Content
Rights gate for version `1.1 (8)` or any newly added Apple platform.

## Content Rights gate for every current submission

- [x] Retain the release owner's 20 August 2026 decision not to send the Wolfx
  request and not to represent that a private written license exists.
- [x] Review the current Wolfx Terms of Service, Open API documentation, JMA
  website terms, Public Data License 1.0, JMA forecasting guidance, and exact
  QuakeSignal product use in `content-rights-evidence.md`.
- [x] Confirm the reviewed release remains free, attributed, independent and
  non-official; uses factual documented fields; does not reproduce Wolfx
  documentation, logos, or JMA `OriginalText`; and exposes no public secondary
  earthquake feed or resale/paywall.
- [x] Narrow build 8 to exactly `jma_eew` and `jma_eqlist`; disable
  `cenc_eew`, `cenc_eqlist`, `sc_eew`, `fj_eew`, and `cq_eew` in submitted
  Apple clients and relay policy and remove their current release claims.
- [x] Record the official CENC, Sichuan, Fujian, and Chongqing sources reviewed
  and the reason those feeds are excluded from build 8.
- [x] Enforce and document the relay's 89-day normalized-event and
  event-revision cleanup cutoff, ordered daily cleanup, and possible
  operational delay.
- [x] Record that radius and magnitude are delivery filters only: build 8 does
  not calculate predicted local intensity or ground-motion arrival and does
  not present a QuakeSignal-authored official warning.
- [ ] At action time, recheck the published terms/document versions, enabled
  sources, direct client/relay routes, product behavior, JMA attribution and
  edited-content notice, 89-day-cutoff cleanup, and intended App Store territories.
- [ ] If Apple requests authorization beyond the published terms, or Wolfx/an
  upstream source objects or changes its terms, pause the affected source or
  territories and narrow the release or obtain additional authorization.
- [ ] Have the release owner reconcile the Apple Content Rights answer only for
  the exact reviewed scope; do not claim that open-source licensing alone grants
  third-party rights.

**Current result: JMA-ONLY PUBLISHED-TERMS MAPPING RECORDED.** Written Wolfx
outreach is not required by the release-owner decision. Content Rights still
requires final signed-artifact/deployed-relay verification, action-time terms
and territory review, portal reconciliation, and accountable release approval;
the previously observed portal **Yes** is not evidence by itself.

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
TestFlight signing, physical-device APNs delivery, App Attest behavior, the
current published-terms mapping, or the version `1.1 (8)` release state.

The historical submission later displayed **Waiting for Review** with manual
release and submission ID `295fd2ba-11c4-4dc9-945b-2bf6a9fc7bbe`. Preserve
that as history only. Do not reuse its build, attachment, answers, checked
actions, or portal state as current release evidence.

## Version 1.1 (8) resubmission decision

- [ ] Complete every gate in `submission-checklist.md` and
  `release-v1.1-checklist.md` using the final signed build and current portal
  state.
- [ ] Complete, recheck, and confirm the published-terms content-rights mapping
  described above against the final signed JMA-only sources, deployed 89-day
  cutoff and next-successful-daily-cleanup behavior, disclosed operational
  delay, non-predictive relay behavior, attribution, scope, and territories.
- [ ] Obtain explicit action-time release-owner approval only after all
  required gates are complete.
- [ ] Only then attach and submit the intended platform build for App Review.
