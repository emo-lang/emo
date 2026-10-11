# Emo 与可视化 —— 一份评估与一个设计方向

写于 2026-10-12。这是一份技术可行性评估外加一个设计方向;文中关于
项目状态的描述以写作日期的仓库为准(`develop`,`v0.28.1`)。方向已
于 2026-10-12 讨论定案(见末尾的已记录决定一节),但在工作被拆成
plan 步骤之前仍留在 `docs/` 设计笔记里;只有成为已定设计时才进入
`README.md`。

问题:要让 Emo 具备与 Python 的 **Matplotlib** 和 **Seaborn** 相当的
绘图与统计图形能力,到底要做什么?

证据基础是一个可运行的 spike
([`spike/plot-svg`](../../spike/plot-svg/README.zh-CN.md)):一张真正的二维
图——nice-number 刻度、绘图框、网格线、坐标轴标签、带标记点的折线
序列——由一个没有任何 FFI 的纯 Emo 程序渲染成 SVG。这个 spike 同时
也是一次目标矩阵探测,它的失败与成功一样有信息量。

## 结论

**可行,但要分档——而且渲染器是容易的部分。** 难的是它下面的数值与
可移植性基底:六个目标、只放行 `c`/`ocaml` 的 FFI、以及停在
`sqrt`/`floor`/`ceil`/`trunc` 的核心浮点面。以 SVG 为输出格式消掉了
古典意义上最大的障碍——字体渲染——因为文本归查看器管,不归库管。
剩下的就是算术、布局,以及大量有纪律的普通代码。

| 档位 | 是什么 | 工作量量级 |
|---|---|---|
| **T0** | 二维图表核心——折线、散点、柱、面积、直方图;坐标轴、刻度、图例、标题;输出 SVG | 一人数周;spike 已证明形状可行,缺口也已摸清 |
| **T1** | Seaborn 级统计——分布(直方/KDE/ECDF)、分类(箱/小提琴/柱/计数/条带)、回归、矩阵(热力图/clustermap)、分面、调色板与主题 | 一人 1–2 个月;在 T0 之上的纯 Emo,只需算术 |
| **T2** | 栅格 PNG——纯 Emo 的 zlib 流(stored 块)、CRC32、带超采样的笔画字体光栅器 | 可读且正确的实现需 1–2 个月;不需要 FFI |
| **T3** | 交互/GUI 图表、3D、动画 | 现在不做;原生 GUI 画布是一条独立方向(见下),不属于本项工作 |
| **不做** | PDF/PS/EPS、LaTeX 文本、复杂文种 shaping、Agg/FreeType 级原生后端 | 不值得追;为一个没人要求的保真度而做的原生专属档位会把产品割裂 |

"完整的 Matplotlib + Seaborn 对等"不是一个可判定的终点——Matplotlib
是十五年以上的积累、远超十万行;seaborn 叠在 pandas、numpy、scipy、
statsmodels 之上。第一个产品决策,和 SQL 那份评估完全一样,就是把
"完整可视化"降维成一个明确声明的档位。值得声明的,是 T0 + T1。

## 为什么先做 SVG

选 SVG 作为输出格式是承重的,不是随手一选。

- **文本变成查看器的活。** 一个 SVG `<text>` 元素把字体查找、shaping、
  hinting、栅格化统统交给渲染该文件的一方。Matplotlib 之所以必须
  内嵌字体管理器、并让构建被 FreeType 支配,正是因为它自己光栅化
  文本。Emo 没有字体引擎,六个目标里有四个没有 FFI;在绘制层把文本
  交出去,就整个绕开了这个问题。
- **文本格式就是纯 Emo。** 渲染器只需要 `String` 拼接,别的都不要,
  于是它可以用 Emo 写在共享运行时之上——即标准库的"语言够用时就用
  纯 Emo"惯例——而它的输出可以在每一个支持该数值面的目标上逐字节
  对齐。
- **矢量是科学配图的用例。** 任意缩放都清晰、可编辑、可 diff、
  体积小。
- **它与既有的东西组合。** SVG 可以直接落进 HTML 给浏览器看,
  `wasm` 与 `typescript` 目标可以把 SVG 注入 DOM。若将来真做出原生
  GUI 画布,它也只是同一份场景描述的第二个消费者——那是一条独立
  方向,不属于本项工作(见第 5 层)。
