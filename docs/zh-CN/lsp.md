# Emo 语言服务器

Emo 自带语言服务器协议（LSP）实现 `emo-lsp`，以及驱动它的编辑器集成：一个
Visual Studio Code 扩展和一个 Neovim 插件。它们共同为 `.emo` 源文件提供语法
高亮、补全、诊断、悬停、导航与包管理。

## 构建服务器

服务器是与编译器同一代码树中的 OCaml 可执行文件：

```sh
dune build bin/emo_lsp_bin.exe        # 产出 _build/default/bin/emo_lsp_bin.exe
dune install                          # 将 `emo-lsp` 与 `emo` 一同安装
```

`emo-lsp` 通过 stdio 使用 LSP，与任何 LSP 客户端兼容；VS Code 扩展只是其中
之一。

服务器是编译器自身库之上的一层薄封装：

| 关注点 | 使用的库 |
| --- | --- |
| 词法与词法单元 | `emo_lexer` |
| 语法分析 | `emo_parser`、`emo_ast` |
| 宏展开 | `emo_eval` |
| 诊断与签名 | `emo_check` |
| 清单、注册表、依赖求解 | `emo_pkg` |
| 位置、URI、区间 | `emo_support`、`lsp_util` |

由于复用了编译器的各个阶段，编辑器显示的诊断与 `emo check` 的输出完全一致
——不存在另一套只属于编辑器的分析器，也就不会与编译器产生偏差。宏应用在文件
被检查之前先行展开，与构建的解析缓存展开方式完全一致，因此宏生成的声明
（`@derive_eq` 的 `eq?`、memoize 的包装器）对编辑器诊断可见，引用它们的调用点
不会被误报为错误。

## VS Code 扩展

扩展位于 [`editors/vscode`](../../editors/vscode)。它包含 TextMate 语法
（语法高亮）、语言配置、代码片段和一个精简的 LSP 客户端。

```sh
cd editors/vscode
npm install
npm run build                  # 将客户端打包为 out/extension.js
bash scripts/install-server.sh # 放置 emo-lsp 与标准库注册表
npx @vscode/vsce package       # 产出 emo-tools-lsp-0.2.2.vsix
```

用 `code --install-extension emo-tools-lsp-0.2.2.vsix` 安装产出的 `.vsix`，
或在扩展视图的 *Install from VSIX* 中安装。

客户端按以下顺序查找服务器：

1. `emo.serverPath` 设置；
2. 扩展内置的 `server/emo-lsp`；
3. `PATH` 上的 `emo-lsp`。

包补全与依赖求解所用的注册表依次取 `emo.registry`、`EMO_REGISTRY`，最后是
内置的 `server/registry`。标准库包不需要其中任何一个：它随服务器二进制本身
分发，编辑器会把已 pin 的包取到共享包缓存——与一次构建所取的内容寻址目录是
同一个——因此 `require "json"` 之类无需任何额外配置即可解析。带 scope 的包从
文件系统注册表解析，或在构建取回之后从构建缓存解析；编辑器从不等待网络。

## Neovim 插件

插件位于 [`editors/neovim`](../../editors/neovim)。它是一个普通的 Neovim 包
——一个 Vim 语法文件、一个缩进表达式和一个小巧的 LSP 客户端——需要 Neovim
0.11 或更新版本，因为用到了 `vim.lsp.config` 与 `vim.lsp.enable`。

```sh
editors/neovim/scripts/build-server.sh   # 在本代码树中构建 emo-lsp
```

把插件目录加入 runtimepath，并按需配置：

```lua
vim.opt.runtimepath:prepend('/path/to/emo/editors/neovim')
require('emo').setup({
  server_path = '/path/to/emo-lsp',
  emo_path = '/path/to/emo',
  registry = '/path/to/emo/stdlib/registry',
})
```

服务器依次从 `server_path`、`PATH` 上的 `emo-lsp`、Emo 代码树内的构建产物中
查找。注册表依次取 `registry`、`EMO_REGISTRY`；`:Emo*` 命令背后的 `emo` CLI
依次取 `emo_path`、`EMO_BIN`。`:checkhealth emo` 会报告实际解析到的结果。

插入补全走 Neovim 自带的 `vim.lsp.completion`：服务器的触发字符——`os.` 的
点与 `require "..."` 里的引号——打开菜单，继续输入即收窄（`os.getp` 只剩
`getpid` 与 `getppid`），`<C-x><C-o>` 可手动补全。`completion` 选项用于把
服务器交给补全插件接管。

