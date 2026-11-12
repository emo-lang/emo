# `wayland` 包

纯 Emo 的 Wayland 客户端协议,骑在 `net` 的 Unix 套接字之上:程序连上
compositor、bind 它点名的 global、经 `wl_shm` 共享像素、应答
compositor 发来的事件——编解码器、接口表、状态机都在包里,不在每个
程序的 socket 循环里。这是 noctalia 轨道通向真实 Wayland 世界的门:
Emo 程序落在真实 compositor 上的第一帧,走的就是这个包。

## 引入

```emo
require "wayland"
require "net"
require "os"

case net.connect_unix(path, 5.0) {
  (R.error, why) -> { println(why) }
  (R.ok, raw) -> {
    const c = wayland.conn_of(raw)
    case wayland.handshake(c) {
      (R.error, why) -> { println(why) }
      (R.ok, globals) -> { /* globals.find("wl_compositor") ... */ }
    }
  }
}
```

`wayland.connect(path, timeout)` 用自己开的套接字包同一套舞步;
`conn_of` 包装一个已打开的套接字(测试替身起步的形状)。包只声明
`c`:Unix 套接字、fd 传递、shm 层都在 c target 的运行时里,其余
target 在解析期拒绝本包(sqlite3 先例)。

## 线格式

编解码器就是协议自己的语法,写在哪就在哪用:8 字节消息头(对象 id、
opcode、size——小端)、参数编码(int32、uint32、fixed 24.8、带 NUL
与 4 字节补齐的字符串、new_id、array),以及经真实 compositor 评分的
fd 规则:**fd 在参数流里不占任何字**——它走套接字带外(SCM_RIGHTS),
按语法点名的顺序排队,`Args.fd` 从队列里认领。构造器对线格式的规矩
从严:越界的值、超 u16 的尺寸、第二条 fd、空队列上的 fd 认领——各自
直接 raise,因为每一条都是线会用乱码来回答的错误。

`Message` 构造请求或事件;`finish` 打上 size 字,交出字节和随行的
fd。`Args` 按接口语法点名的顺序解码一帧;`Side` 是套接字的一端——
每次读都过 recvmsg(丢掉带外数据的读是那种静默的丢失),帧式只归它
管一份,客户端与测试替身共用。

## 接口表

客户端要说的接口,opcode 数字写在调用点:`wl_display`、
`wl_registry`、`wl_callback`;窗口树生长起点的 `wl_compositor` /
`wl_surface` 一对;`wl_shm` 和它的 pool、buffer;以及 `xdg-shell`
家族(`xdg_wm_base`、`xdg_surface`、`xdg_toplevel`)——协议要求的
"先 configure 后 commit"纪律在 `wait_configure` 里结构化:签名说清
它消费什么(toplevel 自身的 configure 置于一旁,ping 用 pong 作答,
交还的 serial 是 ack 和 commit 的执照)。

表是手写的——运行时不解析任何 XML——而 smoke 腿就是真实 compositor
给它们打分的地方:sway 用自己的错误事件点名了两处错的 opcode 和一个
缺掉的请求(`create_positioner` 在 1,`get_xdg_surface` 在 2;
`ack_configure` 在 4;wl_surface 家族比直觉高一位,`destroy` 在 0)。

## 线上的严格性

传输层的真相用 `(R.error, reason)` 回答,reason 以 `wayland:` 开头:
半截读、对端断在帧中、小于头部的 size 字、display 错误事件(其消息
原样带出)。一帧谎报自己的参数长度属于协议损坏,响亮 raise——静默地
错位四个字节,是一根线绝不该粉饰的那一种失败。

## 画像素

pool 的客户端一生是三步:`os_shm_open`(路径上一份出生即 unlink 的
私有文件——macOS 与 Linux 上都可 seek 可 mmap;macOS 的 POSIX shm
对象干脆拒绝 read 和 pwrite)、`os_ftruncate`、`os_pwrite`——像素走
pwrite,compositor 去 mmap,Emo 表面上不存在 mmap。demo 驱动的作画
序列就是本里程碑的梯子:handshake、按广告版本 bind、surface、xdg
surface、toplevel、标题、空 commit、等 configure、ack、逐行 pwrite
的 pool、attach、damage、第二次 commit。

## 输入

seat 的那半边线:`wl_seat`(绑 v5——指针的 frame 家族与键盘的
`repeat_info` 都在内),以及它授出的 `wl_pointer` / `wl_keyboard`
(`seat_get_pointer` / `seat_get_keyboard`)。指针的事件(enter、带
fixed 24.8 窗面坐标的 motion、button、frame 家族)与键盘的事件
(**keymap 的 fd 走事件方向的带外队列**——同一个 `Args.fd` 认领,
字节经通道读回;enter/leave、key、modifiers)都从同一个 `Args`
游标解码。seat 的请求有门:capabilities 广告点名 pointer 之前,
sway 拒绝 `get_pointer`——授权要等 capabilities 事件。

smoke 腿端到端给这些表打分:demo 绑定 sway 广告的
`zwlr_virtual_pointer_manager_v1` 与 `zwp_virtual_keyboard_manager_v1`
global,经 shm 层涂一份最小 xkb_v1 keymap,对自己的窗口注入
motion、左键、按键——事件原路返回,脚本逐条断言。这条腿教了两课:
以线上的 null seat 出生的虚拟指针是 sway 注册了却永不路由的设备
(带 seat 出生的键盘能路由,指针不能);compositor 的光标状态滞后
于它的窗口事务——节拍由指针的 enter 事件触发,那个词说明光标状态
已跟上。