- **有经过验证的先例。** gnuplot 从一个核心出发输出 SVG(还有 PNG 与
  终端),用公有领域的 Hershey 笔画字体、不依赖字体引擎——这是与
  Emo 想做之事最接近的架构先例,也是"这个形状可行"的独立证据。

## Emo 已有什么,一个绘图包必须补什么

spike 把能力盘点钉到了具体条目上。

**已经具备、且够绘制层用:** `Float64`(IEEE 754)与 `Int64`(绕回)、
带插值与 `printf` 的 `String`、不可变且可 `append` 的 `Array`、`Map`、
`List`(带 `push_back`/`pop_back` 的双端队列)、`Box`、带字节与
小端访问器的 `Bytes`、元组、枚举、类、结构化接口、函数组、挂载块、
`for`/`while`,以及可声明目标集的包机制。

**缺口,各带代价:**

1. **超越函数面是缺的。** 核心停在 `sqrt`、`floor`、`ceil`、`trunc`、
   `to_int64`、`to_float64`;没有 `sin`、`cos`、`atan2`、`exp`、
   `log`、`pow`。统计层需要 `exp`/`log`(KDE、对数坐标、回归区间)与
   正态分位函数(误差棒、置信带)。两条路:**纯 Emo 数学层**(运算
   顺序固定,因而确定,因而可逐字节对齐 golden——标准库走的路),
   或者**核心/FFI 原语**(快,但要跨六个目标做对齐,且引出确定性
   问题,见风险一节)。
2. **数值方法分派尚未对齐。** spike 的图对数值用了 `to_float64`、
   `to_int64`、`floor`、`ceil`、`to_string`;今天 `c`、`wasm`、`beam`
   拒绝它们(`to_float64 has no dispatch`、
   `does not support the type-level method fig_w.to_int64`)。一个声明
   五个目标的包,在这个缺口补上之前无法发布。
3. **没有可增长缓冲,也没有 `join`。** `Bytes` 是定长的(`json` 包的
   做法是先算精确长度再填充),`Array` 不可变且只有 `append`/`length`。
   SVG 输出需要分块的 `Buffer`(由 `Bytes` 块组成的 `List`,或两趟
   精确长度填充)作为这个包的第一件工具。
4. **没有 `sort` / `map` / `filter` / `reverse`,也没有泛型。** 分位数、
   箱线图、刻度排序、直方图分箱都需要数值排序。包内这是一个
   `sort_float64s` 加一个索引排序——不讨喜但有边界,而且诚实:这门
   语言有意地没有泛型定义语法。
5. **没有字体尺度信息。** SVG 把渲染交了出去,却没把*测量*交出去,而
   自动布局(标签避让、旋转刻度、图例)需要宽度。两个答案:一张按
   字符的基础字体步进表(近似、零依赖),或者一套 **Hershey 笔画
   字体**——公有领域、纯几何、可精确测量——它同时还能当栅格后端的
   文本来源。
6. **没有默认参数。** 已核实:`def f(a Int64, b Int64)` 以 `f(1)` 调用
   会报 E4009。命名参数有,默认值没有。于是样式选项改由按 mark 的
   样式值配 `with_*` 复制方法来携带(见"Emo 里的 API")——这是一个
   真问题,不是脚注。
7. **绑定模式已定案但不在本构建里。** `const (lo, hi) = f(x)` 已记入
   `CHECK.md`;`v0.28.1` 解释器仍然拒绝它。绘图代码可以不靠它(用下标
   取元组),但对 `(lo, hi, step)` 这类载体,它才是自然的解构写法。

## 架构

六层,每层只依赖它下面的层。T0 只交付第一层;其余是生长路径,现在
就点名,是为了让 T0 的接口不要关上门。

### 第 0 层 —— 场景与渲染器

一份与后端无关的显示列表,外加一个结构化 `Renderer`。每个 mark 算好
像素空间几何并发出图元;第 0 层之上的任何东西都不知道输出格式是
什么。

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

