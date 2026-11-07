#!/bin/bash
# Builds a universal (arm64 + x86_64) CaptureDeck.app into ./build
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
ASSETS="CaptureDeck-brand-assets"
APP="build/CaptureDeck.app"

# Build each architecture separately and merge with lipo. This works with only the
# Command Line Tools (a single `--arch arm64 --arch x86_64` build needs full Xcode).
for ARCH in arm64 x86_64; do
  swift build -c "$CONFIG" --triple "$ARCH-apple-macosx13.0"
done
mkdir -p build
BIN="build/CaptureDeck-universal"
lipo -create -output "$BIN" \
  "$(swift build -c "$CONFIG" --triple arm64-apple-macosx13.0 --show-bin-path)/CaptureDeck" \
  "$(swift build -c "$CONFIG" --triple x86_64-apple-macosx13.0 --show-bin-path)/CaptureDeck"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$BIN" "$APP/Contents/MacOS/CaptureDeck"
cp Packaging/Info.plist "$APP/Contents/Info.plist"

# App icon: build .icns from the brand iconset (unmodified)
iconutil -c icns "$ASSETS/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
# Menu bar template image (1x + 2x)
cp "$ASSETS/menubarTemplate.png" "$ASSETS/menubarTemplate@2x.png" "$APP/Contents/Resources/"

# Sign. Prefer the stable local identity (scripts/setup-dev-signing.sh) so the Screen Recording
# permission survives rebuilds; fall back to ad hoc (permission resets on every build).
IDENTITY="${SIGN_IDENTITY:-CaptureDeck Dev}"
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" "$APP"
else
  echo "Note: '$IDENTITY' not found; signing ad hoc. Run scripts/setup-dev-signing.sh once."
  codesign --force --sign - "$APP"
fi
echo "Built $APP"
lipo -archs "$APP/Contents/MacOS/CaptureDeck"
