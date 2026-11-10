#!/usr/bin/env python3
"""The type's reference rasterizer (emo-desktop A17.3).

This is the algorithm's source of truth (typeface.md, D8): the same
integers `raster.emo` computes on every target, spelled in Python so a
person can read them. It reads the resolved outlines the generator
wrote — `outlines.py`'s own Face, the exact data the face modules
carry, whose Emo-side digest the golden already pins — and strikes any
glyph at any pixel size: 26.6 fixed point throughout, integer
arithmetic only, every division truncating toward zero (Emo's own
semantics; the reference mirrors it — a Python floor here and a
truncation there would drift the dust).

    python3 reference.py --check    recompute the golden's raster pins
    python3 reference.py --audit    dev-only: compare against the grid
                                    FreeType baked (coverage.txt), a
                                    tolerance report, never a gate —
                                    the grid's pixels are hinted, the
                                    reference is not

The algorithm, one glyph at a time:

  - Coordinates. A font-unit value lands in 26.6 by half-up scaling:
    (2·fu·px·64 + upem) / (2·upem), truncated — the exact rational
    rounded half up. The strike's y runs downward from the line box's
    top; the face's y-up outline flips by y' = ascent_px·64 − y, the
    ascent scaled by ceiling as the Strike already does.
  - Flattening. The resolved contours alternate on-curve and off-curve
    vertices, starting on one; on→on is a line, on→off→on a quadratic
    (the closing piece back to vertex zero mirrors whatever the last
    vertex is). A quadratic splits at de Casteljau midpoints (floored
    averages) while its second difference |p0 − 2c + p1| exceeds 64 —
    one pixel in 26.6 — in either component; the curve's worst
    deviation from its chord is a quarter of that difference, so every
    segment stays within a quarter pixel of the true curve. The split
    recursion terminates by halving; an explicit stack walks it, and
    the segments land in a growable edge list.
  - Rows. Each segment's y span is split at the row boundaries, x
    interpolated with a truncating division — the one place dust
    enters, at most one subpixel unit a crossing, deterministic on
    every target. A horizontal segment contributes nothing.
  - Accumulation. A row piece from (xa, ya) to (xb, yb), yb > ya, H =
    yb − ya, contributes to column c the signed integral of the
    clamped abscissa, ∫ clamp(x(y) − 64c, 0, 64) dy. With the clamp's
    antiderivative G2 — 0 below zero, v² inside the pixel, 128v − 4096
    above 64 (doubled, so every cell stays an exact integer) — every
    column the piece's x-range touches answers in one closed form,
        H · (G2(xb − 64c) − G2(xa − 64c)) / D,   D = xb − xa,
    truncated: no column splitting, no interpolation, the sign riding
    D (the antiderivative difference always shares D's sign, so the
    quotient never meets a negative numerator over a positive divisor
    or the reverse). Columns left of the piece's x-range take the full
    strip 64·H, carried as a per-row cover record at the piece's first
    column (the sign of the piece's original descent; nonzero winding
    falls out of the signed sum at the sweep). A vertical piece is its
    own column's rectangle, 2·clamp(x − 64c, 0, 64)·H doubled, plus
    the strip.
  - Sweep. Right to left with a running suffix of the cover records,
    the pixel's doubled area is cells[c] + 128·cover_suffix[c], and
    its coverage is min(255, (|A2| + 16) >> 5) — round half up of
    A2/32, the same rounding the A17.2 metrics ride.
  - Ink and packing. left and top are the first pixel column and row
    the outline's endpoints touch; w and h the span; a glyph without
    edges is an empty box with its advance alone. Coverage bytes go
    into the slot eight to a word, byte j in bits 8j, pixels in
    row-major order within the ink box — the word packing the blit
    reads. An ink box wider or taller than the strike's max_dim
    refuses, and so does the strike before it allocates, when an
    advance will not fit its meta byte.

The golden (`fb/type/`) prints one raster line per glyph per strike —
the advance, the ink box, and a rolling digest (h·31 + b mod
1000000007) over the ink's coverage bytes — and this script's
--check recomputes those lines from the generator's own outlines and
compares them against the golden's expected bytes. Two independent
implementations, one set of integers.
"""

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from outlines import Face, FACES, FIRST, LAST, GLYPHS  # noqa: E402

