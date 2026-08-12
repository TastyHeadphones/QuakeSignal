# QuakeSignal Homebrew tap

This directory is the release template and future source of truth for a
personal Homebrew tap that can distribute the QuakeSignal desktop app on macOS.
It is kept in this repository so a future cask is versioned alongside the code
it installs. It is not itself an installable tap, and no public
`TastyHeadphones/tap` cask is published yet.

## Release contract

A future public tap may distribute only DMGs that have been signed with a
Developer ID Application certificate, notarized by Apple, and stapled by the
protected `macos-direct-release` job. A cask must never tell users to clear
quarantine or bypass Gatekeeper.

The checked-in `0.1.0` cask preserves a historical artifact checksum, but that
release predates Developer ID signing and notarization. Do **not** mirror it
into a public tap or use it to install QuakeSignal. The first public cask commit
must point at a later release that has passed the notarized macOS workflow and
published a stapled DMG plus `SHA256SUMS.txt`.

## Creating the tap repository

Homebrew requires the repository to be named `homebrew-<tap>`. For a tap
installed as `TastyHeadphones/tap`, create a **public** repository named
`homebrew-tap` under the `TastyHeadphones` account only after a qualifying
release has been published. Create it with an initial `main` branch (for
example, with a README), but do **not** manually copy or commit the historical
`0.1.0` cask. Configure the protected `homebrew-tap-release` environment and
run **Publish Homebrew cask** for the qualifying version instead. That workflow
renders the first cask from the template only after it has verified the tagged
notarized DMG, checksum, protected-release provenance, and Homebrew audit.

The public repository is a prerequisite only; the protected workflow creates
the initial `Casks/quakesignal.rb` commit. A manual cask commit is reserved for
the documented incident-recovery procedure below, after reproducing every
release check.

Resulting layout:

```
homebrew-tap/
└── Casks/
    └── quakesignal.rb
```

## Installing after publication

The commands below are not usable today: the public tap and a supported cask
have not been published. After the first qualifying cask has been mirrored to
the public tap, users may run:

```bash
brew tap TastyHeadphones/tap
brew install --cask quakesignal
```

Only publish the cask after the release checks below succeed. The tap must stay
public so `brew tap TastyHeadphones/tap` can resolve it.

## Updating the cask for a new release

After a later `v*` tag (not `v0.1.0`) has completed the protected direct macOS
release job in
[`.github/workflows/desktop-release.yml`](../../.github/workflows/desktop-release.yml):

The normal release route is the protected manual
[`Publish Homebrew cask`](../../.github/workflows/homebrew-tap.yml) workflow.
It checks the tagged release's DMG signature, notarization ticket, universal
architectures, Gatekeeper assessment, published checksum, and Homebrew cask
audit before it uses the environment-scoped tap token to push a rendered cask.
It deliberately rejects `v0.1.0` and will not create the public tap. See
[`docs/RELEASE_SECRETS.md`](../../docs/RELEASE_SECRETS.md#homebrew-tap-release)
for the one token and reviewer setup required before this lane can run.

For an incident-recovery or audited manual update, reproduce the same checks
before making a tap commit:

```bash
VERSION=1.0.0

# Confirm that the direct-download DMG, notarization, and stapling job passed.
gh run list --repo TastyHeadphones/QuakeSignal --workflow desktop-release.yml --limit 5

# Take the checksum straight from the release's published SHA256SUMS.txt.
gh release download "v${VERSION}" --repo TastyHeadphones/QuakeSignal \
  --pattern SHA256SUMS.txt --output - \
  | grep "QuakeSignal_${VERSION}_universal.dmg"
```

Update `version` and `sha256` in `Casks/quakesignal.rb`, copy it into the
Homebrew-managed tap checkout above, and verify it before pushing:

```bash
brew audit --strict --online --cask TastyHeadphones/tap/quakesignal
brew style --cask TastyHeadphones/tap/quakesignal
```

## Verifying a notarized install end to end

```bash
brew uninstall --cask quakesignal 2>/dev/null || true
brew install --cask quakesignal
codesign --verify --deep --strict --verbose=2 /Applications/QuakeSignal.app
spctl --assess --type open --verbose=4 /Applications/QuakeSignal.app
open -a QuakeSignal
```

If Gatekeeper rejects the app, stop the release update and investigate the
signed GitHub artifact. Do not document or use a quarantine-bypass command.
