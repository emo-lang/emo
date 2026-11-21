# 适用于 Visual Studio Code 的 Emo 扩展

为 [Emo 编程语言](https://github.com/emo-lang/emo) 提供语言支持：语法高亮、代码补全、
实时诊断、悬停提示、跳转到定义、文档符号、语义标记以及包管理。

## 功能

- **语法高亮** —— 面向 `.emo` 文件的 TextMate 语法，涵盖字符串插值、
  `predicate?` 形式的名称以及这门语言的大小写约定。
- **语义标记** —— 语言服务器在语法着色之上，进一步区分用户定义的类、枚举、
  接口、函数与参数。
- **代码补全** —— 关键字、内建类型与函数、当前文件与项目中的声明、`.` 之后的
  成员（类方法与字段、分组成员、模块成员），以及 `require "..."` 中的包名。
- **诊断** —— 来自编译器的词法、语法与类型错误，覆盖项目的各个模块及其依赖，
  外加作用域包的清单与 `require` 配对错误，随输入实时发布。不带作用域的
  `require "sync"` 无需清单条目即可解析到标准库；`package.emo` 按清单校验，
  而不是当作 Emo 源码检查。
- **悬停与跳转到定义** —— 跨项目模块树（含依赖）的签名展示与声明跳转。
- **文档符号与工作区符号** —— 当前文件的大纲视图，以及全项目的模糊符号搜索。
- **包管理** —— *Emo Packages* 视图、向 `package.emo` 补充缺失依赖的快速修复，
  以及 `emo deps resolve` / `update` / `list`、`emo check`、`emo build`、
  `emo run` 对应的命令。

## 环境要求

扩展驱动的是 `emo-lsp` 语言服务器。该服务器用 OCaml 编写，随 Emo 编译器一同发布。
构建方式：

```sh
dune build bin/emo_lsp_bin.exe
```

然后二选一：把它放入扩展目录，

```sh
cd editors/vscode
bash scripts/install-server.sh   # 复制二进制与标准库 registry
```

或者告诉扩展它在哪里：

```jsonc
{
  "emo.serverPath": "/path/to/emo-lsp",
  "emo.registry": "/path/to/emo/stdlib/registry"
}
```

两者都不配置时，扩展会在 `PATH` 中查找 `emo-lsp`。`emo.registry` 设置面向
registry 包以及针对本地 `stdlib/registry` 目录树的开发；标准库本身已内置于
服务器二进制中，因此 `require "json"` 等写法无需任何额外配置即可解析——
补全、悬停、跳转到定义、诊断均可用。

## 命令

| 命令 | 说明 |
| --- | --- |
| `Emo: Restart Language Server` | 重启语言服务器 |
| `Emo: Resolve Dependencies` | 运行 `emo deps resolve` |
| `Emo: Update Dependency` | 重新固定某个依赖并重新生成 `package.lock` |
| `Emo: List Dependencies` | 运行 `emo deps list` |
| `Emo: Initialize Package Manifest` | 创建 `package.emo` |
| `Emo: Check File` | 运行 `emo check` |
| `Emo: Build` | 运行 `emo build` |
| `Emo: Run` | 运行 `emo run` |

## 设置

| 设置项 | 默认值 | 说明 |
| --- | --- | --- |
| `emo.serverPath` | `""` | `emo-lsp` 可执行文件路径 |
| `emo.emoPath` | `"emo"` | `emo` CLI 路径 |
| `emo.registry` | `""` | Registry 端点（默认取 `EMO_REGISTRY`） |
| `emo.trace.server` | `"off"` | LSP 跟踪级别 |

## 打包

```sh
cd editors/vscode
bash scripts/build-vsix.sh            # → emo-tools-lsp-<version>.vsix
bash scripts/build-vsix.sh --out /tmp/emo.vsix
```

脚本会构建 `emo-lsp` 并连同标准库 registry 一起放入扩展目录，打包扩展源码，
再用 `vsce` 生成安装包。安装产物：

```sh
code --install-extension emo-tools-lsp-<version>.vsix
```

## 开发

```sh
cd editors/vscode
npm install
npm run build          # 将 src/extension.ts 打包为 out/extension.js
bash scripts/install-server.sh
```

在 VS Code 中按 <kbd>F5</kbd> 启动扩展开发宿主。

`server/registry` 如何从 `stdlib/registry` 同步、以及何时需要重新同步，
见 [REGISTRY_SYNC.md](../../../../editors/vscode/REGISTRY_SYNC.md)（英文）。

## 许可证

MIT —— 见仓库的 [LICENSE](https://github.com/emo-lang/emo/blob/main/LICENSE)
