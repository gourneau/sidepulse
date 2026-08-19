#!/bin/bash
# Render the LED strip animation and encode it as a GIF for the README and the
# landing page.
#
#   scripts/make_led_gif.sh
#
# GitHub markdown will not run CSS or JS, so the README needs a real animated
# raster file — hence a GIF rather than the SVG the landing page uses.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FRAMES="$ROOT/build/frames"
OUT="$ROOT/docs/assets/led-strip.gif"

echo "==> rendering frames"
python3 "$ROOT/scripts/render_led_animation.py" --out "$FRAMES"

mkdir -p "$(dirname "$OUT")"

# Two passes: build one palette from the whole clip, then apply it. A single-pass
# GIF quantises per frame and the bloom would crawl between frames.
#
# dither=none is deliberate. Dithering a smooth radial glow into 256 colours adds
# a visible hex or grain texture AND wrecks compression — adding noise took this
# file from under 1 MB to 20 MB. The bloom is instead kept tight enough that its
# gradient spans few enough steps not to band, over a flat background that costs
# almost nothing to encode.
echo "==> encoding $OUT"
ffmpeg -hide_banner -loglevel error -y \
    -framerate 12 -i "$FRAMES/f%04d.png" \
    -filter_complex "[0:v]split[a][b];\
[a]palettegen=max_colors=256:stats_mode=full[p];\
[b][p]paletteuse=dither=none:diff_mode=rectangle" \
    -loop 0 "$OUT"

echo "==> $(du -h "$OUT" | cut -f1)  $OUT"
