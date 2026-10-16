# EmoUI

用 Emo 写的组件式 UI 框架:一棵声明式树渲染到终端、服务端页面、macOS/AppKit 窗口与 GTK 4 窗口——浏览器 DOM 随后按自己的运行时路径接入。Emo 的语法就是为它塑形的,原则是**没有模板语言——UI 就是普通的 Emo 代码**,与配置同一哲学。

组件树是嵌套调用,子节点是一份显式的 `Array[ui.Node]`:

```emo
def card(user User) ui.Node {
  return ui.row([
    ui.image(user.avatar(), ui.style().with_width(32.0)),
    ui.text(user.name(), ui.style())
  ], ui.style().with_gap(8.0))
}

def inbox(users Array[User]) ui.Node {
  const rows = ArrayBuilder.new()
  for var i = 0; i < users.length(); i = i + 1 {
    rows.push(card(users[i]))
  }
  return ui.column([
    ui.text("Inbox", ui.style()),
    ui.column(rows.to_array(), ui.style().with_padding(12.0))
  ], ui.style())
}
```

子节点是一个实参,永远不是一个块:尾随块是给回调和迭代用的,它产出值时自己 `return`。要到遍历时才知道的子节点列表,用语言自带的 `ArrayBuilder` 攒起来、以 `to_array()` 交出去——这正是那两屏度量定下的容器问题(`docs/emo-ui.md` 决策 3;`spike/emo-ui-spelling`)。数组写法将来是否会再长出一种字面量拼法,仍然开放(`docs/emo-ui-composition.md`)。

## 状态

可移植的 **`ui` 核心**(T48.1)、**Elm 循环**(T48.2)、无头 **`debug` 后端及其金标**(T48.3)与终端 **`ui_tui` 后端及其脚本化输入金标**(T48.4)都已落地。`ui.emo` 是节点脊柱——一个 `Node` 接口,加上 `Column`、`Row`、`Text`、`Button`、`TextInput`、`Image`、`Spacer`、`Scroll` 这些带类型化属性、由位置参数小写构造函数建起的类——以及带 `style()` 工厂与 `with_*` 拷贝的类型化 `Style`、布局词汇(`Align`,以及 style 上的 padding、gap、grow、width、height)、`Backend` 接口(`mount`/`patch`/`run`),还有循环本身:`App`,以及事件登记 tag 用的 `Registry`。它是纯 Emo:没有平台、没有 FFI,并声明了全部五个宿主目标。

一个应用就是 model、纯 `update`、纯 `view` 加一个后端:

```emo
def update(msg Msg, m Model) Model { ... }

def view(reg ui.Registry, m Model) ui.Node {
  return ui.button("+", reg.on(Msg.inc), ui.style())
}

def main() {
  ui.run(view, update, Model.new(0), backend)
}
```

tag 登记表是循环自己持有的对象,而不是 `docs/emo-ui.md` Layer 5 草拟的模块级 `ui.on(msg)` 表:模块级 `const` 在编译目标上每次读取都会重跑初始化式,模块级 `var` 又只有 `ocaml` 支持,表放在那里等于每次读取都拿到一张新的空表(`CHECK.md`,模块级绑定)。这张表属于某一个正在跑的循环,由循环把它交给 `view`。tag 一律在建树之前用独立语句取好,而不是写在构成树的那些实参里:`on` 是副作用,而操作数按 target 的顺序求值——`ocaml` 与其它每个 target 相反——所以从实参位置取的 tag 会因 target 而异(`CHECK.md`,操作数求值顺序)。

循环在 `ocaml`、`typescript`、`beam` 上可编译并运行;在 `c` 与 `wasm` 上还不行,而挡路的是它的拼写而不是它的结构:裸 def 名是唯一能产出 `ui.run` 所收 `Block` 值的表达式,而 `c` 没有 def 当值(`Global`),`wasm` 又拒绝参数多于一个的动态调用。`probe/` 把这个缺口做成一对最小对照——`def_shape/` 是已落地的写法,两个拒绝都能撞到;`handler_shape/` 把应用那两个函数放到 `Handler` 接口后面,是同一个循环,五个 target 全部可编译,在 `c` 与 `ocaml` 上打印出的结果与 `emo run` 一致(`CHECK.md`,Elm 循环的形状)。在 `beam` 上,循环以前只是能构建、不能运行:裸 def 会变成指向未导出函数的远程 fun,`erlc` 接受但加载器让它无法调用;那个缺陷已修好,TUI 金标就是证据。往哪边收口——把这两个 target 补起来,还是把应用的函数移到接口后面——是 T48.4 留下来、仍未收口的那个开放决定。

`debug.emo` 是无头后端(T48.3):`render(node)` 把一棵树变成稳定文本——一个节点一行、每层两个空格,先节点自己的属性,再一份字段顺序固定的样式摘要——而 `Debug` 类就在这份文本之上实现 `Backend`,把循环交给它的每一棵树记进日志而不是打印出来,于是何时让文本到达 stdout 由调用方决定。它的 `run()` 什么也不驱动,因为无头就意味着没有输入源:事件由外部经 `deliver` 手工步进,投递到 `mount` 拿到的那个 sink 上。

`golden/` 就是这份文本形式要服务的东西:核心与之后每个后端都要拿它来量的那套标尺。它是一个处在消费者位置上的包——`deps { "emo/ui" = "0.1.0" }` 加一条 `require`,经关口从被测源码现场搭出的 registry 抵达核心——里面装着唯一一块界面,涵盖每个原语、`w=`/`h=` 的两个分支、全部四个 `Align` 取值、一个空字符串属性以及嵌套容器。`expected.txt` 是解释器自己的输出;`./check.sh` 在每个 target 上构建并运行这块界面,要求逐字节相同——所以一个把树渲染得不一样的后端会在这里失败,而不是在截图里。

