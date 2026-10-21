# `plot` 指南

如何用 `plot` 包画图——整个公开 API,按你要构建的东西分节组织。这个包是声明式的:一张图就是一个值,建一次,渲染多次。`Figure` 持有 `Axes`,每个 `Axes` 持有 mark,一次调用就把整张值图走成 SVG、终端文本或 PNG。全部是纯 Emo,所以五个托管目标逐字节相同。

一个 `require` 背后是三层:

- **图这一层**——`figure()` / `axes()` 与它们的 `with_*` 细化、给整张图定妆的主题、三个渲染入口;
- **数据集这一层**——一个带校验的 `Table`、八个词的通道词汇表、十四个直接回答整张图的图表函数;
- **mark 这一层**——`plot.mark`,手搭的 axes 在没有表可读时画的那些 mark。

简明的参考文档见 [`docs/zh-CN/stdlib/plot.md`](stdlib/plot.md);设计笔记见 [`docs/zh-CN/visualization.md`](visualization.md);覆盖每种图表的可运行程序见 `examples/plot_demo`。

## 入门

标准库随编译器一起发布,但它的包和其他依赖一样带版本——先在 manifest 里钉上版本再 `require`:

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

一个 `require "plot"` 把两个公开模块都带进作用域:`plot`(图的表面与数据集图表)和 `plot.mark`(mark)。所有类都不可变——`with_*` 方法返回一个新值、原值原封不动,所以图靠链式细化拼装,底下没有任何东西在你脚下变。

## 图与坐标轴

### 搭一张图

```emo
def figure() Figure
def axes() Axes
```

`figure()` 回答默认的图:主题的尺寸(640 × 480)、1 × 1 网格、`Share.all`、一个空 axes。`axes()` 回答默认的 axes:linear 刻度、auto 域、图例开、无标签、无 mark。两者都是起点——`with_*` 方法做细化:

```emo
// Figure——每个方法返回一个新的 Figure
with_title(t String)              // 画一次,在网格上方
with_size(w Float64, h Float64)   // 像素尺寸;默认 640 × 480
with_theme(t Theme)
with_grid(rows Int64, cols Int64) // 面板布局,默认 (1, 1)
with_axes(a Array[Axes])          // 行主序填进网格
with_share(s Share)               // Share.all(默认)或 Share.none
with_shared_legend(on Bool)       // 图右侧的一个图例
```

```emo
// Axes——每个方法返回一个新的 Axes
with_x_label(s String)
with_y_label(s String)
with_x_scale(s Scale)             // Scale.linear(默认)或 Scale.log
with_y_scale(s Scale)
with_x_domain(a Float64, b Float64)   // Domain.auto(默认)→ Domain.fixed
with_y_domain(a Float64, b Float64)
with_marks(m Array[Mark])
with_legend(on Bool)              // 默认开
with_title(s String)              // 面板自己的标题,居中
```

```emo
const ax = plot.axes().with_x_label("Temperature").with_y_label("Ice cream").with_marks([
  plot.mark.scatter([14.0, 16.0, 18.0, 21.0, 24.0], [8.0, 12.0, 14.0, 19.0, 26.0])
])
const fig = plot.figure().with_title("Ice cream vs temperature").with_axes([ax])
println(plot.svg(fig))
```

`Axes.with_title` 是面板自己的标题,画在它的绘图区上方居中——分面层靠它给面板落标题(见「分面」)。

### 刻度:linear 与 log

```emo
enum Scale { linear, log }
```

log 轴横跨整十进位:域钳到包住数据的那两个十次方,刻度落在每十进位的 1-2-5 步上(跨度不超过两个十进位时 2 和 5 步才加入),非正值或非正的域直接 raise——log 轴只映射正数,没有例外。

```emo
const views_ax = plot.axes().with_x_label("Day").with_y_label("Views").with_y_scale(plot.Scale.log).with_marks([
  plot.mark.line([1.0, 2.0, 3.0, 4.0], [10.0, 120.0, 900.0, 8500.0])
])
```

### 域:auto 与 fixed

```emo
enum Domain { auto, fixed }
```

