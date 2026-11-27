# `syscall` 包

EmoOS 门的用户侧:机器裸 `ecall` 之上的带类型 Emo 表面,也是用户程序
看得见的唯一内核边界。这不是托管的 `os`——它应答 EmoOS 内核,并且只
准入 `riscv64` 目标(`targets = ["riscv64"]`)。ABI 契约——越界方式、
门的校验、应答约定——在内核的
[`projects/emo-os/docs/syscalls.zh-CN.md`](../../../projects/emo-os/docs/syscalls.zh-CN.md);
本页讲包的这些名字,以及每个名字应答什么。

目标:`["riscv64"]`。

## 使用包

```emo
require "syscall"
```

标准库随编译器一起发布,但它的包和其他包一样带版本:`require "syscall"`
需要 manifest 的 `deps` 块里有 `"syscall" = "0.1.0"`。用
`emo build --target riscv64` 构建镜像;其余目标在解析阶段拒绝这个包,
解释器拒绝它骑的 `ecall` 内建。

## 应答约定

内核在一个寄存器里应答:`>= 0` 是载荷,`< 0` 是拒绝的原因。每个可能
失败的门都把它包进标准库的元组——`(R.ok, payload)` 或
`(R.error, reason)`——由 `why_of` 点名原因:

| 应答 | 原因文本 |
| --- | --- |
| `-2` | `outside the caller's memory` |
| `-3` | `not writable` |
| `-4` | `bad argument` |
| `-5` | `the kernel is out of a resource` |
| `-6` | `no such file` |
| 其他 | `unknown verb` |

拒绝是应答,不是故障:调用者的寄存器完好,执行在 `ecall` 之后继续。
有两个门不是这种可失败形状——`read` 与 `input_read` 返回裸 `Int64`——
而 `exit` 从不返回。

缓冲是调用程序自己内存里的裸地址,门在读写之前先检查它们:落在程序
段之外的缓冲是 `outside the caller's memory`,落在没有所需权限的段里
是 `not writable`。

## 进程与控制台

```emo
def exit(code Int64) Void                       // verb 0
def write(buf Int64, len Int64) (R, Int64)      // verb 1
def read() Int64                                // verb 2
def input_read() Int64                          // verb 12
def spawn() (R, Int64)                          // verb 3
def wait(pid Int64) (R, Int64)                  // verb 4
def exec(name Int64, name_len Int64) (R, Int64) // verb 24
def exec_args(name Int64, name_len Int64, args Int64, args_len Int64) (R, Int64)                 // verb 48
def exec_args_env(name Int64, name_len Int64, args Int64, args_len Int64,
                  env Int64, env_len Int64) (R, Int64)                                           // verb 48
def execve(name Int64, name_len Int64, args Int64, args_len Int64,
           env Int64, env_len Int64) (R, Int64)                                                  // verb 54
```

- **`exit`** 结束调用进程。根的 exit 结束整台机器;被 spawn 的进程的
  exit 应答它父进程的 `wait`。从不返回。
- **`write`** 把 `buf` 处的 `len` 字节送到内核控制台,应答字节数。门
  最多暂存 2048 字节。
- **`read`** 应答控制台的下一个字节(0–255),没有字节时阻塞。
- **`input_read`** 应答机器合并输入流里的下一个事件,没有事件时阻塞。
  事件打包进一个词:类型在 bits 48–63(0 分隔符、1 按键、2 相对移动、
  3 绝对移动、`0x454D` 机器的字节事件),code 在 bits 32–47,value 在
  bits 0–31。这条流把 virtio-input 设备的事件与串口控制台的字节合在
  一起,字节在前;一次只有一个读者。
- **`spawn`** 在一副新栈上、从这个程序的顶层启动新进程;镜像的常量
  就是它的常量,所以子进程靠第一个进程的常量知道自己是子进程。应答
  子进程的 pid 号。
- **`wait`** 阻塞到点名的子进程退出——pid `0` 或负数表示调用者的
  第一个子进程——并应答子进程的状态字。wire 把子进程的 pid 装在状态
  之上;包装把它掩到低 32 位,所以状态就是退出码(在最低字节之上)或
  信号死亡时的信号号。
- **`exec`** 把 `name` 处 `name_len` 字节点名的 ELF 从卷上加载成独立
  镜像与进程;应答子进程的 pid 号。
- **`exec_args`** 是带参数的 `exec`:参数文本(至多 512 字节,按空格
  切分)落在子进程的第一副栈上,成为 `argv[1..]`,`argv[0]` 是名字。
- **`exec_args_env`** 在同一暂存页上再加环境文本。
- **`execve`** 原地替换调用者的镜像:调用者保留 pid,成为新镜像。成功
  时从不返回。

## 文件

