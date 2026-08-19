#!/usr/bin/env python3
"""Generate the screenshot placeholders used by the README and landing page.

The app is a menu-bar popover, which closes as soon as it loses focus, so its
screenshots are taken by hand. These stand in until then — sized to the real
window dimensions so that dropping a real capture in its place does not reflow
anything around it.

    python3 scripts/make_placeholders.py

Replace a placeholder simply by overwriting the file it wrote, at the same
pixel size. See docs/assets/README.md.
"""

from __future__ import annotations

import os

from PIL import Image, ImageDraw, ImageFont

OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                       "docs", "assets")

FONT_UI = "/System/Library/Fonts/SFNS.ttf"
FONT_MONO = "/System/Library/Fonts/SFNSMono.ttf"

BG = (16, 16, 19)
PANEL = (23, 23, 27)
EDGE = (48, 48, 56)
TEXT = (150, 150, 160)
DIM = (96, 96, 106)

# 2x of the app's real window sizes: the popover is ContentView's .frame(width: 460)
# and the Activity window is ActivityView's .frame(width: 440, height: 480).
PLACEHOLDERS = [
    ("app-popover.png", 920, 1040, "The SidePulse menu-bar popover",
     "460 × 520 pt  ·  @2x"),
    ("app-modes.png", 920, 900, "Modes — live battery, CPU, GPU and memory",
     "460 × 450 pt  ·  @2x"),
    ("app-activity.png", 880, 960, "The 24-hour activity window",
     "440 × 480 pt  ·  @2x"),
]


def draw_placeholder(path: str, w: int, h: int, title: str, spec: str) -> None:
    img = Image.new("RGB", (w, h), BG)
    d = ImageDraw.Draw(img)

    m = 24
    d.rounded_rectangle([m, m, w - m, h - m], radius=28, fill=PANEL, outline=EDGE, width=2)

    # A dashed inner frame reads as "deliberately empty" rather than "broken image".
    im = m + 26
    dash, gap = 14, 10
    for x in range(im, w - im, dash + gap):
        d.line([(x, im), (min(x + dash, w - im), im)], fill=EDGE, width=2)
        d.line([(x, h - im), (min(x + dash, w - im), h - im)], fill=EDGE, width=2)
    for y in range(im, h - im, dash + gap):
        d.line([(im, y), (im, min(y + dash, h - im))], fill=EDGE, width=2)
        d.line([(w - im, y), (w - im, min(y + dash, h - im))], fill=EDGE, width=2)

    title_font = ImageFont.truetype(FONT_UI, 30)
    spec_font = ImageFont.truetype(FONT_MONO, 20)
    note_font = ImageFont.truetype(FONT_MONO, 17)

    cy = h // 2
    d.text((w // 2, cy - 34), title, font=title_font, fill=TEXT, anchor="mm")
    d.text((w // 2, cy + 10), spec, font=spec_font, fill=DIM, anchor="mm")
    d.text((w // 2, cy + 44), "screenshot goes here", font=note_font, fill=DIM, anchor="mm")

    img.save(path)
    print(f"{os.path.relpath(path)}  {w}x{h}")


def main() -> None:
    os.makedirs(OUT_DIR, exist_ok=True)
    for name, w, h, title, spec in PLACEHOLDERS:
        draw_placeholder(os.path.join(OUT_DIR, name), w, h, title, spec)


if __name__ == "__main__":
    main()