`Domain.auto`——默认——从每个 mark 声明的范围推断每根轴的跨度,两根轴都缩放到画上去的东西。固定域原样携带调用者给的两端;刻度尊重它们,倒置的域(`lo >= hi`)直接 raise。mark 目前不会裁剪进坐标轴矩形,固定域之外的数据会画出界外。

```emo
const fixed_ax = plot.axes().with_x_label("Year").with_y_label("Revenue").with_y_domain(40.0, 80.0).with_marks([
  plot.mark.line([2020.0, 2021.0, 2022.0, 2023.0], [42.0, 51.0, 47.0, 62.0])
])
```

## 输出格式

同一份图值有三条渲染路——一次 `render` 遍历,三个渲染器:

```emo
def svg(fig Figure) String       // 一份 SVG 文档
def terminal(fig Figure) String  // 给终端看的盲文文本
def png(fig Figure) Bytes        // 一个 PNG 文件
```

`svg` 把文档当作 `String` 交回;写进文件是调用者的事。这个包跑在五个托管目标上,而文件 IO 属于仅原生的 `file` 与 `os` 包——在原生目标上,`file.write("chart.svg", plot.svg(fig))`。

`terminal` 交回一行行盲文单元与字符、每行换行结尾的文本,用 `println` 就能在 CI 日志或命令行里看到图。图的每 4 个像素宽成一列、每 8 个像素高成一行:默认 640 × 480 的图打印为 160 列 × 60 行,`with_size(320.0, 240.0)` 装得进 80 列的终端。每种颜色化为一种墨——按它对主题背景的亮度反差取 0 到 8 的档——所以填充 mark 按档位半调(热图读作深浅),线条按同一档位画实、画稀疏点、或不画。

`png` 把同一份值图栅格化到每像素 2 × 2 超采样上,文字排进 Hershey Simplex 笔画字体,再用包自己的 DEFLATE、CRC-32、Adler-32 装帧——不依赖宿主图像库。答案之所以是 `Bytes`,是因为 PNG 是二进制;在原生目标上用 `file.write("chart.png", plot.png(fig))` 写出。

```emo
println(plot.terminal(fig))
file.write("chart.png", plot.png(fig))
```

## 表与缺失数字

数据集图读的是 `Table`——这个包拥有的唯一数据结构:列式、极简、只能从两个带校验的构造器来。

```emo
def table(numbers Map[String, Array[Float64]], labels Map[String, Array[String]]) Table
def table_missing(numbers Map[String, Array[Float64]], presence Map[String, Array[Presence]], labels Map[String, Array[String]]) Table

enum Presence { present, absent }
```

数值列与类别列放在按列名作键的 map 里,每一列共享同一个行数。`table` 建全在的表;`table_missing` 接收调用者写好的 presence 列——缺失的数字在值数组里保留自己的槽位,由并行的 presence 条目指名该槽 `absent`。缺失值是 presence 标签,不是 `NaN`——beam 目标的 Erlang 浮点装不下它。

两个构造器都校验形状、违约即 raise,因为手写字面量写出的表就是程序员的意图:两列长度不一、一个名字被两种列同时占用、数值列缺 presence 列——或多出一条 stray、或长度与数值列不符——全是契约违约。

```emo
const meals = plot.table(
  { "bill": [16.99, 10.34, 21.01, 23.68], "tip": [1.01, 1.66, 3.50, 3.31], "party": [2.0, 3.0, 2.0, 4.0] },
  { "day": ["Sun", "Sat", "Sun", "Sat"], "time": ["Dinner", "Dinner", "Lunch", "Dinner"] }
)
```

读取走列的类型这一边——`rows` 是行数;读一个表以另一类携带的名字,或它不携带的名字,直接 raise:

```emo
meals.rows                    // 4
meals.number("bill")          // 数值列的值
meals.presence("bill")        // 并行的 presence 数组
meals.label("day")            // 类别列的值
```

`plot.observed(numbers, presence)` 把一列过滤到它在场的条目——一切统计读列时走的那个地板。缺失行以同样方式从数据集图里掉出去:一个缺失值损失的是它那一行,不是整张图。

## 通道

数据集图通过通道映射来点名自己的列——一个 `Map[String, String]`,键是通道、值是列名,所以一个没写的键就是一个没用的通道:

