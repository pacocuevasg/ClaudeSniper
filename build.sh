#!/bin/zsh
# Builds ClaudeSniper and installs it to /Applications/ClaudeSniper.app
#
# Options (environment variables):
#   UNIVERSAL=1   build for Apple Silicon and Intel in one app
#   NO_INSTALL=1  only build into ./build (used by the GitHub release)
#   VERSION=1.2   version shown in Finder (default 1.0)
set -e
cd "$(dirname "$0")"
APP=/Applications/ClaudeSniper.app
BUILD=build/ClaudeSniper.app
VERSION=${VERSION:-1.0}

rm -rf build && mkdir -p "$BUILD/Contents/MacOS"
if [[ -n "$UNIVERSAL" ]]; then
  for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" main.swift -o "build/ClaudeSniper-$arch"
  done
  lipo -create build/ClaudeSniper-arm64 build/ClaudeSniper-x86_64 -output "$BUILD/Contents/MacOS/ClaudeSniper"
  rm build/ClaudeSniper-arm64 build/ClaudeSniper-x86_64
else
  swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" main.swift -o "$BUILD/Contents/MacOS/ClaudeSniper"
fi

cat > "$BUILD/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.pacocuevas.ClaudeSniper</string>
  <key>CFBundleName</key><string>ClaudeSniper</string>
  <key>CFBundleDisplayName</key><string>ClaudeSniper</string>
  <key>CFBundleExecutable</key><string>ClaudeSniper</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>ClaudeSniper exports a chat to Apple Notes when you ask it to.</string>
</dict></plist>
PLIST

codesign --force --deep -s - "$BUILD"
if [[ -n "$NO_INSTALL" ]]; then
  echo "Built $BUILD ($(lipo -archs "$BUILD/Contents/MacOS/ClaudeSniper"))"
  exit 0
fi
pkill -x ClaudeSniper 2>/dev/null || true
rm -rf "$APP" && cp -R "$BUILD" "$APP"
echo "Installed to $APP"
