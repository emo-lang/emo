# Emo 在单片机（ESP32）上 — 可行性评估

写于 2026-11-12。这是一份技术可行性评估，不是既定设计。标注
**实测** 的数字来自该日仓库源码（宿主机：Apple Silicon，`cc -O2`）；
表格里 ESP32 一侧的数字全部是外推，均有标注。姊妹篇是
[rtos-assessment.md](rtos-assessment.md)（RTOS 视角）；路径 B 所依赖
的自由站立执行模型见
[runtime-and-freestanding.md](runtime-and-freestanding.md)。

问题：Emo 程序能不能跑在单片机上——具体说是 ESP32 系列——成本
多大、能交付什么？

## 结论

可行，但不是「今天就能跑」。**c target 是上 ESP32 的最短路径**，
需要一次有边界的移植工程（四个拦路点，数周量级而非数月）。性能对
控制面负载够用，对数据面偏紧。**真正的约束是内存，不是代码体积。**
另有一条侧线——自由站立 riscv64 后端上 64 位 RISC-V MCU；一条零
运行时工作的候选——beam 目标骑 AtomVM；还有一条死路：wasm。

## 实测数据

宿主编译，arm64，`cc -O2`，2026-11-12：

| 项目 | 实测值 | 说明 |
| --- | --- | --- |
| 运行时全部代码 text（`emo_c_runtime.c` 单文件） | **64,790 B** | 含调度器、纤程、net、os、字符串、Map 全部 |
| hello world 生成程序体 | **114 B** | `examples/hello_world/.emo-build/main.c` |
| 1000 万次循环生成程序体 | **128 B** | `benchmarks/plain_loop/.emo-build/main.c` |
| 箱装 `Int64` cell | 24 B + malloc 开销 | `[rc][header][payload]`，step 49 起每 cell 独立 `malloc` |
| 纤程栈 | **8 MiB 常量** | `emo_spawn_process` 对齐宿主 OS 默认值 |
| bump arena chunk 下限 | 64 KiB | `emo_alloc`；chunk 从不回收（见下） |

程序代码相对运行时可忽略：hello world 带上 64 KB 运行时加 libc
片段，flash 预算 100–200 KB——4 MB flash 无压力，S3 的双 OTA
分区布局也放得下。

性能前提是在生成代码里验证的，不是推断的：**typed 热循环降为去箱
化的原生 `int64_t` 局部变量 + 标签跳转循环，逐步零分配**
（`benchmarks/plain_loop/.emo-build/main.c`）。2026-11-09 的基准表
（`benchmarks/results.md`）中循环一行已在 2026-11-12 复核（用户态
0.03 s，与记录的 27 ms 一致）。

## 路径 A — c target 上 ESP32（最短；推荐）

`emo build --target c` 生成一个 `main.c` 伴一份 `emo_c_runtime.c`
拷贝，用系统 `cc` 链接。生成的 C 平实可移植；距离 ESP-IDF 构建有
四个拦路点，均已定位到源码：

1. **LP64 假设。** `emo_value` 是单个 `uintptr_t`——这一半在 32 位
   下成立，因为直接量（Bool/Char/Byte）装得进 32 位的 tag 方案。
   不成立的是：`emo_unbox_i64` 用**单个** payload word 装整个
   `Int64`，且 `emo_cell` 的引用计数是 `int64_t`——32 位构建会截断
   箱装标量。修法收在运行时单文件内：payload 槽统一加宽到 8 字节
   （两侧统一槽宽），几十处；生成代码不用动，因为 typed 位置只经
   box/unbox 调用跨入动态世界。
2. **纤程栈常量。** 每个 Emo 进程分到 8 MiB malloc 栈——宿主 OS 上
   合理，520 KB 芯片上致命。必须改为可配尺寸（16–64 KiB 量级），
   并像现在的注释那样把递归深度后果大声说出来。
