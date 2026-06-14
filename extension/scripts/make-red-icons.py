#!/usr/bin/env python3
"""Generate red-hued variants of the extension icons.

Reads icons/icon{16,48,128}.png and writes
       icons/icon-red-{16,48,128}.png

The transform pins each non-transparent pixel's hue to ~0 (red),
preserving its saturation and value.  That keeps the silhouette of
the original logo while replacing its purple cast with red.  Re-run
whenever the source icons change.
"""

import colorsys
import sys
from pathlib import Path

from PIL import Image

EXT_DIR    = Path(__file__).resolve().parent.parent
ICONS_DIR  = EXT_DIR / "icons"
SIZES      = (16, 48, 128)
TARGET_HUE = 0.02   # ~7° — pure red gets dull on light backgrounds; tiny
                    # nudge toward orange keeps it punchy.


def redden(src: Path, dst: Path) -> None:
    img = Image.open(src).convert("RGBA")
    pixels = img.load()
    w, h = img.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = pixels[x, y]
            if a == 0:
                continue
            _, sat, val = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
            nr, ng, nb = colorsys.hsv_to_rgb(TARGET_HUE, sat, val)
            pixels[x, y] = (int(nr * 255), int(ng * 255), int(nb * 255), a)
    img.save(dst)
    print(f"wrote {dst.relative_to(EXT_DIR)}")


def main() -> None:
    for size in SIZES:
        src = ICONS_DIR / f"icon{size}.png"
        dst = ICONS_DIR / f"icon-red-{size}.png"
        if not src.exists():
            sys.stderr.write(f"missing source icon: {src}\n")
            sys.exit(1)
        redden(src, dst)


if __name__ == "__main__":
    main()