命令与扩展一一对应——`:EmoRestart`、`:EmoCheck`、`:EmoBuild`、`:EmoRun`、
`:EmoDepsResolve`、`:EmoDepsList`、`:EmoDepsUpdate`、`:EmoPackageInit`。
完整列表与选项表见
[`editors/neovim/README.md`](../../editors/neovim/README.md)。

## 功能

- **语法高亮。** TextMate 语法（VS Code）或 Vim 语法文件（Neovim）覆盖
  关键字、声明、字符串插值、以 `?` 结尾的谓词名以及语言的命名约定。服务器
  另外发送语义词法单元，使用户自定义的类、枚举、接口、函数与参数着色一致。
- **代码补全。** 关键字、内建类型与函数、当前文件与项目中的声明、`.` 之后的
  成员（类的字段与方法、函数组成员、模块成员），以及 `require "..."` 中的包名。
  语言自身类型也有成员补全——`String.`、`Bytes.`、`Array.` 等会列出 checker
  应答的方法面，字面量接收者（`"abc".`）与声明类型属于这些类型的值同样适用。
- **诊断。** 词法、语法与类型检查错误，另含“每个 `require`——标准库或带 scope 的
  ——都必须在 `package.emo` 的 `deps` 中有对应项”（E5006）以及“不带 scope 的
  `require` 必须命名一个已发布的标准库包”（E5009）的检查。配对错误附带一个快速修复，用于补上依赖。
  任何包之外的缓冲区——即服务器拿到的根下没有 `package.emo`——这些诊断一条都不给：
  那里不索引任何项目，并且有一条消息说明原因，而不是让沉默无从解释。
- **悬停与跳转定义。** 显示签名，支持跨模块跳转。悬停展示声明的完整签名
  ——参数名与类型、返回类型——并附声明上方紧邻的 `//` 文档注释，可跳转到
  声明所在文件。语言自身的表面同样应答：裸内建函数（`println`）、能力类型
  （`Bytes`）、按类型拼写的内建方法（`Bytes.get_u32_le`），以及内建类型值上的方法。
- **文档与工作区符号。** 文件大纲与项目范围的符号搜索。
- **包管理。** *Emo Packages* 视图列出清单依赖、锁定版本与注册表中可用的
  版本；相关命令封装了 `emo deps resolve` / `update` / `list`、`emo check`、
  `emo build` 与 `emo run`。

## 协议扩展

除标准方法外，服务器还实现了扩展包视图所需的两个 Emo 专有方法：

- `emo/packageInfo`——请求。接受 `{ "root": string }`，返回解析后的清单
  （名称、版本、目标、依赖）、每个依赖在 `package.lock` 中的锁定版本与校验
  和，以及注册表中可用的版本。
- `workspace/executeCommand`——命令 `emo.deps.resolve`、`emo.deps.update`、
  `emo.deps.list`、`emo.package.init`、`emo.check`、`emo.build` 与
  `emo.run`。每个命令返回 `{ "ok": bool, "code": int, "output": string }`。

## 设计说明

- **目录树即模块树。** 只有当交给服务器的根放着 `package.emo` 时，它才索引
  该项目——那个根就是编译器会占据的根，也就是你站的地方，绝不会是它猜出来的
  某个祖先目录。随后它索引该根之下每个 `.emo` 文件，并跳过自带清单的嵌套
  目录，与编译器发现模块的方式完全一致。没有清单的根不是项目：服务器不为它
  发布任何诊断，并且只说一次原因——`initialize` 时若找不到清单，发一条
  `window/showMessage` 警告；每个不带清单的目录有缓冲区进入时，发一条去重后的
  `window/logMessage`，并指向 `emo.package.init`。
- **未保存的缓冲区优先。** 补全、悬停与诊断使用打开文档的文本；磁盘上的
  项目索引提供其余信息。
- **标准库始终触手可及。** 内置的标准库包随服务器二进制一同携带，其模块树
  会挂进每一个索引——无论是已 pin 的项目，还是散文件拿到的无项目索引。在
  没有任何清单认领的文件里，`os.` 一样补全、`os.getenv` 一样带着参数类型
  悬停。但 pin 仍是构建的唯一入口：缺失依赖的诊断（E5006）照常报告未配对的
  `require` 并附带快速修复，与构建的拒绝方式完全一致。
- **位置基于 UTF-16。** Emo 的区间是 UTF-8 源码中的字节偏移；服务器在每个
  边界处转换，因此非 ASCII 源码（Emo 示例含中文）也能正确映射。
- **客户端是可选的。** 任何 LSP 客户端都能使用 `emo-lsp`；语法高亮位于
  语法文件中，而非服务器。
