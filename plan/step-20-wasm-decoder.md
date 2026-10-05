# Step 20 — Wasm runtime: the decoder and validator

**Milestone:** M6 · **Prereq:** step 19 · **Status:** not started

The boundaries below are decided now, because step 20 is where they first
bite — and they are the whole answer to "why does a wasm runtime live in
a language repository". The task list is sized for spare-time work: every
task ends with the tree green, and every prefix of the list is a
consistent tree (the rule `docs/TASKS.md` already states for every step).

The runtime is written in Emo **as the language is today**. Where the
language makes something awkward, the plan works around it and records
the pressure (below); it never adds a primitive to make one task easier.
A primitive the runtime genuinely needs goes through step 19's gate as a
task of its own, with both consumers named.

## Boundaries carried in from step 19

These bind the runtime ladder as a whole (steps 20 and 21, and the
kernel path that shares the layer), not just this step.

**The package is the boundary.** `runtime/wasm/` is an Emo package with
its own `package.emo`; everything it offers crosses that deps edge and
nothing else. It never imports compiler internals — no file under
`src/`, no dune library, no reaching into the wasm writer's ABI or the
codegen's runtime indices — and the dependency never runs the other way:
the compiler does not depend on the runtime. Where the two must meet
(the self-hosting test, below), the coupling lives in the test, which
depends on both. Its guts live under `runtime/wasm/internal/`, so the
only thing another package can see is what the package's own root module
offers.

**Spec data is not on the default test path.** The vendored spec suite
is large and changes rarely, and a language change has no reason to
re-run it. It lives with the package under `runtime/wasm/testdata/`; a
dedicated alias runs it (the Emo-written runtime executing the suite),
while the default `dune test` runs only a small smoke subset. Wiring
that smoke subset in is the first task of this step — until then the
package is inert, and step 19's claim that "the build has something to
check" is not yet true.

**The split is scheduled, not open-ended.** The runtime leaves this
repository when it passes the vendored spec subset and Emo reaches 1.0.
On the split, the language repository keeps a conformance/integration
test that pins a released runtime version, and the runtime gets its own
release cadence and issue tracker. The self-hosting test is the exit
sign that keeps the two in one place until then: the acceptance is
running Emo's own `--target wasm` goldens inside the Emo-written
runtime. Until the split, every primitive the runtime asks for still
goes through step 19's unification gate — the runtime is a consumer that
justifies a primitive, never an argument that skips the gate.

## Goal

`runtime/wasm/` decodes and validates a WebAssembly binary module and
reports either success or the first failure with its phase and byte
offset. The bar is the official spec suite's binary-format cases: every
`assert_malformed` and `assert_invalid` case whose module is given in
binary form must be rejected in the right phase, and every valid module
must be accepted. The interpreter, the host imports, and the
`assert_return` corpus are step 21's.

Two things this step is not: it is not a `.wat` text parser, and it is
not fast. What the runtime does, it does in the language as it stands —
no new syntax, no new primitive, no compiler assist.

## Scope

### In

- `runtime/wasm/` grown into a real package: the byte reader, LEB128,
  the section walk, the module model, the instruction stream, and the
  validator, each an ordinary module of that package, guts under
  `internal/`.
- Failure as a value, never an exception: the catch form is still listed
  as unsettled in `CHECK.md`, so the decoder returns a diagnosed result.
- The corpus harness: a case list under `runtime/wasm/testdata/`, a
  runner that reports a verdict per case, the default-test smoke subset,
  and the `wasm_spec` alias for the full list.
- The vendoring tool that turns a pinned wasm-spec checkout into that
  case list, and the provenance/licence note next to the data.

### Out

- The text format: `.wat` parsing, and every `assert_malformed` case the
  spec marks `module_type: text`.
- Execution: the interpreter core, host imports, WASI, and the
  `assert_return` / `assert_trap` corpus — step 21.
- The GC, threads, SIMD, exceptions, and memory64 proposals; the target
  is the core spec's MVP instruction set plus what the spec suite's
  binary cases exercise.
- Command-line arguments: the language has no argv primitive, so the
  driver compiles its list path in (below). Whether argv earns a place
  on the systems layer is a gate question, not an assumption here.
- Any language or checker change. If a task cannot be written in today's
  Emo, it is a gate item with its own task, not a detour inside this one.
- Performance: no JIT, no tiering, no fast-path decoding.

## Provisional decisions

Marked as provisional per `plan/README.md`; the settled ones move into
`README.md` / `docs/` when step 20 closes.

- **Failures are values.** The decoder and validator return a result
  carrying the phase (`malformed` vs `invalid`), the byte offset, and a
  message. Nothing raises for bad input. This is forced by the language
  as it stands — `CHECK.md` still lists the catch form as unsettled —
  and it is the right shape anyway: a runtime that dies on the first bad
  byte cannot run a corpus. Every read is bounds-checked *before* the
  access, because an out-of-range `Bytes.get` raises and nothing can
  catch it.
- **The spec's messages are not a contract.** Spec cases carry an
  expected message text, but the spec's own suite only asserts that the
  module is rejected; the text is a hint. We compare the *phase*, not
  the message.
