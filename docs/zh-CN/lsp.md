# Emo 语言服务器

Emo 自带语言服务器协议（LSP）实现 `emo-lsp`，以及一个驱动它的 Visual
Studio Code 扩展。二者共同为 `.emo` 源文件提供语法高亮、补全、诊断、悬停、
导航与包管理。

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
| 诊断与签名 | `emo_check` |
| 清单、注册表、依赖求解 | `emo_pkg` |
| 位置、URI、区间 | `emo_support`、`lsp_util` |

由于复用了编译器的各个阶段，编辑器显示的诊断与 `emo check` 的输出完全一致
——不存在另一套只属于编辑器的分析器，也就不会与编译器产生偏差。

## VS Code 扩展

扩展位于 [`editors/vscode`](../editors/vscode)。它包含 TextMate 语法
（语法高亮）、语言配置、代码片段和一个精简的 LSP 客户端。

```sh
cd editors/vscode
npm install
npm run build                  # 将客户端打包为 out/extension.js
bash scripts/install-server.sh # 放置 emo-lsp 与标准库注册表
npx @vscode/vsce package       # 产出 emo-lsp-0.1.0.vsix
```

用 `code --install-extension emo-lsp-0.1.0.vsix` 安装产出的 `.vsix`，或在
扩展视图的 *Install from VSIX* 中安装。

客户端按以下顺序查找服务器：

1. `emo.serverPath` 设置；
2. 扩展内置的 `server/emo-lsp`；
3. `PATH` 上的 `emo-lsp`。

包补全与依赖求解所用的注册表依次取 `emo.registry`、`EMO_REGISTRY`，最后是
内置的 `server/registry`。

## 功能

- **语法高亮。** TextMate 语法覆盖关键字、声明、字符串插值、以 `?` 结尾的
  谓词名以及语言的命名约定。服务器另外发送语义词法单元，使用户自定义的类、
  枚举、接口、函数与参数着色一致。
- **代码补全。** 关键字、内建类型与函数、当前文件与项目中的声明、`.` 之后的
  成员（类的字段与方法、函数组成员、模块成员），以及 `require "..."` 中的包名。
- **诊断。** 词法、语法与类型检查错误，另含“每个 `require` 都必须在
  `package.emo` 的 `deps` 中有对应项”的检查（E5006）。该错误附带一个快速
  修复，用于补上依赖。
- **悬停与跳转定义。** 显示签名，支持跨模块跳转。
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

- **目录树即模块树。** 服务器以最近的 `package.emo`（否则以客户端的工作区
  根目录）作为项目根，索引其下每个 `.emo` 文件，与编译器发现模块的方式完全
  一致。
- **未保存的缓冲区优先。** 补全、悬停与诊断使用打开文档的文本；磁盘上的
  项目索引提供其余信息。
- **位置基于 UTF-16。** Emo 的区间是 UTF-8 源码中的字节偏移；服务器在每个
  边界处转换，因此非 ASCII 源码（Emo 示例含中文）也能正确映射。
- **客户端是可选的。** 任何 LSP 客户端都能使用 `emo-lsp`；语法高亮位于
  语法文件中，而非服务器。
