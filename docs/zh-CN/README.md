# Emo

Emo 是一门通用编程语言，用 OCaml 5 实现。

仓库：<https://github.com/emo-lang/emo>

本页是 Emo 的中文入口：项目概览与安装，以及 `docs/` 下全部设计文档、指南与 API 参考的索引。英文原文是根目录的 [`README.md`](../../README.md)。

## Emo 是什么？

Emo 是**简洁、显式、直观**的。它汲取了三十年开源编程语言的经验——它们的优点与它们的教训——并围绕三条核心原则设计：

- **高表达力的语法。** 代码应当读起来自然，说它所做的事。
- **最小惊讶原则。** 语言规则应当符合程序员直觉；事物应当按你期望的方式工作。
- **多编译目标。** Emo 编译为原生可执行文件、WebAssembly、其他语言（如 TypeScript）、可直接放进页面的浏览器包、BEAM 虚拟机,以及裸机(`riscv64` 目标——见 EmoOS)。解释器直接运行程序,无需产物;[`demo-targets.md`](demo-targets.md) 用一个项目走遍全部七个构建目标。

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
- **一个应用,每个后端。** `emo/ui_corpus` 是各关口在每个后端上原样运行的共享应用;它的 debug 与 SSR 入口在 `c`、`ocaml`、`typescript`、`wasm`、`beam` 这五个托管目标上产出相同的字节。

EmoUI 是 [`projects/emo-ui/`](../../projects/emo-ui) 下的独立项目,不是标准库包——它的原生后端带着每平台 shim 与标准库用不到的 manifest 字段(`.m`、`frameworks`、`pkg_config`)。各包的参考文档就在那里:[`ui`](../../projects/emo-ui/docs/ui.md)、[`debug`](../../projects/emo-ui/docs/debug.md)、[`ui_tui`](../../projects/emo-ui/docs/ui_tui.md)、[`ui_ssr`](../../projects/emo-ui/docs/ui_ssr.md)、[`ui_macos`](../../projects/emo-ui/docs/ui_macos.md)、[`ui_gtk`](../../projects/emo-ui/docs/ui_gtk.md)、[`ui_browser`](../../projects/emo-ui/docs/ui_browser.md)、[`ui_corpus`](../../projects/emo-ui/docs/ui_corpus.md)。

## EmoOS

Emo 的触角伸到操作系统层：这门语言有能力写内核，于是 Emo 内核加 Emo shell——上面再放 EmoUI——构成完整的操作系统，EmoOS。

EmoOS 是 [`../../projects/emo-os/`](../../projects/emo-os) 下的独立项目——定案设计与任务追踪都在它的 [README](../../projects/emo-os/README.zh-CN.md) 里。

其上的桌面也是独立项目:[`projects/emo-desktop/`](../../projects/emo-desktop)——EmoOS 门上的合成窗口 GUI,单语言闭环的下一段路。

## Emo Playground

[`projects/emo-playground/`](../../projects/emo-playground) 是访客在浏览器里写 Emo、在服务器上运行它的 web 应用——用 Emo 写成,由 Emo 自己的 `httpd` 服务,每次提交都交给 Emo 自己的解释器,在工具链为它保管的 `--curfew` 之下运行。定案设计与任务追踪都在它的 [README](../../projects/emo-playground/README.zh-CN.md) 里。

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

文档在 `docs/` 之下;本页就是它的完整中文索引,英文索引见根目录 [`README.md`](../../README.md) 的 Documentation 一节。中文文档与英文文档同构,未翻译的页面在下方逐条标出。

### 语言

- [`intro/syntax.md`](intro/syntax.md)——语法:调用与尾随块、`def` 与绑定、
  控制流、值,以及类型定义构造。
- [`reserved_words.md`](reserved_words.md)——编译器保留的全部保留字、保留
  字面量与内建名。
- [`intro/type-system.md`](intro/type-system.md)——渐近类型、显式位宽的
  数值类型、结构化收窄。
- [`intro/modules-and-visibility.md`](intro/modules-and-visibility.md)——目录树
  即模块树、`internal/` 隐私、显式依赖。
- [`intro/package-management.md`](intro/package-management.md)——包即模块前缀、
  MVS 精确解析、发布。
- [`intro/concurrency.md`](intro/concurrency.md)——进程与消息传递:`do`、
  `<-`、`receive`。
- [`intro/networking.md`](intro/networking.md)——`net` 与 `http` 包之上的
  直接风格网络 API。
