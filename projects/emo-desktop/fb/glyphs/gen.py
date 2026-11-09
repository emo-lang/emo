#!/usr/bin/env python3
"""The type's generator (emo-desktop A14.2).

`coverage.txt` — the grid `rasterize.py` renders from `../fonts/` — is
where the strikes are; this writes `font.emo` whole: the alphabet, the
strikes' line boxes, one meta word per glyph (advance, ink offsets, ink
size, base into the coverage data) and the coverage itself, sixteen
levels a pixel packed two to a byte and eight to a word in chunks the
metal's frames can spill. `--check` regenerates and refuses a
`font.emo` that no longer matches, which is the gate's drift check and
the only thing it needs Python for — this script, the standard
library alone.

    python3 gen.py            rewrite font.emo from coverage.txt
    python3 gen.py --check    exit 1 when the table no longer matches

Python 3, the standard library only. (`glyphs.txt`, the hand-drawn 8x16
drawing this wrote before A14.2, is gone with the cell it drew; the
grid replaced it.)
"""

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
GRID = HERE / "coverage.txt"
MODULE = HERE.parent / "font.emo"

# The coverage data's chunk, in words: a chunk lands in one const
# array, whose build spills its elements through one frame — 448 words
# is 3.5 KiB, well inside every profile's stack.
CHUNK = 448
STRIKE_COUNT = 3
GLYPHS = 96

HEADER = """// The type (emo-desktop A14.2): three strikes rasterized from the
// faces in `fonts/` — Inter at 16 and 24 pixels for the interface,
// JetBrains Mono at 16 for the cell grids — through
// `glyphs/rasterize.py`, whose coverage grid this file is written from
// by `glyphs/gen.py` (the gate refuses a stale table). The faces are
// the SIL Open Font License 1.1's; their licenses travel beside them
// and the tables are the license's 3.1's permit: a modified version,
// shipped as data with the license standing beside it.
//
// A strike is its line box and one meta word per glyph — the advance,
// the ink's offsets from the pen at the line box's top-left, the ink's
// size in pixels, and the glyph's first word in the coverage data —
// and the coverage itself: sixteen levels a pixel (`pixel`'s answer,
// 0 to 255 in steps of 17), packed two pixels to a byte, the even
// pixel in the low nibble, and eight pixels to a word, the words in
// fixed chunks `word` walks to. The 95 printable ASCII characters sit
// in code order and the 96th — the face's own .notdef, reached through
// a byte no mapping names — is what every other character shows as.
"""

ALPHABET = "".join(chr(c) for c in range(0x20, 0x7F))


def parse(path):
    strikes = []
    glyphs = None
    for line in path.read_text().splitlines():
        if line.startswith("strike "):
            parts = line.split()
            glyphs = []
            strikes.append(
                {
                    "ascent": int(parts[-3]),
                    "descent": int(parts[-1]),
                    "glyphs": glyphs,
                }
            )
        elif line.startswith("glyph "):
            parts = line.split()
            w, h = (int(v) for v in parts[-1].split("x"))
            glyphs.append(
                {
                    "advance": int(parts[3]),
                    "left": int(parts[5]),
                    "top": int(parts[7]),
                    "w": w,
                    "h": h,
                    "rows": [],
                }
            )
        elif line.startswith("  ") and glyphs:
            glyphs[-1]["rows"].append(line[2:])
    return strikes


