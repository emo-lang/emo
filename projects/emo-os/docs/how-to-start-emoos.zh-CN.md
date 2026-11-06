# 如何启动 EmoOS

从干净的检出走到机器的提示符的步骤,以及提示符应答的命令。机器本身是 README 的主题、各设计笔记的题材([`shell.zh-CN.md`](shell.zh-CN.md)、[`ui.zh-CN.md`](ui.zh-CN.md)、[`fs.zh-CN.md`](fs.zh-CN.md)、[`sv39.zh-CN.md`](sv39.zh-CN.md));本页只讲怎么开它。

英文原文:[`how-to-start-emoos.md`](how-to-start-emoos.md)。

## 前提

- **`qemu-system-riscv64`**——QEMU 的 RISC-V 系统模拟器。macOS 上 Homebrew 的 `qemu` formula 自带;Linux 上发行版的 `qemu-system-misc`(或等价包)提供。
- **OCaml + dune**——构建编译器用一次。仓库钉住 opam switch `5.5.2`。

编译器是一个自包含的二进制。在仓库根目录:

```console
$ export PATH="$HOME/.opam/5.5.2/bin:$PATH"
$ eval "$(opam env --switch=5.5.2 --set-switch)"
$ dune build src/emo_cli/emo.exe
```

二进制落在 `_build/default/src/emo_cli/emo.exe`;下面的步骤按路径调它。想用 README 里更短的 `emo` 拼法,就把它放进自己的 `PATH`。

## 两个镜像

EmoOS 是同一个编译器构建的两个 Emo 程序:用户镜像(shell 与机器的程序住在里面)与内核镜像——后者在自己的构建里嵌入用户的 ELF。用户镜像在 syscall stub 之外还依赖桌面的几个包(emo-desktop A7.2:EmoUI 核心、fb backend 核心、第一帧),而一次构建只从一个 registry 解析依赖,所以这些包要和 stub 一起先 stage 进一个目录——`start.sh` 构建前自己会做(它的 `registry` 函数就是文件清单);手动做的话,stage 同样的文件,再把 `EMO_REGISTRY` 指向该目录。在 `projects/emo-os/` 下:

```console
$ (cd hello && EMO_REGISTRY=<staged 好的 registry> \
     ../../../_build/default/src/emo_cli/emo.exe build main.emo \
     --target riscv64 --profile user -o ../hello.elf)
$ (cd ../emo-desktop/fb/apps/counter && EMO_REGISTRY=<registry> \
     ../../../../_build/default/src/emo_cli/emo.exe build main.emo \
     --target riscv64 --profile user -o "$OLDPWD/counter.elf")
$ (cd ../emo-desktop/fb/apps/files && EMO_REGISTRY=<registry> \
     ../../../../_build/default/src/emo_cli/emo.exe build main.emo \
     --target riscv64 --profile user -o "$OLDPWD/files.elf")
$ (cd ../emo-desktop/fb/apps/editor && EMO_REGISTRY=<registry> \
     ../../../../_build/default/src/emo_cli/emo.exe build main.emo \
     --target riscv64 --profile user -o "$OLDPWD/editor.elf")
$ ../../_build/default/src/emo_cli/emo.exe build main.emo --target riscv64 \
     -o main.elf
```

用户镜像先建:内核的构建要汇编 `user.S`,而它嵌入 `hello.elf` 与三个应用的 ELF(emo-desktop A11.1)——它们都得先于内核链接存在。改了 `hello/`、应用的树、内核自己的模块或 stage 进去的那些包之后,五个镜像都按这个顺序重建。

## 金测一条龙

```console
$ ./run.sh
```

`run.sh` 是验证,不是 ride。它把盘镜像清零并启动机器两次——第一脚遇到空盘、格式化它,第二脚挂载第一脚留下的卷,所以两脚是一个故事——第一脚用 SBI `set_timer` 兜底驱动 tick,第二脚用 `stimecmp` 传输。每脚跑完整条串口链(启动、各证明、启动机器程序的 shell 对话、文件系统往返、exit 路由)并断言每行的存在与顺序;缺一行或乱序即失败。合成器移动后的拷贝落地时,监视器的 screendump 拿下显示器的 PPM,每个像素按合成历史的并集读回——金测不止有耳朵,还有眼睛(T8.8)。连续三轮逐字节相同,是追踪器里每个任务被要求的线。

## 手动驾驶

`start.sh` 把本节收进一条命令:镜像缺失或过期时先构建,盘缺失时创建(`--fresh` 把卷换成一张空盘),**自动喂过证明链的各扇窗口**——与金测断言的同一批节拍——一路启动到桌面;提示符处终端就是 REPL 的控制台。`--hand` 保留手动 ride,下面的手动步骤供任何想亲手开的人用。

盘是 4 MiB 裸镜像。文件系统在首次挂载时格式化空盘、跨启动保留文件,所以建一次,想要全新卷时再重建:

```console
$ dd if=/dev/zero of=.blk.img bs=4194304 count=1
$ qemu-system-riscv64 -machine virt -display cocoa -serial mon:stdio \
    -global virtio-mmio.force-legacy=false \
    -drive file=.blk.img,format=raw,if=none,id=emoos-blk \
    -device virtio-blk-device,drive=emoos-blk \
    -device virtio-gpu-device,xres=1024,yres=768 \
    -device virtio-keyboard-device \
    -device virtio-tablet-device \
    -kernel main.elf
```

