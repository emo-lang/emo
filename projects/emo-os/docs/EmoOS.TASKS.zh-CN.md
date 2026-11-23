# EmoOS 与 Linux 生态——任务追踪

开于 2026-11-23。这个 tracker 是生态计划自己的:EmoOS 作为 Linux 开源软件的编译目标。内核的历史仍留在 [`TASKS.md`](TASKS.md);本文件只记录这条线。

英文原文:[`EmoOS.TASKS.md`](EmoOS.TASKS.md)。

## 决定

**B 方案——源码移植。** Linux 软件针对 EmoOS 重新编译,靠一套 EmoOS 的 C 库;不做 Linux syscall ABI,也不做预编译二进制兼容。A 方案——加载 Linux ELF、应答 Linux syscall 编号的 Linux personality——按决定排除。门自己的动词就是 ABI;C 库是唯一说这些动词的一层,生态靠重编到达,不靠模拟。

理由就是这台 OS 建立时的理由:EmoOS 拥有一条窄而明确的边界。Linux personality 会用第二条大得多的边界(fd、`fork`、COW、信号、TLS、动态链接)替换它,微内核的隔离叙事会是第一个牺牲品。libc 移植保持一条 ABI,并按需要生长。

## 契约

- **工具链。** 第一阶段先在宿主机上交叉编译:`riscv64-elf-gcc`;之后是 `riscv64-emos` 的 sysroot 与包装器。自举编译是后期里程碑,不是前提。
- **装载。** C 用户程序和 Emo 用户镜像用同一个窗口 `0x87100000` … `0x88000000`,以 `PT_LOAD` 段链接,入口在窗口内。内核的 exec 装载器已经在强制这一条(`exec.emo` 的 `measure`)。
- **BSS。** exec 装载器只拷贝段的文件字节,尾部留给分配器给的零;程序自己的 `crt0` 清 `__bss_start` … `__bss_end`,与 Emo 入口桩的纪律一致。
- **可写暂存。** 门动词 1(`write`)要求源段可写——引导证明的 `gate 500500 r3 r2` 钉住了它。所以 C 的 `write` 经一个可写 bounce buffer 拷贝;之后的某条任务可以让门接受只读源,但必须先把证明和金测重新钉住。
- **不假设 libc。** 库说到的每个 syscall 都由内核实现,并随落地写进 [`syscalls.md`](syscalls.md);库绝不伪造成功。
- **按需生长。** syscall 集合在程序需要时增加,不从 Linux 表整张抄。M4 的软件清单就是检验:它点名系统真正要跑什么。

## 里程碑

### M0——C 的门(进行中)

最小的纵向切片:一个 C 程序、交叉编译器、现有的 exec 装载器、机器的控制台。它在任何 libc 工作之前先证明工具链契约。

- [x] **T0.1**——C 骨架:`c/crt0.s`、`c/emo_syscall.h`、`c/hello.c`、`c/chello.ld`、`c/build.sh`(桩用 `.s` 而不是 `.S`:Emo 包树会汇编它找到的每个 `.S`);ELF 形状对着 `exec.emo` 的 `measure` 检查(入口与段都在窗口内、只有 `PT_LOAD`、`memsz ≥ filesz`)。
- [x] **T0.2**——构建链:`start.sh` 在内核之前构建 `chello.elf`;`user.S` 嵌入它,`runtime.S` 停放它的边界,`main.emo` 把它作为 `chello.elf` 装到卷上,安装行加入金测清单。
- [x] **T0.3**——真机证明:桌面的 `exec chello.elf` 打出那一行并以 0 退出;退出事件静默排空(外来镜像没有启动器槽位)。
- [ ] **T0.4**——dune 冒烟:临时树带上 `c/` 并在内核之前构建 C 应用;测试套件的门加上交叉编译器自己的探测。(代码已接好;`@emo_os` 那条腿自己的运行是剩下的引脚。)

### M0 的记录(2026-11-23)

第一份镜像是 `chello.elf`:9,288 字节,入口 `0x87100000`,两个 `PT_LOAD` 段(text RX 在 `0x87100000`,data RW 在 `0x87101000`),消息放在 `.data`,因为门的 write 动词从可写段拷贝。真机证明:桌面的 `exec chello.elf` 打出 `hello from C on EmoOS`,提示符回来;首启的线上说 `installed chello.elf 9288`。路上发现并修掉两处碰撞:Emo 包树会汇编 `projects/emo-os` 下的每个 `.S`,所以 C 的桩叫 `crt0.s`;树里按 basename 只能有一个 `link.ld`,所以 C 的脚本叫 `c/chello.ld`。金测会装上这份镜像,文件计数随之移动(首启重启后挂载 7 个,第二脚挂载 8 个,`fs ls 8`);exec 的那一拍等一次重新钉住 frame 账目的金测运行。

### M1——POSIX 底座(内核与库)

每个 C 程序站立的那一层。任务只在第一个消费者提出时落地,但顺序就是依赖顺序。