def nibbles(g):
    """The glyph's coverage as one word list: pixel 8k+2j (even) in byte
    j's low nibble, its right neighbor in the high, byte j in bits 8j."""
    flat = [0 if ch == "." else int(ch, 16) for row in g["rows"] for ch in row]
    out = []
    for k in range((len(flat) + 7) // 8):
        word = 0
        for j in range(4):
            b = k * 8 + j * 2
            lo = flat[b] if b < len(flat) else 0
            hi = flat[b + 1] if b + 1 < len(flat) else 0
            word |= ((hi << 4) | lo) << (8 * j)
        out.append(word)
    return out


def emo_words(words, per_line):
    lines = []
    for i in range(0, len(words), per_line):
        lines.append("  " + ", ".join(f"0x{w:08X}" for w in words[i : i + per_line]) + ",")
    lines[-1] = lines[-1].rstrip(",")
    return lines


def meta_word(advance, left, top, w, h, base):
    for v, lo, hi in ((advance, 0, 255), (w, 0, 255), (h, 0, 255)):
        if not lo <= v <= hi:
            raise SystemExit(f"gen.py: meta value {v} outside {lo}..{hi}")
    for v in (left, top):
        if not -128 <= v <= 127:
            raise SystemExit(f"gen.py: ink offset {v} outside -128..127")
    if not 0 <= base <= 8191:
        raise SystemExit(f"gen.py: base {base} outside 0..8191")
    return (
        ((top + 128) << 45)
        | ((left + 128) << 37)
        | (w << 29)
        | (h << 21)
        | (advance << 13)
        | base
    )


def build(strikes):
    flat, bases = [], []
    for s in strikes:
        for g in s["glyphs"]:
            bases.append(len(flat))
            flat += nibbles(g)
    chunks = [flat[i : i + CHUNK] for i in range(0, len(flat), CHUNK)] or [[]]
    out = [HEADER, "// -- the tables: written by glyphs/gen.py from glyphs/coverage.txt --", ""]
    out.append(
        "// The printable ASCII characters in code order — the table's\n"
        "// order, so a character's position here is its glyph index.\n"
    )
    escaped = ALPHABET.replace("\\", "\\\\").replace('"', '\\"')
    out.append(f'const alphabet = "{escaped}"')
    out.append("")
    out.append(
        "// The strikes, the numbers a surface's `ink` names; each line\n"
        "// box's height, then its ascent.\n"
    )
    metrics = []
    for s in strikes:
        metrics += [s["ascent"] + s["descent"], s["ascent"]]
    out.append("const line_boxes = [" + ", ".join(str(v) for v in metrics) + "]")
    out.append("")
    out.append(
        "// One meta word per glyph, strikes in order: the ink's top from\n"
        "// the line box's top (bits 45, +128), its left from the pen (37,\n"
        "// +128), the width (29), the height (21), the advance (13), and\n"
        "// the glyph's first word in the coverage data (0).\n"
    )
    meta = []
    for si, s in enumerate(strikes):
        for gi, g in enumerate(s["glyphs"]):
            meta.append(
                meta_word(
                    g["advance"], g["left"], g["top"], g["w"], g["h"], bases[si * GLYPHS + gi]
                )
            )
    out.append("const meta = [")
    out += emo_words(meta, 6)
    out.append("]")
    out.append("")
    out.append(
        f"// The coverage data, {CHUNK} words to a chunk — pixel 8k+2j in\n"
        "// byte j's low nibble and its right neighbor in the high, byte j\n"
        "// in bits 8j.\n"
    )
    for ci, chunk in enumerate(chunks):
        out.append(f"const data{ci} = [")
        out += emo_words(chunk, 8)
        out.append("]")
    out.append("")
    out.append("// -- the end of the tables --")
    out.append("")
    out.append(f"""// The glyph every character outside the table renders as.
def missing() Int64 {{
  return {GLYPHS - 1}
}}

// The strikes, the numbers a surface's `ink` names.
def strikes() Int64 {{
  return {STRIKE_COUNT}
}}

def ui16() Int64 {{
  return 0
}}

def ui24() Int64 {{
  return 1
}}

def mono16() Int64 {{
  return 2
}}

// The glyph index of one character, handed as the one-byte String a
// label's walk cuts (`substring(i, 1)`): its position in the alphabet,
// or the missing glyph for a byte the font has no drawing of.
def glyph_of(c String) Int64 {{
  const i = alphabet.index_of(c)
  if i < 0 {{
    return missing()
  }}
  return i
}}

// The line box a strike's labels measure against, and the ascent the
// ink hangs from.
def line_height(s Int64) Int64 {{
  return line_boxes[s * 2]
}}

def ascent(s Int64) Int64 {{
  return line_boxes[s * 2 + 1]
}}

def meta_word(s Int64, i Int64) Int64 {{
  return meta[s * {GLYPHS} + i]
}}

// A glyph's advance, its ink's offsets from the pen at the line box's
// top-left, and its size.
def advance(s Int64, i Int64) Int64 {{
  return (meta_word(s, i) >> 13) & 255
}}

def gleft(s Int64, i Int64) Int64 {{
  return ((meta_word(s, i) >> 37) & 255) - 128
}}

def gtop(s Int64, i Int64) Int64 {{
  return ((meta_word(s, i) >> 45) & 255) - 128
}}

def gw(s Int64, i Int64) Int64 {{
  return (meta_word(s, i) >> 29) & 255
}}

def gh(s Int64, i Int64) Int64 {{
  return (meta_word(s, i) >> 21) & 255
}}

// The advance of one character, the mapping the labels walk by.
def char_advance(s Int64, c String) Int64 {{
  return advance(s, glyph_of(c))
}}

// The words one glyph's coverage spans.
def words(s Int64, i Int64) Int64 {{
  return (gw(s, i) * gh(s, i) + 7) / 8
}}

// The k-th coverage word of a glyph: the chunk `base` names and the
// offset inside it.
def word(s Int64, i Int64, k Int64) Int64 {{
  const at = (meta_word(s, i) & 8191) + k
""")
    out.append(
        "\n".join(
            f"  if at < {CHUNK * (ci + 1)} {{\n    return data{ci}[at - {CHUNK * ci}]\n  }}"
            for ci in range(len(chunks))
        )
    )
    out.append(
        f"""  return 0
}}

// One pixel of a glyph's ink: its coverage, 0 to 255 in steps of 17.
def pixel(s Int64, i Int64, m Int64) Int64 {{
  return ((word(s, i, m / 8) >> ((m % 8) * 4)) & 15) * 17
}}
""")
    return "\n".join(out) + "\n"


def main():
    check = "--check" in sys.argv
    text = build(parse(GRID))
    if check:
        if not MODULE.exists() or MODULE.read_text() != text:
            sys.exit("gen.py: font.emo no longer matches coverage.txt")
        print("font.emo matches coverage.txt")
    else:
        MODULE.write_text(text)
        print(f"wrote {MODULE.name}: {len(text.splitlines())} lines")


if __name__ == "__main__":
    main()
