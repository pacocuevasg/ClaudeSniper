#!/bin/zsh
# Compila ClaudeSniper y lo instala en /Applications/ClaudeSniper.app
set -e
cd "$(dirname "$0")"
APP=/Applications/ClaudeSniper.app
BUILD=build/ClaudeSniper.app

rm -rf build && mkdir -p "$BUILD/Contents/MacOS"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" main.swift -o "$BUILD/Contents/MacOS/ClaudeSniper"

cat > "$BUILD/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.pacocuevas.ClaudeSniper</string>
  <key>CFBundleName</key><string>ClaudeSniper</string>
  <key>CFBundleDisplayName</key><string>ClaudeSniper</string>
  <key>CFBundleExecutable</key><string>ClaudeSniper</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

codesign --force --deep -s - "$BUILD"
pkill -x ClaudeSniper 2>/dev/null || true
rm -rf "$APP" && cp -R "$BUILD" "$APP"
echo "Instalado en $APP"
