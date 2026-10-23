#!/bin/bash
# Build a universal (arm64 + x86_64), ad-hoc signed "Claude Desktop Switcher.app".
#   scripts/build-app.sh <output-dir>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?usage: build-app.sh <output-dir>}"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
APP="$OUT/Claude Desktop Switcher.app"

command -v swiftc >/dev/null || { echo "swiftc not found: install Xcode or the Command Line Tools (xcode-select --install)" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos13" \
    -o "$TMP/ClaudeDesktopSwitcher-$arch" "$ROOT/menubar/main.swift"
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create -output "$APP/Contents/MacOS/ClaudeDesktopSwitcher" "$TMP"/ClaudeDesktopSwitcher-*
install -m 755 "$ROOT/claude-desktop-switch.py" "$APP/Contents/Resources/claude-desktop-switch.py"
install -m 644 "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.claude-desktop-switcher</string>
  <key>CFBundleName</key><string>Claude Desktop Switcher</string>
  <key>CFBundleExecutable</key><string>ClaudeDesktopSwitcher</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Quits Claude Desktop before switching accounts.</string>
</dict>
</plist>
PLIST

codesign --force --sign - --identifier local.claude-desktop-switcher "$APP" 2>/dev/null
echo "$APP"
