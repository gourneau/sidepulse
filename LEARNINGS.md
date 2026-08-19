# SidePulse — Learnings & Important Info

Hard-won notes about the device, the macOS gotchas, and the app's design. Read
this before changing the I/O, signing, or device-detection code.

## The device

- An LED controller that presents over USB as a tiny **mass-storage (FAT/msdos)
  volume**. You drive the LEDs by writing a small DSL program to **`LEDS.LED`**.
- Two variants, identified by **volume name**:
  - **SidePulse Pro** → **8 LEDs** (SD card slot)
  - **SidePulse Dot** → **2 LEDs** (USB-C)
  - Shipping units mount as plain `/Volumes/SidePulse`, with no model in the name.
  - The CH32X035 can present as **USB-MSC and an SD card at the same time** → more
    than one matching volume can be mounted at once.
- **`LEDS.LED` DSL** (see `LEDS_FORMAT.md`): `#rrggbb`, `off`, positional lists,
  indexed `0:#ff00ee`, `brightness 0-255`, per-segment timing/easing
  (`330ms`/`0.33s`, `ease`, `cosine`, `pulse`…), `repeat`. **Hard limits: ≤512
  bytes and ≤20 physical lines**, durations ≤65535 ms. A parse error blinks all
  LEDs red 6× — so every
  program the app emits is validated first (`LEDProgram.validate`).
- Animations run **on the device firmware** (write the looping program once, it
  loops). So good animations cost ~zero ongoing I/O; only Info mode + live drags
  write repeatedly.

## ⚠️ The big one: the emulated FAT filesystem is unstable

These devices are **emulated** mass storage, and macOS's **new userspace FAT
driver** handles them poorly:

- Process: `/System/Library/ExtensionKit/Extensions/com.apple.fskit.msdos.appex/Contents/MacOS/com.apple.fskit.msdos`
- **Failure mode:** when the device resets itself (e.g. it briefly powers down /
  factory-resets — we've seen the LEDs flash white as the Mac powers off), macOS
  keeps **stale cached FAT state**, the `com.apple.fskit.msdos` process **spins at
  100% CPU**, and the volume becomes unusable. Finder/terminal/anything touching
  it hangs. Normally only a **reboot** clears it.
- A *write* in this state can enter an **uninterruptible kernel I/O wait** — a
  hung thread that `kill -9` can't stop and that can stall the whole filesystem
  layer (we wedged the Mac hard early on, before the safeguards below).

### Non-reboot recovery (what "Repair" does)

The real fix without rebooting is to **kill the hung FAT driver** so launchd
relaunches it fresh, then remount:

```sh
sudo pkill -9 -f com.apple.fskit.msdos
sleep 1
sudo diskutil unmount force /Volumes/SidePulse
sudo diskutil mount SidePulse
```

This needs **root**. In the app it runs through the privileged helper (below), so
it's passwordless after the one-time approval. **Auto-repair** does this once,
~30s after the device looks wedged/disconnected (only if it can run silently).

**Recovery is software-only — no replug/power-cycle needed.** After the driver is
killed the card stays present as a raw disk (e.g. `diskutil list` shows
`/dev/disk7  SidePulse`, unmounted). Just remount it: `diskutil mount disk7` (or
`diskutil mount SidePulse`) brings `/Volumes/SidePulse` back. macOS has **no supported way
to power-cycle the built-in SD reader slot** (its power is reader-managed; `eject`
only logically removes it and needs a physical reinsert) — but you don't need to,
because remount works. So Repair = kill `fskit.msdos` → `diskutil mount`.

### Diagnosing

```sh
ps -axo pid,%cpu,command | grep fskit         # look for ~100% com.apple.fskit.msdos
diskutil list                                  # is the disk still there?
log show --last 1d --style syslog --info --debug
sudo fs_usage -w                               # while it reproduces
```

## App architecture (and why)

- **All device I/O is off the main thread, in a throwaway child process, with a
  hard timeout** (`DeviceManager.performWrite/performRead/runIsolated`,
  `ioTimeout = 5s`). A wedged device gets stuck in that *child*, never the app —
  the UI stays responsive and the app quits cleanly. Per-device **single-flight**:
  one op per volume at a time; a volume whose op times out is marked **stuck** and
  skipped until reconnect.
- **Detection matches by mount name only** (`knownLEDCounts`) — it never `stat`s
  *into* a volume, because statting a wedged FAT mount hangs. Listing `/Volumes`
  is safe.
- **Keepalive is a zero-byte write to `keepalive`** every 60s. It truncates before
  touching: a bare `touch` on an existing file can be served from the VFS cache
  without reaching the card, and the exit status drives `lastHeartbeatOK`. Host I/O
  keeps the link alive, and a read is far less likely to wedge the device than a
  write.
- **Single instance** only (concurrent writers were a big part of early wedges).
- Menu-bar (`MenuBarExtra`, `LSUIElement`), no Dock icon.

## Privileged helper (root) — for distribution

Lid-closed keep-awake (`pmset disablesleep`) and Repair (kill fskit + remount)
need root. Two paths:

- **Signed build (shipping):** an **SMAppService LaunchDaemon helper**
  (`Sources/SidePulseHelper`) running as root, talked to over **XPC**
  (`HelperProtocol`). Approve once in **System Settings → Login Items**, then
  every call is **passwordless forever**. The helper only accepts XPC from our
  app, signed by **the same Team** (Team is read from the helper's *own*
  signature at runtime — no hardcoded Team ID).
- **Unsigned dev build (`swift run`):** falls back to a one-time passwordless
  `sudo` rule (lid-closed) / an admin `osascript` prompt (repair).

Why not just edit sudoers in the shipping app? `AuthorizationExecuteWithPrivileges`
and editing `/etc/sudoers.d` are deprecated/discouraged and a security smell;
they're fine locally but not for a distributed app. SMAppService is the
Apple-sanctioned way. **Needs a Developer ID Application cert** (we have Team
`8LL2JEMH4P`). Not possible via the Mac App Store / TestFlight (sandbox).

## Signing & shipping

- `scripts/package_app.sh` builds app + helper, embeds the helper +
  `Contents/Library/LaunchDaemons/<label>.plist`, and signs both with
  **Developer ID Application** + **hardened runtime** (notarizable). Override with
  `SIGN_IDENTITY=-` for an ad-hoc dev build (helper won't register → fallbacks).
- Notarize before distributing (see README "Shipping").

## macOS gotchas hit along the way

- **Native `ColorPicker`/`NSColorPanel` is unreliable in a menu-bar popover** (the
  popover loses key focus → changes don't apply). The app uses a custom inline
  `ColorEditor` instead.
- **AppleDouble `._` files**: macOS tags app-written files with
  `com.apple.provenance`, which FAT can't store → spawns `._NAME`. We write via a
  child `cat >` + `xattr -c` + remove the `._` sibling.
- **Accessory apps open windows behind the popover** — the spec window flips
  activation policy to `.regular` while open, back to `.accessory` on close.
- **Lid-open keep-awake** (`IOPMAssertionCreateWithName`) can't stop lid-*close*
  sleep — that needs `pmset disablesleep` (root). `SleepDisabled` clears on reboot.
- Tooltips: the system `.help()` delay felt bad and a floating overlay on a tiny
  icon rendered badly; hover details now appear in the header's device slot.

## Repo

- `github.com/gourneau/sidepulse` (branch `main`).
- The app was called SDRGB until the device shipped as **SidePulse**; the bundle
  id is now `com.gourneau.SidePulse`. Anyone upgrading from an SDRGB build must
  run `scripts/uninstall_legacy.sh` first — see the README.
