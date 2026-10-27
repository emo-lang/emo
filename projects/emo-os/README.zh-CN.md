# EmoOS

一个用 Emo 写成的操作系统——内核、shell、用户程序同出一门语言，从上电走到提示符。EmoOS 是一个 xv6 量级的研究与教学系统：大到能在真实（或模拟的）RISC-V 硬件上跑真程序，小到可以通读全部源码。它是 Emo 单语言闭环的证明，也是这门语言经受的最狠试金石。

状态：pre-alpha。内核可在 QEMU 下启动，并经自己的轮询 16550A 驱动打印；固件控制台只保留关机。任务追踪见 [`docs/TASKS.md`](docs/TASKS.md)。

English version: [`README.md`](README.md).

## 定位

- **xv6 量级——不是 FreeRTOS 量级，不是生产系统。** 软实时、协作式优先。硬实时与功能安全认证不在范围内；边界分析在 Emo 主树的 [`docs/rtos-assessment.md`](../../docs/rtos-assessment.md)。
- **核心价值是闭环。** 同一个编译器产出内核镜像与用户程序；shell 和控制台 UI 是 Emo + EmoUI。特权边界两侧没有第二门语言。

## 架构——结构化微内核

EmoOS 是 QNX 谱系的微内核：进程边界只画在故障隔离买得到的地方。

- **进程化**：设备驱动、文件系统、网络栈、shell、用户程序——大的、易崩的、第三方气质的代码。
- **不进程化**：调度器、trap 分发、分配器、syscall 分发——小而可信的核心代码，直呼函数。把它们进程化是白付消息税、买不到隔离。
- **边界可撤**。SV39 之前一切共享同一地址空间；某条服务间热路径量出来太贵，就合并回一个进程。"一切皆 IPC"的形态是缺陷不是特性——微内核的经典三病在这里都有常备解法：同地址空间下 IPC 就是函数调用加一次拷贝；记账按构造即精确；优先级经由投递每条消息的调度器流动。
- **资源记账**。内存按进程归因是构造保证的；拷入邮箱记发送方配额，拷入接收方堆记接收方；CPU 按进程计时。失控进程耗尽的是自己的配额——响亮地，且只伤自己。
- **send 时优先级捐献**。进程的有效优先级 = max(自身，所有等待者的优先级)。同步内核调用带超时；调度器掌握等待图、可检测环。
- **崩溃重启纪律**。每个服务区分权威状态与可重建状态：重启的文件系统服务从磁盘重建缓存，挂载表必须幸存。只有当"会丢什么"被显式声明时，重启才是安全的。

## 内存模型

- **每进程一个 arena 堆**。进程终止以 O(1) 回收整堆；消息跨堆拷贝。值语义可以放心分配，因为回收有界且确定。
- **内核无 GC——定案**。回收 = 进程死亡 + 有界缓存；长寿服务维持有界工作集。引入收集器只会让抢占更难，不会更容易。
- **物理内存走裸内存**。物理帧、页表、设备缓冲统一用 `Int64` 地址、`peek`/`poke` 和位掩码管理——无类型内存纪律，接受并圈养在固定层。

## 隔离路线

- **特权先行，地址空间后置**。用户程序先以 U-mode 越过 ecall 门；SV39 随后关闭窗口。
- **弱隔离窗口如实记录，绝不遮掩**。SV39 之前，U-mode 执行不了特权指令，但它的访存能摸到内核 RAM 和 MMIO。SV39 之前的防线是拷贝语义与内核自身的参数检查。
- **SV39（M5）买到**：每进程独立地址空间；野写被 MMU 当场击毙而不是被内核吸收；每个服务边界背后都有硬件强制；所有用户 ELF 共用一个固定加载地址。

## 内核所踩的语言原语