T0 只交付一个实现:`SvgRenderer`。终端渲染器(盲文/方块字符,承
`UnicodePlot` 的精神)与 PNG 光栅器是同一接口的后续实现。`Renderer`
是绘图层自身的抽象,不是 Emo 的目标:Emo 的目标是
`ocaml`/`c`/`typescript`/`wasm`/`beam`/`riscv64`,而 EmoUI 是跑在
它们之上的库,其平台后端是 OS 工具包(AppKit、GTK 4)。EmoUI 当前的
契约是摆放控件、没有绘制动词,所以今天它不是一个绘图后端(见第 5
层)。这就是 Matplotlib 的 Artist/Renderer 拆分。

### 第 1 层 —— 几何、比例尺、刻度

`Point`/`Rect` 用普通元组或小类;线性、对数、band、时间比例尺;
色图;以及 "nice numbers" 刻度定位与格式化(Heckbert 的 `nicenum`,
约三十行,也是坐标轴看起来专业而非"算法味"的原因)。除了对数与时间
比例尺需要缺口 1 的数学层,其余全是语言今天就能做的算术。

### 第 2 层 —— 图与坐标轴

对象模型是一张值图:`Figure` 持有一个或多个 `Axes`,每个 `Axes`
有自己的比例尺、mark 列表、图例与标签。构造一张图就是一次普通调用,
返回一个普通值;渲染是再下一次调用。

```
const chart = plot.figure(
  title: "Monthly sales",
  axes: plot.axes(x_label: "Month", y_label: "Sales", marks: [...])
)
plot.save(chart, "chart.svg")
```

刻意**不要 pyplot 式的全局状态**:Emo 的最小惊讶原则反对隐藏的
"当前图"与"当前坐标轴",而这恰是 Matplotlib 最受批评的设计决定。
表面是声明式的(2026-10-12 决定):一张图是一个值,不是对一块活
画布的一串改动。

### 第 3 层 —— Matplotlib 式的表面

mark 是值:`plot.line(x, y)`、`plot.scatter(x, y)`、
`plot.bars(labels, values)`、`plot.area(x, y)`、
`plot.hist(values, bins)`。每个返回一个携带数据与默认样式的 mark,
`axes(marks: [...])` 通过结构化 `Mark` 接口把它们收起来。完整表面,
以及唯一真正的设计难题——没有默认参数时样式如何携带——在下面的
"Emo 里的 API"一节展开。

### 第 4 层 —— Seaborn 式的表面(`plot.stats`)

在同一个引擎之上的、面向数据集的 API,是同一个 `plot` 包的 `stats`
子模块——`plot.stats`(2026-10-12 决定)。一个 `require "plot"` 就把
两个表面都带进来,下面的调用写作 `plot.stats.*`。Seaborn 的洞见是:
一张图就是从数据列到美学通道的*映射*,加一个统计变换,加一个 mark,
再按一个或多个分组列分面。Emo 用一个 `Table` 加上同一套
`Figure`/`Mark` 值恰好能表达:

```
const tips = plot.table(["total_bill", "tip", "time"], rows)
plot.stats.relational(tips, x: "total_bill", y: "tip", hue: "time")
plot.stats.distributions(tips, x: "tip", hue: "smoker")
plot.stats.categorical(tips, x: "day", y: "total_bill", kind: "box")
plot.stats.matrix(correlation)
```

其下的统计子层:`describe`、`quantile`、`histogram_bins`、`kde`、
`ecdf`、`ols` 加置信带、`box_stats`,以及一个确定性的 PRNG。全是纯
算术;KDE 用 `math.exp`,而正态分位(`normal_quantile`)是统计层自己
的(2026-10-12 决定)。

**最小表**(2026-10-12 决定)是这一层唯一需要的新数据结构——Emo
没有 data-frame,它也不能长成 data-frame。`Table` 是列式的:数值列放
`Map[String, Array[Float64]]`,分类列放 `Map[String, Array[String]]`,
外加行数。缺失的数值是 `NaN`(统计函数跳过);标签列不设缺失哨兵。

```emo
const tips = plot.stats.table(
  { "total_bill": [16.99, 10.34, 21.01], "tip": [1.01, 1.66, 3.50] },
  { "time": ["Lunch", "Dinner", "Dinner"] }
)
```

