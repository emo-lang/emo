#!/usr/bin/env python3
"""The wallpaper's art (emo-desktop M31, A31.1): the volume's RLE file
and the golden's fixture words, generated from the formula's render.

The wallpaper the desktop paints stopped being arithmetic the shell
runs at boot and became a file on the volume — `wallpaper.rle`, the
frame's runs, the shell's boot decoding them into the wallpaper's
surface. This tool is where the art lives now: it renders the
procedural formula (the retired gradient and its three ribbons, the
arithmetic the screendump's model in `emo-os/run.sh` also carries) and
writes the two artifacts the tree wants:

  * the volume's file — a header word naming the magic and the mode,
    then one word per run, the pixel count in the low half and the
    opaque color in the high half, little-endian throughout, runs
    row-aligned and in order until they tile the frame exactly;
  * the golden's fixture module — the quarter-mode runs as chunked
    word tables the golden decodes beside the formula it must equal,
    plus the formula's own defs (the package retired them; the
    fixture, the golden's half, keeps them).

Regenerate after touching the formula's constants or the tool:

    python3 gen-wallpaper.py --out ../../../emo-os/wallpaper.rle

(the metal build embeds the file — `user.S` — and start.sh regenerates
it when missing or older than this tool; the volume's copy is the
first boot's install, `installed wallpaper.rle <size>` on the wire).
"""

import argparse
import os
import struct

MAGIC = int.from_bytes(b"EMOWALL1", "little")

# The formula's anchors (the package's `wall_top` and `wall_bottom`)
# and the three ribbons — the same constants the screendump's model
# names; the spans, slopes and inks the art's own.
TR, TG, TB = 0x10, 0x1C, 0x3C
BR, BG, BB = 0x40, 0x30, 0x6A


def mix(s, d, a):
    return (s * a + d * (255 - a) + 127) // 255


def tdiv(a, b):
    # the metal's division truncates toward zero (the ribbon slopes run
    # negative), python's floors — the model divides the metal's way
    q = abs(a) // abs(b)
    return -q if (a < 0) != (b < 0) else q


def over(src, dst):
    a = (src >> 24) & 0xFF
    if a >= 255:
        return src & 0xFFFFFF
    if a <= 0:
        return dst & 0xFFFFFF
    r = mix((src >> 16) & 0xFF, (dst >> 16) & 0xFF, a)
    g = mix((src >> 8) & 0xFF, (dst >> 8) & 0xFF, a)
    b = mix(src & 0xFF, dst & 0xFF, a)
    return (r << 16) | (g << 8) | b


