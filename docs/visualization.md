# Emo and visualization — an assessment and a design direction

Written 2026-10-12. This is a technical feasibility assessment and a
proposed direction, not decided design; project-state claims reflect
the repository as of the date above (`develop` at `v0.28.1`). Nothing
here enters `README.md` until it is settled in `CHECK.md`.

The question: what would it take to give Emo plotting and
statistical-graphics capability comparable to Python's **Matplotlib**
and **Seaborn**?

The evidence base is a working spike
([`spike/plot-svg`](../spike/plot-svg/README.md)): a real 2D chart —
nice-number ticks, a plot frame, gridlines, axis labels, a line series
with markers — rendered as SVG by a pure-Emo program with no FFI. The
spike also served as a probe of the target matrix, and its failures
are as informative as its successes.

## The conclusion

**Feasible, in tiers — and the renderer is the easy part.** The hard
part is the numeric and portability substrate underneath: Emo's six
targets, an FFI confined to `c`/`ocaml`, and a core float surface that
stops at `sqrt`/`floor`/`ceil`/`trunc`. SVG as the output format
removes the single largest classical obstacle — font rendering —
because the viewer, not the library, owns text. What remains is
arithmetic, layout, and a fair amount of disciplined ordinary code.

| Tier | What it is | Order of effort |
|---|---|---|
| **T0** | 2D chart core — line, scatter, bar, area, histogram; axes, ticks, legend, title; SVG output | one person, weeks; the spike already proves the shape and the gaps are known |
| **T1** | Seaborn-grade statistics — distributions (hist/KDE/ECDF), categorical (box/violin/bar/count/strip), regression, matrix (heatmap/clustermap), faceting, palettes and themes | one person, 1–2 months; pure Emo on T0, arithmetic only |
| **T2** | Raster PNG — a pure-Emo zlib stream (stored blocks), CRC32, a stroke-font rasterizer with supersampling | 1–2 months for a readable, correct implementation; no FFI needed |
| **T3** | Interactive/GUI charts (EmoUI canvas), 3D, animation | gated: needs a canvas verb contract, first-class callbacks, and reclamation (the emo-ui checklist) |
| **out** | PDF/PS/EPS, LaTeX text, complex-script shaping, an Agg/FreeType-class native backend | not worth chasing; a native-only tier would fragment the product for fidelity nobody asked for |

"Full Matplotlib + Seaborn parity" is not a decidable end state —
Matplotlib is a decade and a half and well over a hundred thousand
lines, seaborn layers on pandas, numpy, scipy, and statsmodels. The
first product decision, exactly as in the SQL assessment, is to
reduce "complete visualization" to a declared tier. T0 + T1 is the
tier worth declaring.

## Why SVG first

The choice of the SVG output format is load-bearing, not incidental.

- **Text becomes the viewer's job.** An SVG `<text>` element defers
  font lookup, shaping, hinting, and rasterization to whatever renders
  the file. Matplotlib must embed a font manager and dominate a build
  with FreeType precisely because it rasterizes text itself. Emo has
  no font engine and no FFI on four of six targets; deferring text
  sidesteps the whole problem at the drawing layer.
- **A text format is pure Emo.** The renderer needs `String` building
  and nothing else, so it is written in Emo over the shared runtimes —
  the standard library's "pure Emo where the language suffices"
  convention — and its output can be held byte-for-byte across every
  target that honors the numeric surface.
- **Vector is the scientific-figure use case.** Crisp at any zoom,
  editable, diffable, and small on disk.
- **It composes with what already exists.** SVG drops into HTML for a
  browser; the `wasm` and `typescript` targets can inject it into the
  DOM; and a future EmoUI canvas is simply a second consumer of the
  same scene description.
- **There is a proven ancestor.** gnuplot outputs SVG (and PNG, and
  terminals) from one core with public-domain Hershey stroke fonts and
  no font engine — the closest architectural precedent to what Emo
  wants, and independent evidence that the shape works.

## What Emo has, and what a plot package must build

The spike pinned the capability audit down to concrete items.

