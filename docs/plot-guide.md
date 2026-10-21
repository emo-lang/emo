# The `plot` Guide

How to draw charts with the `plot` package — the whole public API,
organized by what you are building. The package is declarative: a
chart is a value, built once, rendered many times. A `Figure` holds
`Axes`, each axes holds marks, and one call walks the whole graph into
SVG, terminal text, or PNG. Everything is pure Emo, so the five hosted
targets answer byte-for-byte.

Three layers sit behind one `require`:

- **the figure layer** — `figure()` / `axes()` and their `with_*`
  refinements, the theme that dresses it all, and the three render
  entry points;
- **the dataset layer** — a validating `Table`, an eight-word channel
  vocabulary, and fourteen chart functions that answer whole figures;
- **the mark layer** — `plot.mark`, the marks a hand-built axes draws
  when there is no table to read.

For the concise reference, see [`docs/stdlib/plot.md`](stdlib/plot.md);
for the design note, [`docs/visualization.md`](visualization.md); for a
runnable program covering every chart kind, `examples/plot_demo`.

## Getting started

The standard library ships with the compiler, but its packages are
versioned like any other dependency — pin the version in the manifest
before `require`:

```emo
// package.emo
deps {
  "plot" = "0.1.0"
}
```

```emo
require "plot"

const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun"]
const sales = [12.0, 18.0, 15.0, 24.0, 21.0, 30.0]

const ax = plot.axes().with_x_label("Month").with_y_label("Sales").with_marks([plot.mark.bar(months, sales)])
const fig = plot.figure().with_title("Monthly sales").with_axes([ax])

println(plot.svg(fig))
```

One `require "plot"` brings both public modules into scope: `plot` (the
figure surface and the dataset charts) and `plot.mark` (the marks).
Every class is immutable — a `with_*` method answers a new value and
leaves the old one alone, so a figure is assembled by chained
refinement and nothing mutates underneath you.

## Figures and axes

### Building a figure

```emo
def figure() Figure
def axes() Axes
```

`figure()` answers the default figure: the theme's size (640 × 480), a
1 × 1 grid, `Share.all`, one empty axes. `axes()` answers the default
axes: linear scales, auto domains, the legend on, no labels, no marks.
Both are starting points — the `with_*` methods refine them:

```emo
// Figure — every method answers a new Figure
with_title(t String)              // drawn once, above the grid
with_size(w Float64, h Float64)   // pixel size; 640 × 480 by default
with_theme(t Theme)
with_grid(rows Int64, cols Int64) // panel layout, (1, 1) by default
with_axes(a Array[Axes])          // fills the grid row major
with_share(s Share)               // Share.all (default) or Share.none
with_shared_legend(on Bool)       // one legend at the figure's right
```

```emo
// Axes — every method answers a new Axes
with_x_label(s String)
with_y_label(s String)
with_x_scale(s Scale)             // Scale.linear (default) or Scale.log
with_y_scale(s Scale)
with_x_domain(a Float64, b Float64)   // Domain.auto (default) → Domain.fixed
with_y_domain(a Float64, b Float64)
with_marks(m Array[Mark])
with_legend(on Bool)              // on by default
with_title(s String)              // the panel's own title, centered
```

```emo
const ax = plot.axes().with_x_label("Temperature").with_y_label("Ice cream").with_marks([
  plot.mark.scatter([14.0, 16.0, 18.0, 21.0, 24.0], [8.0, 12.0, 14.0, 19.0, 26.0])
])
const fig = plot.figure().with_title("Ice cream vs temperature").with_axes([ax])
println(plot.svg(fig))
```

`Axes.with_title` is the panel's own title, drawn centered over its
plot area — the facet layer labels its panels through it (see
"Faceting").

### Scales: linear and log

```emo
enum Scale { linear, log }
```

