# Visualization work — open checks

Written 2026-10-12, on `feat/plot`. This is a temporary working list, not
decided design: it tracks the compiler, language, and backend issues
found while landing the numeric substrate (the float method dispatch and
the `math` package) and the plot T0 skeleton. The plot design itself
lives in [`visualization.md`](visualization.md); the decisions there are
unaffected by this file, except where noted under "Open" below. It is
English-only on purpose — a translation follows only if the file
outlives the work.

## 1. Blocking the plot work

### B1 — the ocaml/c specialization gap: `var` and `case` — resolved

**Symptom.** A function with a real signature (native parameters and
return) that contains a `var` reassignment outside a loop, or a `case`
statement, failed `emo build --target ocaml` with `NONNATIVE STMT ...
Assign` / `... Case`. The `c` target accepted both.

**Cause.** `Emo_ir.stmt_native` classified `Assign_var`, a mutable
`Let`, and `Case` as native, and `Emo_ir.specialize` marked the function
`fspecializable` on that basis, but the ocaml native emitter
`emit_native_stmts` lowered only `Effect`, an immutable `Let`, `If`, and
`Return_stmt`. The predicate and the emitter disagreed.

**Resolved (2026-10-12) — option B, complete the ocaml native emitter.**
It now lowers all three, matching the c emitter and the predicate:

- `var x = init` binds `let x = ref init` and registers `x` as a native
  ref cell; `x = v` emits `x := v`; a read emits `!x`. A new `env.nrefs`
  set keeps the ref cells distinct from the immutable params and
  bindings `env.refs` already tracked.
- a `case` in statement position emits a native `match` whose arms run
  their body and then the rest of the block.
- the mutable `Let` registers its ref **before** the rest of the block is
  emitted, so a later read sees the cell (the ordering bug the first
  attempt hit).

`examples/branch_var` (a `var` in `if`, `case`, and a loop) is the
regression: it runs on the interpreter, `c`, `wasm`, and `beam`, and the
`emo_project` bootstrap suite builds it on `ocaml`.

### B2 — the beam target cannot represent NaN or infinity — resolved

**Symptom.** Erlang floats have no NaN and no infinity, so
`Float64.from_bits` with a NaN/Inf bit pattern cannot work on the `beam`
target (the runtime decodes the bits through the external term format).

**Why it blocked plot.** The design note's `Table` used `NaN` for a
missing number, impossible on `beam`.

**Resolved (2026-10-12).** A missing number is a presence enum, not an
in-band value:

```emo
enum Presence { present, absent }
```

A numeric column is its `Array[Float64]` values plus a parallel
`Array[Presence]`, and the statistics skip the `absent` entries. The type
lives in the `plot` package, not the language core (`CHECK.md`'s tiers:
not syntax-dependent, not universal). `docs/visualization.md` decisions
4, 10, and 25 carry the change. `inf`/`nan` stay unmodelled for now —
`math` raises on overflow rather than returning them, and data rarely
carries infinities; the enum can grow a member if a real need appears.

## 2. Known broken, pre-existing (not from this work)

### P1 — the `runtime/wasm` test rules are red on `develop` — resolved

`dune test` failed the `runtime/wasm` rules with 17 occurrences of
`error[E5004]: module internal has no member instance` / `... model`.
The rules' `deps` enumerated individual `internal/*.emo` files, so the
dune sandbox held an incomplete module tree — and since `emo run`
checks the whole directory tree, a reference to an unlisted module
failed.

**Resolved (2026-10-12).** Each rule now depends on `(source_tree .)` —
the entire `runtime/wasm` directory — so the sandbox tree matches the
real directory. An intermediate `(source_tree internal)` was too narrow:
it pulled in `internal/runlist.emo`, which references the top-level
`wasm` module that those rules did not list. `dune test` is green.

### P2 — `bufio.BytesSink` accumulates quadratically — resolved

`BytesSink.write` was `self.acc.replace(self.acc.read() + data)` — a
full string copy per call, quadratic in the bytes written.

