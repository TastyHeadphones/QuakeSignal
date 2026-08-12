# Microsoft Store distribution

QuakeSignal is distributed for Windows as an **MSIX** package. GitHub Actions
builds the package and Microsoft Store re-signs it after certification, so this
repository does not hold or use a Windows code-signing certificate.

## One-time setup

The Store product must be an **MSIX or PWA app** in Partner Center. The current
product ID is stored as the `MICROSOFT_STORE_PRODUCT_ID` variable in the
protected `microsoft-store-release` Environment.

GitHub Actions authenticates to Partner Center with these environment-scoped
secrets:

- `AZURE_AD_TENANT_ID`
- `AZURE_AD_APPLICATION_CLIENT_ID`
- `AZURE_AD_APPLICATION_SECRET`
- `SELLER_ID`

The Microsoft Entra application must be associated with Partner Center and
have the **Manager** role. The MSIX manifest identity is assigned by Partner
Center and is recorded in `.github/workflows/desktop-release.yml`.

## First submission

Microsoft's GitHub Actions publishing flow is for apps that are already live.
Create the first submission manually in Partner Center:

1. In **Desktop release → Run workflow**, select protected `main` and leave
   `publish_to_store` disabled. The manual protected-main Windows job produces
   the `windows-msix` artifact and skips Partner Center publishing.
2. Download that artifact and upload the `.msixupload` package in the Partner Center
   submission. Complete the listing, availability, age rating, and
   certification notes, then submit it for certification.
3. After Microsoft approves the app and it becomes live, submit each later
   update by starting **Desktop release → Run workflow** from protected `main`
   with `publish_to_store` enabled. That same run builds the MSIX and calls
   `msstore publish` after the protected `microsoft-store-release` Environment
   approves it. Version tags may build a non-public Windows artifact, but they
   neither submit it to Partner Center nor attach it to the GitHub Release,
   which contains only the notarized macOS direct-download DMG.

The raw MSIX build artifact is intentionally not attached to GitHub Releases:
it becomes a publicly installable package only after Microsoft Store signs and
hosts the certified submission.
