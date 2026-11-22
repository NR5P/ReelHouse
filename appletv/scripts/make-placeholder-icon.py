#!/usr/bin/env python3
"""Generate PLACEHOLDER ReelHouse art for tvOS: the layered app icon and both Top Shelf images.

A tvOS app icon is a parallax stack (Back / Middle / Front), so each layer holds a different part
of the picture: Back is the dark background with a soft glow, Front is the glyph (a house with a
film reel inside it), Middle stays empty. Replace this with real art when there is some.

Usage: python3 scripts/make-placeholder-icon.py   (requires Pillow)
"""

import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageOps

ROOT = Path(__file__).resolve().parent.parent
BRAND = ROOT / "ReelHouseTV/Resources/Assets.xcassets/App Icon & Top Shelf Image.brandassets"

BACKGROUND = (14, 10, 18)   # velvet plum-black
GLOW = (110, 28, 36)        # a red-velvet glow behind the mark
ACCENT = (255, 194, 75)     # marquee gold (ReelHouseTheme.gold)
CURTAIN = (226, 61, 61)     # red velvet (ReelHouseTheme.curtain)
SS = 4                    # supersampling factor, for smooth edges


def background(size):
    layer = Image.new("RGB", size, BACKGROUND)
    mask = ImageOps.invert(Image.radial_gradient("L")).resize(size, Image.LANCZOS)
    mask = mask.point(lambda v: int((v / 255) ** 2 * 90))
    mask = mask.filter(ImageFilter.GaussianBlur(max(size) / 40))
    layer.paste(Image.new("RGB", size, GLOW), (0, 0), mask)
    return layer


def glyph(height):
    """A house outline with a film reel inside, RGBA, `height` pixels tall and square."""
    s = height * SS
    image = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    stroke = round(s * 0.055)
    # House: a roof peak over a body.
    left, right, top, eaves, bottom = s * 0.10, s * 0.90, s * 0.06, s * 0.42, s * 0.94
    outline = [(s / 2, top), (right, eaves), (right, bottom), (left, bottom), (left, eaves)]
    draw.line(outline + [outline[0], outline[1]], fill=ACCENT, width=stroke, joint="curve")
    # Film reel: a disc with a hub and five holes.
    cx, cy, radius = s / 2, s * 0.62, s * 0.235
    draw.ellipse((cx - radius, cy - radius, cx + radius, cy + radius), fill=CURTAIN)
    hole = radius * 0.24
    for index in range(5):
        angle = math.radians(-90 + index * 72)
        hx, hy = cx + math.cos(angle) * radius * 0.58, cy + math.sin(angle) * radius * 0.58
        draw.ellipse((hx - hole, hy - hole, hx + hole, hy + hole), fill=(0, 0, 0, 0))
    hub = radius * 0.13
    draw.ellipse((cx - hub, cy - hub, cx + hub, cy + hub), fill=(0, 0, 0, 0))
    return image.resize((height, height), Image.LANCZOS)


def front(size):
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    mark = glyph(round(size[1] * 0.72))
    layer.paste(mark, ((size[0] - mark.width) // 2, (size[1] - mark.height) // 2), mark)
    return layer


def top_shelf(size):
    image = background(size).convert("RGBA")
    mark = glyph(round(size[1] * 0.5))
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", round(size[1] * 0.22), index=1)
    except OSError:
        font = ImageFont.load_default()
    draw = ImageDraw.Draw(image)
    text = "ReelHouse"
    box = draw.textbbox((0, 0), text, font=font)
    gap = round(size[1] * 0.08)
    total = mark.width + gap + (box[2] - box[0])
    x = (size[0] - total) // 2
    image.paste(mark, (x, (size[1] - mark.height) // 2), mark)
    draw.text((x + mark.width + gap, (size[1] - (box[3] - box[1])) // 2 - box[1]), text, font=font, fill=(255, 194, 75))
    return image.convert("RGB")   # Top Shelf images must be opaque


def write(image, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path)
    print(f"  {image.width}x{image.height}  {path.relative_to(ROOT)}")


def main():
    # The App Store icon ships 1x only, the app icon 1x and 2x.
    for stack, base, scales in [("App Icon.imagestack", (400, 240), [("", 1), ("@2x", 2)]),
                                ("App Icon - App Store.imagestack", (1280, 768), [("", 1)])]:
        for suffix, factor in scales:
            size = (base[0] * factor, base[1] * factor)
            layers = {"Front": front(size), "Middle": Image.new("RGBA", size, (0, 0, 0, 0)),
                      "Back": background(size).convert("RGBA")}
            for name, image in layers.items():
                write(image, BRAND / stack / f"{name}.imagestacklayer" / "Content.imageset" / f"{name.lower()}{suffix}.png")
    for folder, name, base in [("Top Shelf Image.imageset", "topshelf", (1920, 720)),
                               ("Top Shelf Image Wide.imageset", "topshelf_wide", (2320, 720))]:
        for suffix, factor in [("", 1), ("@2x", 2)]:
            write(top_shelf((base[0] * factor, base[1] * factor)), BRAND / folder / f"{name}{suffix}.png")


if __name__ == "__main__":
    main()
