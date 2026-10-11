# Emo and visualization — an assessment and a design direction

Written 2026-10-12. This is a technical feasibility assessment and a
design direction; project-state claims reflect the repository as of
the date above (`develop` at `v0.28.1`). The direction was settled in
discussion on 2026-10-12 (see "Decisions recorded" at the end) but
stays a `docs/` design note until the work is scoped into a plan step;
it enters `README.md` only when it becomes decided design.

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
| **T3** | Interactive/GUI charts, 3D, animation | out of scope now; a native GUI canvas is a separate direction (see below), not part of this effort |
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
  browser, and the `wasm` and `typescript` targets can inject it into
  the DOM. A native GUI canvas, if one is ever built, would be a
  second consumer of the same scene description — a separate
  direction, not part of this effort (see Layer 5).
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
   Style options are carried by per-mark style values with `with_*` copy
   methods instead (see "The API in Emo") — a real design problem rather
   than a footnote.
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
same interface. `Renderer` is a plotting-side abstraction, not an Emo
target: Emo's targets are `ocaml`/`c`/`typescript`/`wasm`/`beam`/
`riscv64`, while EmoUI is a library over them whose platform backends
are OS toolkits (AppKit, GTK 4). EmoUI's current contract places
widgets and has no drawing verb, so it is not a plotting backend
today (see Layer 5). This split is Matplotlib's Artist/Renderer.

### Layer 1 — geometry, scales, ticks

`Point`/`Rect` as plain tuples or small classes; linear, log, band,
and time scales; colormaps; and the "nice numbers" tick locator and
formatter (Heckbert's `nicenum`, ~30 lines, and the reason a chart's
axes look professional rather than algorithmic). All of it is
arithmetic the language already supports — except that log and time
scales want the math layer from gap 1.

### Layer 2 — figure and axes

The object model is a value graph: a `Figure` holds one or more
`Axes`, each with its scales, mark list, legend, and labels.
Constructing a figure is an ordinary call returning an ordinary value,
and rendering is one further call.

```
const chart = plot.figure(
  title: "Monthly sales",
  axes: plot.axes(x_label: "Month", y_label: "Sales", marks: [...])
)
plot.save(chart, "chart.svg")
```

Deliberately **no pyplot-style global state**: Emo's principle of
least surprise argues against a hidden current figure and current
axes, which are Matplotlib's most-criticized design decision. The
surface is declarative (decision 2026-10-12): a chart is a value, not
a sequence of mutations against a live canvas.

### Layer 3 — the Matplotlib-like surface

Marks are values: `plot.line(x, y)`, `plot.scatter(x, y)`,
`plot.bars(labels, values)`, `plot.area(x, y)`,
`plot.hist(values, bins)`. Each returns a mark carrying its data and a
default style, and `axes(marks: [...])` collects them through a
structural `Mark` interface. The full surface, and the one real design
problem — how style is carried without default parameters — is worked
out under "The API in Emo" below.

### Layer 4 — the Seaborn-like surface (`plot_stats`)

A dataset-oriented API over the same engine, in its own package —
`plot_stats` (decision 2026-10-12). Seaborn's insight is that a plot
is a *mapping* from data columns to aesthetics, plus a statistical
transformation, plus a mark, faceted by one or more grouping columns.
Emo expresses that with a `Table` and the same figure and mark values:

```
const tips = plot.table(["total_bill", "tip", "time"], rows)
plot_stats.relational(tips, x: "total_bill", y: "tip", hue: "time")
plot_stats.distributions(tips, x: "tip", hue: "smoker")
plot_stats.categorical(tips, x: "day", y: "total_bill", kind: "box")
plot_stats.matrix(correlation)
```

The statistics sublayer underneath: `describe`, `quantile`,
`histogram_bins`, `kde`, `ecdf`, `ols` plus a confidence band,
`box_stats`, and a deterministic PRNG. All pure arithmetic; the KDE
and the normal quantile use the `math` package (decision 2026-10-12).

The **minimal table** (decision 2026-10-12) is the one new data
structure this layer needs — Emo has no data-frame. `Table` holds
numeric columns (`Array[Float64]`) and categorical columns (an integer
code per row plus the level names), so `x:`/`y:` read numeric columns
while `hue:`/`style:`/`facet:` read categorical ones; construction
validates equal row counts and unique names, and a malformed table is
an `(R.error, reason)` value. It lives in `plot` so both front doors
accept it, and it must not grow into pandas.