机器的屏幕是 cocoa 窗口——金测 screendump 断言的同一块显示器(T8.8),键盘之所以在列,是因为输入服务的扫描在缺 DeviceID 18 时响亮告终——串口控制台仍是终端(`-serial mon:stdio` 保住 `-nographic` 原有的复用;Ctrl-A C 到 QEMU 监视器)。OpenSBI 的 banner 走过,内核在自己建的表上分页启动(`sv39 8 0x…` 行),块设备与文件系统各自报到——然后链条在去桌面的路上多次停顿等键。**桌面合成之前,屏幕上一直是 boot 自己的一次性渐变 flush**——那些条带颜色是机器在等它的钥匙,不是故障。各扇窗口按序如下:

- **文件系统的挂载行过去之后敲五个键**——控制台服务的投递测试从线上读五个字节(`abcde` 的应答是 `0:97` … `4:101`);
- **`gate 500500 r3 r2` 行出现后敲一个键**——读证明会在控制台上阻塞直到存在一个字节(`echo 88` 是对 X 的应答);
- **计数器的面板上了窗口之后敲它的键**——屏幕趟经 EmoUI 的 Elm 循环跑桌面的计数器(emo-desktop A8.3):`a` 加、`b` 减,每个键重画一帧并在串口上说出它的 digest(`frame …`、`present ok`),`q` 结束循环;键敲在串口控制台而不是窗口里,其余字节一律丢弃;
- **`keys?` 出现后敲两个键**——合并流的证明:先 `q` 再 `K`(第一个应答按键节拍,第二个应答字节节拍——线上是 `byte 75`);
- **鼠标在 QEMU 窗口里划过一次**——指针平面的第一次落位(线上 `pointer 512 384`);
- **窗口合成落定后敲 `c`**(线上 `win 0`);
- **客户端 fault 的节拍过后敲 `c`**(线上 `addr 0x20000000`,几秒后是重生客户端的帧);
- **再敲一次 `c`,然后 `client back` 之后敲 `z`**;
- **desk 时代敲 `q`**——屏幕上是两个窗口(`alpha`、`beta`);壳的退出在线上是 `desk 0`。

计数器之前的四条击杀报告是证明链在做它的工作——失控的趟独自死掉(其中一条死于自己分配器的耗尽)、机器继续——不是故障。然后桌面合成——壁纸、顶栏、dock 与卷上的图标(emo-desktop A13)——横幅与提示符抵达(`O` 与 `S` 以 ANSI 青色抵达):

    _____                      ____     ____
   | ____|  __  __    ____    / __ \   / ___|
   |  _|   |  \/  |  / __ \  | |  | |  \___ \
   | |___  | |\/| | | |  | | | |__| |   ___) |
   |_____| |_|  |_|  \____/   \____/   |____/

    emo-os>

在这三个窗口之外敲的键不是简单地丢掉。OpenSBI 在自己运行时排空 UART,它剩下的字节留在 FIFO 里,直到内核的驱动收走——字节晚些时候按序冒出来,喂给下一个读者:证明链的应答变得不对,shell 的第一条命令前面缀着它们。只在窗口里敲,只敲窗口要的量。

提示符应答九个命令,小写、精确匹配:

| 命令 | 效果 |
| --- | --- |
| `help` | 列出九个 |
| `echo TEXT` | 把文本原样打回 |
| `ls` | 一行一个列出卷上的文件 |
| `cat NAME` | 打印文件的字节 |
| `write NAME TEXT` | 让文件成为文本的字节;成功时安静 |
| `rm NAME` | 删除文件;成功时安静 |
| `counter` | 启动机器的程序——控制台渲染器:帧画在控制台上,`a`/`b` 加减,`q` 回到提示符 |
| `exec NAME.elf` | 在桌面上启动一个磁盘 ELF——dock 的 tile 是同一扇门的点击形态 |
| `poweroff` | 结束机器——exit 路由的 `dma` 行与 frames 账目,然后 QEMU 自己退出 |

`write`/`ls`/`cat`/`rm` 是文件系统的往返——文件在盘上、跨 poweroff 存活。会话以别的方式结束:**Ctrl-A X** 杀掉 QEMU。

默认的 QEMU CPU 没有可委派的 Sstc,所以 tick 走 SBI `set_timer` 兜底——无需任何配置;双定时器传输是 `run.sh` 钉的。

## 接着读什么

- [`docs/TASKS.md`](TASKS.md)——追踪器:机器做什么,逐任务、各带引脚。
- [`docs/shell.zh-CN.md`](shell.zh-CN.md)——REPL:行、命令、表面携带的严格性。
- [`docs/ui.zh-CN.md`](ui.zh-CN.md)——`counter` 命令启动的控制台渲染器。
- [`docs/fs.zh-CN.md`](fs.zh-CN.md)——文件系统:磁盘布局、重启语义。
- [`docs/sv39.zh-CN.md`](sv39.zh-CN.md)——地址空间、trampoline、缺页击杀。
- [`docs/syscalls.zh-CN.md`](syscalls.zh-CN.md)——门:上面每个字节骑的动词。