这份文本形式比看上去要窄,原因在 target:它只插值 `String`、`Int64`、`Bool` 与 `Float64`,因为插值枚举或元组在每个 target 上产出的字节并不相同——`typescript` 会带上限定名,`beam` 干脆没有这个类别的转换——所以那份样式摘要改用解构(`align_name`、`extent`)并自己拼出要打印的名字。金标也先在建树之前用独立语句取好事件 tag,绝不写在构成树的实参表里,因为操作数按 target 的顺序求值,而 `ocaml` 与其它每个 target 相反,那样会让同一条消息在不同 target 上拿到不同的 tag。两者都连同各自的最小对照记在 `CHECK.md` 里(`probe/eval_order`、`probe/enum_print`)。

`./check.sh` 是它的关口:包能通过类型检查、循环的十七条断言会跑,每个 target 的构建结果——以及每一次拒绝——都在里面钉死,金标的字节也在四个跑得动的 target 上逐一比对。

`tui/` 是终端后端(T48.4),是一个自己的包——`emo/ui_tui`,对 `emo/ui` 取版本——因为它带一个核心没有的平台。终端没有原生布局引擎,所以盒模型就在这里:以字符格为单位度量核心的 `Style`,列纵向堆叠、行横向排列,`padding`/`gap`/`align`/`grow`/`width`/`height` 决定每个子节点的位置。`screen(root, w, h)` 把网格作为 `Array[String]` 交回,于是这套算术不必靠字节就能测;`paint(root, w, h)` 把一帧写成 ANSI(清屏、归位、每行一行),转义字节经 `printf("%c", [27])` 到达 stdout,因为字符串字面量的转义是最小集合、0x1b 不在其中。`Tui` 在其之上实现 `ui.Backend`,`Input`/`Script` 是脚本化事件源:`run()` 从输入拉取 tag,交给循环的 sink,直到输入说没有了。T48.5 把那个源换成 raw-mode 终端读取,而不是换那条接缝——两者都是 `Input`。这个包声明四个能写 stdout 的托管目标;`wasm` 没有 `printf`,不在其中。`tui/golden/` 是两个包的消费者,里面一块界面由一段点击 Add、Add、Sub 的脚本驱动,它的 `expected.txt` 是解释器的输出,在 `ocaml`、`typescript`、`beam` 上相同。`c` 能编译后端,却拒绝金标那个循环形状(`Global`)——就是上面那个决定,如今深了三个 target。`tui/check.sh` 是这个包的关口;金标逼出的 `beam` 降级缺陷已修好,记在 `CHECK.md`。根目录的 `./check.sh` 最后会接着跑 `tui/check.sh`,让整个项目只留一个入口。用法示例在 `examples/tui_menu/`——一个由脚本化输入驱动的终端菜单——同一个关口也会检查它。

接下来:剩下的每平台包与浏览器运行时路径(T48.5–T48.12)。设计与证据:

- [`docs/zh-CN/emo-ui.md`](../../docs/zh-CN/emo-ui.md) —— 评估与设计方向。
- [`docs/zh-CN/emo-ui-composition.md`](../../docs/zh-CN/emo-ui-composition.md) —— 一棵树怎么写出来:子节点为什么是数组而不是块式写法。
- [`plan/step-48-emo-ui.md`](../../plan/step-48-emo-ui.md) —— 执行计划,T48.1–T48.13。
- [`spike/emo-ui-spelling/`](../../spike/emo-ui-spelling/) —— 定下写法的两屏度量,以及这个核心所自来的原型。
- [`spike/emo-ui-probe/`](../../spike/emo-ui-probe/)、[`spike/components/`](../../spike/components/)、[`spike/macos-gui/`](../../spike/macos-gui/)、[`spike/gtk/`](../../spike/gtk/) —— 语言特性与原生工具包两方面的证据。

## 这个目录的位置

EmoUI 是一个**独立项目**,不是标准库包:标准库以生成数据的形式内嵌在编译器二进制里,而一个带着每平台原生 shim 的 UI 框架不该放在那儿。它活在编译器仓库的 `projects/emo-ui/` 下,以它将来可以拆分出去的仓库命名,好让 `git subtree split -P projects/emo-ui` 之后能带着历史得到那个独立仓库(`CHECK.md`,in-tree 项目布局)。

这个目录由它自己的 `package.emo` 生根——也就是可移植核心的那份,其中 `ui.emo` 就是 `require "emo/ui"` 绑定的那个模块——而仓库根没有 manifest,所以这个包的模块按它自己的程序来检查,编译器的构建也不会把它们扫进来。`debug` 后端是这个包的一个*模块*,而不是下面那类包,因为它不带平台、也不带原生代码:`debug.emo` 就坐在 `ui.emo` 旁边,这也让核心自己的测试能用上它。后面每个后端都是它自己的包:一个带自己 `package.emo` 的子目录,模块遍历会把它整个排除在这个包之外,和 `spike/emo-ui-spelling/mismatch/` 完全一样。`golden/` 是这类包里的第一个——它是消费者而不是后端,但同样出于这个理由自成一体,而且正是它那条 `deps` 在演练各平台包将来要用的 registry 流程。

scope 就是 `emo`,和本仓库每个包用的那一个相同:`deps` 的键是一个字符串字面量,所以包名是数据,不必是词法层面能接受的东西(T11.9)。