### Layer 5 — other backends and interaction

Terminal output and PNG are further `Renderer` implementations.
Interactive/GUI charts are **out of scope for now** (decision
2026-10-12): EmoUI is not an Emo target, and its current contract
(`ui_window_make`/`ui_label_make`/`ui_place`/…) places widgets and has
no drawing verb, so drawing into EmoUI would be a new EmoUI
capability, not a plotting backend. If interactivity is ever pursued,
it is a **separate direction in EmoUI**: one shared vector-canvas
contract that both EmoUI's canvas widget and this library's
`Renderer` implement (decision 2026-10-12). It must not shape the
static API now.

## The API in Emo

No new syntax is required, which is itself a strong sign the design
fits. The surface is declarative (decision 2026-10-12): a chart is a
value — a `Figure` holding `Axes`, each holding marks — and one call
renders it. Nothing mutates a hidden current figure.

```emo
const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug"]
const sales = [12.0, 18.0, 15.0, 24.0, 21.0, 30.0, 27.0, 35.0]

const chart = plot.figure(
  title: "Monthly sales",
  axes: plot.axes(
    x_label: "Month",
    y_label: "Sales",
    marks: [plot.line(months, sales), plot.scatter(months, sales)]
  )
)

plot.save(chart, "chart.svg")
```

`marks` is `Array[Mark]`, where `Mark` is a structural interface, so
`Line` and `Scatter` — different classes — sit in one array with no
inheritance:

```emo
interface Mark {
  def draw(ctx DrawContext) Void
}
```

A block-as-children attached block (the shape EmoUI also uses, but
only as a syntax analogy — no dependency) is a possible second
spelling; the array argument is the primary form: it is explicit,
order-visible, and needs nothing new.

### Style is the one real design problem

Emo has **no default parameters** — `def f(a Int64, b Int64)` called as
`f(1)` is E4009 — so "optional" styling cannot ride the function
signature. Every option is either required at the call site or carried
by a value the caller builds. The design below needs no language
change; the alternative, default parameters, is weighed after it.

**Marks are values with the default style baked in.** A mark factory
takes only the data and returns an already-styled mark:

```emo
def line(x Array[Float64], y Array[Float64]) Line {
  return Line.new(x: x, y: y, style: line_style())
}
```

**Each mark family has its own style class**, so a style can never
carry a field its mark ignores — strictness, no silently-ignored
options — and each class exposes one `with_*` copy method per option:

```emo
class LineStyle {
  def init(color String, width Float64, dash Dash, marker Marker, opacity Float64, label String) {
    self.color = color
    self.width = width
    self.dash = dash
    self.marker = marker
    self.opacity = opacity
    self.label = label
  }

  def with_color(c String) LineStyle {
    return LineStyle.new(color: c, width: self.width, dash: self.dash,
      marker: self.marker, opacity: self.opacity, label: self.label)
  }

  def with_width(w Float64) LineStyle {
    return LineStyle.new(color: self.color, width: w, dash: self.dash,
      marker: self.marker, opacity: self.opacity, label: self.label)
  }

  // … one per option …
}

def line_style() LineStyle {
  return LineStyle.new(color: "#2f6fb3", width: 1.5, dash: Dash.solid,
    marker: Marker.none, opacity: 1.0, label: "")
}
```

**The mark carries a style and offers `with_style`**, plus thin
`with_*` pass-throughs for the common one-option case:

```emo
class Line {
  def init(x Array[Float64], y Array[Float64], style LineStyle) {
    self.x = x
    self.y = y
    self.style = style
  }

  def with_style(s LineStyle) Line {
    return Line.new(x: self.x, y: self.y, style: s)
  }

  def with_color(c String) Line {
    return self.with_style(self.style.with_color(c))
  }
}
```

Call sites stay ordinary Emo:

```emo
plot.line(months, sales)                                          // default
plot.line(months, sales).with_color("#c0392b")                    // one option
plot.line(months, sales).with_style(
  plot.line_style().with_color("#c0392b").with_width(2.5))        // several
```

The boilerplate is mechanical and lives in the package once. The cost
is honest: `N` options means `N` copy methods per style class (and `N`
pass-throughs per mark if we want them), and with no generics there is
no way to factor that away.

**The alternative is default parameters.**

