# Emo 与可视化 —— 一份评估与一个设计方向

写于 2026-10-12。这是一份技术可行性评估外加一个提议方向,不是已定的
设计决策;文中关于项目状态的描述以写作日期的仓库为准(`develop`,
`v0.28.1`)。在它进入 `CHECK.md` 并定案之前,任何内容都不写进
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
| **T3** | 交互/GUI 图表(EmoUI 画布)、3D、动画 | 有前置门:需要画布动词契约、一等回调、内存回收(见 emo-ui 清单) |
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
- **它与既有的东西组合。** SVG 可以直接落进 HTML 给浏览器看;
  `wasm` 与 `typescript` 目标可以把 SVG 注入 DOM;而未来的 EmoUI
  画布,不过是同一份场景描述的第二个消费者。
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
   会报 E4009。命名参数有,默认值没有。于是样式选项需要类型化载体或
   预设(见 API 草稿),这是一个真问题,不是脚注。
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
`UnicodePlot` 的精神)与 PNG 光栅器是同一接口的后续实现;EmoUI 画布
是第三个。这就是 Matplotlib 的 Artist/Renderer 拆分,也与 GUI spike
已经立起的九动词 `ui_*` 契约同形。

### 第 1 层 —— 几何、比例尺、刻度

`Point`/`Rect` 用普通元组或小类;线性、对数、band、时间比例尺;
色图;以及 "nice numbers" 刻度定位与格式化(Heckbert 的 `nicenum`,
约三十行,也是坐标轴看起来专业而非"算法味"的原因)。除了对数与时间
比例尺需要缺口 1 的数学层,其余全是语言今天就能做的算术。

### 第 2 层 —— 图与坐标轴

一个显式的对象模型:`Figure` 持有一个或多个 `Axes`,每个 `Axes` 有
自己的比例尺、mark、样式、图例与标签。

```
const fig = plot.figure(width: 800.0, height: 600.0, title: "Monthly sales")
const ax = fig.axes()
```

刻意**不要 pyplot 式的全局状态**:Emo 的最小惊讶原则反对隐藏的
"当前图"与"当前坐标轴",而这恰是 Matplotlib 最受批评的设计决定。
构造一张图就是一次普通调用,返回一个普通值。

### 第 3 层 —— Matplotlib 式的表面

mark 就是 `Axes` 上的普通函数:`ax.line(x, y)`、`ax.scatter(x, y)`、
`ax.bars(labels, values)`、`ax.area(x, y)`、`ax.hist(values, bins)`。
复合便利函数(`plot.line(x, y)` 自建一张图)叠在其上。

### 第 4 层 —— Seaborn 式的表面

在同一个引擎之上的、面向数据集的 API。Seaborn 的洞见是:一张图就是
从数据列到美学通道的*映射*,加一个统计变换,加一个 mark,再按一个或
多个分组列分面。Emo 用 `Map` 与 `Array` 恰好能表达:

```
plot.relational(data, x: "total_bill", y: "tip", hue: "time")
plot.distributions(data, x: "tip", hue: "smoker")
plot.categorical(data, x: "day", y: "total_bill", kind: "box")
plot.matrix(data)
```

其下的统计子层:`describe`、`quantile`、`histogram_bins`、`kde`、
`ecdf`、`ols` 加置信带、`box_stats`,以及一个确定性的 PRNG。全是纯
算术;KDE 与正态分位需要数学层。

**最小表类型**是这一层唯一需要的新数据结构——Emo 没有 data-frame。
一个 `Table` 类,持 `Map[String, Array[Float64]]` 外加列名,或者
`Array[String]` 列名配 `Array[Array[Float64]]` 列数据,就够了;它
绝不能再长成 pandas。

### 第 5 层 —— 其它后端与交互

终端输出(T0 的低成本第二渲染器)、PNG(T2)、EmoUI 画布(T3)。
交互——悬停、缩放、图例开关——只属于这里;它受 emo-ui 清单的前置门
约束(跨 FFI 的回调、内存回收、画布动词),而且不应反过来塑造静态
API。

## Emo 里的 API

不需要任何新语法,这本身就是设计合身的强信号。有两件事需要决断,
而它们才是有意思的部分。

