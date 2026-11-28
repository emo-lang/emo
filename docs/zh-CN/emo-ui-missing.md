# EmoUI —— 还缺什么

写于 2026-11-24。这是一份评估，不是已定设计。它记录 `feat/emo-ui`(在 `develop` `b053a766` 之上，至 `4d0088fa`)这个时点上，树里有什么、缺什么，衡量的只有一个问题:**要在 EmoUI 上构建复杂、健壮的跨平台 GUI 软件，还差什么?** 它不决定任何事，也不提议任何语法。架构及其背后的证据在 [`emo-ui.md`](emo-ui.md)，每个包真正实现了什么以 `projects/emo-ui/docs/` 下的参考为准;下文每一条论断都以代码为准，并注明是在哪里读到的。

## 简短的回答

EmoUI 证明了一件事:同一棵声明式树能渲染到终端、服务端渲染的页面、AppKit 窗口、GTK 4 窗口、浏览器 DOM 和 EmoOS 帧缓冲，并且凡是能比字节的地方都逐字节一致。除此之外，它还没有被要求做更多。对照上面的问题，缺的是六组能力，而其中前四组大都可追溯到核心里的一行——后端每次事件只交给应用一个整数:

```emo
interface Events {
  def deliver(tag Int64) Void
}
```

一次文本编辑、一次按键、一个指针位置、一个新的窗口尺寸，都是事件，而它们没有一个是整数。输入模型的其余部分都由此而来。

## 「复杂而健壮」在这里的含义

缺口是用这把尺子量的，把它写明，是为了可以拿来争:

- **复杂** —— 许多屏幕，由应用自己定义的组件搭成;数据驱动的列表;能接收键入文本的表单;真正的排版与视觉识别;一跑几个小时的会话。
- **健壮** —— 一个坏事件不会结束进程;同一个输入在每个平台上含义相同;长会话的内存保持平稳;错误在发生的地方被拒绝，而不是被悄悄渲染出来。

## 树里已经有的

可移植核心(`projects/emo-ui/ui.emo`):八个节点类——`Column`、`Row`、`Scroll`、`Text`、`Button`、`TextInput`、`Image`、`Spacer`;一个只有六个布局属性的 `Style`(`padding`、`gap`、`align`、`grow`、`width`、`height`);Elm 循环(`run`，以及给本来就是整数的消息用的 `run_raw`);把消息变成 tag 的 `Registry`;保留式 diff(`ui.diff`，2026-11-24 落地);以及后端接缝(`mount`/`patch`/`run`)。各后端用它做出了什么:

| 后端 | 怎么渲染 | 真正能搭出什么 | 真正接什么输入 |
|---|---|---|---|
| `ui_tui` | 字符网格，写成 ANSI | 这个网格 | 一份脚本化的 tag 列表(`Script`);`term` 包没有接进来 |
| `ui_ssr` | HTML 加一份驻留的样式表 | 这个页面 | 没有——一次请求由外部步进一个事件 |
| `debug` | 一份文本日志 | 这份日志 | 没有——由外部步进 |
| `ui_macos` | 经 `shim.m` 走 AppKit | 一个窗口、标签、按钮 | 按钮点击 |
| `ui_gtk` | 经 `shim.c` 走 GTK 4 | 一个窗口、标签、按钮 | 按钮点击 |
| `ui_browser` | 在 `dom_*` 之上的 DOM | `span`、`button`、`input`(只读)、`img`、`div` | 按钮点击 |
| `ui_fb`(`projects/emo-desktop/fb`) | 像素与 Strike 字体 | 画出来的表面 | 一串 tag:seat 的按键，以及解析到某个 `Button` 矩形上的指针点击 |
| Wayland 上的 `ui_fb`(`projects/emo-desktop/wayland`) | 合成器表面上的帧缓冲 | 画出来的表面，若干顶层窗口 | seat 的按键与指针，在核心之外解码 |

每一行渲染的都是同一份收敛语料(`projects/emo-ui/corpus/`)，门禁钉的正是这一点。各行不共享的东西，才是本文余下的主题。

## 1. 输入模型