A log axis spans whole decades: the domain snaps to the enclosing
powers of ten, ticks sit on the 1-2-5 steps through each decade (the 2
and 5 steps join only while the span is two decades or less), and a
nonpositive value or domain raises — a log axis maps positive numbers
and nothing else.

```emo
const views_ax = plot.axes().with_x_label("Day").with_y_label("Views").with_y_scale(plot.Scale.log).with_marks([
  plot.mark.line([1.0, 2.0, 3.0, 4.0], [10.0, 120.0, 900.0, 8500.0])
])
```

### Domains: auto and fixed

```emo
enum Domain { auto, fixed }
```

`Domain.auto` — the default — infers each axis's span from every
mark's declared range, so both axes scale to what is drawn. A fixed
domain carries the caller's ends verbatim; ticks respect them, and an
inverted domain (`lo >= hi`) raises. Marks are not clipped to the axes
rectangle yet, so data outside a fixed domain draws past it.

```emo
const fixed_ax = plot.axes().with_x_label("Year").with_y_label("Revenue").with_y_domain(40.0, 80.0).with_marks([
  plot.mark.line([2020.0, 2021.0, 2022.0, 2023.0], [42.0, 51.0, 47.0, 62.0])
])
```

## Output formats

The same figure value renders three ways — one `render` walk, three
renderers:

```emo
def svg(fig Figure) String       // an SVG document
def terminal(fig Figure) String  // braille text for a terminal
def png(fig Figure) Bytes        // a PNG file
```

`svg` hands back the document as a `String`; writing it to a file is
the caller's step. The package runs on the five hosted targets, while
file IO belongs to the native-only `file` and `os` packages — on a
native target, `file.write("chart.svg", plot.svg(fig))`.

`terminal` hands back rows of braille cells and characters, each row
newline-terminated, so a chart shows in a CI log or at the command
line with `println`. Four pixels of figure width make a column and
eight of height a row: the default 640 × 480 figure prints as 160
columns by 60 rows, and `with_size(320.0, 240.0)` fits an 80-column
terminal. Every color becomes one ink — a level from 0 to 8 from its
luminance contrast against the theme background — so a filled mark
halftones at its level (a heatmap reads as shades) and a line draws
solid, sparsely dotted, or not at all by the same level.

`png` rasterizes the same graph onto 2 × 2 supersamples a pixel, sets
text in the Hershey Simplex stroke font, and frames the result with
the package's own DEFLATE, CRC-32, and Adler-32 — no host image
library. The answer is `Bytes` because a PNG is binary; write it with
`file.write("chart.png", plot.png(fig))` on a native target.

```emo
println(plot.terminal(fig))
file.write("chart.png", plot.png(fig))
```

## Tables and missing numbers

The dataset charts read a `Table` — the one data structure the package
owns: column-oriented, minimal, built only through two validating
constructors.

```emo
def table(numbers Map[String, Array[Float64]], labels Map[String, Array[String]]) Table
def table_missing(numbers Map[String, Array[Float64]], presence Map[String, Array[Presence]], labels Map[String, Array[String]]) Table

enum Presence { present, absent }
```

Numeric columns and categorical columns live in maps keyed by column
name, and every column shares one row count. `table` builds the
all-present table; `table_missing` takes presence columns the caller
wrote — a missing number keeps its slot in the values array and the
parallel presence entry names the slot `absent`. A missing value is a
presence tag, not `NaN` — the beam target's Erlang floats cannot carry
one.

Both builders validate the shape and raise on a violation, because a
table written as a literal is programmer intent: two columns of
different lengths, one name claimed by both kinds, a numeric column
with no presence column — or a stray one, or one whose length
disagrees with its numbers — are all contract violations.

```emo
const meals = plot.table(
  { "bill": [16.99, 10.34, 21.01, 23.68], "tip": [1.01, 1.66, 3.50, 3.31], "party": [2.0, 3.0, 2.0, 4.0] },
  { "day": ["Sun", "Sat", "Sun", "Sat"], "time": ["Dinner", "Dinner", "Lunch", "Dinner"] }
)
```

