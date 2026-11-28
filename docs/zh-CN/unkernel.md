# unkernel 与 EmoOS —— 一份评估与桌面路线图

写于 2026-11-27。本文评估 unkernel 项目，并给出一份把它的桌面 UI 设计
语言搬到 EmoOS 上的建议路线图。这不是已定的设计:文中的路线图已作为
planned 行开进项目的 tracker(2026-11-27)——M37–M42 在桌面 tracker，
Step 18 在 EmoOS 的;测量数字以写作日期的仓库为准。

英文版:[`../unkernel.md`](../unkernel.md)。

## 项目

unkernel 用项目自己的话说，是「一个真正的 Linux 内核，编译成
WebAssembly。它在不到一秒内启动到一个 shell。」它运行未经修改的
aarch64 Linux 二进制——Alpine 和 Debian 的包按原样——其内核的
syscall、调度器、内存管理、ext4 与 TCP/IP 是编译代码，不是模拟硬件。

### 那个反转

README 自己的对比最清楚:

- **整机模拟**(v86、JSLinux、QEMU-in-wasm)忠实但慢:每个 syscall
  和缺页都要穿过模拟硬件。
- **syscall 模拟**(WASIX、WebContainers)快，但只覆盖运行时实现的
  那部分 Linux。
- **在 NOMMU 内核上把程序编译成 wasm**(linux-wasm、LKL)快，但要
  重新编译，fork 和一切需要 MMU 的东西会坏掉或被近似。
- **unkernel 保留真正的 Linux 内核**，让它以原生 wasm 运行，只模拟
  用户态，并在真正的 MMU 下。

名字不是 "unikernel"。unkernel 去掉的是**被模拟的内核态**，不是内核:
一次 syscall 就是 `kwemu` 返回内核的一次普通函数返回，内核按原生
wasm 处理;中间没有模拟 trap，也没有模拟内核态。

### 各个部件

- **内核:** Linux 7.3.4 编成单个 wasm 模块(`arch/wasm`，从 Joel
  Severin 的 linux-wasm 移植长出来)，先编 wasm64，再降成 32 位内存
  的模块给宿主。
- **用户态:** 未经修改的 aarch64 二进制跑在 kwemu 上——一个 Zig 写的
  aarch64 CPU，链进内核(`src/`，契约 `include/kw_emu.h`)。
- **任务切换:** JSPI(`WebAssembly.Suspending`)给内核可挂起、可恢复
  的真实栈。
- **MMU:** 真正的 Sv48 页表;kwemu 走内核自己的页表。
- **设备:** 面向 JavaScript 宿主的小型半虚拟化驱动——kwblk、kwnet
  (JS 的用户态 TCP/IP 栈)、kwfb/kwinput/kwsnd、kwvsock、kwshm;
  GL 走 virglrenderer,Vulkan(`vk/PROTOCOL.md`)，VA 编解码;ext4、
  overlayfs、tmpfs、loop、FUSE、9p。
- **执行层级:** 基本块解码成紧凑 op，一个参考解释器，以及把热块编成
  wasm 的 JIT，输出与解释器逐位一致;FP/AdvSIMD 和少跑代码留在
  解释器。
- **工具链:** Zig 0.16、Node 24、LLVM/clang 22 加打过补丁的 wasm-ld、
  Binaryen 133;内核补丁系列打在 Linux v7.3.4 上。

### 数字与边界

- 启动到 `/init` 约 70 ms;Alpine 提示符在 node 启动后约 0.3 s 出现。
- `getppid` 约 170 ns(qemu-system 下约 1.7 µs);fork + exit + wait
  约 60 µs，原生约 70 µs。
