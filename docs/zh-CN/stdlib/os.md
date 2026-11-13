# `os` 包

标准库的进程级接口:进程 id、`fork`、`execv`、`execvp`、`waitpid`、
管道、描述符接线、环境变量、信号、工作目录、目录列举,以及裸
(非缓冲、基于 fd)文件 IO——系统程序在搭建一切之前需要的底层能力
(shell 便是其一)。与格式包不同,`os` 不是纯 Emo:它的调用分发
到以 POSIX 为底座的运行时实现,因此只声明宿主能承载这套接口的
目标——`ocaml`、`c`,以及 `wasm`(fd、目录与工作目录半边;进程半边
在那里改为调用时 raise 并点名能力)。给浏览器或字节码目标声明这个
包,在任何代码运行之前就会报包错误。

## 使用包

```emo
require "os"
```

标准库随编译器一起发布,但它的包和其他依赖一样带版本:`require "os"` 需要在 manifest 的 `deps` 块里钉上 `"os" = "0.1.0"`。本包声明 `ocaml`、`c` 和 `wasm` 目标,其他目标的构建会拒绝它。

## 错误

遵循标准库的约定,凡是数据能触发的失败,调用都以 `(R.ok, value)` 或
`(R.error, reason)` 返回——reason 是 String,写明是哪个系统调用、
为何失败——`os: open_write notes.txt: Permission denied`——没有
错误码,没有 nil。不会失败的调用(`getpid`、`getppid`、`getcwd`、
`isatty`、`argv`、`wait_*` 状态解码器)就是普通函数,`waitpid` 的
原始状态字同理;`execv` 与 `execvp` 失败时返回而不是抛出——那是
fork 子进程接 `_exit` 的暗号。

## 进程

```emo
def getpid() Int64
def getppid() Int64
def fork() (R, Int64)
def waitpid(pid Int64) (Int64, Int64)
def kill(pid Int64, sig Int64) (R, Int64)
def setpgid(pid Int64, pgid Int64) (R, Int64)
def execv(path String, argv Array[String]) Void
def _exit(status Int64) Void
```

`fork()` 以 `(R.ok, pid)` 回答子进程的 pid——子进程中是 `0`,父进程
中是子进程的 pid。`waitpid(pid)` 阻塞到该子进程改变状态,回答
`(pid, status)`;`status` 是内核原始的 16 位状态字,由 `wait_*` 系列
辅助函数解码——与所有 Unix 内核相同的编码,所以在两个目标上这些
数字含义一致:

```emo
const w = os.waitpid(pid)
if os.wait_exited(w[1]) {
  println(os.wait_exit_code(w[1]))
}
```

- `wait_exited` / `wait_exit_code` —— 正常退出,以及退出码。
- `wait_signaled` / `wait_signal` —— 被信号杀死,以及是哪个信号。
- `wait_stopped` / `wait_stop_signal` —— 被停止,以及是哪个信号。

`execv(path, argv)` 替换调用进程;成功时它绝不返回,失败时返回
——fork 子进程随后接 `_exit`,因为在那里抛异常会把父进程的清理
逻辑再跑一遍。`_exit(status)` 立即结束调用进程,不做任何展开——
这是 fork 子进程的出口,保证子进程不会把父进程的清理逻辑再跑一遍。
`execvp(file, argv)` 是同一种替换,只是多一步查找:`file` 沿 `PATH`
环境变量搜索(与 shell 自己的查找一致;带斜杠的名字原样使用),
失败约定与 execv 相同。

`kill(pid, sig)` 把 `sig` 发给 `pid`——进程 id,或其负数,代表以它
为 id 的整个进程组,这是监护者赖以生存的纪律:一次调用结束一个组。
`sig_*` 常量就是这些数字。越界的信号在调用之前就被拒绝——
`os: kill 99: invalid signal`——每个目标上同样的固定原因;内核的
拒绝则是数据驱动的值(`os: kill: No such process`)。
`setpgid(pid, pgid)` 把 `pid` 挪进以 `pgid` 为 id 的进程组
(`pgid 0` 表示 `pid` 自己的组)——fork 子进程的第一步,在 exec
之前立起自己的新组,是 shell 赖以生存的纪律:此后父进程用一次负
pid 的 kill 就能结束整个组。

## 描述符接线与终端

```emo
def dup2(old_fd Int64, new_fd Int64) (R, Int64)
def isatty(fd Int64) Bool
```