**mark 如何携带样式。** 没有默认参数,于是一个 mark 可以显式收全部
选项,或收一个类型化的 `Style` 值,或返回一个可链式设置的不可变
mark。三条路各带代价:

- *所有参数都放函数上*——完全显式且严格,但每次调用都要写颜色、
  线宽、虚线、标记、透明度、标签,哪怕一个都不想要。不可用。
- *类型化 `Style` 载体*——`Style.new(...)` 同样要求每个字段,于是
  绘图包提供命名预设(`plot.default_style`、`plot.grid_style`)和
  按 mark 的构造器。类型化且严格,代价是仪式感。
- *可链式 mark*——`ax.line(x, y).color("#2f6fb3").width(2.5)`,每个
  方法返回一个复制字段的新不可变 mark。读起来最好,且是普通代码
  (没有新构造),但每个选项都要手写一个复制方法。
- *语言层面的默认参数*——最干净的解法,也是一个真实的语言诉求。它
  只有在出现第二个不相关的消费者时才挣得位置;单凭一个绘图库不足以
  构成正当理由,这是项目规则。

建议:先用类型化 `Style` 载体加预设;如果证明值得这份样板,再把
可链式形态做成包级的人体工学层;默认参数作为语言问题,等真实的 API
摩擦被记录下来之后再议。

**数据进,mark 出。** 位置式表面(Matplotlib 式,`ax.line(x, y)`)与
数据集表面(Seaborn 式,`plot.relational(data, x: "col")`)都属于同一个
引擎;它们是通向第 3 层的两扇门,不是两套实现。

**预期失败是值。** 依循标准库惯例,保存时路径打不开、`Table` 缺某个
命名列、直方图没有值,都返回 `(R.ok, value)` / `(R.error, reason)`;
只有真正的契约违反才 raise。这是正在落地的错误处理约定
(`CHECK.md`,M12),绘图包必须从第一天起就按它写。

## 命名与打包

标准库拥有顶层短名,包名是单个小写单词(`json`、`yaml`、`http`、
`base64`)。**`plot`** 是自然的名字——通用、英文、不是任何单一工具
表面的复制。Matplotlib 式与 Seaborn 式两个表面可以放进一个包(接缝
是内部的模块边界),统计层也可以单列成第二个包。先从**一个声明全部
五个宿主目标**的 `plot` 包开始(`ocaml`、`c`、`typescript`、`wasm`、
`beam`;freestanding 的 `riscv64` 不在范围内——它拒绝 `Map`),是保守
的选择,和那些格式包完全一致。

## 工作顺序

依赖是真实的,所以顺序不是随意的:

- **A. 先做数值基底。** 补上缺口 2(`c`/`wasm`/`beam` 的浮点方法
  分派),并落地纯 Emo 数学层(`log10`、`exp`、`log`、`pow`、三角
  函数、正态分位)。没有这两样,包无法声明五个目标,统计层也建不
  起来。这是门控步骤。
- **B. T0 核心。** `Buffer`、比例尺、刻度、`Style`、`Renderer` 接口、
  `SvgRenderer`,以及带坐标轴、图例、标题的折线/散点/柱/面积/直方图。
  出口条件:`examples/plot_demo` 产出的一批 SVG 在五个目标上逐字节
  一致——标准库的 golden 标准。
- **C. T1 统计。** `Table`、描述统计、分箱、KDE、ECDF、箱统计、带
  置信带的 OLS、分类与矩阵家族、分面、调色板与主题。
- **D. 终端渲染器。** 便宜的第二后端;让图在 CI 与 CLI 里可见。也
  是对"第 0 层真的与格式无关"的诚实检验。
- **E. PNG。** 纯 Emo 的 zlib(stored,再到固定 Huffman 的 DEFLATE
  块)、CRC32 与 Adler-32,以及带超采样的扫描线多边形/线段光栅器,
  文本用 Hershey 笔画字体。
- **F. EmoUI 画布。** 交互图表,受 emo-ui 清单的前置门约束;在那个
  包存在之前不在范围内。

每一步都以仓库构建全绿收尾,和所有步骤一样。

## 对语言与编译器的诉求

明确写出来,好让它们被有意识地决断,而不是在实现中途被撞见:

