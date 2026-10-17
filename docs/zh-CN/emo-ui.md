# EmoUI —— 一份评估与一个设计方向

写于 2026-10-14。这是一份技术可行性评估外加一个设计方向,不是已定设计。文中关于项目状态的描述以写作日期的仓库为准(`develop`)。定下来的决定会进入 `README.md`;本文档记录评估、评估背后的证据,以及开放问题。

问题:**一套声明式 EmoUI 语法,渲染到 Web、终端(TUI)、macOS(AppKit)与 GTK 4——每个平台可以有自己的组件库,但组件的调用与组合方式完全一致。**

让项目走到今天的关口清单见
[`emo-ui-check.md`](emo-ui-check.md);两个原生工具包的证据在
`spike/macos-gui`、`spike/gtk` 与 `spike/components`。本文档补上另外两组证据:
`spike/emo-ui-probe`,四个程序,钉死语言今天给声明式树的边界在哪;以及
`spike/arena-scope`,它实测了 `c` 目标上一次渲染的代价,并排除了廉价的解法。

## 结论

**可行,但要分档——而且语法是容易的那一半。** 这个需求读起来像语法问题(「同一套语法、四个平台」),但语法里没什么可加的:组件树本来就是带 block 的嵌套调用,那就是普通的 Emo。难的是共享表面底下的**语义契约**——布局、事件、文本、生命周期——以及这四个平台是四种不同的程序(保留式工具包主循环、浏览器事件循环、阻塞式终端读取、服务端字符串渲染器)。

四条发现决定了下面的一切:

1. **声明式树今天不受类型检查,而且它最漂亮的那种写法不成立。** 声明为 `Block` 的参数对检查器来说是 `Unknown`,所以尾随 block 里的内容是动态检查的(顶多如此);而一个 body 是一串子节点调用的 block 产出 `void`,子节点被悄悄丢弃。README 里那份示意树(`page(...) { navbar() { ... } }`)不是一个可执行程序。子节点要么是显式的 `Array[Node]`,要么 block 必须 `return` 它们。
2. **四个平台并不同等地就绪。** macOS/AppKit 与 GTK 4 已经经 `foreign def` shim 证明可行;终端渲染器是廉价的纯 Emo;Web 最不成熟——TypeScript 目标只面向 Node(发射出的 runtime 顶部 import `node:net`、`node:fs`),而 wasm 目标的整个宿主接口只有三个 import(`println`、`abort`、`float_str`)。
3. **EmoUI 后端今天无法用包表达。** 一个包只能携带 `.c`/`.h`,并且只能链接裸 `-l` 名。AppKit 后端是 Objective-C(`.m`、`-fobjc-arc`、`-framework AppKit`);GTK 后端需要 `pkg-config --cflags --libs gtk4`。两者都装不进。方向已定——manifest 长出 per-package 原生字段,而不是应用级构建脚本(`CHECK.md`)——字段面属于 T48.7 自己的工作;在它落地之前,原生后端退回到 spike 用的应用级脚本。
4. **`c` 目标上一次渲染的内存不会被回收,而廉价的解法并不存在。** 树恰好由 arena 永不释放的那些种类搭成——子节点数组、样式 map、字符串——而 UI 每个事件重建一次。`spike/arena-scope` 实测:400 节点时每次渲染约 1 MB、约 820 个对象,两者都无界——60 fps 下约 60 MB/s、每秒约 49,000 个对象。region 能回收字节,回收不了对象,并且会把那些引用计数永久搁死。**step 49 已于 2026-10-17 落地修复:每个动态值都可回收,渲染形状的循环持有平坦的工作集**(`CHECK.md`)——demo 尺度的告诫就此退役。
5. **`Array` 没有 O(1) append**,而 `List` 无法转回可索引的 `Array`,所以已定的 children 写法——`Array[Node]` 靠 `.append` 增长、每次渲染重建——在字节与 retain 两面都是 O(k²)。T48.1 应当先定 children 的表示,或者给语言补一个廉价的数组 builder。**这后半句现在有答案了**:语言有了 `ArrayBuilder`(T49.3),用 `push` 以摊还 O(1) 把 `Array[T]` 长出来,再用 `to_array()` 交出。构造 child 列表不再为每个 child 付一次拷贝,所以 `children_of` 式的累加可以不必再绕那道嵌套 `.append` 的弯。T48.1 的表示问题——children 到底是不是数组——已由可移植核心给出答案(2026-10-15):children 仍是显式的 `Array[Node]`,而走到哪才知道的子节点列表用 `ArrayBuilder` 攒。

建议:**EmoUI 是一个独立项目——第三方,而不是标准库包——做成一个可移植的 `ui` 核心加每平台一个包;顺序上先 TUI 与服务端渲染的 HTML(纯 Emo,不需要新工具链),再原生工具包,最后浏览器 DOM。** 不加新语法。唯一值得掂量的语言诉求是一个带检查的 block/函数类型,它是便利项,不是关口。(它的托管位置在 2026-10-15 变了——放在本仓库的 `projects/emo-ui/`,而不是自建一个仓库;见下面的 *打包* 一节。)

## 需求究竟要求什么

把「同一套语法、每平台组件库」写成契约,它拆成五条断言。下面逐条评估。

- **C1 —— 组合是同一套语法。** 组件树在每个平台上用同一种方式搭建。
- **C2 —— 树是同一个值类型。** 一个组件在每个平台返回同一类值,于是组件能与组件组合。
- **C3 —— 组件库可以按平台不同。** 一个平台可以有别的平台没有的控件。
- **C4 —— 组件按其构成决定可移植性。** 用可移植原语写的组件处处可用;用平台扩展写的组件不行。
- **C5 —— 平台差异被限制在后端里。** 语言层与应用代码不知道任何平台细节。

C1 是白送的(它就是普通的 Emo)。C2 需要递归节点类型,而它如今已经能用。C3–C5 才是设计工作所在。

## 已经定下并已被证明的事

本文不重开前人已经关上的问题。

