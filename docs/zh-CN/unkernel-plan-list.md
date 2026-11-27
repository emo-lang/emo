# unkernel 路线图的工作清单

写于 2026-11-27。从 [`unkernel.md`](../unkernel.md) 的 P0–P6 路线图
推导的开发工作清单,以本日树的代码为准落地。它是桌面 tracker 里
planned 的 M37–M42 行与 EmoOS 的 Step 18(均已 2026-11-27 开启)背后
的工作清单;各阶段的详细任务小节在阶段启动时落进自己的 tracker。
noctalia 特有的新增项在
[`noctalia-v5.md`](../noctalia-v5.md),本文只在路线图点到名的地方
折入(明暗对、壁纸选择器)。

英文版:[`../unkernel-plan-list.md`](../unkernel-plan-list.md)。

## 落地事实(2026-11-27)

- 显示驱动是 `projects/emo-os/main.emo` 里的 `gpu_service`(开机
  第四个 spawn);同文件的 `comp_supervisor` 盯合成器并持有驱动的
  pid——但驱动本身没有 supervisor,合成器的 flush 等待也没有超时。
  Step 17 的缺口仍在。
- value-kind 消息泄漏是 T8.7 的成文泄漏:消息的副本落进接收服务
  的 arena,bump allocator 永不归还 boxed value kind;app 在约
  100 次 present 时死。
- `feat/emo-terminal` worktree 已不在;评估只活在记录里,所以这里
  复述的结论就是清单的地基:方案 B(EmoUI 循环 + mono cell 网格、
  carve 直绘),三个缺口(键表不全、Style 无色、子进程输出路由
  ——内核的 Tier C),三个待拍板问题(方案确认、poweroff 语义、
  counter 出列)。
- 桌面包在 `projects/emo-desktop/fb/`:`ui_fb.emo`(核心)、
  `raster.emo`(face 与 strike)、`desktop/`(壳)、`win/`、
  `winbuf/`、`apps/`(counter、editor、files、spin)、`glyphs/`、
  `fonts/`、`type/`,旁边是 `pointer.emo`。

## P0 — 地基(硬前置;与 P1 并行)

| # | 任务 | 位置 | 完成标准 |
| --- | --- | --- | --- |
| P0.1 | 修 value-kind 消息泄漏(T8.7)。探针先行:hosted,一个进程循环向门发 boxed 值,每轮读 arena。然后修消息 copy 路径的记账(门内 `copy_to`、mailbox copy)。备选路——把 c target 的 frame-scoped pool 移植到 riscv64——更大,只在消息路径关不上时走。 | `projects/emo-os`(`gate.emo`、arena/space 各文件);备选启用才动 `src/` | 探针 10k 条消息 arena 平稳;`run.sh` 绿 |
| P0.2 | 显示驱动的 supervisor 与 flush 超时:把 `comp_supervisor` 的血统长到 `gpu_service` 本身(death hook、重启进同一缓存块);给合成器的 flush 等待加超时,死驱动的丢失回复不得永久 park 它。 | `projects/emo-os/main.emo`(`gpu_service`、`comp_supervisor`)、`gate.emo` | golden 长出「杀驱动 → 它重启 → 屏幕恢复」beat;无 wedge |
| P0.3 | 十分钟 soak:QEMU beats 驱动循环——拖拽、开关窗、launcher、editor、剪贴板——双传输跑。 | `projects/emo-os/run.sh`(或旁边一个 soak 脚本) | 双传输绿:无 `heap gone`、无 wedge、帧账本平稳 |

## P1 — 暗色皮肤(M37;hosted 先行)

| # | 任务 | 位置 |
| --- | --- | --- |
| P1.1 | design tokens 模块:Geist 风中性色阶、壁纸强调色(M31 取色 token 化)、8 px 间距、圆角 6/10/16、阴影/透明度/动效配方(骑 `emo_motion`)。 | `fb/desktop/`(新 module,比如 `emo_skin.emo`) |
| P1.2 | Inter Semibold face——typeface 笔记点名的 drop-in(`outlines.py` 生成,Strike 机制现成)。 | `fb/glyphs/`、`fb/fonts/` |
| P1.3 | chrome 可见字对的 kerning(<14 px 的 hinting 留在 D12 触发器后面)。 | `fb/raster.emo` |
| P1.4 | 统一窗口 chrome:标题栏、控件、tab strip 底座(P2 的地基)。 | `fb/desktop/`、`fb/win/` |
| P1.5 | Dock 与 launcher 几何重排。 | `fb/desktop/` |
| P1.6 | 顶栏状态区与光标族(I-beam、resize 一对——P3 的用户)。 | `fb/desktop/`、`fb/pointer.emo` |
| P1.7 | 可选:明暗 palette 对与切换(noctalia-v5 的折入)。 | tokens 模块 |

完成标准:目标分辨率的启动截图与三窗场景对上设计;goldens 逐
字节;零新增动词。

## P2 — 终端(M38)

