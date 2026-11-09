#!/usr/bin/env python3
"""The type's rasterizer (emo-desktop A14.2).

Pillow's FreeType renders the three strikes the desktop paints in —
Inter at 16 and 24 pixels for the interface, JetBrains Mono at 16 for
the cell grids — into `coverage.txt`: one line of metrics per strike,
one line per glyph, and each glyph's rows as a grid of sixteen-level
coverage, '.' for none and '1'..'9', 'a'..'f' for one fifteenth to
whole. The grid is the reviewable source `gen.py` writes `font.emo`'s
tables from, the way `glyphs.txt` was the drawing before the type was
a typeface; this script is the only thing in the pipeline that needs
Pillow, so the gate's drift check (`gen.py --check`) never does.

    uv run --with pillow python3 rasterize.py

The faces are vendored in `../fonts/` beside their licenses (the SIL
Open Font License 1.1): Inter 4.1's static Regular and JetBrains Mono
2.304's Regular, each pinned below by its SHA-256 — a face that changed
under the pin is refused rather than rasterized.
"""

import hashlib
import sys
from pathlib import Path

from PIL import Image, ImageFont, features
import PIL

HERE = Path(__file__).resolve().parent
FONTS = HERE.parent / "fonts"
OUT = HERE / "coverage.txt"

FACES = {
    "Inter-Regular.ttf": (
        "Inter 4.1",
        "40d692fce188e4471e2b3cba937be967878f631ad3ebbbdcd587687c7ebe0c82",
    ),
    "JetBrainsMono-Regular.ttf": (
        "JetBrains Mono 2.304",
        "a0bf60ef0f83c5ed4d7a75d45838548b1f6873372dfac88f71804491898d138f",
    ),
}

# The strikes in their index order — the number a surface's `ink` names.
STRIKES = [
    ("ui16", "Inter-Regular.ttf", 16),
    ("ui24", "Inter-Regular.ttf", 24),
    ("mono16", "JetBrainsMono-Regular.ttf", 16),
]

LEVELS = ".123456789abcdef"
FIRST, LAST = 0x20, 0x7E


def level(c):
    """One pixel's 8-bit coverage as one of sixteen levels, rounded."""
    return (c * 15 + 127) // 255


def raster(font, text):
    """The glyph's levels, trimmed to its ink, and where they sit: the
    left and top offsets from the pen at the line box's top-left."""
    mask, (ox, oy) = font.getmask2(text, mode="L")
    w, h = mask.size
    rows = [[level(mask.getpixel((x, y))) for x in range(w)] for y in range(h)]
    while rows and not any(rows[0]):
        rows.pop(0)
        oy += 1
    while rows and not any(rows[-1]):
        rows.pop()
    if not rows:
        return 0, 0, []
    while not any(r[0] for r in rows):
        rows = [r[1:] for r in rows]
        ox += 1
    while not any(r[-1] for r in rows):
        rows = [r[:-1] for r in rows]
    return ox, oy, rows


def glyph_line(name, advance, left, top, rows):
    w = len(rows[0]) if rows else 0
    out = [f"glyph {name} advance {advance} left {left} top {top} size {w}x{len(rows)}"]
    out += ["  " + "".join(LEVELS[v] for v in r) for r in rows]
    return out


def main():
    for face, (label, digest) in FACES.items():
        got = hashlib.sha256((FONTS / face).read_bytes()).hexdigest()
        if got != digest:
            sys.exit(f"rasterize.py: {face} is not the pinned {label} ({got})")
    lines = [
        "# The type's coverage grid (emo-desktop A14.2): written by rasterize.py",
        "# from ../fonts/ — gen.py writes font.emo's tables from this file, and",
        "# the gate refuses a font.emo that no longer matches it. A glyph is its",
        "# advance, its ink's offsets from the pen at the line box's top-left,",
        "# and its rows: '.' no coverage, '1'..'9' and 'a'..'f' fifteenths.",
    ]
    for face, (label, digest) in FACES.items():
        lines.append(f"# {label}: {face} sha256 {digest}")
    lines.append(f"# Pillow {PIL.__version__}, FreeType {features.version('freetype2')}")
    for name, face, size in STRIKES:
        font = ImageFont.truetype(str(FONTS / face), size)
        ascent, descent = font.getmetrics()
        lines.append(f"strike {name} {face} {size} ascent {ascent} descent {descent}")
        advances = set()
        for code in range(FIRST, LAST + 1):
            ch = chr(code)
            advance = int(font.getlength(ch) + 0.5)
            advances.add(advance)
            left, top, rows = raster(font, ch)
            lines += glyph_line(f"0x{code:02X}", advance, left, top, rows)
        if face.startswith("JetBrainsMono") and len(advances) != 1:
            sys.exit(f"rasterize.py: {name} is monospace but advances {sorted(advances)}")
        # the glyph every byte outside the table shows: the face's own
        # .notdef, reached through a code point no face here maps
        left, top, rows = raster(font, "\uffff")
        missing_adv = int(font.getlength("\uffff") + 0.5) or 10
        lines += glyph_line("missing", missing_adv, left, top, rows)
    OUT.write_text("\n".join(lines) + "\n")
    print(f"wrote {OUT.name}: {len(STRIKES)} strikes")


if __name__ == "__main__":
    main()
