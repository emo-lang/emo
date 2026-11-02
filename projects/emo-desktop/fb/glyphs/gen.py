#!/usr/bin/env python3
"""The glyph table's generator (emo-desktop A8.1).

`glyphs.txt` is where the bitmap font is drawn; this writes the drawing
into `font.emo` as the `rows` table — four 32-bit words per glyph, each
word four rows with the topmost in the high byte, a row's left cell its
high bit — between the two marker lines the module carries, and
touches nothing else in the file. The drawing lives in a directory of
its own, `glyphs/`, because a sibling named `font/` would claim the
module path `font.emo` holds.

    python3 gen.py            rewrite the table in ../font.emo
    python3 gen.py --check    exit 1 when the table no longer matches
                              glyphs.txt (the gate's drift check)

Python 3, the standard library only.
"""

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
GLYPHS = HERE / "glyphs.txt"
MODULE = HERE.parent / "font.emo"
BEGIN = "// -- the glyph table: written by glyphs/gen.py from glyphs/glyphs.txt --"
END = "// -- the end of the glyph table --"
CELL_W, CELL_H = 8, 16
FIRST, LAST = 0x20, 0x7E


def parse(text):
    """The glyphs in file order: (label, [16 row bytes])."""
    glyphs, header, rows = [], None, []
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.rstrip("\n")
        if header is None:
            if line.startswith("0x") or line == "missing":
                header, rows = line, []
            elif line == "" or line.startswith("--"):
                continue
            else:
                sys.exit(f"{GLYPHS}:{n}: expected a glyph header, got {line!r}")
            continue
        if len(line) != CELL_W or set(line) - set(".#"):
            sys.exit(f"{GLYPHS}:{n}: a row is {CELL_W} cells of `.` or `#`, got {line!r}")
        if line[CELL_W - 1] == "#":
            sys.exit(f"{GLYPHS}:{n}: the last cell is the gap between glyphs and stays clear")
        rows.append(sum(1 << (CELL_W - 1 - i) for i, c in enumerate(line) if c == "#"))
        if len(rows) == CELL_H:
            glyphs.append((header, rows))
            header = None
    if header is not None:
        sys.exit(f"{GLYPHS}: the glyph {header!r} ends short of {CELL_H} rows")
    expected = [f"0x{c:02X}" for c in range(FIRST, LAST + 1)] + ["missing"]
    got = [h.split()[0] for h, _ in glyphs]
    if got != expected:
        sys.exit(f"{GLYPHS}: the glyphs must run 0x20 to 0x7E in order, then `missing`")
    return glyphs


def words(rows):
    return [
        (rows[k] << 24) | (rows[k + 1] << 16) | (rows[k + 2] << 8) | rows[k + 3]
        for k in range(0, CELL_H, 4)
    ]


def table(glyphs):
    out = [BEGIN, "const rows = ["]
    for i, (header, rows) in enumerate(glyphs):
        cells = ", ".join(f"0x{w:08X}" for w in words(rows))
        comma = "," if i + 1 < len(glyphs) else ""
        out.append(f"  {cells}{comma} // {header}")
    out.append("]")
    out.append(END)
    return "\n".join(out) + "\n"


def splice(module, generated):
    lines = module.split("\n")
    try:
        b, e = lines.index(BEGIN), lines.index(END)
    except ValueError:
        sys.exit(f"{MODULE}: the marker lines are missing")
    return "\n".join(lines[:b]) + "\n" + generated + "\n".join(lines[e + 1 :])


def main(argv):
    check = argv[1:] == ["--check"]
    if argv[1:] not in ([], ["--check"]):
        sys.exit(__doc__)
    generated = table(parse(GLYPHS.read_text()))
    module = MODULE.read_text()
    updated = splice(module, generated)
    if check:
        if updated != module:
            sys.exit(f"{MODULE}: the glyph table is stale; run glyphs/gen.py")
        return
    if updated != module:
        MODULE.write_text(updated)
        print(f"wrote the glyph table into {MODULE}")
    else:
        print(f"{MODULE} is current")


if __name__ == "__main__":
    main(sys.argv)
