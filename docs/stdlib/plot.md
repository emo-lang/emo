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
def with_shared_legend(on Bool) Figure

// Axes
def with_x_label(s String) Axes
def with_y_label(s String) Axes
def with_x_scale(s Scale) Axes
def with_y_scale(s Scale) Axes
def with_x_domain(a Float64, b Float64) Axes
def with_y_domain(a Float64, b Float64) Axes
def with_marks(m Array[Mark]) Axes
def with_legend(on Bool) Axes
def with_title(s String) Axes

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

## The relational charts

The dataset charts are one function per chart kind: each takes the
table and the channel mapping and answers a whole `Figure` — one axes
carrying the marks the mapping builds, the axes labelled from the
channel's column names — which `svg` renders and the `with_*` methods
refine like any figure.

```emo
def scatter(t Table, ch Map[String, String]) Figure
def line(t Table, ch Map[String, String]) Figure
def reg(t Table, ch Map[String, String]) Figure
```

The `x` and `y` channels are required, and both name number columns —
a label column there raises through the table's own kind check. A row
where either column is absent drops out of the chart; a chart left
with no drawable row raises. Everything else is per chart, and a
mapping that carries a channel its chart does not read raises:

- `scatter` reads `color`, `size`, and `marker`.
- `line` reads `color`, `marker`, and `dash`.
- `reg` reads only the pair.