```emo
def line(x Array[Float64], y Array[Float64],
         color String = "#2f6fb3", width Float64 = 1.5,
         dash Dash = Dash.solid, marker Marker = Marker.none,
         opacity Float64 = 1.0, label String = "") Void { ... }

plot.line(months, sales)                                 // defaults
plot.line(months, sales, color: "#c0392b", width: 2.5)   // overrides
```

This removes the style classes, the `with_*` boilerplate, and the
`plot.line_style()` factory entirely, and gives the cleanest call
sites. It is a language feature, not a library one: it must be
strictly checked (a default may not reference a later parameter;
overriding by name stays unambiguous; a missing *non-defaulted*
parameter stays E4009), and it needs its own design pass and a second
consumer. The recommendation is to **build the library on the
`with_*` design first** — no language change, bounded boilerplate —
and let the friction from real charts decide whether parameter
defaults have earned their place. If they are added, the public
surface loses the style factories without disturbing the declarative
model.

| | `with_*` style values (no language change) | default parameters (language change) |
|---|---|---|
| call site | `plot.line(x, y).with_color("#c00")` | `plot.line(x, y, color: "#c00")` |
| package boilerplate | `N` copy methods per style class | none |
| checking | compile-time, every option typed | compile-time, every option typed |
| new language surface | none | parameter defaults, plus their rules |
| available today | yes | after the feature lands |

### The rest of the contract

- **Both front doors share one engine.** The positional surface
  (`plot.line(x, y)`) and the dataset surface
  (`plot_stats.relational(table, x: "col")`) are two ways into the
  same `Figure`/`Axes`/`Mark` values, not two implementations.
- **Expected failures are values.** Following the standard-library
  convention, a save that cannot open its path, a `Table` missing a
  named column, and a histogram with no values return
  `(R.ok, value)` / `(R.error, reason)`; only a genuine contract
  violation raises. This is the in-flight error-handling convention
  (`CHECK.md`, M12), and the plot packages must be written against it
  from day one.
- **The default style is a value, not global state.** A theme or
  palette is an ordinary value passed to `figure`, so two figures can
  carry different themes in one program.

## Naming and packaging

The standard library owns the top-level short names, and package names
are lowercase words (`json`, `yaml`, `http`, `base64`). The decision
(2026-10-12) is a **two-package split**:

- **`plot`** — the core: the `Renderer` interface and the SVG
  renderer, scales and ticks, the declarative `Figure`/`Axes`/`Mark`
  values, the per-mark style classes, and the `Table`.
- **`plot_stats`** — the Seaborn-like statistical layer on top:
  descriptives and distributions, the categorical, relational, and
  matrix families, regression, faceting, and themes and palettes.

Both declare **all five hosted targets** (`ocaml`, `c`, `typescript`,
`wasm`, `beam`; the freestanding `riscv64` target is out of scope — it
refuses `Map`), exactly as the format packages do.

## Sequencing

Dependencies are real, so the order is not arbitrary. The 2026-10-12
decisions fix the shape: SVG first, a standalone `math` package, then
the two plot packages.

- **A. Numeric substrate first.** Close gap 2 (float method dispatch
  on `c`/`wasm`/`beam`), and land a new standard-library **`math`
  package** — pure Emo, all five targets: `log`, `log10`, `exp`,
  `pow`, `sin`/`cos`/`tan`/`atan2`, `hypot`, and `normal_quantile`.
  Its optional native fast path rides `foreign def` on `c`/`ocaml`,
  opt-in and documented as target-pinned (decision 2026-10-12). The
  dispatch fix and `math` both gate everything above them.
- **B. `plot` T0 core — SVG only.** `Buffer`, scales, ticks, the
  per-mark style classes, the `Renderer` interface, `SvgRenderer`,
  the declarative `figure`/`axes`/mark values, `Table`, and
  line/scatter/bar/area/hist with axes, legend, and title. Exit:
  `examples/plot_demo` emits a corpus of SVGs byte-identical across
  the five targets — the standard library's golden standard.
- **C. `plot_stats` T1.** Descriptives, binning, KDE, ECDF, box
  statistics, OLS with a confidence band, the categorical,
  distribution, relational, and matrix families, faceting, palettes,
  and themes — all built on `plot`.
- **D. Terminal renderer.** The cheap second `Renderer`; makes plots
  visible in CI and the CLI, and tests that Layer 0 is genuinely
  format-agnostic.
- **E. PNG.** Pure-Emo zlib (stored, then fixed-Huffman, DEFLATE
  blocks), CRC32 and Adler-32, and a scanline polygon/line rasterizer
  with supersampling, using the Hershey stroke font for text.
