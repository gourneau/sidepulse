# SidePulse

A tiny macOS **menu-bar app** to control [SidePulse](https://github.com/inteliwear/sidepulse)
LED devices — and, most importantly, a **keepalive that touches each device every
minute** so it stays alive.

## What it does

- Lives in the menu bar (lightbulb icon), no dock icon.
- **Keepalive**: every minute it **touches** `keepalive` on
  every connected device — a dedicated file the firmware never parses, so the LED
  animation is never disturbed. A write is more "activity" than a read, which the
  device's firmware needs to stay awake. Click the **heart** in the header to see
  the keepalive log (last 24h).
- **Self-heal**: after each keepalive (and after the Mac wakes), if the device has
  restarted (its `uptime_ms` went backwards), the app silently
  re-applies the last program — so the LEDs come back without any user action.
  This is the fix for "woke up and the LEDs were off."
- **Activity log**: click the header **status dot** for the last 24h of events
  (updates, warnings, errors, repairs); click the **heart** for keepalive writes.
- **Color** tab: an inline color editor (swatches + RGB sliders) + brightness.
  Updates **live** as you drag — no Apply button. Plus an Off button.
- **Per-LED** tab: tap an LED to select it, then edit its color live (8 LEDs for
  SidePulse Pro, 2 for SidePulse Dot).
- **Presets**: Rainbow (smooth flowing hue gradient), Breathe, Sparkle, White,
  Off. Animated presets have an **Animated** toggle and a **Speed** slider
  (Slow…Fast); plus a brightness slider. All re-apply live.
- **Modes**: show live system info on the whole strip. Toggle metrics on and each
  fills the full strip in its color to its level — Battery (white), CPU (blue),
  Memory (green). Enable several and it **cycles** between them; a **Time between
  modes** slider (2–30s) sets the cadence. Only writes when the displayed bar
  changes. Picking a color or preset takes back manual control.
- **DSL** tab: shows the **actual `LEDS.LED` currently on the device** (with a
  **Reload** button) so you can see the running program and edit it. Live
  512-byte / 10-line validation, a **Format help** button with the full DSL
  reference, and a "Writing…" busy state.
- **Status banner**: clear success/warning/error messages (e.g. "Updated SidePulse",
  or what to do if a write fails).
- **Keep Mac awake**: a footer toggle that prevents the Mac from sleeping (so the
  keepalive keeps running while you're away). The default uses an IOKit power
  assertion (lid open, **no permissions**). An opt-in **"…even with the lid
  closed"** sets the kernel `SleepDisabled` flag via `pmset disablesleep`, which
  needs **admin** (one macOS password/Touch ID prompt); it reflects the real flag
  on launch, reverts on disable/quit, and clears on reboot. Keep the Mac on power
  in lid-closed mode — it can run warm.
- **Launch at login** toggle (works once installed in `/Applications`); a subtle
  keepalive line sits at the bottom — it should just work. Status detail (time)
  shows on hover, not as ticking numbers.

The inline color editor is used instead of the native macOS color picker on
purpose: the system `NSColorPanel` is unreliable inside a menu-bar (accessory)
app, so a self-contained editor is both more reliable and easy to make live.

## Fault tolerance

The device is a `CH32X035` microcontroller *emulating* a USB drive, and its tiny
mass-storage firmware can wedge under frequent writes — and a wedged write enters
an uninterruptible kernel I/O wait that can stall macOS's filesystem layer. To
contain that:

- **Animations run on the firmware.** Presets (rainbow, breathe, sparkle) are
  written once as looping DSL programs; the device animates them itself, so a good
  animation costs ~zero ongoing I/O.
- **All device I/O runs in a throwaway child process** with a 5s timeout. If the
  device wedges, only that child gets stuck (and is abandoned) — the app stays
  responsive and quits cleanly. The volume is marked "paused" until reconnected.
- **Per-device single-flight + gentle cadence.** Never more than one I/O op per
  device at a time; live edits throttle to ~5/s; Info mode cycles every 5s and
  only writes when the displayed bar changes.
- **Single instance.** A second copy won't launch (concurrent writers were a big
  part of what wedged the device).
- **Keepalive touches one zero-byte file** (`keepalive`) once a minute —
  bounded, single-flight, and isolated like every other write.

Maintenance: `SidePulse.app/Contents/MacOS/SidePulse --unregister-login` removes the
launch-at-login item without starting the app or touching any device.

None of this can *fully* prevent a determined hardware/driver stall — the surest
safety is to not run Info mode 24/7 and to use whichever connection (USB-C Dot
vs the SD slot) proves more stable.

## Device detection

A mounted volume is treated as a device when its name matches `SidePulse`,
`SidePulsePro` or `SidePulseDot` exactly (normalized) **and** it contains
`LEDS.LED`. Shipping units mount as plain `SidePulse`, so the LED count is read
from `INIT.LED` — the firmware seeds it with a per-index startup fill — falling
back to the name, then to the 8-LED Pro layout. The CH32X035 can
appear as both a USB-MSC volume and the SD card at once — both are detected, you
pick which one colors go to, and the keepalive runs on all of them.

## Build & run

```sh
# dev: run straight from SwiftPM
swift run

# build a real app bundle (menu-bar agent, ad-hoc signed)
scripts/package_app.sh
open build/SidePulse.app
```

To install permanently and use "Launch at login":

### Upgrading from SDRGB

The app used to be called **SDRGB**, with bundle id `com.gourneau.SDRGB`. The
rename changes the bundle id to `com.gourneau.SidePulse`, and macOS keys the
privileged-helper registration and the Login Items approval to the bundle that
made them — so the new app **cannot** clean up after the old one. Run this once
before installing:

```sh
scripts/uninstall_legacy.sh
```

It removes the old login item, boots out the old root LaunchDaemon
(`com.gourneau.SDRGB.helper`), drops the old sudoers rule, and deletes
`/Applications/SDRGB.app`. Then install SidePulse.app and approve the helper
once when prompted.

```sh
cp -R build/SidePulse.app /Applications/
open /Applications/SidePulse.app
```

## Lid-closed keep-awake: privileged helper

Lid-closed keep-awake needs root (`pmset disablesleep`). The shippable design uses
a **privileged `SMAppService` LaunchDaemon helper + XPC** (`SidePulseHelper`):

- The helper (`Sources/SidePulseHelper`) is a tiny root daemon vending one XPC method
  (`setDisableSleep`). It only accepts connections from this app signed by the
  **same Team** (the Team is read from the helper's own signature at runtime — no
  hardcoded Team ID; see `Sources/SidePulseShared/HelperProtocol.swift`).
- The app registers it via `SMAppService.daemon`. First enable → macOS asks you to
  **approve "SidePulse" in System Settings → General → Login Items** (Allow in the
  Background). After that, toggling is **passwordless forever** over XPC.
- Unsigned/dev builds (`swift run`, or `SIGN_IDENTITY=-`) can't register a daemon,
  so they fall back to a one-time passwordless `sudo` rule.

This requires a **Developer ID Application** signing identity (the helper won't
register otherwise). `scripts/package_app.sh` signs both with it + hardened runtime.

## Shipping (Developer ID + notarized)

**One command** (build → sign → notarize → staple → zip → GitHub prerelease):

```sh
scripts/release.sh v0.1.0-beta.3 ["optional notes"]
```

It uses a stored notarytool keychain profile named `sidepulse-notary` (set up once):

```sh
xcrun notarytool store-credentials sidepulse-notary \
  --key AuthKey_XXXXXX.p8 --key-id XXXXXX --issuer <issuer-uuid>
```

If no profile exists, `release.sh` falls back to an `AuthKey_*.p8` in the repo root
plus `ISSUER_ID=<uuid>` in `.env` (both gitignored).

There's also a CI path: pushing a `v*` tag runs `.github/workflows/release.yml`,
which does the same on a macOS runner using repo secrets. Either works; the script
is handy when your Mac is newer than the GitHub runners.

Distribute the stapled `SidePulse.app` (e.g. zipped or in a DMG). This is a Developer
ID / direct-download app — the privileged helper is **not** compatible with the
sandboxed Mac App Store / TestFlight.

## Requirements

- macOS 13+ (uses SwiftUI `MenuBarExtra`, `SMAppService`, XPC).
- Swift toolchain (`swift build`); a Developer ID for the signed helper build.
