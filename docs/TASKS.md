# Development Tasks

A numbered checklist of every implementation task, consolidated from
`plan/step-01-project-scaffold.md` through `plan/step-14-other-targets.md`.
The plan files remain the specs — each task below belongs to a step that
holds its full goal, scope, and acceptance details. This file is the tracker.

## How to use this file

- **Numbering:** `T<step>.<n>` — the step number matches `plan/step-NN-*.md`.
- **Working in spare time:** tasks within a step are ordered; any prefix of
  completed tasks leaves the tree in a consistent state. A step boundary is
  the checkpoint where the repo must build and `dune test` green.
- **Ground rules** (from `plan/README.md`):
  - Never start the next step on a red build.
  - `README.md` (repo root) is the design source of truth. Provisional
    decisions are marked below; settle them in `CHECK.md` / `README.md`
    before the task that depends on them.
  - Strictness first: reject early with a clear diagnostic. No auto-fixing,
    no implicit additions, no silent fallbacks.
- **Tracking:** check items off here as you go, and update the status table
  in `plan/README.md` when a step completes.

## Milestones

| Milestone | Steps | Exit criteria |
| --- | --- | --- |
| M1 — MVP interpreter | 01–07 | Single-file Emo programs (functions, classes, enums, exceptions) run via `emo run` / `emo repl` with readable errors. |
| M2 — Compile-time experience | 08–10 | Gradual type checker, structural module system, and packages with MVS resolution; multi-package projects build and run. |
| M3 — Concurrency & networking | 11–12 | Processes and message passing on an effects-based scheduler; direct-style networking. |
| M4 — Compilation targets | 13–14 | Native code generation via `emo build`; then wasm / TypeScript / BEAM / qemu. |

## Design gates

Open decisions tracked in `CHECK.md` that gate tasks below. Settle them
before starting the gated work:

| Decision | Gates | Provisional until settled |
| --- | --- | --- |
| CLI command names | T1.3, T7.1–T7.2 | `run` / `repl` / `check` / `version`; rename mechanically once settled |
| String escape rules | T2.3, T2.4 | Minimal set `\n \t \\ \' \"` |
| Self-pid mechanism | Step 11 — settled by T11.1 itself | Reply pattern unusable until settled |
| Exception catch syntax | T12.5, Step 12 acceptance | Catch form absent; uncaught reporting only |
| Manifest / lockfile names, scope-prefix format, version ranges, deps CLI names | T10.2, T10.5–T10.6, T10.8 | `package.emo`, `emo.lock`, `owner/name`, exact pins only, `emo deps *` |
| C FFI binding-surface syntax | T13.6 | FFI task blocked; add to `CHECK.md` and settle first |

---

## M1 — MVP interpreter

### Step 01 — Project scaffold & CLI skeleton · `plan/step-01-project-scaffold.md`

**Prereq:** none.
**Done when:** `dune build` and `dune test` pass from a clean checkout; `emo version` prints `emo 0.0.1`; placeholder subcommands exit non-zero; CI green on Linux and macOS.

- [x] **T1.1** — Create `dune-project` and the `src/` library skeletons (`emo_support`, `emo_lexer`, `emo_parser`, `emo_ast`, `emo_eval`, `emo_check`, `emo_cli`) with placeholder modules that compile.
- [x] **T1.2** — Implement `emo_support`: span, severity, diagnostic, renderer; unit tests for the renderer.
- [x] **T1.3** — Implement `emo_cli` with cmdliner; wire the four subcommands to placeholder actions.
- [x] **T1.4** — Add alcotest smoke tests per library and the CI workflow (setup-ocaml, `dune build`, `dune test`, Linux + macOS).
- [x] **T1.5** — Add `.ocamlformat` (conventional profile); format the tree once (`dune build @fmt` passes).

### Step 02 — Lexer · `plan/step-02-lexer.md`

**Prereq:** Step 01.
**Done when:** suites cover every token kind, interpolation nesting (`"a ${ "b ${x}" } c"`), position fidelity on multi-line input, and every error case; `dune test` green.

- [x] **T2.1** — Token type + positioned token stream in `emo_lexer`.
- [x] **T2.2** — Identifier classes (`LOWER_IDENT` / `UPPER_IDENT`), keywords, operators.
- [x] **T2.3** — Numeric and char literals with escape handling.
- [x] **T2.4** — Interpolated-string token scheme with nesting tests.
- [x] **T2.5** — Newline-preserving stream API.
- [x] **T2.6** — Error cases: each rejects with correct line:col via `emo_support`.