- **Out of scope (decision 2026-10-12).** Interactive/GUI charts and
  an EmoUI canvas. EmoUI is not an Emo target and has no drawing verb
  today, so this is a separate EmoUI direction (a shared vector-canvas
  contract), not a plotting step. 3D and animation are likewise out.

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
3. **Float math goes in a standard-library `math` package** (decision
   2026-10-12): pure Emo, all five targets, with an opt-in
   `foreign def` fast path on `c`/`ocaml` whose output is documented
   as target-pinned. Not in the core, and not package-private. The
   `CHECK.md` entry already records that the current primitives are
   partial across targets, so this is a known-open area rather than a
   surprise.
4. **Default parameters** — build the library on the `with_*` style
   design first (see "The API in Emo"), which needs no language
   change; let real chart code decide whether parameter defaults earn
   their place, with a second consumer.
5. **No new syntax.** A plotting library should be expressible in the
   language as it stands; if it needs a construct, that is evidence
   the construct is wrong, not the library.

## Risks and honest caveats

- **Performance.** SVG generation under the interpreter handles
  thousands of points comfortably but not millions; the `c` target is
  where dense scatter and rasterization belong. Specialization matters
  — the benchmark suite exists to measure it.
- **Determinism versus native math.** *Accepted (2026-10-12):* the
  `math` package is pure Emo and byte-identical by default; its native
  `foreign def` fast path is opt-in and its output is documented as
  target-pinned, so the default path preserves the byte-identical
  golden convention.
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
  and spec-first orientation, and SVG-first output. *Adopted
  (2026-10-12):* Emo's surface is declarative — a `Figure` value
  rendered in one call — rather than an `Axes` object mutated in
  place.
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

The defensible first product, now settled as a direction: **two
packages — `plot` (pure Emo, SVG-first, declarative, a `Renderer`
interface, checked byte-identical goldens, T0) and `plot_stats` (the
Seaborn-like T1 layer on top) — preceded by numeric dispatch parity
and a standard-library `math` package.** No language change is
required. Any native GUI canvas is a separate, later EmoUI direction
and must not gate this work. "Full Matplotlib and Seaborn parity" is
struck from the goal statement and replaced with the declared tier
T0 + T1.

## Decisions recorded (2026-10-12)

1. **Output order — SVG first.** `plot` ships only `SvgRenderer`;
   terminal and PNG are later `Renderer` implementations.
2. **Style API — per-mark style classes with `with_*` copy methods**,
   carried by mark values, no language change. Default parameters are
   deferred; the detailed comparison is under "The API in Emo".
3. **Surface — declarative.** A chart is a `Figure`/`Axes`/`Mark`
   value graph rendered in one call.
4. **Data — a minimal `Table`** (numeric and categorical columns),
   with no ambitions beyond carrying rows.
5. **Packages — `plot` + `plot_stats`**, both declaring the five
   hosted targets.
6. **Math — a standard-library `math` package**, pure Emo and
   byte-identical by default.
7. **Determinism — an opt-in native fast math path is accepted**,
   documented as target-pinned.
8. **Process — this `docs/` note first**, then a
   `plan/step-NN-*.md` step once the numeric-substrate work is
   scoped; `README.md` waits for decided design.
9. **EmoUI — out of scope now.** EmoUI is not an Emo target: it is a
   library over Emo's native targets whose platform backends are OS
   toolkits, and its current contract places widgets and has no
   drawing verb. Interactive/GUI charts are therefore excluded from
   this effort. If a canvas is ever built, the shared vector-canvas
   contract is an **independent EmoUI direction**, accepted
   2026-10-12 — not a plotting backend.

## Remaining open questions

1. **Stats package name.** Is `plot_stats` the right second name, or
   a single word (`stats`) or another form?
2. **`Table`'s home.** `plot` (recommended, so both front doors
   accept it) or `plot_stats`?
3. **Mark pass-throughs.** Does every mark repeat `with_color` etc.,
   or is `with_style` alone enough?
4. **Terminal versus PNG order**, and whether PNG is worth building
   before a consumer actually needs it.
5. **The `math` surface.** The exact function list, the default
   rounding behavior, and the opt-in fast path's spelling.
6. **A block spelling.** Should the declarative tree also accept a
   block-as-children attached block, or stay array-only?
7. **Where the work starts.** Which is step one: the dispatch parity
   fix, the `math` package, or the `plot` skeleton?