- [ ] **T1.0**——门的 write 规则:可读的源段就应当服务 `write`,让 libc 的 bounce 拷贝退休。引导证明和金测随之重新钉住——`gate 500500 r3 r2` 的第一个拒绝不再点名 text 段,它变成一次成功。
- [x] **T1.1**——C 库里的 fd 表:0/1/2 接控制台;按名字的文件上的 `open`/`close`/`read`/`write`/`lseek`/`fstat`,走门的整文件动词;每进程一张表,偏移与缓冲归库,写缓冲到 close 才提交。切法写明:文件装进门的 2048 字节暂存,写打开的描述符替换整个文件。
- [x] **T1.1k**——文件系统服务的打开文件表:句柄按 pid 归属,偏移与大小归服务,部分读写、追加、超过门 2048 字节的文件;句柄区放在自己的一页上,重启的 `abandon` 清掉它。
- [x] **T1.2**——C 库的路径层:根、相对与绝对路径、`.` 与 `..`、进程的 `cwd`、`mkdir`/`rmdir`/`stat`/`rename`、`opendir`/`readdir`/`closedir`,都建在卷的平铺名字上。目录就是标记名 `dir/` 与它前缀下的名字;24 字节的平铺名上界就是切法,更长的路径答 `ENAMETOOLONG`。
- [x] **T1.2k**——服务里的真目录条目:名字条目 `+56` 的类型字(0 文件、1 目录)、`path_type`/`mkdir`/`rmdir` 作为动词 42..44,C 库改用它们。隐式目录——前缀下的名字——仍答为目录,所以平铺年代的卷继续可用。
- [x] **T1.2d**——桌面的类型化列举:动词 45 `list_dir` 带类型字节,图标与文件夹视图读它,`desk_view_build` 的前缀分组退休。启动器 `.elf` 目录仍读平铺列表。金测自己的运行是剩下的引脚;启动壁纸与两个写节拍的 frame 摘要已手动对上。
- [x] **T1.3**——内存:进程 arena 上的 `brk`/`sbrk` 与匿名私有 `mmap`/`munmap`/`mprotect`——用户运行的十六个 64 KiB 块,1 MiB。动词 46 以页号暴露 base/end;C 库的 bump 分配器拥有 break,越过 arena 的写仍是原来的缺页。
- [x] **T1.3k**——分配器的复用:`malloc` 的 first-fit 空闲表与 `mmap` 的页空闲表——`free` 与 `munmap` 交还块,`malloc` 与 `mmap` 复用它们,`realloc` 拷贝;1 MiB 的 arena 是边界。
- [x] **T1.3v**——arena 长过 1 MiB 的运行:动词 47 `arena_grow(bytes)` 取整 64 KiB 块,映射在单元末尾之后的页上,增长表的行在死亡时走回家——shim 的 fault/heap 路径与进程服务的正常 exit。库的 `arena_extend` 跟随应答。
- [x] **T1.4a**——`exec` 的 `argv`:动词 48 `exec_args(name, args)` 把行的余下文本停在 execargs 页,进程服务的 exec 拾取构建孩子的第一张栈(argc、argv——名字然后各个词——argv 的 NULL 与 envp 的 NULL),C crt0 从 cells 页读 args base 并把 `argc`/`argv`/`envp` 交给 `main`,桌面的 `exec` 把行的余下传给子进程。envp 目前为空。
- [x] **T1.4b1**——进程与环境的表面:`getpid`(动词 49)、`setpgid`/`getpgid`(50/51,增长页尾每 pid 一个组字节,0 表示 pid 自己的组)、`getenv`/`setenv`/`unsetenv` 与 `environ`(第一次使用时扫描 `main` 的 envp),以及库的 `wait4`/`waitpid` 走动词 4——退出状态 `code << 8`。任意子进程的 wait 随 T1.4b2;`exec` 的环境交接随 T1.4b3。
- [x] **T1.4b2**——`fork`(动词 52):进程服务复制调用者的镜像运行、栈块、arena 运行与增长块,映射到新表里调用者的虚拟基址,复制私有 handoff 页(保存的上下文与父进程基址在页尾),从库的恢复 trampoline 启动孩子;孩子从 `fork` 返回 0,父进程返回孩子的 pid。wait 的目标与 exit 的码搬到每 pid 的单元(共享的一对会让后到的 exit 覆盖 wait 的参数);动词 4 答孩子的 pid 在其退出码之上,任意子进程的 wait 是按父单元扫退出表,或由第一个孩子的退出应答停泊的 wait。C 库长出 `fork`(汇编上下文保存)、`exit`/`_exit` 与 `wait4` 的打包应答。
- [x] **T1.4b3a**——fork 的描述符:库的 fd 表现在在 `used` 旁携带名字、标志与偏移;孩子第一次访问继承来的 fd 时以自己的 pid 重开该名字并 seek 到复制的偏移(O_APPEND 保留服务的末尾,O_CREAT/O_TRUNC 丢弃)。描述的偏移与父进程分叉——在服务拥有共享描述之前,这是记录在案的近似。
- [x] **T1.4b3b**——`execve`(原地换镜像):动词 54 停名字、argv 文本与 envp 文本;进程服务在新栈与新 arena 上装载新镜像,新的运行时 `user_replace(pid, entry, stack, arena, arena_end)` 回收调用者的旧镜像、栈、arena 与增长块,把同一个槽位打扮成新帧并调 build 钩子——同一个 pid 跑新程序,父/组单元不动,旧 fd 被丢弃(库自己的表是新的——记录里的缺口)。C 库的 `execve`/`execv` 把 `argv[1..]` 与 `envp` 摊成门的空格分隔文本(词里带空格是 EINVAL);新镜像的 `argv[0]` 是文件名,`envp` 是调用者的。替换后库的 fd 表与 cwd 是新的,旧页表与私有页泄漏——记录里点名的后续。
- [x] **T1.5**——管道:`pipe`、`dup2`、阻塞读、最后一个写者关闭时的 EOF。动词 55..60(绑定、读、探测、写、复制、关闭),进程服务的第二条臂:门把每个请求停进调用 pid 在 `.emo_pipe` 请求页上的记录并路由;服务独占全部改动,环空而写者还在时把读者停泊,环满时把写者停泊,凭关闭时的最后持有者计数唤醒对端——最后一个写者的关闭是 EOF,最后一个读者的关闭是断管。库的 `pipe`/`dup`/`dup2` 与描述符种类缓存(每个 fd 探测一次)把两端藏在 POSIX 调用后面;端跨 `fork` 复制,低三个跨 `execve` 留下,所以 shell 的 `cmd1 | cmd2` 就是两个孩子与两次 `dup2`。
- [x] **T1.6**——信号:基本集合、处置、`kill`、`sigaction`/`sigprocmask`、shell 读的状态编码。动词 61..65(kill、处置、掩码、trampoline 的返回、待决字),门自己的——没有服务在中间。八个信号,默认/忽略/处理器三种处置;处理器靠重写 resume 将要恢复的 trap 帧运行,它的返回是 trampoline 页的 `sig_return` ecall,把被打断的帧与掩码放回。默认处置结束进程(SIGCHLD 的默认是忽略),wait 的状态字变成 POSIX 的(退出的 `code << 8`,信号致死是信号编号),孩子退出竖起 SIGCHLD,断管竖起 SIGPIPE。

