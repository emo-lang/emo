# Noctalia 桌面阶梯

noctalia 桌面已经站在什么之上,以及桌面要长出名字所许诺的那种精致效果——半透明面板、壁纸给自己的 chrome 上色、图标、动效——还必须哪些开发。阶梯按层组织;每一项都标注它的依据(对应
[`projects/emo-desktop/docs/assessment.md`](../../projects/emo-desktop/docs/assessment.md)
里的决定,或
[`projects/emo-desktop/docs/TASKS.md`](../../projects/emo-desktop/docs/TASKS.md)
里它所延伸的里程碑),文末的顺序是建议,不是日程。

**更新(2026-11-27)。** 本阶梯追踪的上游已经换代:Quickshell 的
v4 壳已归档存照,noctalia.dev 现在是带原生运行时的 v5 壳,旁边还有
合成器(Umbriel)、文件管理器(Luciole)与登录屏(Greeter)。本阶梯
的三级已全部落地——视觉语言(M30、M31)、动效层(M32,两个动效
停靠)、修饰键(M33 的修饰格,M36 的 Alt 层)——blur 仍是
stretch goal,audio 在自己的轨上(D20)。v5 的功能清单与剩余差距
记录在 [`noctalia-v5.md`](noctalia-v5.md)。

产品宿主是金属——EmoOS 跑在 riscv64 上,效果底下没有 Linux(D13)。sway/Wayland 轨是快速开发回路(hosted 秒级、grim 截图、注入按键,对上金属 591 秒的开机),不是产品地基;皮肤层落在 Emo 侧(fb 包)和内核合成器里,不取 harness 任何东西。harness 笔记里点名的 layer-shell 缺口是 harness 自己的账,永远不是金属的。

## 已经站着的

骨架和礼仪已经在金属上:

- **HD 脸面**(M14,A14 线):1080p、chrome 材质、壁纸彩带、共享标题栏、搁架与绘制图标、抗锯齿指针——以及圆角和阴影,画进 app 自己的像素里。缺的是**皮肤**:效果作为每个窗口共享的服务,不是每个 app 重画的技巧。
- **动效的第一份词表**(M15,EmoOS T10):窗口的 rise/sink,八帧缓动;damage 矩形(T10.1)——窗级重绘 ~36 ms,对上整屏合成的 ~230 ms;还有 frame callback(动词 22),合成本身就是动画的节拍。
- **系统数据层的五个模块**:通知——toast、历史、DND(M25,D16);挂钟和日历(M26,D17);workspace(M27,D18——动词、walk 的过滤、bar 的 pager、金属的指派拍全部 grade 过);launcher 的枚举与搜索面(M28,D14 的接缝与卷上自己的 `.elf` 名);锁(M28,D19——帐户文件的摘要、不透明面背后接管的会话)。
- **alpha 地基**(M30,A30.1,阶梯的第一级):`win_format` 的 ARGB8888 与逐字拷贝路径并存,walk 的逐像素 source-over——launcher 的面板是金属上第一块 ARGB 面,它的 slab、caret 与行就是缓冲自身的直 alpha 真相,合成在壁纸的字节上;金标的四张脸在各 hosted 目标逐字节同钉。
- **形状服务**(M30,A30.2,阶梯的第二级):`win_shape` 的逐面 radius 与 softness——行未声明时 toplevel 带缺省的 10 和 16,其余角色穿裸矩形——walk 的带掩模带影路径长到每个角色,damage 的盒子跟随表面自己的影环。词表与走查已落;金属拍的词是下一个任务的。

所以剩下的工作不是结构,是密度:皮肤和动效。

## 阶梯


launcher 枚举盘上的 Emo 包,把名字交给搜索面;锁屏查一个 hash 文件——永久答案,没有 PAM 可挂认证(D19)。壳面最后两块结构件,launcher 也是图标族的第一个舞台。

### 1. 视觉语言——皮肤层

精致效果的主杠杆,两个里程碑现已收口——M30 = alpha 地基与形状服务,M31 = 壁纸之艺与图标——皮肤层的四级台阶全部落地(2026-11-20):

1. **逐像素 alpha 合成(M30,A30.1)**。声明 XRGB 的面保持字拷贝;`win_format` 词表长出 ARGB8888,合成器的 walk 长出 src-over 混合——逐像素的成本只落在声明的面上。依赖问题已由构造解决:walk 每次合成迭代整个栈,damage 盒只裁剪存储。这是其余三级站的地基——半透明面板、popover、柔和阴影都是 alpha 的消费者,不是各自的特性。
2. **阴影与圆角成为服务(M30,A30.2)**。算术自 T9.2 起就是 walk 自己的——每个 toplevel 圆角 10、阴影 16——服务即词表:逐面的 radius 与 softness,popup、subsurface、panel 戴上只有 toplevel 戴过的东西,不费任何 app 的力。
### 2. 动效层——已编号(M32),站立

缓动词表是桌面包自己的了(`emo_motion.emo`:rise 走过的方衰、镜像、spring),壳面的动效骑在 damage 纪律赖着的窗口尺寸矩形上:焦点的到来在窗条上四帧扫入,启动器面板八帧弹跳落座,workspace 的 pager 强调块跨格滑过条面(D13——硬切保留,chrome 动画)。金属上停靠、画师与钉行站立:dock 悬停与 toast 滑入(走查的 digest 差一、越界座位的 toplevel 挂死 walk——found-not-fixed,M32 的记录)。

### 3. seat 的修饰键

app 的 byte 表现在不带修饰键——编辑器的保存骑 `s` 键,不是 Ctrl+S(A25.2 点名的 follow-up)。workspace 快捷键(super 加数字)是第一个消费者;内核小加一件,input service 长出跟踪,键盘就加入了 chrome 的词表。

## 阶梯留开的两个拍板

- **blur(背景模糊)**。Noctalia 的招牌,而软件合成器上的逐帧高斯超出 TCG 诚实的射程。可行的形态是小面板的静态模糊——开面板时算一次,缓存到它底下的像素变化为止。scrim 加 alpha 已经扛了八成的像;blur 留作 stretch 目标,等 alpha 层落地、成本测得出来,而不是猜。
- **audio**。媒体控件、音量和它的 OSD 骑 audio OS 轨(D20),已 parked——virtio-sound 驱动、混音服务和动词族是独立的 OS 立项。精致效果的主干不倚赖它们,缺席保持可见(D15):没有 audio,就不渲染音量控件。

## 顺序

视觉语言族(alpha、壁纸取色、图标与重装)→ 动效层 → 修饰键。audio 轨独立站着,等它存在再回头;网络在阶梯上没有位置(D21),托盘已经退役(D22)。
