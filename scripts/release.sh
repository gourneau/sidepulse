#!/bin/bash
# One-shot local release: build → sign (Developer ID) → notarize → staple →
# zip → publish a GitHub prerelease. Use this when you don't want to rely on CI
# (e.g. your Mac is newer than the GitHub runners).
#
#   scripts/release.sh v0.1.0-beta.3 ["release notes"]
#
# Notarization credentials, resolved in this order:
#   1. A stored notarytool keychain profile named "sdrgb-notary"
#      (xcrun notarytool store-credentials sdrgb-notary --key AuthKey_XXXX.p8 \
#         --key-id XXXX --issuer <issuer-uuid>)
#   2. Otherwise: an App Store Connect API key file AuthKey_*.p8 in the repo root,
#      with the Issuer ID in .env as  ISSUER_ID=<uuid>  (Key ID is read from the
#      .p8 filename). These files are gitignored.
set -euo pipefail

TAG="${1:?usage: scripts/release.sh <tag> [notes]}"
NOTES="${2:-Notarized & stapled build — runs on any Mac with no Gatekeeper prompt. macOS 13+.}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
APP="build/SDRGB.app"
ZIP="build/SDRGB.zip"
NZIP="build/SDRGB-notarize.zip"

echo "==> 1/5 build + sign"
scripts/package_app.sh >/dev/null
codesign -dv --verbose=2 "$APP" 2>&1 | grep -q "Developer ID Application" \
  || { echo "ERROR: app is not Developer ID signed (set SIGN_IDENTITY)."; exit 1; }

echo "==> 2/5 notarize (Apple scan, ~1-5 min)"
rm -f "$NZIP"; ditto -c -k --keepParent "$APP" "$NZIP"
if xcrun notarytool history --keychain-profile sdrgb-notary >/dev/null 2>&1; then
  xcrun notarytool submit "$NZIP" --keychain-profile sdrgb-notary --wait
else
  KEY="$(ls AuthKey_*.p8 2>/dev/null | head -1 || true)"
  [ -n "$KEY" ] || { echo "ERROR: no notary profile and no AuthKey_*.p8 found."; exit 1; }
  KID="$(basename "$KEY" .p8 | sed 's/^AuthKey_//')"
  ISS="$(grep -E '^ISSUER_ID=' .env 2>/dev/null | sed -E 's/^ISSUER_ID=//' | tr -d " \r\n\"'")"
  [ -n "$ISS" ] || { echo "ERROR: ISSUER_ID not found in .env."; exit 1; }
  xcrun notarytool submit "$NZIP" --key "$KEY" --key-id "$KID" --issuer "$ISS" --wait
fi

echo "==> 3/5 staple + verify"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vv -t exec "$APP" 2>&1 | grep -E "accepted|Notarized" || true

echo "==> 4/5 zip stapled app"
rm -f "$ZIP" "$NZIP"; ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> 5/5 tag + publish GitHub prerelease $TAG"
git rev-parse "$TAG" >/dev/null 2>&1 || { git tag "$TAG"; git push origin "$TAG"; }
gh release create "$TAG" --prerelease --title "SDRGB $TAG" --notes "$NOTES" "$ZIP"

echo "==> done: https://github.com/gourneau/sdrgb/releases/tag/$TAG"
