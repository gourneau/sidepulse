# CLAUDE.md — SDRGB

Guidance for working in this repo. See `README.md` for the user-facing feature
list, `LEARNINGS.md` / `TROUBLESHOOTING.md` for device + fskit-wedge debugging.

## What this is

A macOS **menu-bar app** (SwiftPM, `LSUIElement`, `MenuBarExtra(.window)`) that
controls **SidePulse** LED devices (a CH32X035 microcontroller emulating a
USB/SD mass-storage volume: SidePulse Pro = 8 LEDs in the SD slot, SidePulse Dot
= 2 LEDs over USB-C). Its core job is a **keepalive** that touches `keepalive` on
each device every minute so the SD reader doesn't power it down, plus a UI to
push colors/presets/Info-mode programs to `LEDS.LED`.

**Volume names:** shipping units mount as plain **`/Volumes/SidePulse`** — the
vendor docs promise `SidePulsePro` / `SidePulseDot`, so all three stems are
matched. Detection is an *exact* normalized-name match, never a prefix, because
the name-only scan runs on the main thread and feeds `deliver()`, which writes.

## Targets (Package.swift)

- **SDRGB** — the menu-bar app (executable).
- **SDRGBHelper** — a privileged root LaunchDaemon (executable), installed via
  `SMAppService`, vending XPC methods (`setDisableSleep`, `repair`, `version`).
- **SDRGBShared** — the XPC protocol + constants, compiled into both.
- **XPCAuditToken** — a tiny ObjC shim exposing `NSXPCConnection.auditToken` so
  the helper validates clients by audit token (not PID, which can be recycled).

## Build & run

```sh
swift build                 # debug build of all targets
swift run                   # run the app straight from SwiftPM (unsigned dev)
scripts/package_app.sh      # build + Developer ID sign app + helper → build/SDRGB.app
open build/SDRGB.app
```

- **Toolchain strictness:** local Swift is lenient about Swift-6 concurrency;
  the GitHub macOS runners are stricter. Keep it CI-clean: `[weak self]` on every
  escaping/`Task` closure that captures `self`, copy captured vars into a `let`
  before crossing an actor hop, and mark cross-actor closures `@Sendable` /
  `@MainActor` (e.g. repair `completion: @escaping @MainActor () -> Void`,
  `Preset.make` is `@Sendable`). The build should be **warning-free**.
- Unsigned `swift run` can't register the privileged daemon, so lid-closed
  keep-awake + repair fall back to a one-time admin prompt / sudoers rule.

## Shipping (Developer ID + notarized)

```sh
scripts/release.sh v0.1.0-beta.N ["optional notes"]   # build→sign→notarize→staple→zip→gh prerelease
```

- Signing: **Developer ID Application**, Team `8LL2JEMH4P`. Required for the
  helper to register (`SMAppService.daemon`); `package_app.sh` signs both with
  hardened runtime and embeds the LaunchDaemon plist.
- Notarization: `xcrun notarytool` via the stored keychain profile
  **`sdrgb-notary`**. If absent, `release.sh` falls back to `AuthKey_*.p8` in the
  repo root + `ISSUER_ID=<uuid>` in `.env`.
- CI: pushing a `v*` tag runs `.github/workflows/release.yml` (runs-on
  `macos-15`) which imports the cert from repo secrets and does the same. The
  local script is handy when your Mac is newer than the GitHub runners.

## Secrets — never commit

`.env` (holds `p12=<pw>` and `ISSUER_ID=<uuid>`), `dev.p12`, `AuthKey_*.p8` live
in the repo root and are **gitignored**. Never echo their values; never `git add`
them. `.env` is `KEY=value`, parsed after the first `=`. LibreSSL can't read a
Keychain-exported `.p12` — validate via `security import` into a temp keychain,
not `openssl`.

## Architecture notes that bite