### T1.1 的记录(2026-11-23)

C 库的 fd 表是 `c/emo_posix.c`:16 个描述符、8 个 2048 字节的文件槽,fd 0 走动词 2,fd 1/2 走动词 1(可写 bounce),文件读在 open 时经动词 7 整份装入,写在 close 时经动词 6 提交,`unlink` 走动词 9。`errno` 映射门的理由(6→ENOENT、3→EACCES、2→EFAULT、5→ENOSPC、4→EINVAL)。真机证明:`chello.elf`(10,384 字节)打开 `fd.txt`、写、关、重开,`fstat` 答 `stat ok`,读答 `read back: fd table on EmoOS`,`unlink` 答 `fd table cleaned`;之后卷上没有 `fd.txt`。切法是库的:偏移与缓冲每进程一份,写在 close 时替换文件,文件装进 2048 字节。`T1.1k` 把表搬进文件系统服务,换部分 I/O 与更大的文件。

### T1.1k 的记录(2026-11-23)

文件系统服务现在拥有打开文件表:自己的一页(`link.ld` 的 `.emo_vfs`,在 `0x8700e000`),三十二个 96 字节的句柄,按 `(pid, fd)` 归属——标志字、偏移与大小、名字。门长出动词 36..41(`fd_open`、`fd_close`、`fd_read`、`fd_write`、`fd_lseek`、`fd_fstat`);它们搭文件系统原有 6..9 的路由族,用槽里 `+88` 的标记点名 fd 表,所以 shim 的路由没有增长。服务在部分写时逐扇区合并旧数据,字节之后提交名字表——整文件写的顺序,在偏移上。`O_APPEND` 从大小处开始;`O_CREAT` 与 `O_TRUNC` 是空写;重启丢掉整张表(`abandon` 调 `handles_clear`)。C 库缩成 fd 编号与可写 bounce。

路上发现:门的缓冲检查覆盖镜像的段,不覆盖进程栈,所以库读进 `.bss` 的 bounce 再拷出——这是控制台路径本来就有的理由,现在写明,而不是撞上。

真机证明:`chello.elf`(10,336 字节)答 `stat ok`、`read back: fd table on EmoOS`、`fd table cleaned`;首启线上是 `installed chello.elf 10336`、`fs gen 2 files 7`、`fs ls 8`。

### T1.2 的记录(2026-11-23)

