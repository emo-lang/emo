# Emo 与 xv6 级内核 —— 一份可行性评估

写于 2026-10-06。这是一份技术可行性评估，不是已定的设计决策；文中关于
项目状态的描述以写作日期的仓库为准。

问题：**理论上，用 Emo 开发一个 xv6 级内核是否可行？** 这里只看语言设计
（语法与语义）和编译架构，暂时忽略开发工作量。

## 简短回答

**可行，但有一条精确的边界：不是"纯 Emo"。** 有用的切入方式是把 xv6 拆
成两半：

> **xv6 = C 的一半 + 汇编的一半。**（`entry.S`、`trampoline.S`、
> `kernelvec.S`、`switch.S`、`start.c`，加上 `riscv.h` 里满屏的
> inline-asm CSR 助手、`volatile` MMIO、`__sync` 自旋锁。）

所以真正的问题是：**Emo 能不能替换掉 C 的那一半，而保留汇编那一半？**
理论上可以 —— 只要 C 那一半的需求（原始地址、位域、union、`volatile`、
原子）有出路。Emo 把它们引到 `Int64` + `peek`/`poke` + `Bytes` + 一层
汇编/C shim。代价是：类型系统恰好在这一半变瞎。

## 逐项对照

| xv6 需要什么 | Emo 现状 | 理论上可达方式 |
| --- | --- | --- |
| 裸机启动、链接脚本、固定布局 | `riscv64` 目标已规划（`plan/step-22`），未实现 | 后端发汇编文本 + `ld` 脚本 + 入口 stub |
| **CSR 读写**（`satp`/`stvec`/`sstatus`/`sepc`……） | 无原语；`peek`/`poke` 够不到寄存器组（`plan/step-14`） | 手写 `.S`/C shim（xv6 同样用 inline asm） |
| **trap 入口与返回**（`sret`） | 无 inline asm | 手写 `.S`，和 xv6 一样 |
| 原始物理内存（MMIO、页表） | `peek`/`poke` 已设计但**未实现**；`Bytes` 有，但只是宿主缓冲 | `Int64` 地址 + `peek`/`poke` |
| **位域/重叠 union**（PTE、`struct proc` 落一整页） | 无 union、无 `offsetof`、无布局控制 | `Int64` 掩码 + `peek`/`poke` 手工偏移 |
| **就地可变表**（`proc[]`、页 freelist） | 数组不可变、字段 `init` 后冻结、无全局 `var` | 原始内存 + `Box` |
| **自旋锁与原子**（`amoswap`、LR/SC、`fence`） | 语言无原子/屏障语义 | 汇编 shim（`plan/step-14` 的机制/策略切分） |
| `volatile` MMIO 语义 | `peek`/`poke` 是可被重排/消除的调用 | 同一层 shim，或语言层 `volatile` 决策 |
| 函数指针/中断分发 | 部分 —— 闭包是堆记录 `[code, captured]`，非裸代码地址 | 编译期 vtable 能做分发；`stvec` 需 shim |
| 用户态（U-mode）与 `ecall` 门 | 全是 CSR + `sret` | 汇编 shim |
| 分配器（`kalloc`/`kfree`） | 可插拔运行时、无 GC、bump 分配器 | 自己在 Emo 里写 freelist |
| 调度、syscall 分发、FS、驱动策略 | 纯 Emo 可表达 | Emo |
| 循环 | 目前只有尾递归（循环**已决定未实现**） | 尾递归；`riscv64` 保证 `tail`/`jalr x0` |

## 三类缺口，三种性质

**A. 纯机械缺口 —— 加原语即可，哲学不动。**
CSR 访问、原子/屏障、裸代码指针。这些是"补一个 primitive"的问题；
`docs/rtos-assessment.md` 已把 `volatile`/atomics 列成 `CHECK.md` 的
待决项。加完即关闭。

**B. 有逃生舱，但类型安全归零。**
页表、union/重叠、就地可变表。这些**不是阻塞**：用 `Int64` 当地址、
用 `peek`/`poke` 按 8 字节读写 PTE、用掩码做位域、用原始内存撑起
`proc[NPROC]`。xv6 的 C 代码本质上就是这么干的。Emo 能表达，但它表达的
是一个**无类型的内存程序**。

