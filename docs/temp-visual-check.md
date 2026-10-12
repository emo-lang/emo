# Visualization work — open checks

Written 2026-10-12, on `feat/plot`. This is a temporary working list, not
decided design: it tracks the compiler, language, and backend issues
found while landing the numeric substrate the plot work needs (the float
method dispatch and the `math` package). The plot design itself lives in
[`visualization.md`](visualization.md); the decisions there are unaffected
by this file. It is English-only on purpose — a translation follows only
if the file outlives the work.

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

### P1 — the `runtime/wasm` test rules are red on `develop`

`dune test` fails the `runtime/wasm` rules with 17 occurrences of:

```console
error[E5004]: module `internal` has no member `instance`
error[E5004]: module `internal` has no member `model`
```

The rules' `deps` (in `runtime/wasm/dune`) list only the `internal/*.emo`
files a fixture happens to reach, so the dune sandbox's module tree is
incomplete and the checker cannot resolve `internal.instance` /
`internal.model`. Reduced to the committed tree with all of this work
stashed, the same 17 errors appear, so it predates the plot branch; the
fix is to list the whole `internal/` subtree (or depend on the
directory) in those rules.

### P2 — `bufio.BytesSink` accumulates quadratically

`BytesSink.write` is `self.acc.replace(self.acc.read() + data)` — a full
string copy per call, so building a document through it costs time
quadratic in the bytes written. Noted in `docs/stdlib/bufio.md`; the plot
renderer therefore needs its own chunked `Buffer` (see the design note's
"output buffer" decision). The stdlib fix — a chunked sink, joined once —
is planned but not done.

## 3. Resolved this session (for the record)

Commits on `feat/plot`, oldest first:

- `4120a23` — `Float64.{sqrt,floor,ceil,trunc,to_int64}` and
  `Int64.to_float64` on `c`, `wasm`, and `beam`; `examples/float_methods`
  golden on the interpreter and those three.
- `483e2de` — float-correctness gaps the `math` package surfaced: the TS
  emitter cut float literals at twelve significant digits and its runtime
  lacked the float methods; `beam` `emo_div`/`emo_mod` had no float arm;
  the `c` build now passes `-ffp-contract=off` so an FMA cannot drift a
  bit; the interpreter and ocaml runtime treated `NaN` as equal to itself.
- `cc968f8` — the `math` package (pure Emo, all five targets, byte-for-byte)
  and `examples/math_demo`.
- `a9eed3c` — the numeric literal forms the README already promised:
  `0x` / `0b` / `0o` prefixes, `_` separators, and float exponents.
- `371ed9b` — a `var` assigned in an `if`/`case` is threaded out of the
  branch on `beam`, which used to leave it "unbound variable"; `math.log`
  is back to the natural spelling, so the `math_demo` beam golden covers
  it.

## 4. Decision checklist

- [x] **B1** — completed the ocaml native emitter (`Assignment`,
      mutable `Let`, statement `Case`); `examples/branch_var` is the
      regression.
- [x] **B2** — a presence enum (`enum Presence { present, absent }`)
      plus a parallel array; recorded in `docs/visualization.md`.
- [ ] **P1** — fix the `runtime/wasm` rule `deps` so `dune test` is green?
- [ ] **P2** — make `bufio.BytesSink` chunked (stdlib), or keep the plot
      package's private `Buffer` only?
- [ ] Then: the plot T0 skeleton (the design note's sequencing step B).