3. **ucontext。** Xtensa 没有 `makecontext`/`swapcontext` 实现，纤程
   切换要手写（callee-saved 寄存器 + `sp` + `pc`，FPU 可选——每个
   ISA 约百行汇编；RV32 也可借 libucontext）。友好的一半：调度器是
   **纯协作式**——运行时里没有任何 pthread、定时器、信号驱动的
   抢占——没有东西跟 RTOS 抢 CPU。
4. **POSIX 面。** `poll`、socket、`dirent`、stdio 都能映射到 ESP-IDF
   （LWIP + newlib + VFS）。`fork`/`exec`/信号/环境变量在那里不
   存在——但运行时已经自带诚实降级门 `emo_unsupported()`，且 os
   模块的失败是值（`(R.ok, ...)` / `(R.error, reason)`），不支持的
   系统调用可以按数据应答，而不是弄断构建。TLS 在宿主 profile 骑
   OpenSSL；ESP32 上先放下（日后 mbedTLS，或干脆不编 TLS）。

第五项由内存而非工具链逼出来：**bump arena 从不回收**。
`emo_alloc` 的 chunk 永不 free，`emo_arena_bytes` 只增；typed 渲染
循环能保持平坦是因为 step 49 让 cell 逐个 malloc，但 native 暂存
路径——FFI cstr 拷贝、os 读缓冲、`map_keys`/`map_values` 数组、
printf 渲染——每次调用都永久吃掉 arena。宿主 64 位上还能忍；
320–512 KB SRAM 芯片上的长跑服务会一路漏到死。chunk 下限（64 KiB）
也要缩。这一条同样值得记到宿主轨道上：它是长跑宿主服务的既有隐患，
不只是 MCU 移植项。

## 路径 B — riscv64 后端上 RV64 MCU（最「Emo」的路线）

riscv64 target 本来就是裸机设计：单个自由站立静态 ELF、固定 `.bss`
区域上的 bump 分配器、**无 malloc、无 libc、无 POSIX**，64 位
tagged word 在 RV64 上原生。到真芯片的距离只在 boot profile：现在
假设 OpenSBI S-mode 入口加 SBI ecall 控制台
（`qemu-system-riscv64 -machine virt`）。第二个 boot profile——
M-mode 入口、UART MMIO 控制台、该芯片的 linker script——就能落上
真件。最近的芯片是 Kendryte K210（双 RV64 @ 400 MHz、8 MB SRAM、
无 S-mode，因此内核线的 satp EmoOS profile 跑不了——要跑的是裸
用户 profile 运行时）。

ESP32 完全走不了这条：C3、C6、P4 都是 RV32，而 64 位 tagged word
模型要 64 位字——RV32 移植等于后端重写（值住寄存器对），不是移植。
不建议。

## 路径 C — wasm 上单片机（死路）

wasm target 生成的是 **WasmGC**（`anyref`、按类 struct 类型、
`ref.test`/`ref.cast`）。真正能跑在 MCU 上的 wasm 引擎（Wasm3、
WAMR）都只实现 core wasm；没有一家支持 GC 提案。要让 wasm 路径在
那里成立，得为整个值模型再做一份线性内存 lowering——比路径 A 还
贵，且没有额外回报。不建议。

## 路径 D — beam 骑 AtomVM（零运行时工作；一个开放问题）

AtomVM 官方支持在 ESP32 上跑 BEAM 子集。Emo 的 beam target 为
`erlc` 生成 Core Erlang，管线形状对得上，send/receive/Pid 进程模型
正好落在 AtomVM 的甜区。开放问题是覆盖面：发射器的语法事实钉在
OTP 29 reader 上，而 AtomVM 支持的 OTP/BIF 面更窄更老。探针很便宜
——AtomVM 也有宿主版——应在押注路径 A 或 D 之前先花掉。

## 性能

**实测**（`benchmarks/results.md`，记录于 2026-11-09；循环一行
2026-11-12 复核），Apple Silicon、`cc -O2`：