**Already present, and enough for the drawing layer:** `Float64`
(IEEE 754) and `Int64` (wrap-around), `String` with interpolation and
`printf`, immutable `Array` with `append`, `Map`, `List` (a deque with
`push_back`/`pop_back`), `Box`, `Bytes` with byte and little-endian
accessors, tuples, enums, classes, structural interfaces, function
groups, attached blocks, `for`/`while`, and packages that declare
their targets.

**The gaps, each with its cost:**

1. **The transcendental surface is missing.** The core stops at
   `sqrt`, `floor`, `ceil`, `trunc`, `to_int64`, `to_float64`; there
   is no `sin`, `cos`, `atan2`, `exp`, `log`, `pow`. A statistical
   layer needs `exp`/`log` (KDE, log scales, regression intervals) and
   the normal quantile function (error bars, confidence bands). Two
   routes: a **pure-Emo math layer** (ordered operations, therefore
   deterministic, therefore byte-identical goldens — the standard
   library's route), or **core/FFI primitives** (fast, but parity work
   across six targets and a determinism question, see Risks).
2. **Numeric method dispatch is not at parity.** The spike's chart
   uses `to_float64`, `to_int64`, `floor`, `ceil`, `to_string` on
   numbers; `c`, `wasm`, and `beam` refuse them today
   (`to_float64 has no dispatch`, `does not support the type-level
   method fig_w.to_int64`). A package declaring five targets cannot
   ship until this closes.
3. **There is no growable buffer and no `join`.** `Bytes` is
   fixed-length (the `json` package computes an exact length, then
   fills), and `Array` is immutable with only `append`/`length`. SVG
   output wants a chunked `Buffer` (a `List` of `Bytes` chunks, or a
   two-pass exact-length fill) as the package's first utility.
4. **There is no `sort` / `map` / `filter` / `reverse`, and no
   generics.** Quantiles, box plots, tick ordering, and histogram
   binning all need a numeric sort. Inside a package this is a
   `sort_float64s` and an index sort — unwelcome but bounded, and
   honest: the language deliberately has no generic definition syntax.
5. **There are no font metrics.** SVG defers rendering but not
   *measurement*, and automatic layout (label collision, rotated
   ticks, legends) needs widths. Two answers: a small per-character
   advance table for a base font (approximate, zero dependencies), or
   a **Hershey stroke font** — public-domain, pure geometry, exactly
   measurable — which doubles as the text source for a raster backend.
6. **There are no default parameters.** Verified: `def f(a Int64, b Int64)`
   called as `f(1)` is E4009. Named arguments exist; defaults do not.
   Style options therefore need typed carriers or presets (see the API
   sketch), which is a real ergonomics question, not a footnote.
7. **Binding patterns are settled but not in this build.** `const (lo, hi) = f(x)`
   is recorded in `CHECK.md`; the `v0.28.1` interpreter still rejects
   it. The plot code can live without it (index the tuple), but it is
   the natural destructuring form for `(lo, hi, step)` carriers.

## The architecture

Six layers, each depending only on the ones below it. Only the first
ships in T0; the rest are the growth path, named now so the T0
interfaces do not close doors.

### Layer 0 — scene and renderer

A backend-agnostic display list plus a structural `Renderer`. Every
mark computes pixel-space geometry and emits primitives; nothing above
Layer 0 knows what the output format is.

```emo
interface Renderer {
  def begin(width Float64, height Float64) Void
  def move_to(x Float64, y Float64) Void
  def line_to(x Float64, y Float64) Void
  def curve_to(c1x Float64, c1y Float64, c2x Float64, c2y Float64, x Float64, y Float64) Void
  def rect(x Float64, y Float64, w Float64, h Float64) Void
  def close() Void
  def stroke(s Style) Void
  def fill(s Style) Void
  def text(x Float64, y Float64, body String, s Style) Void
  def finish() String
}
```