文件是按名字的整文件:名字是 `name` 处的 1–24 字节,不含 NUL 与换行。

```emo
def file_write(name Int64, name_len Int64, buf Int64, len Int64) (R, Int64)   // verb 6
def file_read(name Int64, name_len Int64, buf Int64, cap Int64) (R, Int64)    // verb 7
def file_list(buf Int64, cap Int64) (R, Int64)                                // verb 8
def list_dir(name Int64, name_len Int64, buf Int64, cap Int64) (R, Int64)     // verb 45
def file_remove(name Int64, name_len Int64) (R, Int64)                        // verb 9
```

- **`file_write`** 把文件变成 `buf` 处的 `len` 字节(至多 2048),替换
  同名文件;应答字节数。
- **`file_read`** 把文件的字节落到 `buf`,至多 `cap` 字节,并应答文件
  大小——大小超过 `cap` 表示缓冲不够。
- **`file_list`** 把名字逐个加换行落到 `buf`,应答写入的字节数。
- **`list_dir`** 把点名目录的直接子项落到 `buf`——类型字节(0 文件、
  1 目录)、长度字节、名字——应答写入的字节数。根是空名字。
- **`file_remove`** 删除文件,应答 0。

没有文件持有的名字是 `no such file`;写满的盘或名字表是
`the kernel is out of a resource`。在文件系统服务从一个实例换到下一个
之间发出的请求,等下一个实例。

## 时钟

```emo
def time() (R, Int64)   // verb 29
```

自 Unix 纪元以来的秒数(UTC),由门自己从板上的 goldfish RTC 读出。
门从不拒绝这个动词。

## 桌面协议

合成器的表面,由 `desktop_version` 协商——一个词,`1`,即动词 10–35
所携带的协议。

```emo
def desktop_version() (R, Int64)                                  // verb 23
def win_frame() (R, Int64)                                        // verb 22
def present(grant Int64, x Int64, y Int64, w Int64, h Int64) (R, Int64)   // verb 10
def output_info(index Int64) (R, Int64)                           // verb 11
def input_info(index Int64) (R, Int64)                            // verb 18
```

- **`desktop_version`** 锚定协商;动词集的增加从不移动这个词。
- **`win_frame`** 让调用者驻留,应答下一次合成的完成——动画据以自
  走节拍的那一帧脉冲。virtio-gpu 没有 vblank;合成就是机器的脉冲。
  四个驻留排满一圈是 `the kernel is out of a resource`。
- **`present`** 提交 grant 点名的缓冲:damage rect `(x, y, w, h)` 就是
  设备取走的、也是扫描输出显示的矩形,传输与 flush 都在应答之前完成。
  grant id 0 是屏幕 carve 的;调用者必须是内核授权表点名的持有者。
- **`output_info`** 应答第 `index` 个输出的矩形,宽度在 bits 32–63,
  高度在 bits 0–31。
- **`input_info`** 应答第 `index` 个指针设备的轴最大值,X 在 bits
  32–63、Y 在 bits 0–31——绝对上报按此缩放到显示的那段范围。

### 窗口缓冲

```emo
def win_new(w Int64, h Int64) (R, Int64)            // verb 13
def win_close(grant Int64) (R, Int64)               // verb 14
def win_focus(grant Int64) (R, Int64)               // verb 15
def win_move(grant Int64, x Int64, y Int64) (R, Int64)        // verb 16
def win_role(grant Int64, role Int64) (R, Int64)    // verb 17
def win_parent(grant Int64, parent Int64) (R, Int64)          // verb 19
def win_format(grant Int64, format Int64) (R, Int64)          // verb 20
def win_scale(grant Int64, scale Int64) (R, Int64)            // verb 21
def win_shape(grant Int64, radius Int64, softness Int64) (R, Int64)   // verb 33
def win_minimize(grant Int64) (R, Int64)            // verb 25
def win_desk_open(pid Int64) (R, Int64)             // verb 26
```

- **`win_new`** 分配窗口缓冲,并按物理地址的身份映射进调用者自己的
  表。应答把基址的帧号装在 bits 32–63、grant id 装在 bits 0–31;要
  绘制的字节地址是帧号左移 12 位,grant id 是其他窗口门点名称呼缓冲
  的凭据。
- **`win_close`** 把这段运行归还分配器,并丢弃 grant。
- **`win_focus`** 点名合成器把输入路由到的窗口。
- **`win_move`** 设置合成把窗口帧 blit 到的位置。x 按 blit 的词粒度
  (偶数)对齐;对显示模式的边界判断是合成器的事。
