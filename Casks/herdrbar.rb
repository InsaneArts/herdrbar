cask "herdrbar" do
  version "0.2.1"
  sha256 "fc256f007e7c1880c2c02a0db87092da3a0d7cb6d2f3affed1f52df1eb5bb3f1"

  url "https://github.com/InsaneArts/herdrbar/releases/download/v#{version}/Herdrbar-#{version}.zip"
  name "Herdrbar"
  desc "Menu bar companion for herdr: see which agent needs you and jump to it"
  homepage "https://github.com/InsaneArts/herdrbar"

  auto_updates true
  depends_on macos: ">= :sequoia"

  app "Herdrbar.app"

  uninstall quit: "com.tornikegomareli.Herdrbar"

  zap trash: [
    "~/Library/Caches/com.tornikegomareli.Herdrbar",
    "~/Library/HTTPStorages/com.tornikegomareli.Herdrbar",
    "~/Library/Preferences/com.tornikegomareli.Herdrbar.plist",
  ]
end