路径层在 `c/emo_posix.c` 里:`resolve` 把路径对着 `cwd` 规范化(跳过 `.`、`..` 弹栈、开头的 `/` 从根开始)成卷的平铺名;`mkdir` 写零长的标记 `dir/`,`rmdir` 要求它为空,`unlink` 拒绝它,`rename` 经 fd 层拷贝,`stat` 用零容量读探大小,`opendir`/`readdir` 解析门的换行列表,给出直接子项(去重、跳过标记本身)。切法是 24 字节平铺名加标记目录;`T1.2k` 把真条目搬进服务。

真机证明:`chello.elf`(19,816 字节)答 `stat ok`、`read back: fd table on EmoOS`、`fd table cleaned`、`path ok`、`dir listing ok`、`rename ok`、`vfs cleaned`;跑完卷上仍是八个文件。

### T1.2k 的记录(2026-11-23)

类型字是名字条目 `+56` 的 `c_type`——0 文件、1 目录;它之前的卷那里是零,就是它一直意味的文件。服务答 `path_type`(动词 42:类型条目,或隐式目录的前缀)、`mkdir`(43:显式条目,父必须是目录,已存在的名字拒绝)、`rmdir`(44:类型条目、为空、移除);`write_file` 与 `remove_file` 拒绝目录条目。fd 与路径动词共用请求槽和它的 `+88` 标记,所以 shim 的路由仍停在 6..9 族。C 库的存在检查改为问服务,`mkdir`/`rmdir` 归服务。

C 程序里的 `dir` 是真类型条目;shell 与桌面一直在写的 `a/one.txt` 隐式名字仍作为隐式目录工作。桌面的前缀视图没动——T1.2d 接管它自己的类型化列举。真机证明:`chello.elf`(19,840 字节)答 `stat ok`、`read back: fd table on EmoOS`、`fd table cleaned`、`path ok`、`dir listing ok`、`rename ok`、`vfs cleaned`。

### T1.2d 的记录(2026-11-23)

服务的类型化列举是动词 45 `list_dir`:命名目录的直接子项,每个是类型字节(0 文件、1 目录)、长度字节和名字,按名字表顺序去重,隐式目录也算。桌面的 `desk_list_load` 同时装启动器的平铺列表与当前文件夹的类型化列表;`desk_view_build` 解析类型化记录(前缀分组退休),`desk_icons_refresh`/`desk_icon_press` 在视图或文件夹移动时重载类型化列表,`.elf` 目录仍读平铺列表。syscall 包就地长出 `list_dir`;它的五个 lock 重新钉住(`hello`、`counter`、`files`、`editor`、`winbuf`)。

真机证明:桌面启动写出 `comp 0 0 884125748`(金测的壁纸引脚)、`desktop icons 2`、`desktop apps 5`;`write note.txt shell wrote this` 答 `frame 624477878`,`write a/one.txt first inside` 答 `frame 1586168726`——两个都是金测的引脚,类型化视图的像素与前缀视图一致。文件夹 screendump 自己的金测运行仍是引脚(这里没跑)。

### T1.3 的记录(2026-11-23)

arena 是用户运行的十六个 64 KiB 块——1 MiB,不是初稿写的 64 KiB——由 `space.build` 映射在它的物理身份上;build 知道子进程的 pid,直接把它按 pid 的单元(proc 页的后半,`0x8700d800`)写成 base/end 的页号——没有服务拷贝,也没有共享单元可赛跑。动词 46 `arena_info` 答调用者的单元。C 库的 `mem_init` 解页号;`brk`/`sbrk`/`malloc`/`free`/`realloc`/`mmap`/`munmap`/`mprotect` 都建在它的 bump 分配器上;这一刀里 `munmap` 与 `mprotect` 是 arena 的空操作(T1.3k 让 `munmap` 交还页),越过末尾的写仍是原来的缺页。

路上发现:最初的打包把物理地址放进各自的一半——arena 的第 31 位让 ecall 的应答变成负数,shim 把它读成路由,合成器说 `the verb is nobody's (24)`。现在打包的是页号(base 高 20 位,end 低 20 位)。

真机证明:`chello.elf`(20,376 字节)在 `stat ok`、`read back: fd table on EmoOS`、`fd table cleaned`、`path ok`、`dir listing ok`、`rename ok`、`vfs cleaned` 之后答 `heap ok` 与 `mmap ok`;调试运行的 arena base 是 `0x84550000`,`sbrk(0)` 答它。

### T1.3k 的记录(2026-11-23)

初始 arena 是 1 MiB(用户运行的十六个 64 KiB 块);初稿的“64 KiB”是运行里每个块的单位。库的分配器现在有两张 first-fit 空闲表:`malloc` 的 16 字节头块(`free` 交还,`malloc` 复用并拆掉剩余)与 `mmap` 的页块(`munmap` 把节点写回,`mmap` first-fit 它),`realloc` 拷贝后释放。固定运行是边界;长过它是 T1.3v(帧、页表新增映射、死亡回收)。

真机证明:`chello.elf`(20,536 字节)答 `heap ok`、`mmap ok`、`reuse ok`、`mmap reuse ok`。

### T1.3v 的记录(2026-11-23)

