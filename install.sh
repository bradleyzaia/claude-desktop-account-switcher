#!/bin/bash
# Install the claude-desktop-switch CLI and build "Claude Desktop Switcher.app".
#   ./install.sh            install CLI + menu bar app
#   ./install.sh --cli-only install only the CLI
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HOME/.local/bin"
DEST="$HOME/Applications"

mkdir -p "$BIN"
install -m 755 "$HERE/claude-desktop-switch.py" "$BIN/claude-desktop-switch"
echo "Installed CLI: $BIN/claude-desktop-switch"
case ":$PATH:" in *":$BIN:"*) ;; *) echo "  note: add $BIN to your PATH" ;; esac

[ "${1:-}" = "--cli-only" ] && exit 0

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
APP="$("$HERE/scripts/build-app.sh" "$BUILD")"

# Replace a running copy cleanly
pkill -x ClaudeDesktopSwitcher 2>/dev/null || true
mkdir -p "$DEST"
rm -rf "$DEST/Claude Desktop Switcher.app"
mv "$APP" "$DEST/"
echo "Installed app: $DEST/Claude Desktop Switcher.app"
open "$DEST/Claude Desktop Switcher.app"
