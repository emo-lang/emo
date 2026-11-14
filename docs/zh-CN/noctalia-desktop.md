# Noctalia 桌面阶梯

noctalia 桌面已经站在什么之上,以及桌面要长出名字所许诺的那种精致效果——半透明面板、壁纸给自己的 chrome 上色、图标、动效——还必须哪些开发。阶梯按层组织;每一项都标注它的依据(对应
[`projects/emo-desktop/docs/assessment.md`](../../projects/emo-desktop/docs/assessment.md)
里的决定,或
[`projects/emo-desktop/docs/TASKS.md`](../../projects/emo-desktop/docs/TASKS.md)
里它所延伸的里程碑),文末的顺序是建议,不是日程。

产品宿主是金属——EmoOS 跑在 riscv64 上,效果底下没有 Linux(D13)。sway/Wayland 轨是快速开发回路(hosted 秒级、grim 截图、注入按键,对上金属 591 秒的开机),不是产品地基;皮肤层落在 Emo 侧(fb 包)和内核合成器里,不取 harness 任何东西。harness 笔记里点名的 layer-shell 缺口是 harness 自己的账,永远不是金属的。

## 已经站着的

骨架和礼仪已经在金属上:

- **HD 脸面**(M14,A14 线):1080p、chrome 材质、壁纸彩带、共享标题栏、搁架与绘制图标、抗锯齿指针——以及圆角和阴影,画进 app 自己的像素里。缺的是**皮肤**:效果作为每个窗口共享的服务,不是每个 app 重画的技巧。
- **动效的第一份词表**(M15,EmoOS T10):窗口的 rise/sink,八帧缓动;damage 矩形(T10.1)——窗级重绘 ~36 ms,对上整屏合成的 ~230 ms;还有 frame callback(动词 22),合成本身就是动画的节拍。
- **系统数据层的前三个模块**:通知——toast、历史、DND(M25,D16);挂钟和日历(M26,D17);workspace(M27,进行中——内核侧已落地,bar 的 pager 和金属拍未开)。

所以剩下的工作不是结构,是密度:皮肤和动效。

## 阶梯

### 1. M27 收口

bar 的 pager(A27.2)和金属拍与文档(A27.3)。workspace 管道落了一半;这条轨收口之前,别的都不骑它。

### 2. M28——launcher 与锁屏(D19)

launcher 枚举盘上的 Emo 包,把名字交给搜索面;锁屏查一个 hash 文件——永久答案,没有 PAM 可挂认证(D19)。壳面最后两块结构件,launcher 也是图标族的第一个舞台。

### 3. 视觉语言——皮肤层

精致效果的主杠杆,一个里程碑族,四级台阶,每一级骑上一级:

1. **逐像素 alpha 合成**。blit 今天是字拷贝,卡片只能画成不透明(A25.3 自己的笔记)。`win_format` 词表长出 ARGB8888;合成器的 walk 长出 src-over 混合。这是其余三级站的地基——半透明面板、popover、柔和阴影都是 alpha 的消费者,不是各自的特性。
2. **阴影与圆角成为服务**。它们今天存在,但是画进像素的;提升到合成器,就成了每个窗口的——第三方 app 也算——不费任何 app 的力,walk 围着它已经搬运的 buffer 画出来。
3. **壁纸解码与取色**。一个 PNG 解码器(stdlib,或桌面自己的 codec 包)填满壁纸的 surface;取色喂给 chrome——accent 和材质今天是固定常量,而 Noctalia 的一体感,正是壁纸自己的颜色替它们作答。诚实的成本:纯 Emo 的 inflate 解一张 1080p 图,金属开机要花秒级;备选是盘上带预转换的 raw(或 RLE)形态,解码器的活下机做一次。
4. **图标族与壳面重装**。给 launcher、dock 和通知中心一套栅格化的图标 strike(`outlines.py` 字体先例再跑一遍),panel、popover 和 toast 换上 alpha、圆角与阴影的材质。

### 4. 动效层

全是壳面自己的活,骑 frame callback——动词已经齐了:workspace 切换的过渡(滑动或交叉淡化——合成器长一点小支持,或者硬切、壳面只动画 chrome;开这一项时拍板)、toast 滑入、popover 弹跳、dock 悬停、焦点移动。诚实的上限和它们站在一起:全屏 60 fps 动画不是 TCG 能给的,动画走窗口尺寸的矩形,沿用它已经赖着的 damage 纪律。

### 5. seat 的修饰键

app 的 byte 表现在不带修饰键——编辑器的保存骑 `s` 键,不是 Ctrl+S(A25.2 点名的 follow-up)。workspace 快捷键(super 加数字)是第一个消费者;内核小加一件,input service 长出跟踪,键盘就加入了 chrome 的词表。

## 阶梯留开的两个拍板

- **blur(背景模糊)**。Noctalia 的招牌,而软件合成器上的逐帧高斯超出 TCG 诚实的射程。可行的形态是小面板的静态模糊——开面板时算一次,缓存到它底下的像素变化为止。scrim 加 alpha 已经扛了八成的像;blur 留作 stretch 目标,等 alpha 层落地、成本测得出来,而不是猜。
- **audio**。媒体控件、音量和它的 OSD 骑 audio OS 轨(D20),已 parked——virtio-sound 驱动、混音服务和动词族是独立的 OS 立项。精致效果的主干不倚赖它们,缺席保持可见(D15):没有 audio,就不渲染音量控件。

## 顺序

M27 收口 → M28 → 视觉语言族(alpha、壁纸取色、图标与重装)→ 动效层 → 修饰键。audio 轨独立站着,等它存在再回头;网络在阶梯上没有位置(D21),托盘已经退役(D22)。
