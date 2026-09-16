#!/bin/bash
set -euo pipefail

# generate_icon.sh - Generate AppIcon.icns from Stella master graphic
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${BASE_DIR}/../star-components/Stella Origin.png"

if [ ! -f "$SRC" ]; then
    SRC="${BASE_DIR}/../star-components/star-web-client/static/Stella.png"
fi

if [ ! -f "$SRC" ]; then
    echo "❌ Source image not found at $SRC" >&2
    exit 1
fi

echo "==> Generating AppIcon.icns from $SRC ..."
ICONSET_DIR="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"

sips -z 16 16     "$SRC" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32     "$SRC" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32     "$SRC" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64     "$SRC" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128   "$SRC" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256   "$SRC" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$SRC" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512   "$SRC" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$SRC" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$SRC" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null

mkdir -p "${BASE_DIR}/assets"
iconutil -c icns "$ICONSET_DIR" -o "${BASE_DIR}/assets/AppIcon.icns"
rm -rf "$(dirname "$ICONSET_DIR")"

echo "✅ Successfully generated ${BASE_DIR}/assets/AppIcon.icns"
