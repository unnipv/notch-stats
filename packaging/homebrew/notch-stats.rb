cask "notch-stats" do
  version "0.3.0"
  sha256 "b10a4b410df88b0386a06141c58ceba5254905f470155d79dff175094a409ba4"

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
