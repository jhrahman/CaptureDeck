#!/bin/bash
# Builds the app and packages it as dist/CaptureDeck-<version>.zip and .dmg
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Packaging/Info.plist)"
APP="build/CaptureDeck.app"
OUT="dist"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# Release builds are ad hoc signed so no local identity name ends up in the bundle.
if [ "${SKIP_BUILD:-0}" != "1" ]; then
  SIGN_IDENTITY="-" ./scripts/build-app.sh
fi

rm -rf "$OUT"
mkdir -p "$OUT"

ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/CaptureDeck-$VERSION.zip"

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "CaptureDeck $VERSION" -srcfolder "$STAGE" -ov -format UDZO \
  "$OUT/CaptureDeck-$VERSION.dmg" >/dev/null

(cd "$OUT" && shasum -a 256 CaptureDeck-"$VERSION".* > SHA256SUMS.txt)
echo "Packaged:"; ls -lh "$OUT"
