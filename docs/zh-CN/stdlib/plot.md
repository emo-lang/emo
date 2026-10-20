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

`figure()` 与 `axes()` 建出默认值,`with_*` 细化一个值。类是不可变的,所以每个 `with_*` 返回一个新值;整张图就是一个普通的值图。`svg(fig)` 遍历它,返回 SVG 文档(`String`)。

```emo
enum Scale { linear, log }
enum Domain { auto, fixed }
enum Share { all, none }
```

刻度枚举经 `with_x_scale` / `with_y_scale` 落到坐标轴上。log 轴横跨整十进位:域钳到包住数据的那两个十次方,刻度落在每十进位的 1-2-5 步上(跨度不超过两个十进位时 2 和 5 步才加入),非正值或非正的域直接 raise——log 轴只映射正数,没有例外。

域要么是 `Domain.auto`——从每个 mark 的跨度推断,也是默认——要么经 `with_x_domain(a, b)` / `with_y_domain(a, b)` 落成 `Domain.fixed`,原样携带调用者给的两端:刻度尊重固定后的两端,倒置的域(`lo >= hi`)直接 raise。mark 目前不会裁剪进坐标轴矩形,固定域之外的数据会画出界外。

网格画在 mark 背后:y 刻度上的横线与 x 刻度上的竖线,由主题的 `GridStyle` 定样式——`color`、`width`、`dash`(与折线 mark 同一个 `Dash` 枚举)、`visible`(`false` 时完全不画网格)。默认是宽度 1.0 的浅色实线,经 `Theme.with_grid` 细化。

## 缺失数字

缺失的数字用 presence 标签表示,不用 `NaN`——beam 目标的 Erlang 浮点装不下它。数值列在值数组里保留自己的槽位,由一条并行的 presence 数组指出空槽:

```emo
enum Presence { present, absent }
```

统计读一列时连同它的 presence 数组一起读,跳过 `absent` 的条目,一个缺失值损失的是一个观测,而不是整列。并行的 presence 列搭载数据集层建出的 `Table` 而来(`plot.table` / `plot.table_missing`)。

## 表

数据集图读的是 `Table`——这个包拥有的唯一数据结构:列式、极简、只能从两个带校验的构造器来。

```emo
def table(numbers Map[String, Array[Float64]], labels Map[String, Array[String]]) Table
def table_missing(numbers Map[String, Array[Float64]], presence Map[String, Array[Presence]], labels Map[String, Array[String]]) Table
```

数值列与类别列都放在以列名作键的 map 里,所有列共享同一个行数。`table` 建出全在场的表——每个数值列旁边都配好一条 presence 数组;`table_missing` 收调用者写好的 presence 列。两者都校验形状,违例即 raise:手写的表字面量是程序员的意图,两列长度不一、一个名字被两种列同时认领、数值列没有 presence 列——或多出一条游离的 presence 列、或长度与自己的数值对不上——都是违约。

访问按列的种类走:

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

`number(name)` 答数值列的值,`presence(name)` 答它旁边那条并行的 presence 数组,`label(name)` 答类别列的值;`rows` 是行数。读一个表里属于另一种类的名字、或表里没有的名字,都 raise。两副空 map 是零行的表。

`Table` 住在 `plot` 根上,不许长成 data-frame:以后加的数据入口(CSV 或 JSON 读取器)返回 `(R.error, reason)` 而不 raise,因为从外面读进来的数据不是程序员的意图。

## 通道

数据集图用通道映射点名自己的列——一个 `Map[String, String]`,键是通道、值是列名,少写的键就是没用到的通道:

```emo
{ "x": "total_bill", "y": "tip", "color": "time" }
```

词表是八个词——`x`、`y`、`color`、`size`、`marker`、`dash`、`facet_row`、`facet_col`——映射里出现别的词直接 raise。每个图只读它支持的通道,一张图自带支持清单,映射里出现它不读的通道同样 raise。通道的值只能是列名:常量属于 mark 样式,绝不进映射。

`color` 通道按列的种类分派,这份分派本身就是一个独立的函数:

