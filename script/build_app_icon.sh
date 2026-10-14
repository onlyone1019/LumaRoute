#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT_DIR/Resources/AppIcon/LumaRoute-icon.png"
OUTPUT="${1:-$ROOT_DIR/.build/AppIcon.icns}"
[ -f "$SOURCE" ] || { echo '缺少 LumaRoute 图标源图。' >&2; exit 1; }
mkdir -p "$ROOT_DIR/.build" "$(dirname "$OUTPUT")"
ICON_WORK=$(mktemp -d "$ROOT_DIR/.build/app-icon.XXXXXX")
trap 'rm -rf "$ICON_WORK"' EXIT
ICON_SET="$ICON_WORK/AppIcon.iconset"
mkdir "$ICON_SET"
for points in 16 32 128 256 512; do
  for scale in 1 2; do
    pixels=$((points * scale))
    suffix=''
    if [ "$scale" = 2 ]; then suffix='@2x'; fi
    /usr/bin/sips -z "$pixels" "$pixels" "$SOURCE" --out "$ICON_SET/icon_${points}x${points}${suffix}.png" >/dev/null
  done
done
/usr/bin/iconutil --convert icns "$ICON_SET" --output "$OUTPUT"
echo "App icon: $OUTPUT"
