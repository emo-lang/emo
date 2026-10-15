# Step 50 — Cross-target conformance

**Milestone:** M17 — Cross-target conformance · **Related:** `CHECK.md`
(the settled entry and the corrected cost estimate), `docs/intro/
concurrency.md` (the process promises), `docs/intro/syntax.md`
(Mutability — the snapshot promises), `plan/step-49-value-reclamation.md`
(the arena limit the copied aggregates inherit) · **Status:** done —
T50.1 through T50.4 landed 2026-10-15; the `typescript` send gap stays
open and is named below.

## Why this step exists

A 2026-10-14 target-feasibility survey needed each cross-target rule
stated exactly, checked the rules against the implementations, and found
three disagreements (`CHECK.md`, cross-target invariants). All three
were recorded as one open item because the survey could not tell, from
the outside, which half was wrong — the promise or the code.

Reading the promises settles it. Two of the three are not design
questions at all:

- `docs/intro/concurrency.md:11` promises that an unhandled error "kills
  only the offending process"; the root process is the program, and a
  raise elsewhere ends only that process.
- `docs/intro/syntax.md` promises a snapshot copy at the process
  boundary for Map, Box, List and ArrayBuilder alike; the interpreter
  implements it (`emo_eval.ml`'s `snapshot`), the standalone OCaml
  runtime implements it, BEAM gets it by construction, and
  `stdlib/registry/sync/0.1.0/sync.emo:16-18` documents it for a sent
  handle in as many words. T12.4 is already `[x]`.

So the `c` target was the outlier, not the spec. The work is
conformance: **no promise moves, no README change, no language surface
change.** The third item is the same shape on the emitter side — the
capability table is the intended sole gate on `foreign def`, but the
table admits `Float64`/`String`/`Bool` on every target and only the
`c`-only rows (`Int64`, `Void`) block a declaration, so a
marshaling-tier `foreign def` reached the `wasm` and `beam` emitters
past the gate entirely.

## The survey's cost estimate was wrong

Worth recording, because it is the reason this step is small. The
`CHECK.md` entry priced the `raise` gap as "the per-fiber unwind the
`catch` design was refused for" — `setjmp`/`longjmp` plus a
reference-count drain at every unwound C frame — and on that price the
alternative (narrow the promise to the interpreter and BEAM) looked
competitive.

The runtime already had the whole mechanism. The autorelease pool is a
**heap-allocated frame chain hung off the fiber** (`emo_process.
top_frame` → `emo_frame.parent`, `src/emo_codegen/c/emo_c_runtime.c`),
so a fiber's frames are reachable without touching the C stack;
`emo_process_halt_current()` already ends a fiber by swapping to the
scheduler and never returning — that is how every `makecontext`'d fiber
ends today; and the scheduler already reaps a finished fiber's stack and
already treats only the root's finish as program end. The fix is one
drain helper plus two call sites. No `longjmp`, no unwinding, no emitter
change.

## Tasks

### T50.1 — `foreign def` refuses on `wasm` and `beam`

`emo_wasm.ml` and `emo_beam.ml` refuse per function, beside the code
that would have lowered it, with the shape `emo_riscv.ml` already uses:
`raise (Emo_ir.Lower_error "the <target> target does not support
\`foreign def\` yet")`. The CLI renders that as `emo build: …` on
stderr and exit 65 — the code the `Map` and `ArrayBuilder` refusals
carry.

The survey's open question was whether a stray `foreign def` "ends in a
clean refusal downstream or a silently absent symbol". It was the
second: the IR carries the symbol in `fforeign` on an otherwise ordinary
`func` record with `fbody = []` (`emo_ir.ml`), so both emitters were
emitting an **ordinary function for a declaration that has no Emo
body** — a symbol that is never defined. Neither file mentioned
`fforeign` anywhere before this.

### T50.2 — The `c` target's `raise` ends the logical process

`emo_raise` branches three ways:

- outside the scheduler, or in the root process → unchanged: render
  `uncaught exception: …` and `exit(1)`. That is T23.6's E3010
  rendering, and the root's death is the program's end.
- in a spawned process → drain its own frame chain and halt it, with
  `emo_process_halt_current`.

`halt()` routes through the same drain. It abandoned its frame chain,
leaking every pooled identity — the one other site with the identical
shape, so the helper makes it a one-line change.

Result matches the interpreter's split (`emo_sched_det.ml`): the root's
raise prints and exits 1; a child's raise kills only the child and
prints nothing.

### T50.3 — The `c` target's `send` snapshots

`emo_deep_copy` sits beside the mailbox and `emo_process_send` stores
`emo_deep_copy(message)`, following the interpreter's rule
(`emo_eval.ml`'s `snapshot`) over the kinds this runtime has:

| rebuilt (fresh cell) | passed through |
| --- | --- |
| `Box`, `Bytes`, `Tuple`, `Array`, `List`, `ArrayBuilder`, `Map`, `Instance` | `Int64`, `Float64`, `String`, `Enum`, `Closure`, `Pid` |

Instances copy their fields and keep the class; a map copy preserves
insertion order — the interpreter's per-kind detail, not just its shape.
The pass-through set is the interpreter's own `| v -> v`: immutable data,
or the identity the boundary deliberately shares. The interpreter's `Obj`
case has no `EMO_OBJ` counterpart here, so it is skipped.

One emitter line followed: the mailbox take releases its **only** claim
on the snapshot, and the take happens before the receive branch binds
the value, so the scan now holds its own
(`emo_autorelease(emo_retain(...))` in `emo_c.ml`). Without it the value
is freed between take and bind for every identity-bearing kind.

Copied arena aggregates leak exactly as every arena aggregate does —
step 49's already-documented limit, not a new one.

### T50.4 — Docs

`CHECK.md`'s cross-target entry rewritten as settled, with the corrected
cost estimate and with the `typescript` send gap named as its remainder;
`docs/intro/concurrency.md`'s by-reference sentence fixed (it was stale
for `ocaml` already and wrong for `c`); T23.6's note updated; the gates
table updated; this milestone added. The zh-CN mirrors follow.

## Left open, deliberately

- **The `typescript` target still shares on send.**
  `ts_runtime.ts:2378-2389` stores the reference, verified by running the
  T12.4 program under `node`: interp/ocaml/c print `1\n99\n`, typescript
  prints `99\n99\n`. `wasm`'s `rt_send` (`emo_wasm.ml`) does the same,
  though that target refuses this program's shape for unrelated reasons.
  The same conformance gap, on the target whose runtime is being split
  for the browser — the fix belongs with that split (T48.10), so it is
  recorded rather than fixed here.
- **A process-exit signal on `c`.** `docs/intro/concurrency.md:11`
  promises "the process-exit signal a supervisor needs"; the interpreter
  has it (`exit_info`, `exit_hooks`) while the `c` runtime has only
  `int finished`. After T50.2 a child dies *unknowably* — a faithful
  match for the interpreter's silent `Exit_raised`, but a supervisor
  still cannot observe it on `c`. A separate gap, for a separate task.

## Acceptance

- A `foreign def` program refuses on `wasm`, `beam`, `typescript` and
  `riscv64` with exit 65, while `c` builds it and — the half that shows
  the declaration is not being stubbed out — runs it, `floor(2.5)`
  answering 2.0. The test asserts that disjunction across the whole
  target matrix rather than naming the targets known to have been
  broken, so a target that silently emits a body-less function again
  fails it. (`typescript` and `riscv64` reach their refusal through a
  different path — an up-front check and their own `refuse` helper — but
  the same `Lower_error` and the same exit code.)
- A child `c`-target process that raises dies alone and its parent runs
  on; the root's raise still prints the interpreter's message and exits
  1, unchanged.
- A mutable value sent between `c`-target processes arrives as a
  snapshot.
- Every shared golden (`examples/<name>/expected.txt` — one file per
  example, used by the interpreter, wasm, beam and `c` runners)
  byte-identical, and the reclamation probe still returns the identity
  count to baseline after the churn loop, proving the new drain leaks no
  frames.
- `dune build @fmt` clean and `dune test --force` green.
