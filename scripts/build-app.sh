#!/bin/sh
# Builds release binaries and assembles build/DevStore.app (ad-hoc signed, not notarized).
set -eu
cd "$(dirname "$0")/.."
swift build -c release
APP=build/DevStore.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp .build/release/DevStoreApp "$APP/Contents/MacOS/DevStore"
# CLI and MCP server ride along in Helpers/ (not MacOS/: "devstore" and "DevStore"
# collide on case-insensitive APFS).
cp .build/release/devstore .build/release/devstore-mcp "$APP/Contents/Helpers/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>DevStore</string>
  <key>CFBundleIdentifier</key><string>local.devstore.app</string>
  <key>CFBundleName</key><string>DevStore</string>
  <key>CFBundleDisplayName</key><string>DevStore</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
</dict>
</plist>
PLIST
codesign --force --deep --sign - "$APP"
echo "built $APP"