- **`Atomic`——Box 的同步兄弟——住在 `core`**。只有顺序一致性；不暴露 memory order 参数。第一刀只覆盖 `Int64` 与 `Bool`：`load`、`store`、`exchange`、`compare_exchange`（返回 `(Bool, Int64)`）、`fetch_*` 家族，外加 `fence()`。对标量之外的类型原子操作直接拒绝。设计笔记：[`docs/atomics.md`](../../docs/atomics.md)。
- **每目标诚实**。解释器与 TypeScript / wasm 目标是精确空操作（协作单线程——顺序一致性平凡成立）；`c` 落到 `__atomic` 内建；`ocaml` 用它的 `Atomic` 模块、位运算以 CAS 环补足；BEAM 落到运行时的 `atomics` 数组——全集，按位 `fetch_*` 以比较并交换环补足；`riscv64` 是真主场——`amoswap`、LR/SC、`fence`。
- **`peek8`/`poke8`/`peek64`/`poke64` 定义上就是 volatile**——永不消除、互不重排。字节线骑在 `Byte` 上（无符号，0–255），字线用 `Int64`；`poke` 不回答值。`riscv64` 准入——程序拥有地址空间——其余托管目标按名拒绝（E4028）。设计笔记：[`docs/raw-memory.md`](../../docs/raw-memory.md)。
- **riscv64 Stage B 是前置条件，不是优化**。动态值模型下每个 `Int64` 都是装箱的堆单元：一次 MMIO 读分配一个永远无人回收的 cell，轮询循环会烧穿堆。类型特化让 `Int64` 走寄存器，只在逃逸点装箱（容器元素、字段、闭包捕获、消息、动态调用边界）。
- **ISR 纪律：中断体内零分配**。预分配环形缓冲走裸内存；ISR 只做 ack、入队、唤醒——排水是进程的事。

## 机器

- **Boot profile A，整个路线图期间固定**。OpenSBI 以 S-mode 在 `0x80200000` 进入内核，携带 hart id 与 DTB；非 boot hart 永久 park。单 hart；SMP 挂起。
- **QEMU `virt` 是开发环**；同一镜像可跑在真实 RISC-V 硬件上。`./run.sh` 启动镜像并 grep 串口输出。
- **内核拥有自己的控制台。** boot stub 把 Emo 驱动的 putc 停进运行时的单词 console hook，于是每个打印字节——`println`、panic——都走 `peek`/`poke` 之上的轮询 16550A 驱动；SBI 只保留 poweroff ecall。接收侧是中断驱动的：PLIC 把 UART 的中断线送进 trap shim，shim 装满预分配的环并唤醒 console 进程；reader 阻塞在普通邮箱上。
- **双运行开发**。硬件藏在结构接口后面：内核服务在 hosted 解释器 + 假设备下运行——毫秒级迭代、可直接断言——再到 QEMU 里跑真东西。两路输出必须逐字节一致。

## 项目在源码树中的位置

- 内核包名为 **`emo_os`**——扁平名（包注册表对第三方禁用 `emo` 前缀防冒充；内核本身不走发布），与 hosted 的 `os` 包相互独立。用户态 syscall stub 是独立的包，不叫 `os`。
- EmoOS 在 [`docs/TASKS.md`](docs/TASKS.md) 独立追踪自己的工作；编译器侧任务（atomics、Stage B、镜像打包）在 Emo 主树执行、在此追踪。

## 运行

```console
$ emo build main.emo --target riscv64
$ ./run.sh
```

## 里程碑

| 里程碑 | 范围 | 状态 |
| --- | --- | --- |
| M1 — 裸机 bring-up | freestanding 镜像启动、经 SBI 控制台打印 | 完成 |
| S1 — 内存原语 | atomics + volatile `peek`/`poke` + `fence`，全目标 | 完成 |
| S2 — riscv64 Stage B | 类型化调用约定、逃逸点装箱 | complete |
| M2 — 协作内核 | 金属上的进程、调度器、中断驱动 UART | — |
| M3 — 用户态 | U-mode、ecall 门、用户 ELF、syscall stub | — |
| M4 — 进程内存 | arena、配额、死亡即回收、帧分配器 | — |
| M5 — SV39 | 每进程地址空间、trampoline、fault 即击杀 | — |
| M6 — FS、shell、EmoUI | virtio-blk 服务、shell REPL、控制台 UI | — |

逐任务清单见 [`docs/TASKS.md`](docs/TASKS.md)。

## 相关文档

- [`docs/atomics.md`](../../docs/atomics.md) — 原子内存模型：只有顺序一致性、操作集、每目标矩阵、数据竞争语义。
- [`docs/rtos-assessment.md`](../../docs/rtos-assessment.md) — 实时边界分析（Emo 主树）。
- [`docs/xv6.md`](../../docs/xv6.md) — xv6 量级可行性评估：Emo 替换什么、什么留在汇编。
- [`docs/runtime-and-freestanding.md`](../../docs/runtime-and-freestanding.md) — freestanding 目标拥有什么。