**Resolved (2026-10-12).** `BytesSink` now keeps chunks in a `List` plus
a byte count: a write costs the bytes written, and `to_string` copies
each chunk once into an exact-length buffer. It stays non-draining by
rotating the deque (pop the front, push it back). `examples/bufio_demo`
covers repeated `to_string` and a write after it, and the package docs
say linear. This is a standard-library improvement, not a plot
prerequisite — the plot renderer keeps its own `Buffer` because `bufio`
is native-only (`targets = ["ocaml", "c"]`) while `plot` is all five.

## 3. Resolved this session (for the record)

On `feat/plot`, in rough order:

- the `Float64` method surface on `c`, `wasm`, and `beam`
  (`examples/float_methods`);
- the float-correctness gaps the `math` package surfaced (literal
  precision and methods on TypeScript, float division/modulo on beam,
  C float contraction, NaN equality);
- the `math` package itself, pure Emo and byte-identical on all five
  targets (`examples/math_demo`);
- the numeric literal forms the README promised (hex/binary/octal
  prefixes, digit separators, float exponents);
- a `var` assigned in a beam `if`/`case` threaded out of the branch;
- the ocaml native emitter completed for `var`/`case`
  (`examples/branch_var`);
- the in-memory `bufio` sink made linear;
- the `runtime/wasm` rules' sandbox dependencies fixed;
- the plot T0 skeleton (`plot` package) and its bar-chart demo
  (`examples/plot_demo`), byte-identical on all five targets, with the
  package documented in `docs/stdlib/plot.md`;
- the back-end gaps that blocked it: `String.length` on a binary and
  `Array.append` on beam; beam's class factory returning the instance
  and class dispatch binding the receiver once; `to_string` dispatching
  to a class's own method on beam and wasm; class construction and
  marshaling on c and TypeScript.

## 4. Open — remaining

### R1 — the design note's `plot.mark` is really `mark`

A package's submodules are addressed at the top level, not under the
package name: `require "plot"` then `mark.bar(...)`, never
`plot.mark.bar(...)`. A package-root submodule would also take the
generic top-level name `mark`. `docs/visualization.md` (decision 18 and
the surrounding prose, both languages) still says `plot.mark`; it needs
revision, and the same question applies to the planned `stats` module.

### R2 — checker field types stay `Unknown`

Typing `self.field` precisely is the natural fix for nested field reads,
but it broke the emitters: a native-typed field read on a dynamic
receiver is still boxed, and the emitters key their native/dynamic
choice on the expression's static type alone. Doing it properly means
aligning the emitters with the checker, not just changing the checker.
Until then, marks store their style fields flat — a field of a field is
unknown at check time, which some back ends cannot dispatch.

### R3 — a class method named like a builtin method is shadowed

`to_string` and `length` are emitted by name ahead of class dispatch, so
a class method with that name would be shadowed. `to_string` is fixed
(the class answers first on beam and wasm); `length` is not, and no
library hits it yet.

## 5. Checklist

- [x] **B1** — completed the ocaml native emitter (`Assignment`,
      mutable `Let`, statement `Case`); `examples/branch_var` is the
      regression.
- [x] **B2** — a presence enum (`enum Presence { present, absent }`)
      plus a parallel array; recorded in `docs/visualization.md`.
- [x] **P1** — the `runtime/wasm` rules depend on `(source_tree .)`;
      `dune test` is green.
- [x] **P2** — `bufio.BytesSink` is chunked (linear), non-draining, and
      the docs/demo updated.
- [x] **T0** — the plot skeleton, the bar-chart demo on all five targets,
      and the package docs.
- [ ] **R1** — revise `docs/visualization.md` for the real module path
      (`mark`, not `plot.mark`).
- [ ] **R2** — type `self.field` precisely, with the emitters aligned.
- [ ] **R3** — the builtin-vs-class-method shadowing (`length` first).
- [ ] Then: further plot work — T1 statistics, the other mark families,
      and the terminal/PNG renderers (the design note's later steps).
