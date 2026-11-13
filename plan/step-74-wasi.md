# Step 74 — WASI preview1: the rung other toolchains' modules run on

**Milestone:** M35 · **Prereq:** step 72 (the package and its host
interface), 73 (the CLI rung) · **Status:** done

The ladder's third rung: modules from other toolchains run. The
decided surface is **WASI preview1** (`wasi_snapshot_preview1`) — the
standard real toolchains emit (clang/wasi-sdk, `rustc --target
wasm32-wasip1`). The `emo` host module the ladder once named is
**explicitly deferred**: no producer names it — a foreign module
cannot, it does not know Emo — and the design's rule is that a
construct earns its place with a concrete consumer. A module wanting
Emo's host surface takes it through the explicit host table (step 72),
which already serves any module name an Emo program chooses; when a
real producer for an `emo` namespace appears, the rung opens.

## The decided subset

Twelve of preview1's functions, implemented; everything else
link-refuses with the function's name — strictness first, no silent
stubs, and a refusal message a toolchain user can act on:

```
args_sizes_get, args_get            — the argv channel (the CLI's
                                      extra arguments ride here, the
                                      step-73 pressure resolved by
                                      the standard's own door)
environ_sizes_get, environ_get      — empty environment this rung
proc_exit(code)                     — the normal termination path;
                                      unwinds as a trap carrying the
                                      code, and `emo wasm run` maps it
                                      to its exit code
fd_write(fd, iovs, len, nwritten)   — fd 1 and 2 write through the
                                      process output channel (no
                                      newline translation; the iovec
                                      bytes go as they are); other
                                      fds answer EBADF
fd_close, fd_read, fd_seek          — EBADF (nothing is openable this
                                      rung), fd_seek on 1/2 ESPIPE
fd_fdstat_get                       — fd 1/2 answer character device
                                      (what wasi-libc's tty check and
                                      Rust's is_terminal probe touch
                                      at startup), other fds EBADF
random_get(buf, len)                — OS entropy through the rand
                                      package (Rust's RandomState
                                      initializes through it even in
                                      a hello world)
clock_time_get                      — ENOSYS: the language has no
                                      clock primitive yet; the rung
                                      records the pressure rather
                                      than faking a clock
sched_yield                         — answers 0
```

The resolution order grows one built-in: the explicit host table
first (a caller may override any `wasi_snapshot_preview1` import the
way one overrides `spectest`), then the WASI host, then the register
namespace, then `spectest`. WASI state — the argv — is package state
set through the new public `wasm.set_wasi_args(args Array[String])`,
defaulting to an empty argv; the CLI sets it from the artifact's
basename plus any extra arguments.

Errno values are the preview1 numbering, pinned by fixtures:
EBADF 8, EINVAL 28, ENOSYS 51, ESPIPE 69.

## Scope

### In

- `internal/wasi.emo` — the host: the errno names, the function
  table, the memory io the wasi calls need (iovec walks, guest
  writes), the argv store's consumer side.
- The resolution arm and the dispatch arm (host calls touching the
  caller instance's linear memory ride the live machine state —
  `cur_inst` and `mems` are set inside execution, where every wasi
  call arrives).
- `wasm.set_wasi_args` on the package root; the CLI's run subcommand
  taking extra arguments after the artifact and mapping a
  `proc_exit(code)` verdict to its exit code.
- Fixtures: hand-built modules (hex, the corpus discipline) pinning
  fd_write's iovec walk, proc_exit's code, the argv encoding, EBADF
  honesty, and the link refusal naming an unimplemented function. The
  package's `deps` grows `rand`; the demo's lockfile re-resolves.
- **The live check**: a real `rustc --target wasm32-wasip1` hello
  world (target installed with the user's approval, the T64.7
  precedent) through `emo wasm run` — the wasi-libc import list is
  the standard's own witness, and the printed bytes are the verdict.
- Docs: the WASI section in `docs/stdlib/wasm.md` (EN + zh), the
  subset's honest edges (no clock, no filesystem, fds 1/2 only);
  TASKS/plan/CHECK updates.

### Out

- path_open and the filesystem half of preview1 — no preopens, a
  module asking refuses at the link naming the function; the file
  story opens when the runtime's own file surface (the `file`/`os`
  packages' semantics) is decided as WASI preopens, a rung of its
  own.
- wasi preview2 / the component model, threads, sock_* — nothing
  asks.
- The `emo` host module — deferred, per the header's argument.
- Running the output of `emo build --target wasm` (the GC proposal's
  types) — the ladder's exit sign, unchanged.

## Tasks

- [x] **T74.1** — The wasi host: errnos, the twelve functions, the
      memory io, proc_exit's trap, the argv consumer.
- [x] **T74.2** — The resolution and dispatch arms; `set_wasi_args`
      on the package root.
- [x] **T74.3** — The CLI's extra arguments and the proc_exit
      mapping; the driver's entry ladder grows the wasi verdict.
- [x] **T74.4** — The fixtures and the demo lockfile refresh.
- [x] **T74.5** — The live check.
- [x] **T74.6** — The docs and the close-out.

## Acceptance

- `emo wasm run hello.wasm` on a rust-compiled wasm32-wasip1 module
  prints the module's bytes and exits with proc_exit's code; the
  wasi-libc import list resolves through the host with no stubs and
  no fakes.
- The fixtures pin the twelve functions' shapes: the iovec walk
  byte-exact, the argv encoding (pointers then nul-terminated
  buffer), proc_exit's code riding the trap, EBADF/ENOSYS answering
  where the rung refuses, and an unimplemented function failing the
  link with its name.
- `dune runtest` green, `@fmt` green, the wasm_spec/wasm_runs aliases
  untouched and green (the wasi host adds no spec-suite surface).