EXPECTED = HERE.parent / "type" / "expected.txt"
GRID = HERE / "coverage.txt"

STRIKES = [
    ("inter", "face_inter.emo", 16),
    ("inter", "face_inter.emo", 24),
    ("mono", "face_mono.emo", 16),
]


def itrunc(a, b):
    """Division truncating toward zero — Emo's `/`, not Python's floor."""
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b > 0) else -q


def ceil_scale(fu, px, upem):
    a = -fu if fu < 0 else fu
    return (a * px + upem - 1) // upem


def scale26(fu, px, upem):
    """A font-unit value in 26.6, the exact rational rounded half up."""
    return itrunc(2 * fu * px * 64 + upem, 2 * upem)


def half_up(fu, px, upem):
    """An advance in whole pixels, the generator's own rounding."""
    return itrunc(2 * fu * px + upem, 2 * upem)


def g2(v):
    """Twice the antiderivative of clamp(v, 0, 64)."""
    if v <= 0:
        return 0
    if v >= 64:
        return 128 * v - 4096
    return v * v


def glyph_edges(contours, px, upem, ascent26):
    """The glyph's flattened segments in 26.6, y flipped downward from
    the line box's top: each resolved contour (a closed loop, rotated
    onto an on-curve vertex) walked on→(off→on | on), the closing
    piece mirroring whatever the last vertex is."""
    edges = []

    def quad(x0, y0, cx, cy, x1, y1):
        stack = [(x0, y0, cx, cy, x1, y1)]
        while stack:
            ax, ay, qx, qy, bx, by = stack.pop()
            d2x = ax - 2 * qx + bx
            d2y = ay - 2 * qy + by
            if d2x < 0:
                d2x = -d2x
            if d2y < 0:
                d2y = -d2y
            if d2x > 64 or d2y > 64:
                mx, my = (ax + qx) // 2, (ay + qy) // 2
                nx, ny = (qx + bx) // 2, (qy + by) // 2
                ccx, ccy = (mx + nx) // 2, (my + ny) // 2
                stack.append((ccx, ccy, nx, ny, bx, by))
                stack.append((ax, ay, mx, my, ccx, ccy))
            else:
                edges.append((ax, ay, bx, by))

    for pts in contours:
        scaled = [
            (scale26(x, px, upem), ascent26 - scale26(y, px, upem), on)
            for x, y, on in pts
        ]
        n = len(scaled)
        i = 0
        while i < n:
            x0, y0, on0 = scaled[i]
            x1, y1, on1 = scaled[(i + 1) % n]
            if on1:
                edges.append((x0, y0, x1, y1))
                i += 1
            else:
                x2, y2, _ = scaled[(i + 2) % n]
                quad(x0, y0, x1, y1, x2, y2)
                i += 2
    return edges