The `SvgRenderer` is the only shipped implementation in T0. A
terminal renderer (braille/block characters, in the spirit of
`UnicodePlot`) and a PNG rasterizer are later implementations of the
same interface; an EmoUI canvas is a third. This is Matplotlib's
Artist/Renderer split, and it mirrors the nine-verb `ui_*` contract
the GUI spikes already established.

### Layer 1 — geometry, scales, ticks

`Point`/`Rect` as plain tuples or small classes; linear, log, band,
and time scales; colormaps; and the "nice numbers" tick locator and
formatter (Heckbert's `nicenum`, ~30 lines, and the reason a chart's
axes look professional rather than algorithmic). All of it is
arithmetic the language already supports — except that log and time
scales want the math layer from gap 1.

### Layer 2 — figure and axes

An explicit object model: a `Figure` holds one or more `Axes`, each
with its scales, marks, styling, legend, and labels.

```
const fig = plot.figure(width: 800.0, height: 600.0, title: "Monthly sales")
const ax = fig.axes()
```

Deliberately **no pyplot-style global state**: Emo's principle of
least surprise argues against a hidden current figure and current
axes, which are Matplotlib's most-criticized design decision.
Constructing a figure is an ordinary call returning an ordinary value.

### Layer 3 — the Matplotlib-like surface

Marks as ordinary functions on an `Axes`: `ax.line(x, y)`,
`ax.scatter(x, y)`, `ax.bars(labels, values)`, `ax.area(x, y)`,
`ax.hist(values, bins)`. Composite conveniences (`plot.line(x, y)`
constructing its own figure) sit on top.

### Layer 4 — the Seaborn-like surface

A dataset-oriented API over the same engine. Seaborn's insight is
that a plot is a *mapping* from data columns to aesthetics, plus a
statistical transformation, plus a mark, faceted by one or more
grouping columns. Emo can express exactly that with `Map` and
`Array`:

```
plot.relational(data, x: "total_bill", y: "tip", hue: "time")
plot.distributions(data, x: "tip", hue: "smoker")
plot.categorical(data, x: "day", y: "total_bill", kind: "box")
plot.matrix(data)
```

The statistics sublayer underneath: `describe`, `quantile`,
`histogram_bins`, `kde`, `ecdf`, `ols` plus a confidence band,
`box_stats`, and a deterministic PRNG. All pure arithmetic; the KDE
and the normal quantile need the math layer.

A **minimal table type** is the one new data structure this layer
needs — Emo has no data-frame. A `Table` class holding
`Map[String, Array[Float64]]` plus column names, or a pair of
`Array[String]` names with `Array[Array[Float64]]` columns, is enough;
it must not grow into pandas.

### Layer 5 — other backends and interaction