Reading goes through the column's kind — `rows` is the row count, and
reading a name the table carries under the other kind, or a name it
does not carry, raises:

```emo
meals.rows                    // 4
meals.number("bill")          // the numeric column's values
meals.presence("bill")        // the parallel presence array
meals.label("day")            // the categorical column's values
```

`plot.observed(numbers, presence)` filters a column down to its
present entries — the floor every statistic reads through. The absent
rows drop out of the dataset charts the same way: a missing value
costs its row, not the chart.

## Channels

The dataset charts name their columns through a channel mapping — a
`Map[String, String]` whose keys are channels and whose values are
column names, so a key left out is simply a channel unused:

```emo
{ "x": "bill", "y": "tip", "color": "day", "size": "party" }
```

The vocabulary is eight words — `x`, `y`, `color`, `size`, `marker`,
`dash`, `facet_row`, `facet_col` — and a mapping that carries anything
else raises, as does a channel its chart does not read. Channel values
are column names only: a constant belongs in the mark style, never in
the mapping.

What each chart reads:

| Chart | Required | Optional |
|---|---|---|
| `scatter` | `x`, `y` — number columns | `color` (number or label), `size` (number), `marker` (label), facets |
| `line` | `x`, `y` — number columns | `color`, `marker`, `dash` (labels), facets |
| `reg` | `x`, `y` — number columns | facets |
| `hist` | `x` — number column | `color` (label), facets |
| `kde` | `x` — number column | `color` (label), facets |
| `ecdf` | `x` — number column | `color` (label), facets |
| `box` | `x` — label, `y` — number | facets |
| `violin` | `x` — label, `y` — number | facets |
| `bar` | `x` — label, `y` — number | facets |
| `count` | `x` — label column | facets |
| `strip` | `x` — label, `y` — number | `color` (label), facets |
| `point` | `x` — label, `y` — number | facets |
| `heatmap` | — | facets |
| `clustermap` | — | facets |

The `color` channel dispatches on the column's kind, and the dispatch
is a function on its own:

```emo
def channel_colors(t Table, name String, theme Theme) Array[(Int64, Int64, Int64)]
```

A label column resolves through the theme palette by the level's
sorted position — levels are distinct and ordered by their bytes — and
a number column normalizes its observed values over their span and
reads the theme colormap, a column whose values all agree sitting at
the map's low end. A grouping level also picks its marker shape and
stroke pattern by the same sorted position, cycling the vocabulary:
`plot.marker_at(i)` wraps the six shapes (circle, square, triangle,
diamond, cross, plus) and `plot.dash_at(i)` the four patterns (solid,
dashed, dotted, dash dot).

## Relational charts: scatter, line, reg

The dataset charts are one function per chart kind: each takes the
table and the channel mapping and answers a whole `Figure` — one axes
labelled from the channel's column names, carrying the marks the
mapping builds:

```emo
def scatter(t Table, ch Map[String, String]) Figure
def line(t Table, ch Map[String, String]) Figure
def reg(t Table, ch Map[String, String]) Figure
```

A row where a required column is absent drops out of the chart; a
chart left with no drawable row raises.

**`scatter`** stamps one mark per grouping level, one when the mapping
groups nothing. A label `color` column splits the points into one
series per level, colored by the level's sorted position in the theme
palette and named by the level in the legend; a number `color` column
colors every point where it sits on its observed span, through the
theme colormap. The `size` channel scales each point between half and
one and a half times the style's size over its column's observed span;
the `marker` channel stamps each level with its own shape.

```emo
plot.svg(plot.scatter(meals, { "x": "bill", "y": "tip", "color": "day", "size": "party" }))
```

**`line`** draws one stroked series per grouping level, each in the
rows' own order — a table's row order is intent, so the chart does not
sort. A level's color, marker stamp, and dash pattern each resolve by
the level's sorted position when the matching channel names a label
column.

