#!/bin/bash
# Packages SmartDock.app into a drag-to-Applications DMG.
#   ./make_dmg.sh                                           ad-hoc (friends must right-click > Open)
#   SIGN_ID="Developer ID Application: ..." NOTARY_PROFILE=smartdock ./make_dmg.sh
#                                                           signed + notarized + stapled (no warnings)
# One-time notary setup:
#   xcrun notarytool store-credentials smartdock --apple-id YOU@EMAIL --team-id TEAMID --password APP-SPECIFIC-PW
set -euo pipefail
cd "$(dirname "$0")"

APP=SmartDock.app
[ -d "$APP" ] || ./build.sh
VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="SmartDock-$VER.dmg"
STAGE=.build/dmg

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "SmartDock" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

if [ -n "${SIGN_ID:-}" ]; then
  codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
fi
if [ -n "${NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

echo "Created $DMG"
