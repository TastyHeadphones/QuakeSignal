# Microsoft Store distribution

QuakeSignal's Windows release workflow can submit the signed MSI installer to
Microsoft Partner Center after creating a GitHub Release.

The Store job runs only for a `v*` tag in the upstream repository, only after
the Windows installers have been signed, and only when the Store configuration
below exists. Manual workflow runs and unsigned test builds do not submit to
Partner Center.

## One-time Partner Center setup

The app must already exist in Partner Center and must have at least one
manually-created submission. Microsoft does not allow the submission API to
create the app or its first submission.

Create or associate a Microsoft Entra application in Partner Center and give it
the Partner Center role required to manage submissions. Record the tenant ID,
client ID, and client secret. Also copy the Seller ID from Partner Center's
account settings and the app's Partner Center ID from the app overview.

In GitHub, add these under **Settings → Secrets and variables → Actions**:

Secrets:

- `AZURE_AD_TENANT_ID`
- `AZURE_AD_APPLICATION_CLIENT_ID`
- `AZURE_AD_APPLICATION_SECRET`
- `SELLER_ID`

Repository variable:

- `MICROSOFT_STORE_PRODUCT_ID` — the app's Partner Center ID

The workflow copies the versioned MSI from the GitHub Release to the project's
GitHub Pages site and submits that stable, non-redirecting HTTPS URL using the
silent-install command `/qn`.

Enable GitHub Pages for the repository with **Settings → Pages → Source: GitHub
Actions** before the first tagged release. The resulting package URL is:

`https://tastyheadphones.github.io/QuakeSignal/store/<version>/QuakeSignal_<version>_x64_en-US.msi`

## Publishing

1. Configure the existing SignPath variables and secret so the Windows job
   produces a trusted Authenticode-signed MSI.
2. Update `desktop/src-tauri/tauri.conf.json` and create the matching tag, for
   example `v0.1.0`.
3. Push the tag. The `Desktop release` workflow builds the Windows installer,
   creates the GitHub Release, publishes the MSI to GitHub Pages, and then
   submits it to Partner Center.
4. Complete any certification or Store listing actions shown in Partner Center.

The Store submission is asynchronous: a successful workflow means that the
submission was sent to Partner Center, not that certification has finished.
