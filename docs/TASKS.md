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
| M4 — Compilation targets | 13–14 | Native code generation via `emo build`; then wasm / TypeScript / BEAM / riscv64. |
| M5 — BEAM & function groups | 17–18 | The BEAM target ships its golden tier; `emo Foo { ... }` function groups resolve and run on all four targets. |
| M6 — Systems programming | 19–21 | A WebAssembly runtime written in Emo: the shared systems layer, then the binary decoder/validator, then the interpreter with spec-suite goldens. |
| M7 — EmoOS | 22+ | The kernel path on the same systems layer: a unikernel build path (near term), then freestanding codegen (shared with the engine tiering). |

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
- [x] **T8.4** — Flow environments with narrowing on `is()`.
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

Close-out: the exact `net.*` / `http.*` names are in the README (Networking); the stdlib ships as directory-registry packages under `stdlib/registry` with `targets = ["native"]`; the acceptance example is `examples/http_roundtrip`. Step decisions are in `plan/step-12-networking.md` (Close-out). **M3 exit criteria met.**

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
- [x] **T17.2** — The value model and arithmetic: masked i64 wrap-around Int, binary Strings with interpolation, tuples, arrays, enums, deep content equality. Golden: fib.
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

- [ ] **T20.1** — The smoke rule: `runtime/wasm/main.emo`, its golden, and a `runtest` rule that runs `emo run main.emo` in the sandbox. The package stops being inert; no registry and no native toolchain (deps are `{}`).
- [ ] **T20.2** — The case-list format and its hex codec, the corpus runner, the `main.emo` / `spec.emo` drivers, and the `wasm_spec` alias. Both lists start empty; the summary reports `pending 0`.
- [ ] **T20.3** — `devtools/vendor-wasm-spec` (a pinned wasm-spec checkout through `wast2json --no-check`) and the first corpus: `binary.wast`'s binary-form cases, vendored as `pending`. Independent of every decoder task.
- [ ] **T20.4** — The diagnosed-failure value and the `Bytes` reader, bounds-checked before every access; the truncated-read fixtures.
- [ ] **T20.5** — LEB128 (`u32`/`u64`/`s32`/`s64`) with the spec's length caps; `binary-leb128.wast` plus hand-written boundary vectors.
- [ ] **T20.6** — The header and the section walk: magic, version, section id and size, ordering, custom sections, unknown ids, trailing bytes.
- [ ] **T20.7** — The type section, and the tag-tuple / cons-list shape the rest of the module model copies.
- [ ] **T20.8** — The declaration sections: function, table, memory, global, import, export.
- [ ] **T20.9** — Element, data, and constant expressions.
- [ ] **T20.10** — The opcode table and the numeric instructions.
- [ ] **T20.11** — The parametric, variable, and memory instructions.
- [ ] **T20.12** — The structured instructions: block/loop/if/else/end, br/br_if/br_table, and the matching-`end` bookkeeping.
- [ ] **T20.13** — `decode(bytes)` on the package's surface, and the valid-module corpus.
- [ ] **T20.14** — The validation context, the index spaces, and function typing.
- [ ] **T20.15** — The operand type stack for the plain instructions.
- [ ] **T20.16** — Control frames: label depths, branch operand types, and the polymorphic stack after a branch.
- [ ] **T20.17** — Cross-section rules: start function, element/data offsets, limits, global initializers.
- [ ] **T20.18** — The corpus sweep with nothing pending, the smoke subset, `runtime/wasm/README.md`, close-out.

The boundaries that keep the in-repo runtime from becoming an in-repo language — the package edge, the spec data off the default test path, and the condition for the runtime leaving this repository — are in the plan file, with the surface pressure the runtime runs into and the sizes that make the list workable in spare sittings.

### Step 21 — Wasm runtime: interpreter core & spec-suite goldens (plan written at start)

## M7 — EmoOS

The kernel path, on the systems layer M6 lands. Near term: a unikernel
build path — the native backend already emits OCaml, and the
MirageOS/solo5 lineage proves that stack boots — with the `foreign
def` FFI as the machine escape hatch (ports, asm shims) and the
`core` library split from step 14's notes pulled for real. Far term:
freestanding codegen, the same investment a tiered wasm engine needs.
Step plans are written when the kernel work starts.
