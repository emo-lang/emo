# Step 56 — File IO on the wasm target (and the canonical host)

**Milestone:** M22 · **Prereq:** steps 16, 20–22, 31–38, 50 · **Status:** done 2026-11-08

## Why this step exists

Step 16's WASI/IO audit (T16.5) closed with an honest refusal: `file`,
`os`, and `bufio` stayed out of the wasm target because the module's
host boundary carried only `println`, `abort`, and `float_str` — no
way to ask a host for a byte of disk. That left the largest single
capability gap of any hosted target: the pure packages ran, everything
touching the file system did not. The gap had a second, quieter cost —
running a wasm artifact meant hand-copying a `run-wasm.mjs` out of the
docs, while `emo run --target riscv64` booted an ELF in one command.

This step amends the T16.5 trail on the file half. Sockets stay
refused: `net` and `http` remain undeclared for wasm, per the same
audit (Node's WASI preview1 has no usable socket path and preview2 is
component-model shaped — nothing changed there).

## Decisions settled here (the trail)

- **The exchange protocol is syscall + fetch, two calls.** A syscall
  import takes its string arguments as `(ptr, len)` pairs the guest
  wrote through `write_bytes`, and answers `(tag, …)` — tag 0 ok, tag
  1 error — stashing the payload (file contents, or the whole reason
  text) in host state; the guest then calls `emo.fetch(buf, cap)` to
  copy the stash into a buffer it bump-allocated through a new `alloc`
  runtime. Two calls, because `os.read` is not idempotent: a fixed
  scratch area the host writes into (the `float_str` convention) can
  be re-run safely, a read cannot. Count-bearing syscalls
  (`file_write`, `os_write`, the closes) answer `(tag, i64)`, the
  payload size riding the count on the error path.
- **The host formats the reasons whole.** `file: cannot read …: …`
  and `os: <what> <arg>: <strerror>` are spelled in the host against a
  Node error-code → strerror table, byte-identical with the c runtime's
  `emo_os_fail`/`emo_file_*`. The guest carries no message fragments.
- **The os package ships in halves, and says so.** The manifest gains
  `wasm` for the whole package; the fd, directory, and
  working-directory half lowers to syscalls; the process half
  (`getpid`, `getppid`, `fork`, `waitpid`, `pipe`, `execv`, `_exit`)
  lowers to a **run-time raise** naming the capability — the
  interpreter's run-time refusals are the precedent (a bare
  `file.read` off the scheduler is E3009, not a compile error). A
  compile-time refusal would have killed the whole package — its own
  `os.emo` bodies call the process names — and the package-level
  refusal at resolution is coarser than the capability. `os_fs_demo`
  walks the fd half on three targets; `os_demo`, which forks, stays a
  c golden.
- **The canonical host rides the compiler.** `src/emo_codegen/wasm/
  wasm_host.mjs` is embedded as generated data beside the other target
  runtimes; `emo run --target wasm` writes it beside a temp copy of the
  artifact and runs it under Node (refusing with the qemu-style
  diagnostic when Node is missing). The golden tests run the same
  source — one boundary, three copies of the past deleted. The build
  artifact contract is unchanged: `emo build --target wasm` still
  emits `.wasm` + `.wat` and nothing else (step 25's independence
  rule: the host contributes only the emitters).
- **The bump base moves to 65536.** The exchange cursor used to grow
  from 0 toward `float_str`'s fixed scratch at 60000; the base now
  leaves page 0 to the host, and the memory grows to 2 pages so a
  fresh module's first syscalls have room.

## Found and fixed along the way

Two wasm-runtime bugs, both invisible until something needed two live
bump buffers at once (every earlier consumer — `println`, the float
scratch — read its buffer before the next allocation):

- **The bump cursor never moved.** `rt_write_bytes`'s copy loop sat
  directly in its enclosing block; the exit branch (`br_if 1`) jumped
  past the cursor advance, making it dead code. The loop now wears its
  own block, and the advance landed.