增长是动词 47 背后的 `space.grow`:字节数、帧分配器背书的块、单元末尾之后的页——每个块在它自己的物理身份上,虚拟页跟着长——行放在 `0x8700f000` 的 `.emo_grow` 页(200 个 `(pid, block)` 行,计数在页首;T1.4a 的 execargs 页在页尾)。`space.grow_reap` 把某 pid 的行走回家;shim 的 fault/heap 路径在 `emo_arena_reap` 之后调它,进程服务的 exit 为正常退出调它。库的 `arena_extend` 请求该动词,把应答的页并进 `heap_end`,`brk`/`sbrk`/`malloc`/`mmap` 在下一字节越界时调它。

路上发现:长出来的块不在初始运行里,运行时的 `emo_arena_reap` 看不到它们;这些行与两个额外的回收点就是这一刀的实质。

真机证明:`chello.elf`(24,752 字节)在 fd、VFS、复用节拍之后答 `grow ok`;3 MiB malloc 的首尾字节都成立,增长前后帧账目的持有数相同(232,行在 exit 时回了家)。

### T1.4a 的记录(2026-11-23)

args 的门是动词 48 `exec_args(name, nlen, args, alen)`:门把名字和行的余下(至多 512 字节)停在 execargs 页,置 use 标记,路由到进程服务的 exec op;拾取读标记的裸单元,args 门调 `transaction_args`;平铺门照旧把名字拷到 exec 页的缓冲。`build_args` 写孩子的第一张栈:顶部 argc、argv(程序名,然后按空格切出的词)、argv 的 NULL、envp 的 NULL、字符串——sp 是物理基址;C crt0 从 cells 页的 `0x87fff080` 读它,移动 sp,把三元组交给 `main`。Emo 趟从不读 args;运行时把这块覆盖掉。

路上发现:最初放在新固定地址(`0x87010000`,后来 `0x8700b100`)的 execargs 页在进程服务的表里没有映射——exec 拾取的 peek 在 S-mode 里 trap,机器说 `the kernel took an unexpected trap`。真正映射着的是增长表的页(`0x8700f000`,T1.3v 已证明);execargs 挪到它的页尾,增长表从 255 行缩到 200。另外发现:跨模块的 `exec.args_use()` 调用在这个目标上自己就 trap,而 `exec.args_name()` 等正常;进程服务改从裸单元读 use 标记。

真机证明:`exec chello.elf` 答 `args none`(argc 1),`exec chello.elf hello world` 答 `args ok`(argc 3,argv[1] `hello`,argv[2] `world`);`chello.elf` 24,856 字节,C 的整条链(fd、VFS、复用、增长)保持全绿。桌面的 `exec` 取行的余下作为 args;syscall 包就地长出 `exec_args`,五个 lock 重新钉住。

### T1.4b1 的记录(2026-11-23)

进程表面:动词 49 `getpid`;动词 50 `setpgid(pid, pgid)`(目标 0 是调用者,组 0 是目标,只有调用者或其子进程,父单元是权威);动词 51 `getpgid(pid)`(同一权威)。组单元是增长页尾每 pid 一个字节(`0x8700f000 + 3784`,在 execargs 之后;256 字节),0 表示 pid 自己的组。库的环境是 `environ`(crt0 把 `main` 的 envp 交给它;第一次使用时扫进 16×128 的静态表),背后是 `getenv`/`setenv`/`unsetenv`;`wait4`/`waitpid` 走动词 4,状态为 `(code & 0xff) << 8`;任意子进程的 wait(`pid <= 0`)在 T1.4b2 之前答 `ENOSYS`。

真机证明:`chello.elf`(25,560 字节)在 fd、VFS、复用、增长、args 节拍之后答 `proc ok` 与 `env ok`——pid 查到、组设好又读回、`EMO=yes` 设好、读出、删除——机器的 exit 路由干净。

### T1.4b2 的记录(2026-11-23)

fork 是动词 52 `fork(ctx, entry)`:门用调用者镜像的可执行段判断恢复入口,把保存的上下文与入口停在 exec 页尾,路由到进程服务;拾取一直持有 exec 的 busy 单元直到 spawn 完成。克隆把父进程的镜像记录拷进一条空闲记录并配一份新的运行,复制私有 handoff 页并写下 fork 配方(保存的上下文、父进程的栈与 arena 基址、它的 pid、它的打包 arena 单元),并且在 spawn 之前复制栈块——`user_spawn` 随后把合成帧清零在新块底部,只有死掉的底部字节让位。`space.build` 把栈映射在父进程基址(带 U)和它自己的身份(不带 U,内核的锚帧),把 arena 运行与每个增长行复制并映射到父进程的虚拟位置,追加孩子的增长行,并把孩子的 arena 单元写成父进程的。孩子从 `emo_fork_resume` 开始,重载 gp,把 sp 移到保存的上下文,带着 a0 = 0 从 fork 的收尾返回。