- **可达性。** 带可用回调的原生窗口已可达:macOS 经词汇表 shim 驱动 AppKit(`spike/macos-gui`),Linux 上 GTK 4 基本靠直呼 `foreign def`(`spike/gtk`)。
- **组件模型。** `spike/components` 跑通了一个 React/Elm 风格的应用——def 即组件、update/view 回路在 Emo、样式是每节点 Map 且子覆盖父、布局在 Emo 里算——经九动词 `ui_*` shim 契约在 AppKit 与 GTK 4 上逐字节一致。
- **跨模块类型。** 2026-10-14 定案为模块路径限定:`ui.VNode`、`sync.WaitGroup`;两个模块可以声明同名短名,各自是不同类型。这正是库与应用能成为独立模块与包的原因。
- **递归节点。** 树需要的两种形状如今都能通过检查:`class Node { def init(kind String, children Array[Node]) }`,以及接口在签名里指称自己(`def kids() Array[VNode]`)。spike 当年的 E4005 变通(接口 + 各自独立的具体容器)不再是被迫的选择——见 `spike/emo-ui-probe` 的 probe 2。
- **C→Emo 回调契约。** 2026-10-11 定案:单方法结构接口就是回调类型;`c` 目标发射一个 trampoline 加一个不透明 userdata handle,这一对写进 `.emo-build/emo_defs.h`。
- **README 的承诺。** 无模板语言(UI 就是普通 Emo);组件是小写 def,树里永不出现 `.new`;props 由渐进检查器检查;响应式原语是显式的;UI 事件是进程消息;后端消费树及其更新;语言层不知道任何平台。

## 四个平台

| 平台 | 路径 | 状态 | 缺口 |
|---|---|---|---|
| macOS(AppKit) | `c` 目标 + Objective-C shim,经 `foreign def` | **已证明**(`spike/macos-gui`、`spike/components`) | 打包:`.m`、`-fobjc-arc`、`-framework` |
| GTK 4 | `c` 目标 + C shim,经 `foreign def` | **已证明**(`spike/gtk`、`spike/components`) | 打包:`pkg-config gtk4` |
| TUI | 纯 Emo,输出 ANSI 转义 | **已落地**(T48.4) | 终端输入(raw mode、按键事件) |
| Web | HTML/CSS(SSR)→ DOM(浏览器 TS)→ wasm + DOM | **最不成熟** | TS 目标只面向 Node;wasm 宿主只有 3 个 import |

### macOS 与 GTK 4

两者都是 C ABI 上的 `foreign def`,两者都在 spike 里跑通了。差别在 shim 的厚度,不在架构:C 工具包不需要词汇表翻译(GTK 的 shim 约为 AppKit 的三分之一,因为 GTK 的名字本来就是 C 形状的)。九动词 `ui_*` 契约(`window_make`、`label_make`、`button_make`、`place`、`clear`、`connect`、`root`、`run`、`autotest_arm`)是 spike 证明过的可移植接缝,每平台的差异是一个约 100 行的 painter。

真正的阻塞是打包,而它是 manifest 的缺口,不是工具链的缺口:

- `docs/intro/package-management.md`(以及 `docs/c-backend.md` 的「Package-carried native code」)允许包里有 `.c`/`.h`,并且 `link` 字段只收**裸库名**。
- AppKit 需要一个用 `-fobjc-arc -framework AppKit`(或 `-framework Cocoa`)编译的 Objective-C 翻译单元;裸 `-l` 名说不出这些,而 `.m` 文件不会被收集。
- GTK 4 需要 `pkg-config gtk4` 的 cflags 与 libs;裸 `-lgtk-4` 不够(还有 glib、gobject、gio、pango、gdk 以及 include 路径)。

在 manifest 长出 per-package 编译/链接 flag 机制(或一个 `pkg_config = \["gtk4"\]` 字段)之前,原生后端无法成为普通的可消费包。spike 绕开的方式是应用级构建脚本,传 `--cclib="$PWD/shim.o"` 与 `--cclib="-framework AppKit"`。这能工作,但它让每个 macOS 版 EmoUI 应用都得扛一份构建脚本,而不是一个 `require`。这是需求隐含的全部工具链工作中最具体的一块。

**已定(2026-10-14):这个机制就是 manifest 字段,构建脚本那条路不是**(`CHECK.md`)。原生后端仍然是一个普通的包,程序用 `require` 就能取到,所以 AppKit 与 GTK 4 需要的东西声明在 manifest 里,而不是在每个使用者的脚本里重述一遍。字段面——`pkg_config` 与显式编译/链接 flag 列表之间怎么选、`.m` 是否加入被收集的 `.c`/`.h`——是 T48.7 自己的范围。

### TUI

四个平台里最便宜的,也是最好的第一个目标。渲染就是带 ANSI 转义的 `printf`——纯 Emo,在任何能写 stdout 的目标上都能跑,不需要 FFI,也不需要新的包机制。单元格网格本身就是一套布局(以字符格为单位的行/列/宽/高),正是 `plot` 终端渲染器已经规划的那类格式无关表面(`docs/visualization.md`,Layer 5)。终端后端也是检验「核心确实与工具包解耦」的最好办法:如果节点模型与 update 循环能在字符网格上跑,它们就真的是后端中立的。

缺口在**输入**,不在输出。今天没有 raw mode 或按键事件运行时实现:`os` 包给的是 fd 级 `read`,`os` 只面向原生,而且没有 termios 绑定。读一行今天可行;方向键、resize 事件、Ctrl-C-as-a-message 想要 raw mode,那是一个到 `termios` 的小 `foreign def`(c/ocaml)或一个终端运行时实现。有界,但必须排期,不能假定。**2026-10-15 已定**——排期为一个标准库包,形状同 `sqlite3`(见下方诉求 7)。它替换的是 `ui_tui` 的输入源,而不是那条接缝:`Script` 与 raw-mode reader 都是 `Input`。

**2026-10-16 已落地(T48.4)**为 `projects/emo-ui/tui/`(包 `emo/ui_tui`)。盒模型以字符格为单位度量核心的 `Style`——列是纵向堆叠、行是横向排列,`padding`/`gap`/`align`/`grow`/`width`/`height` 决定每个子节点的位置——`screen(root, w, h)` 把网格作为数据交回,于是这套算术不必靠字节就能测;`paint(root, w, h)` 把一帧写成 ANSI。因为字符串字面量的转义是最小集合、0x1b 不在其中,转义字节经 `printf("%c", [27])` 发出。`Tui` 在其之上实现 `Backend`,`Input`/`Script` 就是金标所跑的脚本化事件源:字节固定,不碰终端——`run()` 从输入拉取 tag,交给循环的 sink,直到输入说没有了。这个包声明四个能写 stdout 的托管目标;`wasm` 没有 `printf`,不在其中。`c` 能编译后端,却拒绝金标那个循环形状(`Global`)——T48.2 留下的那个决定,如今深了三个 target。金标逼出的两个 `beam` 降级缺陷(`Block` 值的裸 def 被发射成不可调用的远程 fun;循环体里的 `case` 没有把外层 `var` 的重绑穿出)随后端一起修好,记在 `CHECK.md`。`examples/tui_menu/` 是用法示例:一个由脚本化输入驱动的终端菜单,同一个关口在它声明的每个 target 上检查它。

