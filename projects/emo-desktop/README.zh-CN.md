# emo-desktop

门之上的桌面:EmoOS 的合成窗口 GUI,用 Emo 写成——屏幕、指针、字形、窗口、dock 与其上的应用,一门语言从上电走到桌面。它是 EmoOS 单语言闭环的延续,抵达机器剩下的最后一层:内核、服务、shell、控制台 UI 之后,桌面是证明的下一段路。

emo-desktop 是与 [`projects/emo-os`](../emo-os)、[`projects/emo-ui`](../emo-ui) 并列的独立项目,而它们之间的边界就是机器自己的边界:**门(ecall gate)。** 门以下的一切——设备驱动、合成器的机制、gate 动词、地址空间与帧的管线、ABI 的稳定性契约、冒烟测试的 display 腿——属于 EmoOS,住在 EmoOS 树里。门以上的一切——framebuffer backend、字体、桌面 shell、应用、它们的 hosted 语料——属于本项目。

English version: [`README.md`](README.md).

## 定位

- **Wayland/Quartz 形状,QNX Screen 谱系。** 一个合成器拥有 scanout;客户端在授权缓冲里渲染再 present;输入是统一的事件流。这与 EmoOS 微内核已认的谱系同宗,用在像素上。
- **包的集合,不是第二个镜像。** 内核只嵌一个用户镜像;M7–M10 期间桌面以包的形态骑在该镜像上(boot image `require`,`syscall` stub 包的先例)。到 M11、程序从文件系统以 ELF 装载时,应用原地变成磁盘 ELF——结构不变。
- **hosted 内核,金属外壳。** fb backend 的逻辑(对一个 buffer 接口的 measure/place/clip/blend)是可移植 Emo,hosted 在语料里跑、也在金属上跑;只有薄的 raw 垫片(`peek`/`poke`)独属 riscv64。EmoOS 验证过的双跑纪律向上延伸。核心已落地为 [`fb/`](fb/)——包 `emo/ui_fb`、`emo/ui_fb_canvas`(hosted surface)与 `emo/ui_fb_frame`(第一帧),连同它们的测试、golden 和 gate(`fb/check.sh`);垫片背后的 carve surface 住在 EmoOS 的用户镜像里,核心经它画出的第一帧就是机器开机时屏幕上的画面——carve、hosted canvas、display 三处读出同一个 digest。

## 命名——已定

- 项目目录:**`projects/emo-desktop`**(不取 `emo-gui`——两个 ui 字头的顶层项目是慢性混淆;2026-10-31 定案)。
- framebuffer backend 包:**`emo/ui_fb`**——EmoUI 的第六个 backend,加入解释器、TypeScript、wasm、BEAM、控制台家族。
- 桌面 shell 包:**`emo_desktop`**——扁平系统名,`emo_os` 的先例。
- 目录命名项目,包名命名家族。

## 路线图

| 里程碑 | 范围 | 状态 |
| --- | --- | --- |
| M7 — 屏幕 | virtio-gpu 路径、screen carve、第一帧全屏、present | 进行中 |
| M8 — 字形与指针 | 位图字体、指针精灵、输入合并 | — |
| M9 — 窗口 | 合成窗口循环、拖动、聚焦、击杀重启 | — |
| M10 — 桌面 | EmoUI fb backend 完整化、dock、第一批应用 | — |
| M11 — 诚实多应用 | 文件系统来的 ELF、每镜像段表、每进程 gate 检查 | — |

编译器轨道(字面量宽度修复、N-block arena、frame-scoped pool)在阶梯之旁并行,不在其内——那些任务是 Emo 主树与 EmoOS 追踪器的。

## 体验是什么——不是什么

可达:合成窗口、拖动、聚焦、鼠标、位图字体、dock、真实应用(计数器、文件浏览器、编辑器)。这套栈上不可达:GPU 加速、抗锯齿、动画级帧节奏、硬实时。诚实的体感是九十年代初的工作站带着 Mac OS 9 的脾气。架构在这之上的生长路径也是记录的一部分:[`docs/assessment.md`](docs/assessment.md) 收着可扩展性契约(什么冻结、什么可搬、什么可加)与完整的调研讨论,包括 M7 之前已定案的决策点(2026-10-31)。

逐任务清单见 [`docs/TASKS.md`](docs/TASKS.md)。每个里程碑的内核侧一半住在 [EmoOS 的追踪器](../emo-os/docs/TASKS.md);ABI 的稳定性契约是 [EmoOS 的文档](../emo-os/docs/desktop-abi.md)。