### Step 03 — Parser: expressions · `plan/step-03-parser-expressions.md`

**Prereq:** Step 02.
**Done when:** every expression snippet in the README parses to the expected AST (golden tests); precedence pinned (`1 + 2 * 3`, `a && b || !c`, `x.foo(1)[i].bar?()`); `dune test` green.

- [x] **T3.1** — `emo_ast` expression/statement types with spans on every node.
- [x] **T3.2** — Pratt-style expression parser with the precedence table.
- [x] **T3.3** — Call parsing: positional + named args, trailing-block sugar.
- [ ] **T3.4** — Arrow blocks; `if` / `else` (single shape, no chaining).
- [ ] **T3.5** — Newline-termination rules with depth tracking.
- [ ] **T3.6** — Interpolated-string reassembly from lexer parts.
- [ ] **T3.7** — Parser tests: precedence table, dangling-operator continuations, malformed input errors.

Scope note: tuple literals under the content rule, tuple patterns, `case` / `receive` / `do` / send syntax all parse within this step (semantics stay "not yet" errors until steps 05 / 11).

### Step 04 — Parser: declarations · `plan/step-04-parser-declarations.md`

**Prereq:** Step 03.
**Done when:** the README's `User`, `Greeter` / `English`, `welcome`, and `Color` snippets parse to golden ASTs; negative tests (camelCase `def`, `UPPER` variable, enum payloads, duplicate `init`, annotated `init` return) rejected with the right message and span; `dune test` green.

- [ ] **T4.1** — Declaration AST nodes; top-level item sequence.
- [ ] **T4.2** — `def` parsing with the `init` exemption and `?`-name rules.
- [ ] **T4.3** — `class` (single-`init` rule, field collection from `self.x =`).
- [ ] **T4.4** — `interface` signature-only bodies.
- [ ] **T4.5** — `enum` member lists.
- [ ] **T4.6** — `raise` statement.
- [ ] **T4.7** — Naming-convention checks with spans; multi-error resync.
- [ ] **T4.8** — Golden tests: README examples parse cleanly; convention violations produce the expected errors.

### Step 05 — Interpreter: core values & evaluation · `plan/step-05-interpreter-core.md`

**Prereq:** Step 04.
**Done when:** the acceptance program runs (`fib(20)` → 6765, interpolated greeting, `count_down(1000000)` with a flat stack); `dune test` green including the deep-recursion case.

- [ ] **T5.1** — Value ADT + equality; environment chain.
- [ ] **T5.2** — Expression evaluation with tag-checked operators.
- [ ] **T5.3** — Interpolation; `print` builtin; `.to_string()`.
- [ ] **T5.4** — Closure capture (lexical, by reference to the environment).
- [ ] **T5.5** — Tail-call loop in the evaluator; deep-recursion test.
- [ ] **T5.6** — `if` / `return` semantics; runtime type errors with spans.
- [ ] **T5.7** — Alcotest suites running real programs end to end (assert on captured stdout).

Scope note: arrays, tuples, and `Box` (with its three-operation set) are part of this step's value model. `print` is a provisional name — promote it into the README once the I/O surface settles.

### Step 06 — Interpreter: classes, enums, interfaces · `plan/step-06-interpreter-objects.md`

**Prereq:** Step 05.
**Done when:** the README's object examples run verbatim (value-semantic `User`, `Color`, duck-typed `welcome`, structural `is()`); negative tests (`self.x =` outside `init`, missing method, uncaught raise) error as specified; `dune test` green.

- [ ] **T6.1** — `ClassDef` / `Instance` values; `init` window flag; field freeze.
- [ ] **T6.2** — Method dispatch + `self`; `NoMethodError`.
- [ ] **T6.3** — Deep `==` on instances; shared-structure immutability tests.
- [ ] **T6.4** — Enum singletons; `TypeValue`; `is()` with structural interface check.
- [ ] **T6.5** — `raise`; builtin `Exception`; uncaught-exception termination.
- [ ] **T6.6** — `.to_string()` for instances, enums, exceptions.

### Step 07 — CLI & diagnostics · `plan/step-07-cli-diagnostics.md`

**Prereq:** Steps 01–06.
**Done when:** every `examples/*.emo` runs with expected output in CI; a file with three parse errors reports all three at correct line:col, stable under `--no-color`; the REPL runs the step 06 acceptance block interactively. **M1 exit criteria met.**