wait 的目标与 exit 的码从共享的 `proc_arga`/`proc_argb` 搬到新的 `.emo_procargs` 页(0x8700a000;各 256 字)上的每 pid 单元——没有它,后到的 exit 会在服务读到之前覆盖 wait 的目标。动词 4 现在答 `(pid << 32) | code`;Emo 的 `syscall.wait` 桩剥掉 pid,C 的 `wait4` 返回真正的孩子(任意子进程的 wait 现在知道是谁)。停泊的 wait 直接消费 exit,条目不再进退出表;后到的 wait 消费条目。孩子继承父进程的进程组。

路上发现:第一版在 build 里复制栈,那是在 `user_spawn` 把合成陷阱帧清零在块底之后——复制覆盖了锚,孩子带着父进程的寄存器恢复(两个进程都打印了父进程那一行)。复制现在挪到 spawn 之前。另一处发现是共享的 wait/exit 参数单元:孩子的退出码落进 wait 的目标,wait 把父进程的 pid 当成退出码答了。

真机证明:`chello.elf`(25,928 字节)在 fd、VFS、堆、增长、args、proc、env 节拍之后答 `fork ok` 与 `wait ok`——孩子退出 42,父进程读到;随后任意子进程的 wait 收走第二个孩子的 7——机器的 exit 路由干净。库的 fd 编号随镜像复制;T1.4b3a 的懒重开让文件系统服务的每 pid 句柄在第一次使用时跟上。execve 与环境交接是 T1.4b3b。

### T1.4b3a 的记录(2026-11-23)

库的描述符表在 `used` 旁长出复制的名字(24 字节)、字节长度、打开标志与偏移。`open_name` 填它们;`read`/`write` 推进偏移,`lseek` 设定它。对一个在用的描述符,服务答 -4 表示这个 pid 没有句柄——fork 继承来的 fd——于是库以自己的 pid 重开存下的名字(丢弃 O_CREAT 与 O_TRUNC,O_APPEND 留给服务的末尾)并 seek 到复制的偏移。对这样的描述符 `close` 是只清掉孩子副本的成功。偏移在 fork 之后分叉——服务的句柄还不是共享描述,这是记录在案的近似。

真机证明:`chello.elf`(30,280 字节,一个镜像块)打开 `forkfd.txt`,写 `fork fd`,seek 到 0 并 fork;孩子经重开的描述符读到 `fork `,关掉它并退出 0,父进程收尸后答 `fd fork ok`——在 fd、VFS、堆、增长、args、proc、env、fork、wait 节拍之后,机器的 exit 路由干净。

### T1.4b3b 的记录(2026-11-23)

`execve(path, argv[], envp[])` 是动词 54:门停名字与两段文本(args 至多 512 字节,env 至多 256,放在 `0x8700b900` 的自由尾巴上,避开控制台的每 pid 单元),use 标记点名替换门;进程服务分配新栈与新 arena,经 `exec.transaction_replace` 装载镜像——装载器的记录、运行与私有页,第一张栈带上 argv 与 envp 的指针和字符串。运行时原语 `user_replace` 找到调用者的槽位,标记为 done 并跑死亡的回收(镜像钩子、栈与 arena、增长行),清空邮箱,把槽位打扮成新栈与新 arena,在新栈底建合成帧,调 space 的 build 钩子消费停放的记录并装上新的根表,然后把同一个 pid 排队。调用者原本停在 gate-wait;服务不作应答。

C 库的 `execve` 复制路径(没有路径层——卷的平面名字),把 `argv[1..]` 与 `envp` 摊成门的空格分隔文本(词里带空格是 EINVAL;超长 E2BIG),成功后永不返回。`argv[0]` 是内核启动的文件名;envp 是调用者的。`execv` 传 `environ`。

真机证明:`chello.elf`(30,752 字节,一个镜像块)fork 一个孩子,孩子用 argv `execchild <pid>` 与 env `EMO_EXEC=1` execve 同一个文件;新镜像把 `getpid()` 与 argv 的 pid、env 对照,答 `execve child ok` 并退出 0;父进程的 `waitpid` 答 `execve ok`。此前的节拍全绿,机器的 exit 路由干净。

缺口:新镜像的库 fd 表与 cwd 是新的,旧句柄被丢弃(`fs.drop_pid`)——execution 还不保留描述符;旧页表与私有页泄漏(前者是页表的规矩,后者是 exec 记录在案的 4 KiB);被排队消息钉住的旧 arena 不释放,旧邮箱里的消息被丢掉时没有解开其发送者的钉。环境的线上文本装不下值里的空格。

### T1.5 的记录(2026-11-23)

管道是进程服务的第二条臂,住在自己的六页上(`.emo_pipe`,0x87010000):绑定表(每 pid 每 fd 一字节——0 不是管道,0x10|id 读端,0x20|id 写端)、门停放的每 pid 请求记录(op、fd、第二个 fd、缓冲区、长度、调用者的 space 字),以及八个 1024 字节的管道块(两端的计数、环的游标、四个停泊读者、四个停泊写者、768 字节的环)。动词是 55..60:绑定、读、探测、写、复制、关闭。绑定与探测在门里就答;其余四个路由到进程服务(op 40..44,这一族的 `-(1000 + op)`),因为它们每一个都可能唤醒停泊的对端,而只有服务的上下文可以应答。服务是唯一改动这些表的线程——门只停放——所以没有两个客户端同时碰到一个计数。