- JIT 让 shell 循环快 1.6×、sort 快 2.3×(相对纯解释器)。
- CPU 重活仍落后:`apk search` 约 0.8 s，`apk add python3` 约 3.4 s。
- 边界:SDK/CLI 默认单 CPU(页面上可行时开多个;SMP 快照只在相同
  CPU 数上恢复)，无 IPv6，除 DHCP/DNS 外无 UDP，无入站连接，无硬件
  断点/观察点，FP/AdvSIMD 走解释器，内核里的 wasm trap 会结束会话。
  宿主是 Node 24 与带 JSPI 的浏览器(README 列出 Chrome/Edge 137+、
  Firefox 153+、Safari 27+)。

### 项目状态

仓库创建于 2026-11-12;截至 2026-11-27 约有 1,950 star、107 fork，
仍是活跃推送。内核与补丁是 GPL-2.0(逐文件，或更高版本);SDK 与页面
是 MIT。工程扎实而密集——打过补丁的 wasm-ld、fake-LLVM 的 Kbuild
包装、UP 与 SMP 内核、发行版镜像、profiler 和成文的测试矩阵——但
项目年轻，且要长期背负 Linux 7.3.4 补丁系列的维护。

## 为什么它不能作为 EmoOS 的实现原理

首先要摆正类别:unkernel 是一个**宿主上的兼容运行时**，不是 OS 的
实现原理。它的机器是浏览器或 Node 宿主，设备是 JavaScript;它的内核
是 Linux。EmoOS 的机器是 QEMU `virt` 或真 RISC-V，设备是 16550A、
PLIC 和 virtio，内核是 Emo。两个项目只在一句话上一致——「只模拟必须
模拟的」——而这句话里的每个词都相反。

| 轴 | unkernel | EmoOS |
| --- | --- | --- |
| 机器 | 浏览器 / Node + JS 设备 | QEMU `virt` / 真 RISC-V;OpenSBI;内核自拥 console |
| 内核 | 真 Linux(GPL-2.0) | Emo 写的微内核(MIT) |
| 地址空间 | wasm 无 MMU;软件 Sv48 | 硬件 SV39、trampoline、fault-to-kill |
| 调度 | JSPI、协作式、宿主给的栈 | tick 抢占、trap frame 与内核栈 |
| 用户态 | 模拟 aarch64 二进制 | Emo/C 源码重编成原生 riscv64(Plan B) |
| 设备 | `kw*` → JS 宿主 | 驱动即进程，走 virtio 与 PLIC 的线 |
| 闭包 | Linux + Zig + TypeScript + JS | 一个编译器、一种语言，从开机到提示符 |

三根支柱，以及每一根撞在哪里:

1. **原生内核 + 模拟用户态。** 原生内核是 Linux。采用它就要换掉 Emo
   内核、打破单语言闭包，并把发行物重新许可成 GPL-2.0。这一条就决定
   了问题。
2. **复用现成内核的语义，而不是重实现。** 这是 unkernel 真正的效率
   来源:它不重实现 Linux，它把 Linux 装进来，只模拟 CPU。EmoOS
   不可能在不装 Linux 的前提下拿到这一点，而装 Linux 就不是 EmoOS
   了。没走的那条路是 Plan A,Linux personality——
   [`EmoOS.TASKS.md`](../../projects/emo-os/docs/EmoOS.TASKS.md) 已经
   以隔离为由否决了它。
3. **宿主提供设备与生命周期。** EmoOS 的 "The machine" 一节正好相反:
   profile A 从 `0x80200000` 进入，单 hart，内核自己的 putc 停在运行时
   的 console 钩子里，PLIC 的线进 trap shim,virtio-gpu 走 2D 路径。
   这里没有宿主可以靠。

unkernel 的两个机制是补偿，不是可借鉴的教训:软件 Sv48 走表是因为 wasm 没有
MMU,JSPI 是因为 wasm 栈否则无法挂起/恢复。EmoOS 从 SV39 拿到前者，
从自己的 trap frame 和内核栈拿到后者。性能的不对称也指向同一处:
unkernel 的 ~60 µs fork 是「原生 Linux + 模拟用户态」;EmoOS 的 fork
是原生 riscv64 指令。CPU 密集的活，EmoOS 站在原生的一侧，不是模拟的
一侧。

