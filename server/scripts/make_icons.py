#!/usr/bin/env python3
"""Draws ReelHouse's placeholder icon set into ReelHouse.Server/wwwroot/icons.

A film reel inside a house outline, in the web UI's green on its near-black background. Drawn
once at 1024px and scaled down, so every size is the same picture.

    python3 server/scripts/make_icons.py            # writes next to this repo's wwwroot
    python3 server/scripts/make_icons.py OUT_DIR    # or somewhere else

Needs Pillow (pip install pillow).
"""

import math
import sys
from pathlib import Path

from PIL import Image, ImageDraw

BG = (14, 10, 18, 255)        # --bg, velvet plum-black
GOLD = (255, 194, 75, 255)    # --gold, the marquee
GOLD_DIM = (201, 138, 30, 255)  # --gold-dim
CURTAIN = (226, 61, 61, 255)    # --curtain, red velvet

SIZE = 1024
PNG_SIZES = [16, 32, 180, 192, 512]
ICO_SIZES = [16, 32, 48, 64]


def draw_master() -> Image.Image:
    img = Image.new("RGBA", (SIZE, SIZE), BG)
    d = ImageDraw.Draw(img)
    s = SIZE / 1024
    stroke = round(56 * s)

    # The house: a roof and walls as one outline, with a little margin so it survives the
    # rounded-corner masks iOS and Android put over home-screen icons.
    left, right = 196 * s, 828 * s
    eave_y, base_y = 470 * s, 852 * s
    peak = (512 * s, 156 * s)
    overhang = 64 * s
    d.line([(left - overhang, eave_y + overhang * 0.75), peak, (right + overhang, eave_y + overhang * 0.75)],
           fill=GOLD, width=stroke, joint="curve")
    d.line([(left, eave_y), (left, base_y), (right, base_y), (right, eave_y)], fill=GOLD, width=stroke, joint="curve")

    # The reel, sitting in the house: an outer ring, five holes and a hub.
    cx, cy, r = 512 * s, 628 * s, 176 * s
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=CURTAIN)
    hole_r = 46 * s
    for i in range(5):
        a = -math.pi / 2 + i * 2 * math.pi / 5
        hx, hy = cx + math.cos(a) * r * 0.56, cy + math.sin(a) * r * 0.56
        d.ellipse([hx - hole_r, hy - hole_r, hx + hole_r, hy + hole_r], fill=BG)
    hub = 26 * s
    d.ellipse([cx - hub, cy - hub, cx + hub, cy + hub], fill=BG)

    # A strip of film running off the reel to the right-hand wall.
    film_y = cy + r - 18 * s
    d.line([(cx, film_y), (right - stroke / 2, film_y)], fill=GOLD_DIM, width=round(30 * s))
    return img


def main() -> None:
    here = Path(__file__).resolve().parent
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else here.parent / "ReelHouse.Server" / "wwwroot" / "icons"
    out.mkdir(parents=True, exist_ok=True)

    master = draw_master()
    for size in PNG_SIZES:
        master.resize((size, size), Image.LANCZOS).save(out / f"icon-{size}.png", optimize=True)
    master.resize((256, 256), Image.LANCZOS).save(out / "favicon.ico", sizes=[(n, n) for n in ICO_SIZES])
    print(f"wrote {len(PNG_SIZES)} PNGs and favicon.ico to {out}")


if __name__ == "__main__":
    main()
