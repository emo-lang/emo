# The `plot` Package

The declarative 2D charting package. A figure is a value — a `Figure`
holding `Axes`, each holding marks — and one call renders it to SVG.
Everything is pure Emo over the shared runtimes, so the five hosted
targets the package declares answer byte-for-byte.

## Using the package

```emo
require "plot"
```

The standard library ships with the compiler, but its packages are
versioned like any other: `require "plot"` needs `"plot" = "0.1.0"` in
the manifest's `deps` block.

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
def with_theme(t Theme) Figure
def with_grid(rows Int64, cols Int64) Figure
def with_axes(a Array[Axes]) Figure
def with_share(s Share) Figure

// Axes
def with_x_label(s String) Axes
def with_y_label(s String) Axes
def with_x_scale(s Scale) Axes
def with_y_scale(s Scale) Axes
def with_x_domain(a Float64, b Float64) Axes
def with_y_domain(a Float64, b Float64) Axes
def with_marks(m Array[Mark]) Axes
def with_legend(on Bool) Axes

def grid_style() GridStyle
def rgb(r Int64, g Int64, b Int64) (Int64, Int64, Int64)
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

The scale enums reach an axes through `with_x_scale` / `with_y_scale`.
A log axis spans whole decades: the domain snaps to the enclosing
powers of ten, ticks sit on the 1-2-5 steps through each decade (the
2 and 5 steps join only while the span is two decades or less), and a
nonpositive value or domain raises — a log axis maps positive numbers
and nothing else.

A domain is `Domain.auto` — inferred from every mark's span, the
default — or `Domain.fixed` through `with_x_domain(a, b)` /
`with_y_domain(a, b)`, which carries the caller's ends verbatim: ticks
respect the fixed ends, and an inverted domain (`lo >= hi`) raises.
Marks are not clipped to the axes rectangle yet, so data outside a
fixed domain draws past it.

The grid draws behind the marks: horizontal lines at the y ticks and
vertical lines at the x ticks, styled by the theme's `GridStyle` —
`color`, `width`, `dash` (the same `Dash` enum the line mark strokes
with), and `visible` (`false` draws no grid at all). The default is a
light solid line at width 1.0, refined through `Theme.with_grid`.

## Missing numbers

A missing number is a presence tag, not `NaN` — the beam target's
Erlang floats cannot carry one. A numeric column keeps its slot in the
values array, and a parallel presence array names the empty slots:

```emo
enum Presence { present, absent }
```

The statistics read a column beside its presence array and skip the
`absent` entries, so one missing value costs an observation, not the
whole column. The parallel presence column rides the `Table` the
dataset layer builds (`plot.table` / `plot.table_missing`).

## Tables

The dataset charts read a `Table` — the one data structure the package
owns: column-oriented, minimal, and built only through its two
validating builders.

```emo
def table(numbers Map[String, Array[Float64]], labels Map[String, Array[String]]) Table
def table_missing(numbers Map[String, Array[Float64]], presence Map[String, Array[Presence]], labels Map[String, Array[String]]) Table
```

Numeric columns and categorical columns live in maps keyed by column
name, and every column shares one row count. `table` builds the
all-present table — each numeric column gets its presence array built
beside it; `table_missing` takes the presence columns the caller
wrote. Both validate the shape and raise on a violation, because a
table written as a literal is programmer intent: two columns of
different lengths, one name claimed by both kinds, a numeric column
with no presence column — or a stray presence column, or one whose
length disagrees with its numbers — are all contract violations.

Access goes through the column's kind:

```emo
const tips = plot.table(
  { "total_bill": [16.99, 10.34, 21.01], "tip": [1.01, 1.66, 3.50] },
  { "time": ["Lunch", "Dinner", "Dinner"] }
)
tips.rows
tips.number("total_bill")
tips.presence("total_bill")
tips.label("time")
```

`number(name)` answers a numeric column's values, `presence(name)` the
parallel presence array beside it, and `label(name)` a categorical
column's values; `rows` is the row count. Reading a name the table
carries under the other kind, or a name it does not carry, raises. An
empty pair of maps is a table of zero rows.

`Table` lives at the `plot` root, and it must not grow into a
data-frame: the data-facing entry points added later (a CSV or JSON
reader) will return `(R.error, reason)` instead of raising, because
data read from outside is not programmer intent.

## Channels

The dataset charts name their columns through a channel mapping — a
`Map[String, String]` whose keys are channels and whose values are
column names, so a key left out is simply a channel unused:

```emo
{ "x": "total_bill", "y": "tip", "color": "time" }
```

