cask "herdrbar" do
  version "0.1.0"
  sha256 "e1df85ec7999e0b071af3bd31958ab1bbd8793856967b784e7649466607dd80d"

  url "https://github.com/InsaneArts/herdrbar/releases/download/v#{version}/Herdrbar-#{version}.zip"
  name "Herdrbar"
  desc "Menu bar companion for herdr: see which agent needs you and jump to it"
  homepage "https://github.com/InsaneArts/herdrbar"

  depends_on macos: ">= :sequoia"

  app "Herdrbar.app"

  uninstall quit: "com.tornikegomareli.Herdrbar"

  zap trash: "~/Library/Preferences/com.tornikegomareli.Herdrbar.plist"
end