**文本输入。** *载荷的那一半已于 2026-11-28 落地(`feat/emo-ui`);下面的键盘与焦点那一半仍然开着。* `TextInput` 现在带事件，`deliver(tag, text)` 带着键入的文本:Web 与原生后端握住可编辑控件，把每个字段的文本经 `Registry.on_text` 登记的 tag 投回;kept 字段的文本在中间的多次渲染里保得住;SSR 字段的值以 `emo-<tag>` 之名随 POST 到达。注册表「每个值一个 tag」的限制随之了结(按名字去重的工厂取代了按值的 tag)。这个字段仍然没有自己的按键事件——没有焦点、没有应用看得见的插入点、没有 Tab 遍历——那是下面一段的事。

落地之前:`TextInput` 展示模型的值，不带事件，所以在每个后端都是只读的:`ui_ssr` 输出 `readonly`,`ui_browser` 设置 `readOnly`，原生后端把它做成一个标签。没有任何应用能通过核心在任何平台上拿到一行键入的文本。

**键盘与焦点。** *键的那一半已于同日落地(2026-11-28，`feat/emo-ui`):事件是 `deliver(tag, text, key)`，一个字段用 `on_input` 登记一个 tag 同时收文本与键，后端把 toolkit 不消费的键——拥有字段处 Enter,GTK 与 DOM 加 Escape——投到焦点字段的 tag 上。焦点本身保持 toolkit 内部，已决定:路由键需要焦点控件，而 toolkit 本来就知道;焦点**模型**——事件、转向、应用看得见的插入点、核心里的 Tab 遍历——是下一个输入模型轮，在它落地之前，应用依旧问不出哪个控件握着键盘。*经由核心接缝的其余部分，后端能递交的事件只有按钮的点击——保留控件的三个后端接的恰恰只有这一个(`projects/emo-ui/macos/shim.m`、`projects/emo-ui/gtk/shim.c`、`projects/emo-ui/browser/ui_browser.emo` 的 `dom_connect`)——终端上则是一份脚本化的列表。真实的按键和真实的指针位置，只在桌面项目自己解码它们的地方才到达，也就是帧缓冲的 seat 和 Wayland 客户端的 `LiveInput`，并经 raw loop 以整数交给 `update`，由应用自己去解释。核心里没有焦点:没有被聚焦的节点，没有焦点顺序，没有 Tab 遍历，应用也没法问哪个控件正握着键盘。

**指针与滚动。** 核心没有任何一种指针事件——移动、拖拽、滚轮、悬停、右键菜单都没有;指针能到达应用的地方，它也只是落在某个 `Button` 矩形上的一次点击(`projects/emo-desktop/fb/ui_fb.emo` 的命中表)。`Scroll` 不是视口:在帧缓冲上它「measures and places exactly like a column」——量出来、放下去都和 column 一模一样(`ui_fb.emo`)，终端那边的 `projects/emo-ui/tui/ui_tui.emo` 则说它「not yet a viewport with an offset」;在原生后端上它是定高的 column，只有 Web 两端会滚动它，靠的是 CSS 的 `overflow: auto`——而且不会告诉应用，因为滚动偏移正是这条接缝带不了的事件。

**窗口事件。** 核心自己没有窗口。窗口是后端的，每个原生后端一个(`shim.m` 与 `shim.c` 各自只持有一个窗口)，尺寸是一个参数:`backend(title, width, height, script)`，而「reading the screen size and reflowing on resize is not wired yet」——读取屏幕尺寸、在缩放时重排，还没有接(`projects/emo-ui/docs/ui_macos.md`)。没有缩放事件，也没有缩放系数。

## 2. 组件词表

八个节点就是全部可移植词表。缺的是复杂应用赖以构成的控件——开关、复选框、单选组、滑块、下拉、列表、表格、标签页、菜单、对话框、进度指示、提示——以及组织屏幕的容器:没有东西能层叠或覆盖，没有东西能放到显式的位置上，没有分隔线，也没有多行文本。

在原生后端上词表还要更薄。`ui_macos.emo` 的 `make` 给 `Button` 造按钮，给其余一切造标签，于是 `Text`、`TextInput`、`Image`、`Spacer` 全是标签——`Image` 显示的是它的 `src` 字符串。只有 Web 两端能显示图片。

组件没有属于自己的状态。循环只有一个 model，控件本想自己收着的东西——光标、滚动位置、菜单开没开——要么进那个 model，要么进一个由应用手工管理的 `Box`([`emo-ui.md`](emo-ui.md)，Layer 5)。一个有四十个控件的屏幕，就是应用要亲手写的四十份簿记。

## 3. 样式与排版

