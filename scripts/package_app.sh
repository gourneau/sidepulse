#!/bin/bash
# Build SDRGB and assemble a runnable .app bundle (menu-bar agent, no dock icon).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/SDRGB.app"
CONFIG="${1:-release}"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --package-path "$ROOT"
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/SDRGB"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SDRGB"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

echo "==> ad-hoc codesign"
codesign --force --sign - "$APP"

echo "==> done: $APP"
echo "    open \"$APP\"   # or copy it to /Applications"
