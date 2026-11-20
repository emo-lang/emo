# Step 85 — WASI 0.3: Emo programs as standard command components

**Milestone:** M46 · **Prereq:** step 56 (the wasm target and its
canonical host), 77 (WASI preview1) · **Status:** complete

The wasm target's artifact is a WasmGC module with eighteen `emo.*`
imports, and only the Node canonical host can supply them — wasmtime
compile-validates the shape but cannot execute it (the found-not-fixed
recorded at T56.9). WASI 0.3.0 released 2026-06-11: the component model
with native async, `wasi:io` gone, stdio flipped to guest-supplied
streams, `wasi:sockets` consolidated, wasmtime 46+ shipping it by
default. The track makes `emo build --target wasm --wasi` produce a
real WASI 0.3 command component — a component wrapping the WasmGC core
module — so wasmtime becomes the second execution engine and Emo
programs run on standard WASI runtimes.

The decided surface: a **new flag**, not a new target name. `known_targets`,
the manifests' `targets` arrays, and the lockfile discipline stay
untouched; the default `--target wasm` artifact and the Node host path
are unchanged. The consumer direction (the `wasm` package's interpreter
running foreign 0.3 components) stays out — it would need GC types,
reference types, and the async protocol in an interpreter that has
neither; nothing asks yet.

## Decisions settled by the probe

The probe campaign (2026-11-14, `devtools/wasi03-probe/`, the facts
table and evidence in its README) validated the four load-bearing
assumptions and pinned the encodings:

- **Sync ABI carries the whole component.** An async-typed export can
  be canon-lifted with the sync ABI — wit-component itself emits
  `run: async func() -> result` as `(canon lift ...)` with no async
  option, the async-ness riding the type — and every WASI import
  sync-lowers (blocking happens in the host). No waitable sets, no
  callback, no `task.return`; Emo's single-threaded synchronous model
  maps onto 0.3 without an event loop. The spec names this door
  explicitly: "traditional sync code can export async functions this
  way without any concurrency support".
- **The gate is honest.** The sync variants of the stream builtins
  (`stream.write`, `future.read`) sit behind wasmtime's
  `-W component-model-more-async-builtins=y` — the 🚝-gated extension,
  not yet in the standard's default set. The run path passes the flag;
  the pressure to drop it (by moving writes onto the async builtins +
  a waitable-set poll loop, or onto the standard async ABI) is
  recorded here rather than faked away.
- **The stdout protocol is pinned end to end** (probe README, facts
  6–8): `stream.new` answers one packed i64 (low 32 readable, high 32
  writable); the readable end transfers into `write-via-stream` and
  the host drains and drops it — the guest never drops it; sync
  `stream.write` completes only as the host consumes (a readerless
  write never returns, so the buffer-all-then-hand-off order is the
  only deadlock-free sync order); `stream.drop-writable` is the EOF;
  `future.drop-readable` is the guest's only cleanup.
- **The import shape is what `use` makes it.** `wasi:cli/types@0.3.0`
  is its own instance import (the `error-code` enum); `wasi:cli/stdout@0.3.0`
  aliases that outer type and re-exports it `(eq ...)`. A
  self-contained enum inside the stdout instance is rejected by
  wasmtime's world matching. Version strings pinned at `0.3.0` (the
  probe validated them; the main-branch package is `0.3.2`).
- **The memory cycle has a provider answer.** `canon lower` with a
  memory option needs the memory before the guest module exists, and
  the guest's memory is its own — so the guest *imports* its memory
  from a one-section provider core module instantiated first (the
  route wit-component's shim/fixup machinery avoids by indirection;
  the provider needs none of it).

## The component shape