`Style` 只有布局，别无其他。没有颜色、字体、字号、字重、边框、圆角、可见性、不透明度，于是没有主题，也没有深色模式:调色板只存在于金属桌面的皮肤层(`projects/emo-desktop`，M30–M31)，可移植核心从没见过它。

文本只有一行。核心和所有托管后端里都没有折行、选区、剪贴板和输入法;金属桌面长出的剪贴板是它自己的(`projects/emo-desktop/docs/TASKS.md`，M34)。字体只以帧缓冲的 `raster.Strike` 和浏览器根元素的 `system-ui` 两种形态存在。

布局没有层叠、没有绝对定位、没有溢出规则、没有最小或最大尺寸，原生后端按每字符八个 point 估算文本宽度(`projects/emo-ui/macos/box.emo`，GTK 包里是同一份)。同一个样式数字并不是同一个长度:`box.emo` 以 point 量它，`ui_tui` 以字符格，`projects/emo-ui/browser/css.emo` 以 CSS 像素。评估文档在这里不许诺任何事:「no layout parity guarantee」——不保证布局一致——就在它列出的 v1 不提供的东西之中([`emo-ui.md`](emo-ui.md)，Risks)。

## 4. 应用架构

**副作用与异步工作。** `update` 和 `view` 是纯的，而一个事件期间不允许发生别的事:定时器、网络应答、文件读取、来自另一个进程的消息，都没有被建模成进入树的方式。评估文档在「Two event loops」之下点出了原因——工具包的循环阻塞在 `ui_run()` 里，而 Emo 的调度器并不拥有那个线程([`emo-ui.md`](emo-ui.md)，Layer 5)——它今天和当时一样开放。

**从错误中恢复。**「A raise cannot be caught — Emo has no catch construct」——raise 接不住，Emo 没有 catch 构造([`intro/syntax.md`](intro/syntax.md));未处理的错误会结束它所在的那个进程([`intro/concurrency.md`](intro/concurrency.md))。事件循环跑在一个进程里，所以一个事件处理器里的异常会结束整个应用。语言提供的隔离单元是进程，而由许多进程搭成的 UI，恰恰是双事件循环那个问题尚未回答的东西。