## 可以借的

只有边界原则:

- **只模拟必须模拟的。** EmoOS 已经用另一条路实现了它:信任边界放在
  进程，Emo/C 代码原生编译，门是唯一被认可的跨越。Plan B 就是这个
  原则，以编译器作为兼容层。
- **如果将来真需要 Linux 二进制**，EmoOS 上诚实的形态是一个用户态
  Linux 兼容进程——CPU 模拟器加 Linux syscall 转译者，以门的动词说话——
  而不是把 Linux 放进内核。那是一个重新打开 Plan A 的产品决定，
  隔离成本是 [`EmoOS.TASKS.md`](../../projects/emo-os/docs/EmoOS.TASKS.md)
  已经算过的那笔。
- **如果将来真需要浏览器里的 EmoOS**，`kw*` 设备 ABI、JSPI 调度和
  宿主边界是参考;而且 Emo 的 `wasm` 目标意味着用户代码直接编成
  wasm，根本不需要模拟层。那是一个额外的部署目标，永远不是金属 OS
  的原理。
- **验证。** unkernel 的解释器/JIT 逐位一致与 EmoOS 的 hosted/metal
  逐字节一致是同一种纪律。没有新东西要搬。

## UI 目标

这个问题里的桌面是**宿主页面**(`web/`)，不是 guest GUI。unkernel 的
`.agents/web.md` 描述它:一个画在 DOM 里的 macOS 式桌面——自己的
window manager、壁纸上的窗口、Dock、透明顶栏(菜单、资源表、
Control Center)、带文件夹的 launcher、带 tab 的 Terminal 窗口
(wterm;更多会话走 vsock)、guest display 与 preview、Settings 和
System、installer、guest 的 Wayland 应用窗口、Overview、snap 预览、
对话框和 toast，以及触摸用的键条。它是 React + Tailwind v4(Geist
之后的暗色主题)，客户端 Vite、服务端 Nitro。

它的一半精致来自浏览器合成器:GPU 合成、真正的 backdrop blur、
60 fps、完整的字形排版。EmoOS 是单 TCG hart 上的软件光栅器。所以
这件事是**用 Emo/EmoUI 重做设计语言与交互模型**，不是移植代码;
唯一字面的移植是往 EmoOS 里塞浏览器引擎，那会同时丢掉闭包和性能。

EmoOS 不是从零开始。M13–M36 已经站着:macOS 脸、真字体的 HD 桌面、
圆角与阴影、半透明 chrome、RLE 壁纸与取色、图标族、Dock、launcher
与锁屏、通知、时钟与日历、四个工作区、editor/files/counter 应用、
剪贴板与选区、Alt+1..4、动效词表。工作是密度与帧率，不是结构。

三个瓶颈决定顺序:

1. **会话稳定性。** Step 17 的记录:boxed value-kind 消息泄漏(成文
   的 T8.7 泄漏)让一个 app 的 arena 在约 100 次 present 后死掉;
   显示驱动没有 supervisor，一次丢失的 flush 回复会让合成器永久停住。
   一个会话里会死的漂亮桌面不是桌面。
2. **帧预算。** M15 实测整屏合成约 230 ms、384×256 窗口的 damage
   约 36 ms(约 100 ns/word)。alpha 与 RLE 壁纸之后又加了成本;
   第一件事是重新测量，不是猜。
3. **字体与材质。** 只有 Inter 与 JetBrains Mono Regular，整像素
   advance，无 kerning、无 hinting(typeface 笔记的 D12 触发器);
   逐像素 alpha 从 M30 起有，blur 仍是 stretch goal(noctalia 笔记)。
   浏览器这些东西不用问就有。

## 路线图

