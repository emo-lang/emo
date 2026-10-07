# emo 工具链:CLI 的构建与安装

写于 2026-10-07。本文记录已定的事实与随仓库交付的自动化。

## CLI 由 dune 构建,而不是由 c target 构建

`emo`——命令行工具——是 OCaml 写的,而 `c` target 编译的是 *Emo*
源码到 C。编译器因此无法构建自身:整个链路里唯一需要 OCaml 工具链
的一步就是构建 `emo` 本身,而 self-hosting 明确不是目标
([`plan/README.md`](../../plan/README.md))。

所以"用 c target 构建 emo CLI"这件事不存在,这句话的含义恰恰
相反——分工是:

1. **用 dune 构建 `emo`(release profile),仅此一次。** 产物是一个
   自包含的单一二进制:所有后端、以生成数据内嵌的标准库、以及
   C runtime 都在里面。
2. **此后的一切都不再需要 OCaml。** 装好的二进制默认构建路径就是
   `c` target:`emo build` 调用系统 `cc`,仅此而已——一台只有装好
   二进制的机器就能构建 Emo 程序,无需任何 OCaml 工具链。这一点由
   步骤 25 的验收证明(孤二进制在空目录中运行、检查、构建、安装
   依赖、发布),并由 `emo doctor` 按 target 报告。

## justfile 自动化的正是这条链

| Recipe | 作用 |
| --- | --- |
| `just build` | 以 release profile 编译二进制——其余 recipe 共用的唯一制品。 |
| `just install [PREFIX]` | c target 安装:独立二进制装入 `~/.local/bin`(默认),原子替换并 strip。可重复执行;用 `emo doctor` 验证。 |
| `just install-dev` | 经 opam switch 的源码安装——同时带来 `ocaml` 编译目标的路线。 |
| `just uninstall [PREFIX]` | 移除独立二进制。 |
| `just package` | 把本平台的分发归档装配到 `dist/`——即 `release.yml` 据以起草 GitHub Release 的制品。 |
| `just test` | 全量测试套件。 |

实现中的两个要点:dune 的产物是只读的,所以 install recipe 先拷贝
到 `emo.incoming`、strip、再 `mv` 到位(`mv` 只需要目录的写权限,
这正是重装能工作的原因);`just package` 依赖
`devtools/package-release.sh`,该脚本在进入暂存目录**之前**就把输出
目录解析为绝对路径——否则相对的 `dist` 参数会从暂存目录内解析,
必然失败。

## 参考

- [`docs/toolchain-distribution.md`](toolchain-distribution.md) ——
  分发为何是这个形状(设计记录)。
- [`plan/step-25-toolchain.md`](../../plan/step-25-toolchain.md) ——
  构建它的步骤(M9 — 工具链,以 v0.25.9 发布)。
- [`.github/workflows/release.yml`](../../.github/workflows/release.yml)
  —— 按平台的发布自动化。
