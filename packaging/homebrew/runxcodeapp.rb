# Homebrew cask for RunXcodeApp.
# Lives in this repo as the source of truth; the Release workflow copies it into
# github.com/cse-ariful/homebrew-tap (Casks/runxcodeapp.rb) with the new version + sha256.
cask "runxcodeapp" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/cse-ariful/MenubarRunApp/releases/download/v#{version}/RunXcodeApp-#{version}.dmg"
  name "RunXcodeApp"
  desc "Menu bar app to build and run Xcode projects on simulators and devices"
  homepage "https://github.com/cse-ariful/MenubarRunApp"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :ventura"

  app "RunXcodeApp.app"

  # The app is ad-hoc signed, not notarized. Clear the download quarantine so
  # Gatekeeper doesn't block it on first launch.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/RunXcodeApp.app"],
                   must_succeed: false
  end

  uninstall quit: "com.enosisbd.RunXcodeApp"

  zap trash: [
    "~/Library/Logs/RunXcodeApp",
    "~/Library/Preferences/com.enosisbd.RunXcodeApp.plist",
  ]
end
