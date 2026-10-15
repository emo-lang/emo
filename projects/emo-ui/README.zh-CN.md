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

可移植的 **`ui` 核心**(T48.1)与 **Elm 循环**(T48.2)都已落地。`ui.emo` 是节点脊柱——一个 `Node` 接口,加上 `Column`、`Row`、`Text`、`Button`、`TextInput`、`Image`、`Spacer`、`Scroll` 这些带类型化属性、由位置参数小写构造函数建起的类——以及带 `style()` 工厂与 `with_*` 拷贝的类型化 `Style`、布局词汇(`Align`,以及 style 上的 padding、gap、grow、width、height)、`Backend` 接口(`mount`/`patch`/`run`),还有循环本身:`App`,以及事件登记 tag 用的 `Registry`。它是纯 Emo:没有平台、没有 FFI,并声明了全部五个宿主目标。

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

tag 登记表是循环自己持有的对象,而不是 `docs/emo-ui.md` Layer 5 草拟的模块级 `ui.on(msg)` 表:模块级 `const` 在编译目标上每次读取都会重跑初始化式,模块级 `var` 又只有 `ocaml` 支持,表放在那里等于每次读取都拿到一张新的空表(`CHECK.md`,模块级绑定)。这张表属于某一个正在跑的循环,由循环把它交给 `view`。

循环在 `ocaml`、`typescript`、`beam` 上可编译;在 `c` 与 `wasm` 上还不行,而挡路的是它的拼写而不是它的结构:裸 def 名是唯一能产出 `ui.run` 所收 `Block` 值的表达式,而 `c` 没有 def 当值(`Global`),`wasm` 又拒绝参数多于一个的动态调用。`probe/` 把这个缺口做成一对最小对照——`def_shape/` 是已落地的写法,两个拒绝都能撞到;`handler_shape/` 把应用那两个函数放到 `Handler` 接口后面,是同一个循环,五个 target 全部可编译,在 `c` 与 `ocaml` 上打印出的结果与 `emo run` 一致(`CHECK.md`,Elm 循环的形状)。往哪边收口——把这两个 target 补起来,还是把应用的函数移到接口后面——是 T48.4 起要等的那个开放决定。

`./check.sh` 是它的关口:包能通过类型检查、循环的十四条断言会跑,并且每个 target 的构建结果——以及每一次拒绝——都在里面钉死。

接下来:无头 `debug` 后端(T48.3),以及每平台一个包加浏览器运行时路径(T48.4–T48.12)。设计与证据:

- [`docs/zh-CN/emo-ui.md`](../../docs/zh-CN/emo-ui.md) —— 评估与设计方向。
- [`docs/zh-CN/emo-ui-composition.md`](../../docs/zh-CN/emo-ui-composition.md) —— 一棵树怎么写出来:子节点为什么是数组而不是块式写法。
- [`plan/step-48-emo-ui.md`](../../plan/step-48-emo-ui.md) —— 执行计划,T48.1–T48.13。
- [`spike/emo-ui-spelling/`](../../spike/emo-ui-spelling/) —— 定下写法的两屏度量,以及这个核心所自来的原型。
- [`spike/emo-ui-probe/`](../../spike/emo-ui-probe/)、[`spike/components/`](../../spike/components/)、[`spike/macos-gui/`](../../spike/macos-gui/)、[`spike/gtk/`](../../spike/gtk/) —— 语言特性与原生工具包两方面的证据。

## 这个目录的位置

EmoUI 是一个**独立项目**,不是标准库包:标准库以生成数据的形式内嵌在编译器二进制里,而一个带着每平台原生 shim 的 UI 框架不该放在那儿。它活在编译器仓库的 `projects/emo-ui/` 下,以它将来可以拆分出去的仓库命名,好让 `git subtree split -P projects/emo-ui` 之后能带着历史得到那个独立仓库(`CHECK.md`,in-tree 项目布局)。

这个目录由它自己的 `package.emo` 生根——也就是可移植核心的那份,其中 `ui.emo` 就是 `require "emo_lang/ui"` 绑定的那个模块——而仓库根没有 manifest,所以这个包的模块按它自己的程序来检查,编译器的构建也不会把它们扫进来。后面每个后端都是它自己的包:一个带自己 `package.emo` 的子目录,模块遍历会把它整个排除在这个包之外,和 `spike/emo-ui-spelling/mismatch/` 完全一样。

scope 写成 `emo_lang` 而不是组织名那个带连字符的写法:`deps` 的键是一个带 scope 的标识符,关键字(`emo`)与连字符(`emo-lang`)都写不进去。
