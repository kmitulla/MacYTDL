#!/bin/bash
# Builds dist/MacYTDL.app (universal) from the Swift package, bundles the helper tools and signs ad-hoc.
# Usage: VERSION=3.0.0 BUILD=42 scripts/build_app.sh [vendor-dir]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${VERSION:-3.0.0}
BUILD=${BUILD:-1}
VENDOR=${1:-vendor}
APP=dist/MacYTDL.app

swift build -c release --arch arm64 --arch x86_64
BIN_DIR=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Tools"
cp "$BIN_DIR/MacYTDL" "$APP/Contents/MacOS/MacYTDL"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# App icon (.icns from the 1024 px master).
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cp -R Resources/en.lproj Resources/de.lproj "$APP/Contents/Resources/"
cp Resources/THIRD_PARTY_NOTICES.txt "$APP/Contents/Resources/" 2>/dev/null || true

if [ -d "$VENDOR/Tools" ]; then
  cp -R "$VENDOR/Tools/." "$APP/Contents/Resources/Tools/"
else
  echo "warning: $VENDOR/Tools missing - app will use system tools" >&2
fi

codesign --force --sign - "$APP"
codesign --verify --verbose=2 "$APP"
lipo -info "$APP/Contents/MacOS/MacYTDL"
du -sh "$APP"
