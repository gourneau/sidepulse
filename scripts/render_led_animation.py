#!/usr/bin/env python3
"""Render the SidePulse strip running real LEDS.LED programs, as PNG frames.

This is a *simulation*, not footage of the hardware: it runs the same DSL
programs the app emits (see LEDS_FORMAT.md) through the same semantics the
controller uses, and draws the result. Every frame is therefore something the
device would actually display, but nothing here is a photograph.

    python3 scripts/render_led_animation.py --out build/frames
    # then: scripts/make_led_gif.sh

Requires: Pillow, numpy (both preinstalled with the system python3 on macOS
setups that have them; see the README asset notes).
"""

from __future__ import annotations

import argparse
import math
import os
import shutil

import numpy as np
from PIL import Image, ImageDraw, ImageFont

# ---------------------------------------------------------------- geometry

WIDTH, HEIGHT = 760, 236
FPS = 12

LED_COUNT = 8
CARD_W, CARD_H = 540, 60
CARD_X = (WIDTH - CARD_W) // 2
CARD_Y = 46
LED_Y = CARD_Y + CARD_H // 2
LED_SPACING = CARD_W / (LED_COUNT + 1)

BG = (9, 9, 11)
CARD = (26, 26, 30)
CARD_EDGE = (46, 46, 52)

FONT_MONO = "/System/Library/Fonts/SFNSMono.ttf"
FONT_UI = "/System/Library/Fonts/SFNS.ttf"


def hex_rgb(value: str) -> np.ndarray:
    """'#ff00cc' -> float RGB in 0..1."""
    value = value.lstrip("#")
    return np.array([int(value[i:i + 2], 16) / 255.0 for i in (0, 2, 4)], dtype=np.float32)


OFF = np.zeros(3, dtype=np.float32)

# ------------------------------------------------------------ DSL semantics
#
# Only the handful of constructs the app actually emits, with the meanings the
# controller gives them (LEDS_FORMAT.md):
#   positional list  -> LEDs take the listed colours, the rest turn off
#   i:#rrggbb        -> that LED only; unmentioned LEDs hold their state
#   roll <dur>       -> rotate the CURRENT VISIBLE state one full wraparound
#   <c> <dur> pulse  -> full-cycle envelope: start -> target -> start
#   off <dur> none   -> jump to off and hold


def positional(colors: list[str]) -> np.ndarray:
    state = np.zeros((LED_COUNT, 3), dtype=np.float32)
    for i, c in enumerate(colors[:LED_COUNT]):
        state[i] = hex_rgb(c)
    return state


def indexed(base: np.ndarray, pairs: dict[int, str]) -> np.ndarray:
    state = base.copy()
    for i, c in pairs.items():
        if i < LED_COUNT:
            state[i] = hex_rgb(c)
    return state


def rolled(seed: np.ndarray, turns: float) -> np.ndarray:
    """Seed rotated by `turns` full wraparounds.

    Fractional offsets interpolate between neighbouring LEDs, which is what
    makes a rolled program look continuous rather than stepped — the whole
    reason the Rainbow preset was rebuilt on `roll`.
    """
    offset = (turns % 1.0) * LED_COUNT
    low = np.floor(offset).astype(int)
    frac = offset - low
    out = np.empty_like(seed)
    for i in range(LED_COUNT):
        a = seed[(i - low) % LED_COUNT]
        b = seed[(i - low - 1) % LED_COUNT]
        out[i] = a * (1.0 - frac) + b * frac
    return out


def pulse_envelope(phase: float) -> float:
    """Full cycle: 0 at both ends, 1 in the middle, smooth throughout."""
    return 0.5 - 0.5 * math.cos(2.0 * math.pi * phase)


# ------------------------------------------------------------- the timeline

RAINBOW = ["#ff0000", "#ffbf00", "#80ff00", "#00ff40",
           "#00ffff", "#0040ff", "#8000ff", "#ff00bf"]
CHASE = {0: "#26e5ff", 1: "#137280", 2: "#0a3940"}
BATTERY = ["#ffffff"] * 4 + ["#000000"] * 4


class Segment:
    """One program on the device, held for `duration` seconds."""

    def __init__(self, title: str, source: list[str], duration: float, fn):
        self.title = title
        self.source = source
        self.duration = duration
        self.fn = fn


def solid_seg() -> Segment:
    color = hex_rgb("#ff3a00")
    return Segment(
        "Colour", ["#ff3a00"], 1.6,
        lambda t: np.tile(color, (LED_COUNT, 1)),
    )


