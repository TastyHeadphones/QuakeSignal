# Code signing policy

This document is the code signing policy for **QuakeSignal**. It describes what
is signed, how it is signed, who may authorise a signature, and what the signed
software does with your data.

QuakeSignal is an independent open source project. Its source code is public at
<https://github.com/TastyHeadphones/QuakeSignal> and it is distributed under the
[MIT License](../LICENSE).

> [!NOTE]
> **Current status.** Windows signing through SignPath Foundation is configured
> in CI but not yet active — the Foundation application is pending. Until it is
> approved, Windows artifacts are published unsigned and each release says so.
> macOS artifacts are not yet signed with an Apple Developer ID and are not
> notarized. See [Adding Apple signing later](#adding-apple-signing-later).

---

## What gets signed

| Artifact | Platform | Signed | Signature type |
|---|---|---|---|
| `QuakeSignal_<version>_x64-setup.exe` (NSIS installer) | Windows | Yes | Authenticode, RFC 3161 timestamped |
| `QuakeSignal_<version>_x64_en-US.msi` (MSI installer) | Windows | Yes | Authenticode, RFC 3161 timestamped |
| `QuakeSignal.exe` (main application binary, inside both installers) | Windows | Yes | Authenticode, RFC 3161 timestamped |
| `QuakeSignal_<version>_universal.dmg` | macOS | No | Ad-hoc signature only (see below) |

Only the Windows installers and the Windows application executable published on
the project's [GitHub Releases](https://github.com/TastyHeadphones/QuakeSignal/releases)
page are code signed. Nothing else is signed with the project's certificate.

Every release also publishes a `SHA256SUMS.txt` listing a SHA-256 checksum for
every artifact in that release.

### RFC 3161 timestamping

All Windows signatures carry an RFC 3161 timestamp applied by SignPath's
timestamp authority. A timestamped signature remains verifiable after the
signing certificate expires. The release workflow fails the build if any
published Windows artifact lacks a timestamp.

---

## Build and signing process

Every published binary is produced by GitHub Actions from a version tag on the
public repository, by
[`.github/workflows/desktop-release.yml`](../.github/workflows/desktop-release.yml).

- **CI-built only.** Artifacts are never built on, or uploaded from, a
  maintainer's machine. The workflow has no `pull_request` trigger, so a fork
  can never reach the signing steps. Signing additionally requires that the run
  is a `v*` tag push on `TastyHeadphones/QuakeSignal`.
- **The project never holds a private key.** The Windows signing key is
  generated and held by SignPath in a hardware security module (HSM). It cannot
  be exported, and it is not present in this repository, in CI, or on any
  maintainer's machine. GitHub Actions holds only an API token that can *submit*
  a signing request; every request is subject to the approval rules below.
- **The certificate belongs to SignPath Foundation.** It is an OV code signing
  certificate issued by Sectigo to SignPath Foundation, not to this project and
  not to any individual or company. SignPath Foundation vouches for the fact
  that the binary was built from this public repository. Consequently the
  publisher shown by Windows SmartScreen and UAC reads **SignPath Foundation** —
  not "QuakeSignal". That is expected, not a misconfiguration.
- **Reproducible inputs.** All third-party GitHub Actions are pinned by commit
  SHA. Rust and npm dependencies are resolved from committed lockfiles
  (`Cargo.lock`, `package-lock.json`), and the Rust test suite runs with
  `--locked`.
- **Version consistency.** The workflow refuses to build if the Git tag does not
  match `version` in `desktop/src-tauri/tauri.conf.json`. Product name, version,
  and publisher metadata are set from that file for every signed binary.

### Two-pass Windows signing

The NSIS and MSI installers embed `QuakeSignal.exe`, so the application binary
must already carry its signature before the installers are built. The workflow
therefore signs twice:

1. `tauri build --no-bundle` compiles `QuakeSignal.exe` without packaging it.
2. That binary is submitted to SignPath and the signed copy replaces it on disk.
3. `tauri bundle` builds the NSIS installer and the MSI around the signed binary.
4. Both installers are submitted to SignPath in a second signing request.
5. The workflow verifies each returned file with `Get-AuthenticodeSignature`,
   requiring status `Valid` and a present timestamp, then publishes the release.

### Origin verification

SignPath verifies that each signing request genuinely originates from a GitHub
Actions run of this repository, not merely from possession of the API token.

The repository-side half of that policy lives in
[`.signpath/policies/`](../.signpath/policies/) and is enforced by SignPath on
every signing request.

---

## Team roles

QuakeSignal is a single-maintainer project. All three SignPath roles are held by
the maintainer, [@TastyHeadphones](https://github.com/TastyHeadphones).

| Role | Members | Responsibility |
|---|---|---|
| **Authors** | [@TastyHeadphones](https://github.com/TastyHeadphones) | May modify source code in the repository without additional review. |
| **Reviewers** | [@TastyHeadphones](https://github.com/TastyHeadphones) | Reviews every change proposed by anyone who is not an Author. |
| **Approvers** | [@TastyHeadphones](https://github.com/TastyHeadphones) | Decides whether a given release may be code signed. |

Because there is exactly one maintainer, the following applies explicitly:

- **Every external pull request is reviewed by the maintainer before merge.**
  No contributor other than the maintainer has write access to the repository,
  and no change reaches a release branch or tag without the maintainer's review.
- **Every signing request requires explicit maintainer approval.** Signing is
  not automatic on tag push: the release workflow submits a request, and that
  request stays queued in SignPath until the maintainer approves it by hand.
  An API token alone cannot cause a signature to be issued.

All team members use multi-factor authentication for both their GitHub account
and their SignPath account.

If additional maintainers join the project, this section will be updated before
they are granted any SignPath role.

---

## Privacy

QuakeSignal for desktop is a local-first application. It does not create
accounts, does not register devices, and contains no telemetry, analytics,
advertising, or crash-reporting service.

**Network access.** The application connects directly to the public Wolfx
earthquake data service, and to nothing else:

- `wss://ws-api.wolfx.jp` — live earthquake feeds over encrypted WebSockets
- `https://api.wolfx.jp` — recent earthquake history over HTTPS

No earthquake data is routed through a QuakeSignal server. The desktop
application does not use the project's Cloudflare notification backend at all.
As with any direct network request, Wolfx may receive ordinary connection
metadata such as an IP address, under its own policies.

**Local storage.** Event history and preferences are stored only on the user's
own computer, under the application data directory for
`com.quakesignal.desktop`:

- macOS — `~/Library/Application Support/com.quakesignal.desktop/`
- Windows — `%APPDATA%\com.quakesignal.desktop\`

Uninstalling the application and deleting that directory removes all stored
data.

**Installation.** The installers make no changes outside the application's own
install location and data directory, and both the NSIS and MSI packages provide
a standard uninstaller.

The related privacy policy for the Chrome extension is at
[`extension/PRIVACY.md`](../extension/PRIVACY.md).

---

## macOS: current state

macOS builds are **not** signed with an Apple Developer ID and are **not**
notarized, because the project does not yet hold an Apple Developer Program
membership.

CI applies an *ad-hoc* signature (`APPLE_SIGNING_IDENTITY: "-"`). This is not a
trust signal and does not satisfy Gatekeeper; it exists only because Apple
silicon refuses to execute unsigned native `arm64` code at all. macOS will still
report the app as damaged or from an unidentified developer on first launch.

This has a distribution consequence worth stating plainly: Homebrew has removed
the `--no-quarantine` flag, and **from 1 September 2026 Homebrew will disable
every cask in the official `homebrew/cask` tap that fails Gatekeeper checks**
([Homebrew/brew#20755](https://github.com/Homebrew/brew/issues/20755)).
QuakeSignal therefore cannot be submitted to the official tap while it is
unnotarized. Until notarization exists, macOS users install from the project's
own tap, which documents the quarantine step — see
[`packaging/homebrew-tap/`](../packaging/homebrew-tap/) and the
[Installation on macOS](../README.md#installation-on-macos) section of the
README.

### Adding Apple signing later

Once an Apple Developer Program membership exists, macOS signing and
notarization become a matter of supplying environment variables. The hook point
is the `Build universal macOS bundles` step in
[`desktop-release.yml`](../.github/workflows/desktop-release.yml), which already
carries a commented block listing them.

What changes:

1. Remove the ad-hoc `APPLE_SIGNING_IDENTITY: "-"`.
2. Add a keychain step before the build that imports the Developer ID
   certificate from `APPLE_CERTIFICATE` / `APPLE_CERTIFICATE_PASSWORD`.
3. Provide these variables to the build step. Tauri performs Developer ID
   signing and notarization itself when they are present — no other workflow
   change is required.

| Variable | What it is | Where to get it |
|---|---|---|
| `APPLE_CERTIFICATE` | Base64 of the *Developer ID Application* certificate `.p12` | Xcode → Settings → Accounts → Manage Certificates, then export and `base64 -i cert.p12` |
| `APPLE_CERTIFICATE_PASSWORD` | Password chosen when exporting the `.p12` | You choose it at export time |
| `APPLE_SIGNING_IDENTITY` | e.g. `Developer ID Application: Your Name (TEAMID)` | `security find-identity -v -p codesigning` |
| `APPLE_API_ISSUER` | App Store Connect API issuer UUID | App Store Connect → Users and Access → Integrations → Keys |
| `APPLE_API_KEY` | App Store Connect API key ID | Same page as the issuer ID |
| `APPLE_API_KEY_PATH` | Path to the downloaded `AuthKey_<id>.p8` on the runner | Written from a secret during the workflow run |

4. Once builds are notarized and stapled, the cask's `caveats` block in
   `packaging/homebrew-tap/Casks/quakesignal.rb` should be removed, and the cask
   becomes eligible for submission to the official `homebrew/cask` tap.

---

## Verifying a signature yourself

**Windows** (PowerShell):

```powershell
Get-AuthenticodeSignature .\QuakeSignal_0.1.0_x64-setup.exe | Format-List Status, SignerCertificate, TimeStamperCertificate
```

Status must be `Valid`, `TimeStamperCertificate` must not be empty, and
`SignerCertificate` must be the SignPath Foundation certificate — the publisher
Windows displays is `SignPath Foundation`, for the reason given under
[Build and signing process](#build-and-signing-process).

**Checksums** (any platform), against the `SHA256SUMS.txt` published with each
release:

```bash
sha256sum -c SHA256SUMS.txt
```

---

## SignPath configuration

These values are supplied to CI. None of them is a private key.

| Kind | Name | Purpose |
|---|---|---|
| Secret | `SIGNPATH_API_TOKEN` | Submits signing requests. Cannot approve them. |
| Variable | `SIGNPATH_ORGANIZATION_ID` | SignPath organization identifier |
| Variable | `SIGNPATH_PROJECT_SLUG` | SignPath project slug |
| Variable | `SIGNPATH_SIGNING_POLICY_SLUG` | Signing policy (e.g. `release-signing`) |
| Variable | `SIGNPATH_ARTIFACT_CONFIG_APP` | Artifact configuration for `QuakeSignal.exe` |
| Variable | `SIGNPATH_ARTIFACT_CONFIG_INSTALLERS` | Artifact configuration for the NSIS and MSI installers |

If `SIGNPATH_API_TOKEN` is present but any of the variables is missing, the
release workflow fails immediately with the names of the missing variables,
before the Rust build runs — rather than failing later inside the signing step.

### Artifact configurations

The two artifact configurations are versioned in this repository:

| File | Variable | Signing pass |
|---|---|---|
| [`.signpath/artifact-configurations/windows-app.xml`](../.signpath/artifact-configurations/windows-app.xml) | `SIGNPATH_ARTIFACT_CONFIG_APP` | 1 — application binary |
| [`.signpath/artifact-configurations/windows-installers.xml`](../.signpath/artifact-configurations/windows-installers.xml) | `SIGNPATH_ARTIFACT_CONFIG_INSTALLERS` | 2 — NSIS installer and MSI |

SignPath does **not** read these from the repository — only the signing policy
under `.signpath/policies/` is read from the repo. Paste each file's contents
into the SignPath web UI under *Project → Artifact Configurations → Add →
Enter XML*, and give each the slug named in the table above.

Both use a `<zip-file>` root element, because `actions/upload-artifact` uploads
a ZIP archive. The installer configuration wildcards the version segment so it
survives version bumps. `QuakeSignal.exe` inside the installers is deliberately
not re-signed, because pass 1 already signed it.

---

## Attribution

Free code signing provided by [SignPath.io](https://signpath.io?utm_source=foundation&utm_medium=github&utm_campaign=quakesignal),
certificate by [SignPath Foundation](https://signpath.org/).

---

## Reporting a problem

Report a suspected malicious or incorrectly signed QuakeSignal binary through
the [issue tracker](https://github.com/TastyHeadphones/QuakeSignal/issues).