### Web

诚实的答案是:「Web」是三个不同的产品,只有一个是近的。

- **T0 —— 服务端渲染的 HTML/CSS。** 一个纯 Emo 渲染器,把节点树变成 HTML 与样式表,在五个托管目标上逐字节一致。没有 DOM、没有 JavaScript、没有浏览器 runtime——这正是 `plot` 选择 SVG 时的那一步架构动作:渲染归查看器,场景归库。交互是表单、链接与服务端往返(htmx 形状),或之后的一条 SSE/WebSocket 通道。这廉价、可测,立刻给内容与表单类 UI 带来「Web」。它是正确的 T0。
- **T1 —— DOM 后端。** 一个 Emo 程序,由 TypeScript 目标编译,在浏览器里对着 `document`/`Element` 运行。真正的交互在这里,而它没就绪:发射出的 runtime 顶部 import `node:async_hooks`、`node:net`、`node:dgram`、`node:tls`、`node:dns`、`node:fs`(`ts_runtime.ts`),所以在浏览器里加载不了;step 17 的范围明确把「browser embedding(`fetch`/WebSocket bridging)」列为 out;而浏览器不能执行 `.ts`,所以一个输出打包步骤会进入工具链。要走到那里,需要一层 DOM 能力(TS runtime 里一个 `dom_*` 家族,或一个仅浏览器用的 runtime 变体)、一个浏览器安全的入口,以及一个构建步骤。都是实打实的工作,但没有一个是架构上被堵死的。
- **T2 —— wasm + DOM。** `wasm` 目标的模块只 import `println`、`abort`、`float_str`;wasm 上的 DOM 后端意味着新的宿主 import 与一层 JS 胶水。更晚,而且只在 T1 被证明不够时才做。

Web 与原生工具包还有一个共同的语义要点:**平台持有事件循环。** 浏览器页面或 AppKit 应用不能交给 Emo 一个阻塞的 `ui_run()`、然后让 Emo 自己的协作式调度器持有线程。`c` 目标的工具包主循环确实阻塞在 `ui_run` 里,事件经回调重入;浏览器不会。这会影响下面的状态设计。

## 架构

六层,每层只依赖它下面的层。后端之上的一切都是纯 Emo 且与平台无关。

### Layer 0 —— 节点模型

节点是不可变数据:一个 kind、它的带类型 props、一个 `Style`、一个事件身份,以及子节点。树类型就是递归节点:

```emo
// ui.emo — the portable core
interface Node {
  def style() Style
  def children() Array[Node]
}

class Column {
  def init(style Style, children Array[Node]) {
    self.style = style
    self.children = children
  }
  def style() Style { return self.style }
  def children() Array[Node] { return self.children }
}

class Text {
  def init(body String, style Style) { self.body = body; self.style = style }
  def style() Style { return self.style }
  def body() String { return self.body }
}

class Button {
  def init(label String, event Int64, style Style) {
    self.label = label; self.event = event; self.style = style
  }
  def style() Style { return self.style }
}
```

接口是树脊(`Array[Node]` 因此能装任何东西),而且它指称自己,这一点 checker 接受(probe 2,以及上面那条递归接口的发现)。具体类携带带类型的 props,在构造时受检。后端用 `is()` 收窄——`ui.Text`、`ui.Button`,以及平台自己的类。因为一个后端与一个平台库配对,它知道核心类与其平台类的并集;那就是分派表。

另有两种形态被掂量并拒绝作为核心:

- **一个通用节点类,带 `kind` 字符串与不受检的 prop map。** 这是 spike 用的,建得最快,但它正是 Emo 严格性所拒绝的字符串化、不受检表面;样式键校验问题已在 `emo-ui-check.md` 里被标记。
- **每平台一套节点类,没有可移植核心。** 那样就没有任何组件可移植,C4 直接失败。

推荐的形态保留 spike 已经证明的树脊(接口 + 具体类),并用如今已存在的跨模块类型把树脊放进一个库模块。

### Layer 1 —— 组合

树就是嵌套调用。迭代时,组件接一个 block 并对每个元素调用它;block **返回**该元素对应的节点,组件收集返回值:

```emo
def each_from(xs Array[String], i Int64, into Array[Node],
              f Block) Array[Node] {
  if i == xs.length() { return into }
  const head = f(xs[i])
  return each_from(xs, i + 1, into.append(head), f)
}

def each_users(xs Array[String], f Block) Array[Node] {
  return each_from(xs, 0, [], f)
}

const rows = each_users(users) -> (u String) { return card(u) }
```

那个累加器是承重的。**`Array.append` 追加的是一个元素,不是一个数组**(`src/emo_eval/emo_eval.ml:2055`),所以那个顺手的 `[head].append(each_from(xs, i + 1, f))` 构造出 `[n0, [n1, [n2, []]]]` —— 嵌套的 —— 而且仍然能通过 `Array[Node]` 的类型检查,因为元素经由 `Block` 而来,而 `Block` 是 `Unknown`。没有任何东西会报告它,而那个错误的长度看上去又像是合理的。`spike/emo-ui-spelling` 量了这个惯用法、在一个真实屏幕上把它显示出来,并证明手写的 `List` → `Array` 转换有同样的二次形态。

这能用(probe 3),但它暴露了本篇开头那条发现。**Emo 没有隐式子节点收集,而 `Block` 参数是 `Unknown`。** probe 1 把两半都摆出来了:

- 返回数组的 block 交付子节点(`card() { return [text("a"), text("b")] }`——组件收到那个数组)。
- 是一串子节点调用的 block 交付 `void`(`card() { text("a"); text("b") }`——组件什么都收不到;子节点的值是被丢弃的表达式语句)。

所以 README 那份示意树按原样不成立。要让 block 体的树成真,只有四条路,其中三条是错的:

