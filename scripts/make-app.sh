#!/bin/sh
# Builds djlib and wraps it in WreckBox.app (so WebKit keeps your SoundCloud login and Finder can launch it).
set -e
cd "$(dirname "$0")/.."
REPO="$(pwd)"
CONFIG="${1:-release}"
swift build -c "$CONFIG"
APP="build/WreckBox.app"
rm -rf "$APP" "build/DJ Library.app"   # (the app's earlier name)
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/djlib" "$APP/Contents/MacOS/djlib"
cp -R Sources/djlib/Resources/Fonts "$APP/Contents/Resources/Fonts"
# App icon: the pixel record, rendered at every size from the same drawing as the sidebar logo.
ICONSET="$(mktemp -d)/WreckBox.iconset"
".build/$CONFIG/djlib" make-icon "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/WreckBox.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>WreckBox</string>
  <key>CFBundleDisplayName</key><string>WreckBox</string>
  <key>CFBundleIconFile</key><string>WreckBox</string>
  <key>CFBundleIdentifier</key><string>local.djlibrary.app</string>   <!-- unchanged: keeps the SoundCloud login -->
  <key>CFBundleExecutable</key><string>djlib</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSRequiresAquaSystemAppearance</key><false/>
  <key>DJLibRepoDir</key><string>$REPO</string>
</dict></plist>
PLIST
codesign --force --deep -s - "$APP"
echo "Built $APP"
