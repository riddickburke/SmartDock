#!/bin/bash
# Builds SmartDock.app (with icon) for this Mac's architecture. Works with just the Command Line Tools.
#   UNIVERSAL=1 ./build.sh                                universal build (needs full Xcode)
#   SIGN_ID="Developer ID Application: ..." ./build.sh    sign for distribution (hardened runtime)
set -euo pipefail
cd "$(dirname "$0")"

APP=SmartDock.app
rm -rf "$APP" .build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" .build

# --- compile
if [ "${UNIVERSAL:-0}" = "1" ]; then
  for arch in arm64 x86_64; do
    swiftc -O -target "$arch-apple-macos11.0" main.swift -o ".build/SmartDock-$arch"
  done
  lipo -create .build/SmartDock-arm64 .build/SmartDock-x86_64 -output "$APP/Contents/MacOS/SmartDock"
else
  swiftc -O -target "$(uname -m)-apple-macos11.0" main.swift -o "$APP/Contents/MacOS/SmartDock"
fi

cp Info.plist "$APP/Contents/Info.plist"

# --- icon, step 1: classic .icns from icon.png (works everywhere, no Xcode needed)
SET=.build/AppIcon.iconset
mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s icon.png --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) icon.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$APP/Contents/Resources/AppIcon.icns"

# --- icon, step 2 (optional): Dark / Clear / Tinted variants from SmartDock.icon.
# Needs actool from full Xcode 26+. Skipped automatically otherwise; the .icns above is used.
if [ -d SmartDock.icon ] && xcrun --find actool >/dev/null 2>&1; then
  if xcrun actool SmartDock.icon --compile "$APP/Contents/Resources" \
       --output-format human-readable-text --notices --warnings --errors \
       --output-partial-info-plist .build/icon-partial.plist \
       --app-icon SmartDock --include-all-app-icons --enable-on-demand-resources NO \
       --development-region en --target-device mac --minimum-deployment-target 26.0 \
       --platform macosx >.build/actool.log 2>&1; then
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string SmartDock" "$APP/Contents/Info.plist"
    echo "Icon: Dark/Clear/Tinted variants compiled"
  else
    echo "Icon: actool failed (see .build/actool.log), using static icon"
  fi
else
  echo "Icon: static icon only (Dark/Clear variants need Xcode 26+)"
fi

# --- sign
if [ -n "${SIGN_ID:-}" ]; then
  codesign --force --options runtime --timestamp --entitlements entitlements.plist --sign "$SIGN_ID" "$APP"
else
  codesign --force --sign - "$APP"
fi

echo "Built $APP"
