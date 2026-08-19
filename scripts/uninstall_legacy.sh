#!/bin/bash
# Remove a pre-rename SDRGB installation.
#
# The app's bundle identifier changed from com.gourneau.SDRGB to
# com.gourneau.SidePulse. SMAppService registrations are keyed to the bundle that
# made them, so the new app cannot deregister the old one — the old root
# LaunchDaemon (com.gourneau.SDRGB.helper) and its Login Items approval would
# otherwise linger forever. Run this once, before installing SidePulse.app.
#
#   scripts/uninstall_legacy.sh
set -uo pipefail

OLD_APP="/Applications/SDRGB.app"
OLD_LABEL="com.gourneau.SDRGB.helper"
OLD_SUDOERS="/etc/sudoers.d/sdrgb-disablesleep"

echo "==> removing the old login item"
if [ -x "$OLD_APP/Contents/MacOS/SDRGB" ]; then
    # The old build's own maintenance flag: unregisters the login item and quits
    # without starting up or touching any device volume.
    "$OLD_APP/Contents/MacOS/SDRGB" --unregister-login || true
else
    echo "    $OLD_APP not present, skipping"
fi

echo "==> unregistering the old privileged helper (needs admin)"
if sudo launchctl print "system/$OLD_LABEL" >/dev/null 2>&1; then
    sudo launchctl bootout "system/$OLD_LABEL" || true
    echo "    booted out $OLD_LABEL"
else
    echo "    $OLD_LABEL was not registered"
fi

if [ -f "$OLD_SUDOERS" ]; then
    echo "==> removing the old passwordless sleep rule"
    sudo rm -f "$OLD_SUDOERS"
fi

if [ -d "$OLD_APP" ]; then
    echo "==> removing $OLD_APP"
    rm -rf "$OLD_APP"
fi

cat <<'DONE'

Done. If "SDRGB" still appears in System Settings → General → Login Items,
select it and press the minus button — macOS keeps that entry until the record
is pruned. Then install SidePulse.app and approve it once when prompted.
DONE