| # | 任务 | 位置 |
| --- | --- | --- |
| P2.0 | 拍板终端评估的三问:方案 B 确认、poweroff 语义、counter 出列。先拍后写码。 | 一个决定,然后进 tracker |
| P2.1 | 会话底座:pipes(动词 55–60)与 fork/exec 的 0..2 继承,shell 作为子进程。 | 现有门 |
| P2.2 | 终端窗口:mono cell 网格、strike 直绘(方案 B);tabs、scrollback 环、选择骑 M35 的机制、复制粘贴骑动词 34/35、闪烁骑 frame callback(动词 22)、ANSI 子集(SGR 颜色、光标定位)。 | `fb/apps/terminal/`(新) |
| P2.3 | 多会话——tabs。 | `fb/apps/terminal/` |
| P2.4 | 子进程输出路由——评估点名的内核 Tier C 缺口:先确认 pipe 回读是否够,不够才长动词。 | `projects/emo-os/`(按需) |

完成标准:dock 开 Terminal;`ls`、`cat`、editor 跑通;tabs;复制
粘贴;金属 golden 与 beats。

## P3 — chrome 的行为(M39)

| # | 任务 | 位置 |
| --- | --- | --- |
| P3.1 | `win_resize` 与 resize 事件(Tier C 新增):合成器取新 run、重映射、重绘;app 重排;文档与锁随行。 | `projects/emo-os/gate.emo`、`space.emo`;`syscalls.md`、`desktop-abi.md` |
| P3.2 | 边缘 snap、snap 预览、双击最大化(M16 的基础已在)。 | `fb/desktop/` |
| P3.3 | dock stacks 与 popovers、右键菜单、启动 bounce(行为;动效归 P5)。 | `fb/desktop/` |
| P3.4 | Control Center v1:DND、壁纸、锁、display mode;volume 与 brightness 在各自的轨存在前什么都不渲染(D15)。 | `fb/desktop/` |
| P3.5 | `sys_stats`(Tier C 新增)与顶栏米表。 | `projects/emo-os/gate.emo`;`fb/desktop/` |
| P3.6 | 窗口内菜单原语(v1 不做 top-bar 应用菜单)。 | `fb/desktop/`、`fb/win/` |

完成标准:拖、缩、吸附、最小化、恢复全通;stack 可开;米表实时;
goldens。

## P4 — 系统应用(M40)

| # | 任务 | 位置 |
| --- | --- | --- |
| P4.1 | Settings:外观、accent、壁纸、display、shortcuts、about、lock——provider 走 D14 seam 带 fixtures。 | `fb/apps/settings/`(新) |
| P4.2 | System Info:CPU、内存、uptime、进程、磁盘——吃 `sys_stats`。 | `fb/apps/`(新) |
| P4.3 | About。 | `fb/apps/` |
| P4.4 | Files 与 Editor 换皮;壁纸选择器在预渲染的 RLE 之间挑。 | `fb/apps/files/`、`fb/apps/editor/` |

完成标准:每个 app 都是磁盘 ELF、从 launcher 启动;运行中的 shell
无罐头数据(D15)。

## P5 — 动效预算(M41;测量先行)

| # | 任务 | 位置 |
| --- | --- | --- |
| P5.1 | alpha 与 RLE 壁纸之后重新剖析合成:walk、blit、alpha、shadow、text、transfer、flush,逐项进账本。 | `run.sh` 账本,旁边加探针 |
| P5.2 | 数字点名的优化:opaque fast path、按尺寸缓存 mask/shadow、glyph cache、damage-only 重绘、coalescing、全屏 opaque 直接 scanout;`.S` blitter 只听数字的話。 | `fb/desktop/`、合成器 walk |
| P5.3 | 落地 M32 的停靠对:walk 的 digest 差一;越界座位的 toplevel 挂死 walk。 | `fb/desktop/` |
| P5.4 | 动效补齐:minimize genie、dock 的 hover 与 bounce、toast 滑入、Control Center 的 spring。 | `emo_motion`、壳 |
| P5.5 | Overview(B7)与 Alt-Tab(B8)——先 compact 与 icons。 | 壳、输入层 |

完成标准:1280×800 下 640×480 窗口拖拽 ≥30 fps(800×600 ≥20);
每个动效在预算内;overview ≥15 fps。

## P6 — 材质(M42;决策门)

| # | 任务 |
| --- | --- |
| P6.1 | 缓存 blur:壁纸开机算一次、面板复用缓存、底下窗口移动即失效;downsample-blur-upsample。 |
| P6.2 | glass 的 tint、noise 与边缘高光。 |
| P6.3 | 决策:预算内落地;否则 D15 记录缺席,只发 alpha + scrim。 |

GPU 与多 hart spike 等 P5 的数字;不在本清单的日程上。

## 纪律(每个任务通用)

- hosted 先行、金属验收;双传输逐字节。
- 动词内容移动必须重钉锁。
- 交付前 `@fmt` 绿。
- 金属验证跑本树自己的 `_build` 二进制——PATH 的 `emo` 指向并行
  检出的构建。
- 提交落 develop,听用户的话。

## 起步顺序

P0.2 最先——最小,而且立刻除掉 wedge。接着 P0.1 的探针——硬前置,
诊断先行——P1.1 的 tokens 在 hosted canvas 上并行。P2.0 的拍板可
以搭任何空档;P3.1 是主干的第一次协议增长,等暗色脸钉完再动。
