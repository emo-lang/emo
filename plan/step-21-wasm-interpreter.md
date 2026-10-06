# Step 21 — Wasm runtime: the interpreter and the golden runs

**Milestone:** M6 · **Prereq:** step 20 · **Status:** in progress

The rung step 20 pointed at: the modules the decoder accepts start
*running*. The bar moves from "is this module well-formed?" to "does it
do what the spec says?" — the official suite's `assert_return` /
`assert_trap` commands are the goldens, executed by the Emo-written
runtime. The three boundaries recorded in `plan/step-20-wasm-decoder.md`
bind unchanged — the package is the edge, the spec data stays off the
default test path, and the split condition stands — so they are not
restated here.

The task list follows the step-20 discipline: sized for spare-time work,
every prefix builds green, the corpus lands whole and is claimed family
by family. One rule from step 20 earned its keep twice over and carries
formally into this step: **no shape that puts a method call on a
recursive result** (`f(n-1).append(x)`) — the interpreter spins past
roughly 25 nesting levels. Every array-returning recursion stays a
tail-accumulator loop.

## Goal

`runtime/wasm/` executes a validated module: instantiate it (resolve
imports, lay out memory/table/global state, run initializers and the
start function), invoke exported functions, and report either the
result values or the first trap. The bar is the vendored spec suite's
run commands — every `assert_return` returns its expected values
(NaN payloads included), every `assert_trap` traps where the spec says,
every `assert_uninstantiable` / `assert_unlinkable` module fails at
instantiation, and `register` + imported modules link.