- [ ] **T7.1** — `run` command with stage pipeline and exit codes (lex/parse 65, eval 70, uncaught exception 1).
- [ ] **T7.2** — REPL: multi-line reading, persistent environment, value echo.
- [ ] **T7.3** — Diagnostic renderer completion (excerpts, codes, hints, colors, error limit); unit tests over golden renderings.
- [ ] **T7.4** — Uncaught-exception trace plumbing in the evaluator.
- [ ] **T7.5** — `examples/` golden tests wired into CI.
- [ ] **T7.6** — Manual pass: run each example, use the REPL interactively.

Close-out note: promote the provisional decisions that M1 proved (`print`, trailing-block sugar) into the README.

---

## M2 — Compile-time experience

### Step 08 — Gradual type checker · `plan/step-08-type-checker.md`

**Prereq:** Steps 01–07.
**Done when:** every README example type-checks clean; the annotated-error corpus (wrong return type, bad named arg, `var` escape, narrowing misuse) is rejected with correct spans; the zero-false-positive corpus passes with no diagnostics; `emo check` works and `emo run` runs the pass first.

- [ ] **T8.1** — Type representation + annotation collection pass.
- [ ] **T8.2** — Statement/expression checking with `Unknown` discipline.
- [ ] **T8.3** — Signature checks; arrow-block inference.
- [ ] **T8.4** — Flow environments with narrowing on `is()`.
- [ ] **T8.5** — Structural interface conformance.
- [ ] **T8.6** — `var`-escape detection.
- [ ] **T8.7** — Call-site checking; named-argument validation.
- [ ] **T8.8** — `case` checking: pattern typing, `when` guards as `Bool`, exhaustiveness on decidable enums and on the first tuple element of decidable `(Enum, ...)` scrutinees (guarded branches don't count).
- [ ] **T8.9** — `emo check` command; wire into `emo run`.
- [ ] **T8.10** — Test categories: strict-annotated rejections, inference successes, zero-false-positive corpus.

Follow-up: document the chosen `var`-escape analysis approximation in `docs/`.

### Step 09 — Structural module system · `plan/step-09-modules.md`

**Prereq:** Steps 01–08.
**Done when:** the README's `shop/` tree works verbatim (path-as-module, aliasing via `const`); referencing `shop.internal.discounts` from outside `shop` errors naming both modules; a two-module cycle is rejected with the full chain; multi-file fixtures green.

- [ ] **T9.1** — Module path resolution (file ↔ module name; collisions are errors).
- [ ] **T9.2** — Lazy `Module` values wired into the evaluator's member access.
- [ ] **T9.3** — Load-order orchestration; load-once semantics.
- [ ] **T9.4** — Reference-graph extraction during checking.
- [ ] **T9.5** — `internal/` subtree-privacy check.
- [ ] **T9.6** — Cycle detection with chain reporting.
- [ ] **T9.7** — In-process caching keyed by content hash.
- [ ] **T9.8** — Multi-file test project under `examples/` mirroring the README's `shop/` tree.

Caution: the transitional root rule (entry file's directory) must be swapped for manifest-based roots in step 10 — do not let it fossilize.

### Step 10 — Packages & version resolution · `plan/step-10-packages.md`

**Prereq:** Steps 01–09.
**Done when:** the README's `require "acme/json_tools"` scenario runs against a fixture registry; removing a dep from `deps` while its `require` remains is a compile error; conflicting exact pins resolve to the highest and the lockfile checksums verify on a second run; a dep whose `targets` exclude the current target fails at resolution time. **M2 exit criteria met.**

- [ ] **T10.1** — `require` parsing + scope rules.
- [ ] **T10.2** — Manifest phase A: strict schema parser, errors with spans.
- [ ] **T10.3** — Strict require/deps pairing check.
- [ ] **T10.4** — MVS resolver with target-compatibility gate; unit tests over version lattices.
- [ ] **T10.5** — Lockfile read/write/verify; mismatch errors.
- [ ] **T10.6** — Registry client + content-addressed cache + directory registry for tests.
- [ ] **T10.7** — Manifest phase B: restricted-profile evaluation with step budget.
- [ ] **T10.8** — End-to-end fixture: two local packages, one requiring the other, resolved, locked, built, run.

Also here: swap step 09's transitional root rule for manifest-based roots.

---

## M3 — Concurrency & networking

### Step 11 — Processes & message passing · `plan/step-11-concurrency.md`

**Prereq:** Steps 01–10.
**Done when:** ping-pong (1M messages) and fan-out/fan-in (1000 workers) run correctly under both the Eio-based and own effects schedulers; a process that raises mid-message dies alone while the parent continues; sending a `Box` yields a snapshot; receive loops recursing millions of times keep the native stack flat; `dune test` green under the deterministic scheduler.

- [ ] **T11.1** — Design pass: settle the self-pid mechanism in `CHECK.md` / README (`do`, `<-`, `receive { ... }`, and the `Box` operation set are already decided). Blocking gate for the rest of the step.
- [ ] **T11.2** — Process/mailbox abstraction on Eio; spawn/send/receive.
- [ ] **T11.3** — Crash isolation; process-exit signals for future supervisors.
- [ ] **T11.4** — `Box` with snapshot-on-send semantics.
- [ ] **T11.5** — Deterministic scheduler log for tests.
- [ ] **T11.6** — Phase B: own effects-based scheduler beneath the same interface.
- [ ] **T11.7** — Stress tests: ping-pong, fan-out/fan-in, deep receive-loop recursion.

### Step 12 — Networking library · `plan/step-12-networking.md`

**Prereq:** Steps 01–11.
**Done when:** an Emo HTTP server + client round-trip on localhost runs in one `emo run` program, entirely direct style; a timeout and a refused connection each raise an Emo exception with a precise message; a TLS handshake to a test certificate fails closed on verification error. **M3 exit criteria met.**

- [ ] **T12.1** — TCP socket surface on the scheduler; graceful close semantics.
- [ ] **T12.2** — UDP + Unix-domain sockets.
- [ ] **T12.3** — DNS resolution through the same suspension path.
- [ ] **T12.4** — OpenSSL TLS binding; certificate-verification errors surfaced as Emo exceptions.
- [ ] **T12.5** — HTTP client; HTTP server with process-per-connection helper.
- [ ] **T12.6** — Stdlib packaging with target metadata; fixture-based integration tests (loopback listeners, deterministic order).

Follow-up: write the exact stdlib module/method names (`net.*`, `http.*`) into the README when this step settles them.

---

## M4 — Compilation targets

### Step 13 — Native backend · `plan/step-13-native-backend.md`

**Prereq:** Steps 01–12.
**Done when:** every `examples/*.emo` compiles to a native binary producing output identical to `emo run` (golden comparison in CI); specialized numeric code shows measurably better benchmark numbers than the unspecialized build; a process-per-connection HTTP server built with `emo build` sustains a load test; benchmark results recorded.

- [ ] **T13.1** — IR definition + checked-AST lowering.
- [ ] **T13.2** — Stage A: OCaml emission, runtime linking, single-binary output.
- [ ] **T13.3** — `emo build` with incremental caching.
- [ ] **T13.4** — Benchmark set wired into CI (numbers recorded, not just pass/fail).
- [ ] **T13.5** — Stage B: type-driven specialization passes (unboxing, direct dispatch) behind completeness checks from step 08 data.
- [ ] **T13.6** — C FFI linking path once the binding-surface syntax is decided (blocked — settle in `CHECK.md` first).
- [ ] **T13.7** — Bootstrap test: the `examples/` suite as compiled binaries matches interpreter output byte-for-byte.

Follow-up: document the Stage A emission choice (source vs constructed module trees) and its tradeoff in `docs/`.

### Step 14 — Other targets: wasm, TypeScript, BEAM, qemu · `plan/step-14-other-targets.md`

**Prereq:** Steps 01–13 (per target). These are roadmap entries, not execution-ready plans — each target gets its own step file when scheduled. Recommended order: Wasm → TypeScript → BEAM → qemu.

- [ ] **T14.1** — When a target is scheduled, split it into `step-NN-<target>.md` with the full standard format (goal / scope / tasks / acceptance) and update `plan/README.md`'s status table; its tasks continue the numbering (`T15.*`, …).
- [ ] **T14.2** — Record which key decision each target settled and where (README / `CHECK.md` / docs) — keep the trail.

Key decisions to settle per target: Wasm — WasmGC vs custom GC (prototype both); TypeScript — direct-style mapping onto the event loop, process mapping; BEAM — class value semantics vs Erlang maps; qemu — pluggable runtime, linker scripts (highest risk; pull the `core`-library layering earlier if EmoOS work starts).
