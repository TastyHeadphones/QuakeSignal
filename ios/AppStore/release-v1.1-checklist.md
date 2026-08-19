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
  `reviewer: null`; named visual approval and signed public-Release parity are
  still pending. Keep `ja` and `zh-Hans` unpublished until the product-page
  name, availability, and trademark approvals are recorded.
- Copy the matching `whats_new_v1.1.txt` only into each approved localization.
- Preserve `screenshot-provenance-v1.1.json` as truthful build-7 simulator
  evidence. Its 30 matching hashes do not authorize a build-8 upload. The
  separate build-8 candidate hashes likewise do not authorize upload until the
  named review and signed-Release parity gates are complete.
- No current iPhone or iPad screenshot is approved for a build-8 upload.
- Deploy all D1 migrations through 0011 and the build-8 Worker contract first.
  Confirm the production health endpoint accepts App Attest bundle versions
  1–8.
- Upload only the public `Release` archive. Never submit the `InternalQA`
  configuration, whose controlled delayed training control is intentionally
  excluded from the public build.
- Complete physical-device App Attest, APNs foreground/background/terminated,
  notification-sound, Silent Mode/Focus, location, and iPad QA before public
  submission.
- Obtain and review an affirmative written Wolfx permission reply for the
  intended Apple platforms, persistent normalized-event/client-local storage,
  developer-operated notification relay, App Store territories, attribution,
  restrictions, duration, and termination. The reply must also confirm Wolfx's
  authority over every underlying feed, or every separately required source
  permission must be obtained and reviewed. The ready-to-send request draft is
  not permission. Keep Content Rights certification and every platform
  submission blocked until `content-rights-evidence.md` records the complete
  evidence. Separately confirm the App Review contact fields.
- Follow `apple-platform-release.md` for the iOS+embedded-Watch, tvOS, and
  visionOS protected archive lanes. Do not upload a native platform until its
  store-complete icon set, screenshots, profile, metadata, and platform QA are
  approved. The separate Tauri macOS client retains its own App Store record.
- Use `platforms/` for the platform-specific copy, review notes, planned
  screenshot manifests, and capture checklist. Use
  `app-store-connect-portal-audit-2026-08-19.md` to resolve the observed empty
  platform drafts without deleting or creating duplicate records.