```
(component
  (import "wasi:cli/types@0.3.0" (instance ...))      ; error-code
  (import "wasi:cli/stdout@0.3.0" (instance ...))     ; write-via-stream
  (import "wasi:cli/stderr@0.3.0" (instance ...))     ; write-via-stream
  (import "wasi:cli/exit@0.3.0" (instance ...))       ; exit, exit-with-code
  (core module $prov (memory ...))                    ; the memory provider
  (core instance $prov (instantiate $prov))
  (alias core export $prov "memory" (core memory $mem))
  (core func ... (canon lower ... (memory $mem)))     ; the lowered WASI funcs
  (core func ... (canon stream.new/stream.write/...)) ; the stream builtins
  (core instance $host (export ...))                  ; synthetic, feeds $main
  (core module $main ...)                             ; the Emo WasmGC module,
                                                      ; memory imported
  (core instance $main (instantiate $main (with ...)))
  (alias core export $main "run" (core func $run))
  (func $run (type (func async (result (result)))) (canon lift (core func $run)))
  (instance $run-i (export "run" (func $run)))
  (export "wasi:cli/run@0.3.0" (instance $run-i))
)
```

## The syscall remap (--wasi mode)

| 18-import surface | WASI 0.3 destination |
| --- | --- |
| `println` | stdout buffered guest-side, flushed through the stream protocol at exit and before abort |
| `abort` | stderr through the stream protocol, then `exit-with-code(1)` |
| `float_str` | guest-side `%g` formatting (the host import is retired in this mode; the c runtime's rule ported into the wat-level runtime) |
| `fetch` | retired — the canonical ABI's retptr returns replace the two-phase stash |
| `file_read`/`file_write`, the `os` fd/directory half | `wasi:filesystem@0.3.0` preopens + types, the guest keeping the fd↔descriptor table |
| `rand_bytes` | `wasi:random@0.3.0` `get-random-bytes` (short returns looped) |
| `os_getcwd`/`os_chdir` | refuse by name — 0.3 has no cwd concept (the `environment` interface's `get-initial-cwd` is a hint, not a filesystem fact) |
| the `os` process half | unchanged — the run-time raise naming the capability |
| fd 0 reads | refuse this rung — `stdin.read-via-stream` returns a stream the sync guest can only consume through the gated builtins; the honest refusal names the door |

## Scope

### In

- `src/emo_codegen/emo_component.ml` — the component-level AST, the
  binary writer, and the component WAT printer (the `.wat` sibling
  convention carries over).
- `emo_wasm.ml` — the import table and the `Runtime_impl` lowering
  parameterized by the ABI mode; the guest-side `%g` runtime function;
  the buffered stdout/stderr channels.
- The CLI: `emo build --target wasm --wasi`, `emo run --target wasm
  --wasi` (wasmtime on PATH, exit 69 without it, the flag passed
  through), the `emo doctor` wasm line grown to report wasmtime.
- The goldens: a `wasm_wasi_examples` group mirroring
  `wasm_examples_tests` (skipping when wasmtime is absent), the
  supported subset of the 65 wasm goldens byte-identical with the
  Node/c targets, the known refusals pinned by name.
- `devtools/wasmtime-smoke.sh` grown with the component execution rung.
- Docs: the `--wasi` section in `docs/demo-targets.md` (EN + zh), the
  ledger updates (plan row, TASKS milestone M46 + step section,
  CHECK.md decision + trail).

### Out

- The consumer direction — the `wasm` package interpreter instantiating
  foreign 0.3 components (GC types, reference types, the async protocol:
  nothing asks).
- `wasi:sockets` / `wasi:http` — the wasm target has no network story;
  `net`/`http` already refuse at resolution.
- The async ABI (waitable sets, callbacks, stack switching) — the sync
  door carries the rung; recorded as the follow-up if a runtime's
  default-flag posture or concurrency earns it.
- `wasi:clocks` — the language has no clock primitive (the step-77
  stance unchanged). *Superseded 2026-11-20: the `time` package
  landed, and the rung closed as T85.9 below — the refusal this line
  named was the pressure.*

## Tasks

- [x] **T85.1** — The probe campaign: the four load-bearing facts, the
      encodings, the stdout protocol, the exit channel
      (`devtools/wasi03-probe/`).
- [x] **T85.2** — The component encoder (`emo_component.ml`): the AST,
      the binary writer, the component WAT printer. Validated
      end-to-end: `emo run --target wasm --wasi` on hello_world prints
      the expected bytes under wasmtime 49 and exit codes propagate.
- [x] **T85.3** — The ABI mode in `emo_wasm.ml`: the remapped import
      table, the memory provider, the stdout/stderr stream cycles.
      The guest-side `%g` port ran the fixed-form path byte-identical
      with the node host over the whole float ladder before the
      wat-level exp-form bugs halted it (see the found-not-fixed
      below); this rung ships the honest refusal instead.
- [x] **T85.4** — The CLI flag surface (build/run/doctor).
- [x] **T85.5** — The filesystem, random, and environment imports; the
      refusal pins. The component grows `wasi:filesystem`
      (types + preopens, the descriptor as a `(sub resource)` export,
      the 37-case error-code variant with `other(option<string>)`),
      `wasi:random`, and `wasi:cli/environment`; the provider grows
      the realloc the host-written results allocate through (the
      cursor cell shared with the guest bump allocator); the guest
      grows the preopen table, the path resolution, the fd table,
      and the bounded stream read/write cycles. hello, argv, and the
      environment read back correctly under wasmtime; the relative
      paths anchor on `get-initial-cwd`, falling back to the root
      preopen. The os half's file chain still answered no-entry at
      this task's close (the T85.7 round healed it — see found and
      fixed below).
- [x] **T85.6** — The goldens: `wasi_examples` — 43 demos
      byte-identical with the Node list — skipping without
      wasmtime; `devtools/wasmtime-smoke.sh`'s execution rung
      (39/39 byte-identical); `docs/demo-targets.md` EN+zh; the
      ledger rows (TASKS M46 + step section, this plan, CHECK).
- [x] **T85.7** — The file chain's last mile: five guest-side bugs,
      each pinned by a probe (the handle value thrown through the
      abort door, the preopen table's words dumped cell by cell) and
      each gone. The provider's realloc stored its new cursor with
      the address as the value (the store's operand order again) —
      the cell never advanced, every host allocation landed at the
      same address, and the answers overwrote each other; the value
      256 in a preopen's descriptor slot was the cell's own address.
      `fs_init`'s copy loop and the resolve scan rode their bare
      loops — the `br_if 1` exit landed on the enclosing block's
      label and returned early (fs_init skipped the count store and
      the cwd fetch; resolve skipped the best-match pick and dropped
      absolute paths into the relative fallback, which pasted a
      second slash onto an already-absolute path — wasmtime refused
      the result as outside the filesystem). Both loops now ride a
      wrapping block. The write cycle read the future's error-code
      cell unconditionally — the ok case carries no payload, so a
      successful write answered the cell's stale earlier content
      (open-at's handle byte, "Bad file descriptor"); the tag now
      decides. `os_write`'s fd dispatch read `(fd <= 0) && (fd > 2)`
      — always false, the fs half dead, every file write a fake
      success; the two legs are an `or`. The directory door was
      never wired: the directory-entry `stream.read` canon builtin
      had no import (the scan rode the u8 read and trapped on the
      type), so the guest grew `read-dir-entries` and the scan its
      batch shape — slots as the enumeration progresses, a zero
      count with the stream open a retry, only the closed status
      ends it, the record at 24 bytes with the name's (ptr, len) at
      +16/+20, zero-length slots skipped. The bubble pass swapped on
      `cmp < 0` — descending; now `cmp > 0`. The harness maps the
      entry directory onto the guest root (`--dir <dir>::/`; the
      cwd hint answers none under wasmtime, so the preopen root is
      the only anchor a relative path has), and `os_getenv` answers
      its scan again (the probe dump rode the committed tree). The
      goldens grow to 46: `file_read`, `bufio_demo`, and
      `os_fs_demo` join `wasi_examples` byte-identical with the
      Node list; the smoke rung runs 42/42.
- [x] **T85.8** — The guest-side `%g`: the node host's
      `floatStr`/`g6` rule ported wat level (the integral digits + `.0`
      off the i64, six significant digits fixed and exponent forms,
      the signed zero-padded exponent), seven wat-level bugs found
      and fixed on the way (see found and fixed below), the twenty
      float-rendering demos joining the goldens (66; the smoke rung
      62/62).
- [x] **T85.9** — The clocks rung (2026-11-20): the two
      `wasi:clocks@0.3.0` doors the time package's clock half lowers
      onto — `system-clock`'s `now` (the `instant` record riding the
      retptr, memory option, no realloc) and `monotonic-clock`'s `now`
      (the mark as one flat i64, the bare lower), the probe campaign
      pinning both shapes and the valtype bytes (facts 19–21), the
      `time_now_ms`/`time_mono_ns` doors lowering onto them (the
      milliseconds composed off the record, the sub-millisecond tail
      truncated), `clock_demo` joining the goldens (67; the smoke rung
      aligned), docs EN+zh grown. See the section below.

## Found and fixed (the encoder's first landing)

- The bare WIT `result` is its own type definition; an inline
  `(result)` in a param slot silently shifts the inner type indices.
- `use` splits an interface into two instance imports; a
  self-contained enum inside the stdout instance fails wasmtime's
  world matching.
- `stream.new` answers one packed i64 (low 32 readable, high 32
  writable); the readable end transfers into `write-via-stream` and
  the host drops it — the guest never does.
- Sync `stream.write` completes only as the host consumes; the
  hand-off must precede the writes.
- The canon-lower cycle (the lowered functions write through the
  guest's memory) breaks with a one-section memory provider the guest
  imports, no shim/fixup needed.
- The canon `lower` takes the memory option only when the lowered
  function touches linear memory.
- Section 1 (the embedded core module) is a single module, no vector
  count; every other compound section's payload carries its count.
- Core inline exports carry plain names and the core ExternalKind
  byte; component-level inline exports carry name attributes and the
  component sort. Exports end with the ascribed-type byte (0x00).
- The canon-lift of an async-typed export carries no async option —
  wit-component's own encoding.

## Found and fixed (T85.5's landing)

- The component-level valtype has no inline handle form: own/borrow
  are deftypes (`0x69`/`0x68` + resource index) declared inside the
  instance type and referenced by index, never spliced into a param.
- A `variant` case carries a trailing zero byte per case; the
  wasi:filesystem error-code is a **variant** (the cli one is an
  enum) and wasmtime's host carries **37 cases** — the 36 normative
  ones plus `other(option<string>)`; a smaller guest variant fails
  the linker case-by-case. All the named fs types (flags, error-code,
  descriptor-type, directory-entry) needed `(eq)` exports for the
  host's world match.
- `tuple<own descriptor, string>` in get-directories, the option
  tag/pointer/len read-backs, and every host-written result ride the
  retptr + **realloc** — the realloc cannot reference a guest export
  (the lowers exist before instantiation), so the provider module
  grew the canonical realloc: shrink-in-place, aligned bump off the
  shared cursor cell at 0x100, grow-with-copy. The guest's wasi-mode
  bump allocator advances the same cell — the two allocators never
  overlap.
- `I32_store` pops value first, address second — five sites pushed
  them swapped (the init-time cursor cell, the bump advance, the
  preopen count, the fd-slot clear). The symptom chain: the cursor
  cell read 0, so the host realloc and the guest bump allocator both
  allocated from address 0 and overwrote each other's data, which
  read back as handle-shaped garbage and desc=0.
- `bytes_from_mem` answers a bare `$bytes` array; two list-scan
  loops fed it straight to `bytes_to_str` (which casts `$vbytes`)
  — the missing `Struct_new t_vbytes` tripped the cast on the first
  environment/argv element.
- get-environment/get-arguments/get-directories answer `(retptr)→()`
  with the list at the retptr: (ptr, len) at +0/+4, elements of 8
  (string), 12 (tuple<own,string>), and 16 (tuple<string,string>)
  bytes. The async-typed fs doors sync-lower with a retptr and no
  core result — create/remove/unlink/rename write the result
  variant's discriminant at +0 and the error-code's own discriminant
  at +4.

## Found and fixed (the T85.8 round, 2026-11-15)

**The guest-side `%g` renders every float.** The node host's
`floatStr`/`g6` rule ported wat level: -0 as `-0.0`; an integral
value under 1e16 as its digits + `.0` off the i64 (never a floating
scale); six significant digits fixed between 1e-4 and 1e6 — the
decimals read off |v| by comparisons against the powers, the digits
off the scaled i64 — and exponent form outside with the mantissa
rounded to five decimals, the carry to ten riding the double
division the host's own code takes, and the signed zero-padded
two-digit exponent. The 2026-11-14 session's fixed-form port had run
the ladder byte-identical and then died in the exp form; this round
rebuilt the whole formatter and closed seven wat-level bugs, each
pinned by a probe (the abort door as the print, `WASMTIME_LOG=trace`
for the host's view, a process sample of the spinning loop):

- the NaN test compared `v` with nothing — the second operand of the
  `f64.eq` was missing;
- the decimal-exponent guess multiplied `log10(2)` into an i64 — the
  extend had no convert, an f64 mul sat on an i64;
- the exponent-suffix digit loop's `store8` had no address operand;
- the fixed-form decimals chain's pairing was off by one (the
  `1e4 → 1` pair lost, every threshold answered its neighbor's
  decimals);
- the finder's up-adjust loop exited on the inverted comparison —
  for a value below its guess's power of ten the loop multiplied
  forever (the infinite spin the process sample caught, four hot
  instructions `mul/set/add/set`);
- the digit write loop took its remainder from the scratch copy the
  count loop had already divided to zero — every integer digit
  rendered as `0`;
- the exponent suffix's pad `0` collided with the backward digit
  walk (the pad first, then the digits ending at the pad's slot —
  the pad written before the walk's first decrement).

The twenty float-rendering demos — the math family, json, map,
toml, plot, typed_calls, typed_methods, float_methods, field_types,
fixed_width, list — joined `wasi_examples` (66 goldens
byte-identical with the Node list); the smoke rung runs 62/62. And
the `other` case (36) of the fs error-code now reads its payload:
the host's own text rides the answer variant as an
`option<string>` — the option's tag at retp+8, the string's
`(ptr, len)` at retp+12/+16 (canonical-ABI nesting, confirmed by a
forced-36 probe reading the none tag of a bare-case answer) — and
`wasi_err_text` takes the retptr to render it, falling back to the
fixed text when the option is none. Previously every such error
answered the fixed "the host refused the operation".

## The clocks rung (T85.9, 2026-11-20)

The step closed with `wasi:clocks` out because the language had no
clock primitive. The `time` package landed two days later, the
preview1 host answered `clock_time_get`, and the refusal this plan
recorded became the pressure: a program calling `time.now()` built
under `--wasi` hit the remap's catch-all and answered the honest
by-name refusal — while the same program ran on the Node leg. The
rung grew the two doors:

- `wasi:clocks/system-clock@0.3.0` — 0.3 renamed the 0.2 wall-clock
  and re-spelled its record: `instant { seconds: s64,
  nanoseconds: u32 }` (s64 — the pre-epoch instants are
  representable). The sync lowering rides the retptr (two flat
  results, past the ABI's one-flat limit), the `(memory)` option and
  no realloc — the host allocates nothing; the fields sit at +0 and
  +8, the declaration order the canonical ABI's layout. The named
  record takes the `(eq)` export; the interface's `use
  types.{duration}` stays out of the subset (nothing references it).
- `wasi:clocks/monotonic-clock@0.3.0` — `now: func() -> mark`, the
  `mark` alias riding the inline u64 primval (the filesize
  precedent): one flat result, the bare lower, no memory option.

The probe campaign (`clock_probe.wat`, facts 19–21) pinned the shapes
before the encoder landed, and caught the one wrong byte on the way:
the first s64 encoding used `0x76`, and wasmtime's linker read the
field as f32 ("expected `s64` found `f32`") — the reference record
assembled by wasm-tools with every integer width gave the true table
(s64 `0x78`, u32 `0x79`; the standing u8/u64 bytes confirmed). The
guest composes `time_now_ms` as `seconds * 1000 + nanoseconds / 1e6`
(the sub-millisecond tail truncated, matching the Node host's epoch
ms) and boxes `time_mono_ns` straight off the mark. The demo
(`clock_demo`) prints derived facts only — the wall against fixed
moments, never going back inside a process, the monotonic
nondecreasing — and rides all six legs byte-identically; the BEAM's
monotonic epoch reads negative on this machine (erlang's
`monotonic_time` carries no sign contract), so the positivity pin the
preview1 fixture asserts stays out of the demo's surface.

## The gate decision (settled 2026-11-15, T85.8's round)

- **The more-async-builtins gate stays.** The sync stream builtins
  ride wasmtime's `-W component-model-more-async-builtins=y` — the
  🚝-gated extension. The run path passes the flag, and the flag
  exists on the stable wasmtime release the goldens run, so the
  dependency is one explicit CLI word on a shipped runtime — not a
  nightly build. Dropping it means the async lowering plus a
  waitable-set poll loop (the async ABI's territory), which swaps
  the flag for the equally default-off `component-model-async`
  after a probe campaign and producer surgery — real work for a
  different flag name. The probe pinned the rewrite's starting
  point anyway (`devtools/wasi03-probe/wait_probe.wat`, README
  facts 17-18): the waitable-set machinery — `new`, `drop`, and
  the synchronous `wait` at `(param i32 i32) -> i32` under a
  `(memory)` option — is already **ungated** on stock wasmtime; the
  gate covers exactly the sync stream/future read/write builtins,
  and the ungated failure mode is honest and early (parse-time,
  naming `stream.write`). Revisit when wasmtime flips a default or
  a second runtime matters. The two leftover cosmetics closed in the
  same round: `emo doctor` grew the wasi line it had promised
  (wasmtime's presence and version, `emo run --target wasm --wasi`
  named as the consumer), and the smoke rung's list caught up with
  the golden group — the four macro demos joined, and the rung now
  runs the same 66 the dune group runs (66/66).

## Found and fixed (the T85.7 round, 2026-11-15)

The os half's file chain closed: `file_read`, `bufio_demo`, and
`os_fs_demo` run byte-identically under wasmtime and joined the
golden group. The last mile was five guest-side bugs, none of them
where the first reading pointed:

- **The provider's realloc stored its new cursor with the operands
  swapped** (the store pops value then address — the same family as
  T85.5's five sites, this one hand-encoded in the provider
  module): the cell never advanced, every host allocation landed at
  the same address, and the host-written answers overwrote each
  other. The "unknown handle index 256" the first probes hit was
  the cursor cell's own address (0x100) sitting in a descriptor
  slot.
- **`fs_init`'s copy loop exited through the function's own
  label** — the loop sat bare in the body, so the `br_if 1` that
  should have fallen through to the count store returned early:
  the count cell stayed zero and the cwd hint never fetched.
- **The resolve scan's exit skipped the best-match pick** (the
  same bare-loop shape): an absolute path fell through into the
  relative fallback, which pasted a second slash onto it; wasmtime
  refused the doubled path as outside the filesystem — the
  "Operation not permitted" the absolute probes answered.
- **The write cycle read the future's error-code cell
  unconditionally**: the ok case carries no payload, so a
  successful write answered whatever the cell held from the
  earlier open-at (its handle byte — "Bad file descriptor" on
  every write that actually landed).
- **`os_write`'s fd dispatch read `(fd <= 0) && (fd > 2)`** —
  always false, the fs half dead, every file write a fake success
  (the byte length returned, nothing written). The two legs are an
  `or`.

With the chain alive, two more doors grew: the directory-entry
`stream.read` canon builtin had no import (the scan rode the u8
read and trapped on the type — "a stream of a different type"), so
the guest grew `read-dir-entries` and the scan its batch shape —
the host fills slots as the enumeration progresses, a zero count
with the stream open is a retry, only the closed status ends it,
the record rides 24 bytes with the name's (ptr, len) at +16/+20,
and zero-length slots skip. The bubble pass swapped on `cmp < 0`
(descending); it swaps on `cmp > 0`. The harness maps the entry
directory onto the guest root — `get-initial-cwd` answers none
under wasmtime (`Ok(None)` in the trace), so the preopen root is
the only anchor a relative path has — and `os_getenv` answers its
scan again instead of the probe dump that had ridden the committed
tree.

## Acceptance

- `devtools/wasi03-probe/run.sh` green (stdout `hello`, exit 42).
- `emo run --target wasm --wasi examples/hello_world/main.emo` prints
  the expected bytes and exits 0 under wasmtime.
- The supported golden subset runs byte-identically under wasmtime;
  the Node path and the c targets regress nothing.
- `dune runtest` green, `@fmt` green.