建议编号:`projects/emo-desktop` 的 M37–M42，内核那一半作为
[`projects/emo-os/docs/TASKS.md`](../../projects/emo-os/docs/TASKS.md)
里的步骤。顺序按性价比;P0 与 P1 可并行，P2 的 Terminal 只需要树上
已经有的底座。

| 阶段 | 范围 | 退出标准 |
| --- | --- | --- |
| **P0 — 地基**(前置) | 修 value-kind 消息泄漏(T8.7)，或给每个 app 一条回收路径;给显示驱动加 supervisor 和 flush 超时;十分钟 soak(拖拽、开关、launcher、editor、剪贴板) | 双传输 soak 绿;无 `heap gone`、无 wedge、内存平稳 |
| **P1 — 暗色皮肤**(M37) | design tokens:Geist 风中性色阶、壁纸强调色、8 px 间距、圆角 6/10/16、阴影/透明度/动效配方;Inter Semibold(typeface 笔记点名的 drop-in)、chrome 可见字对的 kerning、<14 px 的 hinting;统一窗口 chrome(标题栏、控件、tab strip);Dock 与 launcher 几何;顶栏状态区与光标族。先在 hosted fb canvas 上迭代 | 目标分辨率的启动截图与三窗场景对上设计;goldens 逐字节;零新增动词 |
| **P2 — Terminal**(M38) | 用现成 pipes(动词 55–60)与 fork/exec 的 0..2 继承起一个会话;终端窗口带 tabs、scrollback、选择、copy/paste、光标闪烁、ANSI 子集;多会话 | 从 Dock 开 Terminal，跑 `ls`/`cat`/`editor`，多 tab，复制粘贴;金属 golden 与拍 |
| **P3 — chrome 的行为**(M39) | `win_resize` 与 resize 事件(Tier C;合成器取新 run、重映射、重绘;app 重排);边缘 snap、snap 预览、双击最大化;Dock stacks/popovers、右键菜单、启动 bounce;Control Center(DND、壁纸、锁、display mode;音量等 audio，亮度无硬件，两者都按 D15 缺席);`sys_stats` 与顶栏米表;窗口内菜单原语(v1 不做 top-bar 应用菜单) | 拖/缩/吸附/最小化/恢复全通;Dock stack 可开;米表实时;goldens |
| **P4 — 系统应用**(M40) | Settings(外观、强调色、壁纸、display、shortcuts、about、lock)、System Info(CPU/内存/uptime/进程/磁盘)、About;Files 与 Editor 换皮;壁纸选择 | 每个 app 都是磁盘 ELF、从 launcher 启动;provider 在 D14 seam 后面带 fixtures;运行中的 shell 无罐头数据(D15) |
| **P5 — 动效预算**(M41) | 重新剖析合成(walk、blit、alpha、shadow、text、transfer、flush);优化 opaque fast path、按尺寸缓存 mask/shadow、glyph cache、damage-only 重绘、coalescing、全屏 opaque 直接 scanout，必要时 `.S` blitter;用 present 回复做帧节奏(D12);落地 M32 停靠的动效(digest 差一、越界座位的 toplevel 挂死 walk)，然后 minimize genie、dock hover/bounce、toast slide、Control Center spring;Overview(B7)与 Alt-Tab(B8) | 1280×800 下 640×480 窗口拖拽 ≥30 fps(800×600 ≥20);每个动效在预算内;Overview ≥15 fps |
| **P6 — 材质**(M42，决策门) | 缓存 blur(壁纸开机算一次;面板复用缓存;底下窗口移动时失效;downsample-blur-upsample);glass 的 tint、noise 与边缘高光;预算不接受就按 D15 记录缺席，只发 alpha + scrim;GPU/virgl 或多 hart tile 合成只作为测量后的研究 spike | blur 在预算内落地，或带数字否决 |

### 阶段说明

- **P0 的泄漏是唯一硬前置。** 静态皮肤可以在 hosted canvas 上先做;
  金属验收等它。