```emo
plot.channel_colors(tips, "time", plot.theme())
```

类别列按水平的排序位置从主题 palette 取色——水平先去重、再按字节排序;数值列把在场值在自己跨度上归一化、从主题 colormap 取色,所有值都相同的列落在 map 的低端。缺席的槽位同样以低端占位,因为图表层永远不会画它。未知的列名直接 raise。

## 关系型图表

数据集图表每种一个函数:每个函数接表和通道映射,应答一整个 `Figure`——一个 axes,装着映射建出的 mark,axes 用通道的列名做标签——`svg` 渲染它,`with_*` 方法像任何图一样细化它。

```emo
def scatter(t Table, ch Map[String, String]) Figure
def line(t Table, ch Map[String, String]) Figure
def reg(t Table, ch Map[String, String]) Figure
```

`x` 与 `y` 通道必备,而且都必须是数值列——类别列在那里会经表自己的种类检查 raise。任一列缺席的行从图里剔除;一张图剔完之后没有可画的行也直接 raise。其余通道按图而异,映射里出现该图不读的通道直接 raise:

- `scatter` 读 `color`、`size`、`marker`。
- `line` 读 `color`、`marker`、`dash`。
- `reg` 只读那一对。

`color` 通道按列的种类分派,与 `plot.channel_colors` 应答的是同一份分派。类别列把行拆成每个水平一条系列——颜色按水平的排序位置取自主题 palette,图例里以该水平命名,两个分组通道共享的水平只命名一次。数值列(scatter 的)把每个点按它在列的观察跨度上的位置、经主题 colormap 取色。`size` 通道把每个点缩放到样式尺寸的一半到一倍半,归一化同样跨列的观察跨度。`marker` 与 `dash` 通道读类别列,按水平挑选点的形状——circle、square、triangle、diamond、cross、plus,绕列表循环——与描边样式——solid、dashed、dotted、dash dot。折线图按行自身的顺序画每条系列:表的行序就是意图,图不排序。分组的颜色在图构建时经默认主题解析;事后的 `with_theme` 只重新装扮图自己的墨色。

```emo
const meals = plot.table(
  { "bill": [16.99, 10.34, 21.01, 23.68], "tip": [1.01, 1.66, 3.50, 3.31],
    "party": [2.0, 3.0, 2.0, 4.0] },
  { "day": ["Sun", "Sat", "Sun", "Sat"] }
)
plot.svg(plot.scatter(meals, { "x": "bill", "y": "tip", "color": "day", "size": "party" }))
```

`reg` 在点之上拟合最小二乘直线,并在其下画出均值响应的 95% 置信带——band 先画,点落在它上面。band 是一块 `plot.mark.band`,以 band 样式填充,在保留跨度上取五十个网格点;拟合线以 `fit` 进图例,band 以 `95% band` 进图例。可画的行至少两行,x 列的值不铺开时经拟合直接 raise。

分面通道通过词表检查、但在图表层长出面板拆分之前直接 raise——按列水平拆分数据、逐面板水平标注、单份共享图例是图表层剩下的工作。其余违例直接 raise:未知通道、该图不读的通道、缺 `x` 或 `y`、分组通道拿到数值列、`size` 或数值 `color` 列没有在场值、图没有可画的行、`reg` 少于两行。

## 分布型图表

`hist`、`kde`、`ecdf` 读一个数值列、按 `color` 的每个水平画一个 mark——拆分方式与关系型一致;`box` 与 `violin` 把数值列按类别列分组:

```emo
def hist(t Table, ch Map[String, String]) Figure
def kde(t Table, ch Map[String, String]) Figure
def ecdf(t Table, ch Map[String, String]) Figure
def box(t Table, ch Map[String, String]) Figure
def violin(t Table, ch Map[String, String]) Figure
```

`hist` 把保留值数进横跨共同范围的等宽箱——箱数取计数的平方根、至少一箱——每个水平一个直方图、共享同一套网格,水平之间可比。`kde` 每个水平画一条密度曲线,带宽由 Silverman 经验法则按该水平自己的值给出,网格两端各越过三个带宽、取一百个点。`ecdf` 每个水平画一条阶梯线,每个值的累积比例在值处抬升。三者的 y 轴标签分别是 `count`、`density`、`proportion`。