def ribbons(w, h):
    # the spans, slopes, intercepts, widths and inks at the mode —
    # fractions of w and h whose 256ths and 128ths reproduce the
    # drawing the formula was tuned at
    return [(0, (5 * h) // 8, 3, 4, -((25 * w) // 128), (115 * w) // 256, 0x2830B8C8),
            ((5 * h) // 24, (15 * h) // 16, 1, 2, (15 * w) // 256, (25 * w) // 64, 0x20E86890),
            ((85 * h) // 192, h, -1, 4, (225 * w) // 256, (135 * w) // 256, 0x188868E8)]


def wall(w, h, x, y):
    denom = h - 1
    r = (TR * (denom - y) + BR * y) // denom
    g = (TG * (denom - y) + BG * y) // denom
    b = (TB * (denom - y) + BB * y) // denom
    p = (r << 16) | (g << 8) | b
    for y0, y1, m, d, c, wd, ink in ribbons(w, h):
        if y0 <= y < y1:
            x0 = c + tdiv(m * y, d)
            w0 = wd
            if x0 < 0:
                w0 += x0
                x0 = 0
            if x0 + w0 > w:
                w0 = w - x0
            if x0 <= x < x0 + w0:
                p = over(ink, p)
    return p


def encode(w, h):
    """The frame's run words: (color << 32) | count, row-aligned, in
    order, tiling the frame exactly."""
    runs = []
    for y in range(h):
        at = 0
        while at < w:
            color = wall(w, h, at, y)
            n = 1
            while at + n < w and wall(w, h, at + n, y) == color:
                n += 1
            runs.append((color << 32) | n)
            at += n
    return runs


def write_file(path, w, h, runs):
    with open(path, "wb") as f:
        f.write(struct.pack("<QQ", MAGIC, (h << 32) | w))
        for run in runs:
            f.write(struct.pack("<Q", run))


CHUNK = 448  # words to a table, the face fixtures' own chunk

FIXTURE_HEADER = """// The wallpaper's fixture (emo-desktop M31): the volume's RLE art as
// run words — the display mode's own and the quarter canvas's ({fw}x{fh})
// beside it — the gray art the palette's walk refuses, and the formula
// the package retired — all written by `gen-wallpaper.py` from the
// formula's render, the decode's truth the golden walks onto a quarter
// canvas beside the formula it must equal. A run word is the pixel
// count in its low half and the opaque color in its high half,
// row-aligned, in order, tiling the frame exactly.
//
//   python3 ../gen-wallpaper.py
"""


def runs_table(out, label, prefix, runs):
    """One run word table: chunked consts, the router, the array."""
    chunks = [runs[i:i + CHUNK] for i in range(0, len(runs), CHUNK)] or [[]]
    out.append("")
    out.append(f"def {prefix}words() Int64 {{\n  return {len(runs)}\n}}")
    out.append("")
    out.append(f"// The {label}'s tables: 448 words to a chunk, the face")
    out.append("// fixtures' chunk, the router below the reader's one door.")
    for ci, chunk in enumerate(chunks):
        out.append(f"const {prefix}data{ci} = [")
        for i in range(0, len(chunk), 8):
            line = ", ".join(str(word) for word in chunk[i:i + 8])
            comma = "," if i + 8 < len(chunk) else ""
            out.append(f"  {line}{comma}")
        out.append("]")
    out.append("")
    out.append(f"def {prefix}word(k Int64) Int64 {{")
    out.append("  const at = k")
    for ci in range(len(chunks)):
        lo, hi = CHUNK * ci, CHUNK * (ci + 1)
        out.append(f"  if at < {hi} {{")
        out.append(f"    return {prefix}data{ci}[at - {lo}]")
        out.append("  }")
    out.append("  return 0")
    out.append("}")
    out.append("")
    out.append(f"// The {label}'s runs whole, one array the walkers consume.")
    out.append(f"def {prefix}runs() Array[Int64] {{")
    out.append("  const holder = ArrayBuilder.new()")
    out.append("  var i = 0")
    out.append(f"  while i < {prefix}words() {{")
    out.append(f"    holder.push({prefix}word(i))")
    out.append("    i = i + 1")
    out.append("  }")
    out.append("  return holder.to_array()")
    out.append("}")


def fixture_module(fw, fh, qruns, fruns):
    out = [FIXTURE_HEADER.format(fw=fw, fh=fh)]
    out.append("//")
    out.append("// `runs()` are the display mode's own runs — the chrome's")
    out.append("// material rows and the palette's accent walk them at the mode the")
    out.append("// painters are called with (the rows are mode-wide); the quarter's")
    out.append("// own runs, `quarter_runs()`, serve the decode pin's small canvas.")
    runs_table(out, "display mode's art", "", fruns)
    runs_table(out, "quarter canvas's art", "quarter_", qruns)
    out.append("// The gray art (emo-desktop M31, A31.2): the failure's fixture —")
    out.append("// twenty-four rows of the mode's width, each one run of a plain")
    out.append("// gray, the channels' spread zero everywhere. The palette's walk")
    out.append("// refuses it, and the chrome's pins beside it wear the constants")
    out.append("// the failure keeps.")
    out.append("def gray_runs() Array[Int64] {")
    out.append("  const holder = ArrayBuilder.new()")
    out.append("  var row = 0")
    out.append("  while row < 24 {")
    out.append(f"    holder.push((((32 + row) * 65793) << 32) | 1920)")
    out.append("    row = row + 1")
    out.append("  }")
    out.append("  return holder.to_array()")
    out.append("}")
    out.append("")
    out.append("// The formula the package retired (emo-desktop A13, A14.3): the")
    out.append("// gradient row by row, the three ribbons over it — the fixture's")
    out.append("// own copy, the anchors the package still holds (the chrome's")
    out.append("// material samples them until the palette feeds it), the bytes")
    out.append("// the volume's file renders.")
    out.append("def wallpaper_formula(s ui_fb.Surface, w Int64, h Int64) Void {")
    out.append("  const denom = h - 1")
    out.append("  const tr = (emo_desktop.wall_top() >> 16) & 0xFF")
    out.append("  const tg = (emo_desktop.wall_top() >> 8) & 0xFF")
    out.append("  const tb = emo_desktop.wall_top() & 0xFF")
    out.append("  const br = (emo_desktop.wall_bottom() >> 16) & 0xFF")
    out.append("  const bg = (emo_desktop.wall_bottom() >> 8) & 0xFF")
    out.append("  const bb = emo_desktop.wall_bottom() & 0xFF")
    out.append("  var y = 0")
    out.append("  while y < h {")
    out.append("    const r = (tr * (denom - y) + br * y) / denom")
    out.append("    const g = (tg * (denom - y) + bg * y) / denom")
    out.append("    const b = (tb * (denom - y) + bb * y) / denom")
    out.append("    s.fill(0, y, w, 1, (r << 16) | (g << 8) | b)")
    out.append("    y = y + 1")
    out.append("  }")
    out.append("  ribbon_f(s, h, (0 << 32) | ((5 * h) / 8), 3, 4, -((25 * w) / 128),")
    out.append("    (115 * w) / 256, (0x28 << 24) | 0x30B8C8)")
    out.append("  ribbon_f(s, h, (((5 * h) / 24) << 32) | ((15 * h) / 16), 1, 2, (15 * w) / 256,")
    out.append("    (25 * w) / 64, (0x20 << 24) | 0xE86890)")
    out.append("  ribbon_f(s, h, (((85 * h) / 192) << 32) | h, -1, 4, (225 * w) / 256,")
    out.append("    (135 * w) / 256, (0x18 << 24) | 0x8868E8)")
    out.append("}")
    out.append("")
    out.append("// One translucent ribbon, the package's retired helper: the row's")
    out.append("// left edge a line, the width fixed, the ink a blend word.")
    out.append("def ribbon_f(s ui_fb.Surface, h Int64, span Int64, m Int64, d Int64,")
    out.append("             c Int64, width Int64, ink_color Int64) Void {")
    out.append("  var y = span >> 32")
    out.append("  if y < 0 {")
    out.append("    y = 0")
    out.append("  }")
    out.append("  var ye = span & 4294967295")
    out.append("  if ye > h {")
    out.append("    ye = h")
    out.append("  }")
    out.append("  while y < ye {")
    out.append("    const x = c + (m * y) / d")
    out.append("    s.blend(x, y, width, 1, ink_color)")
    out.append("    y = y + 1")
    out.append("  }")
    out.append("}")
    out.append("")
    return "\n".join(out)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", default="wallpaper.rle",
                    help="the volume's file (default: ./wallpaper.rle)")
    ap.add_argument("--width", type=int, default=1920)
    ap.add_argument("--height", type=int, default=1080)
    ap.add_argument("--fixture", default=os.path.join(here, "golden", "wall_rle.emo"),
                    help="the golden's fixture module")
    ap.add_argument("--fixture-width", type=int, default=256)
    ap.add_argument("--fixture-height", type=int, default=192)
    args = ap.parse_args()

    runs = encode(args.width, args.height)
    write_file(args.out, args.width, args.height, runs)
    fw, fh = args.fixture_width, args.fixture_height
    qruns = encode(fw, fh)
    os.makedirs(os.path.dirname(os.path.abspath(args.fixture)), exist_ok=True)
    with open(args.fixture, "w") as f:
        f.write(fixture_module(fw, fh, qruns, runs))
    size = 16 + 8 * len(runs)
    print(f"wallpaper.rle {args.width}x{args.height}: {len(runs)} runs, {size} bytes")
    print(f"fixture: {len(runs)} mode runs, {len(qruns)} quarter runs")


if __name__ == "__main__":
    main()
