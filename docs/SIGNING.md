# Code signing policy

## Windows

QuakeSignal for Windows is distributed only through Microsoft Store as an MSIX
package. GitHub Actions builds the package from a version tag; Microsoft Store
performs certification and re-signs the package before it is made available to
customers. No Windows signing key, certificate, or third-party signing service
is used by this repository or its CI.

The pre-certification MSIX artifact is retained only in the GitHub Actions run
that created it. It is not a public download, because it has not yet been
signed and hosted by Microsoft Store.

The workflow embeds the Partner Center-assigned MSIX identity and builds only
from the public `TastyHeadphones/QuakeSignal` repository. It runs the locked
Rust tests before packaging and refuses a tag whose version differs from
`desktop/src-tauri/tauri.conf.json`.

## macOS

macOS builds are ad-hoc signed only and are not notarized by Apple. They are
published separately as universal DMG files. See the installation guidance in
the [README](../README.md#installation-on-macos).

## Privacy

The Windows desktop app is local-first: it has no account, advertising,
analytics, crash reporting, or telemetry. It connects directly to the public
Wolfx earthquake data service. The complete policy is in
[`docs/PRIVACY.md`](PRIVACY.md).
