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

## 平台：原生 Windows 与 WSL2

emit-OCaml 流水线是 POSIX 绑死的，所以**原生 Windows 不是受支持目标** —— 原因不只是
OCaml，而是运行时链接了什么：

- 产物的链接行写死了 `eio_posix`（`src/emo_cli/emo_cli.ml`），所以构建出的
  程序是 POSIX-only；
- 运行时链接 `unix` 与 `ssl`（OpenSSL bindings），调度器是 Eio 上的 OCaml 5
effects（`src/emo_sched/dune`）。

有一点值得直说：即使有一个 Windows 版 `emo`，它能跑解释器和
`wasm`/`beam`/`typescript` 目标，但 `emo build` 的 native 目标在 Windows 上
不通 —— 因为 OCaml 不便于交叉编译。OCaml 本身支持 Windows，但这是最少被压测的
配置：`Unix` 是子集、包生态偏 POSIX、OCaml 5 的 effects/multicore 运行时在
Windows 上最少被验证。

**WSL2 是受支持的 Windows 路径。** WSL2 是轻量 VM 里的真 Linux 内核，所以 Emo
看到的是普通 Linux：`eio_posix`、`unix`、`ssl`（`libssl-dev`）都能用，
OCaml/opam 按常规安装，Linux 预编译渠道也适用。注意：OCaml/opam 装在 WSL 里，
不要用 Windows 侧的 OCaml；项目放在 Linux 文件系统（`~/…`），不要放
`/mnt/c/…`（跨边界 I/O 慢，会拖垮增量构建）；用 WSL2 而非 WSL1 —— 后者的
syscall 翻译层不适合 OCaml 5 effects 运行时。

原生 Windows 二进制是更晚的事；解除 POSIX 绑定，是可移植运行时（`c` 后端，或
专门的移植）必须处理的一部分。

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

## 更新（2026-10-07）：发布工具链已排期并落地（步骤 25）

上文的推迟维持到 `c` 后端交付（步骤 24）为止；M9 — 工具链
（`plan/step-25-toolchain.md`）现在把本文档留白未排期的部分排上了：

- **tag 触发的发布工作流**（`.github/workflows/release.yml`）在四个
  平台构建发布二进制——Linux x86_64/aarch64（Ubuntu 22.04，受支持的
  最旧 glibc：2.35）与 macOS x86_64/arm64——对发布构建跑测试套件，
  并经 `devtools/package-release.sh` 打包：二进制加许可文件，仅此
  而已，因为标准库已随二进制内嵌。Linux 归档在干净的 `ubuntu:22.04`
  容器中验证，而非构建机上。GitHub Release 草稿附带 `SHA256SUMS`。
- **macOS 签名与公证在本地完成。** 托管 runner 上没有 Developer ID
  私钥，因此 `release.yml` 按设计先产出未签名草稿；随后
  `devtools/notarize-release.sh`（`just notarize <tag>`）用钥匙串里的
  Developer ID Application 身份签名——hardened runtime、带时间戳——
  经 notarytool 提交（钥匙串 profile、App Store Connect API 密钥
  三件套或 Apple ID 凭据任选其一），回传归档并刷新 `SHA256SUMS`。
  裸可执行文件无法承载 staple（stapler 只把票据嵌进
  .app/.dmg/.pkg），因此 Gatekeeper 在首次运行时在线校验公证
  票据。
- **原生 Windows 推迟，阻塞点如实记录。** C 运行时的进程是 POSIX
  `ucontext` 纤维、socket 是非阻塞 fd（T24.9/T24.10）；原生 Windows
  移植是把这层调度器与 IO 重建在 Windows 原语之上，预编译渠道等它。
  WSL2 仍是受支持的 Windows 路径，Microsoft Trusted Signing 仍是
  移植落地时的既定签名路线。
- **`emo doctor` 取代了上文的过渡形态**：它是 target 感知的环境
  检查——默认 `c` 目标做 cc 编译并运行的冒烟、ocaml 目标在预编译
  机器上报出需要源码构建安装——退出码只反映真正损坏的部分。
  （2026-10-07 更正：ocaml 行报告的是工具链，从不报告安装形态——
  见下文步骤 26 的更新。）

## 更新（2026-10-07）：target 独立（步骤 26）

步骤 26（`plan/step-26-target-independence.md`）移除了本文档反复
回答的安装形态问题。runtime 独立原则：target 的 runtime 以 target
自己的语言编写、以生成数据的形式随编译器携带、由 target 自己的
工具链在用户机器上编译——宿主只贡献 emitter。具体而言：

- **`emo_runtime.cmxa` 的故事结束了。** ocaml target 的 runtime 如今
  是 `emo_ocaml_runtime.ml`——一个 standalone 文件（值、确定性
  调度器、文件与 socket IO、TLS），以 C runtime 的机制随编译器
  携带。`emo build --target ocaml` 把它与 emitted 的 `main.ml`
  并排写出，调用 target 自己的 `ocamlopt`；不在二进制旁边、也不在
  宿主构建树里查找任何 `.cmxa`，不随包携带任何 `.cmxa`，上文的
  版本核对规则已无对象可核对。
- **ocaml target 在任何安装形态下可用。** 已从 release 布局验证：
  空目录里的孤立 `emo` 二进制，只要 OCaml 工具链在 PATH 上——
  `ocamlfind` 带 runtime 自用的 `unix` 与 `ssl` 包——就能构建
  golden 子集。"源码安装带来 ocaml target"不再是故事；工具链才是。
- **eio 离开链接行。** 过渡计划曾把 `eio_main` 保留为 target 侧
  依赖；移植定型了另一种结果——standalone 调度器就是编译产物
  一直在跑的确定性轮询循环（Unix,无 eio）,因此 runtime 只声明
  `unix`（随编译器附带）与 `ssl`（唯一的 opam 依赖）,缺席时以
  清晰的消息拒绝。
- **`emo doctor` 失去了 installation 行。** "installation:
  source/prebuilt" 的报告删除了——每个 target 的行只报自己的
  工具链，退出码只反映真正损坏的部分。

## 参考

- `CHECK.md` —— "Binary / CLI tool distribution mechanism"。
- `docs/native-backend.md` —— emit-OCaml 流水线与 OCaml 工具链要求。
- `docs/runtime-and-freestanding.md` —— runtime 与 freestanding 之别，以及
  native 产物带的是什么。
- `docs/industrial-software.md` —— FFI 的硬门。
- `plan/step-23-hosted-native-ffi.md` —— `c` 后端评估。
