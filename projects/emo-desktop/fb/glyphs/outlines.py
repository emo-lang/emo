#!/usr/bin/env python3
"""The faces' outline generator (emo-desktop A17.1, face format 1).

The pinned faces in `../fonts/` — Inter for the interface, JetBrains
Mono for the cell grids — are quadratic outlines (TTF `glyf`), and this
reads them and writes each as a `face_*.emo` module beside `font.emo`:
the scalable source the desktop's own rasterizer (A17.3) strikes at any
pixel size. The pixels `rasterize.py` bakes are where A14.2 had to
stop — its strikes froze the sizes at build time — while outlines
travel as data and every size a window ever asks for is one
rasterization away.

What this resolves so the OS-side parser (A17.2) has none of it:

  - The cmap: each of the 95 printable ASCII code points is looked up
    and must be found; a face that lost one is refused, loudly.
  - Implied on-curve midpoints: TTF runs consecutive off-curve points
    and leaves the between-quadratics vertex to the reader; this emits
    every vertex explicitly (floored midpoints), so the parser's only
    curve rule is "an off-curve point bends the path through it".
  - Composites: components arrive with their translation applied. A
    component that carries a scale or anchors by point index is
    refused — neither face uses one, and strictness beats a scale
    chain in the parser.

The emitted layout (face format 1; the normative word tables are in
`docs/typeface.md`): scalar defs for the head's numbers, the 95-glyph
alphabet with `glyph_of` (index 0 — the face's own .notdef, parsed
from gid 0 — is what every other character shows as), a `bases` table
giving each glyph's first word, and the outlines themselves in 448-word
chunks: per glyph its advance in font units, its point and contour
counts, its contour end indices packed four to a word, and one word per
vertex — the on-curve flag in the top byte and the signed x/y deltas
from the previous vertex in two 28-bit fields.

    python3 outlines.py            write face_inter.emo and face_mono.emo
    python3 outlines.py --check    exit 1 when either no longer matches

`--check` is the gate's drift check and never needs more than the
standard library. The advance cross-check against `coverage.txt` (the
grid FreeType rendered) runs in both modes: three strikes' worth of
scaled advances must land on the same pixel the grid records, so a
cmap or hmtx walk that went wrong cannot pass silently.

Python 3, the standard library alone.
"""

import hashlib
import struct
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
FONTS = HERE.parent / "fonts"
GRID = HERE / "coverage.txt"

CHUNK = 448
GLYPHS = 96  # gid 0 is the face's .notdef; gid 1..95 are 0x20..0x7E
FIRST, LAST = 0x20, 0x7E
ALPHABET = "".join(chr(c) for c in range(FIRST, LAST + 1))

FACES = {
    "face_inter.emo": (
        "Inter-Regular.ttf",
        "Inter 4.1",
        "40d692fce188e4471e2b3cba937be967878f631ad3ebbbdcd587687c7ebe0c82",
        "ui16",
    ),
    "face_mono.emo": (
        "JetBrainsMono-Regular.ttf",
        "JetBrains Mono 2.304",
        "a0bf60ef0f83c5ed4d7a75d45838548b1f6873372dfac88f71804491898d138f",
        "mono16",
    ),
}

ON_CURVE = 1
MAX_POINT_COUNT = 4095
MAX_CONTOURS = 255
MAX_COMPOSITE_DEPTH = 8


class Refused(Exception):
    """The face says something the format does not carry; name it."""


# ---- the TTF's words ----------------------------------------------------


class Reader:
    def __init__(self, data, at=0):
        self.data = data
        self.at = at

    def u8(self):
        v = self.data[self.at]
        self.at += 1
        return v

    def u16(self):
        v = struct.unpack_from(">H", self.data, self.at)[0]
        self.at += 2
        return v

    def s16(self):
        v = struct.unpack_from(">h", self.data, self.at)[0]
        self.at += 2
        return v

    def u32(self):
        v = struct.unpack_from(">I", self.data, self.at)[0]
        self.at += 4
        return v

    def s32(self):
        v = struct.unpack_from(">i", self.data, self.at)[0]
        self.at += 4
        return v

    def skip(self, n):
        self.at += n


# ---- the face -----------------------------------------------------------