`plot.stats.table(numbers, labels)` 校验各列等长、列名唯一,形状违例
时 raise:字面量写出的表是程序意图,写错就是契约违反——将来面向数据
的入口(CSV 或 JSON 读取器)才返回 `(R.error, reason)`。访问用
`number(name)` / `label(name)`,并按列的类别校验。数据集 API 用一张
`Map[String, String]` 命名通道——`{ "x": ..., "y": ..., "hue": ... }`
——缺键就是没用那个通道;这是用编译期的通道名校验换真正的可选通道
(2026-10-12 决定)。`Table` 放在 `plot.stats`,紧挨着唯一使用它的那
一层,且绝不能再长成 pandas。

### 第 5 层 —— 其它后端与交互

终端输出与 PNG 是进一步的 `Renderer` 实现。交互/GUI 图表**现在不
做**(2026-10-12 决定):EmoUI 不是 Emo 的目标,且它当前的契约
(`ui_window_make`/`ui_label_make`/`ui_place`/……)是摆放控件,没有
绘制动词,所以把图画进 EmoUI 是 EmoUI 的一个新能力,不是绘图后端。
若将来要追交互,那是 **EmoUI 内部的一条独立方向**:一套共享的
向量画布契约,由 EmoUI 的画布控件与本库的 `Renderer` 各自实现
(2026-10-12 决定)。它现在不得塑造静态 API。

## Emo 里的 API

不需要任何新语法,这本身就是设计合身的强信号。表面是声明式的
(2026-10-12 决定):一张图就是一个值——`Figure` 持有 `Axes`,每个
`Axes` 持有 mark——一次调用即渲染。没有对隐藏当前图的改动。

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

`marks` 是 `Array[Mark]`,`Mark` 是一个结构化接口,于是 `Line` 与
`Scatter` 这两个不同的类可以放进同一个数组,而不需要继承:

```emo
interface Mark {
  def draw(ctx DrawContext) Void
}
```

块当子节点(EmoUI 也用这个形状,但这里只是语法类比——没有依赖)
是可能的第二种写法;数组参数是主形态:显式、顺序可见、不需要任何
新东西。

### 样式是唯一真正的设计难题

Emo **没有默认参数**——`def f(a Int64, b Int64)` 以 `f(1)` 调用会报
E4009——于是可选的样式无法挂在函数签名上。每个选项要么在调用点必
填,要么由一个调用者构造的值携带。下面的设计不需要语言改动;另一条
路——默认参数——在其后权衡。

**mark 是值,默认样式已烘焙其中。** mark 工厂只收数据,返回一个已经
带样式的 mark:

```emo
def line(x Array[Float64], y Array[Float64]) Line {
  return Line.new(x: x, y: y, style: line_style())
}
```

**每个 mark 家族有自己的样式类**,于是样式永远不会带一个它的 mark
会忽略的字段——严格,没有静默忽略的选项——并且每个类为每个选项暴露
一个 `with_*` 复制方法:

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

  // ……每个选项一个……
}

def line_style() LineStyle {
  return LineStyle.new(color: "#2f6fb3", width: 1.5, dash: Dash.solid,
    marker: Marker.none, opacity: 1.0, label: "")
}
```

**mark 持有一个样式,且只有一个样式入口 `with_style`**(2026-10-12
决定——不做 `with_*` 直通,于是每个 mark 的样式入口完全一致):

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
}
```

调用点仍是普通 Emo:

```emo
plot.line(months, sales)                                    // 默认
plot.line(months, sales).with_style(
  plot.line_style().with_color("#c0392b"))                  // 改一项
plot.line(months, sales).with_style(
  plot.line_style().with_color("#c0392b").with_width(2.5))  // 改几项
```

样板是机械的,且在包里只出现一次。代价是诚实的:`N` 个选项意味着每个
样式类 `N` 个复制方法,而没有泛型,语言消不掉这份重复。因为 mark 只有
`with_style`,这份代价每个样式类只付一次,不会乘以 mark 的数量。改一
项的写法比直通啰嗦;若真实图表代码显示这份啰嗦占了大头,给 mark 补
`with_*` 直通是一个有界的后续增补——不是现在。

**另一条路是默认参数。**

```emo
def line(x Array[Float64], y Array[Float64],
         color String = "#2f6fb3", width Float64 = 1.5,
         dash Dash = Dash.solid, marker Marker = Marker.none,
         opacity Float64 = 1.0, label String = "") Void { ... }

plot.line(months, sales)                                 // 全部默认
plot.line(months, sales, color: "#c0392b", width: 2.5)   // 覆盖
```

