#!/usr/bin/env bash
# Packs a notarized, stapled Herdrbar.app into a disk image for drag-and-drop installs: the app beside a
# link to Applications. The image is signed, notarized and stapled too. release.sh runs it after the zip.
#
#   Scripts/make_dmg.sh <Herdrbar.app> <out.dmg>
set -euo pipefail
APP=${1:?usage: make_dmg.sh <Herdrbar.app> <out.dmg>}
DMG=${2:?usage: make_dmg.sh <Herdrbar.app> <out.dmg>}
APP_IDENTITY=${APP_IDENTITY:-"Developer ID Application: Techzy LLC (539293JFA3)"}
NOTARY_PROFILE=${NOTARY_PROFILE:-AC_PASSWORD}

xcrun stapler validate "$APP" >/dev/null || { echo "$APP isn't notarized and stapled: run release.sh." >&2; exit 1; }
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Herdrbar.app"
ln -s /Applications "$STAGE/Applications"

echo "==> disk image"
rm -f "$DMG"
hdiutil create -volname Herdrbar -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$DMG"
codesign --force --timestamp --sign "$APP_IDENTITY" "$DMG"

echo "==> notarize the disk image"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
