#!/usr/bin/env python3
"""Draws the ReelHouse Roku channel art into roku/images/.

The mark is the same one the other apps use (server/scripts/make_icons.py and
ios/scripts/make-icon.py): a gold house outline with a red film reel inside, on the dark plum
"movie palace" background. The drawing code below is ios/scripts/make-icon.py's, so the Roku
tile and the iPhone icon are the same picture.

    python3 roku/scripts/make_images.py           # writes roku/images/
    python3 roku/scripts/make_images.py OUT_DIR   # or somewhere else

Writes what the manifest names, at the sizes Roku asks for:
    mm_icon_focus_fhd.png   540x405   home-screen tile (FHD)
    mm_icon_focus_hd.png    290x218   home-screen tile (HD)
    splash_fhd.png          1920x1080 launch splash (FHD)
    splash_hd.png           1280x720  launch splash (HD)
and the channel's own UI pieces:
    button_focus.9.png      gold 9-patch behind a focused ButtonGroup button
    button_footprint.9.png  card 9-patch behind the last-focused button of an unfocused group
    spinner.png             BusySpinner ring
    logo_mark.png           the mark alone, transparent, for in-channel headers

Needs Pillow (pip install pillow).
"""

import math
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

BG = (14, 10, 18)            # #0E0A12 background
BG_TOP = (38, 24, 44)        # velvet plum, lit from above (ios/scripts/make-icon.py)
PANEL = (23, 16, 32)         # #171020
CARD = (31, 22, 41)          # #1F1629
GOLD = (255, 194, 75)        # #FFC24B
AMBER = (255, 154, 60)       # #FF9A3C
CURTAIN = (226, 61, 61)      # #E23D3D
TEXT = (244, 233, 218)       # #F4E9DA
DIM = (169, 154, 142)        # #A99A8E
DARK = (20, 13, 24)          # the hollow inside the house and the reel's holes


def gradient(size, top=BG_TOP, bottom=BG):
    w, h = size
    img = Image.new("RGB", size)
    d = ImageDraw.Draw(img)
    for y in range(h):
        t = y / max(1, h - 1)
        d.line([(0, y), (w, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))
    return img


def draw_mark(size, transparent=False):
    """The house-and-reel mark on a square canvas `size` px wide (ios/scripts/make-icon.py)."""
    s = size * 4  # drawn large, scaled down for smooth edges
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0)) if transparent else gradient((s, s)).convert("RGBA")
    d = ImageDraw.Draw(img)
    u = s / 100
    house = [(50, 17), (86, 46), (78, 46), (78, 83), (22, 83), (22, 46), (14, 46)]
    d.polygon([(x * u, y * u) for x, y in house], fill=GOLD)
    inner = [(50, 25.5), (72, 43.5), (72, 77), (28, 77), (28, 43.5)]
    d.polygon([(x * u, y * u) for x, y in inner], fill=DARK)
    cx, cy, r = 50 * u, 56 * u, 17 * u
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=CURTAIN)
    hole = 4.6 * u
    for i in range(5):
        a = -math.pi / 2 + i * 2 * math.pi / 5
        hx, hy = cx + math.cos(a) * 10 * u, cy + math.sin(a) * 10 * u
        d.ellipse([hx - hole, hy - hole, hx + hole, hy + hole], fill=DARK)
    hub = 2.4 * u
    d.ellipse([cx - hub, cy - hub, cx + hub, cy + hub], fill=DARK)
    return img.resize((size, size), Image.LANCZOS)


