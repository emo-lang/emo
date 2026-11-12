# The `os` Package

The standard library's process-level surface: process ids, `fork`,
`execv`, `execvp`, `waitpid`, pipes, descriptor plumbing, the
environment, the signals, the working directory, directory listing,
and raw (unbuffered, fd-based) file IO — the machinery a systems
program needs before it can build anything else (a shell, for one).
Unlike the format packages, `os` is not pure Emo: its calls dispatch
to the runtime's implementations, backed by POSIX, and it declares
only the targets whose host carries the surface — `ocaml`, `c`, and
`wasm` (the fd, directory, and working-directory half; the process
half raises at the call there, naming the capability). Declaring it
for the browser or bytecode targets is a package error before any
code runs.

## Using the package

```emo
require "os"
```

The standard library ships with the compiler, but its packages are
versioned like any other: `require "os"` needs `"os" = "0.1.0"` in the
manifest's `deps` block. The package declares the `ocaml`, `c`, and
`wasm` targets, so a build for another target refuses it.

## Errors

Following the standard library's convention, a call whose failure the
data can trigger answers `(R.ok, value)` or `(R.error, reason)` — the
reason a String stating exactly which system call failed and why —
`os: open_write notes.txt: Permission denied` — no error codes, no
nil. The calls that never fail (`getpid`, `getppid`, `getcwd`,
`isatty`, `argv`, the `wait_*` status decoders) are plain functions,
and so is `waitpid`'s raw status word; `execv` and `execvp` return on
failure instead of raising, the fork child's cue to `_exit`.

## Processes

```emo
def getpid() Int64
def getppid() Int64
def fork() (R, Int64)
def waitpid(pid Int64) (Int64, Int64)
def execv(path String, argv Array[String]) Void
def _exit(status Int64) Void
```

`fork()` answers the child's pid in `(R.ok, pid)` — `0` in the child,
the child's pid in the parent. `waitpid(pid)` blocks until that child
changes state and answers `(pid, status)`; `status` is the kernel's
raw 16-bit word, decoded by the `wait_*` helpers — the same encoding
every Unix kernel uses, so the numbers mean the same thing on both
targets:

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
returns, and on failure it returns — the fork child follows it with
`_exit`, since a raise there would run the parent's cleanup a second
time. `_exit(status)` ends the calling process immediately, without
unwinding — the fork child's way out, so a child cannot run its
parent's cleanup a second time. `execvp(file, argv)` is the same
replacement with a lookup: `file` is searched through the `PATH`
environment variable the way the shell's own lookup is (a name with a
slash in it is used as-is), and the failure contract is the execv one.

## Descriptor plumbing and the terminal

```emo
def dup2(old_fd Int64, new_fd Int64) (R, Int64)
def isatty(fd Int64) Bool
```

`dup2` copies `old_fd` onto `new_fd`, closing `new_fd` first if it was
open — the plumbing a shell uses to point a child's stdin or stdout at
a pipe end or a file before the exec. `isatty` answers whether `fd` is
attached to a terminal — how a program tells an interactive session
from a pipe or a script on stdin. Both are plain POSIX with no
buffering and no surprises.

## The environment and the arguments

```emo
def argv() Array[String]
def getenv(name String) (R, String)
def setenv(name String, value String) (R, Int64)
def unsetenv(name String) (R, Int64)
```

`argv()` answers the process's own argument vector, `argv[0]` the name
the process was started with — it never fails. `getenv` answers the
variable's value, and unset is a value like every other data-driven
failure in the package: `(R.error, "os: getenv HOME: is not set")`.
`setenv` sets or replaces (the POSIX overwrite-always form); the fork
child inherits the environment across the exec, which is how a shell's
`export` reaches the commands it runs.

## Signals

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

The classic Unix set — the numbers the `wait_*` decoders answer, the
numbers the dispositions take. `signal_ignore` sets a signal to be
ignored in this process; `signal_default` restores the default. An
out-of-range number answers `(R.error, "os: signal_ignore 99: invalid
signal")` — the same text on both targets, by construction.

The discipline a shell lives by: ignore `sig_int` (and `sig_quit`) in
the shell's own process, and have the fork child call
`signal_default` before the exec. A disposition of *ignored* survives
the exec — that is why the child must undo it — a handler's does not;
this pair is the whole trick, and `sig_pipe` ignored in the shell keeps
a write into a dead pipe from killing the interpreter while the
external commands keep their own default death.

## Pipes

```emo
def pipe() (R, (Int64, Int64))
```

`(R.ok, (read_end, write_end))` — unidirectional, byte-oriented,
in-process. The classic shape, one write per read:

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

## Raw file IO

Unbuffered: every `read` and `write` crosses to the kernel.

```emo
def open_read(path String) (R, Int64)
def open_write(path String) (R, Int64)
def open_append(path String) (R, Int64)
def read(fd Int64, n Int64) (R, String)
def write(fd Int64, data String) (R, Int64)
def close(fd Int64) (R, Int64)
```

`open_write` creates or truncates; `open_append` creates or appends;
both open for writing only. `read` returns up to `n` bytes — fewer
when fewer are available, and the empty string at end of file.
`write` returns how many bytes were written.

## Directories and the working directory

```emo
def list_dir(path String) (R, Array[String])
def mkdir(path String) (R, Int64)
def rmdir(path String) (R, Int64)
def unlink(path String) (R, Int64)
def rename(old_path String, new_path String) (R, Int64)
def getcwd() String
def chdir(path String) (R, Int64)
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

`["ocaml", "c", "wasm"]`. The ocaml target builds its os calls on the
host's Unix module; the c target emits direct POSIX calls; the wasm
target lowers the fd, directory, and working-directory half to the
module's syscalls and lowers the process half to a run-time raise —
`fork`, `execv`, `execvp`, `waitpid`, `pipe`, `dup2`, `getpid`,
`getppid`, `_exit`, `isatty`, `argv`, the environment, and the signal
dispositions each name the capability when called (`os_fs_demo` walks
the fd and directory half; `os_demo`, which forks, stays a c golden).
The typescript and beam targets refuse the package.
