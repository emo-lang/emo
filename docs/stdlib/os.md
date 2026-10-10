# The `os` Package

The standard library's process-level surface: process ids, `fork`,
`execv`, `waitpid`, pipes, the working directory, directory listing,
and raw (unbuffered, fd-based) file IO — the machinery a systems
program needs before it can build anything else. Unlike the format
packages, `os` is not pure Emo: its calls dispatch to runtime
built-ins backed by POSIX, and it declares only the targets that have
a Unix-shaped host — `ocaml` and `c`. Declaring it for the browser or
bytecode targets is a package error before any code runs.

## Using the package

```emo
require "os"
```

A `require` pairs strictly with the manifest: `os` must be pinned in
`package.emo` with matching targets:

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

## Errors

Following the standard library's convention, every failing call raises
an ordinary Emo exception whose message states exactly which system
call failed and why — `os: open_write notes.txt: Permission denied` —
no error codes, no nil. The calls that never fail (`getpid`,
`getppid`, `fork` on a healthy system) are plain functions.

## Processes

```emo
def getpid() Int64
def getppid() Int64
def fork() Int64
def waitpid(pid Int64) (Int64, Int64)
def execv(path String, argv Array[String]) Void
def _exit(status Int64) Void
```

`fork()` returns twice: `0` in the child, the child's pid in the
parent. `waitpid(pid)` blocks until that child changes state and
answers `(pid, status)`; `status` is the kernel's raw 16-bit word,
decoded by the `wait_*` helpers — the same encoding every Unix kernel
uses, so the numbers mean the same thing on both targets:

```emo
const w = os.waitpid(pid)
if os.wait_exited(w[1]) {
  println(os.wait_exit_code(w[1]))
}
```

- `wait_exited` / `wait_exit_code` — exited normally, and its status.
- `wait_signaled` / `wait_signal` — killed by a signal, and which.
- `wait_stopped` / `wait_stop_signal` — stopped, and which signal.

`execv(path, argv)` replaces the calling process; on success it never
returns, and on failure it raises. `_exit(status)` ends the calling
process immediately, without unwinding — the fork child's way out, so
a child cannot run its parent's cleanup a second time.

## Pipes

```emo
def pipe() (Int64, Int64)
```

`(read_end, write_end)` — unidirectional, byte-oriented, in-process.
The classic shape, one write per read:

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

## Raw file IO

Unbuffered: every `read` and `write` crosses to the kernel.

```emo
def open_read(path String) Int64
def open_write(path String) Int64
def open_append(path String) Int64
def read(fd Int64, n Int64) String
def write(fd Int64, data String) Int64
def close(fd Int64) Int64
```

`open_write` creates or truncates; `open_append` creates or appends;
both open for writing only. `read` returns up to `n` bytes — fewer
when fewer are available, and the empty string at end of file.
`write` returns how many bytes were written.

## Directories and the working directory

```emo
def list_dir(path String) Array[String]
def mkdir(path String) Int64
def rmdir(path String) Int64
def unlink(path String) Int64
def rename(old_path String, new_path String) Int64
def getcwd() String
def chdir(path String) Int64
```

`list_dir` answers the entry names of a directory, byte-order sorted,
excluding `.` and `..` — the same order on both targets, so a
directory listing is reproducible. Everything here takes or returns
plain paths: no file-type inquiry yet, no stat.

## The fork discipline

A forked child shares every open descriptor with its parent; the
convention (used by the pipe shape above) is that each side closes the
end it does not use, and the child leaves through `_exit` — ordinary
`return` from main would run the parent's cleanup twice.

## Targets

`["ocaml", "c"]`. The ocaml target builds its os calls on the host's
Unix module; the c target emits direct POSIX calls. fork/exec/wait/
pipe have no meaning where there is no process to fork, so the
typescript, wasm, and beam targets refuse the package.
