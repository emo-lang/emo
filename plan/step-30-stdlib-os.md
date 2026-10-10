# Step 30 — The standard library: `os`

**Milestone:** M11 — The standard library · **Prereq:** step 24 (the
c target — where the POSIX runtime calls live), step 26 (target
independence — the standalone ocaml runtime that also needs the os
dispatch) · **Related:** `stdlib/registry/net` (the other
runtime-backed package whose wiring this follows),
`docs/stdlib/os.md` · **Status:** done on the interpreter, ocaml, and
c targets (2026-10-09); typescript, wasm, and beam refuse the package
by declaration — fork has no meaning where there is no process.

## Why this step exists

The format packages (json, yaml, xml) are pure Emo; `os` is the
second runtime-backed package after `net`, and the first to reach
past IO into process machinery: fork, exec, wait, pipes. That is the
line the README's systems-programming story needs — a language that
cannot fork cannot build a shell, a build tool, or a service manager.
The surface follows Python's os module for the calls a systems
program actually starts with: directory listing, raw unbuffered file
IO, and process control.

## Goal

`require "os"` gives a program its process identity (`getpid`,
`getppid`), `fork`/`execv`/`waitpid`/`_exit`, a `pipe`, raw fd-based
file IO (`open_read`/`open_write`/`open_append`/`read`/`write`/
`close`), and the directory surface (`list_dir`, `mkdir`, `rmdir`,
`unlink`, `rename`, `getcwd`, `chdir`). Every failing call raises an
ordinary Emo exception naming the system call; `waitpid` answers the
kernel's raw 16-bit status word with pure-Emo decoders
(`wait_exited`/`wait_exit_code`/`wait_signaled`/`wait_signal`/
`wait_stopped`/`wait_stop_signal`), and `list_dir` answers
byte-order-sorted names without `.` and `..` — the same order on both
targets.

## Decisions

- **Runtime built-ins, not a scheduler effect.** Unlike `net`'s
  connect/listen (which suspend the fiber scheduler), every os call is
  synchronous: the interpreter dispatches in `apply_builtin`, the c
  target emits calls into `emo_os_*` in the runtime, and the ocaml
  target dispatches through the standalone runtime's `call_builtin`.
- **The raw wait status crosses the boundary.** Only the kernel's
  16-bit encoding is target-independent; the decoders are three pure
  Emo bit operations in the package, so no target needs its own
  `process_status` mapping.
- **Package surface mirrors Python's names** where they are Emo-
  shaped (`getpid`, `fork`, `pipe`, `list_dir`, `getcwd`) — minus the
  ones that need richer machinery (no `stat`, no environ, no
  `system`).

## Follow-ups

- `os` exposes nothing about signals (no handlers, no kill) and
  nothing about file metadata (`stat`) — both are natural next rungs,
  along with `dup2`/`execvp` when a user asks for them.
- The cross-module-types checker step (step 27's follow-up) does not
  gate this package — os.emo crosses modules with native types only —
  but the ts/wasm/beam refusal is by `targets`, not by capability
  detection.

## Tasks

- [x] **T30.1** — The checker signatures and the `os_` builtin
      prefix; the interpreter's Unix-backed dispatch. (Done
      2026-10-09.)
- [x] **T30.2** — The c runtime's `emo_os_*` POSIX implementations
      and the c emitter's dispatch. (Done 2026-10-09.)
- [x] **T30.3** — The standalone ocaml runtime's dispatch (the os
      calls ride the host's Unix module). (Done 2026-10-09.)
- [x] **T30.4** — The package: `stdlib/registry/os/0.1.0` — thin
      wrappers, the wait-status decoders, the fork/pipe discipline
      spelled out. (Done 2026-10-09.)
- [x] **T30.5** — The golden: `examples/os_demo` (raw IO, directory
      create/list/rename/remove, fork+pipe+waitpid with exit-status
      decode) on the bootstrap and c_goldens lists. (Done
      2026-10-09.)
- [x] **T30.6** — The docs: `docs/stdlib/os.md` and its zh-CN
      mirror; `dune build @fmt` and `dune test` green. (Done
      2026-10-09.)
