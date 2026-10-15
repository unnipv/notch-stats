cask "notch-stats" do
  version "0.1.0"
  sha256 "3beecc34d4b316cf92e7de7865e7f1557c9a01c51ae112cc0d807a9048069016"

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
