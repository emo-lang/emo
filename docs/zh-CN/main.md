## Emo 是什么

Emo 是一门通用编程语言，设计沿三条轴展开:**Go 的简洁、C 的速度、
Ruby 的优雅**。

### Go 的简洁

Emo 借的是 Go 的**机制**，保留的是自己的**外表**。让一门语言小而可预测
的那些机制都在这里:

- **声明只有一种写法。** 函数和方法用 `def`，类型用 `class`，契约用
  `interface`，封闭集合用 `enum`，无状态函数组用 `emo`。每个调用都有
  括号。
- **结构化接口，没有继承。** 一个类只要方法对得上就满足接口;没有
  `implements` 子句，没有父类，也没有方法提升。复用来自组合与鸭子类型
  的函数。
- **一套模块系统。** 目录树就是模块树;包是模块前缀;`internal/` 是唯一
  的隐私规则。没有 import 列表，没有 export 列表，也没有可见性关键字。
- **没有泛型机器。** 参数化类型(`Array[T]`、`Map[K, V]`、`Box[T]`)是
  编译器认识的类型声明词汇;应用依赖推断，很少写出类型。
- **小而全的工具链。** 一个 `emo` 二进制带着标准库与各编译器。
  `emo build` 只需要系统的 C 编译器;`emo new`、`emo run`、`emo check`、
  `emo test`、`emo doctor`、`emo docs` 与 `emo man` 组成完整命令集。
  库没有安装步骤。

Emo 不从 Go 借的是外表:语法、关键字、工具命名都是自己的。机制可以从
任何语言借;可辨认的单一来源指纹不行。

### C 的速度

默认构建目标发射 C，并用系统 `cc` 编译，所以一个程序是独立的原生
二进制——旁边没有 OCaml 运行时，也没有解释器:

- **默认原生代码。** `emo build` 默认目标 `c`;另外还有 `ocaml`、
  `typescript`、`wasm`、`beam`、`browser`，以及 freestanding 的
  `riscv64` 镜像。
- **保证的尾调用。** 循环与尾递归保持原生栈平坦;trampoline 是目标本身
  的一部分，不是提示。
- **直接的 C ABI。** `foreign def` 在 `c` 上经 C ABI 直接调用 C 符号，
  没有包装器生成;`ocaml` 目标则经生成的包装器编组。
- **裸机。** `riscv64` 目标假设没有 OS、没有 libc、没有默认运行时——
  语言能写到内核，EmoOS 就建在这上面。

数字在 [`benchmarks/results.md`](../../benchmarks/results.md);2026-11-09
的记录里，`fib(30)` 在 `c` 目标上是 26 ms，解释器上是 980 ms;
一千万次尾循环是 37 ms 对 6.2 s。同样的源码仍然可以构建到
WebAssembly、TypeScript 与 BEAM。

### Ruby 的优雅

表达力是一条设计轴，不是装饰:

- **字符串可以插值任何表达式**(`"hello, ${name}"`)，调用可以把尾随块
  作为最后一个实参——回调、迭代与 UI 树背后的唯一记法。
- **谓词读起来就是谓词。** 名字以 `?` 结尾的方法回答 `Bool`:
  `user.is_older?()`、`ticket.available?()`。
- **值类型就是值。** 实例不可变;"修改"一个值的方法返回新实例，相等是
  结构相等。
- **`case` 是一门模式语言。** 枚举成员、字面量、元组与 `_` 按形状匹配，
  并带 `when` 守卫;糖形式(`:chain`、`:foreach`、`:when`、`:raise`)
  缩短普通代码已经能写出的形状。
- **配置就是 Emo,UI 也是。** 配置文件是一个 Emo 表达式;一棵 EmoUI 树
  就是普通的 Emo 调用。没有模板语言，没有字符串 map，也没有另一套 DSL
  要学。

