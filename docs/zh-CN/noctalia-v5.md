# Noctalia v5 与 Emo 桌面 —— 一份调研记录

写于 2026-11-27。本文对着 noctalia.dev 家族的现状——v5 世代——调研:
Emo 桌面要长出 Noctalia 的效果还剩哪些工作。它延伸并收束旧阶梯
[`noctalia-desktop.md`](../noctalia-desktop.md)(那份是对着上一代壳写
的)。这不是已定的设计:文中的里程碑编号都是候选,一个也没开;
M37–M42 仍为 [`unkernel.md`](../unkernel.md) 的路线图保留。

英文版:[`../noctalia-v5.md`](../noctalia-v5.md)。

## Noctalia 的现状

Noctalia 已经不是一个壳。站点自称「一族感觉像一个桌面的原生
Wayland 项目」:

- **Noctalia Shell v5**(约 12.2k star)——bar、launcher、control
  center、锁屏、dock、壁纸驱动的主题。v5 是「壳的新一代,带原生
  运行时」;本树旧阶梯追踪的 Quickshell v4 壳已被上游归档存照,
  仅作参考、不再更新。
- **Umbriel**(约 1.8k)——一个 Wayland 合成器:scrolling、dwindle、
  master、stacking 四种布局,per-output 工作区,窗口规则,blur、
  阴影、流体动效。
- **Luciole**(约 493)——原生 Wayland 文件管理器:grid、list、
  Miller 视图,tabs、split view,永不阻塞窗口的预览,trash、
  undo/redo。
- **Greeter**——greetd 登录屏,镜像会话的壁纸、palette 与字体。

站点目录计 382 个插件(Luau),外加 IPC、事件 hooks、105+ 个发布。
壳跑在各大 Wayland 合成器上——Niri、Hyprland、Sway、MangoWC、
labwc,以及 Umbriel 自己。

### 壳的功能清单

v5 文档的章节,即下面差距分析的对照组:

- **Bars**:任意一边、per-monitor 覆盖,约三十种 widget:clock、
  workspaces、tray、volume、media、battery、bluetooth、brightness、
  network、weather、night light、taskbar、sysmon、clipboard、
  color picker、screenshot、session、theme mode、lock keys、
  keyboard layout、caffeine、power profile、privacy、audio
  visualizer、active window,以及 control-center 与 launcher
  按钮。
- **Launcher**:应用搜索、计算器、emoji picker、壁纸浏览器。
- **Control center**:home 页、侧栏、shortcuts、screen time。
- **Dock**:固定与运行中的应用、指针附近的放大、实例角标与运行
  圆点、点击启动/聚焦/恢复/最小化、逐窗口右键动作、拖拽排序、
  auto-hide 与 smart auto-hide(工作区有窗口时藏)、exclusive zone
  或 overlay 层、向支持的合成器发布 blur 区域。
- **桌面 widget**:桌面上的 widget,带编辑模式与状态文件。
- **壁纸**:明暗目录、填充模式、per-monitor 选择、定时轮换、十二种
  切换特效(fade、wipe、disc、stripes、zoom、honeycomb、vortex、
  pixel、diamond、golden、melt、crt)、收藏,以及给 overview 用的
  模糊加色 backdrop 副本。
- **Theme 与 palette**:内置主题、壁纸取色、明暗模式、palette 角色、
  自定义 palette 文件、终端配色;为终端、编辑器、浏览器生成的
  app 主题。
- **Services**:audio、battery、bluetooth、brightness、calendar、
  idle、location、night light、notifications、system monitor、
  weather。
- **桌面表面**:OSD、截图、session 菜单、窗口切换器(Alt-Tab,四种
  样式——carousel、compact、grid、icons——带 MRU 排序、最小化窗口
  可选)、剪贴板、锁屏。
- **扩展**:IPC 命令、事件 hooks、Luau 插件。

### Umbriel、Luciole、Greeter

Umbriel 的效果集(blur、阴影、动效)与布局家族(scrolling、dwindle、
master、stacking;窗口规则)是合成器机制。EmoOS 的合成器是内核
服务,所以 Umbriel 是「效果想要什么」的参考,永远不是移植对象。
Luciole 与 Greeter 的 Emo 对应物已经站着——files 应用、锁屏——见
下面的清单。

