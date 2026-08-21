QuakeSignal is a free, open-source earthquake monitor for Windows and macOS.
It connects directly to public seismic feeds, keeps event history and
preferences on your device, and has no account or telemetry.

> [!IMPORTANT]
> QuakeSignal is an independent, non-official app. Earthquake information may
> be delayed, incomplete, revised, or inaccurate. Always follow official
> emergency instructions.

## Downloads

| Platform | Download |
|---|---|
| Windows | [Microsoft Store](https://apps.microsoft.com/detail/9N730S3CZ7Z9) |
| macOS (universal) | `QuakeSignal_@@VERSION@@_universal.dmg` |

The Windows app is an MSIX package distributed and signed by Microsoft Store
after certification. The macOS direct-download build is Developer ID signed,
notarized, and stapled. The dormant, separate Tauri Mac App Store lane never
retains its signed package in GitHub Actions; it keeps verification logs and a
SHA-256 digest, then deletes the package. Signed-build visual approval remains
blocked until a release owner approves a separate private handoff; only after
that approval can the same verified package be sent directly to App Store
Connect.

## Verifying this release

Every downloadable file in this GitHub Release is listed in `SHA256SUMS.txt`.

@@CHECKSUMS@@

## Code signing policy

Windows packages are built by GitHub Actions and signed by Microsoft Store
after certification. The full policy is in
[docs/SIGNING.md](https://github.com/@@REPO@@/blob/@@TAG@@/docs/SIGNING.md).
Privacy is documented in
[docs/PRIVACY.md](https://github.com/@@REPO@@/blob/@@TAG@@/docs/PRIVACY.md).

---

@@GENERATED_NOTES@@
