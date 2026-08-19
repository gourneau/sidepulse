# How SidePulse for Mac works

The detail that used to live in the README. If you are changing the code, read
[`CLAUDE.md`](../CLAUDE.md) too — it carries the invariants in a shorter form.

## Fault tolerance

The device is a `CH32X035` microcontroller *emulating* a USB drive, and its tiny
mass-storage firmware can wedge under frequent writes. A wedged write enters an
uninterruptible kernel I/O wait that can stall macOS's filesystem layer, so the app is
built to contain that rather than to hope it does not happen.

- **Animations run on the firmware.** Presets are written once as looping DSL programs and
  the device animates them itself, so a good animation costs about zero ongoing I/O.
- **All device I/O runs in a throwaway child process** with a 5-second timeout. If the
  device wedges, only that child gets stuck — it is abandoned, the app stays responsive and
  still quits cleanly, and the volume is marked paused until it reconnects.
- **Per-device single-flight, and a gentle cadence.** Never more than one operation in
  flight per device. Live edits throttle to roughly five writes a second; Info mode cycles
  every five seconds and only writes when the bar it would draw actually changes.
- **Single instance.** A second copy will not launch — concurrent writers were a large part
  of what wedged the device historically.
- **The keepalive touches one zero-byte file** (`keepalive`) once a minute, bounded,
  single-flight and isolated like every other write.

None of this can *fully* prevent a determined hardware or driver stall. The surest safety
is not to run Info mode around the clock, and to use whichever connection — the USB-C Dot
or the SD slot — proves more stable for you.

## Device detection

A mounted volume is treated as a device when its normalised name matches `SidePulse`,
`SidePulsePro` or `SidePulseDot` **exactly** and it contains `LEDS.LED`.

The match is exact rather than a prefix on purpose: the name-only scan runs on the main
thread and feeds the write path, so a prefix rule would adopt a volume called
"SidePulse Backup" and create `LEDS.LED` on it.

Shipping units mount as plain `SidePulse` with no model in the name, so the LED count comes
from `INIT.LED`, which the firmware seeds with a per-index startup fill. That is only
trusted while the file is still firmware-seeded — once "save as power-on default" has
overwritten it, it describes your program rather than the hardware. Learned counts are
remembered per volume and never shrink. Failing all that, the name decides, and failing
that, the 8-LED Pro layout.

The CH32X035 can appear as both a USB-MSC volume and the SD card at once. Both are
detected, you pick which one colours go to, and the keepalive runs on all of them.

## Self-heal

The firmware restores `LEDS.LED` from `INIT.LED` on power-up, but only when the two differ,
so the file's modification time can stay weeks stale across power cycles. Reads can also
come back clipped, because macOS keeps serving the previous cached directory-entry size.
Neither the mtime nor the content is a trustworthy signal.

So restart detection watches `uptime_ms` in `STATUS.TXT` and re-applies the last program
when it goes backwards. That holds regardless of what `LEDS.LED` contains, or how much of
it the host will hand back.

## Lid-closed keep-awake: the privileged helper

Lid-closed keep-awake needs root (`pmset disablesleep`), through a privileged
`SMAppService` LaunchDaemon and XPC:

- The helper (`Sources/SidePulseHelper`) is a tiny root daemon vending `setDisableSleep`
  and `repair`. It only accepts connections from this app signed by the **same Team**, and
  the Team is read from the helper's own signature at runtime rather than hardcoded — see
  `Sources/SidePulseShared/HelperProtocol.swift`.
- Clients are validated by **audit token**, not PID: a PID can be recycled between connect
  and check, an audit token cannot be forged.
- The app registers it via `SMAppService.daemon`. The first time you enable it, macOS asks
  you to approve **SidePulse** in System Settings → General → Login Items. After that,
  toggling is passwordless forever over XPC.
- Unsigned dev builds (`swift run`, or `SIGN_IDENTITY=-`) cannot register a daemon, so they
  fall back to a one-time passwordless `sudo` rule.

This needs a **Developer ID Application** identity — the helper will not register
otherwise. `scripts/package_app.sh` signs both with it plus the hardened runtime.

Maintenance: `SidePulse.app/Contents/MacOS/SidePulse --unregister-login` removes the
launch-at-login item without starting the app or touching any device.

## Shipping

One command — build, sign, notarise, staple, zip, publish a GitHub prerelease:

```sh
scripts/release.sh v0.3.0 ["optional notes"]
```

It uses a stored notarytool keychain profile named `sidepulse-notary` (or the older
`sdrgb-notary`, which is the name an existing credential on the author's Mac happens to be
stored under):

```sh
xcrun notarytool store-credentials sidepulse-notary \
  --key AuthKey_XXXXXX.p8 --key-id XXXXXX --issuer <issuer-uuid>
```

With no profile it falls back to an `AuthKey_*.p8` in the repo root plus `ISSUER_ID=<uuid>`
in `.env` — both gitignored.

Pushing a `v*` tag also runs `.github/workflows/release.yml`, which does the same on a
macOS runner using repo secrets. It stands down if the release already exists, so running
the local script and pushing its tag does not produce two conflicting releases.

Distribute the stapled `SidePulse.app`. This is a Developer ID / direct-download app — the
privileged helper is **not** compatible with the sandboxed Mac App Store.

## Assets

The LED animation in the README and on the website is generated, not filmed:

```sh
scripts/make_led_gif.sh        # renders frames, encodes docs/assets/led-strip.gif
python3 scripts/make_placeholders.py
```

`scripts/render_led_animation.py` runs the same DSL programs the app emits through the same
semantics the controller uses, so every frame is something the device would really display.
See [`assets/README.md`](assets/README.md) for swapping in real screenshots.

## Requirements

- macOS 13 or later — the app uses SwiftUI `MenuBarExtra`, `SMAppService` and XPC.
- A Swift toolchain for `swift build`, and a Developer ID for the signed helper build.
