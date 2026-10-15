cask "notch-stats" do
  version "0.2.0"
  sha256 "094fe3ed34654d8ce32c7d0fa66274cf244d4e2fe9d5a65c64e777bf5b006426"

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
