QuakeSignal is a free, open source earthquake early-warning monitor for Windows
and macOS. It connects directly to public seismic feeds, frames each event
against a location you choose, and raises a native alarm from the system tray
when a warning affects that location. It is local-first: your event history and
preferences stay on your own computer, with no account, no server, and no
telemetry.

> [!IMPORTANT]
> QuakeSignal is an independent, non-official app. Earthquake information comes
> from third-party aggregated sources and may be delayed, incomplete, revised,
> or inaccurate. Always follow official announcements and local emergency
> instructions.

## Downloads

| Platform | File |
|---|---|
| Windows (installer) | `QuakeSignal_@@VERSION@@_x64-setup.exe` |
| Windows (MSI) | `QuakeSignal_@@VERSION@@_x64_en-US.msi` |
| macOS (universal) | `QuakeSignal_@@VERSION@@_universal.dmg` |

Installation and uninstallation instructions are in the
[README](https://github.com/@@REPO@@#readme). macOS users: this build is not
notarized — see [Installation on macOS](https://github.com/@@REPO@@#installation-on-macos)
for the one-time step needed to open it.

## Verifying your download

Every file in this release is listed in `SHA256SUMS.txt`. Download it alongside
the artifact and check the hash before installing:

```bash
# macOS
shasum -a 256 -c SHA256SUMS.txt

# Linux
sha256sum -c SHA256SUMS.txt
```

```powershell
# Windows
Get-FileHash .\QuakeSignal_@@VERSION@@_x64-setup.exe -Algorithm SHA256
```

@@CHECKSUMS@@

## Code signing policy

@@SIGNING_STATUS@@

QuakeSignal's full code signing policy — what is signed, how releases are
built, who may approve a signature, and what the app does with your data — is
published at
[docs/SIGNING.md](https://github.com/@@REPO@@/blob/@@TAG@@/docs/SIGNING.md).
Privacy is documented separately at
[docs/PRIVACY.md](https://github.com/@@REPO@@/blob/@@TAG@@/docs/PRIVACY.md).

Free code signing provided by [SignPath.io](https://signpath.io?utm_source=foundation&utm_medium=github&utm_campaign=quakesignal), certificate by [SignPath Foundation](https://signpath.org/).

---

@@GENERATED_NOTES@@
