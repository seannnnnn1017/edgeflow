#!/bin/sh
# Build Edgeflow.app and install it to /Applications.
#   ./build.sh
#   ./build.sh --release    build only and zip it for a GitHub release (no install)
# The app bundles: Deskflow (its server core), the Mac edge effect, and the files it
# serves to the other computer during pairing (app/Resources/payload).
set -e
cd "$(dirname "$0")"
BUILD="${TMPDIR:-/tmp}/edgeflow-build"
APP="$BUILD/Edgeflow.app"
DESKFLOW="${DESKFLOW_APP:-/Applications/Deskflow.app}"
mkdir -p "$BUILD"

echo "› Edgeflow.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -parse-as-library -target arm64-apple-macos14.0 app/Sources/*.swift -o "$APP/Contents/MacOS/Edgeflow"
swiftc -O -target arm64-apple-macos14.0 mac_edge_fx.swift -o "$APP/Contents/Resources/edge-fx"
cp -R app/Resources/payload "$APP/Contents/Resources/payload"

echo "› Deskflow (GPL-2.0, https://github.com/deskflow/deskflow)"
[ -d "$DESKFLOW" ] || { echo "Deskflow.app not found at $DESKFLOW"; exit 1; }
ditto "$DESKFLOW" "$APP/Contents/Resources/Deskflow.app"

echo "› icon (design 1d 雙屏)"
ICONSET="$BUILD/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET" "$BUILD/icons"
swift app/make_icon.swift "$BUILD/icons" >/dev/null
for pair in 16:16 16@2x:32 32:32 32@2x:64 128:128 128@2x:256 256:256 256@2x:512 512:512 512@2x:1024; do
  name=${pair%%:*}; px=${pair##*:}
  base=${name%@2x}; suffix=""; [ "$name" != "$base" ] && suffix="@2x"
  cp "$BUILD/icons/icon_$px.png" "$ICONSET/icon_${base}x${base}${suffix}.png"
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Edgeflow</string>
  <key>CFBundleDisplayName</key><string>Edgeflow</string>
  <key>CFBundleIdentifier</key><string>local.edgeflow</string>
  <key>CFBundleExecutable</key><string>Edgeflow</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>100</string>
  <key>CFBundleDevelopmentRegion</key><string>zh_TW</string>
  <key>CFBundleLocalizations</key><array><string>zh_TW</string><string>en</string></array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Edgeflow 在同一個網路上尋找並連線到你要控制的電腦。 / Edgeflow finds and connects to the computer you control on the same network.</string>
  <key>NSBonjourServices</key><array>
    <string>_edgeflow._tcp</string><string>_workstation._tcp</string><string>_ssh._tcp</string>
    <string>_sftp-ssh._tcp</string><string>_rdp._tcp</string>
  </array>
  <key>NSDesktopFolderUsageDescription</key><string>把 Mac 截圖自動放進剪貼簿。 / Copies Mac screenshots to the clipboard.</string>
</dict></plist>
PLIST
# Sign with the local "Edgeflow Local Signing" certificate when it exists, so macOS keeps
# the Accessibility permission across rebuilds; otherwise ad-hoc.
ID=$(security find-identity -p codesigning 2>/dev/null | awk '/"Edgeflow Local Signing"/ {print $2; exit}')
codesign --force --sign "${ID:--}" "$APP/Contents/Resources/edge-fx"
codesign --force --sign "${ID:--}" "$APP"
codesign -dv "$APP" 2>&1 | grep -E "^Authority|Signature=adhoc" | head -1
if [ "${1:-}" = "--release" ]; then
  VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
  ZIP="$BUILD/Edgeflow-$VER-macOS-arm64.zip"
  rm -f "$ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
  echo "✓ $ZIP"
  exit 0
fi
rm -rf /Applications/Edgeflow.app
cp -R "$APP" /Applications/
echo "✓ /Applications/Edgeflow.app"
