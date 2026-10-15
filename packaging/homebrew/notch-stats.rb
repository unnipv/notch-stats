cask "notch-stats" do
  version "0.1.0"
  sha256 "REPLACE_WITH_SHA256_OF_RELEASE_ZIP"

  url "https://github.com/notch-stats/notch-stats/releases/download/v#{version}/NotchStats.zip",
      verified: "github.com/notch-stats/notch-stats/"
  name "NotchStats"
  desc "Usage limits and live AI coding sessions in the MacBook notch"
  homepage "https://github.com/notch-stats/notch-stats"

  depends_on macos: ">= :sonoma"

  app "NotchStats.app"

  zap trash: [
    "~/Library/Preferences/dev.notchstats.app.plist",
  ]
end