```emo
const regions = plot.table(
  { "quarter": [1.0, 2.0, 3.0, 4.0, 1.0, 2.0, 3.0, 4.0], "revenue": [12.0, 18.0, 15.0, 24.0, 9.0, 11.0, 16.0, 14.0] },
  { "region": ["west", "west", "west", "west", "east", "east", "east", "east"] }
)
plot.svg(plot.line(regions, { "x": "quarter", "y": "revenue", "color": "region", "dash": "region" }))
```

**`reg`** fits the least-squares line over the points and draws the
95% confidence band for the mean response under them — the band first,
so the points sit on it. The band samples the kept span at fifty grid
points; the fit line joins the legend as `fit`, the band as `95% band`.
Two drawable rows are the floor.

```emo
const study = plot.table(
  { "hours": [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0], "score": [52.0, 55.0, 61.0, 64.0, 66.0, 71.0, 74.0, 77.0] },
  {}
)
plot.svg(plot.reg(study, { "x": "hours", "y": "score" }))
```

The group colors resolve through the default theme while the figure is
built; `with_theme` after the call re-dresses the figure's own inks.

## Distribution charts: hist, kde, ecdf, box, violin

`hist`, `kde`, and `ecdf` read one numeric column and draw one mark
per `color` level — the split working like the relational charts'.
`box` and `violin` group a numeric column by a label one:

```emo
def hist(t Table, ch Map[String, String]) Figure
def kde(t Table, ch Map[String, String]) Figure
def ecdf(t Table, ch Map[String, String]) Figure
def box(t Table, ch Map[String, String]) Figure
def violin(t Table, ch Map[String, String]) Figure
```

**`hist`** counts the kept values into equal-width bins spanning their
shared range — the square root of the count of them, at least one —
one histogram per level over the shared grid, so the levels compare.
The y axis labels itself `count`.

**`kde`** draws one density curve per level, the bandwidth Silverman's
rule of thumb answers over the level's own values, the grid three
bandwidths past each end at a hundred points. The y axis labels
`density`. A constant column has no density — the chart raises rather
than drawing a spike.

**`ecdf`** draws one staircase per level, each value's cumulative
proportion stepping up at the value. The y axis labels `proportion`.

**`box`** sits on the `x` column's levels — a number column there
raises — and summarizes each level's `y` values through the Tukey
statistics: whiskers at the most extreme values still inside 1.5·IQR
of the quartiles, the filled quartile box, the median line, and the
fliers stamped beyond the whiskers. A level with no observed `y`
values never appears.

**`violin`** draws a mirrored density per level, the same Silverman
bandwidth and grid shape the `kde` chart reads, every density
normalized across the row so the violins compare. A level whose values
do not spread raises.

```emo
const exam = plot.table(
  { "score": [62.0, 70.0, 75.0, 81.0, 88.0, 58.0, 66.0, 73.0, 55.0, 68.0, 77.0, 83.0] },
  { "class": ["A", "A", "A", "A", "A", "A", "B", "B", "B", "B", "B", "B"] }
)
plot.svg(plot.hist(exam, { "x": "score", "color": "class" }))
plot.svg(plot.kde(exam, { "x": "score", "color": "class" }))
plot.svg(plot.ecdf(exam, { "x": "score", "color": "class" }))
plot.svg(plot.box(exam, { "x": "class", "y": "score" }))
plot.svg(plot.violin(exam, { "x": "class", "y": "score" }))
```

## Categorical charts: bar, count, strip, point

All four sit on the `x` column's levels — a number column there
raises; `bar`, `strip`, and `point` need the `y` number column beside
it:

```emo
def bar(t Table, ch Map[String, String]) Figure
def count(t Table, ch Map[String, String]) Figure
def strip(t Table, ch Map[String, String]) Figure
def point(t Table, ch Map[String, String]) Figure
```