## 旧阶梯的现状

[`noctalia-desktop.md`](../noctalia-desktop.md) 写于 2026-11-12,对着
Quickshell 时代的壳。它的三级此后全部落地:

1. **视觉语言**——M30(alpha 地基:`win_format` 的 ARGB8888 与
   walk 的 source-over;形状服务:逐表面的 radius 与 softness)与
   M31(壁纸的 RLE 画作、给 chrome 上强调色与材质的取色、给 dock、
   launcher 与通知换装的图标族)。
2. **动效层**——M32(`emo_motion.emo`:方衰、镜像、spring;焦点的
   扫入、launcher 的弹跳、pager 的滑移;D13 保持工作区切换是硬切)。
   两个动效停靠在 found-not-fixed:dock 的 hover 与 toast 的滑入
   (walk 的 digest 差一;越界座位的 toplevel 挂死 walk)。
3. **修饰键**——M33 的修饰格与美国布局的上层(编辑器的 Ctrl+S 与
   Ctrl+Q),M36 的 Alt 层在所有 app 之下(Alt+1..4 到 panel
   持有者)。

blur 仍是 stretch goal,audio 在自己的轨上(D20)。那份笔记定义的
阶梯已基本走完;剩余工作对着的是 v5 的清单,而 v5 已经长过了它。

## Emo 侧基线

M13–M36 在金属上全部站立:真字体的 HD 脸、圆角阴影的半透明
chrome、dock、launcher 枚举与锁屏(M28)、带 toast、历史与
do-not-disturb 的通知(M25)、时钟与日历(M26)、四个工作区与
pager(M27)、皮肤地基(M30)、动效词表(M32)、编辑器的 caret 与
修饰键(M33)、剪贴板(M34)、选区(M35)、全局快捷键层(M36)。
开着:B7(overview)、B8(Alt-Tab)、两个停靠动效、blur、audio 轨
(D20)、network(D21,出界)、tray(D22,退役)。Step 17 给显示
驱动自己的 2 MiB run——它的 arena 之死不再楔死合成器——但驱动仍
没有 supervisor、没有 flush 超时,而且 app 在长会话后仍死于自己的
~200 KiB arena,直到 value-kind 消息泄漏(T8.7)被修。

[`unkernel.md`](../unkernel.md) 为它的 P0–P6 路线图保留了
M37–M42:稳定性地基、暗色脸、Terminal、chrome 的行为、系统应用、
动效预算、材质。

## 差距清单

### 已在轨——P0–P6 的车道

| Noctalia 效果 | 落点 |
| --- | --- |
| 不会死的会话 | P0(泄漏、驱动的 supervisor 与超时、soak) |
| 暗色脸、Semibold、kerning | P1 / M37 |
| 终端 | P2 / M38——它的配色白 riding palette |
| resize、snap、control center、顶栏米表(`sys_stats`) | P3 / M39 |
| Settings、System Info、About | P4 / M40 |
| dock 的 hover 与 bounce、toast 滑入(M32 停靠对) | P5 / M41 |
| 窗口切换器(B8)与 overview(B7) | P5 / M41——四种样式里先做 compact 与 icons |
| 每个动效背后的帧预算 | P5 / M41——先重新剖析,再按 D12 的节拍 |
| blur 与 glass 材质 | P6 / M42——缓存 blur |

### 新候选——M43 及以后,一个未开

按性价比排序:

1. **明暗模式。** M31 的取色模块就是 seam:第二套 palette、切换、
   chrome 重着色。便宜;自然并进 P1。
2. **壁纸选择器与轮换。** 壁纸现在是开机解码的单张 RLE;
   `list_dir` 枚举、选择器在预渲染的 RLE 之间挑、定时轮换,
   crossfade 是帧预算内唯一的切换特效。PNG 与 JPEG 解码是独立的
   编解码轨——不为这个开。
3. **桌面 widget。** panel 角色与壳的表面就是地基;带编辑模式的
   widget 是壳层工作,零新动词。