这会彻底消掉样式类、`with_*` 样板与 `plot.line_style()` 工厂,并给出
最干净的调用点。它是语言特性,不是库特性:必须严格检查(默认值不得
引用后面的参数;按名覆盖保持无歧义;漏掉*无默认值*的参数仍是
E4009),而且它需要自己的设计评审与第二个消费者。建议是**先按
`with_*` 设计把库建起来**——不改语言、样板有界——再让真实图表的摩擦
决定默认参数是否挣得了位置。若日后加上,公开表面去掉样式工厂即可,
不会扰动声明式模型。

| | `with_*` 样式值(不改语言) | 默认参数(改语言) |
|---|---|---|
| 调用点 | `plot.line(x, y).with_style(plot.line_style().with_color("#c00"))` | `plot.line(x, y, color: "#c00")` |
| 包内样板 | 每个样式类 `N` 个复制方法 | 无 |
| 检查 | 编译期,每个选项有类型 | 编译期,每个选项有类型 |
| 新语言面 | 无 | 参数默认值及其规则 |
| 今天可用 | 是 | 特性落地之后 |

### 契约的其余部分

- **两扇门共用一个引擎。** 位置式表面(`plot.line(x, y)`)与数据集
  表面(`plot.stats.relational(table, x: "col")`)是进入同一套
  `Figure`/`Axes`/`Mark` 值的两种写法,不是两套实现。
- **预期失败是值。** 依循标准库惯例,保存时路径打不开、`Table` 缺
  某个命名列、直方图没有值,都返回 `(R.ok, value)` /
  `(R.error, reason)`;只有真正的契约违反才 raise。这是正在落地的
  错误处理约定(`CHECK.md`,M12),绘图包必须从第一天起就按它写。
- **默认样式是值,不是全局状态。** 主题或调色板是传给 `figure` 的
  普通值,于是同一个程序里的两张图可以带不同主题。

## 命名与打包

标准库拥有顶层短名,包名是小写单词(`json`、`yaml`、`http`、
`base64`)。2026-10-12 的决定是**一个包 `plot`**——整套能力本质上就是
画图,所以统计层是它的子模块,不是单独的包:

- **`plot`**(模块 `plot`,包根)——核心:`Renderer` 接口与 SVG
  渲染器、比例尺与刻度、声明式的 `Figure`/`Axes`/`Mark` 值、按 mark
  的样式类,以及 `Table`。
- **`plot.stats`**(`stats/` 子模块)——Seaborn 式统计层:描述统计与
  分布、分类/关系/矩阵家族、回归、分面,以及主题与调色板。

该包声明**全部五个宿主目标**(`ocaml`、`c`、`typescript`、`wasm`、
`beam`;freestanding 的 `riscv64` 不在范围内——它拒绝 `Map`),和那些
格式包完全一致。

## 工作顺序

依赖是真实的,所以顺序不是随意的。2026-10-12 的决定钉死了形状:
SVG 优先,一个独立的 `math` 包,然后是这一个 `plot` 包。

- **A. 先做数值基底。** 补上缺口 2(`c`/`wasm`/`beam` 的浮点方法
  分派),并落地一个新的标准库 **`math` 包**——纯 Emo、五个目标,
  以绘图所需为限(2026-10-12 决定):`exp`、`log`、`log10`、`pow`、
  `sqrt`、`min`、`max`、`abs`、`clamp`,以及常量 `e`/`pi`。三角函数
  暂缓(T0+T1 没有极坐标或 3D);`normal_quantile` 与 `normal_cdf`
  放在 `plot.stats` 里,不进 `math`。可选的原生快路径在 `c`/`ocaml`
  上经由 `foreign def`,默认关闭,并写明其输出与目标绑定。分派修复
  与 `math` 一起门控其上的所有工作。
- **B. `plot` T0 核心——只做 SVG。** `Buffer`、比例尺、刻度、按 mark
  的样式类、`Renderer` 接口、`SvgRenderer`、声明式的
  `figure`/`axes`/mark 值、`Table`,以及带坐标轴、图例、标题的
  折线/散点/柱/面积/直方图。出口条件:`examples/plot_demo` 产出的
  一批 SVG 在五个目标上逐字节一致——标准库的 golden 标准。