- **The module model is immutable, and sequences are built by
  recursion.** Classes freeze after `init`, arrays are immutable and
  `.append` copies, and there is no `Array.new(n)` — so the model is
  assembled bottom-up by recursive descent and sequences are cons lists
  of frozen instances (with a sentinel for the empty tail, since there
  is no nil). Decoding wasm suits this: every vector's length is in the
  binary, so the recursion is well-founded and each pass returns the
  decoded value plus the new offset. A tag tuple (`(Kind.num, NumOp.add,
  imm)`) plus `case` carries the instruction shapes, since enums are
  payload-free. The exact tag shape is settled in T20.7, with the
  fixture that proves it.
- **The corpus is text, not binary.** Generated case lists hold the
  module bytes hex-encoded, one case per line, with the expected
  verdict. No `.wasm` blobs enter the repository, the data stays
  reviewable in a diff, and no wasm toolchain is needed at test time —
  `wast2json` is needed only to regenerate the list. If step 21's larger
  corpus outgrows one line per case, the runner's case reader is the
  only place that changes.
- **The corpus is vendored ahead of capability.** A case whose verdict
  the runtime cannot yet decide is marked `pending` in the list, not
  deleted and not expected to fail. The runner skips it and the summary
  prints the pending count, so the gap is visible on every run and each
  later task just flips cases from `pending` to a claimed verdict. This
  is what lets the corpus land whole while every prefix stays green.
- **Two drivers, one runner.** The list path is compiled into a two-line
  driver (`main.emo` for the smoke list, `spec.emo` for the full list)
  because there is no argv; all the logic lives in the runner module.
- **The tests run the interpreter.** `emo run` executes the package for
  every rule in this step: it needs no registry for a deps-less package
  and no opam toolchain, and the corpus is small. Step 21 may move the
  `wasm_spec` alias to a native build when the corpus and the interpreter
  are both real; the rules are written so that swap is one command.

## Pressure the runtime puts on the language

Recorded now, decided nowhere: these are the places the runtime works
around the language, with the evidence the gate would need. They are not
step 20 tasks, and they are not promises.

- **Sequences.** `Array` has no constructor and `.append` copies, so
  collecting *n* items is O(n²) in time and allocation; there is no
  List, Map, or Set. The runtime avoids collecting entirely (cons lists,
  known lengths, one pass). A real allocator story for EmoOS would want
  a growable buffer — but Bytes already covers the byte case, and the
  kernel's other containers are the kernel's to design. Step 21, where
  the interpreter gets hot loops, is where this should be re-read.
- **`catch`.** `CHECK.md` lists the catch form as unsettled. The
  runtime is written to not need it, which costs a bounds check before
  every access. When the form settles, the reader is the one module that
  could simplify.
- **Fixed widths.** `Int32` is not in the family yet. The decoder does
  not need it (a u32 fits `Int`, and an i32 payload is stored as its
  unsigned bit pattern); the *interpreter* does, for i32 wrap-around —
  step 21, per step 19's staging.
- **argv.** A runtime that cannot be handed a file path is a runtime
  whose test driver has the path compiled in. Fine for a corpus runner,
  not fine for a CLI. Step 21 decides whether a CLI is a consumer that
  justifies the primitive.

## The corpus harness

`runtime/wasm/testdata/` holds the case lists and a `README.md` that
records the upstream revision, the licence, and the regeneration
command. A case line is:

```
<name> <ok|malformed|invalid|pending> <hex module bytes>
```

`runtime/wasm/internal/corpus.emo` reads a list with `file_read`, splits
the lines, decodes the hex with `Bytes`, and feeds each claimed case to
the decoder and validator; `runtime/wasm/cli.emo` prints one verdict
line per case and a summary (`claimed N, pending M, failed K`). A
`pending` case prints nothing. The default test diffs the smoke run's
stdout against its golden; the `wasm_spec` alias does the same for the
full list. A misclassification shows up as a diff of that one line.

## Tasks

Sizes: **S** is one short sitting, **M** an evening, **L** several. Any
prefix of this list leaves the repo building and `dune test` green.

### First, the package stops being inert

- [ ] **T20.1** — *The smoke rule.* **(S)** `runtime/wasm/main.emo`
      calls `wasm.smoke()` and prints it; `expected.txt` holds the line;
      `runtime/wasm/dune` adds a `(alias runtest)` rule that runs
      `emo run main.emo` in the sandbox and `diff`s stdout against the
      golden. Deps are `{}`, so this needs no registry, no lockfile and
      no native toolchain. Red when `wasm.emo` stops printing its line,
      which is the point.
- [ ] **T20.2** — *The runner and the two drivers.* **(S)** The case-list
      format and its hex codec, `runtime/wasm/internal/corpus.emo`,
      `runtime/wasm/cli.emo` (read a list, walk it, print verdicts and a
      summary), `main.emo` → `testdata/cases.smoke.txt`, `spec.emo` →
      `testdata/cases.all.txt`, a golden per driver, and a second dune
      rule on the `wasm_spec` alias. Both lists start empty: the
      acceptance is that both aliases run, `dune test` stays green, and
      the summary reports `pending 0`.