**规模。** 每个事件都重建整棵树，注册表靠遍历自己的表来找消息的 tag(`Registry.index_of`)。正如 `ui.emo` 说它自己的表:「a message that carries a value is a distinct message per value, so a message built from a changing string (a text field's own contents) allocates a tag per render」——带值的消息每个值都是一条不同的消息，所以由变化的字符串构造的消息(文本框自己的内容)每次渲染都新占一个 tag。没有虚拟化列表，没有惰性视图。保留式 diff 是第一步，不是最后一步;README 承诺的编译器定向刷新，用评估文档的话说，仍是它的长期形态。

**长会话。** `c` target 会回收一次渲染分配的东西(step 49)。金属不会:它的 `Bytes` 是永久性的 bump 单元(`CHECK.md`，crypto 验证轮)，所以一个每事件都分配的帧缓冲应用，跑多久就涨多久。

## 5. 平台覆盖

EmoUI 抵达 macOS、经 GTK 4 与经 Wayland 的 Linux、浏览器、终端和 EmoOS。它没有原生抵达 Windows——工具链自身只支持 WSL2([`toolchain-distribution.md`](toolchain-distribution.md))——也没有抵达任何移动平台。没有无障碍:没有任何角色、标签或焦点状态到达平台的无障碍树;树里唯一一次提到无障碍，是 GTK 门禁把它关掉。对核心而言文本就是字节;从右到左的布局和输入法在树里任何地方都没有出现。也没有打包方案:「No packaging/app-store story」正是 [`emo-ui-check.md`](emo-ui-check.md) 列为刻意不做的那一条。

## 6. 语言给了什么，又扣住了什么

这些是关于 Emo 的事实，而不是请求;列在这里，是因为它们定下了上面每一样东西的代价。

- 没有泛型，也没有默认参数([`emo-ui.md`](emo-ui.md)，Risks):八个节点类各自重复 `style()`、`children()` 和 `key()`，而 diff 用来匹配的 key 在八个类里各花了一次改动。
- enum 是一个封闭的具名值集合，不带数据([`intro/syntax.md`](intro/syntax.md)):带载荷的消息是类实例或 `(R, value)` 元组，这也是为什么文本输入是一个设计问题，而不是一个下午的活。
- `Block` 是未知层:`view`、`update` 和每一个回调都不受检查([`emo-ui.md`](emo-ui.md)，关于带检查的函数类型那个遗留问题)。
- 模块级绑定每次读取都重跑初始化式，所以状态住在对象里(`ui.emo`，关于注册表的注释)。

## 一座平台有、核心没有的东西

金属桌面跑在了核心前面。在 `projects/emo-desktop/fb/` 之下:`pointer.emo`、带两款字面的 `raster.emo`、动效词表(`desktop/emo_motion.emo`)、一个图标族、一套皮肤调色板(M30–M31)、窗口 chrome 与通知。每一样都在一个后端上被证明过，又没有一样是可移植的。它们是「这些能力能用 Emo 建出来」的证据，也是可移植核心落后于项目已经在跑的东西多远的一把尺子。

## 哪些已在记录里，哪些没有

项目的记录里已经点过名的:双事件循环与带检查的函数类型([`emo-ui.md`](emo-ui.md)，遗留问题)、编译器的定向刷新、画布、无障碍、动画与布局一致性([`emo-ui.md`](emo-ui.md)，Risks;`docs/visualization.md`)，以及打包。

在本文之前没上过任何清单的:文本输入与带载荷的事件;键盘事件与焦点;指针与滚动事件;缩放;`Style` 里的颜色与排版;组件局部状态;从失败的事件中恢复;Windows。

## 第一个应用证实了什么(2026-11-24)

计算器是 `apps/` 下的第一个应用——它的 README 是
[`apps/calculator/README.zh-CN.md`](../../projects/emo-ui/apps/calculator/README.zh-CN.md)
——也是一个人会用的应用里最小的一种，它需要的只有每个后端都递交的那一种事件。写它证实了上面两条，并且找出四条没上过任何清单的。

证实的:一个窗口只接点击，别的都不接，终端入口重放脚本是因为后端没有按键源(第 1 节);`Style` 只说布局、别的都不说，于是显示没有字号、颜色和对齐(第 3 节)。

新的，连同计算器的做法:

1. **`Style` 的数字没有单位。** 同一个间距，在终端上是一格，在窗口里是一点，在 web 上是一像素;应用把间距当作参数，由每个入口传入自己平台的数字。
2. **一个节点没法要「均分」。** `grow` 分的是每个子节点自身宽度之外剩下的部分，所以只有在标签按字符量的地方键才是等宽的。在浏览器里，一个运算符键是 40 px，而数字键是 46。
3. **标签是字节。** 终端量按钮的标签、帧缓冲画它，都是一次一个字节，所以没有任何一个键能写成 `×`、`÷`、`±` 或 `⌫`。
4. **叶子节点没有自己的高度。** 在以字符格或字形行框为单位的地方，一个键只有一行高，而 `Style` 里的 `height` 会是同样多的格数和像素。

它的 README 带着每一条的证据。这里不作任何决定。

## 接下来

**已决定并落地，2026-11-28(`feat/emo-ui`)。** 事件是 `deliver(tag, text, key)`——单方法，载荷以方法自己的编组参数穿过，因为 C→Emo 回调契约只认单方法接口，而 `String` 与 `Int64` 都在它的编组层里。带值的消息是应用自己的类，由 registry 按名字存下的工厂构造(`on_input`——一个字段一个 tag，收文本也收键)，「每个值一个 tag」的限制在同一轮里了结。握着可编辑控件的后端，以「kept 字段只在模型的值不同时才写回」在多次渲染之间保住按键，并把 toolkit 不消费的键投到焦点字段的 tag 上。决定消息形状的是语言的两个事实:`is()` 对枚举成员直接 raise，所以带一份载荷的循环，每条消息都是类实例(无字段的类照样去重——类实例的相等是结构相等);raw 循环拒绝任何一种载荷，因为它的消息就是 tag 本身。形状记在 [`emo-ui.md`](emo-ui.md) Layer 5。

这份决定带走的是文本与键。之后，按依赖允许的顺序:焦点模型(事件、转向、插入点——键的路由已经骑着 toolkit 的);指针、滚动、缩放;一个说得出颜色的 `Style`;副作用模型，连同一直是它一部分的双事件循环问题;然后才是更宽的组件词表——控件要等输入和样式能服务它们之后，才变得便宜。
