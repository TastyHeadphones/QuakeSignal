# Microsoft Store distribution

QuakeSignal is distributed for Windows as an **MSIX** package. GitHub Actions
builds the package and Microsoft Store re-signs it after certification, so this
repository does not hold or use a Windows code-signing certificate.

## One-time setup

The Store product must be an **MSIX or PWA app** in Partner Center. The current
product ID is stored in the `MICROSOFT_STORE_PRODUCT_ID` repository variable.

GitHub Actions authenticates to Partner Center with these repository secrets:

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

1. Run **Desktop release** with **Run workflow**. This produces the
   `windows-msix` artifact without publishing it.
2. Download that artifact and upload the `.msixupload` package in the Partner Center
   submission. Complete the listing, availability, age rating, and
   certification notes, then submit it for certification.
3. After Microsoft approves the app and it becomes live, later tagged releases
   (`v<version>`) automatically build and publish the MSIX package with
   `msstore publish`.

The raw MSIX build artifact is intentionally not attached to GitHub Releases:
it becomes a publicly installable package only after Microsoft Store signs and
hosts the certified submission.
