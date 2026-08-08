# QuakeSignal Homebrew tap

This directory is the source of truth for the personal Homebrew tap that
distributes the QuakeSignal desktop app on macOS. It is kept in this repository
so the cask is versioned alongside the code it installs, and mirrored into a
standalone tap repository that Homebrew can consume.

## Why a personal tap and not `homebrew/cask`

QuakeSignal is not yet signed with an Apple Developer ID and not notarized.

- Homebrew has removed the `--no-quarantine` flag, so there is no supported way
  to install a cask without the quarantine attribute being applied.
- From **1 September 2026**, Homebrew will disable every cask in the official
  `homebrew/cask` tap that fails Gatekeeper checks
  ([Homebrew/brew#20755](https://github.com/Homebrew/brew/issues/20755)).

An unnotarized QuakeSignal therefore cannot be submitted to the official tap.
A personal tap can still ship it, provided the cask tells users plainly that
the app is unnotarized and gives them the command to clear quarantine — which
the `caveats` block in [`Casks/quakesignal.rb`](Casks/quakesignal.rb) does.

Once notarization exists, delete the `caveats` block and the cask becomes
eligible for the official tap.

## Creating the tap repository

Homebrew requires the repository to be named `homebrew-<tap>`. For a tap
installed as `TastyHeadphones/tap`, create a **public** repository named
`homebrew-tap` under the `TastyHeadphones` account, then:

```bash
git clone https://github.com/TastyHeadphones/homebrew-tap.git
mkdir -p homebrew-tap/Casks
cp packaging/homebrew-tap/Casks/quakesignal.rb homebrew-tap/Casks/
cd homebrew-tap && git add Casks/quakesignal.rb && git commit -m "Add QuakeSignal cask" && git push
```

Resulting layout:

```
homebrew-tap/
└── Casks/
    └── quakesignal.rb
```

## Installing

```bash
brew tap TastyHeadphones/tap
brew install --cask quakesignal
```

Then run the command Homebrew prints in the caveats to clear quarantine.

## Updating the cask for a new release

After a `v*` tag has been released by
[`.github/workflows/desktop-release.yml`](../../.github/workflows/desktop-release.yml):

```bash
VERSION=0.2.0

# Take the checksum straight from the release's published SHA256SUMS.txt.
gh release download "v${VERSION}" --repo TastyHeadphones/QuakeSignal \
  --pattern SHA256SUMS.txt --output - \
  | grep "QuakeSignal_${VERSION}_universal.dmg"
```

Update `version` and `sha256` in `Casks/quakesignal.rb`, copy it into the tap
repository, and push. Verify before publishing:

```bash
brew audit --cask --online --strict Casks/quakesignal.rb
brew style Casks/quakesignal.rb
```

## Verifying an install end to end

```bash
brew uninstall --cask quakesignal 2>/dev/null || true
brew install --cask quakesignal
xattr -p com.apple.quarantine /Applications/QuakeSignal.app   # attribute is present
xattr -dr com.apple.quarantine "/Applications/QuakeSignal.app"
open -a QuakeSignal                                            # app launches
```
