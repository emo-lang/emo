# EmoUI 入门

EmoUI 是 Emo 的 UI 框架：一棵声明式组件树，渲染到 macOS/AppKit 窗口、
GTK 4 窗口、终端、服务端页面与浏览器 DOM。一个应用就是普通 Emo——一个
model、一个纯 `update`、一个纯 `view`——后端是唯一与平台相关的部分。

本指南从零写两个应用：一个显示 Hello, World 的窗口，以及一个带加减按钮
的计数器。两者都是完整的：每个例子的 `package.emo` 与 `main.emo` 都完整
给出。

## 组成

- **`emo/ui`** 是可移植核心：节点构造器(`column`、`row`、`text`、
  `button`……)、带类型的 `Style`、循环(`ui.run`)以及后端接缝。它是
  纯 Emo，不点名任何平台。
- **后端包**负责把树画出来：`emo/ui_macos`、`emo/ui_gtk`、`emo/ui_tui`、
  `emo/ui_ssr`、`emo/ui_browser`，以及无头的 `ui.debug`。
- **下面两个应用在每个后端上都一样。** 改掉 `main` 的最后一行——以及
  manifest 里的后端依赖——同一个窗口就搬到 GTK、终端、网页或浏览器上。

EmoUI 住在本仓库的 `projects/emo-ui/` 下;它的包版本是 `0.1.0`，不在
编译器内置的标准库里。下面的例子用 macOS 后端和 `c` 目标。先像项目自己
的门禁那样，把仓库里的包 stage 成一个 registry：

```console
$ cd <emo checkout>
$ scripts/stage-registry.sh "$PWD/.emo-registry"
$ export EMO_REGISTRY="$PWD/.emo-registry"
```

原生窗口是一个构建出来的程序，不是解释器运行：`emo run` 拒绝 foreign
代码(E3009)，所以用 `emo build` 构建，再启动二进制。

## 1 · Hello, World

第一个应用是一个只有一行文字的窗口。

```emo
// package.emo
package {
  name = "emo/hello_ui"
  version = "0.1.0"
  targets = ["c"]

  deps {
    "emo/ui" = "0.1.0"
    "emo/ui_macos" = "0.1.0"
  }
}
```

```emo
// main.emo
require "emo/ui"
require "emo/ui_macos"

def view(reg ui.Registry, model Int64) ui.Node {
  return ui.column([
    ui.text("Hello, World", ui.style())
  ], ui.style().with_padding(24.0))
}

def update(msg Int64, model Int64) Int64 {
  return model
}

def main() {
  ui.run(view, update, 0, ui_macos.backend("Hello, World", 320.0, 120.0, ""))
}

main()
```

在放着这两个文件的目录里构建并运行：

```console
$ emo build main.emo --target c -o hello
$ ./hello
```

一个标题为 "Hello, World" 的窗口打开，320 × 120 点，文字距四边 24 点。
第一次构建还会写出 `package.lock`;把它和 manifest 放在一起。

每一部分在做什么：

- **`ui.column([...], style)`** 是根。子节点是一份显式的
  `Array[ui.Node]`——永远不是块，也没有隐式子节点收集。
- **`ui.text("Hello, World", ui.style())`** 是叶子。`ui.style()` 是空
  样式;`with_padding` 返回只改了一个属性的副本。
- **`view`** 从 model 构建这棵树。它是纯的，循环每一帧都会再调用它。
- **`update`** 是循环的另一半。这个窗口里没有东西会变，所以它把 model
  原样返回——但循环要求这个函数存在。
- **`ui.run(view, update, 0, backend)`** 用 `0` 作为初始 model(这里是
  一个 `Int64`)启动循环。
- **`ui_macos.backend(title, width, height, script)`** 是平台入口。尺寸
  单位是点;最后一个参数是测试用的自驱动输入脚本，真实应用传 `""`。

## 2 · 循环与后端接缝

整个框架就是一个循环：

```text
model ──view──▶ tree ──backend──▶ window
  ▲                                 │
  └──────── update ◀── event tag ◀──┘
```

`view` 收到循环的 `Registry` 和 model。按钮不携带闭包，它携带一个
**`Int64` tag**，因为闭包无法跨过 FFI。`reg.on(msg)` 注册一条消息并
返回它的 tag：

```emo
const plus = reg.on(Msg.inc)
```

取 tag 要放在自己的语句里、建树之前：`on` 是一个副作用，独立语句让注册
顺序在调用处可见。用户点击时，后端投递 tag，循环把它映射回消息、调用
`update`、重建 view。model 是值：`update` 返回新的一个，而不是修改旧的。

一个后端实现三个方法——`mount(root, events)`、`patch(old, next)` 与
`run()`——并且只知道一个整数代表一个事件。这就是同一个应用能到处跑的
原因：

| 后端 | 传给 `ui.run` 的入口 | 目标 |
| --- | --- | --- |
| macOS / AppKit | `ui_macos.backend(title, width, height, script)` | macOS 上的 `c` |
| GTK 4 | `ui_gtk.backend(title, width, height, script)` | 带 GTK 4 的 `c` |
| 终端 | `ui_tui.backend(width, height, input)` | `ocaml`、`c`、`typescript`、`beam` |
| 服务端页面 | `ui_ssr.backend(title)`(或 `ui_ssr.page(title, root)`) | 五个托管目标 |
| 浏览器 | `ui_browser.backend(title)` | `browser` |
| 无头 | `ui.debug.render(root)` | 每个托管目标 |