The vocabulary is eight words — `x`, `y`, `color`, `size`, `marker`,
`dash`, `facet_row`, `facet_col` — and a mapping that carries anything
else raises. Each chart family reads only the channels it supports: the
relational charts read the full set, the distribution and categorical
charts read `x`, `y`, `color`, and the two facet channels, and the
matrix charts read only the facets. A mapping that carries a channel
its family does not read raises. Channel values are column names only:
a constant belongs in the mark style, never in the mapping.

The `color` channel dispatches on the column's kind, and the dispatch
is a function on its own:

```emo
plot.channel_colors(tips, "time", plot.theme())
```

A label column resolves through the theme palette by the level's
sorted position — levels are distinct and ordered by their bytes — and
a number column normalizes its observed values over their span and
reads the theme colormap, a column whose values all agree sitting at
the map's low end. An absent slot keeps its place with the low end
too, since the chart layer never draws it. An unknown column raises.

## Themes

A theme dresses the whole figure: the background and foreground inks,
the grid, axis, title, and label styles, the palette and colormap the
`color` channel resolves through, the spacing between panels, and
the default size a `figure()` starts at. `figure()` builds the default
light theme, and `with_theme` swaps it on a figure:

```emo
plot.figure().with_theme(plot.dark_theme())
```

```emo
def theme() Theme
def dark_theme() Theme

def palette() Palette
def viridis() Colormap
def sequential() Colormap
def diverging() Colormap
```

`Theme` carries `background` and `foreground` (sRGB triples), `grid`
(a `GridStyle`), `axis` (an `AxisStyle`: the spine color and width, the
tick mark length, and the x/y axis label size), `title` and `label`
(`TextStyle`s: color, size, anchor, weight), `palette`, `cmap`,
`spacing`, and `width` / `height`. Every field refines through a
`with_*` copy method: `with_background`, `with_foreground`, `with_grid`,
`with_axis`, `with_title`, `with_label`, `with_palette`, `with_cmap`,
`with_spacing`.

A `Palette` wraps a list of colors and answers `color(i)` wrapping
around the list. A `Colormap` pins stops at positions across 0.0–1.0
and answers `at(t)` by interpolating the bracketing stops' channels in
`Float64`; an empty list, an out-of-range position, or a descending
position raises. The built-ins are starting points: `palette()` lists
the five mark families' default colors, and `viridis()` /
`sequential()` / `diverging()` approximate their targets with five
stops each.

The theme only supplies defaults; what a mark finally draws is still a
`plot.mark` style value.

## The panel grid

`Figure.grid` lays the figure's axes out as rows × cols panels,
separated by the theme spacing; `with_grid(rows, cols)` sets it, and
the default `(1, 1)` is one full-size panel. Cells fill row major and a
grid with more cells than axes leaves the tail blank; more axes than
cells raises, as does a row or column count below 1. The figure title
sits above the grid, drawn once.

`Share.all` — the default — resolves every panel's own domain first and
then draws each on the union, so panels compare against one scale;
`Share.none` leaves each panel on its own.

```emo
plot.figure().with_title("Quarterly review").with_grid(2, 2)
  .with_axes([units_ax, revenue_ax, costs_ax])
```

Splitting one dataset into panels by a column's levels, labelling each
panel from its levels, and drawing one shared legend are the chart
layer's work — the figure carries the grid, the chart functions fill
it.

## Marks

The marks live in the `plot.mark` submodule — a package's submodules are
addressed under its short name. T0 ships the bar, line, scatter, area,
and hist marks:

```emo
def bar(labels Array[String], values Array[Float64]) Bar
def bar_style() BarStyle

def line(x Array[Float64], y Array[Float64]) Line
def line_style() LineStyle

def scatter(x Array[Float64], y Array[Float64]) Scatter
def scatter_style() ScatterStyle

def area(x Array[Float64], y Array[Float64]) Area
def area_style() AreaStyle

def hist(values Array[Float64], bins Int64) Hist
def hist_style() HistStyle
```

A mark is a value too. `Bar.with_style(s BarStyle)` and the style's
`with_color` / `with_width` / `with_label` refine it without mutating
anything:

```emo
plot.mark.bar(months, sales).with_style(
  plot.mark.bar_style().with_color((192, 57, 43)).with_width(0.6))
```

A line draws a stroked polyline through the `(x, y)` points and stamps
its marker shape at every point. `LineStyle` carries `color`, `width`,
`dash` (`Dash.solid` / `dashed` / `dotted` / `dash_dot`), `marker`
(`Marker.none` / `circle` / `square` / `triangle` / `diamond` / `cross` /
`plus`), `marker_size`, `opacity`, and `label`, refined through the same
`with_*` copy methods:

