cask "notch-stats" do
  version "0.1.0"
  sha256 "543f10ba820204be7d0abdf8f939356627e6d5edd463c0aaf5cb6bd8ace66939"

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