1. **子节点是显式的 `Array[Node]` 参数。** 受检、顺序可见、不需要新东西。这正是 `docs/visualization.md` 为 plot 选的(decision 14,「Array-only declarative tree,no trailing-block spelling」)。这里也推荐这条。
2. **block 把子节点 `return` 出来**(`{ return [a, b] }`)。能用,且与尾随 block 语法相容,但每个叶子都要加一个 `return`,而且单个子节点与多个子节点的写法不同。
3. **一个让 block 往里追加的 builder**(`card(user) { children.push(a) }`)。能用,但把可变状态与一个环境收集器塞进树里——隐式状态,违背设计哲学。这条仍然被否掉:反对针对的是 block 在被没被告知的情况下就能取到的那个收集器,而语言自己的 `ArrayBuilder` 并不提供这样的东西——builder 是传进来的值、在调用点被写名字,所以这条选项只有写成「选项 1、但把数组换成 builder」才算可以接受。
4. **给 block 加一条「最后一个表达式即值」的隐式规则。** 这是模板语言机制,与显式 `return` 规则相悖(`docs/intro/syntax.md`)。拒绝。

因此设计说:**子节点列表是显式的 `Array[Node]`;尾随 block 用于回调与迭代,block 产生值时它 `return` 出来。** README 的 EmoUI 示例应改成这种写法,或者把 block 形式定义为必须 `return`。这是需求中「声明式语法」唯一一处实际上是 API 约定而非语法的地方,而这个约定必须写清。

相关的语言缺口:`Block` 是 `Unknown`,意味着 block 参数不受检。一个**带检查的函数类型**能让组件声明它要求的回调形状(`def each(xs Array[T], f (T) Node)`),并让树 block 对着它受检。今天 Emo 只有 `Block` 这一种写法,而 `Block` 被刻意定为 `Unknown`。新增一个带检查的 block/函数类型是一项实打实的语言改动(语法、合一、每个后端的闭包表示);它值得掂量,因为它是受检与不受检组件 API 之别,但它不是第一个包的关口。

本节背后的完整论证——被丢弃的 block 值能被指定去向的三种方式、先例调研、模板语言能有的三种形态,以及它留下的唯一开放问题(Emo 自己语法里的树字面量,还是外部翻译器产出 `.emo`)——见 [`emo-ui-composition.md`](emo-ui-composition.md)。

### Layer 2 —— 组件库

需求明确要每平台组件库。设计给它一条精确边界:

- **`ui` —— 可移植核心。** 节点树脊、可移植原语(column、row、text、button、text input、image、spacer、scroll)、样式词汇表、app 循环,以及后端接口。纯 Emo,所有托管目标。
- **`ui-<platform>` —— 每平台一个包。** 一个后端加上该平台的组件库。各自声明 `targets`,有原生代码时携带原生代码。
- **收敛命名。** 等价组件在各平台库之间共享名字(`text`、`button`、`row`、`column`、……),于是两个平台应用读起来一样,而且对着核心写的组件在所有平台上都能编译。一个平台库可以加别的库没有的名字——那就是 C3。

可移植规则(C4)自然落出:只用核心原语搭的组件可移植;用 `ui-macos.table` 搭的不可移植。框架应让这条边界可见,而不是抹平它——调用点上的平台包名就是信号。

### Layer 3 —— 布局

spike 在 Emo 里算布局,所以两个工具包摆出完全相同的像素。对双后端 demo,那是对的;对真框架,那是错的,因为在 Emo 里算布局丢掉了平台布局引擎给你的一切:浏览器的 reflow、Dynamic Type 与无障碍、GTK 的尺寸协商,以及——在每个平台上——文本测量,而 Emo 没有字体引擎就做不到(`docs/visualization.md`,gap 5)。

因此设计是一套**映射到各平台原生布局的可移植布局词汇表**,而不是一个可移植布局引擎:

- 容器:`row`、`column`。
- 布局属性:`padding`、`gap`、`align`(start/center/end/stretch)、`grow`、可选的固定 `width`/`height`。
- 一切都是节点 `Style` 上的一个值。

映射是直接的:Web 上是 CSS flexbox,GTK 上是 `GtkBox`/`GtkGrid`,AppKit 上是 `NSStackView`/Auto Layout,TUI 网格上是一个 Emo 盒模型(格是单位)。集合刻意小:四个平台都能兑现的交集,于是可移植组件处处看起来都对。平台库可以加自己的布局 props(CSS `grid`、GTK size group)作为平台样式,不是核心样式。

TUI 是证明规则的例外:它没有原生布局引擎,所以核心为终端(以及任何想要显式定位的东西,比如未来的 canvas)带一个小 Emo 盒模型。那个引擎就是 spike 的引擎,留给需要它的后端——不强迫不需要它的后端。

### Layer 4 —— 样式

样式是一个带类型值,配一个工厂与 `with_*` 复制方法,恰是 `docs/visualization.md` 为 plot 定下的形态(decision 2 与 20),因为 Emo 没有默认参数(已验证:`def hello(name String, count Int64)` 的 `hello("a")` 是 E4009;probe 4)。核心 `Style` 携带可移植布局词汇表;平台特有的样式是一个平台类:

```emo
class Style {
  def init(padding Float64, gap Float64, align Align, grow Bool,
           width (R, Float64), height (R, Float64)) { ... }
  def with_padding(p Float64) Style { ... }
  def with_gap(g Float64) Style { ... }
  def with_align(a Align) Style { ... }
  // …
}

def style() Style { return Style.new(padding: 0.0, gap: 0.0, align: Align.start, ...) }

text("Hello", style().with_padding(12.0))
```

`(R, Float64)` 携带「未设置或一个值」——README 自己的可选标量惯用法(元组里的 `R` 枚举)——于是「auto」是显式的,不是魔法哨兵。spike 的 `Map[String, Float64]` 层叠被去掉了:它字符串化,而且静默接受任何键。若之后想要层叠主题,那是一个向下传的 `Theme` 值,不是隐式合并。

### Layer 5 —— 状态与 app 循环

README 承诺 Elm(一个 UI 进程、一个 model、`update`、`view`)加显式响应式原语。设计照字面来:

```emo
enum Msg { increment, decrement }

class Model {
  def init(count Int64) { self.count = count }
}

def update(msg Msg, model Model) Model {
  case msg {
    Msg.increment -> { return Model.new(count: model.count + 1) }
    Msg.decrement -> { return Model.new(count: model.count - 1) }
  }
}

def view(reg ui.Registry, model Model) Node {
  return column(
    text("clicked ${model.count} time(s)"),
    button("+", reg.on(Msg.increment)),
    button("-", reg.on(Msg.decrement))
  )
}
```

