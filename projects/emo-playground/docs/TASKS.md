# emo-playground — the task tracker

The playground is the web app where a visitor writes Emo in the
browser and runs it on the server. The decided design lives in the
[README](../README.md); this file is the ladder.

## M1 — the run loop (the server-side MVP)

- [x] **P1.1** — The curfew: `emo run --curfew SECONDS`, a wall-clock
  deadline the toolchain holds for one interpreted run. Emo has no
  clock (slog's header records the decision), so the one that ends a
  runaway program lives in the interpreter: `Emo_eval` checks the
  deadline every 65,536 steps and raises past it, the CLI renders the
  verdict and exits 124 (the number timeout(1) answers). A `--target`
  artifact does not consult it, and the two are refused together.
  Toolchain tests: the runaway stops at 124, a program that makes its
  curfew is untouched.
- [x] **P1.2** — The run engine: one submission, one fresh directory,
  one child. Two pipes, one fork, one exec of `emo run main.emo
  --curfew N`; stdin from /dev/null; the child's working directory the
  fresh run directory. The parent closes its write ends before the two
  collector processes spawn, each collector drains its stream to EOF
  past the 1 MiB output budget, and the answering connection stays
  parked in receive until both finish. The verdict decodes from the
  raw wait status: ok, compile (65/66), curfew (124), crash, internal
  (127), and a signal death as 128 plus the signal.
- [x] **P1.3** — The run directory's manifest: the standard library's
  hosted packages pinned as dependencies, so a visitor's `require`
  resolves. Off the list: `dom` (browser-only semantics), `syscall`
  (bare metal), and the c-only FFI backends the interpreter cannot
  link. The resolution gate's own E5006 is the refusal a visitor sees.
- [x] **P1.4** — The routes: the editor page and its assets under
  `/web/{path...}`, the example list at `/examples`, one example's
  source at `/examples/{name}`, and the one API call, `POST /api/run`.
  Captures are refused segments that climb before any path is built.
- [x] **P1.5** — The page: an editor, the examples, one Run button
  (Ctrl/Cmd+Enter), and the answer rendered — stdout, stderr, and the
  status worded and colored. No framework, no external resource; the
  curfew in the footer comes from the answer itself.
- [x] **P1.6** — The tests: the engine driven directly (a known
  program's bytes, a compile error naming `main.emo`, the curfew, the
  truncation marker, the sweep), the routes driven the guide's way —
  `parse_head`-built requests against a fresh table — and one test
  over the wire on a port the kernel picks. 21 tests.
- [x] **P1.7** — The examples: hello, fib, types, processes,
  collections — each verified under `emo run` before it ships.

## M2 — the sandbox

- [x] **P2.1** — The fork escape: a submission that calls `os.fork()`
  and lingers held the pipe write ends past its parent's curfew, and
  its connection parked until the server restarts. The fix is the
  process-group discipline: the run child moves itself into its own
  group before the exec (`os.setpgid`, added to the standard library
  beside `os.kill`), so everything it ever forks is in one group
  nothing else on the host belongs to. A second child — the watchdog —
  runs the tick program (a bare spinner the server writes beside the
  run directories once at startup) under its own curfew, the run's
  plus a margin, and the toolchain's deputized kill (`EMO_RUN_GROUP`,
  read once by `emo run`) ends that whole group when the watchdog's
  curfew passes: the write ends close with the group, the collectors
  drain, the answer arrives. The watchdog is forked by the child
  before the exec, so it orphans at the child's death and the kernel
  reaps it: no zombie, no blocking wait. The margin keeps the child's
  own verdict (0, 65, 66, 124) ahead of the kill, and covers the run
  child wedged in a system call, which its own curfew can never reach.
  The child's stderr is a file in the run directory rather than a
  second pipe — a file never blocks its writer, and a second
  collector's read on a silent stderr pipe could starve the stdout
  drain for the whole scheduler. stdlib tests: os_demo's process-group
  section, byte-identical across the interpreter and the c target; the
  wasm refusals for both new names; toolchain tests: the escape's
  answer arriving at the curfew plus the margin, the wedge stopped by
  the watchdog, the broken-emo verdict.
- [ ] **P2.2** — The isolation story: the trust model states plainly
  that user code runs with the interpreter's full library surface on
  the host. A public deployment wants a real boundary — a container or
  a dedicated user with a chroot — named and tested as its own task,
  not a paragraph.
- [ ] **P2.3** — Concurrency limits: one process per connection keeps
  other connections serving while a run is out, but nothing yet bounds
  how many runs may be out at once, or how many connections may park
  waiting. A semaphore owned by a process is the shape the guide's
  store suggests.

## M3 — the reach (open)

- [ ] **P3.1** — More targets on the page: `emo build --target wasm`
  runs in the browser (WasmGC), `--target c` and `--target ocaml`
  compile and run server-side. Each adds an answer the page must
  render honestly — the wasm target's refusals are the language's own.
- [ ] **P3.2** — Sharing: a run's URL carrying the program, so a
  result can be sent. The storage question (nothing? a signed blob?)
  is undecided until P3 is picked up.
- [ ] **P3.3** — The editor's comfort: syntax highlighting, multiple
  files per run. Nothing is decided; the page is deliberately plain
  until then.