def rainbow_seg() -> Segment:
    seed = positional(RAINBOW)
    return Segment(
        "Rainbow",
        ["#ff0000 #ffbf00 #80ff00 #00ff40 #00ffff #0040ff #8000ff #ff00bf",
         "roll 1980ms linear", "repeat"],
        3.4,
        lambda t: rolled(seed, t / 1.98),
    )


def chase_seg() -> Segment:
    seed = indexed(np.zeros((LED_COUNT, 3), dtype=np.float32), CHASE)
    return Segment(
        "Chase",
        ["off", "0:#26e5ff 1:#137280 2:#0a3940", "roll 1750ms linear", "repeat"],
        3.5,
        lambda t: rolled(seed, t / 1.75),
    )


def battery_seg() -> Segment:
    state = positional(BATTERY)
    return Segment(
        "Battery  ·  Info mode",
        ["#ffffff #ffffff #ffffff #ffffff #000000 #000000 #000000 #000000"],
        1.8,
        lambda t: state,
    )


def breathe_seg() -> Segment:
    # The literal colour the preset emits. It is deliberately dim — Breathe is a
    # calm preset — so it renders dim here too rather than being flattered.
    target = hex_rgb("#404040")
    cycle = 1.55 + 0.475

    def frame(t: float) -> np.ndarray:
        phase = t % cycle
        if phase < 1.55:
            # `pulse` runs the whole envelope inside the line's duration.
            return np.tile(target * pulse_envelope(phase / 1.55), (LED_COUNT, 1))
        return np.zeros((LED_COUNT, 3), dtype=np.float32)

    return Segment("Breathe", ["#404040 1550ms pulse", "off 475ms none", "repeat"],
                   3.0, frame)


TIMELINE = [solid_seg(), rainbow_seg(), chase_seg(), battery_seg(), breathe_seg()]

# ------------------------------------------------------------------ drawing

_yy, _xx = np.mgrid[0:HEIGHT, 0:WIDTH].astype(np.float32)


def render(state: np.ndarray, seg: Segment, fonts) -> Image.Image:
    canvas = np.zeros((HEIGHT, WIDTH, 3), dtype=np.float32)
    canvas[:] = np.array(BG, dtype=np.float32) / 255.0

    # The card body, drawn before the light so the LEDs sit *on* it.
    base = Image.fromarray((canvas * 255).astype(np.uint8))
    draw = ImageDraw.Draw(base)
    draw.rounded_rectangle(
        [CARD_X, CARD_Y, CARD_X + CARD_W, CARD_Y + CARD_H],
        radius=12, fill=CARD, outline=CARD_EDGE, width=1)
    canvas = np.asarray(base, dtype=np.float32) / 255.0

    # Additive bloom: a wide soft halo plus a tight core, which is roughly how a
    # diffused SMD LED reads on a dark surface.
    for i in range(LED_COUNT):
        color = state[i]
        if float(color.max()) <= 0.002:
            continue
        cx = CARD_X + LED_SPACING * (i + 1)
        d2 = (_xx - cx) ** 2 + (_yy - LED_Y) ** 2
        halo = np.exp(-d2 / (2.0 * 13.0 ** 2)) * 0.42
        core = np.exp(-d2 / (2.0 * 4.6 ** 2)) * 1.25
        canvas += color.reshape(1, 1, 3) * (halo + core)[:, :, None]

    img = Image.fromarray((np.clip(canvas, 0.0, 1.0) * 255).astype(np.uint8))
    draw = ImageDraw.Draw(img)

    draw.text((CARD_X, 20), "LEDS.LED", font=fonts["label"], fill=(110, 110, 120))
    draw.text((CARD_X + CARD_W, 19), seg.title, font=fonts["title"],
              fill=(228, 228, 235), anchor="ra")

    y = CARD_Y + CARD_H + 26
    for line in seg.source:
        draw.text((CARD_X, y), line, font=fonts["mono"], fill=(132, 132, 142))
        y += 20

    return img


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="build/frames")
    args = ap.parse_args()

    if os.path.isdir(args.out):
        shutil.rmtree(args.out)
    os.makedirs(args.out, exist_ok=True)

    fonts = {
        "mono": ImageFont.truetype(FONT_MONO, 13),
        "label": ImageFont.truetype(FONT_MONO, 11),
        "title": ImageFont.truetype(FONT_UI, 15),
    }

    n = 0
    for seg in TIMELINE:
        frames = int(round(seg.duration * FPS))
        for f in range(frames):
            state = np.clip(seg.fn(f / FPS), 0.0, 1.0)
            render(state, seg, fonts).save(os.path.join(args.out, f"f{n:04d}.png"))
            n += 1

    total = sum(s.duration for s in TIMELINE)
    print(f"{n} frames at {FPS}fps ({total:.1f}s) -> {args.out}")


if __name__ == "__main__":
    main()
