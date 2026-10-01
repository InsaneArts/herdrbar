#!/bin/sh
# Installs the latest Herdrbar from GitHub Releases:
#
#   curl -fsSL https://herdrbar.insanearts.io/install.sh | sh
#
# Before it replaces Herdrbar.app, it checks the download's SHA-256, that Apple notarized the app, and that
# Herdrbar's team signed it. The app goes to /Applications, or to ~/Applications when /Applications isn't
# writable. HERDRBAR_DEST picks another folder. HERDRBAR_NO_OPEN=1 leaves the app closed.
set -eu

REPO=InsaneArts/herdrbar
TEAM=539293JFA3

fail() {
  echo "herdrbar: $*" >&2
  exit 1
}

# Everything runs from the last line, so a download that stops halfway runs nothing.
main() {
  [ "$(uname -s)" = Darwin ] || fail "Herdrbar runs on macOS only."
  macos=$(sw_vers -productVersion)
  [ "${macos%%.*}" -ge 15 ] || fail "Herdrbar needs macOS 15 or later. This Mac runs macOS $macos."

  # GitHub redirects /releases/latest to the latest release's tag: .../releases/tag/v0.1.0.
  url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest") ||
    fail "Can't reach GitHub."
  version=${url##*/tag/v}
  case $version in '' | *[!0-9.]*) fail "Can't find the latest release." ;; esac

  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  zip=Herdrbar-$version.zip
  echo "Downloading Herdrbar $version..."
  curl -fsSL -o "$tmp/$zip" "https://github.com/$REPO/releases/download/v$version/$zip"
  curl -fsSL -o "$tmp/SHA256SUMS" "https://github.com/$REPO/releases/download/v$version/SHA256SUMS"
  (cd "$tmp" && grep " $zip\$" SHA256SUMS | shasum -a 256 -c -s) || fail "The download doesn't match its checksum."

  ditto -x -k "$tmp/$zip" "$tmp/unzipped"
  app=$tmp/unzipped/Herdrbar.app
  spctl --assess --type execute "$app" 2>/dev/null || fail "Apple didn't notarize this download. Nothing was installed."
  codesign -dv "$app" 2>&1 | grep -qx "TeamIdentifier=$TEAM" || fail "Herdrbar's team didn't sign this download. Nothing was installed."

  dest=${HERDRBAR_DEST:-/Applications}
  [ -n "${HERDRBAR_DEST:-}" ] || [ -w /Applications ] || dest=$HOME/Applications
  mkdir -p "$dest"

  # Quit the copy this replaces, or open would only bring the old one forward.
  running="$dest/Herdrbar.app/Contents/MacOS/Herdrbar"
  pkill -f "$running" || true
  i=0
  while pgrep -qf "$running" && [ $i -lt 25 ]; do
    sleep 0.2
    i=$((i + 1))
  done

  rm -rf "$dest/Herdrbar.app"
  ditto "$app" "$dest/Herdrbar.app"
  echo "Installed Herdrbar $version in $dest."
  [ -n "${HERDRBAR_NO_OPEN:-}" ] || open "$dest/Herdrbar.app"
}

main
