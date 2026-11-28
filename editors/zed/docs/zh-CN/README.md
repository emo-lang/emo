# Emo for Zed

[Emo](https://github.com/emo-lang/emo) 编程语言的 Zed 编辑器扩展。

## 功能

- 以 Emo 语言打开 `.emo` 文件。
- 基于 tree-sitter 的语法高亮：关键字、声明、带 `${}` 插值的字符串、数字、
  字节字面量与字符字面量、注释，以及 `//#` / `//@` 指令。
- 括号匹配、自动闭合、缩进、文档大纲和文本对象。
- Emo 缓冲区自动启动 Emo 语言服务器（`emo-lsp`）。
- 可通过 Zed 的 `lsp` 设置覆盖服务器路径与参数。

## 环境要求

- Zed，扩展 API 版本 0.7.0 或更新。
- 带 `wasm32-wasip1` target 的 Rust 工具链。target 缺失时 Zed 会通过
  `rustup` 安装。
- 仅在重新生成 tree-sitter 解析器时需要 Node.js。

## 作为开发扩展安装

Zed 只会从 git 仓库获取扩展语法；它无法直接读取扩展目录中的语法源码。
因此本目录把语法源码放在 `grammars/tree-sitter-emo`，并提供一个脚本将其
快照到本地裸仓库 `.grammar/emo.git`：

```sh
./scripts/prepare-grammar-repo.sh
```

然后在 Zed 命令面板运行 `zed: install dev extension`，选择本目录
（`editors/zed`）。Zed 会构建 Rust 扩展、从 `.grammar/emo.git` 克隆语法并
编译为 WASM。

本地语法仓库只是开发便利，已被 git 忽略。发布扩展时，请把语法推送到
git 托管平台（或在 Emo 单仓库中使用 `extension.toml` 的 `path` 条目），
并把 `extension.toml` 里的 `[grammars.emo]` 换成对应仓库与版本。

## 配置语言服务器

扩展启动 `emo-lsp` 的默认路径是：

```
/Users/daqing/mzevo/open-source/emo-lang/emo/editors/vscode/server/emo-lsp
```

要使用其他二进制，在 Zed 的 `settings.json` 中设置
`lsp.emo-lsp.binary`：

```json
{
  "lsp": {
    "emo-lsp": {
      "binary": {
        "path": "/path/to/emo-lsp",
        "arguments": [],
        "env": {}
      }
    }
  }
}
```

`path`、`arguments` 和 `env` 都是可选的。省略的字段保持默认值：`path`
使用内置路径，`arguments` 与 `env` 为空。

## 重新生成解析器

修改 `grammars/tree-sitter-emo/grammar.js` 后：

```sh
cd grammars/tree-sitter-emo
npx --yes tree-sitter-cli@0.25.10 generate
cd ../..
./scripts/prepare-grammar-repo.sh
```

生成的解析器使用 tree-sitter ABI 14。语法已针对 Emo 仓库的 examples、
stdlib 和 test 语料验证，可以无错误解析。

## 目录结构

```
extension.toml              Zed 扩展清单
Cargo.toml / src/lib.rs     语言服务器注册
languages/emo/              语言配置与 tree-sitter 查询
grammars/tree-sitter-emo/   语法源码与生成的解析器
scripts/                    本地语法仓库初始化
```