def rasterize(pts, advance_fu, px, upem, ascent_px):
    """One glyph at one size: the advance, the ink box (left, top, w,
    h), and the slot's coverage words — eight bytes to a word, byte j
    in bits 8j, row-major within the ink box."""
    ascent26 = ascent_px * 64
    edges = glyph_edges(pts, px, upem, ascent26)
    advance = half_up(advance_fu, px, upem)
    if not edges:
        return advance, 0, 0, 0, 0, []
    xs = [x for e in edges for x in (e[0], e[2])]
    ys = [y for e in edges for y in (e[1], e[3])]
    left = min(xs) >> 6
    top = min(ys) >> 6
    w = ((max(xs) - 1) >> 6) - left + 1
    h = ((max(ys) - 1) >> 6) - top + 1
    width = w + 1  # one spare column the cover records live beside

    # the row pieces: each segment split at the row boundaries, x
    # interpolated with truncation
    pieces = {}
    for x0, y0, x1, y1 in edges:
        if y0 == y1:
            continue
        sign = 1
        if y1 < y0:
            x0, x1 = x1, x0
            y0, y1 = y1, y0
            sign = -1
        ry = y0
        while ry < y1:
            r = ry >> 6
            stop = min(y1, (r + 1) * 64)
            if ry == y0:
                xa = x0
            else:
                xa = x0 + itrunc((ry - y0) * (x1 - x0), y1 - y0)
            if stop == y1:
                xb = x1
            else:
                xb = x0 + itrunc((stop - y0) * (x1 - x0), y1 - y0)
            pieces.setdefault(r, []).append((xa, xb, stop - ry, sign))
            ry = stop

    words = []
    for r in range(top, top + h):
        cells = [0] * width
        cover = [0] * width
        for xa, xb, hp, sign in pieces.get(r, []):
            if xa == xb:
                c = (xa >> 6) - left
                cells[c] += sign * 2 * (xa - 64 * (xa >> 6)) * hp
                cover[c] += sign * hp
                continue
            lo, hi = (xa, xb) if xa < xb else (xb, xa)
            cmin = (lo >> 6) - left
            cmax = ((hi - 1) >> 6) - left
            d = xb - xa
            for c in range(cmin, cmax + 1):
                cells[c] += sign * itrunc(hp * (g2(xb - 64 * (c + left))
                                                - g2(xa - 64 * (c + left))), d)
            cover[cmin] += sign * hp
        # the sweep, right to left: the pixel's doubled area, then its
        # coverage byte
        run = 0
        row_cov = [0] * w
        for c in range(width - 1, -1, -1):
            if c < w:
                a2 = cells[c] + 128 * run
                v = -a2 if a2 < 0 else a2
                cov = (v + 16) >> 5
                row_cov[c] = 255 if cov > 255 else cov
            run += cover[c]
        # the slot's words: row-major bytes, eight to a word
        for pos in range(w):
            idx = (r - top) * w + pos
            at = idx // 8
            while len(words) <= at:
                words.append(0)
            words[at] |= row_cov[pos] << (8 * (idx % 8))
    return advance, left, top, w, h, words


def name_of(gid):
    if gid == 0:
        return "missing"
    if chr(FIRST + gid - 1) == " ":
        return "space"
    return chr(FIRST + gid - 1)


def faces():
    out = {}
    for _, module, _ in STRIKES:
        if module not in out:
            spec = FACES[module]
            out[module] = Face(HERE.parent / "fonts" / spec[0], spec[1], spec[2])
    return out


def glyph_of(face, gid):
    if gid == 0:
        return face.glyph_points(0)
    return face.glyph_points(face.cmap_lookup(FIRST + gid - 1))


def raster_lines():
    """One line per glyph per strike, the golden's own order and
    spelling: the advance, the ink box, the digest over the slot words
    the ink uses."""
    for name, module, px in STRIKES:
        face = faces()[module]
        ascent_px = ceil_scale(face.ascent_fu, px, face.units_per_em)
        for gid in range(GLYPHS):
            pts, adv = glyph_of(face, gid)
            advance, left, top, w, h, words = rasterize(
                pts, adv, px, face.units_per_em, ascent_px
            )
            digest = 0
            for word in words:
                for j in range(8):
                    digest = (digest * 31 + ((word >> (8 * j)) & 255)) % 1000000007
            yield (f"raster {name} {px} {name_of(gid)} {advance} {left} {top} "
                   f"{w} {h} {digest}")


def check():
    want = [ln for ln in EXPECTED.read_text().splitlines() if ln.startswith("raster ")]
    got = list(raster_lines())
    if want == got:
        print(f"reference matches the golden's {len(got)} raster pins")
        return 0
    for i, (a, b) in enumerate(zip(want, got)):
        if a != b:
            print(f"first difference at raster line {i}:\n"
                  f"  golden:    {a}\n  reference: {b}")
            return 1
    print(f"golden has {len(want)} raster lines, reference computes {len(got)}")
    return 1


