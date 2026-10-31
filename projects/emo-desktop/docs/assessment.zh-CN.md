# 桌面评估——调研记录

本笔记是桌面调研与项目背后三轮讨论(2026-10-31)的完整记录:架构、语言与机器划下的硬约束、分期、可扩展性契约(桌面长大时什么冻结、什么可搬、什么可加),以及项目自身的落位。已定的结论在 [README](../README.zh-CN.md);五个决策点已于 2026-10-31 全部定案,记录在这里和[追踪器](TASKS.md)的顶部。

## 形状:Wayland/Quartz,QNX Screen 谱系

一个合成器拥有 scanout,客户端在合成器授权的缓冲里渲染,present 是一个带损伤矩形的显式动作。客户端永远不碰显示硬件;服务器永远不替一个自己无法抢占的协作式客户端渲染。这是微内核自己的纪律(EmoOS 的 README 认领 QNX 谱系)用在像素上——Wayland 与 Quartz 长成那样的同一个理由。

各部件,按调研结论:

- **合成器=内核镜像里的服务进程**——`fs.emo` 谱系:固定页、pid cell、请求槽、负路由码、supervisor 重启。不做泛 IPC 对象;消息税只留在边界真正划算的地方。
- **显示=`virtio-gpu-device`**(本机 QEMU 11.1.2 已验证 riscv64 virt 能挂 gpu/keyboard/tablet/mouse)。驱动照抄 `blk_service` 形态:槽扫描、现代布局协商、DeviceID 16、先轮询完成(IRQ 后补——同一条明说边界)。2D 路径即全部所需:`resource_create_2d` → `attach_backing` → `set_scanout` → `transfer_to_host_2d`(损伤矩形)→ `resource_flush`。不取 ramfb——它能画像素,但不教任何 virtqueue 的事,而 virtio-gpu 是此后每个里程碑要骑的路。
- **输入=`virtio-input`(DeviceID 18)**——一个驱动加一个 input 服务,把事件流与 UART 的字节合并,shell 与桌面共享同一个事件世界。`-nographic` 下 virtio keyboard 收不到宿主按键:交互跑 `-display cocoa`,串口留给 shell。
- **客户端渲染,合成器合成。** 应用在授权缓冲里作画、带损伤矩形 present。M7 最省形状:一个全屏 pass、其缓冲直映射 screen carve,`present` 只做 flush。
- **门长出桌面动词段 10..16**:`present`、`output_info`(outputs 列表的动词——第二条接缝)、`input_read`、`win_new`、`win_close`、`win_focus`、`win_move`。编号规矩(一经分配即冻结、只增不改)在 [`syscalls.zh-CN.md`](../../emo-os/docs/syscalls.zh-CN.md);整个协议四周的稳定性契约在 [`desktop-abi.zh-CN.md`](../../emo-os/docs/desktop-abi.zh-CN.md)。
- **screen carve**:帧分配器区域顶端固定挖 4–8 MiB(推荐基线 1024×768 XRGB8888),`frames.emo` 的 `region_end` 下移——显存是内核的分配物,carve 是唯一比一块大的分配。
- **窗口缓冲**:`frames.take_run(n)`(连续 n 块)、`space.build` 增量映射进属主的表、gate 对每次 present 按授权表校验——缓冲是 capability 对象,不是裸地址。
- **EmoUI fb backend 是 tui backend 的像素孪生**——Elm 循环不动,backend 接口同族。且 blit 必须是 `Int64` 字(或 32 位)store:逐字节的拷贝循环在整帧规模下撑不住 TCG。

## 三大硬约束

1. **riscv64 无回收。** Elm 循环每事件重建树;64 KiB arena 撑不过一屏事件。对策:N-block arena(立即可做——arena 本就是分配器的块),以及更深处,把 c 目标的 frame-scoped autorelease pool 移植 riscv64 并以 Stage B 逃逸分析拒绝逃逸——语言深水区,归编译器轨道。
2. **数组字面量 >~253 元素汇编失败**(CHECK.md 155——12 位立即数;boot 横幅已踩)。这卡住内嵌字体——字形表是 KB 级。建议:修 codegen(register + `addi` 或分块 store);磁盘载字体是后备(M7 的文件系统使之可能)。字面量修复是推荐路线。
3. **协作式、单 hart、无 tick 抢占。** 忙应用冻住桌面。pool 与抢占一起,才撑起诚实的多应用 M11;在那之前,纪律是 shell 已经守着的那条。

## 分期

编译器轨道(字面量修复、N-block arena、pool)与里程碑并行,不在其内。