```emo
{ "x": "bill", "y": "tip", "color": "day", "size": "party" }
```

词汇表一共八个词——`x`、`y`、`color`、`size`、`marker`、`dash`、`facet_row`、`facet_col`——映射里出现别的词直接 raise,图表不读的通道也一样。通道的值只能是列名:常量属于 mark 样式,永远不进映射。

每种图读什么:

| 图 | 必填 | 可选 |
|---|---|---|
| `scatter` | `x`、`y`——数值列 | `color`(数值或类别)、`size`(数值)、`marker`(类别)、两个 facet |
| `line` | `x`、`y`——数值列 | `color`、`marker`、`dash`(类别)、两个 facet |
| `reg` | `x`、`y`——数值列 | 两个 facet |
| `hist` | `x`——数值列 | `color`(类别)、两个 facet |
| `kde` | `x`——数值列 | `color`(类别)、两个 facet |
| `ecdf` | `x`——数值列 | `color`(类别)、两个 facet |
| `box` | `x`——类别,`y`——数值 | 两个 facet |
| `violin` | `x`——类别,`y`——数值 | 两个 facet |
| `bar` | `x`——类别,`y`——数值 | 两个 facet |
| `count` | `x`——类别列 | 两个 facet |
| `strip` | `x`——类别,`y`——数值 | `color`(类别)、两个 facet |
| `point` | `x`——类别,`y`——数值 | 两个 facet |
| `heatmap` | — | 两个 facet |
| `clustermap` | — | 两个 facet |

`color` 通道按列的类型分派,而这个分派本身就是一个函数:

```emo
def channel_colors(t Table, name String, theme Theme) Array[(Int64, Int64, Int64)]
```

类别列经主题调色板按 level 的排序位解析——level 各不相同、按字节序排;数值列把它观测到的值归一化到自己的跨度上、读主题 colormap,值全相同的列落在映射的低端。分组 level 也按同一个排序位挑自己的 marker 形状与笔画样式,循环使用词汇表:`plot.marker_at(i)` 轮过六个形状(circle、square、triangle、diamond、cross、plus),`plot.dash_at(i)` 轮过四种样式(solid、dashed、dotted、dash dot)。

## 关系图:scatter、line、reg

数据集图是一种图一个函数:各自接收表与通道映射,回答一整张 `Figure`——一个 axes、按通道的列名落好标签、带着映射建出的 mark:

```emo
def scatter(t Table, ch Map[String, String]) Figure
def line(t Table, ch Map[String, String]) Figure
def reg(t Table, ch Map[String, String]) Figure
```

必填列缺席的行从图里掉出去;掉到没有可画的行,直接 raise。

**`scatter`** 每个分组 level 盖一个 mark,映射不分组时一个。类别 `color` 列把点按 level 拆成一组一个系列,颜色取 level 在主题调色板里的排序位,图例以 level 名之;数值 `color` 列按每一点在观测跨度上的位置、经主题 colormap 上色。`size` 通道把每个点在样式尺寸的 0.5 到 1.5 倍之间、按其列的观测跨度缩放;`marker` 通道给每个 level 盖自己的形状。

```emo
plot.svg(plot.scatter(meals, { "x": "bill", "y": "tip", "color": "day", "size": "party" }))
```

**`line`** 每个分组 level 画一条描边系列,按行自己的顺序——表的行序就是意图,图不排序。`color`、`marker`、`dash` 通道各自点名类别列时,level 的颜色、点章、虚线样式都按 level 的排序位解析。

```emo
const regions = plot.table(
  { "quarter": [1.0, 2.0, 3.0, 4.0, 1.0, 2.0, 3.0, 4.0], "revenue": [12.0, 18.0, 15.0, 24.0, 9.0, 11.0, 16.0, 14.0] },
  { "region": ["west", "west", "west", "west", "east", "east", "east", "east"] }
)
plot.svg(plot.line(regions, { "x": "quarter", "y": "revenue", "color": "region", "dash": "region" }))
```

**`reg`** 在点上拟合最小二乘直线,并把均值的 95% 置信带画在点下——带先画,点坐在带上。带在留下的跨度上按五十个格点采样;拟合线以 `fit` 入图例,带以 `95% band`。两行可画是底线。