**`bar`** draws one bar per level, its height the mean of the level's
observed `y` values. **`count`** needs no `y` at all: one bar per
level, its height the number of rows the level carries, the y axis
labeled `count`. **`strip`** draws the raw points at their bands'
centers, one mark per `color` level, unjittered and in the rows' own
order — overlapping points are the data. **`point`** draws one stamped,
connected mean per level, walking the bands in their sorted order.

```emo
const regions = plot.table(
  { "revenue": [12.0, 9.0, 18.0, 11.0, 15.0, 16.0, 24.0, 14.0] },
  { "region": ["west", "east", "west", "east", "west", "east", "west", "east"],
    "kind": ["store", "store", "online", "online", "store", "online", "online", "store"] }
)
plot.svg(plot.bar(regions, { "x": "region", "y": "revenue" }))
plot.svg(plot.count(regions, { "x": "region" }))
plot.svg(plot.strip(regions, { "x": "region", "y": "revenue", "color": "kind" }))
plot.svg(plot.point(regions, { "x": "region", "y": "revenue" }))
```

## Matrix charts: heatmap, clustermap

`heatmap` and `clustermap` read the whole table as a matrix: the
numeric columns are the cells' columns and the rows the cells' rows,
and one label column — exactly one — names the rows; with none, or
several, the rows number from 1. The channel mapping carries no column
names here, only the facet channels, so it is normally empty:

```emo
def heatmap(t Table, ch Map[String, String]) Figure
def clustermap(t Table, ch Map[String, String]) Figure
```

Every cell takes its color where its value sits on the cells' own
span, through the theme colormap — a constant matrix sits at the map's
low end. The column names label the x bands and the row names the y
bands, so neither axis ticks numbers. `clustermap` draws the same
cells with the rows and the columns each reordered by average-linkage
clustering over their euclidean distances, so neighbors are the
similar ones; the trees themselves are not drawn — the order is the
clustering.

```emo
const corr = plot.table(
  { "alpha": [1.00, 0.41, 0.18, -0.12], "beta": [0.41, 1.00, 0.55, 0.02],
    "gamma": [0.18, 0.55, 1.00, 0.33], "delta": [-0.12, 0.02, 0.33, 1.00] },
  { "row": ["alpha", "beta", "gamma", "delta"] }
)
plot.svg(plot.heatmap(corr, {}))
plot.svg(plot.clustermap(corr, {}))
```

A table with no number column, or with no rows, raises.

## Faceting

Every chart reads the `facet_row` and `facet_col` channels. Each names
a label column, and the column's levels — distinct, in byte order like
every other grouping — split the chart into panels: `facet_row`'s
levels down, `facet_col`'s across, one channel alone a 1 × N or N × 1
strip. Every cell draws the chart over the rows it holds, so a cell
whose level combination has no rows stays blank.

```emo
plot.svg(plot.scatter(meals, { "x": "bill", "y": "tip", "color": "day", "facet_col": "time" }))
plot.svg(plot.hist(exam, { "x": "score", "facet_row": "class" }))
```

The panels compare: the figure keeps `Share.all`, so every panel draws
on the union of the panels' domains (the matrix charts keep their own
cell grids under `Share.none`); each panel is titled from its levels —
`time = Lunch`, both facets joined with a comma; the axis labels sit
at the outer edge only, the x label on the bottom row and the y label
on the first column; and the panels' own legends give way to one
legend for the whole figure, at its right, listing every labeled mark
once by label. The same level is the same color in every panel, since
the levels sort over the whole table. A facet channel handed a number
column raises, like the grouping channels.

## Panel grids by hand

The figure carries the grid; the chart functions fill it. A hand-built
grid assembles its own axes instead:

```emo
const quarters = ["Q1", "Q2", "Q3", "Q4"]
const units_ax = plot.axes().with_x_label("Quarter").with_y_label("Units").with_marks([plot.mark.bar(quarters, [20.0, 28.0, 26.0, 34.0])])
const revenue_ax = plot.axes().with_x_label("Quarter").with_y_label("Revenue").with_marks([plot.mark.bar(quarters, [180.0, 220.0, 190.0, 260.0])])
const costs_ax = plot.axes().with_x_label("Quarter").with_y_label("Costs").with_marks([plot.mark.bar(quarters, [120.0, 160.0, 140.0, 190.0])])

plot.svg(plot.figure().with_title("Quarterly review").with_grid(2, 2).with_axes([units_ax, revenue_ax, costs_ax]))
```

Cells fill row major. A grid with more cells than axes leaves the tail
blank; more axes than cells raises, as does a row or column count
below 1. An axes with no marks is a blank cell — it draws nothing and
stays out of the shared domain, so a sparse slot costs nothing.
`Share.all` — the default — resolves every panel's own domain first
and then draws each on the union, so panels compare against one scale;
`Share.none` leaves each panel on its own. `with_shared_legend(true)`
draws one legend for the whole figure at its right — every labeled
mark across the panels, once by label — and takes that column out of
the grid's width; the panels' own legends are usually switched off
beside it.

Every dataset chart has a single-panel form that answers the `Axes`
alone, ready for a hand-built grid: `scatter_axes`, `line_axes`,
`reg_axes`, `hist_axes`, `kde_axes`, `ecdf_axes`, `box_axes`,
`violin_axes`, `bar_axes`, `count_axes`, `strip_axes`, `point_axes`,
`heatmap_axes`, and `clustermap_axes` — same table, same channel
mapping, one axes instead of a figure, with `Axes.with_title` the
panel title.

```emo
const ax = plot.scatter_axes(meals, { "x": "bill", "y": "tip", "color": "day" }).with_title("Weekend bills")
plot.svg(plot.figure().with_axes([ax]))
```

## Themes, palettes, and colormaps

A theme dresses the whole figure: the background and foreground inks,
the grid, axis, title, and label styles, the palette and colormap the
`color` channel resolves through, the spacing between panels, and the
default size a `figure()` starts at.

```emo
def theme() Theme
def dark_theme() Theme
```

`figure()` builds the default light theme; `with_theme` swaps one in:

```emo
plot.svg(plot.figure().with_theme(plot.dark_theme()).with_axes([dark_ax]))
```

`Theme` refines field by field — `with_background`, `with_foreground`,
`with_grid`, `with_axis`, `with_title`, `with_label`, `with_palette`,
`with_cmap`, `with_spacing` — over the fields `background`,
`foreground`, `grid`, `axis`, `title`, `label`, `palette`, `cmap`,
`spacing`, and `width` / `height`. The piece styles:

```emo
def grid_style() GridStyle   // color, width, dash, visible — with_* for each
```

`GridStyle` draws the gridlines behind the marks — horizontal at the y
ticks, vertical at the x ticks; `with_visible(false)` draws no grid at
all. `AxisStyle` is the axes frame — the bottom spine's `color` and
`width`, the tick marks' `tick_len`, and the `label_size` of the x/y
axis labels — refined through `with_color`, `with_width`,
`with_tick_len`, `with_label_size`. `TextStyle` dresses a piece of
figure text — `color`, `size`, `anchor` (`Anchor.start` / `middle` /
`end`), and `weight` (`Weight.regular` / `bold`) — through `with_color`,
`with_size`, `with_anchor`, `with_weight`.

The categorical palette:

```emo
def palette() Palette   // the five mark families' default colors
```

`Palette` wraps a list of colors and answers `color(i)` wrapping
around the list; `with_colors` replaces it. An empty list raises.

The continuous colormaps:

```emo
def viridis() Colormap
def sequential() Colormap
def diverging() Colormap
```

`Colormap` pins stops at positions across 0.0–1.0 and answers `at(t)`
— clamped to that span — by interpolating the bracketing stops'
channels in `Float64`; `with_stops` replaces them. An empty list, an
out-of-range position, or a descending position raises. The built-ins
approximate their targets with five stops each.