**C. 真正的模型冲突 —— 需要一次设计决策。**
**整个内核共享的可变全局状态。** Emo 的值语义、不可变数组、字段
`init` 后冻结、`var` 不逃逸 block、消息按拷贝发送 —— 这套模型是为
**隔离**设计的（Erlang 血缘），和内核需要的"别名共享 + 就地改 + 全局
可变"正好相反。理论出路是把**整个内核建模成一个 Emo 进程**，全局状态
放进一组 `Box`，其余全部落到 `peek`/`poke` 背后的原始内存里。它能跑，
但语言对"内核数据结构"没有任何原生惯用法 —— 这才是那个有意思的理论
问题，不是汇编。

## 编译架构

- **后端形态够用。** `riscv64` 发汇编文本交给 GNU `as`/`ld`，配上生成的
  链接脚本；手写 `.S`/freestanding C 源码编入镜像，以 psABI 为契约 ——
  这正是 `plan/step-14` 描述的"裸机 C 互操作"形态。IR（命名函数、闭包、
  编译期 vtable、保证尾调用）对内核逻辑是充分的。
- **无 GC 是加分项。** bump 分配器天然能当 `kalloc` 的底座，freelist 自己
  维护；抢占一旦有了就是纯寄存器/栈切换，不用对付增量回收。
- **两个硬前置门槛：**
  1. 在 `riscv64` 上，`plan/step-22` 目前**在发射期拒绝 `foreign def`**，
     而内核需要 CSR、原子、trap 的桥。也就是说"把 C/汇编编进镜像"这条桥
     必须在 FFI 阶梯（`plan/step-14` 的 rung 1–2）上前移；否则连 M1 都
     过不去。
  2. **`Int32` 与精确位宽的 `peek`/`poke`**：设备寄存器必须按宽度访问
     （`docs/numeric-width.md` 明说），而 `Int32` 目前只是"约定好的未来
     类型，表面未定"。
- 另外，`Int64`/`Float64` 在 freestanding 的动态世界里是**装箱两字单元**；
  内核路径依赖 step 13 的 Stage B 特化来保持裸寄存器，否则每次访存都要过
  装箱路径。

## 一个更尖锐的观察

把上面合起来看：**Emo 的类型系统，恰好在内核最需要它的地方最无能。**
内核代码里最有安全价值的东西 —— 物理地址 vs 虚拟地址、MMIO 寄存器的
宽度与易变性、PTE 的位域、`struct proc` 的布局 —— 在 Emo 里全都退化成
`Int64` + 裸内存，检查器一句话也说不上。

所以"Emo 里写 xv6"理论上成立，但图的不是"更安全的内核"，而是**单语言
闭环**（内核、shell、UI 同一种语言）。在 xv6 这个尺度上，Emo 更像一个
**压在裸内存之上的编排层**（除了垃圾回收以外什么都有），而不是一个能
检查内核最危险代码的语言。

## 判定

- **纯 Emo、不加新表面、不带汇编/C shim：不可行。** CSR、trap 返回、
  原子这三样无法表达。
- **Emo + 一层薄基底**（汇编/C shim —— `plan/step-14` 已认可的机制/策略
  切分）：**理论可行。** 页表构造、分配器、进程表、调度、syscall 分发、
  ELF 装载、驱动策略、文件系统逻辑都能在 Emo 里写。
- **理论上真正的 blocker 只有三处：**（1）trap/CSR/原子原语 —— 可加；
  （2）共享可变全局状态的惯用法 —— 一次设计决策；（3）值语义对"别名
  内存"的盲区 —— 有逃生舱但无类型。

一句话：**可行性不取决于调度器或页表算法，而取决于 Emo 是否愿意承认
"内核代码需要一个类型系统管不到、但语义明确定义的原始内存子语言"。**
`peek`/`poke` 是它的雏形；把 `volatile`、原子、精确位宽补齐，xv6 在 Emo
里就是可写的。

## 参考

- `docs/rtos-assessment.md` —— RTOS 的平行评估，以及同样的"硬实时遥不可
  及"结论。
- `docs/runtime-and-freestanding.md` —— freestanding 与 runtime 之别，以及
  `riscv64` 目标在两个轴上的位置。
- `docs/numeric-width.md` —— 位宽显式的数值类型，以及 MMIO 的 `Int32`/
  精确位宽 `peek`/`poke` 缺口。
- `plan/step-22-riscv64.md` —— freestanding 目标、值模型、启动 profile，
  以及 `foreign def` 的拒绝。
- `plan/step-14-other-targets.md` —— RISC-V 参考注记、机制/策略切分、
  C 互操作阶梯。
- `docs/native-backend.md` —— IR/特化流水线与 `foreign def` 表面。
- `README.md` 的 "EmoOS" —— 单语言闭环的野心。
