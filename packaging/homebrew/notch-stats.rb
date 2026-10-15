cask "notch-stats" do
  version "0.1.0"
  sha256 "ecc718df24cef0d7d78ab43f242952e8d5ea6af1b893021e4ea195819909ed94"

  url "https://github.com/unnipv/notch-stats/releases/download/v#{version}/NotchStats.zip",
      verified: "github.com/unnipv/notch-stats/"
  name "NotchStats"
  desc "Usage limits and live AI coding sessions in the MacBook notch"
  homepage "https://github.com/unnipv/notch-stats"

  depends_on macos: ">= :sonoma"

  app "NotchStats.app"

  zap trash: [
    "~/Library/Preferences/dev.notchstats.app.plist",
  ]
end
