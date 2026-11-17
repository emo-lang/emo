# Step 89 — The GC bootstrap: the interpreter's object model and the collector in Emo

**Milestone:** M50 — The GC bootstrap · **Prereq:** none (the doors
ride the interpreter run's own checking; the `gc` package is pure Emo)
· **Related:** `docs/gc-heap.md`, `docs/stdlib/gc.md`,
`examples/gc_demo/`, `CHECK.md` · **Status:** done — the doors admit
on the interpreter run and refuse everywhere else, the collector is
Emo code, and the demo proves the cycle reclamation reference counting
can never reach.

## Why this step exists

The runtime-independence principle (T25.1) says a target's runtime is
written in the language; the wasm runtime (M38) is the precedent. The
garbage collector had no precedent: the reclamation decision (T23.5)
gave the hosted runtimes reference counting over identity objects and
an arena for value families, and explicitly no tracing GC — which
meant cycles were never reclaimed, and the freestanding target had no
collector to grow into. A collector on metal has only one language to
be written in: Emo. The interpreter run is where such a thing is
built — it can host the machine object model as checked doors while
the host's own collector stands in as scaffolding.

## Goal

The interpreter run grows the machine's object model — the fixed
`struct` block, the counted `array` block, the rooted `ref`, and the
walk's doors (`ref_roots`, `heap_blocks`, `heap_free`, `heap_words`)
— as sixteen bare names admitted by the run alone. The `gc` package
implements mark-sweep over them in pure Emo. The demo proves the
acceptance: rooted data survives, garbage dies, and a cycle — the
shape reference counting can never reclaim — dies the moment its root
lets go.

## Decisions settled here

- **The route: bare builtins, the raw-memory family inverted.** The
  peek/poke pattern (checker signature table, per-target admission in
  `base_env`, the refusal by name at the identifier) with the
  interpreter run as the admitting seat: `emo run` checks as the
  target `interpreter`; every build target — `riscv64` included —
  refuses E4032. The admission principle, stated in the doc: a target
  admits the GC heap iff the target's memory is the collector's to
  manage.
- **The word is self-describing by parity.** Even is a scalar, stored
  shifted left one bit; odd is a reference; `0` is null and rides
  reference slots. The tag is the whole typing discipline — the
  collector walks a heap it did not type — and the same bit rule is
  the riscv64 dynamic value model's, so the spec transfers to the
  real-memory hosts later.
- **Slot 0 is the collector's header; the doors are raw.** Data sits
  in slots 1..n; `block_size` answers the logical n. The package's
  accessors shift so caller fields start at 0; no door hides a
  translation.
- **The roots are weak cells; the host collector is the liveness
  oracle.** A `Ref` value's cell registers weakly; a root the program
  dropped empties at the host's next major cycle — no drop verb, the
  use-after-drop class dead by construction. `ref_roots()` forces a
  major cycle before reading, so a collection sees exactly the
  mutator's live set. A `Ref` crosses a process boundary as its own
  cell (the registry is the run's own).
- **The mutator discipline is the rooted-handle rule** (SpiderMonkey's
  `Rooted` shape): a handle a collection must respect lives in a
  `ref`; a bare `var` holding a handle is invisible, and the block it
  names dies at the next `collect`. A collection allocates nothing —
  the worklist is host memory — and the allocation points are
  ordinary package calls, so no pause protocol exists to get wrong.
- **Refcounting stands.** T23.5's model is untouched: this track is a
  library with its own managed heap, not a change to any runtime's
  value model. The relationship is recorded in CHECK.md.
- **M50/step-89 numbering on the develop base.** The wasm track
  (feat/wasm) carries M48–M49 / steps 87–88 on its own branch; this
  track takes the next numbers so the merge reconciles nothing.

## What landed

- `src/emo_check/emo_check.ml` — the `Ref` type, `gc_heap_bindings`
  (sixteen signatures), `gc_heap_builtin`, the `interpreter` row in
  `base_env`, the E4032 refusal arm, `check_module`'s `?target`.
- `src/emo_project/emo_project.ml` — `check_project ?target`, the run
  checking as `interpreter`.
- `src/emo_eval/emo_eval.ml` — the `Ref` value, the heap state (block
  table, ids from 1, the tombstones, the weak root registry), the
  sixteen arms with their loud ends (E3050–E3055), the identity pass
  at the process boundary, per-run reset beside the program
  registries, `Emo_check.Ref`'s total-match arm in the c backend's
  type map.
- `stdlib/registry/gc/0.1.0/` — the package: tagged accessors (the
  shift; `_ref` refusing an even nonzero word, null passing), the
  header dispatch, mark-sweep with the worklist drain, `collect()`
  answering the words reclaimed.
- `examples/gc_demo/` — the fixture and its nine-line golden.
- Tests: `gc_heap_tests` (checker), `gc_refusal_tests`
  (emo_cli), the interpreter-only leg in `test/emo_project`.
- Docs: `docs/gc-heap.md` + zh-CN, `docs/stdlib/gc.md` + zh-CN,
  `docs/stdlib.md` + zh-CN's `gc` row, TASKS + zh's M50 row and
  section, CHECK.md's record.

## Found and fixed

- **The walk stopped one step past the roots.** The first fixture run
  collected 12021 of 12027 words — the array block and the chain's
  tail survived, their children died. `mark_block` pushed every
  reference field into the worklist, and `collect()` never drained
  it: only the roots were marked, never the descendants. The drain
  (a cursor over the builder until it catches up) is the fix, and the
  demo's counts now land exactly (12000 freed, 27 at rest, the cycle
  taking 6 when its root lets go).
- **The demo rooted the chain's tail.** The chain grows head-ward, so
  a root on the first node sees a graph of one. The GC was right to
  collect the rest; the root moved to the head.

## The ladder ahead (named, not built)

The allocator's free list in Emo (the doors allocate from the
interpreter's table today), float and byte payload packing, the moving
or compacting collector the `Ref` indirection already leaves room for,
and the real-memory hosts — a `c` runtime, the riscv64 tagged-word
heap — answering the same doors with the same Emo collector compiled
in.