事件身份是 FFI 接缝。节点只携带一个 `Int64` tag,永不携带闭包(闭包不能跨 FFI,E4200)。建树时把带类型的消息登记进一张 Emo 侧的表,并往节点上盖它的索引,于是 `update` 保持带类型(`Msg`),而后端只看到整数:

```emo
reg.on(msg Msg) Int64       // registers msg, returns its tag
reg.dispatch(tag Int64) Msg // the driver's lookup
```

这张表是循环自己持有、并交给 `view` 的对象,而不是模块级绑定:模块级 `const` 在编译目标上每次读取都会重跑初始化式,模块级 `var` 只有 `ocaml` 支持,表放在那里等于每次读取都拿到一张新的空表(`CHECK.md`,模块级绑定)。放在循环里持有也更贴合它本身——这张表属于某一个正在跑的循环,所以同一进程里两个循环各持一张。**已随 T48.2 落地为 `ui.Registry`。** tag 一律在建树之前用独立语句取好,绝不写在构成树的那个实参表里:`on` 是副作用,而操作数的求值顺序由 target 决定——`ocaml` 与其它每个 target 相反——所以从实参位置发出的 tag 会因 target 而异(`CHECK.md`,操作数求值顺序)。

这保住了 README 关于事件是消息的承诺,保住了带类型的 update,也尊重了回调分层。不属于 model 的局部可变状态用语言自己的原语——一格用 `Box`,集合用 `List`/`Map`——在 `view` 时读取;README 的「响应式原语住在标准库」由这些满足,而「编译器优化成定向刷新」的承诺是之后针对这些读取的一趟处理,不是一张隐式图。

约束这一层的那几条事实是诚实的告诫,不是设计选择:

- **两个事件循环。** 在 AppKit/GTK 上,`ui_run()` 阻塞在工具包循环里,事件经回调契约重入。Emo 自己的协作式调度器(进程、邮箱)不持有那个线程。一个带邮箱的 UI 进程与一个工具包循环需要一个集成方案(工具包循环驱动调度器,或事件作为消息投递进一个进程)。spike 用的同步 Elm 循环绕开了它,也是正确的 v1:进程与监督在循环被证明之后再来。
- **后端一致性。** `c` 目标的 `raise` 曾经结束的是程序而不是出错的那个进程,`send` 曾经是共享而不是快照——两者已于 2026-10-15 关闭(`CHECK.md`,step 50)。GUI 是让两者都显形的消费者;一个在握着工具包时 raise 的 UI 不能悄悄把窗口一起带走,现在它也不会了。`typescript` 目标的 send 共享是 Web 路径上同一个缺口。
- **循环在各个托管 target 上的形状。** 循环已经落地(`projects/emo-ui/`,T48.2),在解释器上跑得起来;但上面这个形状——应用的 `update` 与 `view` 以 `Block` 值传进来——只在「裸 def 可以当值」的地方能编译:`ocaml`、`typescript`、`beam` 可以;`c` 拒绝(`Global`),`wasm` 拒绝 `update` 需要的双参动态调用(只支持单参闭包)。把这两个函数放到 `Handler` 接口后面——普通的接口分发,没有任何 `Block` 值函数,应用照旧用 `is()` 收窄自己的 model,正如后端收窄节点——就是同一个循环,五个 target 全部可编译,打印结果与解释器一致(`projects/emo-ui/probe/`、`CHECK.md`,Elm 循环的形状)。往哪边收口——把这两个 target 补起来,还是把应用的函数移到接口后面并改写本层的拼写——仍然开放。
- **长跑内存。** `c` 目标不回收一次渲染分配的值语义家族,而 UI 每个事件重渲染一次,所以这是约束平台而非约束设计的那条告诫:`spike/arena-scope` 实测 400 节点时每次渲染约 1 MB、约 820 个对象,两者都无界。region 修不了它——它回收字节、回收不了对象,还会搁死那些引用计数。原生后端的 demo 尺度注记已退役——step 49 于 2026-10-17 落地,一次渲染会把它构建的一切全部释放,工作集保持平坦(`CHECK.md`)。

### Layer 6 —— 后端接缝

后端是一个 Emo 级契约,不是 C ABI。九动词 `ui_*` 契约是 spike 的 macOS+GTK 实现;通用接缝还必须容纳一个纯 Emo 终端写入器与一个浏览器 DOM:

```emo
interface Backend {
  def mount(root Node, events Events) Void
  def patch(old Node, new Node) Void
  def run() Void
}
```

`mount` 把第一棵树和后端投递事件用的 sink 一起交给后端——一个单方法 `Events` 接口,`deliver(tag)`,这就是后端关于应用所知道的全部。单方法接口正是 C→Emo 回调契约早已命名的回调类型(`CHECK.md`),所以原生 shim 经同一条跳板抵达 sink,与抵达任何其它回调一样。已随 T48.2 落地为 `ui.Backend`/`ui.Events`。

每个平台实现它:

- **macOS / GTK:** 一个 Emo 类,其方法调用 `foreign def` shim。shim 实现各原语(`window_make`、`label_make`、`place`、`connect`、……);Emo 侧遍历树并把节点映射到原生 handle。
- **TUI(已落地,T48.4):** 一个纯 Emo 类,把树排到字符网格上并写 ANSI;`run()` 从脚本化输入拉取 tag 并交给循环的 sink。`projects/emo-ui/tui/` 是这个包,`tui/golden/` 是那段脚本化输入的金标:`screen` 把网格作为数据交回,`paint` 写出字节,同一块界面在解释器、`ocaml`、`typescript` 与 `beam` 上逐字节相同。
- **Debug(已落地,T48.3):** 无头的那一个,也是这条接缝的参考实现。它把循环交给它的每一棵树渲染进一份日志而不是打印——于是何时让文本到达 stdout 由调用方决定,金标不会被一个恰好挂上去的后端搅动——而 `run()` 什么也不驱动,因为无头就意味着没有输入源:事件由外部经 `deliver` 手工步进,投递到 `mount` 拿到的那个 sink 上。`projects/emo-ui/golden/` 就是它为的东西:一块界面经核心、以消费者抵达核心的方式走一遍,再以文本出来,在解释器、`ocaml`、`c`、`typescript`、`beam` 上逐字节相同(`wasm` 根本降不下核心——即上面循环的形状)。这个形态之所以这么窄是被 target 逼的、不是选的:它只插值 `String`、`Int64`、`Bool` 与 `Float64`,因为枚举或元组在两个 target 上打印出的字节并不相同(`CHECK.md`,枚举的显示形式);它的金标也先在建树之前用独立语句取好 tag,因为操作数求值顺序由 target 决定(`CHECK.md`)。
- **SSR:** 一个纯 Emo 类,把树序列化成 HTML/CSS;`run()` 就是渲染一次。
- **DOM(之后):** 一个 Emo 类,压在运行时的 `dom_*` 调用上;`run()` 把控制权交给浏览器后返回。

