# Development Tasks

A numbered checklist of every implementation task, consolidated from
`plan/step-01-project-scaffold.md` through `plan/step-26-target-independence.md`.
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
| M4 — Compilation targets | 13–14 | Native code generation via `emo build`; then wasm / TypeScript / BEAM / riscv64. |
| M5 — BEAM & function groups | 17–18 | The BEAM target ships its golden tier; `emo Foo { ... }` function groups resolve and run on all four targets. |
| M6 — Systems programming | 19–21 | A WebAssembly runtime written in Emo: the shared systems layer, then the binary decoder/validator, then the interpreter with spec-suite goldens. |
| M7 — EmoOS | 22+ | The kernel path on the same systems layer: a unikernel build path (near term), then freestanding codegen (shared with the engine tiering). |
| M8 — Self-contained hosted backend | 24 | `emo build --target c`: emit C, Emo's own runtime, direct C ABI — step 23's assessment scheduled; unblocks self-contained tool distribution (CHECK.md). |
| M9 — Toolchain | 25 | The toolchain release (cut as v0.25.9): signed per-platform `emo` binaries on GitHub Releases (brew/opam as the source channels); a binary-only machine runs and builds Emo programs; `emo new` / `emo install` / `emo doctor` complete the command set. |
| M10 — Target independence | 26 | Every target's runtime lives in the target's own ecosystem — embedded as generated data (c, ocaml, typescript) or inside the emitted module (wasm, beam) — never beside the binary or in the host build tree; the host contributes only the emitters. |

## Design gates

Open decisions tracked in `CHECK.md` that gate tasks below. Settle them
before starting the gated work:

| Decision | Gates | Provisional until settled |
| --- | --- | --- |
| CLI command names | T1.3, T7.1–T7.2 | settled in M1 — `run` / `repl` / `check` / `version` shipped |
| String escape rules | T2.3, T2.4 | Minimal set `\n \t \\ \' \"` |
| Self-pid mechanism | T11.1 | settled — `self_pid()` builtin, `Pid` type rendering as `<pid N>`, `halt()`; no user-facing kill/wait |
| Exception catch syntax | T12.5, Step 12 acceptance | Catch form absent; uncaught reporting only |
| Manifest / lockfile names, scope-prefix format, version ranges, deps CLI names | T10.2, T10.5–T10.6, T10.8 | `package.emo`, `package.lock`, `owner/name`, exact pins only, `emo deps *` |
| C FFI binding-surface syntax | T13.6 | settled — `foreign def name(params) Ret = "c_symbol"`, `Float`/`String`/`Bool` only, through generated C wrappers |
| Reclamation model for the dynamic world (no tracing GC) | T24.5 | settled — reference counting for identity objects, arena for value-semantic data (`CHECK.md`, at T24.5) |
| `emo build` default target | T25.1 | flip `ocaml` → `c`: a distributed binary carries no OCaml toolchain; the `ocaml` target stays for source installs |
| Stdlib: embed vs sidecar tree | T25.2 | embed as generated data inside the compiler (the C runtime's mechanism); `EMO_REGISTRY` override stays |
| `emo install` semantics | T25.4 | the project-dependencies front end over resolve/fetch/lock; global executable installation out of scope for 1.0 |
| The runtime-independence principle | T26.1 | a target's runtime is written in the target's language, carried as generated data inside the compiler; the host contributes only the emitter |
| The ocaml runtime's dependency policy | T26.4 | the OCaml standard library plus `unix` for the core; `ssl` as the one opam dep, refused with a clear message when absent; no eio |

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
- [x] **T3.4** — Arrow blocks; `if` / `else` (single shape, no chaining).
- [x] **T3.5** — Newline-termination rules with depth tracking.
- [x] **T3.6** — Interpolated-string reassembly from lexer parts.
- [x] **T3.7** — Parser tests: precedence table, dangling-operator continuations, malformed input errors.

Scope note: tuple literals under the content rule, tuple patterns, `case` / `receive` / `do` / send syntax all parse within this step (semantics stay "not yet" errors until steps 05 / 11).

### Step 04 — Parser: declarations · `plan/step-04-parser-declarations.md`

**Prereq:** Step 03.
**Done when:** the README's `User`, `Greeter` / `English`, `welcome`, and `Color` snippets parse to golden ASTs; negative tests (camelCase `def`, `UPPER` variable, enum payloads, duplicate `init`, annotated `init` return) rejected with the right message and span; `dune test` green.

- [x] **T4.1** — Declaration AST nodes; top-level item sequence.
- [x] **T4.2** — `def` parsing with the `init` exemption and `?`-name rules.
- [x] **T4.3** — `class` (single-`init` rule, field collection from `self.x =`).
- [x] **T4.4** — `interface` signature-only bodies.
- [x] **T4.5** — `enum` member lists.
- [x] **T4.6** — `raise` statement.
- [x] **T4.7** — Naming-convention checks with spans; multi-error resync.
- [x] **T4.8** — Golden tests: README examples parse cleanly; convention violations produce the expected errors.

### Step 05 — Interpreter: core values & evaluation · `plan/step-05-interpreter-core.md`

**Prereq:** Step 04.
**Done when:** the acceptance program runs (`fib(20)` → 6765, interpolated greeting, `count_down(1000000)` with a flat stack); `dune test` green including the deep-recursion case.

- [x] **T5.1** — Value ADT + equality; environment chain.
- [x] **T5.2** — Expression evaluation with tag-checked operators.
- [x] **T5.3** — Interpolation; `print` builtin; `.to_string()`.
- [x] **T5.4** — Closure capture (lexical, by reference to the environment).
- [x] **T5.5** — Tail-call loop in the evaluator; deep-recursion test.
- [x] **T5.6** — `if` / `return` semantics; runtime type errors with spans.
- [x] **T5.7** — Alcotest suites running real programs end to end (assert on captured stdout).

Scope note: arrays, tuples, and `Box` (with its three-operation set) are part of this step's value model. `print` is a provisional name — promote it into the README once the I/O surface settles.

### Step 06 — Interpreter: classes, enums, interfaces · `plan/step-06-interpreter-objects.md`

**Prereq:** Step 05.
**Done when:** the README's object examples run verbatim (value-semantic `User`, `Color`, duck-typed `welcome`, structural `is()`); negative tests (`self.x =` outside `init`, missing method, uncaught raise) error as specified; `dune test` green.

- [x] **T6.1** — `ClassDef` / `Instance` values; `init` window flag; field freeze.
- [x] **T6.2** — Method dispatch + `self`; `NoMethodError`.
- [x] **T6.3** — Deep `==` on instances; shared-structure immutability tests.
- [x] **T6.4** — Enum singletons; `TypeValue`; `is()` with structural interface check.
- [x] **T6.5** — `raise`; builtin `Exception`; uncaught-exception termination.
- [x] **T6.6** — `.to_string()` for instances, enums, exceptions.

### Step 07 — CLI & diagnostics · `plan/step-07-cli-diagnostics.md`

**Prereq:** Steps 01–06.
**Done when:** every `examples/*.emo` runs with expected output in CI; a file with three parse errors reports all three at correct line:col, stable under `--no-color`; the REPL runs the step 06 acceptance block interactively. **M1 exit criteria met.**

- [x] **T7.1** — `run` command with stage pipeline and exit codes (lex/parse 65, eval 70, uncaught exception 1).
- [x] **T7.2** — REPL: multi-line reading, persistent environment, value echo.
- [x] **T7.3** — Diagnostic renderer completion (excerpts, codes, hints, colors, error limit); unit tests over golden renderings.
- [x] **T7.4** — Uncaught-exception trace plumbing in the evaluator.
- [x] **T7.5** — `examples/` golden tests wired into CI.
- [x] **T7.6** — Manual pass: run each example, use the REPL interactively.

Close-out note: promote the provisional decisions that M1 proved (`print`, trailing-block sugar) into the README.

---

## M2 — Compile-time experience

### Step 08 — Gradual type checker · `plan/step-08-type-checker.md`

**Prereq:** Steps 01–07.
**Done when:** every README example type-checks clean; the annotated-error corpus (wrong return type, bad named arg, `var` escape, narrowing misuse) is rejected with correct spans; the zero-false-positive corpus passes with no diagnostics; `emo check` works and `emo run` runs the pass first.

- [x] **T8.1** — Type representation + annotation collection pass.
- [x] **T8.2** — Statement/expression checking with `Unknown` discipline.
- [x] **T8.3** — Signature checks; arrow-block inference.
- [x] **T8.4** — Branch-scoped environments with narrowing on `is()`.
- [x] **T8.5** — Structural interface conformance.
- [x] **T8.6** — `var`-escape detection.
- [x] **T8.7** — Call-site checking; named-argument validation.
- [x] **T8.8** — `case` checking: pattern typing, `when` guards as `Bool`, exhaustiveness on decidable enums and on the first tuple element of decidable `(Enum, ...)` scrutinees (guarded branches don't count).
- [x] **T8.9** — `emo check` command; wire into `emo run`.
- [x] **T8.10** — Test categories: strict-annotated rejections, inference successes, zero-false-positive corpus.

Follow-up: the chosen `var`-escape approximation is documented in `docs/var-escape.md`.

### Step 09 — Structural module system · `plan/step-09-modules.md`

**Prereq:** Steps 01–08.
**Done when:** the README's `shop/` tree works verbatim (path-as-module, aliasing via `const`); referencing `shop.internal.discounts` from outside `shop` errors naming both modules; a two-module cycle is rejected with the full chain; multi-file fixtures green.

- [x] **T9.1** — Module path resolution (file ↔ module name; collisions are errors).
- [x] **T9.2** — Lazy `Module` values wired into the evaluator's member access.
- [x] **T9.3** — Load-order orchestration; load-once semantics.
- [x] **T9.4** — Reference-graph extraction during checking.
- [x] **T9.5** — `internal/` subtree-privacy check.
- [x] **T9.6** — Cycle detection with chain reporting.
- [x] **T9.7** — In-process caching keyed by content hash.
- [x] **T9.8** — Multi-file test project under `examples/` mirroring the README's `shop/` tree.

Caution: resolved in step 10 — a project roots at its nearest `package.emo`; manifest-less trees keep the working-directory rule.

### Step 10 — Packages & version resolution · `plan/step-10-packages.md`

**Prereq:** Steps 01–09.
**Done when:** the README's `require "acme/json_tools"` scenario runs against a fixture registry; removing a dep from `deps` while its `require` remains is a compile error; conflicting exact pins resolve to the highest and the lockfile checksums verify on a second run; a dep whose `targets` exclude the current target fails at resolution time. **M2 exit criteria met.**

- [x] **T10.1** — `require` parsing + scope rules.
- [x] **T10.2** — Manifest phase A: strict schema parser, errors with spans.
- [x] **T10.3** — Strict require/deps pairing check.
- [x] **T10.4** — MVS resolver with target-compatibility gate; unit tests over version lattices.
- [x] **T10.5** — Lockfile read/write/verify; mismatch errors.
- [x] **T10.6** — Registry client + content-addressed cache + directory registry for tests.
- [x] **T10.7** — Manifest phase B: restricted-profile evaluation with step budget.
- [x] **T10.8** — End-to-end fixture: two local packages, one requiring the other, resolved, locked, built, run.

Also here: swap step 09's transitional root rule for manifest-based roots — done; the root rule now prefers the nearest `package.emo`.

---

## M3 — Concurrency & networking

### Step 11 — Processes & message passing · `plan/step-11-concurrency.md`

**Prereq:** Steps 01–10.
**Done when:** ping-pong (1M messages) and fan-out/fan-in (1000 workers) run correctly under both the Eio-based and own effects schedulers; a process that raises mid-message dies alone while the parent continues; sending a `Box` yields a snapshot; receive loops recursing millions of times keep the native stack flat; `dune test` green under the deterministic scheduler.

- [x] **T11.1** — Design pass: settle the self-pid mechanism in `CHECK.md` / README (`do`, `<-`, `receive { ... }`, and the `Box` operation set are already decided). Blocking gate for the rest of the step.
- [x] **T11.2** — Process/mailbox abstraction on Eio; spawn/send/receive.
- [x] **T11.3** — Crash isolation; process-exit signals for future supervisors.
- [x] **T11.4** — `Box` with snapshot-on-send semantics.
- [x] **T11.5** — Deterministic scheduler log for tests.
- [x] **T11.6** — Phase B: own effects-based scheduler beneath the same interface.
- [x] **T11.7** — Stress tests: ping-pong, fan-out/fan-in, deep receive-loop recursion.

### Step 12 — Networking library · `plan/step-12-networking.md`

**Prereq:** Steps 01–11.
**Done when:** an Emo HTTP server + client round-trip on localhost runs in one `emo run` program, entirely direct style; a timeout and a refused connection each raise an Emo exception with a precise message; a TLS handshake to a test certificate fails closed on verification error. **M3 exit criteria met.**

- [x] **T12.1** — TCP socket surface on the scheduler; graceful close semantics.
- [x] **T12.2** — UDP + Unix-domain sockets.
- [x] **T12.3** — DNS resolution through the same suspension path.
- [x] **T12.4** — OpenSSL TLS binding; certificate-verification errors surfaced as Emo exceptions.
- [x] **T12.5** — HTTP client; HTTP server with process-per-connection helper.
- [x] **T12.6** — Stdlib packaging with target metadata; fixture-based integration tests (loopback listeners, deterministic order).

Close-out: the exact `net.*` / `http.*` names are in the README (Networking); the stdlib ships as directory-registry packages under `stdlib/registry` with `targets = ["ocaml"]` at the time; the acceptance example is `examples/http_roundtrip`. Step decisions are in `plan/step-12-networking.md` (Close-out). **M3 exit criteria met.**

---

## M4 — Compilation targets

### Step 13 — Native backend · `plan/step-13-native-backend.md`

**Prereq:** Steps 01–12.
**Done when:** every `examples/*.emo` compiles to a native binary producing output identical to `emo run` (golden comparison in CI); specialized numeric code shows measurably better benchmark numbers than the unspecialized build; a process-per-connection HTTP server built with `emo build` sustains a load test; benchmark results recorded.

- [x] **T13.1** — IR definition + checked-AST lowering.
- [x] **T13.2** — Stage A: OCaml emission, runtime linking, single-binary output.
- [x] **T13.3** — `emo build` with incremental caching.
- [x] **T13.4** — Benchmark set wired into CI (numbers recorded, not just pass/fail).
- [x] **T13.5** — Stage B: type-driven specialization passes (unboxing, direct dispatch) behind completeness checks from step 08 data.
- [x] **T13.6** — C FFI linking path once the binding-surface syntax is decided (blocked — settle in `CHECK.md` first).
- [x] **T13.7** — Bootstrap test: the `examples/` suite as compiled binaries matches interpreter output byte-for-byte.

Close-out: Stage A emits OCaml source (tradeoff documented in `docs/native-backend.md`); the IR lives in `src/emo_ir` with the Stage B `specialize` fixed point, and T13.5's specialization landed with the T13.1/T13.2 commits. `foreign def` settled as above, marshaling through generated C wrappers (`emo build` compiles them with `cc`); `Float`/`String`/`Bool` cross the boundary, everything else refuses with E4200. Benchmarks: `benchmarks/results.md` records fib(30) 345ms unspecialized vs 212ms specialized (~1.6x), ping-pong, JSON scan, and an HTTP echo load test at 112 req/s. Bootstrap: all five examples build to binaries matching `emo run` byte-for-byte (the `bootstrap` suite in `test/emo_project`). Decisions are in `plan/step-13-native-backend.md` (Close-out). **Step 13 acceptance met.**

### Step 14 — Other targets: wasm, TypeScript, BEAM, riscv64 bare metal · `plan/step-14-other-targets.md`

**Prereq:** Steps 01–13 (per target). These are roadmap entries, not execution-ready plans — each target gets its own step file when scheduled. Recommended order: Wasm → TypeScript → BEAM → riscv64.

- [x] **T14.1** — When a target is scheduled, split it into `step-NN-<target>.md` with the full standard format (goal / scope / tasks / acceptance) and update `plan/README.md`'s status table; its tasks continue the numbering (`T15.*`, …).
- [ ] **T14.2** — Record which key decision each target settled and where (README / `CHECK.md` / docs) — keep the trail.

Key decisions to settle per target: Wasm — WasmGC vs custom GC (prototype both); TypeScript — direct-style mapping onto the event loop, process mapping; BEAM — class value semantics vs Erlang maps; riscv64 — pluggable runtime, linker scripts (highest risk; pull the `core`-library layering earlier if EmoOS work starts).

Promotion trail: **TypeScript → `plan/step-15-typescript.md`** (2026-10-02, first target; its key decisions — IR lowering, uniform async, cooperative tasks — are settled in that file). **Wasm → `plan/step-16-wasm.md`** (2026-10-02, second target; the GC question is settled — WasmGC, structs and arrays with RTT dispatch, no custom heap). BEAM is next in the recommended order.

### Step 15 — TypeScript target · `plan/step-15-typescript.md`

**Prereq:** Steps 01–13.
**Done when:** `emo build --target typescript` emits TypeScript that runs on Node, the examples subset (hello_world, fib, objects, language_tour, shop, pipeline, tcp_echo, http_roundtrip) prints byte-for-byte what `emo run` prints (golden in CI), and a package lacking the target fails resolution before emission.

- [x] **T15.1** — Target plumbing and core emitter: `--target` through CLI, project, and the resolution gate; the IR → TypeScript emitter for the core subset; the tagged-value runtime. Golden: hello_world, fib, objects.
- [ ] **T15.2** — Full core semantics: patterns and guards, tuples, arrays, Box, interpolation, content equality, multi-file module references. Golden: language_tour, shop.
- [x] **T15.3** — Concurrency: cooperative tasks, mailboxes, selective receive, `self_pid`, `halt`. Golden: pipeline.
- [ ] **T15.4** — Direct-style IO: sockets and HTTP over Node's APIs as awaited promises; stdlib target metadata gains `"typescript"`. Golden: tcp_echo, http_roundtrip.
- [ ] **T15.5** — Bootstrap: the target-aware golden suite in CI, plus the resolution-gate test for packages lacking the target.

### Step 16 — Wasm target (WasmGC) · `plan/step-16-wasm.md`

**Prereq:** Steps 01–13.
**Done when:** `emo build --target wasm` produces a `.wasm` (plus its `.wat` sibling) that runs on Node's WasmGC, the core subset (hello_world, fib, objects, language_tour, shop) prints byte-for-byte what `emo run` prints (golden in CI), and a package lacking the target fails resolution before any emission.

- [x] **T16.1** — Backend skeleton: `--target wasm` plumbing (resolution gate reads the target); the WAT intermediate; the binary encoder; the boxed-struct value model with RTT dispatch. Golden: hello_world, fib, objects.
- [x] **T16.2** — Full core semantics: patterns and guards, tuples, arrays, Box, interpolation, content equality, interface narrowing, multi-file module references. Golden: language_tour, shop.
- [x] **T16.3** — Bootstrap: the wasm subset in CI, plus the resolution-gate refusal test for packages lacking `"wasm"`.
- [x] **T16.4** — Concurrency: a cooperative driver for `do` / `<-` / `receive`, host-timer preemption points. Golden: pipeline. (Gated on T16.2.)
- [ ] **T16.5** — The WASI and IO audit: stdlib metadata for `"wasm"`, and the io goldens where the host supports it.

## M5 — BEAM target & function groups

### Step 17 — BEAM target (Core Erlang) · `plan/step-17-beam.md`

**Prereq:** Steps 01–16.
**Done when:** `emo build --target beam` emits Core Erlang text that `erlc` assembles to a `.beam`, and the core subset (hello_world, fib, objects, language_tour, shop, pipeline) prints byte-for-byte what `emo run` prints (golden in CI), with the resolution gate reading `"beam"`.

- [x] **T17.1** — Backend skeleton: `--target beam` plumbing; the Core Erlang emitter (module, defs, literals, call/apply, sequencing) against the probed OTP 29 grammar. Golden: hello_world.
- [x] **T17.2** — The value model and arithmetic: masked i64 wrap-around Int64, binary Strings with interpolation, tuples, arrays, enums, deep content equality. Golden: fib.
- [x] **T17.3** — Classes/instances (tagged maps), Box holding processes, closures as funs, case patterns with guards. Golden: objects, language_tour.
- [x] **T17.4** — Processes (`do` / `<-` / `receive` via the compiler's receive primops), shop multi-module, pipeline golden; the CI `beam_examples` group and the resolution-gate test for `"beam"`.

### Step 18 — Function groups (`emo` keyword) · `plan/step-18-function-group.md`

**Prereq:** Steps 01–17.
**Done when:** `emo Foo { def ... const ... }` declares a function group, `Foo.hello()` / `Config.version` resolve and run on the interpreter and all four backends (goldens in CI), and the README documents the syntax.

- [x] **T18.1** — Parser (`emo` keyword + group items), checker (group symbols, name/arity rules), IR lowering to mangled functions; `examples/function_group/` golden through `emo run`.
- [x] **T18.2** — TypeScript, wasm, and beam goldens for the example; README (English + zh-CN) documents the syntax.

Close-out: groups lower to mangled functions with double-keyed symbols (group-qualified and module-bare), so every backend got them without backend code. The showcase example (processes across files on all four targets) landed with the TS process support; the manifest-path bug it exposed (an entry lowered twice under a relative path) is fixed in `emo_project`. Decisions are in `plan/step-18-function-group.md` (Close-out). **Step 18 acceptance met.**

## M6 — Systems programming

Two consumers pull one layer: a WebAssembly decoder, validator, and
interpreter written in Emo, and the EmoOS kernel path. The layer is
designed once under a unification gate — a primitive lands only when
it names both consumers (or one plus a concrete near-term need);
`plan/step-19-wasm-runtime.md` holds the project decisions, the
mechanism matrix, and the ladder.

### Step 19 — The systems layer (wasm runtime + EmoOS primitives) · `plan/step-19-wasm-runtime.md`

**Prereq:** Steps 01–18.
**Done when:** `& | ^ << >> ~` work on integer types across the interpreter and all four backends; the `Bytes` core type with little-endian accessors exists; `file.read` loads a file from disk under the scheduler; `Int64` and `Byte` arithmetic wraps on all targets (goldens in CI); `runtime/wasm/` exists as a real package.

- [x] **T19.1** — Bitwise operators (`& | ^ << >> ~`) on integer types: lexer, parser, checker, interpreter, and all four backends; `examples/bit_ops/` golden through `emo run` and every target's CI group.
- [x] **T19.2** — The `Bytes` core type: construction, bounds-checked get/set, little-endian accessors, String interop; all four backends; golden example. (u64 accessors landed with Int64 in T19.4; printing a raw `Bytes` value on wasm shows the buffer's bytes instead of the `Bytes[n]` label — known gap.)
- [x] **T19.3** — `file.read` stdlib package (native, scheduler-direct); a golden example reading a file from disk. Ships `file.write` too (the demo writes its own data file, keeping the golden CWD-independent); the write closes before resuming so read-your-own-write holds; tests resolve the registry via EMO_REGISTRY.
- [x] **T19.4** — `Int64` and `Byte`: literals, wrap-around arithmetic, comparisons, explicit conversions; all four backends; golden example. `runtime/wasm/` package skeleton created here.

Close-out: `Int64` and `Byte` ride the integer representations each target already had — OCaml `int64`/`int`, Erlang integers masked to signed 64 bits, wasm's `$vint`, TS `BigInt`/`number` — so no backend grew a second value model; what each added was the wrap rule (Byte masks to 256 after add, sub, mul, shl, bnot) and the explicit conversions, and `examples/fixed_width/` runs on all four targets. The `Bytes` u64 accessors deferred by T19.2 landed here, since `Int64` is the carrier they needed, and the golden exercises them everywhere. Two backend notes: OTP 29's `erlc` cannot compile a float bit-string pattern, so `Float.from_bits` goes through `binary_to_term` on an ETF float header; and Emo prints floats by OCaml's `%g` rule, which neither Erlang's nor JavaScript's native formatting matches, so both the BEAM runtime and the wasm host implement it. The wasm golden flushed out two runtime bugs the earlier examples never reached: `bytes_from_mem` read linear memory at `i` instead of `ptr + i`, and `int_str` took its digits with signed division, which mangles `INT64_MIN`. Decisions are in `plan/step-19-wasm-runtime.md` (Close-out). **Step 19 acceptance met.**

### Step 20 — Wasm runtime: decoder & validator · `plan/step-20-wasm-decoder.md`

**Prereq:** Step 19.
**Done when:** `runtime/wasm/` decodes and validates the vendored spec suite's binary-form cases — every valid module accepted, every `assert_malformed` case rejected in the decode phase, every `assert_invalid` case in the validation phase; the default `dune test` runs a smoke subset through the Emo-written runtime, and the `wasm_spec` alias runs the full list with nothing pending.

- [x] **T20.1** — The smoke rule: `runtime/wasm/main.emo`, its golden, and a `runtest` rule that runs `emo run main.emo` in the sandbox. The package stops being inert; no registry and no native toolchain (deps are `{}`).
- [x] **T20.2** — The case-list format and its hex codec, the corpus runner, the `main.emo` / `spec.emo` drivers, and the `wasm_spec` alias. Both lists start empty; the summary reports `pending 0`.
- [x] **T20.3** — `devtools/vendor-wasm-spec` (a pinned wasm-spec checkout through `wast2json --no-check`) and the first corpus: `binary.wast`'s binary-form cases, vendored as `pending`. Independent of every decoder task.
- [x] **T20.4** — The diagnosed-failure value and the `Bytes` reader, bounds-checked before every access; the truncated-read fixtures.
- [x] **T20.5** — LEB128 (`u32`/`u64`/`s32`/`s64`) with the spec's length caps; `binary-leb128.wast` plus hand-written boundary vectors.
- [x] **T20.6** — The header and the section walk: magic, version, section id and size, ordering, custom sections, unknown ids, trailing bytes.
- [x] **T20.7** — The type section, and the tag-tuple / cons-list shape the rest of the module model copies.
- [x] **T20.8** — The declaration sections: function, table, memory, global, import, export.
- [x] **T20.9** — Element, data, and constant expressions.
- [x] **T20.10** — The opcode table and the numeric instructions.
- [x] **T20.11** — The parametric, variable, and memory instructions.
- [x] **T20.12** — The structured instructions: block/loop/if/else/end, br/br_if/br_table, and the matching-`end` bookkeeping.
- [x] **T20.13** — `decode(bytes)` on the package's surface, and the valid-module corpus.
- [x] **T20.14** — The validation context, the index spaces, and function typing.
- [x] **T20.15** — The operand type stack for the plain instructions.
- [x] **T20.16** — Control frames: label depths, branch operand types, and the polymorphic stack after a branch.
- [x] **T20.17** — Cross-section rules: start function, element/data offsets, limits, global initializers.
- [x] **T20.18** — The corpus sweep with nothing pending, the smoke subset, `runtime/wasm/README.md`, close-out.

Close-out: the sweep left nothing behind — `wasm_spec` reports 3456 claimed, 0 pending, 0 failed, and the smoke subset (forty cases, every decoder and validator family) rides the default `dune test`. Getting there flushed out bugs older than the validator: br_table's immediate never consumed its default index (present since T20.12 — the leaked byte parsed as an opcode and desynced whole bodies), and the final bulk-memory opcode numbering replaced the pre-merge proposal's. The validator's frame stack carries a logical top (rebuilding per pop was exponential on nested blocks) and pushes land only after truncating to the live prefix; block parameters live inside their frame (push_ctrl semantics), and unreachable frames keep pushed values concrete so `type-num-vs-num` cases still reject. One interpreter limit shaped the code: a method call on a recursive result (`f(n-1).append(x)`) spins past roughly 25 nesting levels, so every array-returning recursion is a tail-accumulator loop — recorded as language pressure. The datacount rule splits by phase: with a data section present, bulk-memory use without a datacount is malformed; without one, the validator's unknown-segment check makes it invalid — both pinned by the corpus. The declared-reference set (globals, exports, element segments — not the start function) types `ref.func`. **Step 20 acceptance met.**


The boundaries that keep the in-repo runtime from becoming an in-repo language — the package edge, the spec data off the default test path, and the condition for the runtime leaving this repository — are in the plan file, with the surface pressure the runtime runs into and the sizes that make the list workable in spare sittings.

### Step 21 — Wasm runtime: interpreter core & spec-suite goldens · `plan/step-21-wasm-interpreter.md`

**Prereq:** Step 20.
**Done when:** `runtime/wasm/` executes a validated module — instantiate (imports resolved through a register namespace and the `spectest` host module, segments laid out with the spec's trap-on-overflow, start run), invoke exports, and report values or the first trap. The `wasm_runs` alias runs the vendored run corpus (every `assert_return` bit-exact including NaN payload classes, every `assert_trap` and instantiation failure where the spec says) with nothing pending; the default `dune test` runs a smoke slice of both corpora.

- [x] **T21.1** — The run-list format and its codec (type-tagged bit-pattern words, NaN tokens, verdict prefixes), the run runner beside step 20's, the `runs.emo` driver, the `wasm_runs` dune rule, and `vendor-wasm-spec runs` writing the command corpus as all-`pending`. Independent of every execution task.
- [x] **T21.2** — The instance model: a validated module materialized as frozen records — functions as signature + body byte range, the index spaces, the segments, imports, exports, start, the declared reference set — with `wasm.load(bytes)` on the package surface returning module-or-verdict.
- [x] **T21.3** — The value model: i32/i64 as masked patterns, f32/f64 as bit patterns that convert to `Float64` only at an operation, references as tagged pairs; the NaN payload discipline and the comparison codec. Fixtures first — no execution yet.
- [x] **T21.4** — The integer families as pure functions: wrap-around arithmetic, shifts and rotates, clz/ctz/popcnt, division and remainder with their traps, sign extension, saturating truncation, wrap and extends. Boundary fixtures from the spec.
- [x] **T21.5** — The float families: arithmetic and comparisons through the bridge; conversions including truncation traps, promote/demote with correctly-rounded bit surgery (no `Float32` in the language), reinterpret as a pattern move. Conversion-boundary fixtures, NaN classes included.
- [x] **T21.6** — The store: linear memory on `Bytes` (page-granular grow, bounds before access, little-endian widths), tables with grow/size/fill/copy/init, mutable globals; traps as values. Fixtures at the OOB edges.
- [x] **T21.7** — The frame machine: the operand arena of u64 slots, locals and the variable instructions, structured control by recursion with branches as unwind signals, `call`/`call_indirect` with their traps, `return`, `unreachable`. A `fac` fixture proves the tail-call chain.
- [x] **T21.8** — Instantiation and linking: import resolution through the register namespace and host, global initializers, segment layout with trap-on-overflow (`assert_uninstantiable` fails here, store discarded), the start function, `register`. Link failures for missing or mismatched imports.
- [x] **T21.9** — The `spectest` host module: the print functions, typed globals, table, and memory behind the same import interface.
- [x] **T21.10** — Sweep I: the run families claimed in order — integers, floats, conversions, control flow, calls — each flip its own sitting; residuals stay pending.
- [x] **T21.11** — Sweep II: addressing and endianness, memory and table operations, segment initialization, linking through the register namespace, imports through spectest, the trap cases, and the leftovers — the run list ends at zero pending and zero failed.
- [x] **T21.12** — Close-out: the run-list smoke slice rides `dune test`, `runtime/wasm/README.md` grows the execution surface, acceptance recorded here and in `docs/TASKS.md` (both languages).

Close-out: the sweep ends at **25135 claimed, 0 pending, 0 failed** over the vendored run corpus — every `assert_return` bit-exact (NaN classes for the NaN tokens), every `assert_trap` and instantiation failure where the spec says, `register` and linking behaving — and the default `dune test` runs a smoke slice of both corpora. The gate produced one language addition, the float primitives `Float64.sqrt`/`floor`/`ceil`/`trunc`, `Float64.to_int64`, and `Int64.to_float64` (`CHECK.md`). The run driver is compiled: the evaluator is correct but cannot carry the loop-heavy memory tests past its recursion limit, and native compilation needed the boxed-`Int64` route plus module-level-`var` support, both landed here. **Step 21 acceptance met.**

The boundaries step 20 recorded bind unchanged (package edge, spec data off the default test path, the split condition), and the standing rule from step 20's sweep — no method call on a recursive result — is formal in the plan. The pressure notes (`Int32`/`Float32` masking, the growable-buffer arena, the recursion limit, argv) are the gate's raw material, not tasks.

## M7 — EmoOS

The kernel path, on the systems layer M6 lands. Near term: a unikernel
build path — the native backend already emits OCaml, and the
MirageOS/solo5 lineage proves that stack boots — with the `foreign
def` FFI as the machine escape hatch (ports, asm shims) and the
`core` library split from step 14's notes pulled for real. Far term:
freestanding codegen, the same investment a tiered wasm engine needs.
Step plans are written when the kernel work starts; the
freestanding-codegen step is already split out — step 22 below.

### Step 22 — RISC-V target (freestanding RV64) · `plan/step-22-riscv64.md`

**Prereq:** Steps 01–13 (the specialization pass); the step-14 RISC-V
reference note is the design record.
**Done when:** `emo build --target riscv64` produces a freestanding ELF
that boots under `qemu-system-riscv64 -machine virt`; every example in
the core subset prints exactly what `emo run` prints (goldens in CI);
`spawn`/`send`/`receive` and `foreign def` refuse with clear
diagnostics; packages without `"riscv64"` fail resolution; `dune test`
green.

- [ ] **T22.1** — The backend skeleton: `--target riscv64` plumbing
      (emitter module; the CLI arm writing `main.s`, invoking
      `as`/`ld` with the generated linker script; `emo run` booting the
      ELF under QEMU); the entry stub, BSS clear, SBI console.
      Golden: hello_world (serial output byte-for-byte vs `emo run`).
- [ ] **T22.2** — The value model and arithmetic: the tagged-word
      dynamic representation (`Int64`/`Float64` boxed cells, Bool/Char
      immediates) and the bump allocator; wrap-around arithmetic,
      comparisons, `if`, integer formatting (`INT64_MIN` correct);
      guaranteed tail calls as `tail`. Golden: fib.
- [ ] **T22.3** — Dynamic-world data structures: tuples, arrays, Box,
      enums, instances with vtable dispatch, closures and first-class
      functions; patterns with guards; interpolation with the `%g`
      float rule. Golden: objects, language_tour.
- [ ] **T22.4** — Bootstrap: the `riscv64_examples` CI group (QEMU +
      cross-binutils on the runner), the resolution-gate refusal test
      for packages lacking `"riscv64"`, the emission-time refusal
      diagnostics, close-out.

## M8 — Self-contained hosted backend

The hosted half of the self-contained story: Emo's own runtime, the
C ABI as the FFI surface, and no OCaml toolchain in the produced
binary — once this ships, building Emo programs no longer requires an
OCaml toolchain either (CHECK.md, tool distribution). Step 23
(`plan/step-23-hosted-native-ffi.md`) is this milestone's
design-record assessment — an assessment, not a task-bearing step,
which is why no Step 23 section appears in this file. Step 22 above
stays the EmoOS kernel path; the two share the tagged-word value
model from step 22's study.

### Step 24 — C target (emit C) · `plan/step-24-c-target.md`

**Prereq:** Steps 01–13 (the IR); `plan/step-23-hosted-native-ffi.md` is the design record this step schedules.
**Done when:** `emo build --target c` emits C, compiles with the system `cc`, and links a standalone binary with no OCaml runtime; the golden subset (hello_world, fib, objects, language_tour, shop, pipeline, function_group, bit_ops, bytes, fixed_width, file_read) prints byte-for-byte what `emo run` prints (golden in CI); `foreign def` crosses the direct C ABI; a package lacking `"c"` fails resolution; `dune test` green.

- [x] **T24.1** — Design-gate closure (CHECK.md: route confirmed emit-C, trampoline settled, arena provisional) and the backend skeleton: the emitter module in `src/emo_codegen` + the `--target c` CLI arm invoking `cc`; entry stub, hosted startup, `println`; `"c"` enters `known_targets` with the resolution-gate refusal test. Golden: hello_world.
- [x] **T24.2** — Tail calls and the integer core: the trampoline (self/mutual tail calls, `return` as branch-to-epilogue — the fix for the current backend's ~4x loop regression); wrap-around `Int64` on `uint64_t`; comparisons, `if`, `INT64_MIN`-correct formatting. Goldens: fib; the 1M-deep `count_down` stays flat on the C stack; `loops_tail` recorded in `benchmarks/results.md` (4 ms — the OCaml backend's specialized build takes 1910 ms). The examples/fib golden itself waits on closures (T24.5) — its `greeting` needs them; the `c_integer` fixture covers fib, count_down, a mutual-tail cluster, and wrap-around, under a 1MB C stack. Also fixes the checker's span-type table (keyed by start offset alone, later checks overwrote nested expressions' types) and the wasm/beam backends' ClassType dispatch that the fix exposed.
- [x] **T24.3** — The scalar runtime: length-prefixed strings (NUL-terminated only at the FFI boundary), the `%g` float rule, `Bool`/`Char`, interpolation, scalar content equality. Goldens: numerics, if_expr. (Done 2026-10-06: if_expr is the first full-example golden; numerics itself waits on `foreign def` (T24.8) and tuples (T24.4) — the `c_scalar` fixture cross-checks the printing rules against the interpreter's own rendering instead. The string layout and the runtime-in-C decisions are recorded in CHECK.md.)
- [x] **T24.4** — The dynamic value model: step 22's tagged word (8-byte-aligned cells, 3 tag bits; `Int64`/`Float64` boxed two-word cells; no NaN-boxing), bump/arena allocator (provisional), tuples, value-semantic arrays, `Box`. Golden: objects. (Done 2026-10-06: the tagged word is live — one `emo_value` word, low bits 000/001/011 for pointer/Bool/Char, cell kinds in the header word — with bump allocation and malloc-leak documented in CHECK.md's provisional profile. Regime conversion (`emo_box_*`/`emo_unbox_*`) bridges native and dynamic code at every call, binding, return, and operator; dynamic `+`/comparisons/equality dispatch in the runtime per the interpreter's rules; `to_string` renders tuples `(a, b)`, arrays `[a, b]`, Box as `<box>`. The objects golden waits on classes (T24.5) — the `c_dynamic` fixture cross-checks the dynamic world against the interpreter's own rendering instead.)
- [x] **T24.5** — Classes, enums, interfaces, closures: instances with compile-time vtables, enum singletons, structural `is()`, patterns with guards; the reclamation decision lands in CHECK.md before this merges. Golden: language_tour. (Done 2026-10-06: language_tour AND objects both full-example goldens, byte-for-byte. Vtables carry method sigs with dynamic-convention thunks — class-typed receivers dispatch directly, interface/Unknown receivers through `emo_send`; `is()` compares vtable identity (classes) or shape (interfaces); closures take the canonical dynamic convention `[header][fn][captured...]` with creation-site capture analysis and direct dynamic returns; `case` lowers to sequential test/bind/guard blocks with goto-chained fall-through. The reclamation decision settled in CHECK.md: reference counting over the identity objects, arena for value-semantic data — the retain/release emitter work lands before T24.9 makes long-running programs real.)
- [x] **T24.6** — Modules and exceptions: multi-file module references, `raise`, uncaught-exception exit codes (`begin`/`catch`/`ensure` stays unscheduled — out of scope). Goldens: shop, function_group (free via IR lowering — claim the golden). (Done 2026-10-06: both goldens claimed byte-for-byte. Multi-file references needed two call-site fixes — funsigs now carries the callee's declared result so a cross-module call the checker types Unknown still converts, and the IR no longer lowers module-alias const bindings as thunks (they bound a path, not a value); group-const thunks return Unknown, not Void. `raise` renders the interpreter's E3010 message to stderr and exits 1 — no unwinder until `begin`/`catch` lands.)
- [x] **T24.7** — The systems-layer surface: `Bytes` with little-endian accessors, the bitwise operators, `Byte`, `Int64`/`Float64` bit-casts. Goldens: bit_ops, bytes, fixed_width. (Done 2026-10-06: all three full-example goldens byte-for-byte. `&`/`|`/`^` are exact two's-complement on int64_t; `<<`/`>>` guard the count (negative errors, ≥64 gives 0/sign-fill) in the runtime; Byte is uint8_t with wrap-by-truncation and the Int64 div/shift guards; a Byte in the dynamic world materializes as an Int64 cell. Bytes is a new cell kind with in-cell storage, `to_bytes`/`to_string` interop, and a runtime `to_string` method dispatch (Bytes content vs value rendering) — the interpreter's runtime dispatch, mirrored. The checker now types `Unknown + Unknown` as Unknown (the runtime dispatches `+` per the values — neither result is provable); C reserved words in Emo defs get a `_c` suffix.)
- [x] **T24.8** — C FFI rungs 1–3 on the direct C ABI (no wrapper generator): scalars, width types as they land, opaque handles + copied buffers; the capability table flips `c` to honoring `foreign def`. Goldens: a libm `sqrt` fixture and a tiny C opaque-handle fixture under `test/`. (Done 2026-10-06: the c backend emits `extern` declarations and calls the symbol directly — no wrappers. Strings cross with a NUL terminator (`emo_str_cstr` out, `emo_str_from_cstr` in, per CHECK.md's layout decision); Int64 crosses as `int64_t` — the capability table is now target-aware in the checker (`c` admits Int64, the OCaml backend stays Float64/String/Bool); opaque handles ride pointer-sized Int64s behind a tiny externally-owned counter library, explicitly closed, in the `c_foreign` test group alongside the libm fixture.)
- [x] **T24.9** — Processes and the cooperative scheduler: `do` / `<-` / `receive`, mailboxes, selective receive, `self_pid`, `halt`; single-threaded cooperative loop; traces diffed against `emo_sched_det`. Goldens: pipeline, showcase. (Done 2026-10-06: both full-example goldens byte-for-byte. Each Emo process is a ucontext fiber with its own stack; the scheduler keeps emo_sched_det's policy — FIFO run queue, spawn enqueues the child without suspending the spawner, send delivers + wakes + re-queues the sender at the tail, receive scans the mailbox in generated code for the first message a branch accepts (a failed guard leaves the message queued) and parks the fiber when nothing matches; an empty run queue with parked fibers is a reported deadlock. Pids are an EMO_PID cell (rendered `<pid N>`); `EMO_TRACE=1` prints spawn/send/park/dispatch/exit/reap events for diffing. Also fixed en route: the entry file discovered twice (root + tree copies, keyed by a `/.`-carrying path) lowered every symbol under two manglings — the walk now normalizes file paths and the IR dedupes module copies by the parsed items' physical identity.)
- [x] **T24.10** — Hosted IO and stdlib metadata: `file.read`/`file.write`, TCP/UDP sockets, the HTTP client/server over the hosted OS; stdlib gains `"c"` in `targets`. Goldens: file_read, tcp_echo, http_roundtrip. (Done 2026-10-06: all three full-example goldens byte-for-byte, including the stdlib http/net packages compiling on the c target. Sockets are non-blocking fds whose would-block reads park the fiber — the scheduler polls parked descriptors while the run queue is empty; the root process finishing ends the program. Cross-module Unknown receivers dispatch by method/field NAME (globally builtin-owned names, runtime helpers; instance fields by vtable name). Unix sockets, TLS, DNS resolve, and UDP compile as honest runtime refusals. The stdlib file/net/http packages and the three examples declare `"c"`, lockfiles regenerated.)
- [x] **T24.11** — Bootstrap, benchmarks, close-out: the `c_examples` CI group; specialization (unboxing, direct dispatch) with `restrict` on hot loops; `benchmarks/results.md` gains the `c` column; the `native` → `ocaml` rename lands here or in its own step; close-out records the decisions. (Done 2026-10-06: all six benchmarks recorded on the c target — fib 7 ms, tail loop 4 ms (470x under the OCaml backend's specialized build, 1.3x from the C baseline), ffi 46 ms, bytes 43 ms, json 3 ms, http 83 req/s. Specialization is structural: the two-regime emitter already unboxes natives and dispatches directly where types are known; `restrict` waits for pointer-parameter loops (the buffer rung). The rename is its own step, next.)

## M9 — Toolchain

The last mile of the self-contained story, and the toolchain
release — cut as v0.25.9, with the official 1.0 following.
M8 removed the OCaml toolchain from the *programs*; M9 removes the
installation burden from the *tool* — the release engineering
`CHECK.md` left unscheduled, on the decided direction
(`docs/toolchain-distribution.md` is the design record): prebuilt
binaries per platform on GitHub Releases as the primary channel,
`opam` and a Homebrew formula as the source-building alternatives,
and the command set a product needs — `emo new`, `emo install`,
`emo doctor` join `run`/`repl`/`check`/`build`/`deps`/`publish` — so
a machine with nothing but the binary runs, checks, builds (through
the `c` target), installs dependencies, and publishes.

Boundaries, stated plainly: the public registry *service* is a
separate milestone — the tool ships speaking the filesystem registry
plus the bundled stdlib (`publish` already speaks HTTP; fetching
over HTTP lands with the service it talks to); native Windows is not
this release — WSL2 is the supported Windows path, and the
ucontext/socket port of the C runtime is the recorded blocker
(Microsoft Trusted Signing stays the recorded signing route for when
it lands); the c backend's recorded follow-ups (retain/release
emission, the zero-copy buffer rung, cross-module type propagation)
are backend work and stay with the backend line.

### Step 25 — Toolchain distribution & release · `plan/step-25-toolchain.md`

**Prereq:** Step 24 (the `c` target; the `native` → `ocaml` rename landed with it).
**Done when:** the release workflow, run on a version tag, produces
signed per-platform archives (Linux x86_64/aarch64, macOS
x86_64/arm64) whose binaries pass the end-to-end acceptance on every
platform; a machine with only the installed binary — no OCaml, no
opam, no repository — runs, checks, and builds Emo programs through
the `c` target, scaffolds with `emo new`, installs dependencies with
`emo install`, and diagnoses its environment with `emo doctor`;
`dune test` green.

- [x] **T25.1** — Design-gate closure and the default target: the
      four settlements recorded in `CHECK.md` — the build default
      flips `ocaml` → `c`; the stdlib embeds as generated data (the
      C runtime's mechanism) over a sidecar tree; `emo install` is
      the project-dependencies front end (global executable
      installation out of scope for 1.0); the dependency cache
      leaves the temp directory for a durable user location. The
      flip lands here, with the resolution-gate tests and the CI
      groups re-pointed — the c goldens already cover the target;
      only the default moves. (Done 2026-10-07: all four settled in CHECK.md; the flip moved every default path to c and exposed that the content-hash cache lived only in the ocaml arm — the c arm gained it; ocaml-backend harnesses and benchmarks pinned --target ocaml; tree-wide @fmt drift promoted.)
- [x] **T25.2** — The self-contained binary: the bundled stdlib as
      generated data inside the compiler; the registry endpoint
      becomes a filesystem directory or the embedded stdlib;
      `EMO_REGISTRY` still overrides. Verification: a lone `emo`
      copied into an empty directory runs, checks, and builds a
      stdlib-importing program — and `publish`'s embedded uploader
      works from it. (Done 2026-10-07: generated data via devtools/gen-stdlib-data.sh; the macOS sandbox materializes the source_tree dep as symlinks — the generator walks -type f -o -type l, found by probe; endpoint is Fs_dir or Embedded; lone-binary verification passed (run/check/build/publish); embedded-vs-filesystem checksum parity pinned by a test.)
- [x] **T25.3** — `emo new <name>`: the scaffold — `package.emo`
      (name, version, targets) and a hello-world `main.emo`, plus
      `.gitignore`. Strictness holds: an existing directory or
      clashing files refuse with clear errors, no `--force`. The
      scaffold is green the moment it exists — CI creates, checks,
      runs, and builds one. (Done 2026-10-07: CI scaffolds/checks/builds/runs one; owner/name taken as given on relative single-slash args; refusals exit 65.)
- [x] **T25.4** — `emo install`: read the manifest, resolve against
      the registry, fetch into the user cache, write
      `package.lock`; idempotent re-runs change nothing; each
      failure mode — no registry configured, unsatisfiable pin, a
      dependency lacking the requested target — gets its own clear
      message. `emo deps` keeps resolve/update/list as the explicit
      paths. (Done 2026-10-07: idempotent; lockfile written only when it would change; cache default moved to ~/.cache/emo (XDG honored, EMO_CACHE_DIR overrides).)
- [x] **T25.5** — `emo doctor`: the target-aware environment check,
      replacing the interim ocaml-only shape in `CHECK.md`. Per
      target: `c` — a cc compile-and-run smoke; `ocaml` — the
      runtime `.cmxa` found in the switch, or the honest "prebuilt
      installation: the ocaml target needs a source install
      (`opam install emo`)"; `typescript` — node; `beam` — erlc;
      `wasm` — nothing. Plus the installation shape (prebuilt vs
      source), stdlib presence, and version. Exit non-zero only on
      what is actually broken. (Done 2026-10-07: source-vs-prebuilt via the runtime .cmxa set; the c smoke decides the exit code; ocaml unavailable reports the opam install fix.)
- [x] **T25.6** — Release packaging and CI: the tag-triggered
      workflow beside the existing CI — per-platform matrix builds
      (Linux x86_64/aarch64, macOS x86_64/arm64), release binaries
      through dune, the archive layout T25.1 settled, `SHA256SUMS`,
      a drafted GitHub Release. The Linux binary is portable —
      static or the oldest viable glibc — verified in clean
      containers, not on the builder. (Done 2026-10-07: package-release.sh verified end to end locally; matrix = linux x86_64/aarch64 (ubuntu-22.04, glibc 2.35) + macOS x86_64/arm64, suite run before packaging, Linux verified in a clean ubuntu:22.04 container.)
- [x] **T25.7** — Signing and the platform gates: macOS codesign
      (hardened runtime) → notarytool → staple, credentials in CI
      secrets — the solved-not-a-blocker from `CHECK.md`, now
      scheduled. Windows: WSL2 documented as the supported path,
      the native prebuilt recorded as deferred with the
      ucontext/socket port named as the blocker;
      `docs/toolchain-distribution.md` updated (both languages). (Done 2026-10-07: four secrets gate codesign → notarytool → staple; absent secrets ship unsigned with a notice; distribution docs updated both languages.)
- [x] **T25.8** — Provisioning channels and install docs: the
      Homebrew formula (own tap; core when the project qualifies)
      and the opam package — the source channel that brings the
      `ocaml` target. README install sections in both languages:
      prebuilt archives first, then brew, opam, WSL2. (Done 2026-10-07: formula at devtools/homebrew/emo.rb for the own tap, checksums filled at release; dune-project generates emo.opam (no dev_repo field in the stanza — dropped); README install sections in both languages.)
- [x] **T25.9** — Release acceptance and the release cut: on every shipped
      artifact, end to end — download, unpack, `emo doctor`,
      `emo new`, `emo run`, `emo install`, `emo build` (the `c`
      target) — including a stdlib-importing program and the golden
      subset executed from the installed binary. the release commit
      carries the released VERSION; annotated tag, release notes,
      close-out. (Done 2026-10-07: acceptance ran against the packaged-and-unpacked archive (built while
VERSION read v1.0.0; re-cut v0.25.9 before tagging) — doctor healthy in the prebuilt shape; new → run → build green; install resolves through the embedded stdlib; goldens 14/14 from the installed binary (13 via emo run byte-for-byte, numerics via its designed compiled path — it crosses foreign def, which emo run refuses; http_roundtrip/tcp_echo ride the in-tree suite). VERSION shipped as v0.25.9.)

Close-out: recorded 2026-10-07 in `plan/step-25-toolchain.md` — the
acceptance ran against the packaged artifact, not the build tree; the
default-target flip moved every default path to `c` (and flushed out
that the content-hash cache had only ever lived in the ocaml arm),
the embed's dune rule needs `-type f -o -type l` because the macOS
sandbox materializes `source_tree` deps as symlinks, and the archives
ship without an install script. **Step 25 acceptance met.** M9 is
done: the toolchain release is v0.25.9 — the official 1.0 follows.

## M10 — Target independence

The host/target distinction made load-bearing. The host language (how
emo was built — today OCaml) answers one question; the targets (what
emo turns your program into) answer another. Fully honoring the split
means the host contributes only the emitters: every target's runtime
lives in the target's own ecosystem, never beside the binary and never
in the host build tree — so a future host rewrite (Go, Rust) touches
only the emitters.

The audit found three of five targets already there — **c** (standalone
C runtime embedded as generated data, the pattern to generalize),
**wasm** (runtime compiled into the module; the 3 imports are the ABI
with the wasm engine, a different axis), **beam** (one self-contained
Core Erlang module standing on OTP). Two are not: **typescript** ships
its runtime prelude as a side file and is therefore broken on every
installed binary (the release layout carries only `bin/emo`), and
**ocaml** links the host's own eight libraries out of the host build
tree, which is why it works only in-tree — and why `opam install emo`
does not bring it (verified: the opam install set is seven files, zero
`.cmxa`).

### Step 26 — Target independence · `plan/step-26-target-independence.md`

**Prereq:** Step 25 (the toolchain whose claims this step corrects).
**Done when:** no target reads its runtime from beside the binary or
the host build tree — c, ocaml, and typescript runtimes ride inside
the compiler as generated data, wasm and beam inside the emitted
module; `emo build --target ocaml` works on any installation where
the OCaml toolchain is on PATH, with no `.cmxa` lookup and no
installation-shape conditionals; the typescript target works from the
release layout; all goldens byte-for-byte; `dune test` green.

- [x] **T26.1** — The principle and the ts embed: the
      runtime-independence principle recorded in `CHECK.md`; the ts
      prelude embedded as generated data (the C runtime's dune rule
      pattern), the typescript arm stopped from reading the
      filesystem. Verification: a lone release-layout binary compiles
      a typescript program; the ts goldens byte-for-byte. (Done
      2026-10-07: the prelude rides `emo_codegen/ts` as generated data
      and the CLI never touches the filesystem for it; a lone binary
      compiles and runs a ts program; the seven ts goldens green.)
- [x] **T26.2** — The emitted-code inventory and the standalone
      skeleton: emit the golden subset through the ocaml emitter,
      collect mechanically every host symbol the emitted code
      references, and record the inventory as the standalone runtime's
      contract; the skeleton compiles with plain `ocamlopt`, zero
      `emo_*` dependencies, proven by a fixture from the build
      directory alone. (Done 2026-10-07: two modules and 70-odd
      symbols recorded in the plan as the contract, collected by
      `devtools/ocaml-runtime-inventory.sh` over the sixteen-example
      golden corpus with a stray-module alarm; the skeleton lands with
      the ADT, signals, and effects final.)
- [x] **T26.3** — The value and scalar core: the value ADT, strings,
      print/interpolation rendering, arithmetic/comparison dispatch,
      and the case/error paths the inventory names, standalone. Each
      piece covered by a fixture compiled against the runtime alone.
      (Done 2026-10-07: five fixture programs in the emitter's call
      shape, compiled with `ocamlopt -open Emo_ocaml_runtime` against
      the extracted runtime alone.)
- [x] **T26.4** — The scheduler and IO: the effects-based scheduler,
      file IO, and networking, per the dependency policy (the OCaml
      standard library plus `unix`; `ssl` as the one opam dep; no eio).
      Fixtures: a process program and an HTTP roundtrip compiled
      against the standalone runtime alone. (Done 2026-10-07: the det
      scheduler ports whole — spawn/send/receive, fd and timer parking,
      TLS, UDP, file IO; eio drops out, the policy settles on unix plus
      ssl; four more fixtures ride the scheduler.)
- [x] **T26.5** — The cutover: the ocaml emitter's references flip to
      the standalone runtime; the arm emits runtime + `main.ml` and
      invokes `ocamlopt` (ocamlfind only for the runtime's own
      packages); the `.cmxa` machinery, the library scan, and the
      beside-binary lookup are deleted; refusal and doctor wording
      become installation-independent. All ocaml goldens and tests
      byte-for-byte; an installed binary with an OCaml toolchain
      builds the golden subset. (Done 2026-10-07: the arm writes
      runtime + main.ml and compiles them with the target's own
      ocamlopt; the cmxa machinery, the library scan, and the
      beside-binary lookup are deleted; all sixteen goldens match
      byte-for-byte and the emitted main.ml is unchanged; a lone
      release-layout binary builds the golden subset.)
- [x] **T26.6** — The independence audit and close-out: wasm and beam
      recorded as verified-independent (no tasks — evidence noted);
      the docs corrected (`docs/toolchain.md`,
      `docs/toolchain-distribution.md` — the true ocaml-target story
      replaces "a source install brings the ocaml target");
      `benchmarks/results.md`'s ocaml column re-run against the
      standalone runtime; close-out. (Done 2026-10-07: wasm and beam
      recorded verified-independent in the plan; both toolchain docs
      corrected bilingually — the true ocaml-target story replaces the
      source-install story, and doctor lost its installation line; the
      benchmark suite re-ran on the standalone runtime with the ocaml
      rows within the machine's observed run-to-run noise; plan status
      done.)

Step 26 complete 2026-10-07 (T26.1–T26.6 on
`feat/target-independence`): no target reads its runtime from beside
the binary or the host build tree; the ocaml target works from a lone
release-layout binary wherever the OCaml toolchain is on PATH; the
typescript target likewise; all goldens byte-for-byte and `dune test`
green.

### Step 27 — The standard library: `json` · `plan/step-27-stdlib-json.md`

**Prereq:** Step 10 (packages) + step 26 (target independence).
**Done when:** `require "json"` decodes and encodes JSON on every
target the compiler ships, byte-identically — strict offset-bearing
errors, exactly round-tripping numbers, a value tree of ordinary Emo
data over the shared runtimes, zero per-target runtime work beyond the
typescript UTF-8 bytes fix; goldens on all six paths; `dune test`
green.

- [x] **T27.1** — The spec and the skeleton: the package
      `stdlib/registry/json/0.1.0` (`package.emo` over the five tested
      targets, `json.emo` with the value model — `JsonKind`, the
      `Json` interface, seven payload classes, the factories — and
      `internal/float.emo` for the numeric machinery) embedded by
      rebuild. Verification: a factory-built value encodes,
      interpreted. (Done 2026-10-09.)
- [x] **T27.2** — The typescript bytes fix: `to_bytes` encodes UTF-8
      and `Bytes.to_string` decodes UTF-8 in the ts prelude; all
      existing ts goldens byte-for-byte. (Done 2026-10-09: the
      interpreter, c, and typescript agree on a non-ASCII
      round-trip.)
- [x] **T27.3** — The decoder: the byte-level scanner and
      recursive-descent parser over the RFC 8259 grammar — escapes
      with surrogate pairs, exact `Int64`/`Float64` numbers, the depth
      cap, offset-bearing errors. (Done 2026-10-09: decode rounds
      decimals once, to nearest with ties to even — `strtod`'s
      answer — via exact long division in `internal/float.emo`.)
- [x] **T27.4** — The encoder: compact and pretty forms; string
      escaping; integers through `Int64.to_string`; the
      shortest-round-trip float formatter. (Done 2026-10-09: π prints
      `3.141592653589793`, denormal-min prints `5.0e-324`, max prints
      `1.7976931348623157e+308`; a float always stays visibly a
      float.)
- [x] **T27.5** — The golden example: `examples/json_demo` wired into
      the interpreter-bootstrap and typescript golden lists (one
      `expected.txt`); c, wasm, and beam wait on the cross-module
      follow-up below. (Done 2026-10-09.)
- [x] **T27.6** — The edge fixtures: `examples/json_edge` — escape
      matrix, surrogate pairs, the 512-array cap round-tripped,
      duplicate keys, number boundaries, round-trips, pretty form —
      wired into the interpreter-bootstrap list. (Done 2026-10-09;
      flushed out the missing empty-container guards in the compact
      encoder.)
- [x] **T27.7** — The docs and close-out: `docs/stdlib/json.md` and
      its zh-CN mirror; `dune build @fmt` and `dune test` green.
      (Done 2026-10-09.)

Step 27 close-out (2026-10-09, on `feat/stdlib`): `require "json"`
decodes and encodes byte-identically on the interpreter, the ocaml
target, and the typescript target — goldens `json_demo` (bootstrap +
ts) and `json_edge` (bootstrap) green, `dune build @fmt` and
`dune test` green end to end. The package is ordinary pure Emo; the c,
wasm, and beam targets stay blocked on one checker step — cross-module
type names ("cross-module types stay unchecked this step", step 9) —
with the minimal repros and the backend fixes this step already landed
recorded in `plan/step-27-stdlib-json.md`. Compiler fixes riding this
step: the span type table keyed by file (multi-module type
corruption), the typescript tail-call rewrite's argument
temporaries + string escapes + interface separators, the c `emo_send`
argument array + unknown-receiver vtable fallback + mutual-tail
cluster entry dispatch, and the wasm interface-dispatch `Ref_cast` +
field display-name resolution.

### Step 28 — The standard library: `yaml` · `plan/step-28-stdlib-yaml.md`

**Prereq:** Step 27 (the json package — the tree design and the float
machinery this package mirrors). **Done when:** `require "yaml"`
decodes and encodes YAML 1.2 (core schema) byte-identically on the
targets the checker carries — block/flow, quoted scalars with the
YAML escape set, block scalars with chomping, duplicate keys
last-win, numbers at their boundaries; goldens green on
interpreter/ocaml/typescript; c, wasm, and beam wait on the
cross-module-types follow-up shared with step 27.

- [x] **T28.1** — The package and the parser: `stdlib/registry/yaml/
      0.1.0` embedded by rebuild; the value model, the block/flow
      parser. (Done 2026-10-09.)
- [x] **T28.2** — The encoder: block style; plain-when-unambiguous
      strings; empty-container flow forms. (Done 2026-10-09.)
- [x] **T28.3** — The goldens: `examples/yaml_demo` (bootstrap +
      typescript) and `examples/yaml_edge` (bootstrap). (Done
      2026-10-09.)
- [x] **T28.4** — The docs: `docs/stdlib/yaml.md` + zh-CN mirror;
      `dune build @fmt` and `dune test` green. (Done 2026-10-09.)

Step 28 close-out (2026-10-09, on `feat/stdlib`): the yaml package
mirrors the json package's tree design and passes its goldens on the
interpreter, ocaml, and typescript; c, wasm, and beam remain gated on
the cross-module-types checker step shared with step 27. The package
also flushed out the typescript runtime's field-shadows-method
dispatch bug (fixed in `ts_runtime.ts`: E.method now falls through to
the prototype's method when the own property is not a function).
