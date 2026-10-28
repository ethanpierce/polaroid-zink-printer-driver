#!/bin/bash
# Builds "ZIP Print.app" into dist/.
#
#   scripts/build-app.sh            # universal (Apple silicon + Intel) release build
#   CODESIGN_IDENTITY="-" scripts/build-app.sh   # force ad-hoc signing
#
# Signs with the first "Developer ID Application" or "Apple Development"
# identity in your keychain, or ad-hoc if there isn't one. A stable identity
# matters: macOS ties the Bluetooth permission to the signature, so an
# ad-hoc build asks for permission again after every rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

APP="dist/ZIP Print.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/ZipPrint" "$APP/Contents/MacOS/ZipPrint"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Developer ID Application|Apple Development/ { print $2; exit }')}"
codesign --force --options runtime --sign "${IDENTITY:--}" "$APP"

echo "Built $APP (signed: ${IDENTITY:-ad-hoc})"