def font(size, bold=True):
    candidates = [
        "/System/Library/Fonts/Supplemental/Arial Black.ttf",
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
        "/Library/Fonts/Arial Bold.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    ] if bold else [
        "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    ]
    for path in candidates:
        if Path(path).exists():
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                continue
    return ImageFont.load_default()


def wordmark(draw, xy, text, size, spacing):
    """REELHOUSE in marquee gold running into curtain red, letter by letter."""
    f = font(size)
    x, y = xy
    widths = [draw.textlength(ch, font=f) for ch in text]
    n = len(text)
    for i, ch in enumerate(text):
        t = i / max(1, n - 1)
        if t < 0.5:
            a, b, k = GOLD, AMBER, t / 0.5
        else:
            a, b, k = AMBER, CURTAIN, (t - 0.5) / 0.5
        colour = tuple(round(p + (q - p) * k) for p, q in zip(a, b))
        draw.text((x, y), ch, font=f, fill=colour)
        x += widths[i] + spacing
    return x


def text_width(draw, text, size, spacing):
    f = font(size)
    return sum(draw.textlength(ch, font=f) for ch in text) + spacing * (len(text) - 1)


def tile(w, h):
    """Home-screen tile: the mark on the left, the wordmark beside it."""
    img = gradient((w, h))
    mark_size = round(h * 0.62)
    mark = draw_mark(mark_size, transparent=True)
    d = ImageDraw.Draw(img)
    # The biggest wordmark that fits beside the mark with a margin either side.
    size = round(h * 0.13)
    while True:
        spacing = round(size * 0.12)
        label_w = text_width(d, "REELHOUSE", size, spacing)
        total = mark_size * 0.86 + label_w
        if total <= w * 0.9 or size <= 8:
            break
        size -= 1
    x0 = round((w - total) / 2)
    img.paste(mark, (x0 - round(mark_size * 0.07), round((h - mark_size) / 2) - round(h * 0.02)), mark)
    wordmark(d, (x0 + round(mark_size * 0.86), round(h / 2 - size * 0.62)), "REELHOUSE", size, spacing)
    # A thin gold rule under it: the marquee's edge.
    d.rectangle([0, h - max(3, h // 90), w, h], fill=GOLD)
    return img


def splash(w, h):
    img = gradient((w, h))
    d = ImageDraw.Draw(img)
    mark_size = round(h * 0.36)
    mark = draw_mark(mark_size, transparent=True)
    img.paste(mark, (round((w - mark_size) / 2), round(h * 0.2)), mark)
    size = round(h * 0.075)
    spacing = round(size * 0.16)
    label_w = text_width(d, "REELHOUSE", size, spacing)
    wordmark(d, (round((w - label_w) / 2), round(h * 0.6)), "REELHOUSE", size, spacing)
    sub = "Your movies, TV, music and podcasts"
    f = font(round(h * 0.028), bold=False)
    sw = d.textlength(sub, font=f)
    d.text(((w - sw) / 2, h * 0.72), sub, font=f, fill=DIM)
    return img


def nine_patch(w, h, radius, fill, border=None, border_w=0):
    """A Roku 9-patch: the picture plus a 1px frame whose black pixels mark the stretchable
    middle (top and left edges) and the content area (bottom and right edges)."""
    body = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(body)
    if border is not None and border_w > 0:
        d.rounded_rectangle([0, 0, w - 1, h - 1], radius=radius, fill=border + (255,))
        d.rounded_rectangle([border_w, border_w, w - 1 - border_w, h - 1 - border_w],
                            radius=max(1, radius - border_w), fill=fill + (255,))
    else:
        d.rounded_rectangle([0, 0, w - 1, h - 1], radius=radius, fill=fill + (255,))
    out = Image.new("RGBA", (w + 2, h + 2), (0, 0, 0, 0))
    out.paste(body, (1, 1))
    o = ImageDraw.Draw(out)
    black = (0, 0, 0, 255)
    o.line([(1 + radius, 0), (w - radius, 0)], fill=black)            # stretch, horizontal
    o.line([(0, 1 + radius), (0, h - radius)], fill=black)            # stretch, vertical
    o.line([(1 + radius // 2, h + 1), (w - radius // 2, h + 1)], fill=black)  # content, horizontal
    o.line([(w + 1, 1 + radius // 2), (w + 1, h - radius // 2)], fill=black)  # content, vertical
    return out


def spinner(size):
    s = size * 4
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    width = round(s * 0.11)
    d.arc([width, width, s - width, s - width], start=0, end=280, fill=GOLD + (255,), width=width)
    d.arc([width, width, s - width, s - width], start=280, end=360, fill=CURTAIN + (255,), width=width)
    return img.resize((size, size), Image.LANCZOS)


def main():
    here = Path(__file__).resolve().parent
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else here.parent / "images"
    out.mkdir(parents=True, exist_ok=True)
    written = []

    def save(img, name):
        img.save(out / name, optimize=True)
        written.append(f"{name} {img.size[0]}x{img.size[1]}")

    save(tile(540, 405), "mm_icon_focus_fhd.png")
    save(tile(290, 218), "mm_icon_focus_hd.png")
    save(splash(1920, 1080), "splash_fhd.png")
    save(splash(1280, 720), "splash_hd.png")
    save(nine_patch(48, 48, 12, GOLD), "button_focus.9.png")
    save(nine_patch(48, 48, 12, CARD, border=(70, 52, 60), border_w=2), "button_footprint.9.png")
    save(spinner(96), "spinner.png")
    save(draw_mark(128, transparent=True), "logo_mark.png")
    print(f"wrote to {out}:\n  " + "\n  ".join(written))


if __name__ == "__main__":
    main()