- [`intro/configuration.md`](intro/configuration.md)——配置即 Emo 表达式,
  在受限 profile 中求值。
- [`intro/testing.md`](intro/testing.md)——`emo test`、`test/` 约定与
  `expect_*` 断言。
- [`intro/native-builds.md`](intro/native-builds.md)——`emo build`、二进制内的
  运行时,以及 `foreign def` C 互操作。
- [`intro/macros.md`](intro/macros.md)——编译期宏:指令、`Syntax` API 与
  quote 面。

### 指南

- [`tour.md`](tour.md)——语言导览:快速开始加十章,每个可运行的 Emo 块在检查文档时编译成 Wasm 并运行。
- [`httpd-guide.md`](httpd-guide.md)——Web 服务器指南:从十行的
  `httpd.serve` 到带进程自有状态、中间件与优雅关闭的 JSON API。
- [`emosh-guide.md`](emosh-guide.md)——用 Emo 写的命令解释器 `emosh`:
  管道、重定向、展开与内建命令。
- [`plot-guide.md`](plot-guide.md)——用 `plot` 包画图:完整公开 API 与示例。
- [`playwright-guide.md`](playwright-guide.md)——从 Emo 驱动真实浏览器。
- [`macro-guide.md`](macro-guide.md)——面向任务的宏走读:配方与错误表。
- [`emo-testing-guide.md`](emo-testing-guide.md)——详细的测试指南:发现规则、
  四个断言内建、报告与隔离。
- [`lsp.md`](lsp.md)——语言服务器 `emo-lsp` 与编辑器集成。

### 编译目标与工具链

- [`c-backend.md`](c-backend.md)——默认目标:发射 C、C 运行时与 C FFI。
- [`ocaml-backend.md`](ocaml-backend.md)——发射 OCaml 的后端与 OCaml 工具链
  要求。
- [`demo-targets.md`](demo-targets.md)——用一个脚手架项目走遍全部目标,
  包括 `beam` 与 `wasm` 产物如何执行。
- [`runtime-and-freestanding.md`](runtime-and-freestanding.md)——"runtime" 与
  "freestanding" 各指什么,以及它们如何对应 Emo 的各目标。
- [`toolchain.md`](toolchain.md)——构建与安装 `emo` CLI。
- [`toolchain-distribution.md`](toolchain-distribution.md)——工具链如何分发:
  安装渠道、`emo doctor` 与签名。
- [`numeric-width.md`](numeric-width.md)——所有目标上的显式位宽数值类型。
- [`var-escape.md`](var-escape.md)——`var` 逃逸规则。
- [`raw-memory.md`](raw-memory.md)——`peek`/`poke` 与裸内存接口。
- [`atomics.md`](atomics.md)——`Atomic`,`Box` 的同步孪生。
- [`gc-heap.md`](gc-heap.md)——GC 堆的 arena、对象模型与 Emo 写的收集器。

### 标准库

- [`stdlib.md`](stdlib.md)——导览:每个包的用途与对外接口。
- [`stdlib/`](stdlib/)——各包的 API 参考。大致分组:
  - **格式与文本**——[`json`](stdlib/json.md)、[`yaml`](stdlib/yaml.md)、
    [`toml`](stdlib/toml.md)、[`xml`](stdlib/xml.md)、[`csv`](stdlib/csv.md)、
    [`template`](stdlib/template.md)、[`dom`](stdlib/dom.md)、
    [`base64`](stdlib/base64.md)。
  - **数值与图表**——[`float`](stdlib/float.md)、[`math`](stdlib/math.md)、
    [`fastmath`](stdlib/fastmath.md)、[`quad`](stdlib/quad.md)、
    [`plot`](stdlib/plot.md)。
  - **系统与 IO**——[`file`](stdlib/file.md)、[`os`](stdlib/os.md)、
    [`bufio`](stdlib/bufio.md)、[`term`](stdlib/term.md)、
    [`net`](stdlib/net.md)、[`http`](stdlib/http.md)、
    [`httpd`](stdlib/httpd.md)、[`valkey`](stdlib/valkey.md)、
    [`websocket`](stdlib/websocket.md)、[`playwright`](stdlib/playwright.md)、
    [`wayland`](stdlib/wayland.md)、[`sync`](stdlib/sync.md)、
    [`time`](stdlib/time.md)、[`slog`](stdlib/slog.md)、
    [`syscall`](stdlib/syscall.md)(EmoOS 门的用户侧)。
  - **运行时与数据**——[`crypto`](stdlib/crypto.md)、[`hash`](stdlib/hash.md)、
    [`rand`](stdlib/rand.md)、[`uuid`](stdlib/uuid.md)、
    [`sql`](stdlib/sql.md)、[`sqlite3`](stdlib/sqlite3.md)、
    [`postgres`](stdlib/postgres.md)、[`gc`](stdlib/gc.md)、
    [`wasm`](stdlib/wasm.md)。

