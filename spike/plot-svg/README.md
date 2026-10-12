# Plot spike: a real 2D chart in pure Emo

This spike answers one question before any plotting library gets built:
**can a genuine 2D chart be produced by Emo's value types and string
building alone, with no FFI and no graphics runtime?** The answer is
yes — `main.emo` renders the month-vs-sales chart in `chart.png` as an
SVG document, from a program that is nothing but `Float64`, `Array`,
`String`, and loops.

The companion write-up — tiers, architecture, the target gaps this
spike surfaced, and the open design questions — is
[`docs/visualization.md`](../../docs/visualization.md).

## Run

```sh
emo run main.emo > chart.svg
rsvg-convert -w 760 -h 460 chart.svg -o chart.png   # any SVG viewer works
```

`chart.svg` is the checked-in output; `chart.png` is that SVG
rasterized by an external converter, included only so the result is
visible without a viewer.

## What the spike proves

- **The renderer is not the hard part.** Scales, nice-number ticks
  (Heckbert's `nicenum`), a plot frame, gridlines, axis labels, a
  polyline series and its markers all fall out of ordinary Emo code.
  The output is a normal, editable, resolution-independent SVG.
- **Text is free.** Every label is an SVG `<text>` element, so the
  viewer owns font lookup, shaping, and rasterization. The single
  biggest reason Matplotlib must ship FreeType — and the reason an
  Emo raster backend is a separate, later tier — disappears entirely
  at the SVG layer.
- **A pure-Emo math shim closes the first gap.** `log10` is not on
  the core float surface, so the tick algorithm counts powers of ten
  with two `while` loops. The same shape — a small, ordered, pure-Emo
  numeric layer — is what a statistical layer will need for `exp`,
  `log`, and the normal quantile function.

## What the spike found missing

The spike was also a probe of the target matrix. The same source on
the `develop` tree (`v0.28.1`):

| Target | Line chart | Axes + ticks chart |
|---|---|---|
| `emo run` (interpreter) | runs | runs |
| `ocaml` | runs, byte-identical to the interpreter | **fails**: `non-native expression in specialized body` (`Type_ref margin_t`) |
| `typescript` | builds | builds |
| `c` | **refuses**: "does not support method calls yet" | **refuses**: "does not support the type-level method `fig_w.to_int64`" |
| `wasm` | **refuses**: `to_float64` has no static dispatch | **refuses**: same |
| `beam` | **refuses**: `to_float64` has no dispatch | **refuses**: same |

Two conclusions follow, both recorded in the assessment:

1. **Float method-dispatch parity is a prerequisite.** A chart uses
   `to_float64`, `to_int64`, `floor`, `ceil` and `to_string` on
   numbers; three of the six backends cannot emit those today. A
   library that declares five targets — the standard-library
   convention — cannot exist until that gap closes.
2. **The `ocaml` failure is a bug, not a design limit.** The simpler
   chart builds and matches the interpreter byte-for-byte, so the
   richer one's specialization failure is an emitter defect worth a
   bug report before the library work starts.

Neither blocks the design; both pin the order of work.
