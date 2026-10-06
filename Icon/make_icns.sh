#!/bin/zsh
# Gera Icon/AppIcon.icns a partir do desenho em make_icon.swift.
set -e
cd "$(dirname "$0")"
swift make_icon.swift icon_1024.png >/dev/null
rm -rf AppIcon.iconset && mkdir AppIcon.iconset
for s in 16 32 128 256 512; do
    sips -z $s $s icon_1024.png --out AppIcon.iconset/icon_${s}x${s}.png >/dev/null
    sips -z $((s*2)) $((s*2)) icon_1024.png --out AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns AppIcon.iconset -o AppIcon.icns
rm -rf AppIcon.iconset
echo "OK: Icon/AppIcon.icns"
