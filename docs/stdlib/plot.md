# The `plot` Package

The declarative 2D charting package. A figure is a value — a `Figure`
holding `Axes`, each holding marks — and one call renders it to SVG.
Everything is pure Emo over the shared runtimes, so all five hosted
targets answer byte-for-byte.

## Using the package

```emo
require "plot"
```

The standard library ships with the compiler: `require "plot"` needs no
`package.emo` entry.

The package carries two public modules: `plot` (the figure surface) and
`mark` (the marks). One `require "plot"` brings both into scope.

## The surface

```emo
def figure() Figure
def axes() Axes
def svg(fig Figure) String

// Figure
def with_title(t String) Figure
def with_size(w Float64, h Float64) Figure
def with_axes(a Array[Axes]) Figure
def with_share(s Share) Figure

// Axes
def with_x_label(s String) Axes
def with_y_label(s String) Axes
def with_marks(m Array[Mark]) Axes
def with_legend(on Bool) Axes
```

`figure()` and `axes()` build the defaults, and `with_*` refines a value.
Classes are immutable, so every `with_*` answers a new value; the whole
figure is a plain value graph. `svg(fig)` walks it and returns the SVG
document as a `String`.

```emo
enum Scale { linear, log }
enum Domain { auto, fixed }
enum Share { all, none }
```

## Marks

The marks live in the `plot.mark` submodule — a package's submodules are
addressed under its short name. T0 ships the bar mark:

```emo
def bar(labels Array[String], values Array[Float64]) Bar
def bar_style() BarStyle
```

A mark is a value too. `Bar.with_style(s BarStyle)` and the style's
`with_color` / `with_width` / `with_label` refine it without mutating
anything:

```emo
plot.mark.bar(months, sales).with_style(
  plot.mark.bar_style().with_color((192, 57, 43)).with_width(0.6))
```

**Colors are `(Int64, Int64, Int64)` sRGB triples**, each channel 0–255.
Opacity is a separate `Float64` on the style, never baked into the
triple.

A mark draws itself into an axes through the `Mark` interface — `draw`,
`y_max`, `bands`, `x_labels` — so a new mark family is a new class that
satisfies that shape.

## A worked example

```emo
require "plot"

const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun"]
const sales = [12.0, 18.0, 15.0, 24.0, 21.0, 30.0]

const ax = plot.axes()
  .with_x_label("Month")
  .with_y_label("Sales")
  .with_marks([plot.mark.bar(months, sales)])
const chart = plot.figure().with_title("Monthly sales").with_axes([ax])

println(plot.svg(chart))
```

`examples/plot_demo` is this program.

## Output

`svg` hands back the document; writing it to a file is the caller's step.
The package runs on all five targets, while file IO belongs to the
native-only `file` and `os` packages — on a native target,
`file.write("chart.svg", plot.svg(chart))`.

Text is delegated to the viewer: every label is an SVG `<text>` element,
so the package carries no font engine. Coordinates and values are
formatted with the interpreter's float rendering, which is why the bytes
are identical on every target.

## Targets and what is landed

Targets: all five (`ocaml`, `c`, `typescript`, `wasm`, `beam`).

T0 — what exists today — is the bar mark, linear axes with nice-number
ticks, a title, axis labels, and SVG output. The remaining pieces the
surface carries are reserved and not rendered yet: `Scale.log`,
`Domain`, faceting via `Share`, legends, and the other mark families
(line, scatter, area, histogram). The SVG renderer sits behind an
internal `Renderer` contract, so a terminal or raster backend can join
later without disturbing the figure or the marks.

See also: `examples/plot_demo`, and the design note
[`docs/visualization.md`](../visualization.md).