`dup2` 把 `old_fd` 复制到 `new_fd` 上,若 `new_fd` 原本打开会先关掉
——shell 靠它在 exec 之前把子进程的 stdin/stdout 指到管道端点或
文件上。`isatty` 回答 `fd` 是否连接着终端——程序由此分辨交互会话
与管道、脚本喂入的 stdin。两者都是朴素 POSIX,没有缓冲,没有意外。

## 环境变量与参数

```emo
def argv() Array[String]
def getenv(name String) (R, String)
def setenv(name String, value String) (R, Int64)
def unsetenv(name String) (R, Int64)
```

`argv()` 返回进程自己的参数向量,`argv[0]` 是进程启动时的名字——
永不失败。`getenv` 返回变量的值;未设置与其他数据驱动的失败一样
是值:`(R.error, "os: getenv HOME: is not set")`。`setenv` 设置或
替换(POSIX 恒覆盖形式);fork 子进程经 exec 继承环境——shell 的
`export` 正是这样传给它运行的命令的。

## 信号

```emo
const sig_hup = 1
const sig_int = 2
const sig_quit = 3
const sig_kill = 9
const sig_pipe = 13
const sig_term = 15

def signal_ignore(sig Int64) (R, Int64)
def signal_default(sig Int64) (R, Int64)
```

经典的 Unix 集合——`wait_*` 解码器回答的数字,也就是处置调用
接受的数字。`signal_ignore` 把信号在本进程置为忽略;
`signal_default` 恢复默认。越界号码返回 `(R.error, "os:
signal_ignore 99: invalid signal")`——两个目标上文字相同,由构造
保证。

这是 shell 赖以为生的纪律:shell 自己的进程里忽略 `sig_int`(和
`sig_quit`),fork 子进程在 exec 之前调 `signal_default` 撤销。
*忽略*的处置会跨 exec 存活——所以子进程必须撤销——*handler* 的
处置则不会;这一对就是全部技巧。shell 里忽略 `sig_pipe`,写进
死管道就不会杀死解释器,外部命令仍保留自己的默认死法。

## 管道

```emo
def pipe() (R, (Int64, Int64))
```

`(R.ok, (读端, 写端))`——单向、字节流、进程内。经典形状,一写一读:

```emo
const (R.ok, p) = os.pipe()
const (R.ok, pid) = os.fork()
if pid == 0 {
  os.close(p[0])
  os.write(p[1], "from the child")
  os.close(p[1])
  os._exit(0)
}
os.close(p[1])
const (R.ok, text) = os.read(p[0], 64)
println(text)
os.close(p[0])
```

## 裸文件 IO

非缓冲:每次 `read` 和 `write` 都直接进内核。

```emo
def open_read(path String) (R, Int64)
def open_write(path String) (R, Int64)
def open_append(path String) (R, Int64)
def read(fd Int64, n Int64) (R, String)
def write(fd Int64, data String) (R, Int64)
def close(fd Int64) (R, Int64)
```

`open_write` 创建或截断;`open_append` 创建或追加;两者都只以写
方式打开。`read` 最多返回 `n` 字节——有多少给多少,文件末尾返回
空串。`write` 返回实际写入的字节数。

## 目录与工作目录

```emo
def list_dir(path String) (R, Array[String])
def mkdir(path String) (R, Int64)
def rmdir(path String) (R, Int64)
def unlink(path String) (R, Int64)
def rename(old_path String, new_path String) (R, Int64)
def getcwd() String
def chdir(path String) (R, Int64)
```

`list_dir` 返回目录里的条目名,按字节序排序,不含 `.` 和 `..`——
两个目标上顺序一致,目录列举可复现。这里的一切都只收发普通路径:
还没有文件类型查询,没有 stat。

## fork 纪律

fork 出的子进程与父进程共享所有打开的描述符;约定(上面管道形状
所用的)是各方关掉自己不用的那一端,子进程经 `_exit` 离开——从
main 普通 `return` 会把父进程的清理逻辑跑两遍。

## 目标

`["ocaml", "c", "wasm"]`。ocaml 目标把 os 调用建在宿主的 Unix 模块上;
c 目标直接发射 POSIX 调用;wasm 目标把 fd、目录与工作目录半边降级为
模块的 syscall,把进程半边降级为运行时 raise——`fork`、`execv`、
`execvp`、`waitpid`、`pipe`、`dup2`、`getpid`、`getppid`、`_exit`、
`isatty`、`argv`、环境变量与信号处置各自在被调用时点名能力
(`os_fs_demo` 走 fd 与目录半边;含 fork 的 `os_demo` 仍是 c
golden)。typescript 与 beam 目标拒绝这个包。
