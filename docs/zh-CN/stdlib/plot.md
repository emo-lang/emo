# `plot` 包

声明式二维绘图包。一张图就是一个值——`Figure` 持有 `Axes`,每个 `Axes` 持有 mark——一次调用即渲染成 SVG。全部是纯 Emo,写在共享运行时之上,所以五个宿主目标逐字节相同。

## 使用这个包

```emo
require "plot"
```

标准库随编译器一起发布,但它的包和其他依赖一样带版本:`require "plot"` 需要在 manifest 的 `deps` 块里钉上 `"plot" = "0.1.0"`。

这个包有两个公开模块:`plot`(图的表面)与 `mark`(mark)。一个 `require "plot"` 把两者都带进作用域。

## 表面

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

`figure()` 与 `axes()` 建出默认值,`with_*` 细化一个值。类是不可变的,所以每个 `with_*` 返回一个新值;整张图就是一个普通的值图。`svg(fig)` 遍历它,返回 SVG 文档(`String`)。

```emo
enum Scale { linear, log }
enum Domain { auto, fixed }
enum Share { all, none }
```

## mark

mark 在 `plot.mark` 子模块里——包的子模块以包的短名为前缀寻址。T0 有柱状、折线、散点、面积四个 mark:

```emo
def bar(labels Array[String], values Array[Float64]) Bar
def bar_style() BarStyle

def line(x Array[Float64], y Array[Float64]) Line
def line_style() LineStyle

def scatter(x Array[Float64], y Array[Float64]) Scatter
def scatter_style() ScatterStyle

def area(x Array[Float64], y Array[Float64]) Area
def area_style() AreaStyle
```

mark 也是值。`Bar.with_style(s BarStyle)` 以及样式上的 `with_color` / `with_width` / `with_label` 细化它,不改动任何东西:

```emo
plot.mark.bar(months, sales).with_style(
  plot.mark.bar_style().with_color((192, 57, 43)).with_width(0.6))
```

折线沿 `(x, y)` 点画一条描边折线,并在每个数据点盖上 marker 形状。`LineStyle` 携带 `color`、`width`、`dash`(`Dash.solid`/`dashed`/`dotted`/`dash_dot`)、`marker`(`Marker.none`/`circle`/`square`/`triangle`/`diamond`/`cross`/`plus`)、`marker_size`、`opacity` 与 `label`,用同一套 `with_*` 拷贝方法细化:

```emo
plot.mark.line(years, revenue).with_style(
  plot.mark.line_style().with_dash(plot.mark.Dash.dashed)
    .with_marker(plot.mark.Marker.circle))
```

散点在每个 `(x, y)` 点盖上 marker,不连任何线。`ScatterStyle` 携带 `color`、`size`、`marker`、`opacity` 与 `label`——marker 词汇与折线用的是同一个 `Marker` 枚举,`Marker.none` 的散点什么都不画。

面积填充折线与零基线之间的闭合区域,负值落到基线下方。`AreaStyle` 携带 `color`(填充)、`edge_color` 与 `edge_width`(沿曲线本身的描边;默认 `0.0` 宽度不画边)、`opacity` 与 `label`。

**颜色是 `(Int64, Int64, Int64)` 的 sRGB 三元组**,每通道 0–255。不透明度是样式上单独的 `Float64`,绝不煍进三元组。它随每个样式携带,但**尚未渲染**——渲染器图元还没有不透明度旋钮。

mark 通过 `Mark` 接口把自己画进坐标轴——`draw`,加上它要求坐标轴覆盖的数据跨度:连续的 x、y 范围走 `x_min`/`x_max`/`y_min`/`y_max`,类别的 x 面走 `bands` 和 `x_labels`——所以新增一种 mark 就是新增一个满足该形状的类。

## 完整例子

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

`examples/plot_demo` 就是这段程序。

## 输出

`svg` 交出文档;写进文件是调用方的事。这个包在五个目标上都能跑,而文件 IO 属于只有原生目标的 `file` 与 `os` 包——在原生目标上,`file.write("chart.svg", plot.svg(chart))`。

文本交给查看器:每个标签都是 SVG `<text>` 元素,所以这个包不带字体引擎。坐标与数值用解释器的浮点渲染来格式化,这正是各目标字节相同的原因。

## 目标与已落地部分

目标:全部五个(`ocaml`、`c`、`typescript`、`wasm`、`beam`)。

T0——今天已有的——是柱状、折线、散点、面积 mark、带 nice-number 刻度的线性坐标轴、标题、轴标签,以及 SVG 输出。表面上还带着的其余部分是**预留、尚未渲染**的:`Scale.log`、`Domain`、经 `Share` 的分面、图例,以及直方图 mark。SVG 渲染器位于一个内部的 `Renderer` 契约之后,所以终端或栅格后端以后可以在不扰动图与 mark 的前提下接上。

另见:`examples/plot_demo`,以及设计笔记 [`docs/zh-CN/visualization.md`](../visualization.md)。