`patch` 是成长边缘。spike 每个事件做全量重建(`clear` 加重新 `place`),对终端与静态 HTML 渲染没问题,对保留式工具包是错的(丢焦点、选区、滚动位置),对 DOM 也浪费。v1 可以对 TUI/SSR 先上全量重建、对原生/DOM 用保留式;带 key 的协调是后续项,而编译器的「静态可判定的定向刷新」是它的长期形态。

## 评估这个需求

**C1 —— 同一套组合语法:成立,而且零成本。** 树是带显式括号的嵌套调用、props 用命名参数、回调与迭代用尾随 block。这些都是现成 Emo(`docs/intro/syntax.md`);README 的「带显式括号的调用、单一形态的 block、命名参数」就是全部语法。这里没有哪条构造是被挣得的,也不该新增。

**C2 —— 同一个树值类型:成立,且如今不再被堵。** 跨模块类型加上可用的递归节点给出一个 `ui.Node`,每个组件返回它、每个后端消费它。这正是 2026-10-10 与 2026-10-14 两个决定想要解锁的东西;probe 确认自指类如今能通过检查。

**C3 —— 每平台组件库:按设计成立。** 核心是可移植集合;每个平台包加原生控件。没有任何东西强迫集合一致,这正是需求所要的。

**C4 —— 按构成可移植:成立,边界可见。** 用核心原语搭的组件可移植;用平台扩展搭的不可移植,而调用点上的平台名说明了这点。这是「同一套语法」的诚实解读:语法相同,可用的名词不同,假装不是就是在做设计所拒绝的隐式魔法。

**C5 —— 平台差异限于后端:只有把布局与事件也算后端时才成立。** spike 把*绘制*限制在后端,同时把布局算在共享层。这里的设计把布局移进后端(经可移植词汇表),把事件移进 tag 契约,于是共享层是真正平台无关的。这是对 spike 的改动,理由正是 spike 的共享布局无法扩展到 Web,也无法尊重原生度量。

**需求低估了什么。** 「同一套语法、不同的组件库」是必要但不充分的。两个共享语法的程序仍可能在*行为*上完全分叉:Web 表单是 POST,macOS 按钮是回调,TUI 读一个键。设计的活儿是四个后端实现的**语义契约**——可移植布局词汇表、组件命名收敛、事件 tag 协议、update 循环。语法是最不成问题的那部分。

**它会在哪里失败。** 失败模式不是「语法不工作」,而是一个平台包悄悄用不同语义实现某个核心组件(Web 上会换行的 `row`,AppKit 上不会),或者一个组件库长出一个平台特有动词、用户又在上面搭东西,把可移植集合撕碎。防线是收敛命名规则、一个一致性语料(同一个 app 跑在每个后端上),以及让平台扩展在命名空间上可见。

## 一个落地形状

这套架构的实际结果是「一个共享应用模块 + 一个薄薄的每平台入口模块」,正是 spike 那套拆分的一般化:

```emo
// app.emo — portable: components, update, view. No platform name.
def view(reg ui.Registry, model Model) ui.Node { ... }

// main_macos.emo
require "ui_macos"
ui.run(app.view, app.update, Model.new(0), ui_macos.backend())

// main_web.emo
require "ui_web"
ui.run(app.view, app.update, Model.new(0), ui_web.backend())

// main_tui.emo
require "ui_tui"
ui.run(app.view, app.update, Model.new(0), ui_tui.backend())
```

裸 def 是值——本地与模块限定都是(probe 5)——所以 `app.view` 与
`app.update` 可以直接传进去。它们落在 `Block` 参数里,而那是
`Unknown`,所以入口的接线和 Layer 1 一样是那条不受检的回调边界。
`view` 先收循环的 `Registry`,因为那张表是循环的(Layer 5)。这就是
`ui.run` 落地时的形状(T48.2)——也是有两个 target 还编译不了的形状,
即 Layer 5 记下的那个开放项。

`app.emo` 对所有三个都是同一个文件;只有入口模块不同,而它只有几行。一个想要 `ui_macos.table` 的平台特有应用把它写在入口里或一个 macOS 专属组件模块里;可移植组件从不提到它。这就是对需求的直接回答:**组合方式相同,组件库按平台,差异被隔离到一个小入口模块与一个包依赖里。**

## 打包:标准库还是第三方

两者都摆上了台面。建议是**第三方、独立仓库**(`github.com/emo-lang/emo-ui`,README 里已有的链接),可移植核心作为一个普通的 Emo 包。

**2026-10-15 修订:** 「独立仓库」变成了「独立项目目录」——本仓库里的 `projects/emo-ui/`,以它将来仍可拆分出去的仓库命名(`CHECK.md`)。「标准库还是第三方」这一问的另一半不受影响:可移植核心仍然是普通包,不是 stdlib 包。搬进 in-tree 确实付出了独立仓库本可买到的解耦——UI 发布现在与编译器同仓库、同 CI——暂时接受这个代价,换取不必同步维护第二个仓库。

第三方的理由:

- **标准库以生成数据的形式嵌在编译器里**(step 24,`CHECK.md`);一个带每平台原生 shim 的 UI 框架会撑大那个二进制,并把 UI 发布与编译器发布绑在一起。
- **原生后端需要标准库惯例不使用的 manifest 能力**(frameworks、`pkg-config`),而第三方包可以长出这些,不必改编译器的内置 registry。
- **标准库是可移植、逐字节一致的那一档。** `plot` 够格进那里是因为它在五个目标上都是纯 Emo。EmoUI 的后端包是目标特定且原生的;只有核心是标准库形状的。
- README 已经把 EmoUI 定位成一个独立项目,这本身就是一条已定的陈述。

