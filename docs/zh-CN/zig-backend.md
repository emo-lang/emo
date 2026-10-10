# Emo 与 Zig 后端 —— 一份评估

写于 2026-10-10。这是一份技术可行性评估,不是已定的设计决策;文中关于
项目状态的描述以写作日期的仓库为准,关于 Zig 版本的描述以 Zig 0.17.0
(2026-10-01 发布)为准。

问题:Emo 要不要长出一个生成 Zig 源码的 codegen 后端——成为解释器、
C、OCaml、TypeScript、wasm、BEAM 之外的第七个目标?

## 结论

**技术上毫无障碍——机制上就是 C 目标的镜像——但今天不值得建。**
Zig 后端能买到、而现有六个目标都买不到的东西只有一样:生成代码层
safe mode 的边界与溢出检查。收益真实,但只是中等规模的开发期收益。
摆在对面的是一个完整后端的工作量,外加一笔永久性的 churn 税:Zig 每次
发布都破坏语言和 std API(写作时九天前发布的 0.17.0 两样又都破了,
其中还有一处静默破坏),1.0 没有日期,incremental compilation 只覆盖
x86_64-linux 且要挂 `--watch`。

Zig *工具链*的大部分价值,有一个便宜一个数量级的拿法:让现有 C 目标
换用 `zig cc` 当编译驱动——交叉编译、musl 静态二进制、Windows 免
MSVC,一行 Zig 都不用生成。建议:把后端方案挂起,写明重新评估的触发
条件;若 Windows 支持或 Linux 静态分发进入计划,单独开一个小步评估
`zig cc`。

## 生成 Zig 要做什么

仓库事实,以写作日期为准:

- **后端形态。**各后端没有共享模块签名,每个都是独立 emitter,在
  `build_file` 里手写分发分支(`src/emo_cli/emo_cli.ml:185-487`)。
  C 目标是 `emo_c.ml`(2,390 行),产出两个工件——`main.c` 和
  `emo_defs.h`;运行时作为生成数据随编译器分发(`emo_c_runtime.c`
  2,737 行加 420 行头文件,由 dune 规则打包进生成的数据模块)。
  Zig 目标一比一镜像:一个 `emo_zig.ml`,加上运行时的 Zig 移植,接上
  一个分发分支、一行 doctor、一个缓存键。
- **构建驱动。**`emo build --target c` 调系统 `cc`(`-O2 -std=c11`,
  emo_cli.ml:323-329);doctor 会先编译并运行一个冒烟程序,才承认默认
  目标健康(emo_cli.ml:1596-1642)。Zig 目标在同一套机制里加一个
  `zig` 存在性检查。
- **FFI 是最顺的部分。**每个 `foreign def` 本来就以裸 `extern` 声明
  发进 `emo_defs.h`(emo_c.ml:2261-2281)——Zig 侧对应裸
  `extern fn ... callconv(.c)` 声明。这恰好躲开了 Zig 侧最凶的动荡:
  `@cImport` 0.16 弃用、0.17 移除,而 Emo 根本不需要它。
- **测试。**新增三处:`test/emo_cli/emo_cli_test.ml` 里与 `c_goldens`
  并排的 `zig_goldens` 列表和 runner(现在挂 23 个 example)、
  `test/emo_project/emo_project_test.ml` 里一个 golden 套件,仅此
  而已——32 个 example 的 `expected.txt` 是共享的。「每个目标逐字节
  复现解释器输出」的家规将延伸到第七个实现。
- **stdlib 面。**包清单按目标设门(`targets = [...]`);五个面向
  原生的包(`os`、`net`、`file`、`http`、`bufio`)今天声明
  `ocaml, c`,Zig 目标会被期待与 `c` 并排——运行时里 33 个
  `os_*`/`net_*`/`file_*` builtin 直呼 libc,届时会经由 extern 声明
  继续直呼。
- **CI。**release 矩阵是四个平台(linux x86_64/aarch64、macos
  x86_64/arm64,release.yml:26-32),每台要装 Zig。

仓库里此前没有任何 Zig 相关计划——仅有的提及是 `docs/numeric-width.md`
里的命名先例引用。

## 逐机制对照

| Emo 机制 | Zig 对应 | 评价 |
| --- | --- | --- |
| 标签值模型 | tagged union(safe mode 自带 tag 与边界检查) | 顺 |
| 永不回收的 arena(产品门) | `std.heap.ArenaAllocator` | 语义天生匹配——显式分配器与只分配不回收的 arena 是同一个想法 |
| `foreign` FFI | 裸 `extern fn` 声明 | 顺;与 `emo_defs.h` 同构,躲开已移除的 `@cImport` |
| C→Emo 回调(macOS shim 是 `.m`) | 带C调用约定的 `export fn` | ABI 层顺,但 zig 编不了 Objective-C——AppKit 路线仍需 clang,「单一工具链」在那里不成立 |
| 异常(`Exception` + data `Map`) | Zig 的 error union 不带 payload | 有摩擦:异常值必须放堆上;将来 `begin`/`catch` 落地时(T12.5,未实现),C 运行时选什么机制——大概率是 `setjmp`/`longjmp`——Zig 后端就得镜像什么 |
| `receive` / fiber 调度(trampoline + receive 标签) | 无现成物(async 已于 0.14 移除) | 中性:手移植 C 运行时的既有机制,同价 |