环空而仍有写者持有端时,读把调用者按进 gate-wait;一个写者不剩时答 0。写超过环的容量时把写者停泊,这一趟装了多少答多少(POSIX 的部分写),读者一个不剩时答断管。每个被服务的请求都有界地泵动管道停泊的两端,因为一次读腾出写者的空间,一次写填满读者的环。计数跟着持有者走:`fork` 把每个端复制到孩子的 pid(多一个持有者,所以父进程的关闭还不是孩子的 EOF),`execve` 丢掉 fd 3..15(新镜像崭新的库表叫不出它们)而留下 0..2(管道的重定向),正常退出走遍每个端。`dup2` 把管道绑定经内核搬走;文件的名字、标志与偏移经库自己的表;控制流描述符的编号把控制台授予新号。管道上的 `lseek`/`fstat` 答 `ESPIPE`/零大小。

库缓存每个描述符的种类(0 未知、控制台进/出、文件、管道读/写、已关闭),字节未知时对每个 fd 问一次动词 57——所以 exec 过的新镜像第一次读或写 fd 0..2 时,会找到前任留下的管道。

路上发现的:fork 把孩子的栈映射在它的物理身份上作 trap anchor,而父进程的虚拟 arena 范围(它的运行加上其后的增长块,在父进程的地址上)可能覆盖分配器要递出的那块——一页两个翻译,`space.map_page` 的响亮终点。修法是 `frames.take_outside`:孩子的栈从父进程虚拟范围之外取。

真机证明:`chello.elf`(40,208 字节,一个镜像块)答出 `pipe ok`(孩子的行穿过环、父进程在最后一个写者关闭时读到 EOF)、`pipe dup ok`(管道的写端落到 fd 1,控制台先被 `dup` 存下、再被 `dup2` 恢复)、`pipe exec ok`(孩子的 fd 1 进管道再 `execve`——低端留下,新镜像的 `write(1)` 落进环)、`pipe big ok`(2,000 字节穿过 768 字节的环,两端都阻塞且保持流的顺序)与 `pipe epipe ok`(最后一个读者的关闭是写者的 EPIPE),在之前所有节拍之后。机器的 exit 路由干净。

缺口:因 fault 或堆的击杀而死的进程会漏掉它的管道端——fault 路径跑在 trap 里,无法唤醒停泊的对端(它的应答会在 trap 中途置起 SIE),所以丢端要等 T1.6 的信号接管死亡路径的唤醒。一条管道保留八个块、每端四个停泊者;第五个停泊的读者或写者是服务的响亮终点。`pipe`/`dup`/`dup2` 的端不是按共享描述继承的——库的 fd 表拥有它们,文件描述符的偏移在 `fork` 后依旧分叉(T1.4b3a 的近似,未变)。

### T1.6 的记录(2026-11-23)

信号是门自己的,住在自己的页上(`.emo_sig`,0x87018000):每 pid 一个待决字与一个阻塞字,每 pid 每个信号槽一个字 disposition(0 默认,1 忽略,地址即处理器),每个进程槽一个活动标记与一个保存帧,外加 trap shim 每次 ecall 停放的两个单元(帧基址与槽索引)。词表是八个——SIGINT 2、SIGQUIT 3、SIGKILL 9、SIGUSR1 10、SIGSEGV 11、SIGPIPE 13、SIGTERM 15、SIGCHLD 17——掩码的位就是信号编号本身(位 2 是 SIGINT)。动词:61 `kill(pid, sig)`(一个进程、一个组、调用者自己的组;权限是调用者自身、它的孩子、或它携带的组;信号 0 是探针),62 `sig_action(sig, disp)`(SIGKILL 拒绝;处理器必须落在调用者可执行段内,fork 入口的检查),63 `sig_mask(how, set)`(阻塞、解除、替换;SIGKILL 的位与词表之外的位丢掉),64 `sig_return()`,65 `sig_pending()`。

投递在 resume 上:`emo_os_trap_resume` 每次回到 U-mode 都先问 `emo_os_sig_deliver`,在 anchor 武装之前。最低的、未阻塞的、处置为处理器的信号把被打断的帧与它的 sp 槽复制进该槽的记录,阻塞所有信号,重写帧——`ra` 指向 0x87ffd000 的 trampoline 页(每张用户表以 RX 带 U 映射它),`a0` 放信号,`sepc` 放处理器。处理器跑在被打断的栈上,返回到 trampoline 的 `li a7, 64; ecall`;门的动词 64 把保存的帧与掩码放回并应答 shim 的特殊 -105,让帧原样恢复——不往 a0 写答案,不推进 sepc。trampoline 的第三个字是 `ebreak`,没有处理器却返回时的响亮终点。默认处置结束进程:shim 的死亡路径把信号写成退出的状态,把退出投给进程服务(记录、waiter、父进程的事件、管道端的走查),把槽标为 done 并回收。SIGKILL 的待决位无视掩码与正在运行的处理器——机器的击杀。

