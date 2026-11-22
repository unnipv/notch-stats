cask "notch-stats" do
  version "0.3.2"
  sha256 "0dcb6cd98634c60e86521417554c5fba5425bc876e3fcf9a4816442c6bfd9492"

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