Terminal output (T0's low-cost second renderer), PNG (T2), and an
EmoUI canvas (T3). Interactivity — hover, zoom, legend toggling —
belongs here and only here; it is gated on the emo-ui checklist
(callbacks across the FFI, reclamation, a canvas verb), and should not
shape the static API.

## The API in Emo

No new syntax is required, which is itself a strong sign the design
fits. Two things need a decision, and they are the interesting part.

**How marks carry style.** With no default parameters, a mark can
take all of its options explicitly, or take a typed `Style` value, or
return a chainable immutable mark. The choices, with their costs:

- *All parameters on the function* — fully explicit and strict, but
  every call names color, width, dash, marker, opacity, and label even
  when it wants none of them. Unusable.
- *A typed `Style` carrier* — `Style.new(...)` requires every field
  too, so the plot package ships named presets (`plot.default_style`,
  `plot.grid_style`) and per-mark constructors. Strict and typed, at
  the cost of ceremony.
- *A chainable mark* — `ax.line(x, y).color("#2f6fb3").width(2.5)`,
  where each method returns a new immutable mark copying the fields.
  Reads best and is ordinary code (no new construct), but every option
  needs a hand-written copy method.
- *Default parameters in the language* — the clean fix, and a genuine
  language ask. It earns its place only if a second, unrelated
  consumer wants it; a plotting library alone is not sufficient
  justification under the project's rules.

The recommendation is to start with the typed `Style` carrier plus
presets, keep the chainable form as a package-level ergonomic layer
if it proves worth the boilerplate, and revisit default parameters as
a language question only after real API friction is documented.

**Data in, marks out.** Both a positional surface (Matplotlib-like,
`ax.line(x, y)`) and a dataset surface (Seaborn-like,
`plot.relational(data, x: "col")`) belong on the same engine; they
are two front doors to Layer 3, not two implementations.

**Expected failures are values.** Following the standard library
convention, a save that cannot open its path, a `Table` missing a
named column, a histogram with no values return `(R.ok, value)` /
`(R.error, reason)`; only a genuine contract violation raises. This
is the in-flight error-handling convention (`CHECK.md`, M12) and the
plot package must be written against it from day one.

## Naming and packaging

The standard library owns the top-level short names, and package
names are single lowercase words (`json`, `yaml`, `http`, `base64`).
**`plot`** is the natural name — generic, English, and not a copy of
any single tool's surface. The Matplotlib-like and Seaborn-like
surfaces can live in one package (the seam is an internal module
boundary), or the statistical layer can be a second package. Starting
with one `plot` package that declares **all five hosted targets**
(`ocaml`, `c`, `typescript`, `wasm`, `beam`; the freestanding
`riscv64` target is out of scope — it refuses `Map`) is the
conservative choice, exactly as the format packages do.

## Sequencing

Dependencies are real, so the order is not arbitrary:

- **A. Numeric substrate first.** Close gap 2 (float method dispatch
  on `c`/`wasm`/`beam`) and land the pure-Emo math layer (`log10`,
  `exp`, `log`, `pow`, trig, the normal quantile). Without both, the
  package cannot declare five targets and the statistical layer cannot
  be built. This is the gating step.
- **B. T0 core.** `Buffer`, scales, ticks, `Style`, the `Renderer`
  interface, `SvgRenderer`, and line/scatter/bar/area/hist with axes,
  legend, and title. Exit: `examples/plot_demo` emits a corpus of SVGs
  that are byte-identical across the five targets — the standard
  library's golden standard.
- **C. T1 statistics.** `Table`, descriptives, binning, KDE, ECDF,
  box statistics, OLS with a confidence band, the categorical and
  matrix families, faceting, palettes, and themes.
- **D. Terminal renderer.** The cheap second backend; makes plots
  visible in CI and in the CLI. Also the honest test that Layer 0 is
  genuinely format-agnostic.
- **E. PNG.** Pure-Emo zlib (stored, then fixed-Huffman, DEFLATE
  blocks), CRC32 and Adler-32, and a scanline polygon/line rasterizer
  with supersampling, using the Hershey stroke font for text.
- **F. EmoUI canvas.** Interactive charts, gated on the emo-ui
  checklist; out of scope until that package exists.

Each step ends with the repo building green, as every step does.

## Language and compiler asks

Made explicit so they can be decided deliberately rather than
discovered mid-implementation:

1. **Numeric method-dispatch parity (`c`, `wasm`, `beam`)** — a
   blocker, not a nicety. Likely the same lowering the `ocaml` and
   `typescript` emitters already do.
2. **The `ocaml` specialization defect** the spike hit
   (`non-native expression in specialized body`, `Type_ref margin_t`).
   A bug report, not a design item; file it first.
3. **Float math** — prefer a pure-Emo layer in the package, promote
   to core only if a second consumer appears. The `CHECK.md` entry
   already records that the current primitives are partial across
   targets, so this is a known-open area rather than a surprise.
4. **Default parameters** — do **not** add pre-emptively. Document the
   friction; decide as a language question with a second consumer.
5. **No new syntax.** A plotting library should be expressible in the
   language as it stands; if it needs a construct, that is evidence
   the construct is wrong, not the library.

## Risks and honest caveats

- **Performance.** SVG generation under the interpreter handles
  thousands of points comfortably but not millions; the `c` target is
  where dense scatter and rasterization belong. Specialization matters
  — the benchmark suite exists to measure it.
- **Determinism versus native math.** If `sin`/`exp`/`log` ride a
  platform `libm` through `foreign def`, last-bit differences across
  machines and OSes can change SVG bytes and break the byte-identical
  golden convention. A pure-Emo, fixed-order math layer is the only
  way to guarantee identical output; the native path can exist as an
  opt-in fast path with output documented as target-pinned.
- **Text metrics.** Without a font engine, automatic layout is either
  approximate (advance table) or limited to the bundled stroke font.
  This is the same trade gnuplot made and it has been acceptable for
  decades, but it should be stated, not hidden.
- **Scope.** Matplotlib's surface is effectively unbounded
  (projections, date locales, 3D, animation, GUI event loops). The
  tier table is the defense: T0 + T1, declared, with everything else
  explicitly out.
- **No generics.** Each numeric type gets its own sort and reduction
  helpers inside the package. Bounded, but it is real duplication the
  language will not factor away.

## Prior art, and what to borrow

Per the project's design philosophy, mechanisms may be borrowed but no
single language's look may be copied.

- **Matplotlib** (Python) — the Artist model and the pluggable
  backends (Agg for raster, SVG/PDF for vector) are the mechanisms
  worth taking; the global pyplot state and the `Axes`/
  `Axis`/`Artist` naming hierarchy are not.
- **Seaborn** (Python) — the dataset-oriented mapping (data columns →
  aesthetics), statistical transformations, and themes and palettes.
  Its API is the model for Layer 4.
- **ggplot2 / Vega-Lite / Observable Plot** — the grammar-of-graphics
  and spec-first orientation, and SVG-first output. A declarative
  `Figure` value that renders in one call is a plausible Emo surface;
  it should be weighed against the imperative `Axes` surface rather
  than assumed.
- **gnuplot** (C) — terminal backends, Hershey fonts, multiple output
  formats from one core. The closest ancestor to the SVG + terminal +
  PNG plan, and proof that the plan is old and sound.
- **Elixir's `VegaLite` and `UnicodePlot`** — the BEAM lineage's two
  answers: emit a spec, or draw to a terminal. Both fit Emo's actor
  and text-first world.
- **Go's `gonum/plot`** — proof that a small, pure-language plotting
  library with a renderer interface and an SVG backend is a
  one-person undertaking. Borrow the mechanism; not the naming or the
  API shape.

## Recommendation

If the capability is wanted, the defensible first product is:
**a `plot` package, pure Emo, SVG-first, with a `Renderer` interface
and a checked byte-identical golden, covering T0 and then T1.** It
requires one gating prerequisite (numeric dispatch parity and a
pure-Emo math layer) and no language change. It can share the emo-ui
canvas later, but it must not wait for it. "Full Matplotlib and
Seaborn parity" should be struck from the goal statement and replaced
with the declared tier.

## Open questions for discussion

1. **Output format order.** SVG first is argued above; is a terminal
   renderer worth promoting ahead of PNG (cheaper, and it stress-tests
   Layer 0), and is PNG worth building at all before a consumer
   actually needs it?
2. **Style API.** Typed `Style` carriers plus presets, a chainable
   immutable mark, or a language-level default-parameter mechanism?
3. **Declarative versus imperative surface.** A `Figure` value
   rendered in one call, an `Axes` object mutated through marks, or
   both? Layer 4 can be declarative on top of an imperative Layer 3,
   but the seam should be chosen deliberately.
4. **Table type.** Does the dataset layer need a `Table` at all, or
   can it run on `Map[String, Array[Float64]]` and tuples? How much
   structure is worth introducing?
5. **Package split.** One `plot` package, or `plot` plus a statistical
   `seaborn`-analogue package? What is the second package named?
6. **Math layer home.** Package-internal, a public `math` package, or
   the core? (The recommendation is package-internal first.)
7. **Determinism policy.** Is an opt-in native fast math path with
   target-pinned output acceptable, or must every target's SVG be
   byte-identical, full stop?
8. **Where the work lives.** A new `plan/step-NN-*.md` step once the
   direction is settled, or a `docs/` design note first?