**Colors are `(Int64, Int64, Int64)` sRGB triples**, each channel
0–255:

```emo
def rgb(r Int64, g Int64, b Int64) (Int64, Int64, Int64)
```

`plot.rgb` builds one with the range checked — an out-of-range channel
raises — and a raw triple is accepted and validated when it is drawn.
Opacity is a separate `Float64` on the style; it rides every style but
is not rendered yet. The theme only supplies defaults — what a mark
finally draws is still a `plot.mark` style value.

## Marks: drawing without a table

`plot.mark` is the layer under the charts: a mark is a value that
knows how to draw itself into an axes and what its data spans. When
the data is already in arrays — or the chart layer does not draw the
thing you want — build the marks yourself:

```emo
def bar(labels Array[String], values Array[Float64]) Bar
def line(x Array[Float64], y Array[Float64]) Line
def scatter(x Array[Float64], y Array[Float64]) Scatter
def area(x Array[Float64], y Array[Float64]) Area
def hist(values Array[Float64], bins Int64) Hist
def band(xs Array[Float64], lo Array[Float64], hi Array[Float64]) Band
def box(labels Array[String], lows Array[Float64], q1s Array[Float64], medians Array[Float64], q3s Array[Float64], his Array[Float64], flier_xs Array[Float64], fliers Array[Float64]) BoxPlot
def violin(labels Array[String], points Int64, xs Array[Float64], density Array[Float64]) Violin
def strip(labels Array[String], xs Array[Float64], ys Array[Float64]) Strip
def point(labels Array[String], xs Array[Float64], ys Array[Float64]) Point
```

Each factory validates its arrays and answers a mark carrying its
default style; `with_style` swaps the style, and the style's `with_*`
methods refine it — all copies, never mutations:

```emo
plot.mark.line(years, revenue).with_style(
  plot.mark.line_style().with_dash(plot.mark.Dash.dashed).with_color(plot.rgb(47, 111, 179)))
```

### bar

`bar(labels, values)` draws one bar per label at its band center, on
the zero baseline. `BarStyle` carries the fill `color`, the band
fraction `width` (0.8 by default), `opacity`, and `label`, refined
through `with_color`, `with_width`, `with_label`.

### line

`line(x, y)` strokes a polyline through the points and stamps its
marker shape at every point. `LineStyle` carries `color`, `width`,
`dash`, `marker`, `marker_size`, `opacity`, and `label` — refined
through the matching `with_*` methods:

```emo
enum Dash { solid, dashed, dotted, dash_dot }
enum Marker { none, circle, square, triangle, diamond, cross, plus }
```

### scatter

`scatter(x, y)` stamps its marker at every point and connects nothing.
`ScatterStyle` carries `color`, `size`, `marker`, `opacity`, and
`label`; a scatter with `Marker.none` draws nothing. A scatter also
carries per-point color and size overrides — the arrays the dataset
charts read their `color` and `size` channels through; a point past an
override's end draws the style's value:

```emo
plot.mark.Scatter.new(x: xs, y: ys, style: plot.mark.scatter_style(), colors: point_colors, sizes: point_sizes)
```

### area

`area(x, y)` fills the closed region between its polyline and the zero
baseline, negative values dipping below it. `AreaStyle` carries the
fill `color`, `edge_color` and `edge_width` (a stroke along the curve
itself; the default `0.0` draws no edge), `opacity`, and `label`.

### hist

`hist(values, bins)` counts its values into equal-width bins spanning
the data and tiles them as bars on the zero baseline. A value equal to
the maximum counts into the last bin; identical values pile into it
too, since their span collapses to zero. `bins < 1` raises.
`HistStyle` carries the fill `color`, the `edge_color` and
`edge_width` of the bar outlines (white by default at width 1.0),
`opacity`, and `label`. `bin_index(v, lo, span, bins)` answers the bin
a value falls into — the counting rule, on its own.