```emo
const study = plot.table(
  { "hours": [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0], "score": [52.0, 55.0, 61.0, 64.0, 66.0, 71.0, 74.0, 77.0] },
  {}
)
plot.svg(plot.reg(study, { "x": "hours", "y": "score" }))
```

组的颜色在建图时经默认主题解析;调用之后再 `with_theme` 重新给图自己的墨上色。

## 分布图:hist、kde、ecdf、box、violin

`hist`、`kde`、`ecdf` 读一个数值列、每个 `color` level 画一个 mark——拆分方式与关系图相同。`box` 与 `violin` 用一个类别列给数值列分组:

```emo
def hist(t Table, ch Map[String, String]) Figure
def kde(t Table, ch Map[String, String]) Figure
def ecdf(t Table, ch Map[String, String]) Figure
def box(t Table, ch Map[String, String]) Figure
def violin(t Table, ch Map[String, String]) Figure
```

**`hist`** 把留下的值数进横跨它们共同范围的等宽桶——桶数是值数的平方根、至少一——每个 level 在共享网格上一个直方图,level 之间可比。y 轴自动落标 `count`。

**`kde`** 每个 level 画一条密度曲线,带宽由 Silverman 经验法则按该 level 自己的值得出,网格每端外推三个带宽、一百个点。y 轴落标 `density`。常数列没有密度——图直接 raise,不画尖峰。

**`ecdf`** 每个 level 画一段阶梯,每个值的累计比例在该值处踏上一级。y 轴落标 `proportion`。

**`box`** 坐在 `x` 列的 level 上——那里给数值列直接 raise——并用 Tukey 统计汇总每个 level 的 `y` 值:须在四分位距 1.5·IQR 之内最远的值上,填充的四分位箱、中位线,越出须端的盖点。没有观测 `y` 值的 level 不出现。

**`violin`** 每个 level 画一条镜像密度,带宽与网格形状与 `kde` 图相同,整行归一化让 violin 之间可比。值不散开的 level 直接 raise。

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

## 类别图:bar、count、strip、point

四者都坐在 `x` 列的 level 上——那里给数值列直接 raise;`bar`、`strip`、`point` 还需要旁边的 `y` 数值列:

```emo
def bar(t Table, ch Map[String, String]) Figure
def count(t Table, ch Map[String, String]) Figure
def strip(t Table, ch Map[String, String]) Figure
def point(t Table, ch Map[String, String]) Figure
```

**`bar`** 每个 level 一根柱,高是该 level 观测 `y` 值的均值。**`count`** 完全不需要 `y`:每个 level 一根柱,高是该 level 携带的行数,y 轴落标 `count`。**`strip`** 把原始点画在各自带中心,每个 `color` level 一个 mark,不抖动、按行自己的顺序——重叠的点就是数据。**`point`** 每个 level 一个盖章的、连线的均值,按 level 的排序序走过各带。

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

## 矩阵图:heatmap、clustermap

`heatmap` 与 `clustermap` 把整张表读成矩阵:数值列是格子的列、行是格子的行,恰好一个类别列给行命名;一个没有、或有好几个,行就从 1 编号。通道映射在这里不携带列名、只有两个 facet 通道,所以通常是空的:

```emo
def heatmap(t Table, ch Map[String, String]) Figure
def clustermap(t Table, ch Map[String, String]) Figure
```

每个格子按自己的值在全部格子自己跨度上的位置、经主题 colormap 取色——常数矩阵落在映射的低端。列名落 x 轴的带、行名落 y 轴的带,两根轴都不刻数字。`clustermap` 画同样的格子,行与列各自按欧氏距离的平均连接聚类重排,相邻的就是相近的;树本身不画——顺序就是聚类。

```emo
const corr = plot.table(
  { "alpha": [1.00, 0.41, 0.18, -0.12], "beta": [0.41, 1.00, 0.55, 0.02],
    "gamma": [0.18, 0.55, 1.00, 0.33], "delta": [-0.12, 0.02, 0.33, 1.00] },
  { "row": ["alpha", "beta", "gamma", "delta"] }
)
plot.svg(plot.heatmap(corr, {}))
plot.svg(plot.clustermap(corr, {}))
```

