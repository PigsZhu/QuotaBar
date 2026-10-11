#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="${1:-$ROOT_DIR/AppResources/QuotaBar.png}"
ICON_WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/quotabar-icon.XXXXXX")"
trap 'rm -rf "$ICON_WORK_DIR"' EXIT
ICONSET="$ICON_WORK_DIR/QuotaBar.iconset"
mkdir -p "$ICONSET" "$ROOT_DIR/AppResources"

# Convert the selected artwork into Apple's standard 1x and 2x icon sizes.
for SIZE in 16 32 128 256 512; do
  /usr/bin/sips -z "$SIZE" "$SIZE" "$SOURCE" \
    --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
  DOUBLE_SIZE=$((SIZE * 2))
  /usr/bin/sips -z "$DOUBLE_SIZE" "$DOUBLE_SIZE" "$SOURCE" \
    --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$ICONSET" -o "$ROOT_DIR/AppResources/QuotaBar.icns"
echo "App icon: $ROOT_DIR/AppResources/QuotaBar.icns"