优雅在代码的形状里，不在借来的语法里:表面是 Emo 自己的，组合笔记
([`emo-ui-composition.md`](emo-ui-composition.md))记录了 Ruby 式树的想法
在哪里停下、Emo 自己的数组子节点从哪里开始。

## 文档如何组织

文档是 `docs/` 下的一棵树，中文镜像在 `docs/zh-CN/`。每页都是普通
Markdown;其中两套同时嵌入编译器二进制。

| 位置 | 内容 |
| --- | --- |
| [`README.md`](../../README.md) | 项目概览、安装，以及完整的文档索引 |
| `docs/main.md` | 本页地图与阅读路径 |
| [`docs/intro/`](intro/) | 语言:语法、类型、模块、包、并发、网络、配置、测试、原生构建、宏，以及语言导览;`emo docs` 渲染这些页面 |
| [`docs/stdlib.md`](stdlib.md)、[`docs/stdlib/`](stdlib/) | 标准库:每个包的导览，然后一包一页 API 参考;`emo man` 渲染这些页面 |
| `docs/*-guide.md` | 面向任务的指南:[`httpd-guide`](httpd-guide.md)、[`emosh-guide`](emosh-guide.md)、[`plot-guide`](plot-guide.md)、[`playwright-guide`](playwright-guide.md)、[`macro-guide`](macro-guide.md)、[`emo-testing-guide`](emo-testing-guide.md) |
| [`docs/emo-ui/intro.md`](emo-ui/intro.md) | EmoUI 入门指南 |
| [`docs/c-backend.md`](c-backend.md)、[`ocaml-backend.md`](ocaml-backend.md)、[`demo-targets.md`](demo-targets.md)、[`runtime-and-freestanding.md`](runtime-and-freestanding.md)、[`toolchain.md`](toolchain.md)、[`toolchain-distribution.md`](toolchain-distribution.md)、[`lsp.md`](lsp.md)、[`gc-heap.md`](gc-heap.md) | 目标、运行时、工具链、编辑器支持与 GC 堆 |
| [`docs/reserved_words.md`](reserved_words.md)、[`numeric-width.md`](numeric-width.md)、[`var-escape.md`](var-escape.md)、[`raw-memory.md`](raw-memory.md)、[`atomics.md`](atomics.md) | 语言的参考脚注 |
| [`projects/`](../../projects/) | 与代码放在一起的项目文档:[EmoUI](../../projects/emo-ui/docs/README.zh-CN.md)、[EmoOS](../../projects/emo-os/README.zh-CN.md)、[Emo 桌面](../../projects/emo-desktop/README.zh-CN.md)、[EmoDB](../../projects/emo-db/README.zh-CN.md)、[Emo shell](../../projects/emo-shell/)、[playground](../../projects/emo-playground/README.zh-CN.md) |
| [`docs/emo-ui.md`](emo-ui.md)、[`emo-db.md`](emo-db.md)、[`unkernel.md`](unkernel.md)、[`industrial-software.md`](industrial-software.md)、[`sql-database.md`](sql-database.md)、[`rtos-assessment.md`](rtos-assessment.md)、[`xv6.md`](xv6.md)、[`visualization.md`](visualization.md)、[`math-netlib.md`](math-netlib.md)、[`esp32.md`](esp32.md)、[`lua-backend.md`](lua-backend.md)、[`zig-backend.md`](zig-backend.md)、[`noctalia-desktop.md`](noctalia-desktop.md)、[`noctalia-v5.md`](noctalia-v5.md) | 设计记录与可行性评估——决策背后的推理 |
| [`docs/TASKS.md`](TASKS.md)、[`plan/`](../../plan/README.md)、[`CHECK.md`](../../CHECK.md) | 实现追踪表与已定的设计决策 |
| [`docs/zh-CN/`](README.md) | 中文镜像，与 `docs/` 同构;少数内部页面只有英文 |

两个通道读同一批页面:

- **终端里。** `emo docs` 列出导言页，`emo docs <page>` 打印其中一页;
  `emo man` 对标准库做同样的事(`emo man`、`emo man json`、
  `emo man stdlib`)。二进制带着这些页面，安装后的编译器身边什么都不
  需要。
- **网页上。** <https://docs.emo-lang.cn/> 提供由本树构建的指南:
  语言导览在 <https://docs.emo-lang.cn/guides/tour/>，EmoUI 指南在
  <https://docs.emo-lang.cn/guides/emo-ui/intro>;中文页加 `/zh/` 前缀。

## 从语言导览开始

[`docs/intro/tour.md`](intro/tour.md) 是从"我听说过 Emo"到"我能写程序"
的最短路径。它是一份可以读、也可以跑的程序:每个 `run` 块都会编译成
Wasm，并由 `just tour` 逐字节比较输出，所以正文不会和语言脱节。

它从十分钟的快速开始进入，然后是十章短章:

- 值与绑定、字符串;
- 控制流;
- 函数、箭头块与元组;
- 类与结构化接口;
- 枚举与 `case`;
- 集合(`Array`、`ArrayBuilder`、`Map`);
- 错误即值:`(R.ok, ...)` / `(R.error, ...)`;
- 模块、包与标准库的 `json`;
- 进程与消息传递;
- 一个把它们合在一起的小业务切片。

三种读法:在编辑器里读 [`docs/intro/tour.md`](intro/tour.md);在终端里
`emo docs tour`;或在网页上读 <https://docs.emo-lang.cn/guides/tour/>
(中文:<https://docs.emo-lang.cn/zh/guides/tour/>)。

## 然后用 EmoUI 写界面

[`docs/emo-ui/intro.md`](emo-ui/intro.md) 是 EmoUI 的入门指南。它从零
构建两个应用，并给出完整代码:

1. **Hello, World**——一个空窗口，里面一行文字，展示最小的应用:
   一个 `view`、一个 `update` 与 `ui.run`。
2. **Counter**——一个数字与两个按钮，展示循环的事件 tag、`update` 返回
   新 model，以及一行等宽按钮。

指南里两者都跑在 macOS/AppKit 窗口上;同一份 `view` 与 `update` 换个
后端就搬到 GTK 4 窗口、终端、服务端页面或浏览器——这条接缝在指南和
[`projects/emo-ui/README.md`](../../projects/emo-ui/README.zh-CN.md) 里
解释。完整的演算应用、七个后端入口共享一个 app 模块，在
[`projects/emo-ui/apps/calculator/`](../../projects/emo-ui/apps/calculator/)。

读它:[`docs/emo-ui/intro.md`](emo-ui/intro.md)，或网页
<https://docs.emo-lang.cn/guides/emo-ui/intro>(中文:
<https://docs.emo-lang.cn/zh/guides/emo-ui/intro>)。

## 阅读路径

| 如果你想…… | 读 |
| --- | --- |
| 开始学这门语言 | [`docs/intro/tour.md`](intro/tour.md)，然后 [`docs/intro/syntax.md`](intro/syntax.md) |
| 做一个用户界面 | [`docs/emo-ui/intro.md`](emo-ui/intro.md)，然后是 calculator，再是 [`projects/emo-ui/docs/ui.md`](../../projects/emo-ui/docs/ui.md) |
| 使用标准库 | [`docs/stdlib.md`](stdlib.md) 与 `emo man <package>` |
| 研究目标与系统 | [`docs/c-backend.md`](c-backend.md)、[`docs/runtime-and-freestanding.md`](runtime-and-freestanding.md)、[`docs/demo-targets.md`](demo-targets.md)，以及 EmoOS 项目 |
| 理解某个设计决策 | `docs/` 下的记录——[`emo-ui.md`](emo-ui.md)、[`emo-db.md`](emo-db.md)、[`unkernel.md`](unkernel.md) |
| 跟进实现 | [`docs/TASKS.md`](TASKS.md) 与 [`plan/`](../../plan/README.md) 下的步骤计划 |