- **`com.apple.fskit.msdos`** (macOS's userspace FAT driver) wedges at ~100% CPU
  when the emulated device resets. Recovery without reboot: kill it
  (`pkill -9 -f com.apple.fskit.msdos`) + `diskutil mount SidePulse`. The app
  does this via the root helper (`repair`) — passwordless after one-time Login
  Items approval. **Repair mounts by exact volume name only** — never parse
  `diskutil list` + `mountDisk` (it can force-mount an unrelated whole disk).
- **Two distinct stuck states, one repair.** (1) the CPU wedge above; (2) the
  **"ghost card"**: the SD reader sees the card (`system_profiler
  SPCardReaderDataType` shows Product Name `SPPulse`; older firmware said
  `SDLED…`) but it never enumerates as a block device — **absent from `diskutil list`/`/Volumes`, and no msdos process is
  even running**. `repair` now handles both: it kills the whole fskit user-space
  stack (`com.apple.fskit.msdos` + `libexec/fskit_agent` + `fskit_helper`) to force
  macOS to re-probe the card, then retries `diskutil mount <name>` a few times as
  the disk node reappears. `DeviceManager.checkDeviceHealth()` (the watchdog, run
  on each beat / scan-empty / wake) detects the ghost state via a bounded
  `system_profiler` child and arms auto-repair; `deviceGhosted` drives a UI banner.
- **All device I/O runs in a throwaway child process** (`runIsolated` /
  `readContents` / `performWrite`) with a hard `DispatchSemaphore` timeout
  (`ioTimeout` = 5s). A wedged device gets the child stuck (abandoned, contained),
  never the app. Per-device **single-flight** via `inFlightVolumes` /
  `stuckVolumes`. A D-state child can't be killed — that's expected; it's
  contained.
- **Never stat *into* a device volume on the main thread** — it can hang on a
  wedged mount. `scanVolumes()` matches by mount name; `scanVolumes(verify: true)`
  (background only) confirms `LEDS.LED` via a bounded isolated child — and reads
  `INIT.LED` in the same child to derive the LED count — so a same-named user
  volume isn't scribbled with `LEDS.LED`.
- **Self-heal keys off `uptime_ms`, not file content.** The firmware plays
  `INIT.LED` on power-up but **never rewrites `LEDS.LED`** — measured on a real
  unit, `LEDS.LED`'s mtime stayed a month stale across power cycles *and* a
  physical re-seat, while `uptime_ms` reset to ~1000. The volume stays mounted
  throughout, so mount events can't see it either. `healIfRestarted()` reads
  `STATUS.TXT` after each keepalive and re-applies `lastWrittenLEDS` when
  `uptime_ms` goes backwards. Root cause of "overnight LEDs off."
- **`STATUS.TXT`** is one `key value` per line, **NUL-padded** to 1024 bytes, and
  the host caches it for ~5s (irrelevant at a 60s beat).
- **Keep `DeviceManager` re-entrancy in mind:** `deliver()`'s no-device re-check
  updates selection in place (it must NOT call `applyScan`, which re-enters
  `beat()`/`showInfoFrame`); a background `rescan()` corrects it.
- **`LEDS.LED` DSL limits:** ≤512 bytes, ≤20 physical lines, durations ≤65535 ms
  (`LEDProgram.validate`). Measure with `LEDProgram.stats`, which counts the *wire*
  form — `deliver()` appends the trailing newline after validation.
- **`SpecText.swift` is generated** from `LEDS_FORMAT.md` by
  `scripts/embed_spec.sh` (`--check` verifies sync). It must stay a **raw**
  string literal: the spec's shell examples contain literal `\n`.
- **Single instance** is enforced in `SDRGBApp.init` (concurrent writers wedge
  the device). `--unregister-login` removes the login item and quits without
  touching any device.

## UI conventions

- Header **status dot** → click opens the 24h Activity window (events filter);
  **heart** → opens it (keepalive filter). Both use `.pointingCursor()` and fast
  native `.help()` tooltips (`NSInitialToolTipDelay` set to 80ms in
  `SDRGBApp.init`). The Activity window is a separate `Window(id: "activity")`
  scene brought to front with the same accessory→regular dance as the spec window.
