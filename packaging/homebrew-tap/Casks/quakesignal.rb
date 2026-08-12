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
    "~/Library/Logs/com.quakesignal.desktop",
    "~/Library/LaunchAgents/QuakeSignal.plist",
    "~/Library/Preferences/com.quakesignal.desktop.plist",
    "~/Library/Saved Application State/com.quakesignal.desktop.savedState",
    "~/Library/WebKit/com.quakesignal.desktop",
  ]

  # Release template: publish this cask to the public tap only after the
  # matching GitHub Release's DMG has passed Developer ID signing,
  # notarization, and stapling in the protected macos-direct-release job.
end