def parse_grid():
    """The grid's strikes: per glyph the advance, the ink box and the
    sixteen-level pixels — the audit's other side."""
    strikes = []
    glyph = None
    for line in GRID.read_text().splitlines():
        if line.startswith("strike "):
            parts = line.split()
            glyph = None
            strikes.append({"name": parts[1], "px": int(parts[3]), "glyphs": {}})
        elif line.startswith("glyph "):
            parts = line.split()
            if not parts[1].startswith("0x"):
                glyph = None
                continue
            w, h = (int(v) for v in parts[-1].split("x"))
            glyph = {
                "left": int(parts[5]),
                "top": int(parts[7]),
                "w": w,
                "h": h,
                "pixels": [],
            }
            strikes[-1]["glyphs"][int(parts[1], 16)] = glyph
        elif line.startswith("  ") and glyph is not None:
            glyph["pixels"].append([0 if ch == "." else int(ch, 16)
                                    for ch in line[2:]])
    return strikes


def audit():
    """Dev-only: the reference's 8-bit coverage against the 16-level
    grid FreeType baked, per strike — a tolerance report, never a gate.
    The grid's pixels are hinted (edges snapped to whole pixels), the
    reference is not, so ink boxes move by a pixel and the per-pixel
    comparison runs box-aligned: the grid's (r, c) against the
    reference's (r + top offset, c + left offset). The ink mass — the
    coverage sum — is hinting-independent to first order and reported
    beside."""
    grid_strikes = parse_grid()
    grid_name = {"inter": {16: "ui16", 24: "ui24"}, "mono": {16: "mono16"}}
    for name, module, px in STRIKES:
        grid = next(s for s in grid_strikes
                    if s["name"] == grid_name[name][px] and s["px"] == px)
        face = faces()[module]
        ascent_px = ceil_scale(face.ascent_fu, px, face.units_per_em)
        worst = 0
        boxes = 0
        over = 0
        total = 0
        mass_mine = 0
        mass_theirs = 0
        for cp in range(FIRST, LAST + 1):
            grid_glyph = grid["glyphs"].get(cp)
            if grid_glyph is None:
                continue
            pts, _ = face.glyph_points(face.cmap_lookup(cp))
            _, left, top, w, h, words = rasterize(
                pts, 0, px, face.units_per_em, ascent_px
            )
            if (left, top, w, h) != (grid_glyph["left"], grid_glyph["top"],
                                     grid_glyph["w"], grid_glyph["h"]):
                boxes += 1
            dr = top - grid_glyph["top"]
            dc = left - grid_glyph["left"]
            for r in range(grid_glyph["h"]):
                for c in range(grid_glyph["w"]):
                    theirs = grid_glyph["pixels"][r][c] * 17
                    mr, mc = r + dr, c + dc
                    if 0 <= mr < h and 0 <= mc < w:
                        idx = mr * w + mc
                        word = words[idx // 8] if idx // 8 < len(words) else 0
                        mine = (word >> (8 * (idx % 8))) & 255
                    else:
                        mine = 0
                    mass_mine += mine
                    mass_theirs += theirs
                    d = abs(mine - theirs)
                    total += 1
                    if d > 2:
                        over += 1
                    if d > worst:
                        worst = d
        rel = (mass_mine - mass_theirs) * 100.0 / max(1, mass_theirs)
        print(f"audit {name} {px}: {total} pixels aligned, worst delta {worst}, "
              f"{over} beyond 2, {boxes} ink boxes moved, ink mass "
              f"{mass_mine} vs {mass_theirs} ({rel:+.2f}%)")


def main():
    if "--audit" in sys.argv:
        audit()
        return
    sys.exit(check())


if __name__ == "__main__":
    main()
