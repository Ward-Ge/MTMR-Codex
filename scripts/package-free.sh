#!/bin/bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE_DIR="$PROJECT_DIR/Release"
DERIVED_DATA="$RELEASE_DIR/DerivedData"
BUILD_APP="$DERIVED_DATA/Build/Products/Release/MTMR.app"
DMG_ROOT="$(mktemp -d /tmp/mtmr-codex-dmg.XXXXXX)"

cleanup() {
  rm -rf "$DMG_ROOT"
}
trap cleanup EXIT

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/MTMR/Info.plist")"
DMG_PATH="$RELEASE_DIR/MTMR-Codex-${VERSION}-macOS-universal.dmg"
ZIP_PATH="$RELEASE_DIR/MTMR-Codex-${VERSION}-macOS-universal.zip"

rm -rf "$DERIVED_DATA"
rm -f "$DMG_PATH" "$ZIP_PATH"
mkdir -p "$RELEASE_DIR"

xcodebuild \
  -project "$PROJECT_DIR/MTMR.xcodeproj" \
  -scheme MTMR \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  ARCHS='x86_64 arm64' \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

test -d "$BUILD_APP"

# A free Apple account cannot create a Developer ID signature. Ad-hoc signing keeps
# the app internally consistent, while macOS will still require one Open Anyway step.
codesign --force --deep --sign - "$BUILD_APP"
codesign --verify --deep --strict --verbose=2 "$BUILD_APP"

ditto "$BUILD_APP" "$DMG_ROOT/MTMR.app"
ln -s /Applications "$DMG_ROOT/Applications"

if ! hdiutil create \
  -volname "MTMR-Codex" \
  -srcfolder "$DMG_ROOT" \
  -format UDZO \
  -ov \
  "$DMG_PATH"; then
  # Some managed/macOS virtual environments cannot attach the temporary device
  # used by `hdiutil create`. `makehybrid` builds a Finder-mountable HFS image
  # directly and does not need that device. Convert it to compressed UDZO after.
  UNCOMPRESSED_DMG="$RELEASE_DIR/MTMR-Codex-${VERSION}-macOS-universal-uncompressed.dmg"
  hdiutil makehybrid \
    -hfs \
    -hfs-volume-name "MTMR-Codex" \
    -o "$UNCOMPRESSED_DMG" \
    "$DMG_ROOT"
  hdiutil convert \
    "$UNCOMPRESSED_DMG" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG_PATH"
  rm -f "$UNCOMPRESSED_DMG"
fi

ditto -c -k --sequesterRsrc --keepParent "$BUILD_APP" "$ZIP_PATH"

# The packaged app is already present in the DMG and ZIP. Keep build caches out
# of Release so the directory stays small and is safe to inspect or copy.
rm -rf "$DERIVED_DATA"

echo
echo "Release artifacts:"
echo "  $DMG_PATH"
echo "  $ZIP_PATH"
shasum -a 256 "$DMG_PATH" "$ZIP_PATH"