驭用示例的指针长出了点击路径:`LiveInput` 从 motion 事件里记着
指针的窗面坐标,一次按下跑调用方的矩形表——`(x, y, w, h, tag)`,
第一个包含它的矩形获胜——于是桌面的 dock 可以点击:demo 画桌面
脸面(`emo_desktop` 的壁纸、头部、dock——dock 的条带局部公式经一
个带偏移的 Surface 包装落位),点一个 tile 交付它的 tag,焦点移动,
重绘。方向键移动焦点,Enter 切换启动位,smoke 腿断言点击、方向键
与启动——桌面活着,点击落了,按键驱动了它。

内容是一棵树时,这张表不再手写(M22):`ui_fb` 的绘制走查带一个
矩形收集器(`ui_fb.paint_rects`),每放一个 Button,它就带着
registry 发给视图的 tag 落进表里——一帧的像素和它的点击目标出自
同一次走查——demo 把启动的应用树画进窗内,导出的矩形并入指针表
(带应用的 tag 基数)。点树自己的 "+" 便驱动应用自己的
`update`(quiet backend 之上立着的 `ui.App`,语料 counter 从
`emo/ui_apps` 整包 require):计数动了,应用自己的话骑上转录,
smoke 腿钉住导出的矩形行与两次点击。

按键如今出自 keymap(M23):`keymap` 事件的 fd 走通道读回,解析
一次——keycodes 段的 `<AD01> = 24;` 条目,symbols 段的两种拼写
(编译后 keymap 穿的那两种),每一次搜索都被行自己的花括号框住
——`name_of(key, shift)` 答出 keysym 名,compositor 对这颗键自己
的说法。keymap 说的 keycode 是 xkb 的:**evdev 加八**,每个
Wayland 客户端问 xkb 前都跳的这支舞(注入的 Enter 骑 evdev 28;
keymap 的 `<RTRN>` 是 36)。demo 的 tag 表按名配键——"Left"、
"Right"、"Return"——M19 demo 手写的 evdev 行退役;smoke 腿的活
keymap 是 sway 自己的(编译后的,490 个码、117 行符号,全部解
析),按键按名交付。

窗口随后就来(M24):一次启动把应用立成第二个 toplevel——自己的
surface、自己的 xdg surface、自己的 shm pool、自己的 configure
等待(`wait_configure` 容忍 seat 自己的事件与兄弟窗的
configure——多于一扇窗之后两者都会在等待中途到达)——而
`LiveInput` 变成一台译码器,答出的 `Ev` 带着事件所属的窗面:键盘
enter 命中的那面、指针悬停的那面。路由是调用方的事:桌面的名字
驱动 dock,窗的名字驱动它背后的应用,rect 表按窗各一张(每次重
绘都重新导出它的树按钮)。seat 的焦点是指挥——`wl_keyboard.enter`
点名每颗键骑去哪面窗,语料应用的键表就用 keymap 产出的那些名字
(编辑器打字的 "a"、"b"、"Return")——指针点击带着它落点的窗面。
smoke 腿往编辑器窗口里打字,在计数器窗口上计数,全部活在 sway
之下。

## 局限

- **只有一个 target。** 只有 `c`;解释器的 fd 传递 stub(OCaml 运行时
  的 Unix 模块没有 sendmsg)是点名的后续。
- **一条消息一个 fd。** 本包要说的协议恰好都只带一个;哪天某个协议
  要两个,再长这个形状。
- **keymap 是个专注的读者,不是 xkb。** 解析器取 keycodes 与
  symbols 两段的朴素行——sway 编译后 keymap 穿的形状——答头两个
  符号;group、头两级以外的 level、types 与 compat 段都不建模。
- **第二扇窗的指针归 compositor 路由。** demo 往立起的应用窗里
  点的指针在 sway 1.7 headless 下没有送达(键盘的焦点路由是送达
  的,同一矩形机制在 M22 于桌面自有窗面上已证);后续是换更新的
  sway 重试,若复现,便是这个差异点名要问的协议问题。
- **手写表。** opcode 活在调用点,由 compositor 打分;运行时不解析
  XML。

## 驭之:活窗口

活应用需要的桥很小,而且骑在 Elm 循环自己的缝上:一个 `Surface`,其
`present()` 把画布字节经 `os_pwrite` 推进 pool,attach、整幅
damage、commit(画布的 XRGB8888 字就是 wl_shm 的字节原样);一个
`Input`,其 `next()` 阻塞在 Wayland 事件上,把应用说的 tag 递出去
——按键经 compositor 自己的 keymap 翻译(keymap 事件时解析,
shift 状态读自 modifiers 事件,其第一个参数是 serial、depressed 在
第二),点击经矩形表在指针位置上命中。自 M24 起,demo 是一个多窗
客户端:桌面的 dock 加每启动一个应用一扇窗,各有自己的 pool 与
buffer、自己的 rect 表,seat 的焦点决定哪个 `ui.App` 接住这颗键或
这次点击。fb 后端的示例让收敛语料自己的应用活在一个真实
compositor 上:注入的按键、真实的重绘、转录里每一帧的 digest
(`projects/emo-desktop/wayland/`,smoke 腿
`devtools/wayland-face-smoke.sh`)。

## 示例

- `examples/wayland_wire`——编解码器对手算 fixture,字节级。
- `examples/wayland_handshake`——真 Unix 套接字上的 mock
  compositor,逐字节。
- `examples/wayland_paint`——第一帧,由 `devtools/wayland-smoke.sh`
  驱动:Docker 腿编译 demo 的 C,在 headless sway 下实跑,grim 当
  眼睛。
- `examples/wayland_input`——对罐头流检验 seat 的表:capabilities、
  指针、键盘、keymap 的 fd 走通道。
- `examples/wayland_inject`——smoke 腿驱动活窗口的虚拟设备:节拍即
  一个事件数组。
