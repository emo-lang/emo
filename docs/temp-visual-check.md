# Visualization work — open checks

Written 2026-10-12, on `feat/plot`. This is a temporary working list, not
decided design: it tracks the compiler, language, and backend issues
found while landing the numeric substrate the plot work needs (the float
method dispatch and the `math` package). The plot design itself lives in
[`visualization.md`](visualization.md); the decisions there are unaffected
by this file. It is English-only on purpose — a translation follows only
if the file outlives the work.

## 1. Blocking the plot work

### B1 — the ocaml/c specialization gap: `var` and `case` in a typed function

**Symptom.** A function with a real signature (native parameters and
return) that contains a `var` reassignment outside a loop, or a `case`
statement, fails `emo build --target ocaml`:

```console
$ emo build main.emo --target ocaml
ASSERT ... build failed: NONNATIVE STMT in <fn>: Assign
# or
ASSERT ... build failed: NONNATIVE STMT in <fn>: Case
```

The `c` target accepts both.

**Cause.** `Emo_ir.stmt_native` (`src/emo_ir/emo_ir.ml`) classifies
`Assign_var`, a mutable `Let`, and `Case` as native, and `Emo_ir.specialize`
marks the function `fspecializable` on that basis. The ocaml native
emitter `emit_native_stmts` (`src/emo_codegen/emo_codegen.ml`, around
line 840) lowers only `Effect`, an immutable `Let`, `If`, and
`Return_stmt`; anything else hits the `NONNATIVE STMT` refusal. The c
native emitter (`emo_c.ml`) does lower `Assign_var` and `Case`, but the
predicate is shared, so the ocaml target is the one that breaks.

**Why it blocks plot.** Plot code is imperative numerics: domains, tick
loops, and scales use `var` and `case` heavily, and library functions
carry full type declarations. On `ocaml` these functions cannot compile
as written.

**The choice.**

- **A — make `stmt_native` conservative.** Return `false` for
  `Assign_var`, a mutable `Let`, and `Case`, matching what the ocaml
  emitter actually lowers. Correct, small, but de-specializes every such
  function on `ocaml` and `c` (a performance regression on `c`, which can
  handle them).
- **B — complete the ocaml native emitter.** Lower `Assign_var`, a
  mutable `Let`, and `Case` natively (the c emitter is the reference).
  Keeps specialization and is the real fix, at more implementation risk.

A narrower third option is a per-target specialization predicate (c keeps
its native `Assign_var`/`Case`, ocaml falls back), but that is more
machinery than the two above.

**Evidence from the session.** Adding a throwaway example with
`if y = 1` / `case { y = 10 }` inside typed functions turned the
`emo_project` bootstrap suite red with exactly the errors above; the
example was removed to keep the tree green, and this gap left open.

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

- [ ] **B1** — conservative `stmt_native` (A) or complete the ocaml native
      emitter (B)?
- [x] **B2** — a presence enum (`enum Presence { present, absent }`)
      plus a parallel array; recorded in `docs/visualization.md`.
- [ ] **P1** — fix the `runtime/wasm` rule `deps` so `dune test` is green?
- [ ] **P2** — make `bufio.BytesSink` chunked (stdlib), or keep the plot
      package's private `Buffer` only?
- [ ] Then: the plot T0 skeleton (the design note's sequencing step B).
