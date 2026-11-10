# The type at any size (M17)

The desktop's type has been a real typeface since A14.2 — Inter for the
interface, JetBrains Mono for the cell grids — but it travels as three
pixel strikes (Inter at 16 and 24, JetBrains Mono at 16) that
`glyphs/rasterize.py` bakes on the host through Pillow's FreeType. A
window that wants its title at 32 pixels, a body at 20, or a whole
interface twice the size for a denser display has no answer today: the
sizes are frozen where the generator left them, and every new strike
grows `font.emo` by another 96 glyphs of coverage. The text itself is
already crisp at the pixels it occupies — a maximized window relayouts
and re-renders, and the strike it renders is native to the display —
what the desktop lacks is the *freedom of size*, and with it the
freedom to scale the interface at all (a 2x display is a room full of
sizes the pipeline cannot bake).

M17 moves the rasterization into the OS. The faces travel as quadratic
outlines (they always were that, underneath the grid), and a rasterizer
in Emo strikes any glyph at any pixel size on first use, keeping the
result in a strike that lives as long as its app does. The decisions
below were made 2026-11-09; the ladder is A17.1 through A17.4.

## The decisions

- **D7 — the outlines ride as generated modules.** Each face is
  compiled in as a `face_*.emo` data module written by
  `glyphs/outlines.py` from the pinned TTF, the way `gen.py` wrote
  `font.emo` from the grid. No runtime file reads a font — the six
  targets need no new file capability, the hosted goldens stay
  single-source, and the metal carries the outlines in its image as it
  carried the pixels. The outlines are *smaller* than the pixels they
  replace: Inter's 96 glyphs are 3,383 words in 8 chunks and JetBrains
  Mono's are 2,973 in 7, against the 4,269 words of the three strikes
  they retire — and one table now answers every size instead of three.
- **D8 — the rasterizer is the OS's own, integer only, with a
  normative reference.** All arithmetic is 26.6 fixed point in `Int64`
  — no `Float64` anywhere in the path, so every target lands on the
  same byte by construction. The algorithm's source of truth is a
  stdlib-only Python reference (`glyphs/reference.py`, written in
  A17.3); the Emo rasterizer must reproduce it byte for byte, and the
  goldens pin exactly that. FreeType stays the visual audit, not the
  oracle.
