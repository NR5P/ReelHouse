#!/usr/bin/env python3
"""Draws the placeholder ReelHouse app icon (a film reel inside a house, on a dark background)
and writes every size AppIcon.appiconset/Contents.json lists. Needs Pillow.

    python3 scripts/make-icon.py

Replace with real artwork when there is some: drop a 1024x1024 PNG in as the master and keep
the resize loop."""
import json
import math
import os
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
ICONSET = os.path.join(HERE, "..", "ReelHouse", "Resources", "Assets.xcassets", "AppIcon.appiconset")
S = 2048  # drawn large, scaled down for smooth edges
BG_TOP, BG_BOTTOM = (38, 24, 44), (12, 8, 16)   # velvet plum, lit from above
GOLD = (255, 194, 75)      # marquee gold
CURTAIN = (226, 61, 61)    # red velvet
DARK = (20, 13, 24)


def master():
    img = Image.new("RGB", (S, S))
    draw = ImageDraw.Draw(img)
    for y in range(S):
        t = y / (S - 1)
        draw.line([(0, y), (S, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(BG_TOP, BG_BOTTOM)))

    # The house: a roof and a body, as one outline.
    u = S / 100
    house = [(50, 17), (86, 46), (78, 46), (78, 83), (22, 83), (22, 46), (14, 46)]
    draw.polygon([(x * u, y * u) for x, y in house], fill=GOLD)
    inner = [(50, 25.5), (72, 43.5), (72, 77), (28, 77), (28, 43.5)]
    draw.polygon([(x * u, y * u) for x, y in inner], fill=DARK)

    # The film reel inside it.
    cx, cy, r = 50 * u, 56 * u, 17 * u
    draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=CURTAIN)
    hole = 4.6 * u
    for i in range(5):
        a = -math.pi / 2 + i * 2 * math.pi / 5
        hx, hy = cx + math.cos(a) * 10 * u, cy + math.sin(a) * 10 * u
        draw.ellipse([hx - hole, hy - hole, hx + hole, hy + hole], fill=DARK)
    hub = 2.4 * u
    draw.ellipse([cx - hub, cy - hub, cx + hub, cy + hub], fill=DARK)
    return img


def mac_variant(square):
    """macOS icons carry their own rounded shape and margin; iOS masks a full square itself."""
    size = square.size[0]
    inset = round(size * 0.1)
    body = square.resize((size - 2 * inset, size - 2 * inset), Image.LANCZOS)
    mask = Image.new("L", body.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, body.size[0] - 1, body.size[1] - 1],
                                           radius=round(body.size[0] * 0.225), fill=255)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(body, (inset, inset), mask)
    return out


def main():
    square = master()
    mac = mac_variant(square)
    with open(os.path.join(ICONSET, "Contents.json")) as f:
        images = json.load(f)["images"]
    for entry in images:
        points = float(entry["size"].split("x")[0])
        pixels = round(points * int(entry["scale"].rstrip("x")))
        source = mac if entry["idiom"] == "mac" else square
        source.resize((pixels, pixels), Image.LANCZOS).save(os.path.join(ICONSET, entry["filename"]))
    print(f"Wrote {len(images)} icons to {os.path.normpath(ICONSET)}")


if __name__ == "__main__":
    main()
