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
- [`docs/zh-CN/intro/configuration.md`](intro/configuration.md) —— 配置即 Emo 表达式，在受限 profile 下求值。

## EmoUI

[EmoUI](projects/emo-ui) 是用 Emo 写的组件式 UI 框架：UI 组合为组件树，从响应式状态渲染。Emo 的语法就是为它塑形的，原则是**没有模板语言——UI 就是普通的 Emo 代码**，与配置同一哲学。组件树是带块的嵌套调用（示意语法）：

```emo
page(title: "Home") {
  navbar() {
    logo()
    menu(routes)
  }

  list(users) -> (user User) {
    card(user) {
      text(user.name)
      text(user.bio)
    }
  }
}
```

这里的一切都是普通语法（见 [`docs/zh-CN/intro/syntax.md`](intro/syntax.md)）：显式括号的调用、单一形式的块、具名参数。组件树由普通函数调用组成——组件定义为函数（`def card(user User) Component { ... }`），或作为类通过同名小写工厂函数暴露（`def card(user User) Component { return Card.new(user) }`）。从调用者一侧，每个组件都是小写函数；大写类型从不被调用，`.new` 从不出现在树里。属于这个领域的一条规则：结构化字面量不可变，所以 props 与组件树是普通的不可变数据。

响应式是显式的而非隐式的：

- 响应式原语住在标准库里，语义显式、可预测——没有隐藏的依赖图。
- 编译器感知优化它们：静态可判定的更新编译为定向刷新，而非运行时 diff。

这些决策与核心设计互相咬合：props 由内置类型检查器检查（渐近类型），UI 事件是进程消息（一个 UI 进程加信箱，在 Emo 并发之上给出 Elm 架构），平台后端只消费组件树及其响应式更新——语言层不知道任何平台细节。

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
- [`docs/zh-CN/stdlib/`](stdlib/) —— 标准库 API 文档(`file`、`os`、`bufio`、`net`、`http`、`json`、`yaml`、`xml`、`base64`、`csv`、`float`、`math`、`plot`、`slog`、`sync`、`sql`、`sqlite3`)。
- [`docs/zh-CN/lsp.md`](lsp.md) —— 语言服务器与 VS Code 扩展。
- [`docs/zh-CN/emo-ui.md`](emo-ui.md) —— EmoUI 的评估与设计方向:一套声明式树渲染到 Web、TUI、macOS 与 GTK 4。
- [`docs/zh-CN/emo-ui-composition.md`](emo-ui-composition.md) —— 一棵 EmoUI 树怎么写出来:组件为什么是返回子节点而不是发射,以及唯一还没定的那个写法问题。
- [`docs/zh-CN/industrial-software.md`](industrial-software.md)、[`docs/zh-CN/sql-database.md`](sql-database.md)、[`docs/zh-CN/rtos-assessment.md`](rtos-assessment.md)、[`docs/zh-CN/xv6.md`](xv6.md)、[`docs/zh-CN/visualization.md`](visualization.md) —— 可行性与市场评估。
- [`docs/zh-CN/TASKS.md`](TASKS.md) —— 实现任务清单。

## 许可

Emo 以 [MIT License](../../LICENSE) 发布。