The `color` channel dispatches on the column's kind, the same dispatch
`plot.channel_colors` answers. A label column splits the rows into one
series per level — colored by the level's sorted position in the theme
palette and named by the level in the legend, a level two grouping
channels share named once. A number column (a scatter's) colors each
point where it sits on the column's observed span, through the theme
colormap. The `size` channel scales each point between half and one
and a half times the style's size over its column's observed span. The
`marker` and `dash` channels read label columns and pick each level's
point stamp — circle, square, triangle, diamond, cross, plus, wrapping
the list — and stroke pattern — solid, dashed, dotted, dash dot. The
line chart draws each series in the rows' own order: a table's row
order is intent, so the chart does not sort. The group colors resolve
through the default theme while the figure is built; `with_theme`
after the call re-dresses the figure's own inks.

```emo
const meals = plot.table(
  { "bill": [16.99, 10.34, 21.01, 23.68], "tip": [1.01, 1.66, 3.50, 3.31],
    "party": [2.0, 3.0, 2.0, 4.0] },
  { "day": ["Sun", "Sat", "Sun", "Sat"] }
)
plot.svg(plot.scatter(meals, { "x": "bill", "y": "tip", "color": "day", "size": "party" }))
```

`reg` fits the least-squares line over the points and draws the 95%
confidence band for the mean response under them — the band first, so
the points sit on it. The band is a `plot.mark.band` filled with the
band style, sampled over the kept span at fifty grid points; the fit
line joins the legend as `fit`, the band as `95% band`. Two drawable
rows are the floor, and an x column whose values do not spread raises
through the fit.

The facet channels split any chart into panels — see "Faceting"
below. The violations raise: an unknown channel, a channel the chart
does not read, a missing `x` or `y`, a grouping or facet channel
handed a number column, a `size` or number `color` column with no
observed values, a chart with no drawable rows, and a `reg` with fewer
than two.

## The distribution charts

`hist`, `kde`, and `ecdf` read one numeric column and draw one mark
per `color` level — the split working like the relational charts' —
and `box` and `violin` group a numeric column by a label one:

```emo
def hist(t Table, ch Map[String, String]) Figure
def kde(t Table, ch Map[String, String]) Figure
def ecdf(t Table, ch Map[String, String]) Figure
def box(t Table, ch Map[String, String]) Figure
def violin(t Table, ch Map[String, String]) Figure
```

`hist` counts the kept values into equal-width bins spanning their
shared range — the square root of the count of them, at least one —
one histogram per level over the shared grid, so the levels compare.
`kde` draws one density curve per level, the bandwidth Silverman's
rule of thumb answers over the level's own values, the grid three
bandwidths past each end at a hundred points. `ecdf` draws one
staircase per level, each value's cumulative proportion stepping up at
the value. The three label their y axes `count`, `density`, and
`proportion`.

`box` and `violin` sit on the `x` column's levels — a number column
there raises, the boxes sit on the levels, not on numbers. Each level's
`y` values summarize through the Tukey statistics: `box` draws the
whiskers, the filled quartile box, the median line, and the fliers
stamped beyond the whiskers; `violin` draws a mirrored density per
level, the same Silverman bandwidth and grid shape the `kde` chart
reads, every density normalized across the row so the violins compare.
A level with no observed `y` values never appears; a level whose values
do not spread has no density and raises. The `color` channel is not
read by `box` or `violin` yet.

The single-column charts need the `x` channel, the grouped pair needs
both; the absent rows drop out as everywhere, a chart with no drawable
row raises, and an unknown channel, an unread channel, or a `color`
mapping to a number column raises too. A constant column has no
density: the `kde` chart raises rather than drawing a spike.

## The categorical charts

`bar`, `count`, `strip`, and `point` sit on the `x` column's levels —
a number column there raises, the marks sit on the levels, not on
numbers:

```emo
def bar(t Table, ch Map[String, String]) Figure
def count(t Table, ch Map[String, String]) Figure
def strip(t Table, ch Map[String, String]) Figure
def point(t Table, ch Map[String, String]) Figure
```

`bar` and `point` need the `y` channel and aggregate each level's
observed y values by their mean — one bar per level, and one stamped,
connected mean walking the bands in their sorted order. `count` needs
no `y` at all: one bar per level, its height the number of rows the
level carries. `strip` draws the raw points at their bands' centers,
one mark per `color` level — the split working like the relational
charts' — the points unjittered and in the rows' own order, so
overlapping points are the data. `strip` labels its y axis from the
`y` column and `count` labels it `count`.

## The matrix charts

`heatmap` and `clustermap` read the whole table as a matrix: the
numeric columns are the cells' columns and the rows the cells' rows,
and one label column — exactly one — names the rows; with none, or
several, the rows number from 1. The channel mapping carries no column
names here, only the facet channels, so it is normally empty:

```emo
def heatmap(t Table, ch Map[String, String]) Figure
def clustermap(t Table, ch Map[String, String]) Figure
```

```emo
const corr = plot.table(
  { "alpha": [1.00, 0.41, 0.18], "beta": [0.41, 1.00, 0.55], "gamma": [0.18, 0.55, 1.00] },
  { "row": ["alpha", "beta", "gamma"] }
)
plot.svg(plot.heatmap(corr, {}))
```

Every cell takes its color where its value sits on the cells' own
span, through the theme colormap — a constant matrix sits at the map's
low end. The column names label the x bands and the row names the y
bands, so neither axis ticks numbers. `clustermap` draws the same cells
with the rows and the columns each reordered by average-linkage
clustering over their euclidean distances, so neighbors are the similar
ones; the trees themselves are not drawn — the order is the clustering.
A table with no number column, or with no rows, raises.

## Faceting

Every chart reads the `facet_row` and `facet_col` channels. Each names
a label column, and the column's levels — distinct, in byte order like
every other grouping — split the chart into panels: `facet_row`'s
levels down, `facet_col`'s across, one channel alone a 1 × N or N × 1
strip. Every cell draws the chart over the rows it holds, so a cell
whose level combination has no rows stays blank, and the facet columns
themselves stay out of a heatmap's row-name rule.

```emo
plot.scatter(meals, { "x": "bill", "y": "tip", "color": "day", "facet_col": "time" })
plot.hist(exam, { "x": "score", "facet_row": "class" })
```

The panels compare: the figure keeps `Share.all`, so every panel draws
on the union of the panels' domains (the matrix charts keep their own
cell grids under `Share.none`); each panel is titled from its levels —
`time = Lunch`, both facets joined with a comma; the axis labels sit at
the outer edge only, the x label on the bottom row and the y label on
the first column; and the panels' own legends give way to one legend
for the whole figure, at its right, listing every labeled mark once by
label — the same level is the same color in every panel, since the
levels sort over the whole table. A facet channel handed a number
column raises, like the grouping channels.

The pieces are ordinary figure values, so a hand-built grid can use
them too: `Axes.with_title` is the panel title, `Figure.with_shared_legend`
the figure-level legend, and each chart's single-panel form —
`scatter_axes`, `hist_axes`, `heatmap_axes`, and so on for all fourteen
— answers the `Axes` alone for a table, ready for `with_axes`.

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

An axes with no marks is a blank cell: it draws nothing and stays out
of the shared domain. `with_shared_legend(true)` draws one legend for
the whole figure at its right — every labeled mark across the panels,
once by label — and takes that column out of the grid's width; the
panels' own legends are usually switched off beside it. Splitting one
dataset into panels by a column's levels is the chart layer's work —
see "Faceting" — the figure carries the grid, the chart functions fill
it.