```emo
plot.mark.line(years, revenue).with_style(
  plot.mark.line_style().with_dash(plot.mark.Dash.dashed)
    .with_marker(plot.mark.Marker.circle))
```

A scatter stamps its marker at every `(x, y)` point and connects
nothing. `ScatterStyle` carries `color`, `size`, `marker`, `opacity`,
and `label` — the marker vocabulary is the same `Marker` enum the line
stamps with, and a scatter with `Marker.none` draws nothing.

An area fills the closed region between its polyline and the zero
baseline, negative values dipping below it. `AreaStyle` carries `color`
(the fill), `edge_color` and `edge_width` (a stroke along the curve
itself; the default `0.0` width draws no edge), `opacity`, and `label`.

A histogram counts its values into equal-width bins spanning the data
and tiles the bins as bars on the zero baseline. A value equal to the
maximum counts into the last bin; identical values pile into it too,
since their span collapses to zero. `bins < 1` is a contract violation
and raises. `HistStyle` carries `color` (the fill), `edge_color` and
`edge_width` (the bar outlines; white by default at width 1.0),
`opacity`, and `label`.

**Colors are `(Int64, Int64, Int64)` sRGB triples**, each channel 0–255.
`plot.rgb(r, g, b)` builds one with the range checked — an
out-of-range channel raises — and a raw triple is accepted and
validated when it is drawn. Opacity is a separate `Float64` on the
style, never baked into the triple. It rides every style but is not
rendered yet — the renderer's primitives do not carry an opacity knob
yet.

A mark draws itself into an axes through the `Mark` interface — `draw`,
plus the data span it asks the axes to cover: a continuous x and y
range through `x_min` / `x_max` / `y_min` / `y_max`, and the categorical
x face through `bands` and `x_labels` — and it feeds the legend:
`legend_label()` answers the style's label, `legend_sample` draws the
family's swatch. A new mark family is a new class that satisfies that
shape.

With `legend` on (the default), the labeled marks list into a legend in
the plot's top-right corner — marks array order, drawn last, one panel
behind them filled with the theme background and inset by the theme
spacing. Marks whose label is empty stay out of it. Entry offsets use
an approximate per-character advance, since the package carries no font
metrics.

## A worked example

```emo
require "plot"

const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun"]
const sales = [12.0, 18.0, 15.0, 24.0, 21.0, 30.0]

const ax = plot.axes().with_x_label("Month").with_y_label("Sales").with_marks([plot.mark.bar(months, sales)])
const chart = plot.figure().with_title("Monthly sales").with_axes([ax])

println(plot.svg(chart))
```

`examples/plot_demo` is this program.

## Output

`svg` hands back the document; writing it to a file is the caller's step.
The package runs on the five hosted targets it declares, while file IO
belongs to the native-only `file` and `os` packages — on a native
target, `file.write("chart.svg", plot.svg(chart))`.

Text is delegated to the viewer: every label is an SVG `<text>` element,
so the package carries no font engine. Coordinates and values are
formatted with the interpreter's float rendering, which is why the bytes
are identical on every target.

## Targets and what is landed

Targets: the five hosted targets the package declares — `c`, `ocaml`,
`typescript`, `wasm`, `beam`. That list is the package's, not the
language's: the interpreter evaluates a program without an artifact, and
the full build-target set adds `browser` and the freestanding
`riscv64`, which stays outside this list because it refuses `Map`. The
whole story, target by target, is
[`docs/demo-targets.md`](../demo-targets.md).

T0 — what exists today — is the bar, line, scatter, area, and hist
marks, linear axes with nice-number ticks, a title, axis labels, tick
marks, the grid, the theme that dresses it all, the validating `Table`
the dataset charts will read, the channel vocabulary and the `color`
channel's kind dispatch, and SVG output. Both
axes scale to the marks' declared spans: the y domain covers every
mark's range, and the x axis ticks numerically unless a mark supplies
categorical labels. The remaining pieces the surface carries are
reserved and not rendered yet: the chart functions that take a table
and a channel mapping, and the chart-layer half of faceting —
splitting a dataset by a column's levels, per-panel level labels, and
the one shared legend. The marks and the axes draw through the internal
`Renderer` interface — `DrawContext` carries a `Renderer`, not the
concrete SVG class — so a terminal or raster backend can join later
without disturbing the figure or the marks.

See also: `examples/plot_demo`, and the design note
[`docs/visualization.md`](../visualization.md).
