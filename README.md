# SDRGB

A tiny macOS **menu-bar app** to control [sdstatusbar](https://github.com/unrelatedlabs/sdstatusbar)
LED devices — and, most importantly, a **keepalive that touches each device every
2 minutes** so it stays alive.

## What it does

- Lives in the menu bar (lightbulb icon), no dock icon.
- **Keepalive**: every 2 minutes it gently **reads** `STATUS.TXT` on every
  connected device to keep the USB/SD link alive. A read keeps the link active
  without the wedge risk of writing, and never disturbs the LED animation. (If a
  read turns out not to keep your firmware awake, that's the one thing to revisit
  — see Fault tolerance below.)
- **Color** tab: an inline color editor (swatches + RGB sliders) + brightness.
  Updates **live** as you drag — no Apply button. Plus an Off button.
- **Per-LED** tab: tap an LED to select it, then edit its color live (8 LEDs for
  `SDRGB`, 2 for `USBDOT`).
- **Presets**: Rainbow (smooth flowing hue gradient), Breathe, Sparkle, White,
  Off. Animated presets have an **Animated** toggle and a **Speed** slider
  (Slow…Fast); plus a brightness slider. All re-apply live.
- **Modes**: show live system info on the whole strip. Toggle metrics on and each
  fills the full strip in its color to its level — Battery (white), CPU (blue),
  Memory (green). Enable several and it **cycles** between them; a **Time between
  modes** slider (2–30s) sets the cadence. Only writes when the displayed bar
  changes. Picking a color or preset takes back manual control.
- **DSL** tab: shows the **actual `LEDS.TXT` currently on the device** (with a
  **Reload** button) so you can see the running program and edit it. Live
  512-byte / 10-line validation, a **Format help** button with the full DSL
  reference, and a "Writing…" busy state.
- **Status banner**: clear success/warning/error messages (e.g. "Updated SDRGB",
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
- **Keepalive is a read, not a write** (see above).

Maintenance: `SDRGB.app/Contents/MacOS/SDRGB --unregister-login` removes the
launch-at-login item without starting the app or touching any device.

None of this can *fully* prevent a determined hardware/driver stall — the surest
safety is to not run Info mode 24/7 and to use whichever connection (USB `USBDOT`
vs the SD slot) proves more stable.

## Device detection

Any mounted volume containing both `LEDS.TXT` and `STATUS.TXT` is treated as a
device. LED counts: `SDRGB` → 8, `USBDOT` → 2, anything else → 2. The CH32X035 can
appear as both a USB-MSC volume and the SD card at once — both are detected, you
pick which one colors go to, and the keepalive runs on all of them.

## Build & run

```sh
# dev: run straight from SwiftPM
swift run

# build a real app bundle (menu-bar agent, ad-hoc signed)
scripts/package_app.sh
open build/SDRGB.app
```

To install permanently and use "Launch at login":

```sh
cp -R build/SDRGB.app /Applications/
open /Applications/SDRGB.app
```

## Lid-closed keep-awake: privileged helper

Lid-closed keep-awake needs root (`pmset disablesleep`). The shippable design uses
a **privileged `SMAppService` LaunchDaemon helper + XPC** (`SDRGBHelper`):

- The helper (`Sources/SDRGBHelper`) is a tiny root daemon vending one XPC method
  (`setDisableSleep`). It only accepts connections from this app signed by the
  **same Team** (the Team is read from the helper's own signature at runtime — no
  hardcoded Team ID; see `Sources/SDRGBShared/HelperProtocol.swift`).
- The app registers it via `SMAppService.daemon`. First enable → macOS asks you to
  **approve "SDRGB" in System Settings → General → Login Items** (Allow in the
  Background). After that, toggling is **passwordless forever** over XPC.
- Unsigned/dev builds (`swift run`, or `SIGN_IDENTITY=-`) can't register a daemon,
  so they fall back to a one-time passwordless `sudo` rule.

This requires a **Developer ID Application** signing identity (the helper won't
register otherwise). `scripts/package_app.sh` signs both with it + hardened runtime.

## Shipping (Developer ID + notarized)

```sh
# build + sign (uses the Developer ID identity in package_app.sh)
scripts/package_app.sh

# one-time: store notary credentials
xcrun notarytool store-credentials sdrgb-notary \
  --apple-id "<your apple id>" --team-id 8LL2JEMH4P --password "<app-specific-password>"

# notarize + staple
ditto -c -k --keepParent build/SDRGB.app build/SDRGB.zip
xcrun notarytool submit build/SDRGB.zip --keychain-profile sdrgb-notary --wait
xcrun stapler staple build/SDRGB.app
```

Distribute the stapled `SDRGB.app` (e.g. zipped or in a DMG). This is a Developer
ID / direct-download app — the privileged helper is **not** compatible with the
sandboxed Mac App Store / TestFlight.

## Requirements

- macOS 13+ (uses SwiftUI `MenuBarExtra`, `SMAppService`, XPC).
- Swift toolchain (`swift build`); a Developer ID for the signed helper build.
