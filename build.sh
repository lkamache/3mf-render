#!/bin/zsh
# Compila o app "3MF Render.app" sem precisar do Xcode (apenas Command Line Tools).
# Compila para a arquitetura desta máquina (ou as de ARCHS, ex.: ARCHS="arm64" ./build.sh).
set -e
cd "$(dirname "$0")"
APP="build/3MF Render.app"
ARCHS=(${=ARCHS:-$(uname -m)})
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

bins=()
for arch in $ARCHS; do
    swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" \
        -o "build/obj/3MFRender-$arch" Sources/*.swift
    bins+="build/obj/3MFRender-$arch"
done
lipo -create $bins -output "$APP/Contents/MacOS/3MFRender"

cp Info.plist "$APP/Contents/Info.plist"
[ -f Icon/AppIcon.icns ] || Icon/make_icns.sh
cp Icon/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "OK: $APP ($(lipo -archs "$APP/Contents/MacOS/3MFRender"))"
