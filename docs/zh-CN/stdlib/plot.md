# `plot` 包

声明式二维绘图包。一张图就是一个值——`Figure` 持有 `Axes`,每个 `Axes` 持有 mark——一次调用即渲染成 SVG。全部是纯 Emo,写在共享运行时之上,所以包所声明的那五个托管目标逐字节相同。

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
def with_x_scale(s Scale) Axes
def with_y_scale(s Scale) Axes
def with_x_domain(a Float64, b Float64) Axes
def with_y_domain(a Float64, b Float64) Axes
def with_grid_style(s GridStyle) Axes
def with_marks(m Array[Mark]) Axes
def with_legend(on Bool) Axes

def grid_style() GridStyle
```

`figure()` 与 `axes()` 建出默认值,`with_*` 细化一个值。类是不可变的,所以每个 `with_*` 返回一个新值;整张图就是一个普通的值图。`svg(fig)` 遍历它,返回 SVG 文档(`String`)。

```emo
enum Scale { linear, log }
enum Domain { auto, fixed }
enum Share { all, none }
```

刻度枚举经 `with_x_scale` / `with_y_scale` 落到坐标轴上。log 轴横跨整十进位:域钳到包住数据的那两个十次方,刻度落在每十进位的 1-2-5 步上(跨度不超过两个十进位时 2 和 5 步才加入),非正值或非正的域直接 raise——log 轴只映射正数,没有例外。

域要么是 `Domain.auto`——从每个 mark 的跨度推断,也是默认——要么经 `with_x_domain(a, b)` / `with_y_domain(a, b)` 落成 `Domain.fixed`,原样携带调用者给的两端:刻度尊重固定后的两端,倒置的域(`lo >= hi`)直接 raise。mark 目前不会裁剪进坐标轴矩形,固定域之外的数据会画出界外。

网格画在 mark 背后:y 刻度上的横线与 x 刻度上的竖线,由 `GridStyle` 定样式——`color`、`width`、`dash`(与折线 mark 同一个 `Dash` 枚举)、`visible`(`false` 时完全不画网格)。默认是宽度 1.0 的浅色实线。

## mark

mark 在 `plot.mark` 子模块里——包的子模块以包的短名为前缀寻址。T0 有柱状、折线、散点、面积、直方图五个 mark:

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

直方图把值数进横跨数据的等宽箱,把箱子作为柱子铺在零基线上。等于最大值的数落进最后一箱;全同值跨度塌缩为零,也堆进最后一箱。`bins < 1` 是契约违例,直接 raise。`HistStyle` 携带 `color`(填充)、`edge_color` 与 `edge_width`(柱子描边;默认白色、宽度 1.0)、`opacity` 与 `label`。

**颜色是 `(Int64, Int64, Int64)` 的 sRGB 三元组**,每通道 0–255。不透明度是样式上单独的 `Float64`,绝不煍进三元组。它随每个样式携带,但**尚未渲染**——渲染器图元还没有不透明度旋钮。

mark 通过 `Mark` 接口把自己画进坐标轴——`draw`,加上它要求坐标轴覆盖的数据跨度:连续的 x、y 范围走 `x_min`/`x_max`/`y_min`/`y_max`,类别的 x 面走 `bands` 和 `x_labels`——还要喂养图例:`legend_label()` 应答样式上的 label,`legend_sample` 画该族自己的样例。新增一种 mark 就是新增一个满足该形状的类。

`legend` 开着时(默认),带 label 的 mark 列进绘图区右上角的图例——按 marks 数组序、最后绘制,背后垫一块白板。label 为空的 mark 不进图例。条目的偏移用近似的单字符宽度估算,因为这个包不带字体度量。

## 完整例子

```emo
require "plot"

const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun"]
const sales = [12.0, 18.0, 15.0, 24.0, 21.0, 30.0]

const ax = plot.axes().with_x_label("Month").with_y_label("Sales").with_marks([plot.mark.bar(months, sales)])
const chart = plot.figure().with_title("Monthly sales").with_axes([ax])

println(plot.svg(chart))
```

`examples/plot_demo` 就是这段程序。

## 输出

`svg` 交出文档;写进文件是调用方的事。这个包在它声明的五个托管目标上都能跑,而文件 IO 属于只有原生目标的 `file` 与 `os` 包——在原生目标上,`file.write("chart.svg", plot.svg(chart))`。

文本交给查看器:每个标签都是 SVG `<text>` 元素,所以这个包不带字体引擎。坐标与数值用解释器的浮点渲染来格式化,这正是各目标字节相同的原因。

## 目标与已落地部分

目标:包所声明的五个托管目标——`c`、`ocaml`、`typescript`、`wasm`、`beam`。这份清单是包的,不是语言的:解释器直接求值程序、不产生产物;完整的构建目标集合还有 `browser` 和 freestanding 的 `riscv64`,后者因为拒绝 `Map` 而留在这份清单之外。逐个目标的完整故事见 [`demo-targets.md`](../../demo-targets.md)。

T0——今天已有的——是柱状、折线、散点、面积、直方图 mark、带 nice-number 刻度的线性坐标轴、标题、轴标签,以及 SVG 输出。两条轴都按 mark 声明的跨度定标:y 域覆盖每个 mark 的范围,x 轴在没有 mark 提供类别标签时打数字刻度。表面上还带着的其余部分是**预留、尚未渲染**的:经 `Share` 的分面。SVG 渲染器位于一个内部的 `Renderer` 契约之后,所以终端或栅格后端以后可以在不扰动图与 mark 的前提下接上。

另见:`examples/plot_demo`,以及设计笔记 [`docs/zh-CN/visualization.md`](../visualization.md)。
