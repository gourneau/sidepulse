# Troubleshooting a stuck SDRGB / USBDOT device

Field notes for when the LED device (and often **Finder / the whole Mac**) gets
stuck. This is a real, repeatable macOS bug — these are the symptoms, how to
confirm it, and how to fix it without a reboot.

## TL;DR fix

```sh
sudo pkill -9 -f com.apple.fskit.msdos     # kill the hung FAT driver
diskutil list                               # find the device disk, e.g. "SDRGB ... disk7"
diskutil mount disk7                         # remount it (no replug needed)
```

In the app: menu-bar lightbulb → **Repair** (or gear ⚙ → *Reconnect / repair
device*). It does exactly the above, **passwordless** via the privileged helper,
and **auto-repair** (default on) tries it ~30 s after a wedge.

## What's actually happening

- The device is an **emulated** USB/SD mass-storage volume (FAT). macOS drives it
  with its newish **userspace FAT driver**:
  `/System/Library/ExtensionKit/Extensions/com.apple.fskit.msdos.appex/Contents/MacOS/com.apple.fskit.msdos`
- When the device **resets itself** (e.g. it briefly powers down / factory-resets
  — you may see the **LEDs flash white** as the Mac powers off/sleeps), macOS is
  left with **stale cached FAT state**. The `com.apple.fskit.msdos` process then
  **spins at ~100% CPU** and the volume's I/O **hangs forever**.
- It's **not a CPU problem** (you have spare cores — your browser still works).
  It's an **I/O-wait** problem: anything that *touches the volume* blocks waiting
  on the wedged driver. That's why **Finder hangs**, `open`/**app launches fail**
  (`-600`), and the device is unusable — but unrelated apps are fine.
- A write in this state can be an **uninterruptible kernel wait** that `kill -9`
  on the *waiter* can't clear. The thing you must kill is the **driver**
  (`com.apple.fskit.msdos`), not the app.

## Symptoms checklist

- LEDs frozen / not responding to writes; or LEDs flashed white right before a
  power-off/sleep.
- Finder beachballs when opening a folder or showing the device.
- Apps won't launch (`open` returns `-600`); SDRGB.app doesn't appear in the menu bar.
- The device is missing from `/Volumes`, **or** present but any access hangs.

## Diagnose

```sh
# Is the FAT driver pegged? (look for ~100% com.apple.fskit.msdos)
ps -axo pid,%cpu,command | grep com.apple.fskit.msdos | grep -v grep

# Is the disk still physically there (just unmounted)?
diskutil list            # look for a tiny volume named SDRGB / USBDOT, note its diskN

# Safe volume listing (NEVER `ls -la /Volumes` while wedged — it stats into the
# mount and hangs). Names only:
ls /Volumes

# For your board dev:
log show --last 1d --style syslog --info --debug   # huge; filter to fskit/msdos
sudo fs_usage -w        # run while it reproduces
diskutil list
```

## Fix (no reboot)

1. **Kill the hung driver** (root): `sudo pkill -9 -f com.apple.fskit.msdos`
   launchd relaunches a clean instance; Finder / `open` / everything waiting on it
   unsticks within a few seconds.
2. **Remount** — the card stays present as a raw disk after the kill:
   `diskutil mount disk7` (use the identifier from `diskutil list`), or
   `diskutil mount SDRGB`. `/Volumes/SDRGB` comes back.

You do **not** need to replug or power-cycle. (There's no supported way to
power-cycle the built-in SD-reader slot from macOS anyway; `eject` just logically
removes the card and needs a physical reinsert. Remount is the real recovery.)

## How the app automates this

- **Detection:** on launch and ongoing, a cheap `ps` checks for a ~100%
  `com.apple.fskit.msdos` (never touches the device). If found, a **Repair?**
  banner appears (this also frees a stuck Finder).
- **Repair (root, passwordless):** via the SMAppService privileged helper —
  `pkill` the driver, force-unmount, then remount by name **and** by disk
  identifier (`diskutil mountDisk diskN`).
- **Auto-repair:** ~30 s after the device looks wedged/disconnected, it runs the
  repair once, silently (only if the helper is already approved). Toggle in the
  gear menu (default on).
- **Never hangs the UI:** all device I/O is in timeout-bounded child processes;
  detection matches volumes by **name only** (no statting into a wedged mount).

## If software repair doesn't bring it back

The kill + remount resolves the common fskit-wedge, so run **Repair** a couple of
times first. If the disk is truly gone from `diskutil list`:

- **Last resort:** reboot.
- Physically reseating the card/device also works, but it's awkward to get in/out
  — avoid it unless nothing else does.

## Notes for the firmware/board side

The root trigger is the device **resetting itself** (to factory) while mounted,
which desyncs macOS's cached FAT state and wedges `com.apple.fskit.msdos`. If the
device can avoid resetting while the host has it mounted (or signal the host to
unmount first), the host-side wedge would stop happening. The macOS
`fskit.msdos` driver handling this case poorly is an Apple bug (the code is open
source); the host-side mitigations here are the practical workaround.
