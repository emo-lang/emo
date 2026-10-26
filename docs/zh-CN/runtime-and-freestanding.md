# 运行时与独立环境 —— 两个词,两个维度

Emo 的文档里反复出现"freestanding""runtime""host runtime"——`riscv64`
目标、`ocaml` 与 `c` 后端。它们说的是两件不同的事:
**freestanding 描述程序跑在什么环境里;runtime 描述运行时支撑它的那层
代码。** 本文把两者钉死,并映射到 Emo 的各个目标。

## Freestanding(独立环境)

这个词来自 C/C++ 标准,它把执行环境分成两种:

| | Hosted(宿主环境) | Freestanding(独立环境) |
| --- | --- | --- |
| 操作系统 | 有 | 无,或仅有极简的固件层 |
| 标准库 | 完整的 C 库(stdio、stdlib、string、文件、线程……) | 只有编译器自身需要的那一小撮(`stddef.h`、`stdint.h`、`limits.h`、`stdarg.h`、`stdbool.h`……) |
| 入口 | 标准 `main`,返回给操作系统 | 由实现自定义(`_start`、boot 桩) |
| 内存 | libc 提供的 `malloc` 等 | 分配器由你自己提供 |
| I/O | `printf`、`fopen`、socket…… | 自己提供(MMIO 寄存器,或固件调用) |
| 编译器开关 | 默认 | `-ffreestanding` |

Freestanding 的意思是**没有 OS、没有标准库:地基自己搭**。它是内核、
嵌入式、固件、bootloader、裸机实时代码所处的环境。

它并不完全等同于"bare metal"。Emo 的 `riscv64` 目标有两个启动 profile:
profile A(默认)由 OpenSBI 托管、跑在 S-mode,存在固件层但没有 OS 和
libc;profile B(`-bios none`、M-mode、自带 UART 驱动)才是真裸机。相对
操作系统与 C 库,两者都是 freestanding——区别只在于下面垫不垫一层固件。

在 Emo 里(`plan/step-19-riscv64.md`),`riscv64` 就是那个 freestanding
目标:无 OS、无 libc、无默认运行时;分配器、GC、调度器是可替换组件;
`core` 是 kernel 代码唯一可用的库层;`peek`/`poke` 是显式危险的访存
原语。它的 `println` 不调用 libc——而是发一个 SBI `ecall` 到固件的
控制台。

这份可替换性自 EmoOS T3.1(2026-10-26)起落到实处:包可以携带自己的
freestanding runtime——一个 `runtime.S` boot stub 和一个 `link.ld`
链接脚本,与其它原生源码一样从包树里收集——镜像即归包所有:入口纪律
与内存布局是包的,编译器的 runtime 主体(生成代码所调用的分配器与值
机器)仍在其下。普通程序依旧使用默认的 stub 与脚本。内核包拥有自己的
镜像。

## Runtime(运行时)

一门语言的 **runtime** 是程序运行时支撑它的代码与数据结构——编译器
默认它们已经存在、并会调用它们。它不是用户写的逻辑,而是让那份逻辑
能跑起来的机器。视语言不同,它包含以下的一部分:

- **内存管理** —— 分配器、垃圾回收器;
- **值表示** —— 装箱/拆箱、类型标签检查、字符串操作;
- **派发** —— 方法表与 vtable、动态类型判断;
- **并发** —— 调度器、线程或进程、mailbox;
- **异常** —— 抛出与展开;
- **算术辅助** —— 大整数、溢出检查;
- **启动与收尾** —— 入口、初始化、退出;
- **与 OS 的交互** —— 常与标准库重叠。

编译器与运行时的关系:编译器把源码翻成机器码;runtime 被链进产物、
与它一起运行。标准库与运行时的界限更模糊——`println` 是标准库的**接口**,
它背后依赖的调度器与回收器才是 **runtime**。标准库是用户看到的面,
runtime 是面下面的机器。

"runtime" 还有几个需要区分开的意思:

1. **语言运行时** —— 上文这个意思。
2. **host runtime(宿主运行时)** —— 实现**借来的**宿主语言的运行时。
   Emo 的 `ocaml` 后端发射 OCaml 并链接 **OCaml 运行时**,
   所以每个 Emo 二进制都背着 OCaml 的回收器和值模型;那就是 host
   runtime。
3. **云/执行环境意义的 runtime** —— "Lambda runtime""JVM runtime":
   程序被运行的环境,而不是语言自身的机器。
4. **runtime 与 compile time** —— 运行时错误 vs 编译期错误,运行时
   类型 vs 静态类型。这是另一个维度。

在参考实现里,编译器自身的 runtime 层——解释器运行所依赖的那层——
是 `src/emo_eval`(求值器)、`src/emo_runtime`(native 的装箱、标准库的运行时实现、
派发辅助)与 `src/emo_sched`(进程调度器)。**目标**的 runtime 是
另一回事:runtime 独立性原则(2026-10-07)要求它用目标语言书写、
以生成数据的形式随编译器携带、并由目标自己的工具链编译——`c` 携带
`src/emo_codegen/c/emo_c_runtime.c`,`ocaml` 携带
`src/emo_codegen/ocaml/emo_ocaml_runtime.ml`,`typescript` 与
`browser` 携带 `src/emo_codegen/ts/ts_core.ts` 再加一个 host 文件
(分别是 `ts_node.ts` 与 `ts_browser.ts`,拼接在 core 之后),而
`wasm`/`beam` 的 runtime 就在
发射出的模块里。（`ocaml` 那个文件是调度器与运行时实现;它脚下的回收器与
值模型仍是 OCaml 的——即上文第 2 点的 borrowed host runtime。）
这正是 README 说的"随二进制一起发布":编译产物
自带运行时,既没有解释器也没有运行时下载。freestanding 目标
**没有 host runtime**——它自带,含自己的分配器(step-19 的 bump
分配器,"GC deferred")。

为什么 runtime 对 GC、FFI 与 HPC 的讨论至关重要:runtime 掌管**值表示、
内存管理与调度**。"无 GC"与"无缝 C FFI",底层都是在重写这一层——
值怎么摆(装箱、打标签、地址稳定)、内存谁回收(追踪 GC、引用计数、
arena)、C 怎么进来(ABI、根扫描问题)。这正是 `c` 后端的成本落在
runtime 而非代码生成上的原因。

## 两个维度,套到 Emo 上

把两个维度交叉,各个目标的名字就说清楚了:

| | 借用 host runtime | 自持 runtime |
| --- | --- | --- |
| **Hosted(宿主环境)** | `ocaml` 后端(发射 OCaml,链接 OCaml 运行时) | `c` 后端(发射 C,自持 runtime;步骤 23) |
| **Freestanding(独立环境)** | ——(无意义的组合) | `riscv64` 目标(`plan/step-19-riscv64.md`) |

这样读来,"freestanding 目标"与"自持 runtime"说的是两个不同的维度:
前者是镜像启动进入的环境,后者是承载程序的机器归谁所有。

## 参考资料

- [`docs/zh-CN/ocaml-backend.md`](ocaml-backend.md) —— 发射 OCaml 的后端、
  它的 OCaml 发射与 C FFI。
- [`docs/zh-CN/c-backend.md`](c-backend.md) —— C 后端、它自持的 runtime,
  以及包自带原生代码。
- `plan/step-19-riscv64.md` —— freestanding 目标、它的值模型与启动
  profile。
- `plan/hosted-native-ffi.md` —— `c` 后端评估。
- `README.md` 的 "Native Builds" —— runtime 随二进制发布的表述。