4. **launcher 计算器与剪贴板历史。** 纯 Emo,骑在已有动词上
   (34 与 35);几乎白送。
5. **session 菜单。** 壳里已有 poweroff;logout 与 restart 是围着
   它的面板。
6. **截图 verb。** 合成器把 carve 区域经文件系统服务落盘;QEMU
   monitor 的 `screendump` 已证明管线的另一半。
7. **Night light。** 合成时逐通道的整数色温乘法;小的合成器特性。
8. **Idle 与息屏。** virtio-gpu 没有 DPMS;一张覆盖表面或停掉的
   scanout 加计时器——小的内核件。
9. **Files v2**(Luciole 的对应物)——grid 与 list 视图、tabs、
   trash;独立的应用工作包,可选。
10. **开机锁屏**(Greeter 的对应物)——锁屏的账户文件与脸已有
    (M28);开机进锁屏而非 shell 是 boot 流改动,可选。

### 被别的轨卡住

- **audio 的整个家族**——volume 与 media widget、OSD 的音量一半、
  audio visualizer——都等 audio OS 轨(D20):virtio-sound 驱动、
  mixer 服务、verb 家族。这是对着 Noctalia 清单最大的一块单项缺席。
- **亮度**——QEMU `virt` 无背光;按 D15 缺席。
- **天气、network、bluetooth、battery**——network 出界(D21);
  其余无硬件。缺席,且可见(D15)。

### 非目标

- **Luau 插件系统。** EmoOS 的扩展故事已经存在:app 是说门与
  mailbox 的磁盘 ELF。不做壳内脚本运行时。
- **Umbriel 的布局与窗口规则**(scrolling、dwindle、master、
  stacking)。合成器机制,不是效果;EmoOS 的合成器按设计是浮动式。
  定位问题,另日再议。
- **emoji picker**——字形覆盖是字体轨的成本,与这个 widget 不成
  比例。
- **多输出与一切 per-monitor**——单输出;OS 轨。
- **分数缩放**——`win_scale` 只收整数倍,ARGB 行拒绝它(blend 与
  缩放还不是同一次 walk)。Tier B 增长,以后。
- **App 主题模板**(gtk、emacs 之流)——EmoOS 上没有第三方工具包;
  给 chrome 上色的 palette 就是对应物,Terminal 的配色经 P2 骑它。

## 顺序

处处一样:P0 最先。明暗对并进 P1。给 P3 的 control center 留 D15
占位——volume 与 brightness 在各自的轨存在前什么都不渲染。B7、
B8 与停靠动效在 P5,blur 在 P6。把便宜的 M43 候选——选择器、桌面
widget、计算器、剪贴板历史、session 菜单——打成一个桌面丰富度
里程碑;截图、night light 与 idle 作为小件跟上。audio 是唯一值得
开的 OS 侧家族,而且要等桌面的脸站在 P0 的地基上。tiling 问题、
多输出与分数缩放在效果被搬完之前保持关闭。

## 参考

- <https://noctalia.dev> ——家族页面;
  <https://docs.noctalia.dev> ——v5 文档(`noctalia/`、`umbriel/`、
  `greeter/`、`luciole/`)。
- [`noctalia-desktop.md`](../noctalia-desktop.md) ——旧阶梯;各项
  已落地,笔记本身已带 v5 更新注记。
- [`unkernel.md`](../unkernel.md) ——P0–P6 路线图;M37–M42 保留。
- 桌面:
  [`README.md`](../../projects/emo-desktop/README.md)、
  [`docs/TASKS.md`](../../projects/emo-desktop/docs/TASKS.md)
  ——M13–M36、B7、B8、M32 的停靠对;
  [`docs/typeface.md`](../../projects/emo-desktop/docs/typeface.md)
  ——Semibold drop-in、D12 触发器。
- 机器:
  [`docs/TASKS.md`](../../projects/emo-os/docs/TASKS.md)
  ——Step 17 的稳定性记录;
  [`docs/syscalls.md`](../../projects/emo-os/docs/syscalls.md)
  ——动词 10–35 与 55–60。