- **C. `plot.stats` T1。** 描述统计、分箱、KDE、ECDF、箱统计、带置信
  带的 OLS、分类/分布/关系/矩阵家族、分面、调色板与主题——全部建在
  `plot` 之上。
- **D. 终端渲染器**(2026-10-12 决定:排在 PNG 之前)。便宜的第二
  `Renderer`——把字符打印到终端,不开窗口;让图在 CI 与 CLI 里可见,
  也检验第 0 层真的与格式无关。
- **E. PNG。** 纯 Emo 的 zlib(stored,再到固定 Huffman 的 DEFLATE
  块)、CRC32 与 Adler-32,以及带超采样的扫描线多边形/线段光栅器,
  文本用 Hershey 笔画字体。
- **不做(2026-10-12 决定)。** 交互/GUI 图表与 EmoUI 画布。EmoUI
  不是 Emo 的目标,今天也没有绘制动词,所以这是一条独立的 EmoUI
  方向(共享的向量画布契约),不是绘图步骤。3D 与动画同样排除。

每一步都以仓库构建全绿收尾,和所有步骤一样。

## 对语言与编译器的诉求

明确写出来,好让它们被有意识地决断,而不是在实现中途被撞见:

1. **数值方法分派对齐(`c`、`wasm`、`beam`)**——这是阻塞项,不是
   锦上添花。多半就是 `ocaml` 与 `typescript` 发射器已经在做的同一套
   lowering。
2. **spike 撞上的 `ocaml` specialization 缺陷**
   (`non-native expression in specialized body`、`Type_ref margin_t`)。
   这是 bug,不是设计项;先报它。
3. **浮点数学放进一个标准库 `math` 包**(2026-10-12 决定):纯 Emo、
   五个目标,暂时以绘图所需为限——`exp`、`log`、`log10`、`pow`、
   `sqrt`、`min`、`max`、`abs`、`clamp`、`e`、`pi`;三角函数暂缓;
   `normal_quantile` 与 `normal_cdf` 放 `plot.stats`。它在 `c`/`ocaml`
   上的可选 `foreign def` 快路径写明与目标绑定。不放核心,也不做包内
   私有。`CHECK.md` 条目已经记录了当前原语在各目标上的不完整,所以这是
   已知的开放领域,而非意外。