标准库导览与 `stdlib/` 下的每一页在构建时嵌入编译器二进制;`emo man <package>`
在终端渲染其中一页,`emo man` 列出全部。改这里的 Markdown,手册随之更新。

### 项目

每个项目的文档与代码放在一起:

- **EmoUI**——[`../../projects/emo-ui/docs/`](../../projects/emo-ui/docs/README.zh-CN.md):
  横跨终端、服务端页面、macOS、GTK 4 与浏览器 DOM 的组件框架。
- **EmoOS**——[`../../projects/emo-os/`](../../projects/emo-os/README.zh-CN.md):
  内核、shell,以及通往完整操作系统的路径。
- **Emo 桌面**——[`../../projects/emo-desktop/`](../../projects/emo-desktop/README.zh-CN.md):
  EmoOS 门之上的合成窗口 GUI。
- **EmoDB**——[`../../projects/emo-db/`](../../projects/emo-db/README.zh-CN.md),
  设计记录见 [`emo-db.md`](emo-db.md):一条 SQL 表面、两台引擎。
- **Emo shell**——[`../../projects/emo-shell/`](../../projects/emo-shell/),
  指南见 [`emosh-guide.md`](emosh-guide.md)。
- **Emo Playground**——
  [`../../projects/emo-playground/`](../../projects/emo-playground/README.zh-CN.md):
  由 Emo 自己的 `httpd` 服务的浏览器演练场。

### 评估与设计记录

这些文档记录一次调研、一个决策或一个方向。它们不是教程,其中一部分
是历史记录:读它们的推理,而不是当作当前参考。

- **EmoUI**——[`emo-ui.md`](emo-ui.md)(可行性评估与设计方向)、
  [`emo-ui-composition.md`](emo-ui-composition.md)(一棵树怎么写出来)、
  [`emo-ui-check.md`](emo-ui-check.md)(决策闸门)、
  [`emo-ui-missing.md`](emo-ui-missing.md)(还缺什么)。
- **平台**——[`unkernel.md`](unkernel.md)、
  [`noctalia-desktop.md`](noctalia-desktop.md)、
  [`noctalia-v5.md`](noctalia-v5.md)、
  [`industrial-software.md`](industrial-software.md)。
- **语言与工具链**——[`lua-backend.md`](lua-backend.md)、
  [`zig-backend.md`](zig-backend.md)、[`esp32.md`](esp32.md)、
  [`xv6.md`](xv6.md)、[`rtos-assessment.md`](rtos-assessment.md)。
- **数据与数学**——[`sql-database.md`](sql-database.md)、
  [`math-netlib.md`](math-netlib.md)、[`visualization.md`](visualization.md)。
- **语言机制**——[`../macros.md`](../macros.md),宏表面的工作设计(教程见
  [`intro/macros.md`](intro/macros.md),配方见
  [`macro-guide.md`](macro-guide.md))(英文)。

### 内部与追踪

- [`TASKS.md`](TASKS.md)——实现任务清单,每个里程碑一节。
- [`../../plan/README.md`](../../plan/README.md)——各步骤计划与状态表。
- [`../emo-test-ir.md`](../emo-test-ir.md)——断言内建为何只留在解释器,
  以及编译构建如何处理 `test/`(英文)。
- [`../temp-check-bugs.md`](../temp-check-bugs.md)——从 `CHECK.md` 带出的
  未决 bug 工作清单,不是设计文档(英文)。

### 翻译状态

除本页(项目 README 的中文版)外,`docs/zh-CN/` 与英文 `docs/` 同构;以下页面目前只有英文:

- [`../emo-test-ir.md`](../emo-test-ir.md)
- [`../temp-check-bugs.md`](../temp-check-bugs.md)
- [`../macros.md`](../macros.md)

更新英文文档时,请同步更新对应的中文翻译,或在英文页注明中文尚未跟进。

## 许可

Emo 以 [MIT License](../../LICENSE) 发布。
