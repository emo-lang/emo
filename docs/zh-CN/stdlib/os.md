# `os` 包

标准库的进程级接口:进程 id、`fork`、`execv`、`waitpid`、管道、工作
目录、目录列举,以及裸(非缓冲、基于 fd)文件 IO——系统程序在搭建
一切之前需要的底层能力。与格式包不同,`os` 不是纯 Emo:它的调用分发
到以 POSIX 为底座的运行时内建,因此只声明拥有 Unix 形态宿主的两个
目标——`ocaml` 与 `c`。给浏览器或字节码目标声明这个包,在任何代码
运行之前就会报包错误。

## 使用包

```emo
require "os"
```

`require` 与清单严格配对:`os` 必须钉在 `package.emo` 里,且目标
一致:

```emo
package {
  name = "acme/myapp"
  version = "0.1.0"
  targets = ["ocaml", "c"]

  deps {
    os = "0.1.0"
  }
}
```

## 错误

遵循标准库的约定,每个失败的调用都会抛出普通的 Emo 异常,消息写明
是哪个系统调用、为何失败——`os: open_write notes.txt: Permission
denied`——没有错误码,没有 nil。不会失败的调用(`getpid`、
`getppid`、健康系统上的 `fork`)就是普通函数。

## 进程

```emo
def getpid() Int64
def getppid() Int64
def fork() Int64
def waitpid(pid Int64) (Int64, Int64)
def execv(path String, argv Array[String]) Void
def _exit(status Int64) Void
```

`fork()` 返回两次:子进程中是 `0`,父进程中是子进程的 pid。
`waitpid(pid)` 阻塞到该子进程改变状态,回答 `(pid, status)`;
`status` 是内核原始的 16 位状态字,由 `wait_*` 系列辅助函数解码——
与所有 Unix 内核相同的编码,所以在两个目标上这些数字含义一致:

```emo
const w = os.waitpid(pid)
if os.wait_exited(w[1]) {
  println(os.wait_exit_code(w[1]))
}
```

- `wait_exited` / `wait_exit_code` —— 正常退出,以及退出码。
- `wait_signaled` / `wait_signal` —— 被信号杀死,以及是哪个信号。
- `wait_stopped` / `wait_stop_signal` —— 被停止,以及是哪个信号。

`execv(path, argv)` 替换调用进程;成功时它绝不返回,失败时抛异常。
`_exit(status)` 立即结束调用进程,不做任何展开——这是 fork 子进程
的出口,保证子进程不会把父进程的清理逻辑再跑一遍。

## 管道

```emo
def pipe() (Int64, Int64)
```

`(读端, 写端)`——单向、字节流、进程内。经典形状,一写一读:

```emo
const p = os.pipe()
const pid = os.fork()
if pid == 0 {
  os.close(p[0])
  os.write(p[1], "from the child")
  os.close(p[1])
  os._exit(0)
}
os.close(p[1])
println(os.read(p[0], 64))
os.close(p[0])
```

## 裸文件 IO

非缓冲:每次 `read` 和 `write` 都直接进内核。

```emo
def open_read(path String) Int64
def open_write(path String) Int64
def open_append(path String) Int64
def read(fd Int64, n Int64) String
def write(fd Int64, data String) Int64
def close(fd Int64) Int64
```

`open_write` 创建或截断;`open_append` 创建或追加;两者都只以写
方式打开。`read` 最多返回 `n` 字节——有多少给多少,文件末尾返回
空串。`write` 返回实际写入的字节数。

## 目录与工作目录

```emo
def list_dir(path String) Array[String]
def mkdir(path String) Int64
def rmdir(path String) Int64
def unlink(path String) Int64
def rename(old_path String, new_path String) Int64
def getcwd() String
def chdir(path String) Int64
```

`list_dir` 返回目录里的条目名,按字节序排序,不含 `.` 和 `..`——
两个目标上顺序一致,目录列举可复现。这里的一切都只收发普通路径:
还没有文件类型查询,没有 stat。

## fork 纪律

fork 出的子进程与父进程共享所有打开的描述符;约定(上面管道形状
所用的)是各方关掉自己不用的那一端,子进程经 `_exit` 离开——从
main 普通 `return` 会把父进程的清理逻辑跑两遍。

## 目标

`["ocaml", "c"]`。ocaml 目标把 os 调用建在宿主的 Unix 模块上;
c 目标直接发射 POSIX 调用。没有进程可 fork 的地方,fork/exec/
wait/pipe 就没有意义,因此 typescript、wasm、beam 目标拒绝这个包。
