cask "notch-stats" do
  version "0.2.1"
  sha256 "15bed1124f3ed668dfe8aeb7b78cf15c875c689328a9c2c0b4450e8b7fc7557a"

  url "https://github.com/unnipv/notch-stats/releases/download/v#{version}/NotchStats.zip"
  name "NotchStats"
  desc "Usage limits and live AI coding sessions in the MacBook notch"
  homepage "https://github.com/unnipv/notch-stats"

  depends_on macos: :sonoma

  app "NotchStats.app"

  # The build is ad-hoc signed rather than notarized, so Gatekeeper would refuse
  # the first launch. Clear the quarantine flag Homebrew sets on download.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/NotchStats.app"]
  end

  zap trash: [
    "~/Library/Preferences/dev.notchstats.app.plist",
  ]
end