无数值列的表、或零行的表,直接 raise。

## 分面

每种图都读 `facet_row` 与 `facet_col` 通道。各自点名一个类别列,列的 level——各不相同、与其他分组一样按字节序——把图拆成面板:`facet_row` 的 level 纵向排、`facet_col` 的横向排,单个通道就是 1 × N 或 N × 1 的一条。每格画自己持有的行上的那种图,所以某组 level 组合没有行的格子保持空白。

```emo
plot.svg(plot.scatter(meals, { "x": "bill", "y": "tip", "color": "day", "facet_col": "time" }))
plot.svg(plot.hist(exam, { "x": "score", "facet_row": "class" }))
```

面板之间可比:图保持 `Share.all`,每格画在全部面板域的并集上(矩阵图在自己的格子网格上保持 `Share.none`);每格的标题来自它的 level——`time = Lunch`,两个 facet 用逗号相连;轴标签只落外缘,x 标签在最底行、y 标签在第一列;各格自己的图例让位给整张图右侧的一个图例,把每个带标签的 mark 按 label 列一次。同一个 level 在每格同色,因为 level 是在整张表上排序的。facet 通道交给数值列会 raise,与分组通道一样。

## 手搭面板网格

图携带网格;图表函数去填。手搭的网格自己组装 axes:

```emo
const quarters = ["Q1", "Q2", "Q3", "Q4"]
const units_ax = plot.axes().with_x_label("Quarter").with_y_label("Units").with_marks([plot.mark.bar(quarters, [20.0, 28.0, 26.0, 34.0])])
const revenue_ax = plot.axes().with_x_label("Quarter").with_y_label("Revenue").with_marks([plot.mark.bar(quarters, [180.0, 220.0, 190.0, 260.0])])
const costs_ax = plot.axes().with_x_label("Quarter").with_y_label("Costs").with_marks([plot.mark.bar(quarters, [120.0, 160.0, 140.0, 190.0])])

plot.svg(plot.figure().with_title("Quarterly review").with_grid(2, 2).with_axes([units_ax, revenue_ax, costs_ax]))
```

格子按行主序填。格子多于 axes 时尾部留空;axes 多于格子直接 raise,行数或列数低于 1 也一样。没有 mark 的 axes 是一个空白格——什么都不画、也不进共享域,所以留个稀疏的格子不花任何代价。`Share.all`——默认——先把每格自己的域解出来、再让每格画在并集上,面板在同一把尺上可比;`Share.none` 让每格各用各的。`with_shared_legend(true)` 在整张图右侧画一个图例——全部面板、每个带标签的 mark、按 label 一次——并把那一列从网格宽度里扣掉;通常同时把各格自己的图例关掉。

每种数据集图都有一个单面板形态、只回答 `Axes`,正适合手搭网格:`scatter_axes`、`line_axes`、`reg_axes`、`hist_axes`、`kde_axes`、`ecdf_axes`、`box_axes`、`violin_axes`、`bar_axes`、`count_axes`、`strip_axes`、`point_axes`、`heatmap_axes`、`clustermap_axes`——同样的表、同样的通道映射,回答一个 axes 而不是一张图,`Axes.with_title` 就是面板标题。

```emo
const ax = plot.scatter_axes(meals, { "x": "bill", "y": "tip", "color": "day" }).with_title("Weekend bills")
plot.svg(plot.figure().with_axes([ax]))
```

## 主题、调色板与 colormap

主题给整张图定妆:背景与前景的墨、网格、轴、标题与标签的样式、`color` 通道解析所经的调色板与 colormap、面板间距、`figure()` 起始的默认尺寸。

```emo
def theme() Theme
def dark_theme() Theme
```

`figure()` 建默认浅色主题;`with_theme` 换上一个:

```emo
plot.svg(plot.figure().with_theme(plot.dark_theme()).with_axes([dark_ax]))
```

`Theme` 逐字段细化——`with_background`、`with_foreground`、`with_grid`、`with_axis`、`with_title`、`with_label`、`with_palette`、`with_cmap`、`with_spacing`——落在字段 `background`、`foreground`、`grid`、`axis`、`title`、`label`、`palette`、`cmap`、`spacing` 与 `width` / `height` 之上。部件样式:

```emo
def grid_style() GridStyle   // color、width、dash、visible——各有 with_*
```

`GridStyle` 画 mark 背后的网格线——y 刻度上的横线、x 刻度上的竖线;`with_visible(false)` 完全不画网格。`AxisStyle` 是坐标轴框——底边脊线的 `color` 与 `width`、刻度线的 `tick_len`、x/y 轴标签的 `label_size`——经 `with_color`、`with_width`、`with_tick_len`、`with_label_size` 细化。`TextStyle` 给一段图上文本定妆——`color`、`size`、`anchor`(`Anchor.start` / `middle` / `end`)、`weight`(`Weight.regular` / `bold`)——经 `with_color`、`with_size`、`with_anchor`、`with_weight` 细化。

类别调色板:

```emo
def palette() Palette   // 五个 mark 家族的默认色
```

`Palette` 包一列颜色,`color(i)` 按表长回绕;`with_colors` 换掉它。空表直接 raise。

连续 colormap:

```emo
def viridis() Colormap
def sequential() Colormap
def diverging() Colormap
```

`Colormap` 在 0.0–1.0 的位置上钉 stop,`at(t)`——钳进这个跨度——用 Float64 插值夹住它的两个 stop 的通道;`with_stops` 换掉它们。空表、越界位置、或降序位置直接 raise。三个内置图各用五个 stop 逼近它们的目标。

**颜色是 `(Int64, Int64, Int64)` 的 sRGB 三元组**,每通道 0–255:

```emo
def rgb(r Int64, g Int64, b Int64) (Int64, Int64, Int64)
```

`plot.rgb` 建一个并查范围——越界通道直接 raise——裸三元组也可用,画的时候再校验。不透明度是样式上一个独立的 `Float64`;它搭载在每个样式上,但尚未渲染。主题只供默认——mark 最终画什么,仍然是一个 `plot.mark` 样式值。

## mark:没有表时的画法

`plot.mark` 是图表层底下的那一层:一个 mark 是一个值,知道自己怎么画进一个 axes、自己的数据跨多大。数据已经在数组里——或图表层不画你想要的东西——时就自己搭 mark:

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

每个工厂校验自己的数组、回答一个携带默认样式的 mark;`with_style` 换样式,样式的 `with_*` 方法做细化——全是拷贝,没有原地改:

```emo
plot.mark.line(years, revenue).with_style(
  plot.mark.line_style().with_dash(plot.mark.Dash.dashed).with_color(plot.rgb(47, 111, 179)))
```

### bar

`bar(labels, values)` 每个 label 在它的带中心画一根柱,坐在零基线上。`BarStyle` 携带填充 `color`、带占比 `width`(默认 0.8)、`opacity`、`label`,经 `with_color`、`with_width`、`with_label` 细化。

### line

`line(x, y)` 沿点描一条折线,并在每个点盖上它的 marker 形状。`LineStyle` 携带 `color`、`width`、`dash`、`marker`、`marker_size`、`opacity`、`label`——经对应的 `with_*` 方法细化:

```emo
enum Dash { solid, dashed, dotted, dash_dot }
enum Marker { none, circle, square, triangle, diamond, cross, plus }
```

### scatter

`scatter(x, y)` 在每个点盖章、互不相连。`ScatterStyle` 携带 `color`、`size`、`marker`、`opacity`、`label`;`Marker.none` 的 scatter 什么都不画。scatter 还携带逐点的颜色与尺寸覆盖——数据集图读 `color` 与 `size` 通道所经的那两个数组;超出覆盖数组长度的点画样式值:

```emo
plot.mark.Scatter.new(x: xs, y: ys, style: plot.mark.scatter_style(), colors: point_colors, sizes: point_sizes)
```

### area

`area(x, y)` 填充折线与零基线之间的闭合区域,负值沉到基线下。`AreaStyle` 携带填充 `color`、`edge_color` 与 `edge_width`(沿曲线本身的一笔描边;默认 `0.0` 不描边)、`opacity`、`label`。

### hist