- **The grow delta paged the length alone.** Crossing a page boundary
  computed `(len + 65535) >> 16 - memory.size` — negative once the
  cursor rode along — so `memory.grow` failed, its `-1` was dropped,
  and the copy stored out of bounds. `plot_demo`'s second SVG caught
  it; the delta now pages `end`.

## Tasks

- [x] **T56.1** — The protocol and the `file` pair. `emo_wasm.ml`:
      the import table grows `file_read`, `file_write`, `fetch` (and
      the import-relative `rt` index map, so future imports shift
      every defined function mechanically); `Runtime_impl` lowers
      `file_read`/`file_write` to syscalls through the new
      `string_args`/`fetch_string`/`r_pair` helpers; the canonical
      host lands at `src/emo_codegen/wasm/wasm_host.mjs` (generated
      into `emo_wasm_host_data.ml`); the golden tests' inline runner
      is deleted in favor of the shared source; the bump-cursor fix
      above; a scratch probe pins ok and error bytes.
- [x] **T56.2** — The os fd/directory half. Eleven more imports
      (`os_open` with a mode parameter the three `open_*` wrappers
      share, `os_read`, `os_write`, `os_close`, `os_list_dir`,
      `os_mkdir`, `os_rmdir`, `os_unlink`, `os_rename`, `os_getcwd`,
      `os_chdir`); `list_dir`'s payload is a NUL-separated name stream
      the guest splits with the existing `str_split`; `getcwd` drops
      its tag (the host cannot fail it); the process half raises at
      the call; `os.emo`'s header comment states the split; a probe
      pins the fork refusal's message.
- [x] **T56.3** — `emo run --target wasm`. The run arm mirrors the
      riscv64 arm (build into `.emo-build`, probe `node`, run from the
      caller's working directory so relative paths resolve as the
      interpreter resolves them); `emo doctor`'s wasm line names the
      run path when Node is present; the `--target` help and the
      unknown-target refusal name both run targets.
- [x] **T56.4** — Manifests, examples, goldens. `file`, `os`, and
      `bufio` declare `wasm`; `file_read`, `bufio_demo`, and the new
      `examples/os_fs_demo` join the wasm golden list, `os_fs_demo`
      joins the c list and the interpreter exclusion list; every
      lockfile pinning a changed manifest is regenerated (the E5007
      discipline); the test fixtures' root directory is created at
      definition instead of assumed to exist — a wiped temp directory
      had taken every scratch-writing test with it.
- [x] **T56.5** — The exchange-area audit (folded into T56.1: the
      collision the audit looked for was real but secondary — the
      cursor never moved at all until the loop fix, and the grow-delta
      bug was what actually fired on long output).
- [x] **T56.6** — Docs and close-out: `docs/demo-targets.md`'s wasm
      section (the import table, the run path, the capability story) +
      zh mirror; `docs/stdlib/{file,os,bufio}.md` and the
      `docs/stdlib.md` index + zh mirrors; this plan file;
      `docs/TASKS.md`'s Step 56 section + zh mirror; `plan/README.md`'s
      milestone row; `CHECK.md`'s trail.

## Left open, deliberately

- **Sockets.** `net`/`http` stay undeclared for wasm; the T16.5
  reopen condition stands (a preview2/component lowering plus a host
  shim, or a host that grows core-module sockets).
- **`argv`/environment.** The os surface has no argv accessor to
  expose; if one lands, the host can supply it as one more syscall.
- **`os.read` on stdin under a redirected host.** The host maps fd 0
  to Node's stdin synchronously; interactive wasm programs are not a
  golden concern today.

## Acceptance

- `emo run --target wasm` runs `examples/os_fs_demo`, `file_read`, and
  `bufio_demo` byte-for-byte as their `expected.txt` spell them.
- The new wasm goldens (three examples + the two scratch probes) pass,
  the fork refusal names `os_fork`, and every existing golden on every
  target stays byte-identical — `dune runtest` green, 376 tests in the
  CLI group alone, `dune build @fmt` clean.
- `emo build --target wasm` still emits exactly `.wasm` + `.wat`.
