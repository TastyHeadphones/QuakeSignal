cask "quakesignal" do
  version "0.1.0"
  sha256 "9a77c04b4bfe262aa59a196148fdee7524ac00cff76d45c1acf5ab1a63b70d2a"

  url "https://github.com/TastyHeadphones/QuakeSignal/releases/download/v#{version}/QuakeSignal_#{version}_universal.dmg",
      verified: "github.com/TastyHeadphones/QuakeSignal/"
  name "QuakeSignal"
  desc "Local-first earthquake early-warning monitor with native alerts and alarms"
  homepage "https://github.com/TastyHeadphones/QuakeSignal"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on :macos

  app "QuakeSignal.app"

  zap trash: [
    "~/Library/Application Support/com.quakesignal.desktop",
    "~/Library/Caches/com.quakesignal.desktop",
    "~/Library/Preferences/com.quakesignal.desktop.plist",
    "~/Library/Saved Application State/com.quakesignal.desktop.savedState",
    "~/Library/WebKit/com.quakesignal.desktop",
  ]

  # QuakeSignal is not yet notarized by Apple, so macOS blocks it on first
  # launch. Homebrew removed `--no-quarantine`, so the quarantine attribute
  # must be cleared manually after installation.
  #
  # TODO(apple): delete this entire caveats block once the app is signed with a
  # Developer ID certificate and notarized. At that point the cask also becomes
  # eligible for submission to the official homebrew/cask tap.
  caveats <<~EOS
    QuakeSignal is not yet notarized by Apple. macOS will refuse to open it and
    may report that it is damaged. To allow it to run, clear the quarantine
    attribute once:

      xattr -dr com.apple.quarantine "/Applications/QuakeSignal.app"

    Then open QuakeSignal normally. You only need to do this once per install,
    and again after each upgrade.

    Alternatively, try to open the app, then go to
    System Settings > Privacy & Security and click "Open Anyway".

    Verify the download against the checksums published with the release:
      https://github.com/TastyHeadphones/QuakeSignal/releases/tag/v#{version}
  EOS
end
