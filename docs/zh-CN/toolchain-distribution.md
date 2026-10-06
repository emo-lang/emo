# 工具链分发

写于 2026-10-06。记录已定的方向及其理由；文中关于项目状态的描述以写作
日期的仓库为准。

问题：当 `emo build` 用用户自己的 OCaml 工具链编译产出的 OCaml 时，Emo
工具链要如何以一个可用的二进制形式分发？

## 一个"问题"，其实是三个

二进制分发通常被当成一件事来谈。但 `emo build` 的流水线 ——

```
parse → check → lower → specialize → emit OCaml → ocamlfind ocamlopt → binary
```

—— 有三个可分离的依赖，而它们的答案并不相同：

| 目标 | 今天的要求 | 由什么消除 |
| --- | --- | --- |
| 运行工具（`emo run`/`repl`、`wasm`/`beam`/`typescript` 构建） | 一个自包含的 `emo` 可执行文件 | 已满足 —— `ocamlopt` 会把 OCaml runtime 链进 native 可执行文件 |
| 用 `emo build` 构建 native 程序 | 用户机上有 `ocamlfind` + `ocamlopt`、Emo 运行时 `.cmxa`、OCaml stdlib 头文件 | 只有 `c` 后端（或直接的机器码后端） |
| 产物自包含 | 产物里已经带上 OCaml runtime 与 Emo runtime | 把剩下的 C 依赖（libc、OpenSSL）静态链接，且要按平台处理 |

`CHECK.md` 里的分发决定针对的是**第二行**：把 OCaml 工具链依赖从**工具**
身上去掉。静态链接 emit-OCaml 的产物碰不到它 —— 这个依赖在**构建期**，
不在运行期，所以产物变大在这里毫无帮助。真正把 `ocamlfind ocamlopt` 换成
`cc` 的是 `c` 后端；它不消除 `cc`，只是把门槛降低。

## 已定的方向

- **`c` 后端推迟到 1.0 之后。** 在它落地前，emit-OCaml 后端保留，`emo
  build`（native/`ocaml` 目标）需要用户自己的 OCaml 工具链。这一点要**写
  进文档，而不是藏起来**。
- **现在就把工具发出去。** native `emo` 二进制本来就带 OCaml runtime，所以
  对 `emo run`/`repl` 以及 wasm/beam/typescript 目标的分发今天就不需要外部
  工具链。
- **是"检测 + 引导"，不是下载器。** 一个工具链检查（`emo doctor`）负责：检
  测 `ocamlfind`/`ocamlopt`；把版本与二进制旁边随发的 `emo_runtime.cmxa`
  对照；在缺失或不匹配时，打印当前平台的安装命令 —— `brew install ocaml
  opam && opam install ocamlfind`、`apt install ocaml ocaml-findlib`，或项
  目自带的 setup 脚本。经用户同意后，它可以代跑系统包管理器。**它自己不下载
  OCaml。**
- **通过生态来供给。** 把 Emo 发布为 opam 包和 Homebrew formula；
  `opam install emo` 会带来匹配的 OCaml、`ocamlfind` 与 runtime，版本关系由
  包管理器保证。`CHECK.md` 已经把 `opam` 与 Homebrew 列为源码构建渠道。
- **版本匹配是硬要求。** 用户的 `ocamlopt` 必须与工具随发的
  `emo_runtime.cmxa` 一致；`emo doctor` 要把"版本不匹配"变成一句清楚的话，
  而不是原始的、工具链报错。

## 已否决：自助下载工具链

曾考虑一个 `emo toolchain download` 命令去抓取并安装 OCaml，已否决：

- 它会让 Emo 变成一个残缺的包管理器、以及一整个编译器的再分发者 ——
  per-platform 构建、签名、校验和、供应链信任，全变成项目的责任。
- OCaml 没有每个平台统一的官方预编译二进制，`ocamlfind` 是单独的包，而
  Windows 上的原生 OCaml 很别扭 —— 恰恰是最想要"自动安装"的地方最难。
- 下载物必须与随发的 `.cmxa` 保持版本匹配，于是下载器和工具被耦合在一起。
- 它是一块会被 `c` 后端淘汰的子系统，而删掉一个"下载工具链"命令会伤害已经
  用了它的用户。检测则没有这种锁定。

如果将来真要做下载器，它必须 pinned + checksum —— 绝不能 `curl | sh` ——
并标注为临时设施。

## `c` 后端不只是为了分发

把它推迟到 1.0 之后是一个排期选择，不等于"分发是它唯一的目的"。同一个后端
还是通向这些的路：无 OCaml 的 native 构建、产物不带 OCaml runtime、真正的
C FFI（指针、结构体、数组、回调 —— `docs/industrial-software.md` 里的硬
门）、以及 HPC 代码生成（vectorization、OpenMP pragma）。这些时间线与分发
相互独立。

## 参考

- `CHECK.md` —— "Binary / CLI tool distribution mechanism"。
- `docs/native-backend.md` —— emit-OCaml 流水线与 OCaml 工具链要求。
- `docs/runtime-and-freestanding.md` —— runtime 与 freestanding 之别，以及
  native 产物带的是什么。
- `docs/industrial-software.md` —— FFI 的硬门。
- `plan/step-23-hosted-native-ffi.md` —— `c` 后端评估。