- **M7——屏幕**:驱动、carve、第一帧全屏、`present` 即 flush。
- **M8——字形与指针**:位图字体、指针精灵、输入合并。
- **M9——窗口**:合成循环、拖动、聚焦,以及真正要紧的验收——被击杀又重启的窗口栈。
- **M10——桌面**:EmoUI fb backend 完整化、dock、第一批应用(计数器、文件浏览器、编辑器)。
- **M11——诚实多应用**:文件系统来的 ELF、每镜像段表、每进程 gate 检查、按实测需要上泛 IPC。

**测试纪律**(EmoOS 的,延伸):QEMU monitor `screendump` PPM 校验和作金测的眼,`sendkey`/`mouse_move` 作它的手,`run.sh` 长 display 腿(golden 走 `-display none`,手开走 `-display cocoa`)。

## 体验边界

可达:合成多窗口、拖动、聚焦、鼠标、位图字体、dock、真实应用。不可达:GPU 加速、抗锯齿、动画、硬实时。诚实体感:九十年代初的工作站带着 Mac OS 9 的脾气。再往上,是下面的生长契约。

## 决策点,已定(2026-10-31)

1. **合成器落点**——定案:内核镜像里的服务进程(`fs.emo` 谱系)。
2. **M7 present 形状**——定案:客户端直映射 carve,`present` 只 flush。
3. **字体路线**——定案:修 codegen 的宽字面量;磁盘是后备。
4. **pool 排期**——定案:与 M7 并行而非其后——M8 的 Elm 循环等着它。
5. **分辨率基线**——定案:1024×768 XRGB8888。

## 生长契约:长到现代桌面还诚实地保持架构,需要什么

"架构不变"分三层:

- **Tier A——协议 ABI,冻结。** 动词编号、事件流形状、capability 模型。破它们就是破掉每一个写过的应用;`syscalls.md` 的编号冻结规矩就是版本化机制,而版本化本身就是契约。
- **Tier B——实现,可搬。** 字体可以变 TrueType,blit 可以变 GPU 工作,合成器可以离开内核镜像成为用户进程——不动一个动词、一个事件的形状。
- **Tier C——追加。** IME、剪贴板、截屏、通知、无障碍:新动词、新事件,加而不改写。

**现在就要定对的八个接缝**(各自经 B 或 C 生长,永不经破坏 A):

1. **缓冲是 capability 对象**,永不是裸物理地址——IOSurface/DMA-BUF 形状;GPU 路径、零拷贝、沙箱的前提。
2. **outputs 列表不是常量**——`frame_w`/`frame_h` 式常量是诚实的陷阱;枚举 outputs。
3. **surface 带 role 字段**——toplevel/popup/subsurface/panel;先实现 toplevel,其余按名拒绝。
4. **format 与 scale 是字段**——先只认 XRGB8888,协商的形状先在。
5. **统一版本化事件流,带 frame callback**——virtio-gpu 无 vblank;合成器按 tick 合成,frame callback 是动画故事的命门。
6. **present 是原子 commit**——一帧的状态整体落地。
7. **文本永不进协议**——键与字形是两端的;合成器运字节与矩形,永不运字符串。
8. **机制与策略分离,合成器可回缩**——win32k.sys 是反例,DWM 的迁移是故事;grant 对象从第一天起可 attach 进任意授权进程表。

**诚实的四件**——协议自身救不了的:无回收 arena(pool 是前置而非并行)、协作式单 hart(抢占必须落地;`-smp` 是 parked 不是不可能)、单镜像多 pass(M11)、泛 IPC(portal 类服务终会要;实测路径要它时再造)。

M7 与 M9 的规格各从本契约取五处增量——随各自任务记在两侧追踪器里。

## 落位一轮:本项目自身的形状

- **边界画在门。** 内核侧机制(驱动、合成器服务、动词、`space.build` 与 `frames` 管线、N-block arena、ABI 文档、冒烟的 display 腿、M7–M9 机制任务)留在 [emo-os](../../emo-os);fb backend、字体、shell、应用、语料,与本项目的 README 和追踪器,在这里。
- **包的集合,不是第二个镜像**——内核嵌一个镜像(`user.S` 嵌 `hello.elf`);M7–M10 期间桌面代码以包骑它。机制先例:`syscall` stub 包被 `hello/package.emo` 的 deps 消费,`projects/emo-ui` 的 `check.sh` 跨目录消费文件系统 registry。M11 时语料应用原地变磁盘 ELF——结构零改动。
- **fb backend 内部再切**:纯逻辑(measure、place、clip、blend 对 buffer 接口)hosted 进语料双跑;raw 垫片(`peek`/`poke`)独属 riscv64。
- **命名,已定**:`emo/ui_fb` 做 backend(EmoUI 第六个),`emo_desktop` 做 shell(`emo_os` 扁平名先例);目录命名项目。
- **第一批内容是文档与 hosted 语料**——不建空脚手架;代码随 M7 的第一个任务到来。