1. **数值方法分派对齐(`c`、`wasm`、`beam`)**——这是阻塞项,不是
   锦上添花。多半就是 `ocaml` 与 `typescript` 发射器已经在做的同一套
   lowering。
2. **spike 撞上的 `ocaml` specialization 缺陷**
   (`non-native expression in specialized body`、`Type_ref margin_t`)。
   这是 bug,不是设计项;先报它。
3. **浮点数学**——优先包内纯 Emo 层,只有出现第二个消费者才提升到
   核心。`CHECK.md` 条目已经记录了当前原语在各目标上的不完整,所以
   这是已知的开放领域,而非意外。
4. **默认参数**——**不要**预防性地加。记录摩擦;等第二个消费者,
   作为语言问题一起决断。
5. **不加新语法。** 一个绘图库应当能用当下的语言表达;如果它需要
   某个构造,那是这个构造不对的证据,不是这个库的。

## 风险与诚实的保留

- **性能。** 解释器下生成 SVG 能舒服地处理数千个点,但处理不了数百
   万;密集散点与光栅化属于 `c` 目标。specialization 很重要——基准
   套件就是用来量它的。
- **确定性与原生数学。** 如果 `sin`/`exp`/`log` 经由 `foreign def`
  走平台 `libm`,跨机器、跨系统的末位差异会改变 SVG 字节,破坏逐字节
  golden 惯例。纯 Emo、固定顺序的数学层是唯一能保证输出一致的路;
  原生路径可以作为可选快路径存在,但要在文档里写明其输出与目标绑定。
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
  取向,以及 SVG 优先输出。一个一次调用即渲染的声明式 `Figure` 值是
  可能的 Emo 表面;应当与命令式 `Axes` 表面权衡,而不是默认选它。
- **gnuplot**(C)——终端后端、Hershey 字体、一个核心多种输出格式。
  SVG + 终端 + PNG 计划最接近的祖先,也是"这个计划古老而可靠"的
  证明。
- **Elixir 的 `VegaLite` 与 `UnicodePlot`**——BEAM 谱系的两个答案:
  发一份 spec,或者画到终端。两者都贴 Emo 的 actor 与文本优先世界。
- **Go 的 `gonum/plot`**——证明一个小型纯语言绘图库、带渲染器接口与
  SVG 后端,是一个人就能做的项目。借机制,不借命名与 API 形状。

## 建议

如果确实要这项能力,站得住脚的第一个产品是:
**一个 `plot` 包,纯 Emo,SVG 优先,带 `Renderer` 接口与逐字节 golden
校验,先覆盖 T0 再覆盖 T1。** 它需要一个门控前置(数值分派对
齐 + 纯 Emo 数学层),不需要任何语言改动。日后它可以与 emo-ui 画布
共用,但绝不能等它。"完整的 Matplotlib 与 Seaborn 对等"应当从目标
表述中删掉,换成声明清楚的档位。

## 待讨论的开放问题

1. **输出格式的先后。** 上面论证了 SVG 优先;终端渲染器是否值得排到
   PNG 之前(更便宜,且能压测第 0 层)?在真有消费者需要之前,PNG
   值不值得做?
2. **样式 API。** 类型化 `Style` 载体加预设、可链式不可变 mark,还是
   语言层的默认参数机制?
3. **声明式与命令式表面。** 一次调用渲染的 `Figure` 值、通过 mark
   改动的 `Axes` 对象,还是两者都要?第 4 层可以在命令式第 3 层之上
   做成声明式,但接缝要有意识地选。
4. **表类型。** 数据集层到底需不需要 `Table`,还是用
   `Map[String, Array[Float64]]` 与元组就够?多少结构才值得引入?
5. **包拆分。** 一个 `plot` 包,还是 `plot` 加一个统计的
   `seaborn`-对应包?第二个包叫什么?
6. **数学层的归属。** 包内、公开的 `math` 包,还是核心?(建议先包内。)
7. **确定性策略。** 可选的原生快数学路径、其输出与目标绑定,可以
   接受吗?还是每个目标的 SVG 必须逐字节一致,没有例外?
8. **工作落在哪里。** 方向定了之后开一个新的 `plan/step-NN-*.md`
   步骤,还是先写一份 `docs/` 设计笔记?
