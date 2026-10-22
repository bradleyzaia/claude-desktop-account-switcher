#!/bin/bash
# Build the app and zip it for a GitHub release.
#   scripts/package-release.sh   ->  dist/Claude-Desktop-Switcher-v<VERSION>.zip (+ .sha256)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
DIST="$ROOT/dist"
ZIP="Claude-Desktop-Switcher-v$VERSION.zip"

rm -rf "$DIST"
mkdir -p "$DIST"
APP="$("$ROOT/scripts/build-app.sh" "$DIST")"

# ditto keeps the bundle's code signature and extended attributes intact
(cd "$DIST" && ditto -c -k --keepParent "$(basename "$APP")" "$ZIP")
(cd "$DIST" && shasum -a 256 "$ZIP" > "$ZIP.sha256")
rm -rf "$APP"
echo "$DIST/$ZIP"