Two things this step is not, same as step 20: it is not fast (no JIT,
no tiering — interpreter-first is the ladder's rule), and it is not a
language change. Where today's Emo makes execution awkward, the task
works around it and records the pressure; a primitive the interpreter
genuinely needs goes through step 19's gate as a task of its own, with
both consumers named.

## Scope

### In

- The run-list harness: a vendored command corpus (invoke with
  arguments, expected results, trap expectations), text lists under
  `runtime/wasm/testdata/`, a runner, drivers, and a dedicated dune
  alias — the same shape as step 20's module corpus, so claiming stays
  deliberate and visible.
- The instance model: materializing what the decoder proved — function
  bodies as byte ranges with their signatures, the index spaces, the
  segments — into frozen records the interpreter can walk without
  re-parsing.
- The value model and the numeric families: i32/i64/f32/f64 with exact
  wrap-around, NaN payload discipline, traps on the spec's error cases
  (division by zero, integer overflow on truncation, out-of-bounds).
- The store: linear memory on `Bytes`, tables, globals; grow, bounds,
  the little-endian accessors, and the bulk operations.
- The frame machine: an operand stack, structured control by recursion
  (tail calls carry the nesting), branches as signals, calls and
  `call_indirect`.
- Instantiation and the host: import resolution with a register
  namespace (linking.wast is in the corpus), segment initialization
  with the spec's trap-on-overflow semantics, the start function, and
  the `spectest` host module the suite's imports reference.
- The sweeps that flip the run corpus from `pending` to claimed, family
  by family, ending at zero.

### Out

- Everything step 20 already excluded: the text format, the GC /
  threads / SIMD / exceptions / memory64 proposals, WASI.
- Self-hosting — running Emo's own `--target wasm` goldens inside this
  runtime. That is the ladder's exit sign and needs the GC proposal's
  types; it is not smuggled in here.
- New language surface. `Int32` and `Float32` are *not* added: i32
  masks (the backends' own discipline), and f32 is carried as its bit
  pattern with correctly-rounded conversion by integer bit surgery.
  The gate evidence this produces is recorded below, not acted on.
- A CLI. Step 20 deferred argv; the corpus driver keeps its list path
  compiled in, and no consumer has yet asked for more.
- Performance work beyond correctness: no arena tuning, no decode
  caching, no dispatch tables.

## Provisional decisions

Marked as provisional per `plan/README.md`; the settled ones move into
`docs/` when the step closes.

- **Values are bit patterns on the operand stack.** An i32 is its
  unsigned 32-bit pattern in `Int`, an i64 its full pattern in
  `Int64`, an f32 its 32-bit pattern in `Int` and an f64 its 64-bit
  pattern in `Int64`. Float arithmetic converts to `Float64` at the
  operation and re-encodes after — the only way NaN payloads survive
  loads, stores, and `reinterpret` exactly, which `float_misc` and the
  `nan:canonical` / `nan:arithmetic` expectations demand. References
  are a tagged pair: funcref holds the function index, externref holds
  the host value, null is its own encoding.
- **f32 without `Float32`.** Demotion (f64→f32) is the one operation
  that needs rounding `Float64` cannot give directly, so it is integer
  bit surgery — round-to-nearest-even on the significand, overflow to
  infinity, subnormals included — with the fixture list that proves it
  against the spec's conversion cases. If the surgery turns out to be
  a maintenance burden, the gate note below is the record; the
  primitive is not pre-justified.
- **Traps are values.** Same forced shape as step 20's diagnosed
  failures: execution returns either values or a trap record (kind +
  message), never raises. The store's bounds checks run before every
  access.
- **Branches are signals, not exceptions.** `br` and friends return a
  tagged unwind value that the enclosing frame recursion inspects —
  the validator's reader-bail pattern, moved to execution. Unwinding
  is proportional to the labels crossed, which validation already
  bounded.
- **The operand stack is a byte arena.** A `Bytes` buffer of little-
  endian u64 slots (the T19.2 accessors), doubling by copy when full —
  the no-growable-buffer pressure worked around in the one place step
  20 predicted it would bite. Locals ride the same arena; frames are
  slices of it.
- **The run-list format extends the case-list format.** One command
  per line, verdict-prefixed, `pending` until claimed:
  `<file>.wast:<line> <return|trap|ok> <module> <export> <args>
  <expected>`, where args and expected are type-tagged bit patterns
  (`i:`, `I:`, `f:`, `F:`, `ref:`) and NaN expectations carry their
  pattern token. The exact tokens are settled with the first fixture,
  in the task that owns the codec.
- **One module instance per `module` command, registered by name.**
  The runner keeps the register namespace the suite's `register`
  commands define; an import resolves against it first, then against
  the host (`spectest`). A missing import is a link failure, which is
  exactly what `assert_unlinkable` expects.

## Pressure the interpreter puts on the language

Re-read from step 20's list, now with execution-shaped evidence. None
of these is a task here; they are the gate's raw material.

- **The growable buffer.** The arena's doubling-by-copy is amortized
  and correct, and the corpus is small — but the interpreter is the
  first in-repo consumer with a hot inner loop that allocates per
  step. If the sweeps run slow, the evidence lands here.
- **Float math and conversion primitives.** The float families needed
  `sqrt`, `floor`, `ceil`, `trunc`, and float ↔ int conversion; the
  language had none. The gate settled them into the core surface
  (`Float64.sqrt`/`floor`/`ceil`/`trunc`, `Float64.to_int64`,
  `Int64.to_float64`; `nearest` built in Emo), so T21.5's conversion
  half can land. `CHECK.md` carries the record.
- **`Int32` / `Float32`.** The interpreter is a second consumer for
  both (the backends were the first — they mask and convert too), but
  "two consumers doing the same workaround" is an argument the gate
  has not heard yet, not a decision. The masking discipline this step
  implements is the shared evidence.
- **The method-on-recursive-result limit** (step 20's find): it is now
  a standing rule for every runtime module, and the interpreter's
  walker is exactly the shape that would trip it. A fix in the
  interpreter's evaluator would name two consumers (the runtime and
  the compiler's own tail-call guarantee); recorded, not acted on.
- **`argv`**, unchanged: the drivers compile their paths in.

## The run-list harness

`devtools/vendor-wasm-spec` grows a `runs` mode: the same pinned
checkout and `wast2json --no-check` pass, but reading the *commands*
instead of the module verdicts — `module`, `register`, `action`,
`assert_return`, `assert_trap`, `assert_uninstantiable`,
`assert_unlinkable` — and writing them as text lines whose module is
the hex blob (same codec as the case lists, so the data stays
reviewable and toolchain-free at test time). The runner instantiates
each module fresh, resolves imports through the register namespace and
the host module, invokes, and compares bit patterns exactly — except
the NaN tokens, which match by payload class. `runtime/wasm/runs.emo`
drives the full list under a new `wasm_runs` alias; a smoke slice
rides `dune test` beside step 20's.

## Tasks

Sizes: **S** is one short sitting, **M** an evening, **L** several. Any
prefix of this list leaves the repo building and `dune test` green.

### First, the harness

- [x] **T21.1** — *The run-list format and the vendoring mode.* **(S)**
      The command-line grammar and its codec (`i:` / `I:` / `f:` /
      `F:` / `ref:` words, NaN tokens, the verdict prefixes), the
      runner module beside step 20's, the `runs.emo` driver, the
      `wasm_runs` dune rule, and `vendor-wasm-spec runs` writing the
      list as all-`pending`. Acceptance: the alias runs, the summary
      reports `pending N` for the vendored commands, `dune test`
      stays green. *(Independent of every execution task — the
      break-sitting of this step, like T20.3 was.)*
- [x] **T21.2** — *The instance model.* **(M)** Materialize a validated
      module: functions as (signature, body byte range) pairs in index
      order, the table / memory / global declarations, the element and
      data segments, imports, exports, start, and the declared
      reference set — frozen records under `internal/`, assembled by
      the same recursive walks the validator uses. Surface:
      `wasm.load(bytes)` returns the module or the step-20 verdict,
      so a caller never sees an unvalidated module. Fixture: a
      hand-written module loads with the right counts and ranges.

### Then the values, fixture-first

- [x] **T21.3** — *The value model.* **(M)** The tagged scalars of the
      provisional decision, the NaN payload discipline (arithmetic
      canonicalizes only when the spec says; moves preserve), and the
      hex-word codec the runner compares with. Fixtures: wrap-around,
      payload round-trips, null references. No execution yet — every
      later task leans on these functions directly.
- [x] **T21.4** — *The integer families.* **(L)** i32/i64 arithmetic,
      comparisons, shifts and rotates (mask counts), clz / ctz /
      popcnt, division and remainder with their traps (zero, MIN / −1),
      sign extension and saturating truncation, the i64↔i32 wrap and
      extends. Pure functions over the value model, proven by
      hand-written fixtures lifted from the spec's boundary cases.
- [x] **T21.5** — *The float families.* **(L)** f32/f64 arithmetic and
      comparisons through the `Float64` bridge; the conversions —
      including truncation with its overflow / NaN traps, promote /
      demote with the bit-surgery round-to-nearest-even, and
      reinterpret as a pattern move. Fixtures pin every conversion
      boundary the suite exercises, NaN classes included.

### Then the store and the machine

- [x] **T21.6** — *The store.* **(M)** Linear memory as `Bytes` with
      page-granular grow (cap 2¹⁶ pages), little-endian loads / stores
      of every width, bounds-checked before access; tables as value
      arrays with grow / size / fill / copy / init; globals with
      mutation. Traps are values here too. Fixtures: the OOB edges,
      grow's wrap behavior, fill / copy overlaps.
- [x] **T21.7** — *The frame machine.* **(L)** The operand arena and
      the walker: locals and parameters, the parametric and variable
      instructions, structured control by recursion with branches as
      unwind signals, `call` and `call_indirect` (null and type
      mismatches trap), `return`, and the `unreachable` trap. The
      walker mirrors the validator's dispatch shape — one pass per
      opcode, immediates decoded in place. Fixtures: a hand-written
      module's invocation returns its expected values; a deep
      recursion (`fac`) returns, proving the tail-call chain.

### Then the world around the machine

- [x] **T21.8** — *Instantiation and linking.* **(M)** Resolve imports
      through the register namespace and the host; evaluate global
      initializers; lay out element and data segments with the spec's
      trap-on-overflow (an `assert_uninstantiable` module fails here,
      partially-initialized store discarded); run the start function;
      `register` a named instance. Missing and mismatched imports are
      link failures. Fixture: two modules linking through a table.
- [x] **T21.9** — *The spectest host module.* **(S)** The `spectest`
      imports the suite references — the print functions (output to
      the runner's log), the typed globals, the table, the memory —
      as host-side values behind the same import interface. *(A short
      sitting once linking exists; the corpus's import cases all
      resolve through it.)*

### Then the sweeps

- [ ] **T21.10** — *Sweep I: numbers, control, calls.* **(L)** Claim
      the run-list families in order — the integer and float suites,
      conversions, `if` / `br` / `br_table` / `loop`, `call` /
      `call_indirect`, `fac`, `forward`, `stack`. Each family's flip
      is its own sitting; the residuals stay `pending`.
- [ ] **T21.11** — *Sweep II: memory, tables, linking, traps.* **(L)**
      The addressing and endianness suites, `memory_*` / `table_*`
      operations, `elem` / `data` initialization, `linking` through
      the register namespace, `imports` through spectest, the trap
      cases, and the leftovers — the run list ends at zero pending
      and zero failed.
- [ ] **T21.12** — *Close-out.* **(S)** The run-list smoke slice rides
      `dune test`; `runtime/wasm/README.md` grows the execution
      surface and the run-corpus section; step 21's acceptance is
      recorded here and in `docs/TASKS.md` (both languages).

## Acceptance

- The `wasm_runs` alias reports zero pending and zero failed over the
  vendored run corpus: every `assert_return` matches bit-exactly
  (NaN payload classes for the NaN tokens), every `assert_trap`
  traps with the right kind, every `assert_uninstantiable` /
  `assert_unlinkable` module fails at instantiation, and `register`
  / linking behaves.
- The default `dune test` runs a smoke slice of both corpora (modules
  and runs) through the Emo-written runtime and is green.
- The boundaries hold: no file under `src/` reads anything under
  `runtime/`, nothing under `runtime/` names a compiler module, and
  the language's surface is unchanged — the pressure notes carry the
  gate evidence, nothing more.