状态编码改成 POSIX 的:门的 exit 往每 pid 单元写 `code << 8`,信号致死写信号编号,退出表与 wait 原样应答这个字,C 库把它当 wait 状态返回(`WIFEXITED`/`WEXITSTATUS`/`WIFSIGNALED`/`WTERMSIG`)。启动证明的 `wait 7` 自己把码移出来;`syscall` 包的注释改成状态字,五把锁重新钉过。孩子退出给父进程竖起 SIGCHLD,断管在 EPIPE 应答旁竖起 SIGPIPE。处置与掩码跨 `fork` 复制;`execve` 重置处置(那些地址属于旧镜像)而保留掩码。

路上发现的:投递自己的调用帧写在了它即将恢复的那一帧上——typed def 的栈从 `sp` 往下长进 anchor 的字里,被写坏的 sepc/帧让机器无声地卡住。这个钩子现在跑在自己的 4 KiB 栈上(`emo_os_sig_stack`),调用前后切换 sp。还发现:trampoline 的指令必须相隔四字节——最初把每条写成双字,ebreak 的邻居被读成非法指令(`user fault ... cause 2 at 0x87ffd004`)。

真机证明:`chello.elf`(41,016 字节,一个镜像块)答出 `signal ok`(SIGUSR1 的处理器在 raise 返回前跑过、SIGTERM 被忽略、SIGKILL 被拒)、`signal mask ok`(SIGUSR1 阻塞、raise、看到待决、解除时投递)、`signal kill ok`(孩子的默认 SIGTERM 死亡读成 `WIFSIGNALED`/`WTERMSIG`,父进程的 SIGCHLD 处理器跑过),`pipe epipe ok` 长出被阻塞 SIGPIPE 的待决检查——在之前所有节拍之后,`wait 7` 也在。机器的 exit 路由干净。

缺口:在停泊进程上竖起的信号等它的停泊解开——`kill` 不打断一次阻塞的读(EINTR 是后续),所以睡在控制台上的孩子还够不着。处理器运行时所有信号都被阻塞:`sa_mask`、`sa_flags` 与嵌套处理器是库的 `sigaction` 结构体要长的东西。词表是八个——没有 SIGSTOP/SIGCONT/停止态,没有作业控制(T3 的 shell)。fault 路径仍不把孩子的死亡投给进程服务(信号死亡的路径不共享这个旧缺口)。

### M2——C 库(源自 musl)

- [ ] **T2.1**——syscall 层:musl 的 `arch/riscv64` 桩接到门上,每个函数对一个已记录的动词。
- [ ] **T2.2**——`crt`、TLS、`malloc`、`stdio`、`string`、`errno`;静态 `hello`、`printf`、`malloc`、`getenv`。
- [ ] **T2.3**——sysroot 与编译器包装器:`libc.a`、头文件、链接脚本;`riscv64-emos-gcc`。
- [ ] **T2.4**——一致性探针:一小套 C 测试钉住本里程碑的调用,在金属和宿主解释器上(都适用时)逐字节相同。

### M3——emosh 作为默认 shell

- [ ] **T3.1**——emosh 对着 sysroot 构建。移植被迫改的每一处源码都列出来;目标是零。
- [ ] **T3.2**——emosh 成为启动前台——行编辑、历史、补全——替换 `hello/shell.emo` 作为机器的 shell。
- [ ] **T3.3**——控制台交接:串口字节进 fd 0,写走 fd 1/2,`poweroff` 仍是引导自己拥有的 exit 路由。
- [ ] **T3.4**——桌面的 `exec` 把 `argv`/`envp` 交给子进程;启动器与 shell 共用一扇门。

### M4——生态

- [ ] **T4.1**——busybox 或 dash:第一个真正的 POSIX 程序,shell 自己的验收。
- [ ] **T4.2**——核心工具:第一套语料(文件、文本、进程),每个用金测钉住。
- [ ] **T4.3**——构建系统:`make`,然后 autotools/CMake 与 `pkg-config`,让一个 Linux tarball 自己的构建能跑。
- [ ] **T4.4**——软件语料与 CI:什么能构建、什么能跑、各自需要什么;清单就是这个 tracker 诚实的答案。
- [ ] **T4.5**——自举编译:EmoOS 自己上的 GCC/Clang 与工具。放最后,因为它需要上面一切。

## 边界

- 不做 Linux syscall ABI、不做 Linux ELF 兼容、不跑预编译二进制、不碰 glibc。
- 在静态语料挣到它之前不做动态链接;musl 静态是第一份契约。
- 微内核仍是微内核:C 库是用户进程的库,不是第二个内核。
- 每个新增先在这里成为任务,再成为代码;每个任务点名它的消费者。