- **D9 — coverage is eight-bit.** The strikes store one coverage byte
  per pixel (the A14.2 grid's sixteen levels were a storage choice),
  fed straight to the source-over arithmetic the surfaces already run.
- **D10 — the seam keeps its shape.** `ink` keeps its five-argument
  form; its strike argument widens from an `Int64` table index to a
  `Strike`, the dense per-size object A17.2 builds. `text` and
  `text_width` take the strike they draw in, and every caller names its
  own size.
- **D11 — the pixel pipeline retires at A17.4.** `font.emo`,
  `glyphs/gen.py` and `coverage.txt` go; `glyphs/rasterize.py` stays as
  the audit's reference renderer. One text path, not two.
- **D12 — expansion has named triggers, none pulled yet.** Hinting
  (below 14px grows soft), kerning pairs, fractional advances, CJK
  coverage, and weight faces each reopen when their need is real; see
  the non-goals.

## The face format (format 1)

A face module (`face_inter.emo`, `face_mono.emo`) is generated text,
checked against its TTF by `outlines.py --check` in the gate. It
carries:

- Scalar defs from `head` and `hhea`: `units_per_em` (Inter 2048, JBM
  1000), `ascent_fu` (1984 / 1020), `descent_fu` (−494 / −300, hhea's
  sign), `line_gap_fu`, and `glyphs` (always 96: gid 0 is the face's
  own `.notdef`, gid 1..95 are 0x20..0x7E in code order).
- `glyph_of(c String)`, the alphabet's `index_of` walk the labels
  already use, answering 0 — the `.notdef` — for anything outside.
- `bases`, one word per glyph: the slice's first word in the outlines.
- The outlines in 448-word chunks behind `outline_word(k)`, the same
  chunk discipline `font.emo`'s tables use. A glyph's slice is:

| words | field |
|-------|-------|
| 1 | advance, font units |
| 1 | vertex count (cap 4095) |
| 1 | contour count (cap 255) |
| ⌈contours/4⌉ | contour end indices, four 16-bit fields to a word, little end |
| rest | one word per vertex |

  A vertex word packs the on-curve flag into its top byte (bit 56, the
  only flag defined) and the signed deltas from the previous vertex —
  the first from the origin — into two 28-bit fields. Everything
  unsigned, everything below 2⁶¹. An off-curve vertex bends the path
  through it; runs of them were resolved at generation time.

What `outlines.py` resolves so the OS-side parser has none of it: the
cmap (format 4 or 12, the `(3, 1)` subtable; every ASCII code point
must map or the generator refuses), the implied on-curve midpoints
(floored, inserted between consecutive off-curve vertices, each
contour rotated to start on an on-curve vertex), and composites
(components arrive with their translation applied; a scale or a
point-index anchor is refused by name — neither pinned face uses one).

The advance cross-check runs in both generator modes: every strike's
95 advances scaled from font units must equal the grid's recorded
value, the exact rational round-half-up. FreeType's own hinting moves
an advance by a pixel now and then (`5` at 16px, `T` at 24px on the
current Inter); a one-pixel difference is reported and allowed, two or
more refuse — a misaligned cmap or hmtx walk misses by wide margins,
not by one.

## The rasterizer (A17.3)

The normative algorithm, implemented first as `glyphs/reference.py`
(stdlib only, reviewable like the grid was) and then ported to Emo in
`raster.emo` to match it byte for byte:

- **Coordinates.** A vertex at font units `fu` and strike size `px`
  lands at 26.6 fixed point by `v26 = (2·fu·px·64 + upem) / (2·upem)`,
  floored — the exact rational rounded half up, integer throughout.
  The strike's y runs downward from the line box's top; the face's
  y-up outlines flip by `y26' = ascent_px·64 − y26`.
- **Metrics.** `ascent_px` and `descent_px` scale by ceiling:
  `ceil(fu·px / upem)` — the one rounding FreeType does that the grid
  confirms (Inter 16: 1984·16/2048 = 15.5 → 16; 24: 23.25 → 24; every
  ascent, descent and `.notdef` advance of the three grid strikes
  reproduces exactly).
- **Flattening.** A quadratic flattens by de Casteljau midpoint
  splits, `floor((a+b)/2)` per midpoint, while its second difference
  `|p0 − 2c + p1|` exceeds 64 (one pixel in 26.6) in either component
  — the curve's worst deviation from its chord is a quarter of that
  difference, so every segment stays within a quarter pixel of the
  true curve. The recursion terminates by halving, and the segments
  land in a growable edge list — no depth cap, no overflow to refuse.
- **Area accumulation.** Each segment's y span is split at the row
  boundaries, x interpolated with a truncating division — the one
  place dust enters, at most one subpixel unit a crossing,
  deterministic everywhere. A row piece from `(xa, ya)` to `(xb, yb)`
  contributes to column `c` the signed integral of the clamped
  abscissa, `∫ clamp(x(y) − 64c, 0, 64) dy`, and with the clamp's
  antiderivative — 0 below the pixel, `v²/2` inside it, `64v − 2048`
  above (doubled, so every cell stays an exact integer) — every
  column the piece's x-range touches answers in one closed form,
  `H·(G2(xb − 64c) − G2(xa − 64c)) / D` with `D = xb − xa`, truncated:
  no column splitting, no interpolation, the antiderivative
  difference always sharing `D`'s sign so the quotient never meets a
  negative numerator over a positive divisor or the reverse. Columns
  left of the piece's x-range take the full strip `64·H`, columns
  right take nothing — the closed form hands both out by itself, and
  a vertical piece is its own column's rectangle,
  `2·clamp(x − 64c, 0, 64)·H` doubled. The sweep runs right to left
  with a running suffix of the pieces' strip records, the pixel's
  doubled area is `cells[c] + 128·cover_suffix[c]`, and its coverage
  is `min(255, (|A2| + 16) >> 5)` — round half up of `A2/32`, the
  same rounding the metrics ride.
- **Ink placement.** `left = min_x26 >> 6`, `top = min_y26' >> 6`
  (arithmetic shifts, floor at any sign), `w` and `h` the span through
  `(max − 1) >> 6` — the same pen/line-box semantics the grid's
  `left` and `top` carry today; a glyph without edges is an empty box
  with its advance alone. An ink wider or taller than the strike's
  `max_dim` refuses, as does the strike before it allocates, when an
  advance will not fit its meta byte.
- **Order does not matter.** The cells accumulate truncated integers
  piece by piece; flattening order, edge order, none of it moves a
  byte.

The audit against FreeType (Pillow, through `rasterize.py`'s machinery)
is a development report — box-aligned per-pixel deltas and ink masses,
run once at A17.3: the shapes agree, the deltas are hinting's (the
grid's pixels are grid-fitted, the reference is not; ink boxes move by
a pixel and stems read a level or two heavier), not the algorithm's.
The gate is the reference's own bytes — 288 raster lines in the type
golden, each the advance, the ink box and a rolling digest
(`h·31 + b mod 1000000007`) over the ink's coverage bytes — recomputed
by `reference.py --check` in the gate and byte-identical to the Emo
strike on the three hosted targets. The digest folds bytes, not slot
words: a word packs eight coverage bytes and reaches 2⁶⁴ − 1, past
Int64's positive range, while the bytes stay 0..255 everywhere.

## The Strike (A17.2)

One `Strike` per (face, pixel size), dense over the ASCII table — no
hash, no eviction; the slot a glyph lands in is its alphabet position.
The strike's constructor answers the error convention — `(R.ok, the
strike)` or `(R.error, why)` — because the raise is not the metal's:
the riscv64 target does not lower it, and the compiler pulls every
module of a package into its builds, so `raster.emo` lowers with the
metal's images and refuses the way the gate's own syscall answers do
(its constructors keep to seven parameters for the same traveler —
the metal refuses a wider one).

- `max_dim` defaults to the line box rounded up to 8; a glyph whose
  ink exceeds it refuses (the generator asserts the same bound
  statically for its own tables). Slots are `ceil(max_dim² / 8)` words
  each, coverage bytes packed eight to a word; at 16px a strike is
  96 × 72 words ≈ 54 KiB, at 24px ≈ 96 KiB, all allocated at
  construction — a Strike is a boot-time constant of its app, in the
  winbuf mold, and costs nothing per frame after.
- A strike rasterizes eagerly, at construction — the design's "first
  use rasterizes" amended when A17.2 met the language: arrays are
  immutable values and the mutable containers (Box, List, Map) hold no
  indexed word storage a blit could read at `font.emo`'s shape, so the
  strike rasterizes all ninety-six glyphs into a plain `Array[Int64]`
  its init stores. Boot-time work either way; the blit reads the same
  words every frame, and nothing allocates per frame after.
- The meta each glyph exposes is two words: base and advance; left,
  top, width, height. The blit needs nothing else.

Editor loads both faces; each face parses once per app (a few thousand
words), strikes warm lazily.

## The seam (A17.4)

```emo
def ink(x Int64, y Int64, f Strike, glyph Int64, color Int64) Void
def text(f Strike, label String, x Int64, y Int64, ink Int64, s Surface)
def text_width(f Strike, label String) Int64
```

The verb's shape is what it has been since A8.1 — one interface call
per glyph, the metal boxing nothing per pixel. A backend fetches the
two meta words and the coverage words once and loops locally. The
first-day spike is `Array[Int64]` crossing module lines on riscv64
(the winbuf's byte tables argue it passes); if the return position
refuses, the words ride the verb instead, and the signature grows fat
within the eight-argument ceiling — decided by evidence, not guessed.

`raster.emo` joins the `emo/ui_fb` package as the parser, the Strike
and the rasterizer's home; the face modules feed it. Migration swaps
every caller to a named strike — the header and dock at their header
size, the editor's cells at the mono face — and the goldens regenerate
once, locks included (the M16 lesson: a package's sources moved means
its consumers' locks move).

## The ladder

| # | content | verification |
|---|---------|--------------|
| A17.1 | `glyphs/outlines.py`: pinned faces → resolved outlines → `face_inter.emo`, `face_mono.emo`; gate drift check | generator's cross-check against the grid; the package type-checks |
| A17.2 | the parser and the Strike in `raster.emo`: faces read, metrics scaled by the pinned formulas, slots allocated | hosted goldens: parse-level facts, metrics reproducing the grid's three strikes |
| A17.3 | `glyphs/reference.py` then the Emo port: flatten, area accumulation, sweep | the 288 raster pins byte-identical to the reference on the three hosted targets, the two bytecode refusals pinned; FreeType audit report |
| A17.4 | the seam migrates; the pixel pipeline retires; metal bring-up | run.sh ×3 dual transport byte-identical, dune full, @fmt, fb gate, locks regenerated |

## Non-goals, with their triggers

- **Hinting** — the faces render unhinted, as the grid's pixels did
  (Pillow's masks carry no grid-fitting either). Reopens below 14px,
  where hinting is the difference between a letter and a smudge.
- **Kerning pairs and fractional advances** — the pen moves in whole
  pixels, as it does today. Reopens when a visible pair or a large
  size makes the spacing uneven.
- **Subpixel-positioned glyphs** — the cache is keyed per glyph, not
  per phase. Reopens with fractional advances, never alone.
- **CJK** — the format carries any subset; a CJK face is a bigger file
  and a dense-slot question, decided when the desktop needs the text.
- **Weight faces** — Inter Regular and JBM Regular only. A Semibold
  face file is a drop-in when the chrome wants the contrast.
- **Float arithmetic** — none, by decision, not by omission: the
  byte-identical targets rest on integers, and nothing here needs
  more than they give.
