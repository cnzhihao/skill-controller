#!/usr/bin/env python3
"""Regenerate AppIcon.appiconset for Skill Controller.

Usage:  python3 docs/app-icon/generate.py <master-source.png> [block] [mask]

Reads the designer's square art and writes all ten macOS slots plus Contents.json
straight into App/Assets.xcassets/AppIcon.appiconset.

Defaults: block=1024, mask=none — a full-bleed opaque square.

WHY FULL-BLEED, NOT THE CLASSIC GRID
------------------------------------
Measured on macOS 26 (Tahoe, build 25.6.0) by asking NSWorkspace for the
resolved icon of the built bundle. Three candidates were probed from fresh
bundle paths (LaunchServices caches by path, so re-probing the same path
returns a stale image):

  824 block + own squircle  -> the system's backing plate shows through the
                               transparent margin: icon-inside-an-icon.
  1024 block + own squircle -> own corner radius disagrees with the system's,
                               leaving a ~3% grey rim at the edges.
  1024 block, opaque square -> clean, edge-to-edge, same shape as Xcode's icon.

The transparency profile sampled along the top row was identical for all three
(128/128 transparent at y=2, 17/128 at mid-row), which is what proves the final
squircle mask is applied by the system, not by us. So: hand the system a full
opaque square and let it do the shaping.

TRADE-OFF, NOT YET MEASURED
---------------------------
MACOSX_DEPLOYMENT_TARGET is 14.0. macOS 14/15 are not expected to apply that
mask, where this asset will read as a sharp-cornered white square. That is
accepted deliberately (智昊 2026-09-23, 三档实测后选满幅不透明); revisit if the
app ever ships to users on Sonoma/Sequoia.

Pass `824 squircle` to go back to the classic grid, or `1024 squircle` for the
old-system-safe full-bleed compromise.
"""
from PIL import Image
import json
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT_DIR = os.path.join(REPO, "App", "Assets.xcassets", "AppIcon.appiconset")
DOC_DIR = os.path.join(REPO, "docs", "app-icon")

CANVAS = 1024
BLOCK = 1024         # artwork footprint inside the canvas
EXPONENT = 4.5       # corner shape, only used when mask == "squircle"
SS = 6               # supersample factor before down-scaling

SLOTS = [
    ("16x16", "1x", 16), ("16x16", "2x", 32),
    ("32x32", "1x", 32), ("32x32", "2x", 64),
    ("128x128", "1x", 128), ("128x128", "2x", 256),
    ("256x256", "1x", 256), ("256x256", "2x", 512),
    ("512x512", "1x", 512), ("512x512", "2x", 1024),
]


def squircle_mask(size, exponent):
    big = size * SS
    a = (big - 1) / 2.0
    img = Image.new("L", (big, big), 0)
    px = img.load()
    inv = 2.0 / exponent
    for y in range(big):
        rem = 1.0 - abs((y - a) / a) ** exponent
        if rem <= 0:
            continue
        limit = a * (rem ** inv)
        for x in range(big):
            if abs(x - a) <= limit:
                px[x, y] = 255
    return img.resize((size, size), Image.LANCZOS)


def master(art_path, block, mask):
    art = Image.open(art_path).convert("RGBA").resize((block, block), Image.LANCZOS)
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    off = (CANVAS - block) // 2
    if mask == "none":
        canvas.paste(art, (off, off))
    else:
        canvas.paste(art, (off, off), squircle_mask(block, EXPONENT))
    return canvas


def main():
    if not 2 <= len(sys.argv) <= 4:
        sys.exit(__doc__)
    src = os.path.abspath(sys.argv[1])
    if not os.path.isfile(src):
        sys.exit(f"no such file: {src}")
    block = int(sys.argv[2]) if len(sys.argv) >= 3 else BLOCK
    mask = sys.argv[3] if len(sys.argv) == 4 else "none"
    if mask not in ("none", "squircle"):
        sys.exit(f"unknown mask: {mask}")

    os.makedirs(OUT_DIR, exist_ok=True)
    art = master(src, block, mask)
    art.save(os.path.join(DOC_DIR, "master.png"))

    images = []
    for size_str, scale_str, px_size in SLOTS:
        base = "icon_%s%s.png" % (size_str, "" if scale_str == "1x" else "@2x")
        art.resize((px_size, px_size), Image.LANCZOS).save(os.path.join(OUT_DIR, base))
        images.append({"size": size_str, "scale": scale_str, "idiom": "mac", "filename": base})

    with open(os.path.join(OUT_DIR, "Contents.json"), "w") as fh:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, fh, indent=2)
        fh.write("\n")

    # Inspection sheet: small slots magnified, on light and dark backdrops.
    sheet = Image.new("RGB", (4 * (128 + 16) + 16, 2 * (128 + 16) + 16), (60, 60, 65))
    for col, px_size in enumerate((16, 32, 64, 128)):
        icon = art.resize((px_size, px_size), Image.LANCZOS)
        for row, bg in enumerate(((245, 245, 247), (28, 28, 30))):
            tile = Image.new("RGB", (128, 128), bg)
            zoom = icon.resize((px_size * 2, px_size * 2), Image.NEAREST)
            tile.paste(zoom, ((128 - zoom.width) // 2, (128 - zoom.height) // 2), zoom)
            sheet.paste(tile, (16 + col * 144, 16 + row * 144))
    sheet.save(os.path.join(DOC_DIR, "small-sizes.png"))

    print("wrote %d slots (block=%d, mask=%s) to %s" % (len(images), block, mask, OUT_DIR))


if __name__ == "__main__":
    main()