| 负载 | 宿主实测 | c target 实测 |
| --- | --- | --- |
| 1000 万次循环 | 27–37 ms | 27 ms |
| fib(30) | 18 ms（specialized）/ 29 ms（unspecialized） | 26 ms |
| bytes get × 2000 万 | 1138 ms（dynamic） | 138 ms |
| fib(30)，解释器（`emo run`） | 980 ms | — |

**外推到 ESP32-S3 @ 240 MHz**（顺序执行 Xtensa LX7；按主频折算再
乘 2–3× IPC 因子；中等置信度——未用 xtensa 工具链、未上真板）：

| 负载 | 外推 |
| --- | --- |
| 1000 万次循环 | ~0.4–0.8 s |
| fib(30) | ~0.2–0.5 s |
| fib(30)，解释器路径 | ~5–10 s（只适合配置/胶水） |

时间特性：协作调度加逐 cell 引用计数意味着**没有 GC 暂停**，抖动
是语句级的——兼容软实时任务逻辑。硬 µs 级 ISR 仍留在 C；Emo 在它
上面一层（任务、状态机、协议）。

## 芯片与路径对照

| 芯片 | 形态 | 可行路线 |
| --- | --- | --- |
| ESP32 / S2 / S3 | Xtensa LX6/LX7，1–2 核，320–512 KB SRAM（S3 带 PSRAM），S3 有 FPU | 路径 A（移植完成后） |
| ESP32-C3 / C6 | RV32IM(C) @ 160 MHz，400–512 KB SRAM，无 FPU，无原生原子指令（64 位原子靠锁模拟） | 路径 A（移植完成后） |
| ESP32-P4 | RV32 ×2 @ 400 MHz，768 KB SRAM（+PSRAM），FPU，无射频 | 32 位工作落地后最有吸引力的 ESP32 靶子 |
| K210（对照） | RV64 ×2 @ 400 MHz，8 MB SRAM，仅 M-mode | 路径 B——现成后端，工作量最小 |

## 移植清单（路径 A，按序）

1. cell payload 槽 32 位加宽（LP64 修复，收在 `emo_c_runtime.c`
   单文件内）。
2. 纤程栈尺寸可配；手写 Xtensa 上下文切换（RV32 部分也可借
   libucontext）。
3. 缩小 arena chunk 下限并加 chunk 回收。
4. os/net 面映射到 ESP-IDF（LWIP `poll`、VFS stdio），其余经
   `emo_unsupported` / `(R.error, reason)` 降级。
5. 给 CLI 加 `--cc`/sysroot 透传（今天硬编码系统 `cc`；
   `.emo-build/` 里两个文件也可手动编译）。
6. `app_main` shim 替代 `main()`。
7. 后置：`rand` 换硬件 RNG（`esp_random`——严格优于
   `getentropy`），TLS 换 mbedTLS。

## 建议

1. 要「Emo 上 ESP32」的故事：**ESP32-S3 + 路径 A**。第一个里程碑：
   hello world、两个协作进程、一行 UART。
2. 要 EmoOS 叙事里最省事的活：**K210 + 路径 B boot profile**——与
   OS 工作同一代码谱系，无 malloc、固定堆。
3. 押注之前先花半天做 **AtomVM 探针**；这是整个问题里最便宜的信息。
4. C3/C6/P4 都在等 32 位工作；之后 P4 是头奖。
5. 无论哪条路胜出，都先把 arena 回收在宿主轨道修掉——它既是移植
   前置项，也是长跑宿主服务的既有隐患。

## 验证说明

「实测」各行均来自 2026-11-12 用宿主 `cc` 编译本仓库运行时与生成
程序的结果。未使用任何 ESP32 或 RV64 MCU 工具链、未上任何开发板；
文中 ESP32 一侧的所有数字都是外推，第一次上板实测会重写这些行。