## Marks

The marks live in the `plot.mark` submodule — a package's submodules are
addressed under its short name. The bar, line, scatter, area, and hist
marks are T0's, and `band` joined them for the regression chart:

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

def band(xs Array[Float64], lo Array[Float64], hi Array[Float64]) Band
def band_style() BandStyle

def box(labels Array[String], lows Array[Float64], q1s Array[Float64], medians Array[Float64], q3s Array[Float64], his Array[Float64], flier_xs Array[Float64], fliers Array[Float64]) BoxPlot
def box_style() BoxStyle

def violin(labels Array[String], points Int64, xs Array[Float64], density Array[Float64]) Violin
def violin_style() ViolinStyle

def strip(labels Array[String], xs Array[Float64], ys Array[Float64]) Strip

def point(labels Array[String], xs Array[Float64], ys Array[Float64]) Point
def point_style() LineStyle
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
stamps with, and a scatter with `Marker.none` draws nothing. A scatter
also carries per-point color and size overrides — the arrays the
dataset charts read their `color` and `size` channels through; a point
past an override's end draws the style's value.

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

A band fills the region between a lower and an upper curve over one
shared run of `xs` — one polygon, the upper curve read forward and the
lower one back — and the regression chart draws its confidence band as
one. The factory checks that the low and high arrays match the xs and
that the xs ascend. `BandStyle` carries `color` (the fill), `opacity`,
and `label`.

A box row sits on the categorical face — one box per label at its band
center: whiskers, the filled quartile box, the median line, and the
fliers stamped beyond the whiskers. The five statistics arrays share
the labels' length and the flier arrays their own; the factories check.
`BoxStyle` carries the fill and edge `color`s, `edge_width`, the band
fraction `width`, `opacity`, and `label`.

A violin row mirrors a density per label — the grids and densities are
flat, one run of `points` per label, the densities fractions of the
band's half width. `ViolinStyle` carries `color` (the fill), the band
fraction `width`, `opacity`, and `label`.

A strip is a scatter over the categorical face: raw points at their
bands' centers, the xs band coordinates and the arrays sharing their
length. A point row walks the bands — one value per label, connected
in band order and stamped with the style's marker; its style is a
`LineStyle` (the line connects, the marker stamps) and a strip's is a
`ScatterStyle`.

A heatmap is a grid of pre-colored cells — the values row major over
the column names across and the row names down, each cell's color
handed in by the chart layer, so the mark knows nothing of colormaps.
It is the one mark that labels both axes: the column names ride the
categorical x face and the row names the y face. It carries no style
and stays out of the legend.

**Colors are `(Int64, Int64, Int64)` sRGB triples**, each channel 0–255.
`plot.rgb(r, g, b)` builds one with the range checked — an
out-of-range channel raises — and a raw triple is accepted and
validated when it is drawn. Opacity is a separate `Float64` on the
style, never baked into the triple. It rides every style but is not
rendered yet — the renderer's primitives do not carry an opacity knob
yet.

A mark draws itself into an axes through the `Mark` interface — `draw`,
plus the data span it asks the axes to cover: a continuous x and y
range through `x_min` / `x_max` / `y_min` / `y_max`, the categorical
x face through `bands` and `x_labels`, and the categorical y face
through `y_labels` (empty for every mark but the heatmap) — and it
feeds the legend:
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
the dataset charts read, the channel vocabulary and the `color`
channel's kind dispatch, the relational charts — `scatter`, `line`,
and `reg`, with the `band` mark joining `plot.mark` for the
regression chart — the distribution charts — `hist`, `kde`, `ecdf`,
`box`, and `violin`, with the `box` and `violin` marks joining
`plot.mark` — the categorical charts — `bar`, `count`, `strip`, and
`point`, with the `strip` and `point` marks joining `plot.mark` — the
matrix charts — `heatmap` and `clustermap`, with the `heatmap` mark
and the categorical y face joining `plot.mark` — and SVG output. Both
axes scale to the marks' declared spans: the y domain covers every
mark's range, and the x axis ticks numerically unless a mark supplies
categorical labels. Faceting rides every chart: a facet channel's
sorted levels split it into panels on one shared domain, each titled
from its level, with one legend for the figure. The marks and the axes
draw through the internal
`Renderer` interface — `DrawContext` carries a `Renderer`, not the
concrete SVG class — so a terminal or raster backend can join later
without disturbing the figure or the marks.

See also: `examples/plot_demo`, and the design note
[`docs/visualization.md`](../visualization.md).