## 核心两难

**不用 std 的 Zig 后端 = 换了花括号的 C。**稳定性来自把一切运行时
服务留在 Emo 自己的运行时里、经 extern 声明直呼 libc——这正是 C 目标
的做法。Zig 的贡献随之缩水成 safe mode 的边界与溢出检查。这是真的,
也是唯一真正的新东西——但有边界:Emo 的产品门已经把伤害最大的那类
C bug 排除在外——arena 永不回收、裸指针不进用户代码,use-after-free
和多数内存破坏从构造上就不存在。

**用 std 的 Zig 后端 = 追着发布火车跑。**近期的记录:0.16 把全部
I/O 重构到 `std.Io` 接口后面,移除了大部分 `std.posix`,把环境变量和
argv 全部去全局化;0.17 换掉分配器家族(`DebugAllocator` →
`SafeAllocator`)、把 `fmt.allocPrint` 挪进 `mem.Allocator.print`、
overhaul 了 build system 的 API 面,还附带一处静默破坏(`@bitCast`
的语义重定义可以不报编译错地改变行为)。消费 std 的生成器,等于
无限期承诺每半年做一轮全量 golden 回归。

先例指向同一边。emit-C 阵营有几十年深——Nim、V、Nelua、Vala、
Haxe 的 C++ 后端、Cython——其稳定性论证恰恰是 Zig 今天还做不出的
那条。emit-Zig 阵营在生产规模上是空白:Bun、Ghostty、TigerBeetle 是
*用 Zig 写的*;没有任何在产语言生成 Zig 源码。任何规模上做第一个,
坑都得亲自踩。

两个次级顾虑:

1. **incremental compilation 覆盖不了这个场景。**截至 0.17,它只在
   x86_64-linux 上、且只在 `zig build -fincremental --watch` 下可用;
   Mach-O linker 和自研 aarch64 后端仍在路上。其余平台每次 rebuild
   都要重新分析整个生成模块——对「生成大文件、频繁 rebuild」的回路
   很不友好。
2. **定位噪音。**「编译到 Zig」容易被读成「Zig 皮的 DSL」。这与任何
   设计都不冲突——设计哲学管的是 Emo 自己的表面语法,不是底层基座,
   目标独立性也是已定的设计——但这是 C 目标不用付的一笔解释成本。

## 更便宜的替代:zig cc + 现有 C 目标

运行时已在 gcc 和 clang 上验证过 strict C11——事实上它已经在
`zig cc` 下编译过一次,当时正是 strict-C11 CI 失败的复现载体——而
`zig cc` 是 Clang/LLVM 22 前端,稳定面远宽于 Zig 的 std。让现有
C 目标指向它,一行 Zig 都不用生成就能买到:

- 一套工具链覆盖整个 release 矩阵,任意宿主机交叉编译;
- musl 全静态 Linux 二进制,强化「单个二进制」的分发故事;
- Windows 免 MSVC——若 Windows 加入 release 矩阵(今天缺席),
  这是最短路径;
- 可选:把 zig 随发行版捆绑,做成真正零依赖工具链——Bun 走过的路——
  代价约 50 MB 体积。这是改天再做的决定,记在这里只为免得将来重新
  发现一遍。

成本:CLI 里一个编译驱动选项,doctor 一行。顺路要还的一笔债:c 的
缓存键不含编译驱动版本(emo_cli.ml:287-293 只哈希源码、运行时、
cclib 和 emo 二进制自身)——驱动可换之后,驱动版本必须进键,否则
用户升级 zig 后会静默命中旧二进制。

## 建议

1. **挂起 Zig 后端。**现在就把重新评估的触发条件写下来,让门槛
   显式:Zig 1.0 落地,或 language stabilization 完成(0.17 时点仍有
   84 个提案待决);incremental compilation 覆盖到 x86_64-linux 之外;
   或出现一个 C 目标经 zig cc 也满足不了的具体需求。
2. **把 zig cc 作为 C 目标的可选驱动单独小步评估**,连同缓存键修复
   一起——若 Windows 支持或 Linux 静态分发进入计划,尤其如此。
3. **riscv64 维持原计划。**step 22 直接产出汇编文本、用 GNU as/ld
   链接,不经过 Zig;freestanding 值模型已有设计。

## 参考

- Zig 下载与版本历史:<https://ziglang.org/download/>
- Zig 0.17.0 release notes:
  <https://ziglang.org/download/0.17.0/release-notes.html>
- Zig 0.16.0 release notes:
  <https://ziglang.org/download/0.16.0/release-notes.html>
- Zig 新闻(0.17.0 发布公告,2026-10-02):<https://ziglang.org/news/>