4. **默认参数**——先按 `with_*` 样式设计把库建起来(见"Emo 里的
   API"),它不改语言;让真实图表代码决定参数默认值是否挣得位置,
   并与第二个消费者一起决断。
5. **不加新语法。** 一个绘图库应当能用当下的语言表达;如果它需要
   某个构造,那是这个构造不对的证据,不是这个库的。

## 风险与诚实的保留

- **性能。** 解释器下生成 SVG 能舒服地处理数千个点,但处理不了数百
   万;密集散点与光栅化属于 `c` 目标。specialization 很重要——基准
   套件就是用来量它的。
- **确定性与原生数学。** *已接受(2026-10-12):* `math` 包默认是
  纯 Emo 且逐字节一致;它的原生 `foreign def` 快路径为可选加入,输出
  写明与目标绑定,所以默认路径保住了逐字节 golden 惯例。
- **文本尺度。** 没有字体引擎,自动布局要么近似(步进表),要么
  局限于随包字体。这是 gnuplot 做过的同一取舍,几十年来都可接受,
  但要写出来,不能藏。
- **范围。** Matplotlib 的表面实际上无界(投影、日期区域设置、3D、
  动画、GUI 事件循环)。分档表就是防线:T0 + T1,声明清楚,其余明确
  排除。
- **没有泛型。** 每种数值类型在包内要有自己的排序与归约辅助。有界,
  但确实是要靠语言消不掉的重复。

## 先例,以及该借什么

按项目的设计哲学,机制可以借,但任何单一语言的表面都不能照抄。

- **Matplotlib**(Python)——值得拿的是 Artist 模型与可插拔后端(光栅
  的 Agg、矢量的 SVG/PDF);不要的是全局 pyplot 状态,以及
  `Axes`/`Axis`/`Artist` 那套命名层级。
- **Seaborn**(Python)——面向数据集的映射(数据列 → 美学)、统计
  变换、主题与调色板。它的 API 是第 4 层的范本。
- **ggplot2 / Vega-Lite / Observable Plot**——图形语法与 spec 优先的
  取向,以及 SVG 优先输出。*已采纳(2026-10-12):* Emo 的表面是
  声明式的——一次调用渲染一个 `Figure` 值——而不是就地改动的 `Axes`
  对象。
- **gnuplot**(C)——终端后端、Hershey 字体、一个核心多种输出格式。
  SVG + 终端 + PNG 计划最接近的祖先,也是"这个计划古老而可靠"的
  证明。
- **Elixir 的 `VegaLite` 与 `UnicodePlot`**——BEAM 谱系的两个答案:
  发一份 spec,或者画到终端。两者都贴 Emo 的 actor 与文本优先世界。
- **Go 的 `gonum/plot`**——证明一个小型纯语言绘图库、带渲染器接口与
  SVG 后端,是一个人就能做的项目。借机制,不借命名与 API 形状。

## 建议

站得住脚的第一个产品,现在已作为方向定案:**一个 `plot` 包——纯
Emo、SVG 优先、声明式、`Renderer` 接口、逐字节 golden 校验,T0,其上是
Seaborn 式的 `plot.stats` 子模块——前置为数值分派对齐与一个标准库
`math` 包。** 不需要任何语言改动。任何原生
GUI 画布都是日后
一条独立的 EmoUI 方向,绝不能门控本项工作。“完整的 Matplotlib 与
Seaborn 对等”从目标表述中删掉,换成声明清楚的档位 T0 + T1。

## 已记录的决定(2026-10-12)

1. **输出先后——SVG 优先。** `plot` 只交付 `SvgRenderer`;终端与 PNG
   是后续的 `Renderer` 实现。
2. **样式 API——按 mark 的样式类配 `with_*` 复制方法**,由 mark 值
   携带,不改语言。默认参数暂缓;详细对比见"Emo 里的 API"。
3. **表面——声明式。** 一张图是一个 `Figure`/`Axes`/`Mark` 值图,
   一次调用渲染。
4. **数据——一个最小 `Table`**:列式,数值列 `Map[String, Array[Float64]]`、
   分类列 `Map[String, Array[String]]`,缺失数值用 `NaN`;由
   `plot.stats.table(numbers, labels)` 构造并校验;数据集通道用
   `Map[String, String]` 命名。
5. **包——一个 `plot`**,声明五个宿主目标,Seaborn 式层是它的
   `plot.stats` 子模块。
6. **数学——一个标准库 `math` 包**,默认纯 Emo 且逐字节一致,
   以绘图所需为限(见第 13 条)。
7. **确定性——接受可选加入的原生快数学路径**,写明与目标绑定。
8. **流程——先留这份 `docs/` 笔记**,等数值基底工作被拆细后再开
   `plan/step-NN-*.md`;`README.md` 等已定设计。
9. **EmoUI——现在不做。** EmoUI 不是 Emo 的目标:它是跑在 Emo
   native 目标之上的库,平台后端是 OS 工具包,且当前契约是摆放控件、
   没有绘制动词。因此交互/GUI 图表被排除在本项工作之外。若将来真做
   画布,共享的向量画布契约是一条**独立的 EmoUI 方向**(2026-10-12
   接受),不是绘图后端。
10. **`Table` 与通道——即上面的具体形状。** 列式、两张 Map、缺失数值
    用 `NaN`、`plot.stats.table(...)` 形状违例时 raise、通道用
    `Map[String, String]`(接受运行期通道名校验)。
11. **mark 不做直通。** mark 唯一的样式入口是 `with_style`;样式类保留
    自己的 `with_*` 复制方法。
12. **渲染器先后——终端,然后 PNG。**
13. **`math` 以绘图为限**:`exp`、`log`、`log10`、`pow`、`sqrt`、
    `min`、`max`、`abs`、`clamp`、`e`、`pi`;不做三角函数;
    `normal_quantile`/`normal_cdf` 放 `plot.stats`。
14. **声明式树只用数组**——不做尾随块写法。

## 剩余的开放问题

1. **通道词表。** 确切的键名——`x`、`y`、`hue`、`size`、`style`、
   `row`、`col`——等 `plot.stats` 细化时定下来。
2. **`math` 快路径的拼写。** 可选的原生路径怎么选,是逐调用还是包级。
3. **从哪里开工。** 暂缓(2026-10-12 决定):设计还没定完,先不开
   `plan/step-NN-*.md`。