### band

`band(xs, lo, hi)` fills the region between a lower and an upper curve
over one shared run of xs — one polygon, the upper curve read forward
and the lower one back. The factory checks that the low and high
arrays match the xs and that the xs ascend. `BandStyle` carries the
fill `color`, `opacity`, and `label`.

### box and violin

`box(labels, lows, q1s, medians, q3s, his, flier_xs, fliers)` draws
one box per label at its band center — the whiskers, the filled
quartile box, the median line, and the fliers stamped beyond the
whiskers. The five statistics arrays share the labels' length and the
flier arrays their own; the factory checks. `BoxStyle` carries the
fill and edge `color`s, `edge_width`, the band fraction `width`
(default 0.5), `opacity`, and `label`.

`violin(labels, points, xs, density)` mirrors a density per label: the
grids and densities are flat, one run of `points` entries per label,
the densities fractions of the band's half width (0.0 to 1.0), and the
arrays carry exactly `labels × points` entries or the factory raises.
`ViolinStyle` carries the fill `color`, the band fraction `width`
(default 0.9), `opacity`, and `label`.

### strip and point

`strip(labels, xs, ys)` is a scatter over the categorical face: raw
points at their bands' centers, the xs band coordinates (0.5, 1.5, …)
and the arrays sharing their length; its style is a `ScatterStyle`.
`point(labels, xs, ys)` walks the bands — one value per label,
connected in band order and stamped with the style's marker; its
style is a `LineStyle` (the line connects, the marker stamps) and
`point_style()` answers that default.

### heatmap

The heatmap mark is a grid of pre-colored cells — the values row major
over the column names across and the row names down, each cell's color
handed in by the caller, so the mark knows nothing of colormaps:

```emo
plot.mark.Heatmap.new(col_names: cols, row_names: rows, values: vals, colors: cell_colors)
```

It is the one mark that labels both axes — the column names ride the
categorical x face and the row names the y face. It carries no style
and stays out of the legend.

### the Mark interface

A mark draws itself through one interface — `draw`, plus the data span
it asks the axes to cover: a continuous x and y range through `x_min`
/ `x_max` / `y_min` / `y_max`, the categorical x face through `bands`
and `x_labels`, the categorical y face through `y_labels` (empty for
every built-in mark but the heatmap), and the legend pair
`legend_label` / `legend_sample`. A new mark family is a new class
that satisfies that shape and joins `with_marks` like any other.

With `legend` on (the default), the labeled marks list into a legend
in the plot's top-right corner — marks array order, drawn last. Marks
whose label is empty stay out of it.

## What raises

The package follows the standard library's convention: expected
failures are values, violations raise — and a raise ends the process.
The raises are contract violations, each with a `plot:`-prefixed
message:

- **table shape** — a name claimed by both kinds, columns of different
  lengths, a numeric column without its presence column, a stray
  presence column, or one whose length disagrees;
- **table reads** — an unknown column name, or a name carried under
  the other kind;
- **channels** — an unknown channel, a channel the chart does not
  read, a missing `x` or `y`, a grouping or facet channel handed a
  number column, a `color` / `size` number column with no observed
  values;
- **chart shapes** — no drawable rows, a `reg` with fewer than two, a
  `kde` or `violin` over values that do not spread, a matrix chart
  with no number column or no rows;
- **mark factories** — array lengths that disagree, a band's xs that
  do not ascend, `hist` bins below 1;
- **figure assembly** — a grid below 1 × 1, more axes than cells, a
  fixed domain with `lo >= hi`, a log axis over nonpositive values;
- **colors** — an `rgb` channel outside 0–255, an empty palette,
  colormap stops that are empty, out of range, or not ascending.

When the data comes from outside the program instead of a literal,
build the table only after the read has been reconciled — the data
read step belongs to the reader, and a table that disagrees with
itself is always a bug in the caller.
