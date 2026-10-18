#!/bin/zsh
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
app="$root/Raster.app"
macos="$app/Contents/MacOS"
resources="$app/Contents/Resources"
sdk="$(xcrun --show-sdk-path)"
arch="$(uname -m)"
target="${arch}-apple-macos14"
iconset="$root/build/AppIcon.iconset"
master="$root/build/icon-1024.png"
icns="$resources/AppIcon.icns"

rm -rf "$app" "$root/build"
mkdir -p "$macos" "$resources" "$iconset" "$root/build"

ictool="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
"$ictool" "$root/AppIcon.icon" \
  --export-image --output-file "$master" \
  --platform macOS --rendition Default \
  --width 1024 --height 1024 --scale 1 >/dev/null

sizes=(16 32 128 256 512)
for size in $sizes; do
  sips -z $size $size "$master" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  retina=$((size * 2))
  sips -z $retina $retina "$master" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$iconset" -o "$icns"

swiftc -parse-as-library -O \
  "$root/Sources/Raster.swift" \
  -o "$macos/Raster" \
  -target "$target" \
  -sdk "$sdk" \
  -framework AppKit \
  -framework ApplicationServices \
  -framework ServiceManagement

cp "$root/Info.plist" "$app/Contents/Info.plist"
cp "$root/PrivacyInfo.xcprivacy" "$resources/PrivacyInfo.xcprivacy"
cp "$root/PrivacyPolicy.txt" "$resources/PrivacyPolicy.txt"
echo -n "APPL????" > "$app/Contents/PkgInfo"
chmod +x "$macos/Raster"
codesign --force --sign - --identifier local.raster "$app" >/dev/null

echo "Bygget $app"