- **P2 比看上去便宜。** Pipes(55–60)、fork 与 exec 的低 fd 继承已经
  在门里;shell 今天是机器的 REPL(emosh 的分支是更丰富的行编辑器，
  落地后可换)，终端只是它们之上的桌面窗口与 cell 渲染器。它是单位
  工作量里最显眼的一块。
- **P3 带主干的两条 Tier C 新增。** `win_resize` 及其 resize 事件，
  以及 `sys_stats`:两者都是编号冻结规则下的新增，八条 seam 不动。
  如果 resize 推迟，snap 和最大化可以只落在被移动的窗口上。
- **P5 从测量开始，不从优化开始。** M15 的数字早于 alpha 和 RLE
  壁纸;新的剖析是后面每个选择的输入，包括是否值得开 GPU 或
  SMP 轨。
- **P6 是决策门，不是承诺。** 浏览器的 blur 是免费的;金属的不是。
  alpha、scrim 和缓存 blur 是诚实的版本。

## 保真度上限

软件路线的现实目标是 **1280×800 或 1440×900、窗口级动效约 30 fps、
全屏切换硬切(D13 的决定)、静态缓存 blur**。这能拿到 unkernel 的
静态观感和大部分交互;拿不到 60 fps 全屏动效或实时 backdrop blur。

越过上限的两条路都是独立的轨:

- **GPU。** growth contract 的 Tier B 已经允许 "the blit may become
  GPU work";八条 seam(其中有 buffer 是 capability、formats 与 scale
  是字段、frame callback、原子提交)就是为它建的。但它需要 QEMU 在
  macOS 上真能提供的 GPU 路径(virgl 支持要先验证)，而真 RISC-V
  板子上根本没有这条路。
- **多 hart 合成。** `-smp` 是停靠，不是不可能;tile 并行能按 hart 数
  切整屏 walk。那是 SMP 内核里程碑，不是桌面的。

两条都不该在 P5 的数字出来前开。建议先走软件路线。

字体是第二大杠杆，也最便宜:一个 Semibold face、可见字对的 kerning、
只在 <14 px 做 hinting(typeface 笔记点名的触发器)。浏览器的 shaping
引擎仍然领先;在 UI 字号上差距很小，而且每个字形只付一次。

## 非目标

- 不搬 React/Tailwind/DOM，不往 EmoOS 里塞浏览器引擎。
- 不搬 unkernel 的内核、wasm 或 GPL 代码;页面是 MIT，只解决资产
  问题，设计语言是参考。
- 不为好看破 Tier A ABI:resize 与 stats 是 Tier C 新增，编号冻结
  不动。
- 不做 guest display、installer 或 Wayland 应用窗口:EmoOS 自己就是
  机器，对应物是原生 app。unkernel 的 guest preview 存在，是因为它
  托管了一个不是自己写的 Linux。

## 参考

- unkernel:<https://github.com/pithings/unkernel> —— `README.md`、
  `kernel/README.md`、`.agents/web.md`、`.agents/status.md`。
- 桌面:[`projects/emo-desktop/README.md`](../../projects/emo-desktop/README.md)、
  [`docs/assessment.md`](../../projects/emo-desktop/docs/assessment.md)、
  [`docs/typeface.md`](../../projects/emo-desktop/docs/typeface.md)、
  [`docs/TASKS.md`](../../projects/emo-desktop/docs/TASKS.md)。
- 机器:[`projects/emo-os/README.md`](../../projects/emo-os/README.md)、
  [`docs/TASKS.md`](../../projects/emo-os/docs/TASKS.md)(Step 17)、
  [`docs/syscalls.md`](../../projects/emo-os/docs/syscalls.md)(动词
  10–35 与 55–60)。
- 皮肤阶梯与语言边界:[`noctalia-desktop.md`](../noctalia-desktop.md)、
  [`xv6.md`](../xv6.md)、[`rtos-assessment.md`](../rtos-assessment.md)、
  [`runtime-and-freestanding.md`](../runtime-and-freestanding.md)。
