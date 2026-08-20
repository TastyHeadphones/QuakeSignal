# Code signing policy

## Windows

QuakeSignal for Windows is distributed only through Microsoft Store as an MSIX
package. GitHub Actions builds the package on a version tag or in a manual
protected-main **Desktop release** run; only the explicitly approved manual
run can submit it to Microsoft Store. Microsoft Store performs certification
and re-signs the package before it is made available to customers. No Windows
signing key, certificate, or third-party signing service is used by this
repository or its CI.

The pre-certification MSIX artifact is retained only in the GitHub Actions run
that created it. It is not a public download, because it has not yet been
signed and hosted by Microsoft Store.

The workflow embeds the Partner Center-assigned MSIX identity and builds only
from the public `TastyHeadphones/QuakeSignal` repository. It runs the locked
Rust tests before packaging and refuses a tag whose version differs from
`desktop/src-tauri/tauri.conf.json`.

## macOS

> **Dormant for Apple release 1.1 build 8.** The sole current Mac storefront
> product is the shared SwiftUI Mac Catalyst target (`com.quakesignal.app`),
> to be built with automatic signing by the coordinated Xcode Cloud workflow.
> No Xcode Cloud signed build `8` exists yet. The
> Tauri direct/Homebrew and separate Tauri Mac App Store lanes documented
> below are retained only for a possible later release and must not be run,
> uploaded, or substituted for the Catalyst build in this release.

macOS has two deliberately separate distribution lanes in
[`.github/workflows/desktop-release.yml`](../.github/workflows/desktop-release.yml).
The direct/Homebrew lane publishes from a protected version tag; an explicit
protected-main manual run can also build its private validation artifact. The
Mac App Store lane is a separately approved protected-main manual action.
Neither lane falls back to an ad-hoc signature.

### Direct download and Homebrew

The `macos-direct` job runs in the protected `macos-direct-release` GitHub
Environment. It requires these environment secrets and variables:

- `MACOS_DEVELOPER_ID_CERTIFICATE` — base64-encoded Developer ID Application
  `.p12` certificate (**environment secret**)
- `MACOS_DEVELOPER_ID_CERTIFICATE_PASSWORD` — the `.p12` export password
  (**environment secret**)
- `MACOS_NOTARY_API_KEY` — App Store Connect **team** API private key contents
  (**environment secret**)
- `MACOS_NOTARY_API_KEY_ID` — App Store Connect team API key ID
  (**environment secret**; the workflow reads `secrets`, not `vars`)
- `MACOS_NOTARY_API_ISSUER` — App Store Connect API issuer ID
  (**environment secret**; the workflow reads `secrets`, not `vars`)
- `MACOS_DEVELOPER_ID_SIGNING_IDENTITY` — Environment variable containing the
  Developer ID Application signing identity

#### Account Holder preparation

The direct lane needs a locally exportable **Developer ID Application**
certificate. It cannot use an Apple Distribution certificate, a 3rd Party Mac
Developer Installer certificate, a Mac App Store provisioning profile, or a
cloud-managed-only certificate in place of the `.p12` input above.

Before the direct lane can be configured, the UniSphereco LLC Account Holder
must confirm that the Apple Developer Program membership and current agreements
are active, create a Developer ID Application certificate from a certificate
signing request in Certificates, Identifiers & Profiles, install it together
with its private key, and export the resulting identity as the `.p12` named
above. Apple reserves creation of a standard Developer ID certificate for the
Account Holder. The workflow later proves the actual signing authority is
`Developer ID Application`; it does not accept an App Store signing identity.

Notarization uses a **team** App Store Connect API key. Individual API keys
cannot use `notarytool`. The Account Holder must request App Store Connect API
access initially, but a team key whose role can notarize software (for example,
App Manager) can be reused after that approval. Keep its one-time-download
private `.p8` outside the repository and store it only as the protected
environment secret above.

Tauri signs the universal app with hardened runtime, submits it to Apple for
notarization through the API key, and staples the resulting ticket to the DMG.
The workflow verifies the code signature and stapled ticket. On a protected
version tag it then attaches only the DMG and its checksum to the public GitHub
Release; an explicit protected-main `build_macos_direct` run retains an Actions
artifact for validation and does not publish a GitHub Release. The Homebrew
cask must be updated only from the verified tagged release.

### Mac App Store

The `macos-app-store` job runs in the separately protected
`macos-app-store-release` GitHub Environment. It builds the same universal app
with [`Entitlements.macos-app-store.plist`](../desktop/src-tauri/Entitlements.macos-app-store.plist),
which enables App Sandbox and outbound network access, and embeds a Mac App
Store Connect provisioning profile. It needs:

- `MACOS_APP_STORE_APPLICATION_CERTIFICATE` and
  `MACOS_APP_STORE_APPLICATION_CERTIFICATE_PASSWORD` — Apple Distribution
  `.p12` credentials for the app
- `MACOS_APP_STORE_INSTALLER_CERTIFICATE` and
  `MACOS_APP_STORE_INSTALLER_CERTIFICATE_PASSWORD` — Mac Installer Distribution
  `.p12` credentials for the package
- `MACOS_APP_STORE_PROVISIONING_PROFILE` — base64-encoded Mac App Store Connect
  provisioning profile for `com.quakesignal.desktop`
- `MACOS_APP_STORE_APPLICATION_IDENTITY` and
  `MACOS_APP_STORE_INSTALLER_IDENTITY` — protected Environment variables naming
  the imported identities
- `MACOS_APP_STORE_CONNECT_API_KEY` — App Store Connect API private `.p8` key
  contents, stored as a protected environment secret
- `MACOS_APP_STORE_CONNECT_API_KEY_ID` and
  `MACOS_APP_STORE_CONNECT_API_ISSUER` — protected Environment variables for
  that App Store Connect API key

The resulting signed `.pkg` is a private Actions artifact, not a GitHub Release
asset. It contains no signing key. A trusted maintainer can run **Desktop
release** with `upload_macos_to_app_store_connect` enabled; the protected lane
validates the package and uploads it to App Store Connect. Do this only after
the Mac App Store record, screenshots, and review metadata are ready. The Mac
App Store profile's App ID Prefix must match the values in the entitlement
template; if Apple shows a different prefix, update the template and profile
together.

The App Store build intentionally omits the direct build's legacy
LaunchAgent-based “Launch at Login” setting because it writes outside App
Sandbox. It remains available in the notarized direct-download build.

## Privacy

The Windows desktop app is local-first: it has no account, advertising,
analytics, crash reporting, or telemetry. It connects directly to the public
Wolfx earthquake data service. The complete policy is in
[`docs/PRIVACY.md`](PRIVACY.md).
