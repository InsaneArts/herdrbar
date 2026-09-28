cask "herdrbar" do
  version "0.1.0"
  sha256 "bf0f690b51b5d969fb33f3113655b8fe0080900b81f3b75950a2116ec5313bc4"

  url "https://github.com/InsaneArts/herdrbar/releases/download/v#{version}/Herdrbar-#{version}.zip"
  name "Herdrbar"
  desc "Menu bar companion for herdr: see which agent needs you and jump to it"
  homepage "https://github.com/InsaneArts/herdrbar"

  depends_on macos: ">= :sequoia"

  app "Herdrbar.app"

  uninstall quit: "com.tornikegomareli.Herdrbar"

  zap trash: "~/Library/Preferences/com.tornikegomareli.Herdrbar.plist"
end
