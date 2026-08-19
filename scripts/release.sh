#!/bin/bash
# One-shot local release: build → sign (Developer ID) → notarize → staple →
# zip → publish a GitHub prerelease. Use this when you don't want to rely on CI
# (e.g. your Mac is newer than the GitHub runners).
#
#   scripts/release.sh v0.1.0-beta.3 ["release notes"]
#
# Notarization credentials, resolved in this order:
#   1. A stored notarytool keychain profile named "sidepulse-notary". "sdrgb-notary"
#      is also accepted: it is the name this Mac's existing App Store Connect
#      credential was stored under, and re-storing it is the only way to drop that
#      (xcrun notarytool store-credentials sidepulse-notary --key AuthKey_XXXX.p8 \
#         --key-id XXXX --issuer <issuer-uuid>)
#   2. Otherwise: an App Store Connect API key file AuthKey_*.p8 in the repo root,
#      with the Issuer ID in .env as  ISSUER_ID=<uuid>  (Key ID is read from the
#      .p8 filename). These files are gitignored.
set -euo pipefail

TAG="${1:?usage: scripts/release.sh <tag> [notes]}"
NOTES="${2:-Notarized & stapled build — runs on any Mac with no Gatekeeper prompt. macOS 13+.}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
APP="build/SidePulse.app"
ZIP="build/SidePulse.zip"
NZIP="build/SidePulse-notarize.zip"

echo "==> 1/5 build + sign"
export APP_VERSION="${TAG#v}"   # stamp the release version into the bundle
scripts/package_app.sh >/dev/null
# Capture first, then grep: piping `codesign | grep -q` under `set -o pipefail`
# can fail spuriously — grep -q closes the pipe on first match, codesign gets
# SIGPIPE and exits non-zero, and pipefail reports the whole pipeline failed.
SIGN_INFO="$(codesign -dv --verbose=2 "$APP" 2>&1 || true)"
echo "$SIGN_INFO" | grep -q "Developer ID Application" \
  || { echo "ERROR: app is not Developer ID signed (set SIGN_IDENTITY)."; exit 1; }

echo "==> 2/5 notarize (Apple scan, ~1-5 min)"
rm -f "$NZIP"; ditto -c -k --keepParent "$APP" "$NZIP"
# A profile that exists but is rejected by Apple is a completely different
# problem from one that was never set up, and reporting both as "no notary
# profile found" sends you looking for a missing credential that is right there.
NOTARY_PROFILE=""
NOTARY_ERROR=""
for candidate in sidepulse-notary sdrgb-notary; do
  if OUT="$(xcrun notarytool history --keychain-profile "$candidate" 2>&1)"; then
    NOTARY_PROFILE="$candidate"; break
  fi
  case "$OUT" in
    *"No Keychain password item found"*) : ;;   # simply not set up; try the next
    *) NOTARY_ERROR="$candidate: $(printf '%s' "$OUT" | tr '\n' ' ')" ;;
  esac
done
if [ -z "$NOTARY_PROFILE" ] && [ -n "$NOTARY_ERROR" ]; then
  echo "ERROR: a notarytool keychain profile exists, but Apple rejected it:" >&2
  echo "  $NOTARY_ERROR" >&2
  echo >&2
  echo "  'A required agreement is missing or has expired' is an account-level" >&2
  echo "  problem, not a credential one: sign in at developer.apple.com (and" >&2
  echo "  App Store Connect) as the Account Holder and accept the pending" >&2
  echo "  agreements, then re-run this script. Nothing has been tagged or" >&2
  echo "  published — $APP is built and Developer ID signed, just not notarized." >&2
  exit 1
fi
if [ -n "$NOTARY_PROFILE" ]; then
  echo "    using keychain profile $NOTARY_PROFILE"
  xcrun notarytool submit "$NZIP" --keychain-profile "$NOTARY_PROFILE" --wait
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
gh release create "$TAG" --prerelease --title "SidePulse $TAG" --notes "$NOTES" "$ZIP"

echo "==> done: https://github.com/gourneau/sidepulse/releases/tag/$TAG"