反方论点——标准库里的 `ui` 核心会被每个用户发现、并获得语言已经付过代价的 UI 驱动编译器工作——是真实的,解决办法是**之后可能的分拆**:一旦稳定,可移植核心(`ui`)与纯 Emo 后端(TUI、SSR)可以搬进标准库,把原生/DOM 后端留给第三方。那是 v1 之后要重访的决定,不是现在。

## 语言与编译器诉求

明确列出,好让它们被有意决定,而不是在实现中途被发现:

1. **带检查的 block/函数类型(可选)。** `Block` 是 `Unknown`,所以组件 API 的回调与树 block 不受检。带类型的 block 能让 `each(xs, f: (T) Node)` 受检。便利项,不是关口;数组子节点形式不用它也能让树受检。
2. **没有隐式子节点收集——这是设计。** 不要新增一种收集 block 表达式语句的构造。那是模板语言,而数组参数已经把树表达清楚了。
3. **包原生输入的扩展(原生后端的真正关口)。** `.c`/`.h` 加裸 `-l` 表达不了 AppKit(`.m`、frameworks)或 GTK(`pkg-config`)。新增 per-package 编译 flag / `pkg_config` 机制——**已定(2026-10-14)走这条路,不走「写明使用应用级构建脚本」那条**(`CHECK.md`);字段面是 T48.7 自己的范围。
4. **`c` 目标的内存回收——已定(2026-10-14)走值语义家族的引用计数;2026-10-17 落地(step 49)。** region 那条路已被实测并排除(`spike/arena-scope`、`CHECK.md`);原生后端交付时附带的 demo 尺度注记已退役——渲染形状的循环持有平坦的工作集,由 T49.4 闸门钉住。
5. **`c` 目标的 `raise` 与 `send`——已定(2026-10-15),兑现已经做出的承诺**(`CHECK.md`,step 50)。UI 不能因为一个坏事件整体死掉,跨进程的事件载荷也不能被静默共享——这两条正是 `docs/intro/concurrency.md` 与 `docs/intro/syntax.md` 早已写下的。`c` 目标是唯一跑偏的实现;现在子进程的 `raise` 只结束它自己,`send` 送快照。`typescript` 目标的 send 共享是下面 Web 路径上的同一个缺口。
6. **Web 的浏览器路径(T1)——已定(2026-10-15)走拆分路线:** 把 TypeScript runtime 拆出一个浏览器安全子集、加一个 `dom_*` 家族与一个打包步骤,而不是新增 wasm 宿主 import(`CHECK.md`)。打包步骤落在工具链的哪里属于 T48.10 自己的范围。SSR(T0)不需要。
7. **终端输入。** TUI 的 raw mode 与按键事件(一个小的 termios 绑定或一个终端运行时实现)。**2026-10-15 已定:做成一个标准库包,按 `sqlite3` 的方式发布**(`CHECK.md`)——包自带 `.c`/`.h` 源码,经 `foreign def` 调用,由 manifest 的 `targets` 把关,随其余 stdlib 一起内嵌。raw mode 是任何 TUI 程序都需要的能力,该跟 `os`、`file` 放在一起,而不是塞进恰好第一个用到它的那个 UI 框架里。
8. **不加新语法。** 树已经可表达;如果不可,缺口是一个类型或一个库函数,不是一条构造。

## 风险

- **后端间的语义漂移。** 语法收敛并不让一个 `row` 处处同义。缓解:一套小的声明式布局词汇表、收敛命名规则,以及一个一致性语料(一个 app、每个后端)——**已落地为 `debug` 后端与 `projects/emo-ui/golden/`(T48.3)**,它们把一块界面钉成在所有跑得动的 target 上逐字节相同,并且在第二个后端出现之前就找出了第一批分歧:操作数求值顺序与枚举的显示形式,今天在这两个 target 上并非同样的字节(`CHECK.md`)。**终端后端与它的脚本化金标(T48.4)**把这条线延长——一块界面经过一个真正的盒模型,在五个托管目标中的四个上逐字节相同——并逼出、修掉了它记下(`CHECK.md`)的两个 `beam` 降级缺陷。
- **文本。** 可移植的自动布局需要文本度量;设计通过把布局委托给平台(而 TUI 数格子)来避免需要它们。未来的 canvas 或像素一致模式会重新引入 `docs/visualization.md` 拒绝过的字体度量问题。
- **原生打包。** 在 manifest 长出 flags 之前,macOS/GTK 应用要扛构建脚本;这是需求「下载即用」上的摩擦。manifest 字段这条路已定(T48.7),所以风险在排期,不在方向。
- **两个事件循环**(Emo 调度器 vs. 工具包/浏览器),如上。
- **范围。** UI 框架是无界的。分档表是防线:可移植核心 + TUI + SSR 先行,原生工具包其次,DOM 最后;不承诺布局一致、不做动画、v1 的无障碍不超出原生控件自带的部分。
- **没有泛型、没有默认参数。** 节点数组是 `Array[Node]`(没问题——接口就是元素类型),但样式工厂带 `N` 个复制方法,恰如 `plot` 接受的那样。有界样板。
- **`c` 目标的长跑内存。** 已退役:step 49 于 2026-10-17 落地,每个事件分配的树全额回收——`spike/arena-scope` 量测过它过去泄漏多少。`Array` 的二次构建是同一条发现的另一面;`ArrayBuilder` 回答了它(T49.3),可移植核心把它接了下来——子节点列表用 `push` 攒,而不是每个子节点重建一次(T48.1)。

## 先例,以及该借什么

机制可以借;任何单一语言的外形不可照搬。

- **Elm** —— model/update/view 架构,副作用即消息。借它的循环;不要超出 Emo 自己的枚举与元组惯用法去发明一套 `Msg` 重的词汇。
- **React / Solid** —— 组件即函数、树即值,以及协调。协调作为后端关切借入;Solid 的细粒度 signal 接近 README 的显式响应式,但它的隐式追踪图正是 README 拒绝的「隐式依赖图」。
- **SwiftUI / Compose** —— 声明式树与 modifier 概念。借树;拒绝 modifier 链(spike 刻意用了无序样式值,`docs/visualization.md` 用 `with_*` 复制——同一个理由)。
- **GTK / AppKit** —— EmoUI 映射上去的原生控件与布局引擎。它们是平台,不是要照抄的模型。
- **Textual / Ratatui** —— 终端后端:字符网格、控件树、按键事件。借网格,不借控件词汇。
- **htmx / 服务端渲染 HTML** —— T0 的 Web:服务端持有状态,页面是一次渲染。借这个模型;Emo 自己的渲染器在 `plot` 的 SVG 形状里已经存在。
- **Iced / egui / Druid** —— Rust 谱系里的保留式 vs. 立即式之分。值得读作协调决策的参考;不是风格来源(而 Rust 尤其是本设计的负面参照)。

