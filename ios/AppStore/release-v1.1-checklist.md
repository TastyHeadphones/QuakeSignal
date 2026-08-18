# QuakeSignal 1.1 App Store release

This checklist is the release-specific source of truth for marketing version
`1.1`, build `7`. It does not replace the legal and physical-device approvals
recorded in the existing submission documents.

> Do not use the legacy unversioned screenshot paths for this release; they
> describe the earlier iPhone-only 1.0 asset set.

- Use `screenshot-manifest-v1.1.json`, not the earlier 1.0 manifest.
- Upload the five JPEGs in `screenshots-v1.1/<locale>/iphone-6.5/` for each of
  `en-US`, `ja`, and `zh-Hans`.
- Upload the five JPEGs in `screenshots-v1.1/<locale>/ipad-13/` for each locale.
- Copy the matching `whats_new_v1.1.txt` into each localization.
- Confirm `screenshot-provenance-v1.1.json` names the frozen release source and
  that all 30 file hashes still match immediately before upload.
- Deploy D1 migration 0010 and the build-7 Worker contract first. Confirm the
  production health endpoint accepts App Attest bundle versions 1–7.
- Upload only the public `Release` archive. Never submit the `InternalQA`
  configuration, whose controlled delayed training control is intentionally
  excluded from the public build.
- Complete physical-device App Attest, APNs foreground/background/terminated,
  notification-sound, Silent Mode/Focus, location, and iPad QA before public
  submission.
- Confirm current content-rights evidence and the App Review contact fields.
- Release the iOS/iPadOS binary only for platforms it supports: iPhone, iPad,
  Designed for iPhone/iPad on Apple-silicon Mac, and compatible Vision Pro.
  Native macOS, tvOS, and watchOS require their own targets and binaries.