- **`win_role`** 声明表面的角色:`0` toplevel、`1` popup、
  `2` subsurface、`3` panel、`4` wallpaper。词汇表已冻结,而且全部角色
  都已实现:toplevel 独立,popup 与 subsurface 相对父面
  (`win_parent` 绑定父面),panel 是走栈最顶的条带,wallpaper 是每个
  窗口之下的桌面画布(一台机器只有一份)。没有声明角色的缓冲在每个
  表面动词上都遇 `bad argument`;同一表面的第二次声明、第二份
  wallpaper 也一样;对 wallpaper 调 `win_focus` 同样被拒。栈满为
  `the kernel is out of a resource`。
- **`win_parent`** 把 popup 或 subsurface 绑到它挂靠的 toplevel:自此
  它的位置就是父面的,自身坐标相对,父面死亡时随之而去。调用者必须
  拥有两个 grant。不接受父面的角色(toplevel、panel)是
  `bad argument`。
- **`win_format`** 记录调用者绘制的像素格式:XRGB8888(`0`)是第一个
  接受的值,ARGB8888(`1`)是第二个——走栈对 ARGB 行逐像素做
  source-over 合成,缓冲的 alpha 字节即形状。合成器不携带的格式按其
  号码拒绝。
- **`win_scale`** 设置合成携带缓冲时遵循的倍数:过 1 的整数以该倍数
  携带,最近邻;低于 1 是 `bad argument`,ARGB 行上的 scale 同样是
  `bad argument`(混合与缩放还不是同一条走栈)。
- **`win_shape`** 设置合成器的掩模与阴影所穿的 radius 与 softness;
  未设置的行携带 toplevel 的 `10` 与 `16`。radius 为零是裸矩形,也是
  其他角色的形态(词自身的含义:剥掉 toplevel、给 panel 整形);
  softness 为零是只有掩模没有影环。过 255 的值为 `bad argument`。
  形状在声明时绑定;第二次调用即参数拒绝。
- **`win_minimize`** 把 toplevel 移出合成器的走栈,保留其条目(位置与
  grant)供恢复使用。不是 toplevel、或已隐藏的 grant 是
  `bad argument`。
- **`win_desk_open`** 是桌面的打开:该 pid 拥有的窗口被抬到栈顶并成为
  焦点,隐藏的先取消隐藏。调用者必须拥有一个 panel——桌面的权威是
  面板,不是窗口的归属。

### 工作空间与通知服务

```emo
def win_workspace(grant Int64, desk Int64) (R, Int64)   // verb 30
def desk_show(desk Int64) (R, Int64)                    // verb 31
def desk_workspace() (R, Int64)                         // verb 32
def notify(title Int64, tlen Int64, body Int64, blen Int64) (R, Int64)   // verb 27
def notify_take(buf Int64, cap Int64) (R, Int64)        // verb 28
```

- **`win_workspace`** 把调用者的 toplevel 换到另一张桌面;桌号界为
  `0..3`,走栈只在它现在点名的桌面上画这个窗口。
- **`desk_show`** 是壳的切换:点名桌面的窗口上屏,离桌者记住自己的
  焦点,进桌者恢复自己的。调用者必须拥有一个 panel。
- **`desk_workspace`** 应答打包的桌面字——低字节是当前桌面,其上是
  占用掩码,只要活的 toplevel 还背着这张桌,该位就置着。
- **`notify`** 排队一条通知:`title` 处的标题 1–64 字节,`body` 处的
  正文 0–192 字节。服务保留八条已发起、尚未取走;队列满为
  `the kernel is out of a resource`,由调用者在壳排空之后重试。应答
  通知的 id(≥1)。
- **`notify_take`** 把至多一条打包通知落到 `buf`:先 24 字节的头
  (id 在 0、标题长度在 8、正文长度在 16),然后是标题与正文字节;
  应答打包大小。空队列应答 0。第一个取者成为通知中心的所有者,之后
  别的 pid 取者为 `not writable`。

## 剪贴板

```emo
def clip_set(buf Int64, len Int64) (R, Int64)   // verb 34
def clip_get(buf Int64, cap Int64) (R, Int64)   // verb 35
```

- **`clip_set`** 用 `buf` 处的 `len` 字节整体替换剪贴板;`len` 为 0
  清空,超过剪贴板页 4096 是 `bad argument`。写入者必须是焦点表面的
  属主——即复制键到达的那个应用——所以后台调用者是
  `not writable`。门在 trap 内完成拷贝,剪贴板永远不会只装半个选区。
- **`clip_get`** 把剪贴板的字节尽可能多地落到 `buf`(至多 `cap`),
  并应答拷贝的字节数。读取是任何进程的。

## 示例

桌面自己的程序就是现成的例子:
`projects/emo-desktop/fb/apps/files/main.emo` 打开窗口、用 `present`
绘制缓冲、用 `input_read` 读输入流;`projects/emo-desktop/fb/winbuf/`
是完整的合成器客户端。
