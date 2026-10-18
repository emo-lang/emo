# Emo

Emo 是一门通用编程语言，用 OCaml 5 实现。

仓库：<https://github.com/emo-lang/emo>

## Emo 是什么？

Emo 是**简洁、显式、直观**的。它汲取了三十年开源编程语言的经验——它们的优点与它们的教训——并围绕三条核心原则设计：

- **高表达力的语法。** 代码应当读起来自然，说它所做的事。
- **最小惊讶原则。** 语言规则应当符合程序员直觉；事物应当按你期望的方式工作。
- **多编译目标。** Emo 编译为原生可执行文件、WebAssembly、其他语言（如 TypeScript）、BEAM 虚拟机，以及裸机（`riscv64` 目标——见 EmoOS）。

## 安装

macOS 或 Linux（含 WSL2）上一行搞定——脚本会识别平台、下载最新 release、校验其 SHA256，并安装到 `~/.emo/bin`：

```console
curl -fsSL https://www.emo-lang.cn/cdn/install.sh | sh
```

预编译归档同样可以。覆盖 Apple Silicon Mac 与 x86_64/aarch64 的 Linux——Intel Mac 不是发布目标。二进制内嵌标准库——无需安装其他东西（用 `emo build` 构建时才需要 C 编译器，那是默认 target）。从[下载站点](https://www.emo-lang.cn/cdn/dist/releases.json)获取你平台的归档，然后：

```console
$ unzip emo-<version>-macos-arm64.zip
$ ./emo-<version>-macos-arm64/bin/emo run hello.emo
```

Windows：WSL2 是受支持路径——在 WSL 内按 Linux 的方式安装；原生 Windows 构建在等待运行时移植（见 `docs/toolchain-distribution.md`）。

无论从哪个渠道安装，`emo doctor` 都会按 target 检查环境并说出缺什么。

## 设计细节

每一块设计都有自己的文档：

- [`docs/zh-CN/intro/syntax.md`](intro/syntax.md) —— 语言语法：调用与其尾随块、`def` 与绑定、控制流、值，以及类型定义构造。
- [`docs/reserved_words.md`](../reserved_words.md) —— 保留字、保留字面量与编译器保留名的完整清单（英文）。
- [`docs/zh-CN/intro/type-system.md`](intro/type-system.md) —— 渐近类型、显式位宽的数值类型、结构化收窄。
- [`docs/zh-CN/intro/modules-and-visibility.md`](intro/modules-and-visibility.md) —— 目录树即模块树、`internal/` 私有、显式依赖。
- [`docs/zh-CN/intro/package-management.md`](intro/package-management.md) —— 包即模块前缀、精确版本按 MVS 解析、发布。
- [`docs/zh-CN/intro/concurrency.md`](intro/concurrency.md) —— 进程与消息传递：`do`、`<-`、`receive`。
- [`docs/zh-CN/intro/networking.md`](intro/networking.md) —— 基于 `net` 与 `http` 包的直接风格异步网络 API。
- [`docs/zh-CN/intro/native-builds.md`](intro/native-builds.md) —— `emo build`、随二进制附带的运行时、`foreign def` C 互操作。
- [`docs/zh-CN/intro/testing.md`](intro/testing.md) —— `emo test`、`test/` 约定、`expect_*` 断言。
- [`docs/emo-testing-guide.md`](../emo-testing-guide.md) —— 测试指南：发现规则、四个断言内建、报告与隔离（英文）。
- [`docs/zh-CN/intro/configuration.md`](intro/configuration.md) —— 配置即 Emo 表达式，在受限 profile 下求值。

## EmoUI

[EmoUI](../../projects/emo-ui) 是用 Emo 写的组件式 UI 框架:一棵声明式组件树,渲染到终端、服务端页面、macOS/AppKit 窗口、GTK 4 窗口与浏览器 DOM。Emo 的语法就是为它塑形的,原则是**没有模板语言——UI 就是普通的 Emo 代码**,与配置同一哲学。组件树是嵌套调用,子节点是一份显式的 `Array[ui.Node]`:

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

这里的一切都是普通语法(见 [`docs/zh-CN/intro/syntax.md`](intro/syntax.md)):显式括号的调用、具名参数、不可变数据。子节点是一个实参,永远不是一个块:尾随块是给回调和迭代用的,它产出值时自己 `return`。要到遍历时才知道的子节点列表,用语言自带的 `ArrayBuilder` 攒起来、以 `to_array()` 交出去。没有隐式子节点收集,组件就是普通函数——大写类型从不被调用,`.new` 从不出现在树里。

这个框架是已定设计:

- **一种树类型。** `ui.Node` 是接口;`Column`、`Row`、`Text`、`Button`、`TextInput`、`Image`、`Spacer` 与 `Scroll` 是带类型化属性的类,经小写构造函数(`ui.column`、`ui.text`、`ui.button`……)建起。同一个名字在每个后端上都是同一个组件。
- **带类型的样式。** `ui.Style` 是由 `ui.style()` 建起、经 `with_padding`、`with_gap`、`with_align`、`with_grow`、`with_width` 与 `with_height` 拷贝的带类型值——没有字符串 map,也没有默认参数。它的属性就是那套可移植的布局词汇,每个后端把它映射到平台自己的布局引擎。
- **Elm 状态。** 一个应用是 model、纯 `update`、纯 `view` 加一个后端:`ui.run(view, update, model, backend)`。`view` 收到循环自己的 `Registry`,用 `reg.on(msg)` 登记每条带类型消息并拿回后端投递的 `Int64` tag——应用的类型从不跨过后端接缝。
- **一条后端接缝。** 后端实现 `ui.Backend`——`mount(root, events)`、`patch(old, new)`、`run()`——它只知道一个整数代表一个事件。后端包是 `ui_tui`、`ui_ssr`、`ui_macos`、`ui_gtk` 与 `ui_browser`,外加无头的 `ui.debug`。
- **一个应用,每个后端。** `emo/ui_corpus` 是各关口在每个后端上原样运行的共享应用;它的 debug 与 SSR 入口在全部五个托管编译目标上产出相同的字节。

EmoUI 是 [`projects/emo-ui/`](../../projects/emo-ui) 下的独立项目,不是标准库包——它的原生后端带着每平台 shim 与标准库用不到的 manifest 字段(`.m`、`frameworks`、`pkg_config`)。各包的参考文档就在那里:[`ui`](../../projects/emo-ui/docs/ui.md)、[`debug`](../../projects/emo-ui/docs/debug.md)、[`ui_tui`](../../projects/emo-ui/docs/ui_tui.md)、[`ui_ssr`](../../projects/emo-ui/docs/ui_ssr.md)、[`ui_macos`](../../projects/emo-ui/docs/ui_macos.md)、[`ui_gtk`](../../projects/emo-ui/docs/ui_gtk.md)、[`ui_browser`](../../projects/emo-ui/docs/ui_browser.md)、[`ui_corpus`](../../projects/emo-ui/docs/ui_corpus.md)。

## EmoOS

Emo 的触角伸到操作系统层：这门语言有能力写内核，于是 Emo 内核加 Emo shell——上面再放 EmoUI——构成完整的操作系统，EmoOS。

`riscv64` 编译目标是裸机目标。它假设没有 OS、没有 libc、没有默认运行时；构建 freestanding 的 RISC-V 镜像——内核开发循环是编译、启动、调试，不需要硬件。QEMU 只是这个循环的默认运行器，不属于目标本身；同一镜像可原样运行在真实 RISC-V 硬件上。

写内核从四个方面塑造语言：

- **分层核心库。** `core`（整数、字符串、元组、控制流）零运行时依赖，是内核代码唯一可用的层；标准库需要运行时。
- **显式的内存原语。** 裸内存访问（`peek`/`poke` 及其伙伴）作为显式命名的库函数提供——危险的操作可见地危险。
- **可插拔运行时。** GC、分配器与调度器是裸机目标上可替换的组件，而非注入的默认——内核可以选择最小 GC、arena 或静态分配。
- **单语言闭环。** 内核用 `riscv64` 目标构建，而 shell 与用户程序构建为普通的原生二进制——一门语言贯通系统两侧。

## 实现

Emo 的参考实现用 OCaml 5 编写。自举明确不是目标：Emo 的参考实现保持在 OCaml。

Emo 通过 `foreign def` 与 C 互操作：`c` 后端经 C ABI 直接调用符号，`ocaml` 后端则经生成的 C 包装器编组。

## 文档

文档在 `docs/` 之下。本 README 的中文翻译是 [`docs/zh-CN/README.zh-CN.md`](README.zh-CN.md)。

- [`docs/zh-CN/c-backend.md`](c-backend.md) —— 默认目标：发射 C、C 运行时，以及 C FFI。
- [`docs/zh-CN/ocaml-backend.md`](ocaml-backend.md) —— 发射 OCaml 的后端，以及 OCaml 工具链要求。
- [`docs/zh-CN/toolchain.md`](toolchain.md) —— `emo` CLI 的构建与安装:为何 dune 是唯一需要 OCaml 的一步,以及 justfile 自动化。
- [`docs/zh-CN/toolchain-distribution.md`](toolchain-distribution.md) —— 工具链如何分发：OCaml 依赖、`emo doctor`、以及推迟 `c` 后端。
- [`docs/zh-CN/runtime-and-freestanding.md`](runtime-and-freestanding.md) —— "runtime" 与 "freestanding" 各指什么,以及它们如何对应 Emo 的各目标。
- [`docs/zh-CN/numeric-width.md`](numeric-width.md) —— 所有目标上显式位宽的数值类型。
- [`docs/zh-CN/var-escape.md`](var-escape.md) —— `var` 逃逸规则。
- [`docs/zh-CN/stdlib.md`](stdlib.md) —— 标准库导览:每个包的用途与对外接口。
- [`docs/zh-CN/stdlib/`](stdlib/) —— 标准库 API 文档(`file`、`os`、`bufio`、`net`、`http`、`json`、`yaml`、`xml`、`base64`、`csv`、`float`、`math`、`plot`、`slog`、`sync`、`sql`、`sqlite3`、`term`)。
- [`docs/zh-CN/lsp.md`](lsp.md) —— 语言服务器与 VS Code 扩展。
- [`docs/zh-CN/emo-ui.md`](emo-ui.md) —— EmoUI 的评估与证据:为什么一棵声明式树能跨 TUI、服务端 HTML、macOS、GTK 4 与 DOM 工作,以及还有什么仍然开放。
- [`docs/zh-CN/emo-ui-composition.md`](emo-ui-composition.md) —— 一棵 EmoUI 树怎么写出来:子节点为什么是数组而不是块式写法,以及数组写法是否该再长出字面量拼法。
- [`docs/zh-CN/industrial-software.md`](industrial-software.md)、[`docs/zh-CN/sql-database.md`](sql-database.md)、[`docs/zh-CN/rtos-assessment.md`](rtos-assessment.md)、[`docs/zh-CN/xv6.md`](xv6.md)、[`docs/zh-CN/visualization.md`](visualization.md) —— 可行性与市场评估。
- [`docs/zh-CN/TASKS.md`](TASKS.md) —— 实现任务清单。

## 许可

Emo 以 [MIT License](../../LICENSE) 发布。
