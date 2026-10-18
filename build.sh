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

# A stable certificate keeps the Accessibility grant across rebuilds.
# An ad hoc signature changes every build, and the switch in System Settings
# keeps pointing at the old one.
sign_raster() {
  local app="$1"
  local name="Raster Local"
  local keychain="$HOME/Library/Keychains/login.keychain-db"
  if ! security find-identity -v -p codesigning | grep -q "\"$name\""; then
    local dir
    dir="$(mktemp -d)"
    cat > "$dir/cert.cfg" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF
    openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
      -keyout "$dir/key.pem" -out "$dir/cert.pem" -config "$dir/cert.cfg" >/dev/null 2>&1
    openssl pkcs12 -export -inkey "$dir/key.pem" -in "$dir/cert.pem" \
      -out "$dir/cert.p12" -passout pass:raster >/dev/null 2>&1
    security import "$dir/cert.p12" -k "$keychain" -P raster -A \
      -T /usr/bin/codesign -T /usr/bin/security >/dev/null
    security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$dir/cert.pem" >/dev/null
    rm -rf "$dir"
  fi
  codesign --force --sign "$name" --identifier local.raster "$app" >/dev/null
}

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
sign_raster "$app"

echo "Bygget $app"