下面的应用代码不随后端改变;变的只有 `main` 的最后一行和 manifest 里的
`deps`/`targets`。

## 3 · Counter

第二个应用持有一个数字并改变它：两个按钮，加号与减号，以及一行显示
计数。

```emo
// package.emo
package {
  name = "emo/counter_ui"
  version = "0.1.0"
  targets = ["c"]

  deps {
    "emo/ui" = "0.1.0"
    "emo/ui_macos" = "0.1.0"
  }
}
```

```emo
// main.emo
require "emo/ui"
require "emo/ui_macos"

enum Msg {
  inc,
  dec
}

def update(msg Msg, count Int64) Int64 {
  case msg {
    Msg.inc then { return count + 1 }
    Msg.dec then { return count - 1 }
  }
}

def view(reg ui.Registry, count Int64) ui.Node {
  const plus = reg.on(Msg.inc)
  const minus = reg.on(Msg.dec)
  return ui.column([
    ui.text("${count}", ui.style()),
    ui.row([
      ui.button("+", plus, ui.style().with_grow(true)),
      ui.button("-", minus, ui.style().with_grow(true))
    ], ui.style().with_gap(8.0))
  ], ui.style().with_padding(16.0).with_gap(16.0))
}

def main() {
  ui.run(view, update, 0, ui_macos.backend("Counter", 260.0, 160.0, ""))
}

main()
```

同样构建并运行：

```console
$ emo build main.emo --target c -o counter
$ ./counter
```

一个 260 × 160 的窗口打开，顶部是 `0`，下面是两个按钮。点击 `+` 发送
`inc` tag，`update` 返回 `count + 1`，循环重建 view;后端保留已有的
文字控件、只改它的内容，所以窗口不会闪烁。点击 `-` 则反过来。

每一部分在做什么：

- **`enum Msg { inc, dec }`** 是消息类型。消息可以是枚举、元组或任何值;
  这里两个成员就够了。
- **`update`** 用 `case` 匹配消息并返回下一个 model。model 是
  `Int64`;没有可变状态需要更新。
- **`reg.on(Msg.inc)`** 把每条消息变成对应按钮携带的 tag。tag 在建树
  之前、在各自的语句里取出。
- **`ui.text("${count}", ...)`** 渲染 model，因为 `view` 每帧都看到当前
  的那一个。
- **`ui.row([...], style)`** 把两个按钮横着排;`with_grow(true)` 让每个
  按钮分到等宽的一份，`with_gap(8.0)` 把它们隔开。
- **`ui.run(view, update, 0, ...)`** 从零开始计数。

计数器可以减到负数，没有任何东西阻止它——如果要有业务规则，它属于
`update`，不属于按钮。这就是这个循环的意义：`update` 拥有策略，`view`
拥有画面，后端拥有平台。

## 4 · 一页讲完布局与样式

- **容器**是 `ui.column`、`ui.row` 与 `ui.scroll`，都接收一份
  `Array[ui.Node]`。运行时才知道的列表用 `ArrayBuilder` 攒起来，以
  `to_array()` 交出去。
- **叶子**是 `ui.text`、`ui.button`、`ui.text_input`、`ui.image` 与
  `ui.spacer`。`ui.button` 是唯一携带事件的叶子。
- **样式是不可变值。** `ui.style()` 是空的;每个 `with_*` 返回只改一个
  属性的副本：`with_padding`、`with_gap`、`with_align`、`with_grow`、
  `with_width`、`with_height`。没有默认参数，所以不带样式的调用要把工厂
  写出来：`ui.text("a", ui.style())`。
- **宽度和高度是 `(R, Float64)`**：`(R.ok, 12.0)` 是一个尺寸，
  `(R.error, 0.0)` 交给平台决定。上面的计数器用 `grow` 而不是固定宽度，
  因为 `Style` 的数字在 macOS 和 GTK 上是点、在终端是字符格、在浏览器
  是像素——固定尺寸在这些单位之间不可移植。
- **key**(`ui.keyed("id", node)`)在列表重排时保住子节点的身份。没有
  key 时，身份由位置与类型决定。

## 5 · 接下来

- [`projects/emo-ui/apps/calculator/`](../../../projects/emo-ui/apps/calculator/)
  ——完整演算的应用：一个 model、一个纯 update、一个纯 view，以及共享同一个
  app 模块的七个后端入口(debug、TUI、SSR、macOS、GTK、浏览器、
  framebuffer)。
- [`projects/emo-ui/docs/ui.md`](../../../projects/emo-ui/docs/ui.md)——
  核心参考：节点、样式、diff 与循环。
- 旁边的后端参考：
  [`ui_macos`](../../../projects/emo-ui/docs/ui_macos.md)、
  [`ui_gtk`](../../../projects/emo-ui/docs/ui_gtk.md)、
  [`ui_tui`](../../../projects/emo-ui/docs/ui_tui.md)、
  [`ui_ssr`](../../../projects/emo-ui/docs/ui_ssr.md)、
  [`ui_browser`](../../../projects/emo-ui/docs/ui_browser.md) 与
  [`debug`](../../../projects/emo-ui/docs/debug.md)。
- [`emo-ui.md`](../../emo-ui.md)——框架为什么是这个形状，证据是什么。
- [`projects/emo-ui/README.zh-CN.md`](../../../projects/emo-ui/README.zh-CN.md)
  ——包地图、收敛语料与各门禁。