`hist(values, bins)` 把值数进横跨数据的等宽桶、在零基线上铺成柱。等于最大值的落进最后一桶;全部相同的值也堆进最后一桶,因为它们的跨度塌成零。`bins < 1` 直接 raise。`HistStyle` 携带填充 `color`、柱描边的 `edge_color` 与 `edge_width`(默认白、宽 1.0)、`opacity`、`label`。`bin_index(v, lo, span, bins)` 回答一个值落进哪个桶——计数规则单独拆出来。

### band

`band(xs, lo, hi)` 填充同一串 xs 上、下两条曲线之间的区域——一个多边形,上曲线正向读、下曲线反向读。工厂检查 low、high 数组与 xs 等长、且 xs 严格升序。`BandStyle` 携带填充 `color`、`opacity`、`label`。

### box 与 violin

`box(labels, lows, q1s, medians, q3s, his, flier_xs, fliers)` 每个 label 在它的带中心画一个箱——须、填充的四分位箱、中位线、越出须端的盖点。五个统计数组与 labels 等长,flier 两数组彼此等长;工厂检查。`BoxStyle` 携带填充与描边的 `color`、`edge_width`、带占比 `width`(默认 0.5)、`opacity`、`label`。

`violin(labels, points, xs, density)` 每个 label 画一条镜像密度:网格与密度都是平铺的、每个 label 一段 `points` 个条目,密度是带的半宽的分数(0.0 到 1.0),数组必须恰好 `labels × points` 个条目,否则工厂 raise。`ViolinStyle` 携带填充 `color`、带占比 `width`(默认 0.9)、`opacity`、`label`。

### strip 与 point

`strip(labels, xs, ys)` 是类别面上的 scatter:原始点落在各带中心,xs 是带坐标(0.5、1.5、……),两数组等长;样式是 `ScatterStyle`。`point(labels, xs, ys)` 走过各带——每个 label 一个值、按带序连线并盖样式的 marker;样式是 `LineStyle`(线连、章盖),`point_style()` 给出该默认。

### heatmap

heatmap mark 是一个预先着色的格子网格——值按列名横、行名纵、行主序排,每个格子的颜色由调用者递进来,mark 对 colormap 一无所知:

```emo
plot.mark.Heatmap.new(col_names: cols, row_names: rows, values: vals, colors: cell_colors)
```

它是唯一一个给两根轴都落标签的 mark——列名落类别 x 面、行名落 y 面。它不带样式、也不进图例。

### Mark 接口

一个 mark 经一个接口自画——`draw`,加上它请坐标轴覆盖的数据跨度:连续 x、y 范围经 `x_min` / `x_max` / `y_min` / `y_max`,类别 x 面经 `bands` 与 `x_labels`,类别 y 面经 `y_labels`(除 heatmap 外所有内置 mark 都为空),以及图例对 `legend_label` / `legend_sample`。一个新的 mark 家族就是满足这个形状的一个新类,像别的 mark 一样进 `with_marks`。

图例开着时(默认),带标签的 mark 按数组顺序列进绘图区右上角的图例——最后画。label 为空的 mark 不进。

## 什么会 raise

这个包遵守标准库的约定:预期的失败是值,违约才 raise——raise 即进程结束。raise 都是契约违约,消息都带 `plot:` 前缀:

- **表形状**——一个名字被两种列同时占用、各列长度不一、数值列缺 presence 列、多出 stray presence 列、或其长度与数值列不符;
- **表读取**——未知的列名,或表以另一类携带的名字;
- **通道**——未知通道、图表不读的通道、缺 `x` 或 `y`、分组或 facet 通道交给数值列、`color` / `size` 的数值列没有观测值;
- **图形状**——没有可画的行、`reg` 不足两行、`kde` 或 `violin` 撞上不散开的值、矩阵图无数值列或零行;
- **mark 工厂**——数组长度不符、band 的 xs 不升序、`hist` 桶数低于 1;
- **图的组装**——网格低于 1 × 1、axes 多于格子、固定域 `lo >= hi`、log 轴撞上非正值;
- **颜色**——`rgb` 通道越出 0–255、空调色板、colormap 的 stop 为空、越界、或非升序。

数据来自程序之外而不是字面量时,先把读取理顺再建表——读数据这一步属于读取方,一张自相矛盾的表永远是调用方的 bug。
