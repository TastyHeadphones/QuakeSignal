# QuakeSignal 1.1 App Store release

This checklist is the release-specific source of truth for marketing version
`1.1`, build `8`. It does not replace the legal and physical-device approvals
recorded in the existing submission documents.

> Do not use the legacy unversioned screenshot paths for this release; they
> describe the earlier iPhone-only 1.0 asset set.

- Use `screenshot-manifest-v1.1-build8.template.json` only to plan a future
  build-8 manifest. Do not upload from the template or any existing screenshot
  directory.
- After the build-8 source is frozen, recapture the five planned iPhone and five
  planned 13-inch iPad frames into a new `screenshots-v1.1-build8/<locale>/`
  set, then create new manifest/provenance files with exact native-device
  evidence and hashes. Keep `ja` and `zh-Hans` unpublished until the
  product-page name, availability, and trademark approvals are recorded.
- Copy the matching `whats_new_v1.1.txt` only into each approved localization.
- Preserve `screenshot-provenance-v1.1.json` as truthful build-7 simulator
  evidence. Its 30 matching hashes do not authorize a build-8 upload. Recapture
  from the frozen build-8 source into a new versioned set and approve new hashes
  and provenance before upload.
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
- Confirm current content-rights evidence and the App Review contact fields.
- Follow `apple-platform-release.md` for the iOS+embedded-Watch, tvOS, and
  visionOS protected archive lanes. Do not upload a native platform until its
  store-complete icon set, screenshots, profile, metadata, and platform QA are
  approved. The separate Tauri macOS client retains its own App Store record.
- Use `platforms/` for the platform-specific copy, review notes, planned
  screenshot manifests, and capture checklist. Use
  `app-store-connect-portal-audit-2026-08-19.md` to resolve the observed empty
  platform drafts without deleting or creating duplicate records.
