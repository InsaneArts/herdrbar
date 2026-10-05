cask "herdrbar" do
  version "0.2.0"
  sha256 "a894fd1f82369d1e899c43ada775c85d44c9716c4b7368c956751ca4a53997df"

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
