#!/usr/bin/env bash
# Builds a signed, notarized, stapled Herdrbar for Apple silicon and Intel from a clean checkout, then zips
# it, packs a disk image, writes checksums, fills in the Homebrew cask, and adds the signed update to
# appcast.xml. It publishes nothing; see RELEASING.md.
#
#   Scripts/release.sh            # version and build number come from version.env
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
source version.env
# Build releases with the stable Xcode, not whatever xcode-select points at (it may be a beta).
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
APP_IDENTITY=${APP_IDENTITY:-"Developer ID Application: Techzy LLC (539293JFA3)"}
TEAM_ID=${TEAM_ID:-539293JFA3}
NOTARY_PROFILE=${NOTARY_PROFILE:-AC_PASSWORD}
OUT="$ROOT/release/$MARKETING_VERSION"

[[ "$MARKETING_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version.env: MARKETING_VERSION must look like 0.1.0" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes first: a release builds exactly what is committed." >&2; exit 1; }
[[ ! -e "$OUT" ]] || { echo "$OUT already exists. Remove it, or raise the version." >&2; exit 1; }
! git rev-parse -q --verify "refs/tags/v$MARKETING_VERSION" >/dev/null || { echo "Tag v$MARKETING_VERSION already exists." >&2; exit 1; }

echo "==> Herdrbar $MARKETING_VERSION ($BUILD_NUMBER) with $(xcodebuild -version | head -1)"
swift test
SIGNING_MODE=release APP_IDENTITY="$APP_IDENTITY" ARCHES="arm64 x86_64" Scripts/package_app.sh release

echo "==> verify signature"
codesign --verify --deep --strict --verbose=2 Herdrbar.app
codesign -dv Herdrbar.app 2>&1 | grep -q "TeamIdentifier=$TEAM_ID" || { echo "Signed with the wrong team." >&2; exit 1; }
lipo -archs Herdrbar.app/Contents/MacOS/Herdrbar

echo "==> notarize"
mkdir -p "$OUT"
ditto --norsrc -c -k --keepParent Herdrbar.app "$OUT/notarize.zip"
xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
rm "$OUT/notarize.zip"
xcrun stapler staple Herdrbar.app
xcrun stapler validate Herdrbar.app
spctl --assess --type execute --verbose=2 Herdrbar.app

echo "==> package"
ZIP="$OUT/Herdrbar-$MARKETING_VERSION.zip"
ditto --norsrc -c -k --keepParent Herdrbar.app "$ZIP"
Scripts/make_dmg.sh Herdrbar.app "$OUT/Herdrbar-$MARKETING_VERSION.dmg"
Scripts/generate-cask.sh "$MARKETING_VERSION" "$ZIP" "$OUT/herdrbar.rb"
(cd "$OUT" && shasum -a 256 "Herdrbar-$MARKETING_VERSION.zip" "Herdrbar-$MARKETING_VERSION.dmg" herdrbar.rb > SHA256SUMS)

# Sparkle updates from the zip. generate_appcast signs it with the EdDSA key in the login Keychain (the first
# run asks for Keychain access: choose Always Allow) and keeps the five newest versions in appcast.xml.
echo "==> Sparkle feed"
mkdir -p "$OUT/sparkle"
cp "$ZIP" "$OUT/sparkle/"
.build/artifacts/sparkle/Sparkle/bin/generate_appcast \
  --download-url-prefix "https://github.com/InsaneArts/herdrbar/releases/download/v$MARKETING_VERSION/" \
  --link "https://insanearts.github.io/herdrbar/" --maximum-versions 5 -o "$ROOT/appcast.xml" "$OUT/sparkle"
grep -q "sparkle:edSignature" appcast.xml || { echo "appcast.xml has no EdDSA signature." >&2; exit 1; }
echo "Done: $OUT"
ls -la "$OUT"