- [ ] **T20.3** — *The vendoring tool and the first corpus.* **(S)**
      `devtools/vendor-wasm-spec` reads a local wasm-spec checkout
      (revision pinned in `testdata/README.md`), runs
      `wast2json --no-check`, and writes the text case lists; the
      checkout itself is fetched by hand, once, outside the tool. Vendors
      `binary.wast`'s binary-form cases as `pending`.
      *(Independent of every decoder task below — a good sitting to pick
      up whenever the next decoder task needs a break.)*

### Then the decoder, bottom-up

- [ ] **T20.4** — *Failures and the reader.* **(S)** `internal/error.emo`
      — the diagnosed-failure value (`ok`, `phase`, `offset`, `message`);
      `internal/reader.emo` — a `Bytes` cursor with an offset, `u8` /
      `peek` / `skip` / `remaining`, and a bounds check before every
      access, since the raise it prevents cannot be caught. Fixtures: the
      truncated-read family, claimed from this task on.
- [ ] **T20.5** — *LEB128.* **(S)** `u32` / `u64` / `s32` / `s64`,
      including the spec's length caps: an over-long or over-wide
      encoding is `malformed`, not a wrapped value. `u64` needs `Int64`
      and its explicit conversions; `u32` stays in `Int`. Fixtures:
      `binary-leb128.wast` plus hand-written boundary vectors (2³²−1,
      the sign-extension forms, the too-long forms). Self-contained —
      the best candidate for a short sitting.
- [ ] **T20.6** — *The header and the section walk.* **(M)** Magic,
      version, section id and size, the ordering and uniqueness rules,
      custom sections skipped, unknown ids rejected, trailing bytes
      after the last section, sizes that overrun the module.
- [ ] **T20.7** — *The type section, and the model's shape.* **(M)**
      Value and reference types, function types, limits — and the tag
      tuples and cons lists the rest of the model copies. The
      representation decision in "Provisional decisions" is settled here,
      with the fixture that proves it decodes to what it should.
- [ ] **T20.8** — *The declaration sections.* **(M)** Function, table,
      memory, global, import, and export, with their index spaces and
      the export-name uniqueness rule.
- [ ] **T20.9** — *Element, data, and constant expressions.* **(M)**
      The constant-expression subset as a decoded expression stream, the
      element type, the data segments, and their bounds.
- [ ] **T20.10** — *The opcode table and the numeric instructions.*
      **(M)** The dispatch on the first byte, and the immediates of the
      numeric instructions (`i32.const`, `f64.const`, the reinterpret
      family). Kept to one sitting by taking the table family by family.
- [ ] **T20.11** — *Parametric, variable, and memory instructions.*
      **(M)** `drop` / `select`, `local.*` / `global.*`, and the memory
      instructions with their alignment and offset immediates.
- [ ] **T20.12** — *The structured instructions.* **(M)** `block`,
      `loop`, `if` / `else` / `end` with their block types, `br`,
      `br_if`, `br_table`, and the matching-`end` bookkeeping that makes
      a function body one well-formed expression. Recursion follows the
      nesting, so the tail-call guarantee carries it.
- [ ] **T20.13** — *The public entry and the valid corpus.* **(S)**
      `decode(bytes)` on the package's surface, the decoded module as
      the thing the validator consumes, and the `ok` cases: minimal
      valid modules, including empty and custom-section-only ones.

### Then the validator

- [ ] **T20.14** — *The context and function typing.* **(M)** The
      validation context (types, functions, tables, memories, globals),
      index-space checks, and function signature agreement.
- [ ] **T20.15** — *The type stack.* **(L)** Operand typing for the
      plain instructions, including the numeric rules the spec states
      per opcode.
- [ ] **T20.16** — *Control frames.* **(L)** Block/loop/if typing, label
      depths, branch operand types, and the polymorphic stack after an
      unconditional branch — the part of the spec that is easy to get
      subtly wrong, so its fixtures come first.
- [ ] **T20.17** — *Cross-section rules.* **(M)** Start function,
      element/data offsets against declared limits, table and memory
      limits, global initializer typing, and the last `assert_invalid`
      families.

### Close-out

- [ ] **T20.18** — *Corpus sweep and close-out.* **(S)** The `wasm_spec`
      alias runs the full list with nothing pending; the smoke list
      carries a representative subset; `runtime/wasm/README.md` states
      what the package offers and what it refuses; step 20's acceptance
      is recorded here and in `docs/TASKS.md` (both languages).

## Acceptance

- The `wasm_spec` alias reports zero pending and zero failed over the
  vendored binary-form corpus: every valid module decodes and validates,
  every `assert_malformed` case fails in the decode phase, every
  `assert_invalid` case fails in the validation phase.
- The default `dune test` runs the smoke subset through the Emo-written
  runtime and is green; a regression in any claimed case fails it.
- No file under `src/` reads anything under `runtime/`, and no file
  under `runtime/` names a compiler module or library — the boundary
  holds in both directions.