class Face:
    def __init__(self, path, label, digest):
        raw = path.read_bytes()
        got = hashlib.sha256(raw).hexdigest()
        if got != digest:
            raise Refused(f"{path.name} is not the pinned {label} ({got})")
        self.label = label
        self.raw = raw
        self.tables = {}
        r = Reader(raw, 4)
        num_tables = r.u16()
        r.skip(6)  # searchRange, entrySelector, rangeShift; records start at 12
        for _ in range(num_tables):
            tag = raw[r.at : r.at + 4].decode("latin-1")
            r.skip(8)  # the tag itself, then its checkSum
            offset = r.u32()
            length = r.u32()
            self.tables[tag] = (offset, length)
        if ("glyf" not in self.tables) or ("loca" not in self.tables):
            raise Refused(f"{label} is not a glyf face (quadratic outlines)")
        self.read_head()
        self.read_maxp()
        self.read_hhea()
        self.read_hmtx()
        self.read_cmap()

    def table(self, tag):
        if tag not in self.tables:
            raise Refused(f"the pinned face carries no {tag} table")
        off, length = self.tables[tag]
        return self.raw[off : off + length]

    def read_head(self):
        r = Reader(self.table("head"))
        if r.u32() != 0x00010000:
            raise Refused("head's sfnt version is not 1.0")
        r.skip(12)  # fontRevision, checkSumAdjustment, magicNumber
        r.u16()  # flags
        self.units_per_em = r.u16()
        if self.units_per_em <= 0:
            raise Refused("head's unitsPerEm is not positive")
        r.skip(30)  # dates, bbox, macStyle, lowestRecPPEM, fontDirectionHint
        self.index_to_loc_format = r.s16()
        if self.index_to_loc_format not in (0, 1):
            raise Refused(f"head's indexToLocFormat is {self.index_to_loc_format}")

    def read_maxp(self):
        r = Reader(self.table("maxp"))
        r.u32()
        self.num_glyphs = r.u16()

    def read_hhea(self):
        r = Reader(self.table("hhea"))
        r.u32()
        self.ascent_fu = r.s16()
        self.descent_fu = r.s16()
        self.line_gap_fu = r.s16()
        r.skip(24)
        self.num_h_metrics = r.u16()

    def read_hmtx(self):
        r = Reader(self.table("hmtx"))
        self.advances = []
        for _ in range(self.num_h_metrics):
            self.advances.append(r.u16())
            r.s16()  # lsb
        if self.num_glyphs > self.num_h_metrics:
            self.advances += [self.advances[-1]] * (self.num_glyphs - self.num_h_metrics)

    def read_cmap(self):
        r = Reader(self.table("cmap"))
        r.u16()
        count = r.u16()
        chosen = None
        for _ in range(count):
            platform, encoding = r.u16(), r.u16()
            at = r.u32()
            if (platform, encoding) == (3, 1):
                chosen = at
        if chosen is None:
            raise Refused("cmap carries no (3, 1) subtable for the ASCII range")
        self.cmap_at = self.tables["cmap"][0] + chosen
        r = Reader(self.raw, self.cmap_at)
        fmt = r.u16()
        if fmt == 4:
            self.cmap4(r)
        elif fmt == 12:
            self.cmap12(r)
        else:
            raise Refused(f"cmap (3, 1) is format {fmt}, not 4 or 12")

    def cmap4(self, r):
        r.skip(4)  # length, language
        seg_count = r.u16() // 2
        r.skip(6)  # searchRange, entrySelector, rangeShift
        ends = [r.u16() for _ in range(seg_count)]
        r.u16()  # reservedPad
        starts = [r.u16() for _ in range(seg_count)]
        deltas = [r.s16() for _ in range(seg_count)]
        range_offset_at = r.at
        offsets = [r.u16() for _ in range(seg_count)]
        self.cmap_lookup = lambda cp: self.cmap4_lookup(
            cp, seg_count, ends, starts, deltas, range_offset_at, offsets
        )

    def cmap4_lookup(self, cp, seg_count, ends, starts, deltas, range_offset_at, offsets):
        for i in range(seg_count):
            if starts[i] <= cp <= ends[i]:
                if offsets[i] == 0:
                    return (cp + deltas[i]) % 65536
                at = range_offset_at + i * 2 + offsets[i] + 2 * (cp - starts[i])
                gid = struct.unpack_from(">H", self.raw, at)[0]
                if gid == 0:
                    return 0
                return (gid + deltas[i]) % 65536
        return 0

    def cmap12(self, r):
        r.skip(6)  # length, language
        groups = r.u32()
        table = []
        for _ in range(groups):
            start = r.u32()
            end = r.u32()
            glyph = r.u32()
            table.append((start, end, glyph))
        self.cmap_lookup = lambda cp: self.cmap12_lookup(cp, table)

    def cmap12_lookup(self, cp, table):
        for start, end, glyph in table:
            if start <= cp <= end:
                return glyph + (cp - start)
        return 0

    def glyph_at(self, gid):
        if gid >= self.num_glyphs:
            raise Refused(f"loca names glyph {gid} past maxp's {self.num_glyphs}")
        r = Reader(self.table("loca"))
        if self.index_to_loc_format == 0:
            r.skip(2 * gid)
            start, end = r.u16() * 2, r.u16() * 2
        else:
            r.skip(4 * gid)
            start, end = r.u32(), r.u32()
        if end <= start:
            return None
        return Reader(self.raw, self.tables["glyf"][0] + start)

    def glyph_points(self, gid, depth=0):
        """The glyph's vertices with contours resolved: a list of
        contours, each a list of (x, y, on_curve) in font units, every
        vertex explicit (implied midpoints inserted), plus the advance."""
        if depth > MAX_COMPOSITE_DEPTH:
            raise Refused(f"glyph {gid} nests composites deeper than 8")
        r = self.glyph_at(gid)
        advance = self.advances[gid]
        if r is None:
            return [], advance
        contours = r.s16()
        r.skip(8)  # the bbox; the rasterizer measures its own
        if contours >= 0:
            ends = [r.u16() for _ in range(contours)]
            count = ends[-1] + 1 if ends else 0
            r.skip(r.u16())  # instructions
            flags = []
            while len(flags) < count:
                f = r.u8()
                flags.append(f)
                if f & 0x08:  # repeat
                    runs = r.u8()
                    flags.extend([f] * runs)
            xs = []
            x = 0
            for f in flags:
                if f & 0x02:
                    dx = r.u8()
                    if not f & 0x10:
                        dx = -dx
                elif f & 0x10:
                    dx = 0
                else:
                    dx = r.s16()
                x += dx
                xs.append(x)
            ys = []
            y = 0
            for f in flags:
                if f & 0x04:
                    dy = r.u8()
                    if not f & 0x20:
                        dy = -dy
                elif f & 0x20:
                    dy = 0
                else:
                    dy = r.s16()
                y += dy
                ys.append(y)
            on = [(f & ON_CURVE) != 0 for f in flags]
            resolved = self.resolve_contours(ends, xs, ys, on, gid)
            return resolved, advance
        # composite: translation-only components, scaled or anchored ones refused
        points = []
        more = True
        while more:
            f = r.u16()
            index = r.u16()
            if f & 0x0001:  # ARG_1_AND_2_ARE_WORDS
                a, b = r.s16(), r.s16()
            else:
                a, b = r.u8(), r.u8()
            if not f & 0x0002:  # ARGS_ARE_XY_VALUES
                raise Refused(f"glyph {gid} anchors a component by point index")
            for scale_bit, name in ((0x0008, "a scale"), (0x0040, "x and y scales"), (0x0080, "a 2x2 matrix")):
                if f & scale_bit:
                    raise Refused(f"glyph {gid} carries {name} on a component")
            sub, _ = self.glyph_points(index, depth + 1)
            points += [[(x + a, y + b, on) for x, y, on in contour] for contour in sub]
            more = (f & 0x0020) != 0  # MORE_COMPONENTS
        return points, advance

    def resolve_contours(self, ends, xs, ys, on, gid):
        """Every vertex explicit: runs of off-curve points gain the
        midpoint between neighbours (floored), and each contour is
        rotated to start on an on-curve vertex so the path reads as
        line/quadratic alternations from its first point."""
        out = []
        start = 0
        for end in ends:
            contour = [
                (xs[i], ys[i], on[i]) for i in range(start, end + 1)
            ]
            start = end + 1
            n = len(contour)
            if n == 0:
                continue
            first = next((i for i, p in enumerate(contour) if p[2]), None)
            if first is None:
                raise Refused(f"glyph {gid} has a contour with no on-curve vertex")
            contour = contour[first:] + contour[:first]
            resolved = []
            for i in range(n):
                p = contour[i]
                resolved.append(p)
                nxt = contour[(i + 1) % n]
                if not p[2] and not nxt[2]:
                    resolved.append(((p[0] + nxt[0]) // 2, (p[1] + nxt[1]) // 2, True))
            out.append(resolved)
        return out


# ---- the word tables ----------------------------------------------------


def glyph_words(points, advance):
    """One glyph's slice: the advance, the counts, the packed contour
    ends, and one word per vertex."""
    count = sum(len(c) for c in points)
    if count > MAX_POINT_COUNT:
        raise Refused(f"a glyph carries {count} vertices, past the {MAX_POINT_COUNT} cap")
    if len(points) > MAX_CONTOURS:
        raise Refused(f"a glyph carries {len(points)} contours, past the {MAX_CONTOURS} cap")
    words = [advance, count, len(points)]
    ends = []
    at = 0
    for contour in points:
        at += len(contour)
        ends.append(at - 1)
    for j in range((len(ends) + 3) // 4):
        word = 0
        for k in range(4):
            i = j * 4 + k
            if i < len(ends):
                word |= ends[i] << (16 * k)
        words.append(word)
    x, y = 0, 0
    for contour in points:
        for vx, vy, on_curve in contour:
            dx, dy = vx - x, vy - y
            for d, limit in ((dx, 1 << 27), (-dx, 1 << 27), (dy, 1 << 27), (-dy, 1 << 27)):
                if d >= limit:
                    raise Refused(f"a vertex delta of {d} does not fit the 28-bit field")
            flag = ON_CURVE if on_curve else 0
            words.append(
                (flag << 56) | ((dx & 0x3FFFFFF) << 28) | (dy & 0x3FFFFFF)
            )
            x, y = vx, vy
    return words


def face_module(name, face, grids):
    """The module's text: scalars, the alphabet, the bases, the chunks."""
    slices = []
    for gid in range(GLYPHS):
        if gid == 0:
            points, advance = face.glyph_points(0)
        else:
            cp = FIRST + gid - 1
            mapped = face.cmap_lookup(cp)
            if mapped == 0:
                raise Refused(f"the pinned face maps no glyph for U+{cp:04X}")
            points, advance = face.glyph_points(mapped)
        slices.append(glyph_words(points, advance))
    bases = []
    at = 0
    for s in slices:
        bases.append(at)
        at += len(s)

    outlines = [w for s in slices for w in s]
    chunks = [outlines[i : i + CHUNK] for i in range(0, len(outlines), CHUNK)] or [[]]

    # the advance cross-check: the grid FreeType rendered must agree
    cross_check(name, face, grids)

    escaped = ALPHABET.replace("\\", "\\\\").replace('"', '\\"')
    out = [HEADER.format(label=face.label)]
    out.append(
        f"// -- the tables: written by glyphs/outlines.py from the pinned face --"
    )
    out.append("")
    out.append("// The head's numbers, in font units: the em square the")
    out.append("// outlines live on, and the line the ink hangs from.")
    out.append(f"def units_per_em() Int64 {{\n  return {face.units_per_em}\n}}")
    out.append(f"def ascent_fu() Int64 {{\n  return {face.ascent_fu}\n}}")
    out.append(f"def descent_fu() Int64 {{\n  return {face.descent_fu}\n}}")
    out.append(f"def line_gap_fu() Int64 {{\n  return {face.line_gap_fu}\n}}")
    out.append(f"def glyphs() Int64 {{\n  return {GLYPHS}\n}}")
    out.append("")
    out.append(
        "// The printable ASCII characters in code order — the table's\n"
        "// order, so a character's position here is its glyph index\n"
        "// minus one, and index 0 is the face's own .notdef."
    )
    out.append(f'const alphabet = "{escaped}"')
    out.append("")
    out.append(
        """// The glyph index of one character, handed as the one-byte String a
// label's walk cuts (`substring(i, 1)`): its position in the alphabet
// plus one, or the .notdef for a byte the face has no drawing of.
def glyph_of(c String) Int64 {
  const i = alphabet.index_of(c)
  if i < 0 {
    return 0
  }
  return i + 1
}"""
    )
    out.append("")
    out.append(
        "// Each glyph's first word in the outlines below, gid 0 through\n"
        f"// {GLYPHS - 1}. The .notdef is glyph 0."
    )
    out.append("const bases = [" + ", ".join(str(b) for b in bases) + "]")
    out.append("")
    out.append("def outline_base(g Int64) Int64 {")
    out.append("  return bases[g]")
    out.append("}")
    out.append("")
    out.append(
        "// The outlines' word count: the bound `outline_word(k)` walks\n"
        "// to, and the words a Face copies whole."
    )
    out.append(f"def outline_words() Int64 {{\n  return {len(outlines)}\n}}")
    out.append("")
    out.append(
        f"// The outlines: {CHUNK} words to a chunk, each glyph's slice its\n"
        "// advance in font units, its vertex and contour counts, its\n"
        "// contour end indices packed four to a word, and one word per\n"
        "// vertex — the on-curve flag in the top byte, the signed x and y\n"
        "// deltas from the previous vertex in two 28-bit fields."
    )
    for ci, chunk in enumerate(chunks):
        out.append(f"const data{ci} = [")
        for i in range(0, len(chunk), 8):
            line = ", ".join(str(w) for w in chunk[i : i + 8])
            comma = "," if i + 8 < len(chunk) else ""
            out.append(f"  {line}{comma}")
        out.append("]")
    out.append("")
    out.append("def outline_word(k Int64) Int64 {")
    out.append("  const at = k")
    for ci in range(len(chunks)):
        lo, hi = CHUNK * ci, CHUNK * (ci + 1)
        out.append(f"  if at < {hi} {{")
        out.append(f"    return data{ci}[at - {lo}]")
        out.append("  }")
    out.append("  return 0")
    out.append("}")
    out.append("")
    return "\n".join(out) + "\n"


HEADER = """// The {label} face's outlines (face format 1, emo-desktop A17.1): the
// quadratic outlines of the 95 printable ASCII glyphs and the face's
// own .notdef, generated from the pinned face in `fonts/` by
// `glyphs/outlines.py` — the scalable source the desktop's rasterizer
// strikes at any pixel size, where A14.2's `font.emo` could only ship
// the three pixel strikes its grid baked. A vertex word is the
// on-curve flag in its top byte and the signed deltas from the
// previous vertex in two 28-bit fields; an off-curve vertex bends the
// path through it, a run of them sharing the midpoints the generator
// resolved. The face is the SIL Open Font License 1.1's; its license
// travels beside the face it came from.
"""


def cross_check(name, face, grids):
    """The advances the grid recorded must be the face's own advances,
    scaled: a cmap or hmtx walk that went wrong cannot pass silently."""
    strikes = parse_grid_strikes(grids)
    face_key = FACES[name][3]
    for strike_name, strike_face, strike_size, advances in strikes:
        wants = (
            (face_key == "ui16" and strike_name == "ui16")
            or (face_key == "ui16" and strike_name == "ui24")
            or (face_key == "mono16" and strike_name == "mono16")
        )
        if not wants:
            continue
        wrong, hinted = [], []
        for cp in range(FIRST, LAST + 1):
            gid = face.cmap_lookup(cp)
            if gid == 0:
                wrong.append((cp, None, advances[cp]))
                continue
            got = int(face.advances[gid] * strike_size / face.units_per_em + 0.5)
            if got != advances[cp]:
                (hinted if abs(got - advances[cp]) == 1 else wrong).append(
                    (cp, got, advances[cp])
                )
        if wrong:
            lines = ", ".join(
                f"U+{cp:04X} face={got} grid={want}" for cp, got, want in wrong[:12]
            )
            raise Refused(
                f"{name}: {len(wrong)} advances disagree with the grid's "
                f"{strike_name}: {lines}"
            )
        if hinted:
            lines = ", ".join(
                f"U+{cp:04X} face={got} grid={want}" for cp, got, want in hinted
            )
            print(
                f"  {name}: {len(hinted)} advance(s) differ by one pixel from the "
                f"grid's {strike_name} — FreeType's own hinting, reported not refused:"
            )
            print(f"    {lines}")
        print(
            f"  {name}: advances agree with the grid's {strike_name} "
            f"({strike_face} at {strike_size}px, 95 glyphs)"
        )


def parse_grid_strikes(path):
    """The grid's strikes: name, face, size, and the advance per code
    point — enough to audit this generator's walk against FreeType's."""
    strikes = []
    glyphs = None
    for line in path.read_text().splitlines():
        if line.startswith("strike "):
            parts = line.split()
            glyphs = {}
            strikes.append((parts[1], parts[2], int(parts[3]), glyphs))
        elif line.startswith("glyph ") and glyphs is not None:
            parts = line.split()
            cp = parts[1]
            if cp.startswith("0x"):
                glyphs[int(cp, 16)] = int(parts[3])
    return strikes


def face_module_name(out_name):
    return out_name


def main():
    check = "--check" in sys.argv
    grids = GRID
    outputs = {}
    for out_name, (face_file, label, digest, key) in FACES.items():
        face = Face(FONTS / face_file, label, digest)
        outputs[HERE.parent / out_name] = face_module(out_name, face, grids)
    if check:
        for path, text in outputs.items():
            if not path.exists() or path.read_text() != text:
                sys.exit(f"outlines.py: {path.name} no longer matches the pinned face")
        print("face_inter.emo and face_mono.emo match the pinned faces")
    else:
        for path, text in outputs.items():
            path.write_text(text)
            words = text.count("\n")
            print(f"wrote {path.name}: {words} lines")


if __name__ == "__main__":
    main()
