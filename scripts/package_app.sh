#!/bin/bash
# Build SDRGB + its privileged helper, assemble a signed .app bundle.
#
# Signing identity: defaults to the Developer ID Application cert (needed for the
# SMAppService privileged helper to register and for notarization). Override with
# SIGN_IDENTITY=- for an ad-hoc dev build (the app still runs; lid-closed then
# uses the sudo fallback instead of the helper).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/SDRGB.app"
CONFIG="${1:-release}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Joshua Gourneau (8LL2JEMH4P)}"

HELPER_LABEL="com.gourneau.SDRGB.helper"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --package-path "$ROOT"
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchDaemons"
cp "$BIN/SDRGB" "$APP/Contents/MacOS/SDRGB"
cp "$BIN/SDRGBHelper" "$APP/Contents/MacOS/SDRGBHelper"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Stamp the version shown in the app (gear menu). release.sh passes APP_VERSION
# from the release tag; default to a git describe so dev bundles aren't stale.
APP_VERSION="${APP_VERSION:-$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || echo dev)}"
APP_VERSION="${APP_VERSION#v}"   # strip leading v from tags like v0.1.0-beta.3
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" \
    "$APP/Contents/Info.plist" 2>/dev/null || true
echo "==> version $APP_VERSION"

# LaunchDaemon plist for SMAppService (runs the helper as root, on demand).
cat > "$APP/Contents/Library/LaunchDaemons/$HELPER_LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$HELPER_LABEL</string>
	<key>BundleProgram</key>
	<string>Contents/MacOS/SDRGBHelper</string>
	<key>MachServices</key>
	<dict>
		<key>$HELPER_LABEL</key>
		<true/>
	</dict>
	<key>AssociatedBundleIdentifiers</key>
	<array>
		<string>com.gourneau.SDRGB</string>
	</array>
</dict>
</plist>
PLIST

# Sign inner-to-outer: helper first, then the app bundle. Hardened runtime +
# secure timestamp so the result is notarizable.
SIGN_FLAGS=(--force --options runtime --timestamp)
if [ "$SIGN_IDENTITY" = "-" ]; then SIGN_FLAGS=(--force); fi

echo "==> codesign helper ($SIGN_IDENTITY)"
codesign "${SIGN_FLAGS[@]}" --identifier "$HELPER_LABEL" \
    --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/SDRGBHelper"

echo "==> codesign app ($SIGN_IDENTITY)"
codesign "${SIGN_FLAGS[@]}" --sign "$SIGN_IDENTITY" "$APP"

echo "==> verify"
codesign --verify --strict --verbose=2 "$APP" 2>&1 | tail -2 || true

echo "==> done: $APP"
echo "    open \"$APP\"   # or copy it to /Applications"
