#!/bin/bash
# Install the claude-desktop-switch CLI and build "Claude Desktop Switcher.app".
#   ./install.sh            install CLI + menu bar app
#   ./install.sh --cli-only install only the CLI
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HOME/.local/bin"
APP="$HOME/Applications/Claude Desktop Switcher.app"

mkdir -p "$BIN"
install -m 755 "$HERE/claude-desktop-switch.py" "$BIN/claude-desktop-switch"
echo "Installed CLI: $BIN/claude-desktop-switch"
case ":$PATH:" in *":$BIN:"*) ;; *) echo "  note: add $BIN to your PATH" ;; esac

[ "${1:-}" = "--cli-only" ] && exit 0

command -v swiftc >/dev/null || { echo "swiftc not found: install Xcode or the Command Line Tools (xcode-select --install)"; exit 1; }

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13" \
  -o "$BUILD/ClaudeDesktopSwitcher" "$HERE/menubar/main.swift"

mkdir -p "$BUILD/app/Contents/MacOS"
cp "$BUILD/ClaudeDesktopSwitcher" "$BUILD/app/Contents/MacOS/"
cat > "$BUILD/app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.claude-desktop-switcher</string>
  <key>CFBundleName</key><string>Claude Desktop Switcher</string>
  <key>CFBundleExecutable</key><string>ClaudeDesktopSwitcher</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Quits Claude Desktop before switching accounts.</string>
</dict>
</plist>
PLIST
codesign --force --sign - --identifier local.claude-desktop-switcher "$BUILD/app"

# Replace a running copy cleanly
pkill -x ClaudeDesktopSwitcher 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$APP"
mv "$BUILD/app" "$APP"
echo "Installed app: $APP"
open "$APP"