## 建议

可辩护的方向,写成产品:

**一个第三方 EmoUI 项目——一个可移植的 `ui` 核心(节点模型、可移植布局词汇表、带类型样式、Elm 循环、事件 tag、后端接口)加每平台一个包。顺序:(1) 核心与 TUI 后端(纯 Emo,无工具链,它证明后端中立);(2) SSR HTML/CSS 后端(纯 Emo,逐字节一致的 golden);(3) macOS 与 GTK 4 后端,压在已被证明的 `foreign def` shim 上,先把打包问题解决,并把 `c` 目标的内存问题回答掉——值语义家族的回收已作为独立里程碑(step 49)落地;(4) TypeScript 目标上的浏览器 DOM 后端,它需要浏览器安全 runtime、一层 `dom_*` 能力与一个打包步骤。子节点是显式的 `Array[Node]`;尾随 block 用于 `each`/回调,并返回其值。不加新语法。**

需求是可达的,但它该按语义契约来评判,而不是语法——语法已经能用,而四个后端是四种不同的程序。

## 已记录决定(2026-10-14)

1. **EmoUI 是独立项目**,不是标准库包;可移植核心与纯 Emo 后端搬进标准库是一个可能的后续分拆,不是 v1。**2026-10-15 修订:** 它托管在本仓库的 `projects/emo-ui/` 下,而不是一开始就另建一个独立仓库(`CHECK.md`,in-tree 项目布局)。「不是标准库包」这一半不变——stdlib 内嵌只走 `stdlib/registry`,所以 in-tree 的 `projects/emo-ui` 不会进入编译器二进制。
2. **树类型是多模块的 `ui.Node`**(接口树脊 + 带类型 props 的具体类),不是一个字符串化的单类,也不是每平台一套节点类、没有核心。
3. **子节点是显式的 `Array[Node]`。** 尾随 block 用于回调与迭代,且必须 `return` 其值;没有隐式子节点收集,README 的示意树改成这种写法。
4. **布局是一套映射到平台原生布局的可移植词汇表**,不是一个共享 Emo 布局引擎。TUI 保留一个小 Emo 盒模型,因为它没有原生引擎。
5. **样式是带类型值,配工厂与 `with_*` 复制**,不用字符串 map,不用默认参数。
6. **状态是 Elm**(model、`update`、`view`),压在显式语言原语(`Box`/`List`/`Map`)上;事件是登记在 Emo 侧的带类型消息,以后端可见的 `Int64` tag 暴露。
7. **后端是一个 Emo 接口**(`mount`/`patch`/`run`);九动词 `ui_*` 契约是原生实现细节。
8. **平台库对等价组件共享收敛命名**;平台特有组件在调用点带上平台包名。
9. **顺序:TUI 与 SSR 先行,原生工具包其次,DOM 最后。**
10. **不加新语法。** 唯一值得掂量的语言诉求是带检查的 block/函数类型;它不是关口。
11. **probe 的发现是证据**(`spike/emo-ui-probe`):`Block` 参数是 `Unknown`;Void block 产出 `void`;递归节点类与自指接口如今能通过检查;返回值的迭代 block 能用;裸 def(本地或模块限定)是值,能满足 `Block`;默认参数被拒(E4009)。
12. **`c` 目标的长跑内存不是 region 问题。** 由 arena-scope spike 于 2026-10-14 落定:region 回收 100% 的 arena 字节与 0% 的身份泄漏,并把那些引用计数永久搁死;解法是值语义家族的引用计数。因此 T48.8/T48.9 曾以 demo 尺度推进并把限制写进文档,而回收是独立的里程碑——**不是**原生后端的先决条件(`CHECK.md`、`spike/arena-scope/`)。**已于 2026-10-17 落地**(T49.1–T49.4):每个动态 cell 都可回收,渲染循环持有平坦的工作集,demo 尺度注记退役;T49.4 闸门钉住它。

决定 1–11 在 [`TASKS.md`](TASKS.md) 里作为 **M15 — EmoUI(step 48)** 追踪,完整的
步骤规格在 [`plan/step-48-emo-ui.md`](../../plan/step-48-emo-ui.md);决定 12 作为
**M16 — 值语义家族的回收(step 49)** 追踪,规格在
[`plan/step-49-value-reclamation.md`](../../plan/step-49-value-reclamation.md)。

## 仍开放的问题

1. **原生打包机制** —— 方向已定(2026-10-14)走 per-package 的 manifest 字段,取代应用级构建脚本那条路;字段面(`pkg_config`、编译/链接 flags、`.m` 是否收集)是 T48.7 自己的范围。这卡住顺序里的第 3 项。
2. **协调** —— 保留式后端何时从全量重建换成带 key 的 diff,以及编译器的定向刷新是否与它同时落地。
3. **两个事件循环的集成** —— UI 进程与工具包循环如何共存,以及事件在 v1 还是更晚变成真正的进程消息。
4. **带检查的 block/函数类型** —— 在第一个包显出摩擦之后,组件 API 是否值得它。循环现在露出了这份摩擦的另一面:它那两个 `Block` 值的 `view`/`update` 正是 `c` 与 `wasm` 编译不了的东西(`CHECK.md`,Elm 循环的形状),所以「不加带检查的函数类型」的那条替代路——把应用的两个函数放到接口后面——同时也是「不补这两个 target」的那条替代路。
5. **Web T1 的边界** —— 路线已定(2026-10-15):把 TypeScript runtime 拆出一个浏览器安全子集加一个 `dom_*` 家族,不做浏览器专属的 runtime 变体(`CHECK.md`)。仍然开放的是机械问题:打包步骤落在工具链的哪里,属于 T48.10 自己的范围。`typescript` 目标的 send 共享(`CHECK.md`,跨 target 不变量)也在这条路径上。
6. **树的拼法** —— 数组式 children 到底要不要一个字面量写法;如果要,它属于 Emo 自己的语法,还是属于一个产出 `.emo` 的外部翻译器。已经**关掉**的机制(发射、self 重绑定、环境式收集器、自带走作用域求值的模板引擎)记在 [`emo-ui-composition.md`](emo-ui-composition.md),那里也写明了能了结这个问题的证据是什么。