`box` 与 `violin` 落在 `x` 列的水平上——那里给数值列直接 raise,箱子落在水平上、不落在数字上。每个水平的 `y` 值经 Tukey 统计概括:`box` 画须、填充的四分位箱、中位线,以及须外盖章的离群点;`violin` 每个水平画一条镜像密度,带宽与网格形状与 `kde` 图同源,所有密度按整行归一化、小提琴之间可比。没有在场 `y` 值的水平不出现;值不铺开的水平没有密度,直接 raise。`box` 与 `violin` 目前不读 `color` 通道。

单列图需要 `x` 通道,分组对需要两个都给;缺席行照旧剔除、没有可画行的图直接 raise,未知通道、该图不读的通道、`color` 映射到数值列同样 raise。常数列没有密度:`kde` 图直接 raise,不画一根针。

## 主题

主题装扮整张图:背景与前景墨色、网格、坐标轴、标题、标签样式,color 通道经过的 palette 与 colormap、面板间距,以及 `figure()` 出发的默认尺寸。`figure()` 建出默认的浅色主题,`with_theme` 把另一套换上图:

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

`Theme` 携带 `background` 与 `foreground`(sRGB 三元组)、`grid`(一个 `GridStyle`)、`axis`(一个 `AxisStyle`:轴线颜色与宽度、刻度线长度、x/y 轴标签字号)、`title` 与 `label`(两个 `TextStyle`:颜色、字号、锚点、字重)、`palette`、`cmap`、`spacing` 与 `width`/`height`。每个字段都有对应的 `with_*` 拷贝方法:`with_background`、`with_foreground`、`with_grid`、`with_axis`、`with_title`、`with_label`、`with_palette`、`with_cmap`、`with_spacing`。

`Palette` 包一组颜色,`color(i)` 按列表取模应答。`Colormap` 把 stops 钉在 0.0–1.0 的位置上,`at(t)` 把 `t` 钳进该区间、按夹住它的两个 stops 在 `Float64` 里插值应答;空列表、越界位置或倒序位置直接 raise。内置的都是起点:`palette()` 列出五个 mark 族的默认色,`viridis()`/`sequential()`/`diverging()` 各用五个 stops 逼近各自的目标。

主题只供默认值;mark 最终画什么,仍是它自己的 `plot.mark` 样式值。

## 面板网格

`Figure.grid` 把图里的 axes 排成 rows × cols 的面板,面板之间隔主题间距;`with_grid(rows, cols)` 负责设置,默认的 `(1, 1)` 就是一块全尺寸面板。格子按行优先填充,格子多于 axes 时尾部留空;axes 多于格子直接 raise,行或列数小于 1 同样 raise。图题坐在网格上方,只画一次。

`Share.all`——默认——先把每个面板自己的域解出来,再让每个面板都画在并集上,面板与面板因此共享同一把标尺;`Share.none` 让各面板各用各的。

```emo
plot.figure().with_title("Quarterly review").with_grid(2, 2)
  .with_axes([units_ax, revenue_ax, costs_ax])
```

把一份数据按某列的水平拆成多块、逐面板用水平标注、只画一份共享图例,是图表层的工作——图携带网格,图表函数往里填。

## mark

mark 在 `plot.mark` 子模块里——包的子模块以包的短名为前缀寻址。柱状、折线、散点、面积、直方图五个 mark 是 T0 的,`band` 为回归图加入:

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

散点在每个 `(x, y)` 点盖上 marker,不连任何线。`ScatterStyle` 携带 `color`、`size`、`marker`、`opacity` 与 `label`——marker 词汇与折线用的是同一个 `Marker` 枚举,`Marker.none` 的散点什么都不画。散点还带逐点的颜色与尺寸覆盖——正是数据集图表读取 `color` 与 `size` 通道的那两个数组;越过覆盖数组末端的点画样式的值。

面积填充折线与零基线之间的闭合区域,负值落到基线下方。`AreaStyle` 携带 `color`(填充)、`edge_color` 与 `edge_width`(沿曲线本身的描边;默认 `0.0` 宽度不画边)、`opacity` 与 `label`。

直方图把值数进横跨数据的等宽箱,把箱子作为柱子铺在零基线上。等于最大值的数落进最后一箱;全同值跨度塌缩为零,也堆进最后一箱。`bins < 1` 是契约违例,直接 raise。`HistStyle` 携带 `color`(填充)、`edge_color` 与 `edge_width`(柱子描边;默认白色、宽度 1.0)、`opacity` 与 `label`。

band 在同一段升序 `xs` 上填充下曲线与上曲线之间的区域——一个多边形,上曲线正向读、下曲线反向读——回归图的置信带画的就是它。工厂检查低、高数组与 xs 等长且 xs 升序。`BandStyle` 携带 `color`(填充)、`opacity` 与 `label`。

箱线一排落在类别面上——每个标签一个箱、在它的 band 中心:须、填充的四分位箱、中位线、须外盖章的离群点。五个统计数组与 labels 等长,离群点两个数组彼此等长;工厂都检查。`BoxStyle` 携带填充与边缘 `color`、`edge_width`、band 占比 `width`、`opacity` 与 `label`。

小提琴一排按标签镜像密度——网格与密度都是扁平数组,每个标签一段 `points` 个点,密度是 band 半宽的分数。`ViolinStyle` 携带 `color`(填充)、band 占比 `width`、`opacity` 与 `label`。

**颜色是 `(Int64, Int64, Int64)` 的 sRGB 三元组**,每通道 0–255。`plot.rgb(r, g, b)` 构造经过范围检查的三元组——越界通道直接 raise;裸三元组也接受,在绘制时校验。不透明度是样式上单独的 `Float64`,绝不煍进三元组。它随每个样式携带,但**尚未渲染**——渲染器图元还没有不透明度旋钮。

mark 通过 `Mark` 接口把自己画进坐标轴——`draw`,加上它要求坐标轴覆盖的数据跨度:连续的 x、y 范围走 `x_min`/`x_max`/`y_min`/`y_max`,类别的 x 面走 `bands` 和 `x_labels`——还要喂养图例:`legend_label()` 应答样式上的 label,`legend_sample` 画该族自己的样例。新增一种 mark 就是新增一个满足该形状的类。

`legend` 开着时(默认),带 label 的 mark 列进绘图区右上角的图例——按 marks 数组序、最后绘制,背后垫一块主题背景色的面板、按主题间距内缩。label 为空的 mark 不进图例。条目的偏移用近似的单字符宽度估算,因为这个包不带字体度量。

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

T0——今天已有的——是柱状、折线、散点、面积、直方图 mark、带 nice-number 刻度的线性坐标轴、标题、轴标签、刻度线、网格、装扮这一切的主题、数据集图表读取的带校验的 `Table`、通道词表与 `color` 通道的种类分派、关系型图表——`scatter`、`line`、`reg`,`band` mark 为回归图加入 `plot.mark`——分布型图表——`hist`、`kde`、`ecdf`、`box`、`violin`,`box` 与 `violin` mark 随之加入 `plot.mark`——还有 SVG 输出。两条轴都按 mark 声明的跨度定标:y 域覆盖每个 mark 的范围,x 轴在没有 mark 提供类别标签时打数字刻度。表面上还带着的其余部分是**预留、尚未渲染**的:类别与矩阵图表,以及图表层的那一半分面——按列水平拆分数据、逐面板水平标注、单份共享图例。mark 与坐标轴都经内部的 `Renderer` 接口绘制——`DrawContext` 携带的是一个 `Renderer`,不是具体的 SVG 类——所以终端或栅格后端以后可以在不扰动图与 mark 的前提下接上。

另见:`examples/plot_demo`,以及设计笔记 [`docs/zh-CN/visualization.md`](../visualization.md)。
