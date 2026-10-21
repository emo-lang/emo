# Development Tasks

A numbered checklist of every implementation task, consolidated from
`plan/step-01-project-scaffold.md` onward.
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
| M1 — MVP interpreter | 01–08 | Single-file Emo programs (functions, classes, enums, exceptions) run via `emo run` / `emo repl` with readable errors. |
| M2 — Compile-time experience | 09–11 | Gradual type checker, structural module system, and packages with MVS resolution; multi-package projects build and run. |
| M3 — Concurrency & networking | 12–13 | Processes and message passing on an effects-based scheduler; direct-style networking. |
| M4 — Compilation targets | 14–19 | Native code generation via `emo build`; then Wasm / TypeScript / BEAM / RISC-V. |
| M5 — Wasm Runtime | 20–22 | A WebAssembly runtime written in Emo: the shared systems layer, then the binary decoder/validator, then the interpreter with spec-suite goldens. |
| M6 — Self-contained hosted backend | 23 | `emo build --target c`: emit C, Emo's own runtime, direct C ABI — the hosted-native-FFI assessment scheduled; unblocks self-contained tool distribution (CHECK.md). |
| M7 — Toolchain | 24 | The toolchain release: signed per-platform `emo` binaries on GitHub Releases (brew/opam as the source channels); a binary-only machine runs and builds Emo programs; `emo new` / `emo deps` / `emo doctor` complete the command set. |
| M8 — Target independence | 25 | Every target's runtime lives in the target's own ecosystem — embedded as generated data (c, ocaml, typescript) or inside the emitted module (wasm, beam) — never beside the binary or in the host build tree; the host contributes only the emitters. |
| M9 — For / While loops | 26–27 | The settled loop surface runs on the interpreter and all six targets byte-for-byte: `for` (three clauses, the header `var` scoped to the loop) and `while`, with bare `break`/`continue`; loops never grow any stack; guaranteed tail calls unchanged. |
| M10 — Error handling | 28–30 | The Erlang split lands: expected failures return `(R.ok, value)` / `(R.error, reason)` matched by `case` or assert-bound by pattern, violations raise the one `Exception` class, and the stdlib's raise sites migrate to the convention — every target byte-for-byte, `R` reaching the freestanding tier with them. |
| M11 — The standard library | 31–38 | The bundled stdlib packages — `json`, `yaml`, `xml`, `os`, `base64`, `slog`, `bufio`, and the native-binding `sqlite3` — each resolving against the manifest's `targets`, answering byte-for-byte on every target it declares, and shipping a full API reference plus a runnable golden. |
| M12 — Visualization (`plot`) | 39–45 | The `plot` package fills its T0 surface (continuous axes; line / scatter / area / histogram marks; log scales, domains, legends, grid, themes, palettes, faceting) and the T1 dataset charts, then adds terminal and PNG renderers — SVG output byte-identical on all five hosted targets. |
| M13 — Unit testing | 46 | `emo test` discovers the project's `test/` directory and runs every top-level `def test_*` with per-test isolation, reporting, and the exit-code family; the `expect_*` assertion builtins raise the one `Exception` class on failure (interpreter; compiled targets refuse honestly); scaffold, example, tests, and docs land together. |
| M14 — CSV read/write | 47 | The bundled `csv` package — RFC 4180 records, UTF-8 only — resolving like any stdlib package, answering byte-for-byte on all five targets, with the API reference and runnable goldens. |
| M15 — EmoUI | 48 | One declarative EmoUI tree renders on a terminal, a server-rendered page, a macOS/AppKit window, and a GTK 4 window (the browser DOM following its runtime path), each behind a thin per-platform entry; the shared app module is portable Emo, the composition syntax is identical everywhere, and per-platform component libraries share convergent names. The EmoUI packages live in this repository under `projects/emo-ui/`, and the compiler-side gates and the terminal-input package land in the tree (`CHECK.md`, the in-tree project layout). |
| M16 — Value-family reclamation | 49 | The `c` target reclaims the value-semantic kinds, not only the identity cells: a long-running program's arena bytes and identity liveness stay flat across renders instead of rising per event, array growth is linear rather than quadratic, and every existing golden on every target stays byte-identical (`spike/arena-scope`, `CHECK.md`). |
| M17 — Cross-target conformance | 50 | Conformance to promises already made, not new design: a spawned `c`-target process that raises dies alone, `send` delivers a snapshot, and `foreign def` refuses by name on `wasm` and `beam`; every existing golden on every target stays byte-identical (`CHECK.md`). |
| M18 — TLS on the `c` target | 51 | The three existing `net` TLS builtins run on the default target: the C runtime lands them against the system OpenSSL/LibreSSL behind hand-declared prototypes and IR-keyed conditional linkage (a non-TLS build never links OpenSSL), the ocaml scheduler's semantics and reason conventions hold, and `http`'s `https://` works end-to-end on `c` (`CHECK.md`). |
| M19 — Map on `wasm` and `beam` | 52 | The last two hosted targets implement the `Map` builtin through their existing mutable-kind mechanisms — insertion order, the six key kinds, structural `==`, and the `{key: value}` rendering byte-identical with the four targets that have it — `send` delivers a snapshot on `wasm` (the recorded remainder the new mutability makes reachable), `slog` widens to the two targets, `Exception.new(data:)` carries crash context everywhere but `riscv64`, and the `plot` package's Map-shaped `Table` and channels (Step 42) unblock (`CHECK.md`). |

## Design gates

Open decisions tracked in `CHECK.md` that gate tasks below. Settle them
before starting the gated work:

| Decision | Gates | Provisional until settled |
| --- | --- | --- |
| CLI command names | T01.3, T08.1–T08.2 | settled in M1 — `run` / `repl` / `check` / `version` shipped |
| String escape rules | T02.3, T02.4 | Minimal set `\n \t \\ \' \"` |
| Self-pid mechanism | T12.1 | settled — `self_pid()` builtin, `Pid` type rendering as `<pid N>`, `halt()`; no user-facing kill/wait |
| Error-handling model (was: exception catch syntax) | T13.5, M10 | settled 2026-10-11 — no catch; `(R.ok, value)` / `(R.error, reason)` tuples plus the one `Exception` class (`CHECK.md`); Steps 28–29 land it |
| Manifest / lockfile names, scope-prefix format, version ranges, deps CLI names | T11.2, T11.5–T11.6, T11.8–T11.9 | `package.emo`, `package.lock`, `owner/name`, exact pins only, `emo deps *`; a deps key is a string literal (T11.9) |
| C FFI binding-surface syntax | T14.6 | settled — `foreign def name(params) Ret = "c_symbol"`, `Float`/`String`/`Bool` only, through generated C wrappers |
| Reclamation model for the dynamic world (no tracing GC) | T23.5 | settled — reference counting for identity objects, arena for value-semantic data (`CHECK.md`, at T23.5) |
| `emo build` default target | T24.1 | flip `ocaml` → `c`: a distributed binary carries no OCaml toolchain; the `ocaml` target stays for source installs |
| Stdlib: embed vs sidecar tree | T24.2 | embed as generated data inside the compiler (the C runtime's mechanism); `EMO_REGISTRY` override stays |
| `emo install` semantics | T24.4 | settled then superseded 2026-10-17 — the command was removed; `emo deps` and the build path own resolve/fetch/lock, and installing global executables stays out of scope for 1.0 |
| The runtime-independence principle | T25.1 | a target's runtime is written in the target's language, carried as generated data inside the compiler; the host contributes only the emitter |
| The ocaml runtime's dependency policy | T25.4 | the OCaml standard library plus `unix` for the core; `ssl` as the one opam dep, refused with a clear message when absent; no eio |
| EmoUI native UI packaging (per-package native fields) | T48.7–T48.9 | settled 2026-10-14 — the manifest grows per-package native fields; a native backend does not ship an app-level build script (`CHECK.md`, `docs/emo-ui.md`). **Landed 2026-10-18 (T48.7)**: `pkg_config` (bare modules; `--cflags` compile, `--libs` link), `frameworks` (bare names; `-framework NAME`), and `.m` collected beside `.c`/`.h` and compiled under ARC |
| `c` target long-running memory (value-family reclamation) | T48.8–T48.9 (demo scale), step 49 | settled 2026-10-14 — region reclamation is not viable; the value families need refcounting, scheduled as step 49 (`CHECK.md`, `spike/arena-scope/`). **Landed 2026-10-17 (T49.1–T49.4)**: the working set is flat and the demo-scale note is retired |
| EmoUI browser runtime path | T48.10–T48.11 | settled 2026-10-15 — the split route: a browser-safe subset of the TypeScript runtime, a `dom_*` family, and a bundling step, rather than new wasm host imports (`CHECK.md`, `docs/emo-ui.md`). **Landed 2026-10-18 (T48.10–T48.11)**: the bundling step is a build target (`emo build --target browser`), the split is a host-free core plus Node and page hosts, the `dom_*` family is thirteen calls over Int64 handles, and `emo/ui_browser` is the DOM backend over them, with the convergence corpus running in a stub page |
| Cross-target conformance (`c` raise, `c` send, `foreign def` on `wasm`/`beam`) | step 50 | settled 2026-10-15 — conformance to promises already made, not new design: a child's raise ends only that child, `send` snapshots, and the two emitters refuse `foreign def` by name (`CHECK.md`). Refined by T39.3: the declaration is inert off the native targets, and the refusal is at the call. The `typescript` target's share-on-send stays open |
| Array growth (O(1) append vs a builder) | T48.1, T49.4 | settled 2026-10-15 (T49.3) — a builder, as a new language-level `ArrayBuilder` type rather than an `Array` representation change (`CHECK.md`, `docs/intro/syntax.md`); the `List` → `Array` conversion half is deliberately not taken |
| The in-tree project layout (`projects/`) | all of M15 | settled 2026-10-15 — `projects/<repo-name>/` at the repository root holds each named Emo project (EmoUI, EmoOS, EmoShell), named for the repository it can later be split out into; EmoUI stays not a standard-library package (`CHECK.md`) |
| Terminal input's placement (T48.5) | T48.5 | settled 2026-10-15 — raw mode is a standard-library package in the `sqlite3` shape (package-carried `.c`/`.h` reached through `foreign def`, gated by `targets`), not a UI-framework or compiler-side artifact (`CHECK.md`, `docs/emo-ui.md`) |
| TLS on the `c` target (linkage detection, prototypes, Windows) | step 51 | settled 2026-10-17 — the three `net` TLS builtins land in the C runtime against the system OpenSSL/LibreSSL: the `c` emitter's IR walk gates `EMO_HAS_TLS` + `-lssl -lcrypto`, the prototypes are hand-declared (no OpenSSL headers anywhere), the floor is the API subset (OpenSSL ≥ 1.1.1 / LibreSSL ≥ 3.5.0), and Windows stays refused (`CHECK.md`, `plan/step-51-tls-c-target.md`) |

---

## M1 — MVP interpreter

### Step 01 — Project scaffold & CLI skeleton · `plan/step-01-project-scaffold.md`

**Prereq:** none.
**Done when:** `dune build` and `dune test` pass from a clean checkout; `emo version` prints `emo 0.0.1`; placeholder subcommands exit non-zero; CI green on Linux and macOS.

- [x] **T01.1** — Create `dune-project` and the `src/` library skeletons (`emo_support`, `emo_lexer`, `emo_parser`, `emo_ast`, `emo_eval`, `emo_check`, `emo_cli`) with placeholder modules that compile.
- [x] **T01.2** — Implement `emo_support`: span, severity, diagnostic, renderer; unit tests for the renderer.
- [x] **T01.3** — Implement `emo_cli` with cmdliner; wire the four subcommands to placeholder actions.
- [x] **T01.4** — Add alcotest smoke tests per library and the CI workflow (setup-ocaml, `dune build`, `dune test`, Linux + macOS).
- [x] **T01.5** — Add `.ocamlformat` (conventional profile); format the tree once (`dune build @fmt` passes).

### Step 02 — Lexer · `plan/step-02-lexer.md`

**Prereq:** Step 01.
**Done when:** suites cover every token kind, interpolation nesting (`"a ${ "b ${x}" } c"`), position fidelity on multi-line input, and every error case; `dune test` green.

- [x] **T02.1** — Token type + positioned token stream in `emo_lexer`.
- [x] **T02.2** — Identifier classes (`LOWER_IDENT` / `UPPER_IDENT`), keywords, operators.
- [x] **T02.3** — Numeric and char literals with escape handling.
- [x] **T02.4** — Interpolated-string token scheme with nesting tests.
- [x] **T02.5** — Newline-preserving stream API.
- [x] **T02.6** — Error cases: each rejects with correct line:col via `emo_support`.

### Step 03 — Parser: expressions · `plan/step-03-parser-expressions.md`

**Prereq:** Step 02.
**Done when:** every expression snippet in the README parses to the expected AST (golden tests); precedence pinned (`1 + 2 * 3`, `a && b || !c`, `x.foo(1)[i].bar?()`); `dune test` green.

- [x] **T03.1** — `emo_ast` expression/statement types with spans on every node.
- [x] **T03.2** — Pratt-style expression parser with the precedence table.
- [x] **T03.3** — Call parsing: positional + named args, trailing-block sugar.
- [x] **T03.4** — Arrow blocks; `if` / `else` (single shape, no chaining).
- [x] **T03.5** — Newline-termination rules with depth tracking.
- [x] **T03.6** — Interpolated-string reassembly from lexer parts.
- [x] **T03.7** — Parser tests: precedence table, dangling-operator continuations, malformed input errors.

Scope note: tuple literals under the content rule, tuple patterns, `case` / `receive` / `do` / send syntax all parse within this step (semantics stay "not yet" errors until steps 05 / 11).

### Step 04 — Parser: declarations · `plan/step-04-parser-declarations.md`

**Prereq:** Step 03.
**Done when:** the README's `User`, `Greeter` / `English`, `welcome`, and `Color` snippets parse to golden ASTs; negative tests (camelCase `def`, `UPPER` variable, enum payloads, duplicate `init`, a declared `init` return type) rejected with the right message and span; `dune test` green.

- [x] **T04.1** — Declaration AST nodes; top-level item sequence.
- [x] **T04.2** — `def` parsing with the `init` exemption and `?`-name rules.
- [x] **T04.3** — `class` (single-`init` rule, field collection from `self.x =`).
- [x] **T04.4** — `interface` signature-only bodies.
- [x] **T04.5** — `enum` member lists.
- [x] **T04.6** — `raise` statement.
- [x] **T04.7** — Naming-convention checks with spans; multi-error resync.
- [x] **T04.8** — Golden tests: README examples parse cleanly; convention violations produce the expected errors.

### Step 05 — Interpreter: core values & evaluation · `plan/step-05-interpreter-core.md`

**Prereq:** Step 04.
**Done when:** the acceptance program runs (`fib(20)` → 6765, interpolated greeting, `count_down(1000000)` with a flat stack); `dune test` green including the deep-recursion case.

- [x] **T05.1** — Value ADT + equality; environment chain.
- [x] **T05.2** — Expression evaluation with tag-checked operators.
- [x] **T05.3** — Interpolation; `print` builtin; `.to_string()`.
- [x] **T05.4** — Closure capture (lexical, by reference to the environment).
- [x] **T05.5** — Tail-call loop in the evaluator; deep-recursion test.
- [x] **T05.6** — `if` / `return` semantics; runtime type errors with spans.
- [x] **T05.7** — Alcotest suites running real programs end to end (assert on captured stdout).

Scope note: arrays, tuples, and `Box` (with its three-operation set) are part of this step's value model. `print` is a provisional name — promote it into the README once the I/O surface settles.

### Step 06 — Interpreter: classes, enums, interfaces · `plan/step-06-interpreter-objects.md`

**Prereq:** Step 05.
**Done when:** the README's object examples run verbatim (value-semantic `User`, `Color`, duck-typed `welcome`, structural `is()`); negative tests (`self.x =` outside `init`, missing method, uncaught raise) error as specified; `dune test` green.

- [x] **T06.1** — `ClassDef` / `Instance` values; `init` window flag; field freeze.
- [x] **T06.2** — Method dispatch + `self`; `NoMethodError`.
- [x] **T06.3** — Deep `==` on instances; shared-structure immutability tests.
- [x] **T06.4** — Enum singletons; `TypeValue`; `is()` with structural interface check.
- [x] **T06.5** — `raise`; builtin `Exception`; uncaught-exception termination.
- [x] **T06.6** — `.to_string()` for instances, enums, exceptions.

### Step 07 — Function groups (`emo` keyword) · `plan/step-07-function-group.md`

**Prereq:** Steps 01–06.
**Done when:** `emo Foo { def ... const ... }` declares a function group, `Foo.hello()` / `Config.version` resolve and run on the interpreter and all four backends (goldens in CI), and the README documents the syntax.

- [x] **T07.1** — Parser (`emo` keyword + group items), checker (group symbols, name/arity rules), IR lowering to mangled functions; `examples/function_group/` golden through `emo run`.
- [x] **T07.2** — TypeScript, wasm, and beam goldens for the example; README (English + zh-CN) documents the syntax.

Close-out: groups lower to mangled functions with double-keyed symbols (group-qualified and module-bare), so every backend got them without backend code. The showcase example (processes across files on all four targets) landed with the TS process support; the manifest-path bug it exposed (an entry lowered twice under a relative path) is fixed in `emo_project`. Decisions are in `plan/step-07-function-group.md` (Close-out). **Step 07 acceptance met.**

### Step 08 — CLI & diagnostics · `plan/step-08-cli-diagnostics.md`

**Prereq:** Steps 01–07.
**Done when:** every `examples/*.emo` runs with expected output in CI; a file with three parse errors reports all three at correct line:col, stable under `--no-color`; the REPL runs the step 06 acceptance block interactively. **M1 exit criteria met.**

- [x] **T08.1** — `run` command with stage pipeline and exit codes (lex/parse 65, eval 70, uncaught exception 1).
- [x] **T08.2** — REPL: multi-line reading, persistent environment, value echo.
- [x] **T08.3** — Diagnostic renderer completion (excerpts, codes, hints, colors, error limit); unit tests over golden renderings.
- [x] **T08.4** — Uncaught-exception trace plumbing in the evaluator.
- [x] **T08.5** — `examples/` golden tests wired into CI.
- [x] **T08.6** — Manual pass: run each example, use the REPL interactively.

Close-out note: promote the provisional decisions that M1 proved (`print`, trailing-block sugar) into the README.

---

## M2 — Compile-time experience

### Step 09 — Gradual type checker · `plan/step-09-type-checker.md`

**Prereq:** Steps 01–08.
**Done when:** every README example type-checks clean; the wrong-type-declaration corpus (wrong return type), bad named arg, `var` escape, narrowing misuse) is rejected with correct spans; the zero-false-positive corpus passes with no diagnostics; `emo check` works and `emo run` runs the pass first.

- [x] **T09.1** — Type representation + type declaration collection pass.
- [x] **T09.2** — Statement/expression checking with `Unknown` discipline.
- [x] **T09.3** — Signature checks; arrow-block inference.
- [x] **T09.4** — Branch-scoped environments with narrowing on `is()`.
- [x] **T09.5** — Structural interface conformance.
- [x] **T09.6** — `var`-escape detection.
- [x] **T09.7** — Call-site checking; named-argument validation.
- [x] **T09.8** — `case` checking: pattern typing, `when` guards as `Bool`, exhaustiveness on decidable enums and on the first tuple element of decidable `(Enum, ...)` scrutinees (guarded branches don't count).
- [x] **T09.9** — `emo check` command; wire into `emo run`.
- [x] **T09.10** — Test categories: strict type-declaration rejections, inference successes, zero-false-positive corpus.

Follow-up: the chosen `var`-escape approximation is documented in `docs/var-escape.md`.

### Step 10 — Structural module system · `plan/step-10-modules.md`

**Prereq:** Steps 01–09.
**Done when:** the README's `shop/` tree works verbatim (path-as-module, aliasing via `const`); referencing `shop.internal.discounts` from outside `shop` errors naming both modules; a two-module cycle is rejected with the full chain; multi-file fixtures green.

- [x] **T10.1** — Module path resolution (file ↔ module name; collisions are errors).
- [x] **T10.2** — Lazy `Module` values wired into the evaluator's member access.
- [x] **T10.3** — Load-order orchestration; load-once semantics.
- [x] **T10.4** — Reference-graph extraction during checking.
- [x] **T10.5** — `internal/` subtree-privacy check.
- [x] **T10.6** — Cycle detection with chain reporting.
- [x] **T10.7** — In-process caching keyed by content hash.
- [x] **T10.8** — Multi-file test project under `examples/` mirroring the README's `shop/` tree.

Caution: resolved in step 11 — a project roots at the working directory, which
must hold `package.emo` (T11.10); no ancestor is ever consulted.

### Step 11 — Packages & version resolution · `plan/step-11-packages.md`

**Prereq:** Steps 01–10.
**Done when:** the README's `require "acme/json_tools"` scenario runs against a fixture registry; removing a dep from `deps` while its `require` remains is a compile error; conflicting exact pins resolve to the highest and the lockfile checksums verify on a second run; a dep whose `targets` exclude the current target fails at resolution time. **M2 exit criteria met.**

- [x] **T11.1** — `require` parsing + scope rules.
- [x] **T11.2** — Manifest phase A: strict schema parser, errors with spans.
- [x] **T11.3** — Strict require/deps pairing check.
- [x] **T11.4** — MVS resolver with target-compatibility gate; unit tests over version lattices.
- [x] **T11.5** — Lockfile read/write/verify; mismatch errors.
- [x] **T11.6** — Registry client + content-addressed cache + directory registry for tests.
- [x] **T11.7** — Manifest phase B: restricted-profile evaluation with step budget.
- [x] **T11.8** — End-to-end fixture: two local packages, one requiring the other, resolved, locked, built, run.
- [x] **T11.9** — A `deps` key is a string literal: the deps block's one
      spelling, so a package name is never something the lexer must
      accept. **Landed 2026-10-15** across the parser, the manifest
      evaluator and `emo_pkg`. A manifest parses in its own profile
      (`parse_program_in ~manifest:true`, whose only caller is
      `Emo_pkg.parse_manifest`), where a string assignment target is a
      dependency's name and an identifier target stays a package field;
      the `a / b` fold that turned a scoped name into an `Ident` is
      deleted, along with the now-unreachable `E4015` scoped-name check
      it fed. A string-keyed field is `E5102`, so a mistyped field can no
      longer be silently dropped, an empty dependency name is `E5102`,
      and a stray statement inside `deps` is `E5104`. Reason: `emo` is a
      reserved word, so this repository's own
      packages could not pin their scope as `emo/ui` — and a name is
      already data everywhere else (the `name` field, `require`, the
      lockfile, the registry), which left the key as the single place it
      masqueraded as code. 29 manifests migrated (`examples/**`,
      `benchmarks/http_echo`, five stdlib packages, the emo-ui golden),
      every committed lockfile re-resolved, and `projects/emo-ui/` now
      names its package `emo/ui`. The same day, `emo check <FILE>` learned
      the rule the editor already applied: a `package.emo` is read as a
      manifest rather than as a module, so the two agree on what a
      manifest says (`Emo_pkg.is_manifest_file` is where the rule lives),
      and the token-level phase-A manifest helpers that T11.7 superseded
      are gone. `emo run` and `emo build` refuse a manifest named as the
      entry (66) instead of reading it as a program — a manifest is data
      wherever it is read, and a command that needs a program says which
      module to name.

- [x] **T11.10** — The root is where you stand: a project is the working
      directory, which must hold `package.emo`. **Landed 2026-10-16.** The
      nearest-manifest search above the entry file is deleted — the rule
      settled that day is cwd-only, so a missing `./package.emo` is **E5010**
      (``run `emo new <name>` to scaffold a project here``, spanned on the
      directory) and an entry that is not a module of the package rooted
      there is **E5011** (spanned on the entry), both through
      `Static_errors` → 65. Reason: the old search let a manifest-less tree
      silently become a project rooted at cwd — `emo check
      examples/alias_demo/main.emo` from the repository root checked the
      whole repository and reported other examples' errors — and let the
      same file mean different things depending on where the command was
      typed. Every runnable tree that lacked a manifest got one (16
      `examples/`, 7 `benchmarks/`, 6 `spike/`, the release workflow's smoke
      project), and every test invocation now stands in the directory it
      roots at. The LSP tightened the same way: it indexes a project only
      when the root it was handed holds `package.emo`, says so once per
      workspace, and `scan` skips a nested package the way the compiler's
      walk does. Also here: a foreign parameter's contract is now looked up
      under its qualified name, so `foreign def` on a type declared in the
      entry module resolves on the `c` target — a latent bug the standalone
      entry build had hidden.

Also here: swap step 10's transitional root rule for manifest-based roots — done; the root is the working directory, and it must hold `package.emo`.

---

## M3 — Concurrency & networking

### Step 12 — Processes & message passing · `plan/step-12-concurrency.md`

**Prereq:** Steps 01–11.
**Done when:** ping-pong (1M messages) and fan-out/fan-in (1000 workers) run correctly under both the Eio-based and own effects schedulers; a process that raises mid-message dies alone while the parent continues; sending a `Box` yields a snapshot; receive loops recursing millions of times keep the native stack flat; `dune test` green under the deterministic scheduler.

- [x] **T12.1** — Design pass: settle the self-pid mechanism in `CHECK.md` / README (`do`, `<-`, `receive { ... }`, and the `Box` operation set are already decided). Blocking gate for the rest of the step.
- [x] **T12.2** — Process/mailbox abstraction on Eio; spawn/send/receive.
- [x] **T12.3** — Crash isolation; process-exit signals for future supervisors.
- [x] **T12.4** — `Box` with snapshot-on-send semantics.
- [x] **T12.5** — Deterministic scheduler log for tests.
- [x] **T12.6** — Phase B: own effects-based scheduler beneath the same interface.
- [x] **T12.7** — Stress tests: ping-pong, fan-out/fan-in, deep receive-loop recursion.

### Step 13 — Networking library · `plan/step-13-networking.md`

**Prereq:** Steps 01–12.
**Done when:** an Emo HTTP server + client round-trip on localhost runs in one `emo run` program, entirely direct style; a timeout and a refused connection each raise an Emo exception with a precise message; a TLS handshake to a test certificate fails closed on verification error. **M3 exit criteria met.**

- [x] **T13.1** — TCP socket surface on the scheduler; graceful close semantics.
- [x] **T13.2** — UDP + Unix-domain sockets.
- [x] **T13.3** — DNS resolution through the same suspension path.
- [x] **T13.4** — OpenSSL TLS binding; certificate-verification errors surfaced as Emo exceptions.
- [x] **T13.5** — HTTP client; HTTP server with process-per-connection helper.
- [x] **T13.6** — Stdlib packaging with target metadata; fixture-based integration tests (loopback listeners, deterministic order).

Close-out: the exact `net.*` / `http.*` names are in the README (Networking); the stdlib ships as directory-registry packages under `stdlib/registry` with `targets = ["ocaml"]` at the time; the acceptance example is `examples/http_roundtrip`. Step decisions are in `plan/step-13-networking.md` (Close-out). **M3 exit criteria met.**

---

## M4 — Compilation targets

### Step 14 — Native backend · `plan/step-14-native-backend.md`

**Prereq:** Steps 01–13.
**Done when:** every `examples/*.emo` compiles to a native binary producing output identical to `emo run` (golden comparison in CI); specialized numeric code shows measurably better benchmark numbers than the unspecialized build; a process-per-connection HTTP server built with `emo build` sustains a load test; benchmark results recorded.

- [x] **T14.1** — IR definition + checked-AST lowering.
- [x] **T14.2** — Stage A: OCaml emission, runtime linking, single-binary output.
- [x] **T14.3** — `emo build` with incremental caching.
- [x] **T14.4** — Benchmark set wired into CI (numbers recorded, not just pass/fail).
- [x] **T14.5** — Stage B: type-driven specialization passes (unboxing, direct dispatch) behind completeness checks from step 09 data.
- [x] **T14.6** — C FFI linking path once the binding-surface syntax is decided (blocked — settle in `CHECK.md` first).
- [x] **T14.7** — Bootstrap test: the `examples/` suite as compiled binaries matches interpreter output byte-for-byte.

Close-out: Stage A emits OCaml source (tradeoff documented in `docs/ocaml-backend.md`); the IR lives in `src/emo_ir` with the Stage B `specialize` fixed point, and T14.5's specialization landed with the T14.1/T14.2 commits. `foreign def` settled as above, marshaling through generated C wrappers (`emo build` compiles them with `cc`); `Float`/`String`/`Bool` cross the boundary, everything else refuses with E4200. Benchmarks: `benchmarks/results.md` records fib(30) 345ms unspecialized vs 212ms specialized (~1.6x), ping-pong, JSON scan, and an HTTP echo load test at 112 req/s. Bootstrap: all five examples build to binaries matching `emo run` byte-for-byte (the `bootstrap` suite in `test/emo_project`). Decisions are in `plan/step-14-native-backend.md` (Close-out). **Step 14 acceptance met.**

### Step 15 — Other targets: Wasm, TypeScript, BEAM, RISC-V · `plan/step-15-other-targets.md`

**Prereq:** Steps 01–14 (per target). These began as roadmap entries, not execution-ready plans; all four are now promoted to their own step files — TypeScript first (the lowest toolchain risk, 2026-10-02), then Wasm, BEAM, and riscv64.

- [x] **T15.1** — When a target is scheduled, split it into `step-NN-<target>.md` with the full standard format (goal / scope / tasks / acceptance) and update `plan/README.md`'s status table; its tasks continue the numbering (`T17.*`, …).
- [x] **T15.2** — Record which key decision each target settled and where (README / `CHECK.md` / docs) — keep the trail. (Done 2026-10-17: the promotion trail below now covers all four targets and points at each step file's "Decisions settled here" section plus the cross-cutting `README.md` / `CHECK.md` / `docs/numeric-width.md` records.)

Key decisions each target settled: Wasm — **WasmGC** (structs and arrays with RTT dispatch, no custom heap; the custom-GC branch removed) and Int boxing an i64; TypeScript — lowering from the IR, a uniform `async`/`await` mapping with no coloring analysis, and cooperative tasks rather than workers; BEAM — class instances as tagged maps (map equality is Emo's content equality), Core Erlang text assembled by `erlc`, and processes mapped natively; riscv64 — boot profile A, tagged-word dynamic values with boxed `Int64`/`Float64`, the psABI as Emo's internal convention, and a whole-program single artifact.

Promotion trail: **TypeScript → `plan/step-17-typescript.md`** (2026-10-02, first target; its key decisions — IR lowering, uniform async, cooperative tasks, Node networking — are settled in that file). **Wasm → `plan/step-16-wasm.md`** (2026-10-02, second target; GC settled as WasmGC, structs and arrays with RTT dispatch, no custom heap; T16.5's WASI/IO audit closed in favor of refusing `net`/`http` — no usable socket path on the reference host). **BEAM → `plan/step-18-beam.md`** (Core Erlang emission, the value model, native process mapping; net/http and FFI explicitly out). **riscv64 → `plan/step-19-riscv64.md`** (2026-10-05, last; per-task decision trails, close-out recorded, the `%g` float to-string follow-up landed 2026-10-17). Full pointers, including `CHECK.md`'s cross-target entries, are in `plan/step-15-other-targets.md`.

### Step 16 — Wasm target (WasmGC) · `plan/step-16-wasm.md`

**Prereq:** Steps 01–15.
**Done when:** `emo build --target wasm` produces a `.wasm` (plus its `.wat` sibling) that runs on Node's WasmGC, the core subset (hello_world, fib, objects, language_tour, shop) prints byte-for-byte what `emo run` prints (golden in CI), and a package lacking the target fails resolution before any emission.

- [x] **T16.1** — Backend skeleton: `--target wasm` plumbing (resolution gate reads the target); the WAT intermediate; the binary encoder; the boxed-struct value model with RTT dispatch. Golden: hello_world, fib, objects.
- [x] **T16.2** — Full core semantics: patterns and guards, tuples, arrays, Box, interpolation, content equality, interface narrowing, multi-file module references. Golden: language_tour, shop.
- [x] **T16.3** — Bootstrap: the wasm subset in CI, plus the resolution-gate refusal test for packages lacking `"wasm"`.
- [x] **T16.4** — Concurrency: a cooperative driver for `do` / `<-` / `receive`, host-timer preemption points. Golden: pipeline. (Gated on T16.2.)
- [x] **T16.5** — The WASI and IO audit: stdlib metadata for `"wasm"`, and the io goldens where the host supports it. (Done 2026-10-17: the host supports neither network golden. Node's preview1 WASI has no usable socket calls, and the working socket API — preview2's `wasi:sockets` — is component-model-shaped, unreachable from this core WasmGC module; wasmtime's preview1 answers the legacy call `notsock`. `net`/`http` stay undeclared and refuse at resolution; the pure stdlib packages already declare `"wasm"` and run in the golden group, now pinned by resolution tests on both sides.)

**Step 16 acceptance met.** `emo build --target wasm` emits a `.wasm` plus its `.wat` sibling that runs under Node's WasmGC; the core subset and the pure stdlib demos print byte-for-byte what `emo run` prints; packages lacking `"wasm"` fail resolution before emission. The WASI/IO audit closed with an honest refusal: no network goldens are possible on the reference host, and the IO packages' metadata says so.

### Step 17 — TypeScript target · `plan/step-17-typescript.md`

**Prereq:** Steps 01–16.
**Done when:** `emo build --target typescript` emits TypeScript that runs on Node, the examples subset (hello_world, fib, objects, language_tour, shop, pipeline, tcp_echo, http_roundtrip) prints byte-for-byte what `emo run` prints (golden in CI), and a package lacking the target fails resolution before emission.

- [x] **T17.1** — Target plumbing and core emitter: `--target` through CLI, project, and the resolution gate; the IR → TypeScript emitter for the core subset; the tagged-value runtime. Golden: hello_world, fib, objects.
- [x] **T17.2** — Full core semantics: patterns and guards, tuples, arrays, Box, interpolation, content equality, multi-file module references. Golden: language_tour, shop. (Done 2026-10-17: both examples join `ts_golden_tests` and declare `"typescript"` in their manifests. The emitter already handled the surface — the gap was the pin, so no backend change.)
- [x] **T17.3** — Concurrency: cooperative tasks, mailboxes, selective receive, `self_pid`, `halt`. Golden: pipeline.
- [x] **T17.4** — Direct-style IO: sockets and HTTP over Node's APIs as awaited promises; stdlib target metadata gains `"typescript"`. Golden: tcp_echo, http_roundtrip. (Done 2026-10-12: the whole `net` surface rides `node:net`/`node:dgram`/`node:tls`/`node:dns` behind `E.builtin` with one persistent per-connection reader; the root process finishing releases the live handles so the loop drains, matching the native rule. `net` and `http` declare `"typescript"`; tcp_echo and http_roundtrip join the target's goldens. The `c` target stays TCP-only, and the `http` server block's double close — hidden by the native scheduler, surfaced by the TypeScript target — is fixed.)
- [x] **T17.5** — Bootstrap: the target-aware golden suite in CI, plus the resolution-gate test for packages lacking the target. (Done 2026-10-17: `pipeline` joins the `ts_golden` group, completing the subset above; the gate now has a refusing and an accepting test, mirroring the `wasm` pair.)

Close-out: the target-aware golden group (`ts_golden`) pins the subset named above — 25 examples — and the resolution gate is tested both ways. Decisions are in `plan/step-17-typescript.md` (the trail). **Step 17 acceptance met.**

### Step 18 — BEAM target (Core Erlang) · `plan/step-18-beam.md`

**Prereq:** Steps 01–17.
**Done when:** `emo build --target beam` emits Core Erlang text that `erlc` assembles to a `.beam`, and the core subset (hello_world, fib, objects, language_tour, shop, pipeline) prints byte-for-byte what `emo run` prints (golden in CI), with the resolution gate reading `"beam"`.

- [x] **T18.1** — Backend skeleton: `--target beam` plumbing; the Core Erlang emitter (module, defs, literals, call/apply, sequencing) against the probed OTP 29 grammar. Golden: hello_world.
- [x] **T18.2** — The value model and arithmetic: masked i64 wrap-around Int64, binary Strings with interpolation, tuples, arrays, enums, deep content equality. Golden: fib.
- [x] **T18.3** — Classes/instances (tagged maps), Box holding processes, closures as funs, case patterns with guards. Golden: objects, language_tour.
- [x] **T18.4** — Processes (`do` / `<-` / `receive` via the compiler's receive primops), shop multi-module, pipeline golden; the CI `beam_examples` group and the resolution-gate test for `"beam"`.

### Step 19 — RISC-V target (freestanding RV64) · `plan/step-19-riscv64.md`

**Prereq:** Steps 01–14 (the specialization pass); the step-15 RISC-V
reference note is the design record.
**Done when:** `emo build --target riscv64` produces a freestanding ELF
that boots under `qemu-system-riscv64 -machine virt`; every example in
the core subset prints exactly what `emo run` prints (goldens in CI);
`spawn`/`send`/`receive` and `foreign def` refuse with clear
diagnostics; packages without `"riscv64"` fail resolution; `dune test`
green.

- [x] **T19.1** — The backend skeleton: `--target riscv64` plumbing
      (emitter module; the CLI arm writing `main.s`, invoking
      `as`/`ld` with the generated linker script; `emo run` booting the
      ELF under QEMU); the entry stub, BSS clear, SBI console.
      Golden: hello_world (serial output byte-for-byte vs `emo run`).
- [x] **T19.2** — The value model and arithmetic: the tagged-word
      dynamic representation (`Int64`/`Float64` boxed cells, Bool/Char
      immediates) and the bump allocator; wrap-around arithmetic,
      comparisons, `if`, integer formatting (`INT64_MIN` correct);
      guaranteed tail calls as `tail`. Golden: fib.
- [x] **T19.3** — Dynamic-world data structures: tuples, arrays, Box,
      enums, instances with vtable dispatch, closures and first-class
      functions; patterns with guards; interpolation with the `%g`
      float rule. Goldens: objects, language_tour, floats.
- [x] **T19.4** — Bootstrap: the `riscv64_examples` CI group (QEMU +
      cross-binutils on the runner), the resolution-gate refusal test
      for packages lacking `"riscv64"`, the emission-time refusal
      diagnostics, close-out.

**Step 19 acceptance met.** The freestanding RV64 backend
ships — hello_world, fib, objects, language_tour, and floats boot
under QEMU as byte-for-byte goldens, the refusals are loud, and
resolution gates packages. The `%g` float to-string follow-up landed
2026-10-17 (plan/step-19 close-out).

## M5 — Wasm Runtime

The layer is a WebAssembly decoder, validator, and interpreter written
in Emo. It is designed once under a unification gate — a primitive
lands only when it names a concrete near-term need;
`plan/step-20-wasm-runtime.md` holds the project decisions, the
mechanism matrix, and the ladder.

### Step 20 — The systems layer (wasm runtime) · `plan/step-20-wasm-runtime.md`

**Prereq:** Steps 01–19.
**Done when:** `& | ^ << >> ~` work on integer types across the interpreter and all four backends; the `Bytes` core type with little-endian accessors exists; `file.read` loads a file from disk under the scheduler; `Int64` and `Byte` arithmetic wraps on all targets (goldens in CI); `runtime/wasm/` exists as a real package.

- [x] **T20.1** — Bitwise operators (`& | ^ << >> ~`) on integer types: lexer, parser, checker, interpreter, and all four backends; `examples/bit_ops/` golden through `emo run` and every target's CI group.
- [x] **T20.2** — The `Bytes` core type: construction, bounds-checked get/set, little-endian accessors, String interop; all four backends; golden example. (u64 accessors landed with Int64 in T20.4; printing a raw `Bytes` value on wasm shows the buffer's bytes instead of the `Bytes[n]` label — known gap.)
- [x] **T20.3** — `file.read` stdlib package (native, scheduler-direct); a golden example reading a file from disk. Ships `file.write` too (the demo writes its own data file, keeping the golden CWD-independent); the write closes before resuming so read-your-own-write holds; tests resolve the registry via EMO_REGISTRY.
- [x] **T20.4** — `Int64` and `Byte`: literals, wrap-around arithmetic, comparisons, explicit conversions; all four backends; golden example. `runtime/wasm/` package skeleton created here.

Close-out: `Int64` and `Byte` ride the integer representations each target already had — OCaml `int64`/`int`, Erlang integers masked to signed 64 bits, wasm's `$vint`, TS `BigInt`/`number` — so no backend grew a second value model; what each added was the wrap rule (Byte masks to 256 after add, sub, mul, shl, bnot) and the explicit conversions, and `examples/fixed_width/` runs on all four targets. The `Bytes` u64 accessors deferred by T20.2 landed here, since `Int64` is the carrier they needed, and the golden exercises them everywhere. Two backend notes: OTP 29's `erlc` cannot compile a float bit-string pattern, so `Float.from_bits` goes through `binary_to_term` on an ETF float header; and Emo prints floats by OCaml's `%g` rule, which neither Erlang's nor JavaScript's native formatting matches, so both the BEAM runtime and the wasm host implement it. The wasm golden flushed out two runtime bugs the earlier examples never reached: `bytes_from_mem` read linear memory at `i` instead of `ptr + i`, and `int_str` took its digits with signed division, which mangles `INT64_MIN`. Decisions are in `plan/step-20-wasm-runtime.md` (Close-out). **Step 20 acceptance met.**

### Step 21 — Wasm runtime: decoder & validator · `plan/step-21-wasm-decoder.md`

**Prereq:** Step 20.
**Done when:** `runtime/wasm/` decodes and validates the vendored spec suite's binary-form cases — every valid module accepted, every `assert_malformed` case rejected in the decode phase, every `assert_invalid` case in the validation phase; the default `dune test` runs a smoke subset through the Emo-written runtime, and the `wasm_spec` alias runs the full list with nothing pending.

- [x] **T21.1** — The smoke rule: `runtime/wasm/main.emo`, its golden, and a `runtest` rule that runs `emo run main.emo` in the sandbox. The package stops being inert; no registry and no native toolchain (deps are `{}`).
- [x] **T21.2** — The case-list format and its hex codec, the corpus runner, the `main.emo` / `spec.emo` drivers, and the `wasm_spec` alias. Both lists start empty; the summary reports `pending 0`.
- [x] **T21.3** — `devtools/vendor-wasm-spec` (a pinned wasm-spec checkout through `wast2json --no-check`) and the first corpus: `binary.wast`'s binary-form cases, vendored as `pending`. Independent of every decoder task.
- [x] **T21.4** — The diagnosed-failure value and the `Bytes` reader, bounds-checked before every access; the truncated-read fixtures.
- [x] **T21.5** — LEB128 (`u32`/`u64`/`s32`/`s64`) with the spec's length caps; `binary-leb128.wast` plus hand-written boundary vectors.
- [x] **T21.6** — The header and the section walk: magic, version, section id and size, ordering, custom sections, unknown ids, trailing bytes.
- [x] **T21.7** — The type section, and the tag-tuple / cons-list shape the rest of the module model copies.
- [x] **T21.8** — The declaration sections: function, table, memory, global, import, export.
- [x] **T21.9** — Element, data, and constant expressions.
- [x] **T21.10** — The opcode table and the numeric instructions.
- [x] **T21.11** — The parametric, variable, and memory instructions.
- [x] **T21.12** — The structured instructions: block/loop/if/else/end, br/br_if/br_table, and the matching-`end` bookkeeping.
- [x] **T21.13** — `decode(bytes)` on the package's surface, and the valid-module corpus.
- [x] **T21.14** — The validation context, the index spaces, and function typing.
- [x] **T21.15** — The operand type stack for the plain instructions.
- [x] **T21.16** — Control frames: label depths, branch operand types, and the polymorphic stack after a branch.
- [x] **T21.17** — Cross-section rules: start function, element/data offsets, limits, global initializers.
- [x] **T21.18** — The corpus sweep with nothing pending, the smoke subset, `runtime/wasm/README.md`, close-out.

Close-out: the sweep left nothing behind — `wasm_spec` reports 3456 claimed, 0 pending, 0 failed, and the smoke subset (forty cases, every decoder and validator family) rides the default `dune test`. Getting there flushed out bugs older than the validator: br_table's immediate never consumed its default index (present since T21.12 — the leaked byte parsed as an opcode and desynced whole bodies), and the final bulk-memory opcode numbering replaced the pre-merge proposal's. The validator's frame stack carries a logical top (rebuilding per pop was exponential on nested blocks) and pushes land only after truncating to the live prefix; block parameters live inside their frame (push_ctrl semantics), and unreachable frames keep pushed values concrete so `type-num-vs-num` cases still reject. One interpreter limit shaped the code: a method call on a recursive result (`f(n-1).append(x)`) spins past roughly 25 nesting levels, so every array-returning recursion is a tail-accumulator loop — recorded as language pressure. The datacount rule splits by phase: with a data section present, bulk-memory use without a datacount is malformed; without one, the validator's unknown-segment check makes it invalid — both pinned by the corpus. The declared-reference set (globals, exports, element segments — not the start function) types `ref.func`. **Step 21 acceptance met.**


The boundaries that keep the in-repo runtime from becoming an in-repo language — the package edge, the spec data off the default test path, and the condition for the runtime leaving this repository — are in the plan file, with the surface pressure the runtime runs into and the sizes that make the list workable in spare sittings.

### Step 22 — Wasm runtime: interpreter core & spec-suite goldens · `plan/step-22-wasm-interpreter.md`

**Prereq:** Step 21.
**Done when:** `runtime/wasm/` executes a validated module — instantiate (imports resolved through a register namespace and the `spectest` host module, segments laid out with the spec's trap-on-overflow, start run), invoke exports, and report values or the first trap. The `wasm_runs` alias runs the vendored run corpus (every `assert_return` bit-exact including NaN payload classes, every `assert_trap` and instantiation failure where the spec says) with nothing pending; the default `dune test` runs a smoke slice of both corpora.

- [x] **T22.1** — The run-list format and its codec (type-tagged bit-pattern words, NaN tokens, verdict prefixes), the run runner beside step 21's, the `runs.emo` driver, the `wasm_runs` dune rule, and `vendor-wasm-spec runs` writing the command corpus as all-`pending`. Independent of every execution task.
- [x] **T22.2** — The instance model: a validated module materialized as frozen records — functions as signature + body byte range, the index spaces, the segments, imports, exports, start, the declared reference set — with `wasm.load(bytes)` on the package surface returning module-or-verdict.
- [x] **T22.3** — The value model: i32/i64 as masked patterns, f32/f64 as bit patterns that convert to `Float64` only at an operation, references as tagged pairs; the NaN payload discipline and the comparison codec. Fixtures first — no execution yet.
- [x] **T22.4** — The integer families as pure functions: wrap-around arithmetic, shifts and rotates, clz/ctz/popcnt, division and remainder with their traps, sign extension, saturating truncation, wrap and extends. Boundary fixtures from the spec.
- [x] **T22.5** — The float families: arithmetic and comparisons through the bridge; conversions including truncation traps, promote/demote with correctly-rounded bit surgery (no `Float32` in the language), reinterpret as a pattern move. Conversion-boundary fixtures, NaN classes included.
- [x] **T22.6** — The store: linear memory on `Bytes` (page-granular grow, bounds before access, little-endian widths), tables with grow/size/fill/copy/init, mutable globals; traps as values. Fixtures at the OOB edges.
- [x] **T22.7** — The frame machine: the operand arena of u64 slots, locals and the variable instructions, structured control by recursion with branches as unwind signals, `call`/`call_indirect` with their traps, `return`, `unreachable`. A `fac` fixture proves the tail-call chain.
- [x] **T22.8** — Instantiation and linking: import resolution through the register namespace and host, global initializers, segment layout with trap-on-overflow (`assert_uninstantiable` fails here, store discarded), the start function, `register`. Link failures for missing or mismatched imports.
- [x] **T22.9** — The `spectest` host module: the print functions, typed globals, table, and memory behind the same import interface.
- [x] **T22.10** — Sweep I: the run families claimed in order — integers, floats, conversions, control flow, calls — each flip its own sitting; residuals stay pending.
- [x] **T22.11** — Sweep II: addressing and endianness, memory and table operations, segment initialization, linking through the register namespace, imports through spectest, the trap cases, and the leftovers — the run list ends at zero pending and zero failed.
- [x] **T22.12** — Close-out: the run-list smoke slice rides `dune test`, `runtime/wasm/README.md` grows the execution surface, acceptance recorded here and in `docs/TASKS.md` (both languages).

Close-out: the sweep ends at **25135 claimed, 0 pending, 0 failed** over the vendored run corpus — every `assert_return` bit-exact (NaN classes for the NaN tokens), every `assert_trap` and instantiation failure where the spec says, `register` and linking behaving — and the default `dune test` runs a smoke slice of both corpora. The gate produced one language addition, the float primitives `Float64.sqrt`/`floor`/`ceil`/`trunc`, `Float64.to_int64`, and `Int64.to_float64` (`CHECK.md`). The run driver is compiled: the evaluator is correct but cannot carry the loop-heavy memory tests past its recursion limit, and native compilation needed the boxed-`Int64` route plus module-level-`var` support, both landed here. **Step 22 acceptance met.**

The boundaries step 21 recorded bind unchanged (package edge, spec data off the default test path, the split condition), and the standing rule from step 21's sweep — no method call on a recursive result — is formal in the plan. The pressure notes (`Int32`/`Float32` masking, the growable-buffer arena, the recursion limit, argv) are the gate's raw material, not tasks.

## M6 — Self-contained hosted backend

The hosted half of the self-contained story: Emo's own runtime, the
C ABI as the FFI surface, and no OCaml toolchain in the produced
binary — once this ships, building Emo programs no longer requires an
OCaml toolchain either (CHECK.md, tool distribution). The hosted-native-FFI assessment
(`plan/hosted-native-ffi.md`) is this milestone's design record — an assessment, not a task-bearing step,
which is why no section appears in this file. Step 19's study
shares the tagged-word value model.

### Step 23 — C target (emit C) · `plan/step-23-c-target.md`

**Prereq:** Steps 01–14 (the IR); `plan/hosted-native-ffi.md` is the design record this step schedules.
**Done when:** `emo build --target c` emits C, compiles with the system `cc`, and links a standalone binary with no OCaml runtime; the golden subset (hello_world, fib, objects, language_tour, shop, pipeline, function_group, bit_ops, bytes, fixed_width, file_read) prints byte-for-byte what `emo run` prints (golden in CI); `foreign def` crosses the direct C ABI; a package lacking `"c"` fails resolution; `dune test` green.

- [x] **T23.1** — Design-gate closure (CHECK.md: route confirmed emit-C, trampoline settled, arena provisional) and the backend skeleton: the emitter module in `src/emo_codegen` + the `--target c` CLI arm invoking `cc`; entry stub, hosted startup, `println`; `"c"` enters `known_targets` with the resolution-gate refusal test. Golden: hello_world.
- [x] **T23.2** — Tail calls and the integer core: the trampoline (self/mutual tail calls, `return` as branch-to-epilogue — the fix for the current backend's ~4x loop regression); wrap-around `Int64` on `uint64_t`; comparisons, `if`, `INT64_MIN`-correct formatting. Goldens: fib; the 1M-deep `count_down` stays flat on the C stack; `loops_tail` recorded in `benchmarks/results.md` (4 ms — the OCaml backend's specialized build takes 1910 ms). The examples/fib golden itself waits on closures (T23.5) — its `greeting` needs them; the `c_integer` fixture covers fib, count_down, a mutual-tail cluster, and wrap-around, under a 1MB C stack. Also fixes the checker's span-type table (keyed by start offset alone, later checks overwrote nested expressions' types) and the wasm/beam backends' ClassType dispatch that the fix exposed.
- [x] **T23.3** — The scalar runtime: length-prefixed strings (NUL-terminated only at the FFI boundary), the `%g` float rule, `Bool`/`Char`, interpolation, scalar content equality. Goldens: numerics, if_expr. (Done 2026-10-06: if_expr is the first full-example golden; numerics itself waits on `foreign def` (T23.8) and tuples (T23.4) — the `c_scalar` fixture cross-checks the printing rules against the interpreter's own rendering instead. The string layout and the runtime-in-C decisions are recorded in CHECK.md.)
- [x] **T23.4** — The dynamic value model: step 19's tagged word (8-byte-aligned cells, 3 tag bits; `Int64`/`Float64` boxed two-word cells; no NaN-boxing), bump/arena allocator (provisional), tuples, value-semantic arrays, `Box`. Golden: objects. (Done 2026-10-06: the tagged word is live — one `emo_value` word, low bits 000/001/011 for pointer/Bool/Char, cell kinds in the header word — with bump allocation and malloc-leak documented in CHECK.md's provisional profile. Regime conversion (`emo_box_*`/`emo_unbox_*`) bridges native and dynamic code at every call, binding, return, and operator; dynamic `+`/comparisons/equality dispatch in the runtime per the interpreter's rules; `to_string` renders tuples `(a, b)`, arrays `[a, b]`, Box as `<box>`. The objects golden waits on classes (T23.5) — the `c_dynamic` fixture cross-checks the dynamic world against the interpreter's own rendering instead.)
- [x] **T23.5** — Classes, enums, interfaces, closures: instances with compile-time vtables, enum singletons, structural `is()`, patterns with guards; the reclamation decision lands in CHECK.md before this merges. Golden: language_tour. (Done 2026-10-06: language_tour AND objects both full-example goldens, byte-for-byte. Vtables carry method sigs with dynamic-convention thunks — class-typed receivers dispatch directly, interface/Unknown receivers through `emo_send`; `is()` compares vtable identity (classes) or shape (interfaces); closures take the canonical dynamic convention `[header][fn][captured...]` with creation-site capture analysis and direct dynamic returns; `case` lowers to sequential test/bind/guard blocks with goto-chained fall-through. The reclamation decision settled in CHECK.md: reference counting over the identity objects, arena for value-semantic data — the retain/release emitter work lands before T23.9 makes long-running programs real.)
- [x] **T23.6** — Modules and exceptions: multi-file module references, `raise`, uncaught-exception exit codes (`begin`/`catch`/`ensure` stays unscheduled — out of scope). Goldens: shop, function_group (free via IR lowering — claim the golden). (Done 2026-10-06: both goldens claimed byte-for-byte. Multi-file references needed two call-site fixes — funsigs now carries the callee's declared result so a cross-module call the checker types Unknown still converts, and the IR no longer lowers module-alias const bindings as thunks (they bound a path, not a value); group-const thunks return Unknown, not Void. `raise` renders the interpreter's E3010 message to stderr and exits 1 in the root process — no unwinder until `begin`/`catch` lands; a spawned process's raise ends only that process, per step 50.)
- [x] **T23.7** — The systems-layer surface: `Bytes` with little-endian accessors, the bitwise operators, `Byte`, `Int64`/`Float64` bit-casts. Goldens: bit_ops, bytes, fixed_width. (Done 2026-10-06: all three full-example goldens byte-for-byte. `&`/`|`/`^` are exact two's-complement on int64_t; `<<`/`>>` guard the count (negative errors, ≥64 gives 0/sign-fill) in the runtime; Byte is uint8_t with wrap-by-truncation and the Int64 div/shift guards; a Byte in the dynamic world materializes as an Int64 cell. Bytes is a new cell kind with in-cell storage, `to_bytes`/`to_string` interop, and a runtime `to_string` method dispatch (Bytes content vs value rendering) — the interpreter's runtime dispatch, mirrored. The checker now types `Unknown + Unknown` as Unknown (the runtime dispatches `+` per the values — neither result is provable); C reserved words in Emo defs get a `_c` suffix.)
- [x] **T23.8** — C FFI rungs 1–3 on the direct C ABI (no wrapper generator): scalars, width types as they land, opaque handles + copied buffers; the capability table flips `c` to honoring `foreign def`. Goldens: a libm `sqrt` fixture and a tiny C opaque-handle fixture under `test/`. (Done 2026-10-06: the c backend emits `extern` declarations and calls the symbol directly — no wrappers. Strings cross with a NUL terminator (`emo_str_cstr` out, `emo_str_from_cstr` in, per CHECK.md's layout decision); Int64 crosses as `int64_t` — the capability table is now target-aware in the checker (`c` admits Int64, the OCaml backend stays Float64/String/Bool); opaque handles ride pointer-sized Int64s behind a tiny externally-owned counter library, explicitly closed, in the `c_foreign` test group alongside the libm fixture.)
- [x] **T23.9** — Processes and the cooperative scheduler: `do` / `<-` / `receive`, mailboxes, selective receive, `self_pid`, `halt`; single-threaded cooperative loop; traces diffed against `emo_sched_det`. Goldens: pipeline, showcase. (Done 2026-10-06: both full-example goldens byte-for-byte. Each Emo process is a ucontext fiber with its own stack; the scheduler keeps emo_sched_det's policy — FIFO run queue, spawn enqueues the child without suspending the spawner, send delivers + wakes + re-queues the sender at the tail, receive scans the mailbox in generated code for the first message a branch accepts (a failed guard leaves the message queued) and parks the fiber when nothing matches; an empty run queue with parked fibers is a reported deadlock. Pids are an EMO_PID cell (rendered `<pid N>`); `EMO_TRACE=1` prints spawn/send/park/dispatch/exit/reap events for diffing. Also fixed en route: the entry file discovered twice (root + tree copies, keyed by a `/.`-carrying path) lowered every symbol under two manglings — the walk now normalizes file paths and the IR dedupes module copies by the parsed items' physical identity.)
- [x] **T23.10** — Hosted IO and stdlib metadata: `file.read`/`file.write`, TCP/UDP sockets, the HTTP client/server over the hosted OS; stdlib gains `"c"` in `targets`. Goldens: file_read, tcp_echo, http_roundtrip. (Done 2026-10-06: all three full-example goldens byte-for-byte, including the stdlib http/net packages compiling on the c target. Sockets are non-blocking fds whose would-block reads park the fiber — the scheduler polls parked descriptors while the run queue is empty; the root process finishing ends the program. Cross-module Unknown receivers dispatch by method/field NAME (globally runtime-owned names, runtime helpers; instance fields by vtable name). Unix sockets, TLS, DNS resolve, and UDP compile as honest runtime refusals. The stdlib file/net/http packages and the three examples declare `"c"`, lockfiles regenerated.)
- [x] **T23.11** — Bootstrap, benchmarks, close-out: the `c_examples` CI group; specialization (unboxing, direct dispatch) with `restrict` on hot loops; `benchmarks/results.md` gains the `c` column; the `native` → `ocaml` rename lands here or in its own step; close-out records the decisions. (Done 2026-10-06: all six benchmarks recorded on the c target — fib 7 ms, tail loop 4 ms (470x under the OCaml backend's specialized build, 1.3x from the C baseline), ffi 46 ms, bytes 43 ms, json 3 ms, http 83 req/s. Specialization is structural: the two-regime emitter already unboxes natives and dispatches directly where types are known; `restrict` waits for pointer-parameter loops (the buffer rung). The rename is its own step, next.)

## M7 — Toolchain

The last mile of the self-contained story, and the toolchain
release, with the official 1.0 following.
M6 removed the OCaml toolchain from the *programs*; M7 removes the
installation burden from the *tool* — the release engineering
`CHECK.md` left unscheduled, on the decided direction
(`docs/toolchain-distribution.md` is the design record): prebuilt
binaries per platform on GitHub Releases as the primary channel,
`opam` and a Homebrew formula as the source-building alternatives,
and the command set a product needs — `emo new`, `emo deps`,
`emo doctor` join `run`/`repl`/`check`/`build`/`publish` — so
a machine with nothing but the binary runs, checks, builds (through
the `c` target), pins and resolves dependencies, and publishes.

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

### Step 24 — Toolchain distribution & release · `plan/step-24-toolchain.md`

**Prereq:** Step 23 (the `c` target; the `native` → `ocaml` rename landed with it).
**Done when:** the release workflow, run on a version tag, produces
signed per-platform archives (Linux x86_64/aarch64, macOS
x86_64/arm64) whose binaries pass the end-to-end acceptance on every
platform; a machine with only the installed binary — no OCaml, no
opam, no repository — runs, checks, and builds Emo programs through
the `c` target, scaffolds with `emo new`, pins dependencies with
`emo deps add`, and diagnoses its environment with `emo doctor`;
`dune test` green.

- [x] **T24.1** — Design-gate closure and the default target: the
      four settlements recorded in `CHECK.md` — the build default
      flips `ocaml` → `c`; the stdlib embeds as generated data (the
      C runtime's mechanism) over a sidecar tree; `emo install` is
      the project-dependencies frontend (global executable
      installation out of scope for 1.0); the dependency cache
      leaves the temp directory for a durable user location. The
      flip lands here, with the resolution-gate tests and the CI
      groups re-pointed — the c goldens already cover the target;
      only the default moves. (Done 2026-10-07: all four settled in CHECK.md; the flip moved every default path to c and exposed that the content-hash cache lived only in the ocaml arm — the c arm gained it; ocaml-backend harnesses and benchmarks pinned --target ocaml; tree-wide @fmt drift promoted. Amended 2026-10-17: the `emo install` command was removed; `emo deps` and the build path own resolve/fetch/lock.)
- [x] **T24.2** — The self-contained binary: the bundled stdlib as
      generated data inside the compiler; the registry endpoint
      becomes a filesystem directory or the embedded stdlib;
      `EMO_REGISTRY` still overrides. Verification: a lone `emo`
      copied into an empty directory runs, checks, and builds a
      stdlib-importing program — and `publish`'s embedded uploader
      works from it. (Done 2026-10-07: generated data via devtools/gen-stdlib-data.sh; the macOS sandbox materializes the source_tree dep as symlinks — the generator walks -type f -o -type l, found by probe; endpoint is Fs_dir or Embedded; lone-binary verification passed (run/check/build/publish); embedded-vs-filesystem checksum parity pinned by a test.)
- [x] **T24.3** — `emo new <name>`: the scaffold — `package.emo`
      (name, version, targets) and a hello-world `main.emo`, plus
      `.gitignore`. Strictness holds: an existing directory or
      clashing files refuse with clear errors, no `--force`. The
      scaffold is green the moment it exists — CI creates, checks,
      runs, and builds one. (Done 2026-10-07: CI scaffolds/checks/builds/runs one; owner/name taken as given on relative single-slash args; refusals exit 65.)
- [x] **T24.4** — `emo install`: read the manifest, resolve against
      the registry, fetch into the user cache, write
      `package.lock`; idempotent re-runs change nothing; each
      failure mode — no registry configured, unsatisfiable pin, a
      dependency lacking the requested target — gets its own clear
      message. `emo deps` keeps resolve/update/list as the explicit
      paths. (Done 2026-10-07: idempotent; lockfile written only when it would change; cache default moved to ~/.cache/emo (XDG honored, EMO_CACHE_DIR overrides). Amended 2026-10-17: the `emo install` command was removed; the resolve/fetch/lock behavior it fronted lives in `emo deps resolve` and in the build path's own resolution.)
- [x] **T24.5** — `emo doctor`: the target-aware environment check,
      replacing the interim ocaml-only shape in `CHECK.md`. Per
      target: `c` — a cc compile-and-run smoke; `ocaml` — the
      runtime `.cmxa` found in the switch, or the honest "prebuilt
      installation: the ocaml target needs a source install
      (`opam install emo`)"; `typescript` — node; `beam` — erlc;
      `wasm` — nothing. Plus the installation shape (prebuilt vs
      source), stdlib presence, and version. Exit non-zero only on
      what is actually broken. (Done 2026-10-07: source-vs-prebuilt via the runtime .cmxa set; the c smoke decides the exit code; ocaml unavailable reports the opam install fix.)
- [x] **T24.6** — Release packaging and CI: the tag-triggered
      workflow beside the existing CI — per-platform matrix builds
      (Linux x86_64/aarch64, macOS x86_64/arm64), release binaries
      through dune, the archive layout T24.1 settled, `SHA256SUMS`,
      a drafted GitHub Release. The Linux binary is portable —
      static or the oldest viable glibc — verified in clean
      containers, not on the builder. (Done 2026-10-07: package-release.sh verified end to end locally; matrix = linux x86_64/aarch64 (ubuntu-22.04, glibc 2.35) + macOS x86_64/arm64, suite run before packaging, Linux verified in a clean ubuntu:22.04 container.)
- [x] **T24.7** — Signing and the platform gates: macOS codesign
      (hardened runtime) → notarytool → staple, credentials in CI
      secrets — the solved-not-a-blocker from `CHECK.md`, now
      scheduled. Windows: WSL2 documented as the supported path,
      the native prebuilt recorded as deferred with the
      ucontext/socket port named as the blocker;
      `docs/toolchain-distribution.md` updated (both languages). (Done 2026-10-07: four secrets gate codesign → notarytool → staple; absent secrets ship unsigned with a notice; distribution docs updated both languages.)
- [x] **T24.8** — Provisioning channels and install docs: the
      Homebrew formula (own tap; core when the project qualifies)
      and the opam package — the source channel that brings the
      `ocaml` target. README install sections in both languages:
      prebuilt archives first, then brew, opam, WSL2. (Done 2026-10-07: formula at devtools/homebrew/emo.rb for the own tap, checksums filled at release; dune-project generates emo.opam (no dev_repo field in the stanza — dropped); README install sections in both languages.)
- [x] **T24.9** — Release acceptance and the release cut: on every shipped
      artifact, end to end — download, unpack, `emo doctor`,
      `emo new`, `emo run`, dependency resolution, `emo build` (the `c`
      target) — including a stdlib-importing program and the golden
      subset executed from the installed binary. the release commit
      carries the released VERSION; annotated tag, release notes,
      close-out. (Done 2026-10-07: acceptance ran against the packaged-and-unpacked archive — doctor healthy in the prebuilt shape; new → run → build green, with `emo install` resolving through the embedded stdlib (the `emo install` command was removed 2026-10-17; `emo deps resolve` and the build path now own that step); goldens 14/14 from the installed binary (13 via emo run byte-for-byte, numerics via its designed compiled path — it crosses foreign def, which emo run refuses; http_roundtrip/tcp_echo ride the in-tree suite).)

Close-out: recorded 2026-10-07 in `plan/step-24-toolchain.md` — the
acceptance ran against the packaged artifact, not the build tree; the
default-target flip moved every default path to `c` (and flushed out
that the content-hash cache had only ever lived in the ocaml arm),
the embed's dune rule needs `-type f -o -type l` because the macOS
sandbox materializes `source_tree` deps as symlinks, and the archives
ship without an install script. **Step 24 acceptance met.** M7 is
done: the toolchain release accompanies the official 1.0.

## M8 — Target independence

The host/target distinction made load-bearing. The host language (how
emo was built — today OCaml) answers one question; the targets (what
emo turns your program into) answer another. Fully honoring the split
means the host contributes only the emitters: every target's runtime
lives in the target's own ecosystem, never beside the binary and never
in the host build tree — so a future host rewrite (Go, or another
host entirely) touches only the emitters.

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

### Step 25 — Target independence · `plan/step-25-target-independence.md`

**Prereq:** Step 24 (the toolchain whose claims this step corrects).
**Done when:** no target reads its runtime from beside the binary or
the host build tree — c, ocaml, and typescript runtimes ride inside
the compiler as generated data, wasm and beam inside the emitted
module; `emo build --target ocaml` works on any installation where
the OCaml toolchain is on PATH, with no `.cmxa` lookup and no
installation-shape conditionals; the typescript target works from the
release layout; all goldens byte-for-byte; `dune test` green.

- [x] **T25.1** — The principle and the ts embed: the
      runtime-independence principle recorded in `CHECK.md`; the ts
      prelude embedded as generated data (the C runtime's dune rule
      pattern), the typescript arm stopped from reading the
      filesystem. Verification: a lone release-layout binary compiles
      a typescript program; the ts goldens byte-for-byte. (Done
      2026-10-07: the prelude rides `emo_codegen/ts` as generated data
      and the CLI never touches the filesystem for it; a lone binary
      compiles and runs a ts program; the seven ts goldens green.)
- [x] **T25.2** — The emitted-code inventory and the standalone
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
- [x] **T25.3** — The value and scalar core: the value ADT, strings,
      print/interpolation rendering, arithmetic/comparison dispatch,
      and the case/error paths the inventory names, standalone. Each
      piece covered by a fixture compiled against the runtime alone.
      (Done 2026-10-07: five fixture programs in the emitter's call
      shape, compiled with `ocamlopt -open Emo_ocaml_runtime` against
      the extracted runtime alone.)
- [x] **T25.4** — The scheduler and IO: the effects-based scheduler,
      file IO, and networking, per the dependency policy (the OCaml
      standard library plus `unix`; `ssl` as the one opam dep; no eio).
      Fixtures: a process program and an HTTP roundtrip compiled
      against the standalone runtime alone. (Done 2026-10-07: the det
      scheduler ports whole — spawn/send/receive, fd and timer parking,
      TLS, UDP, file IO; eio drops out, the policy settles on unix plus
      ssl; four more fixtures ride the scheduler.)
- [x] **T25.5** — The cutover: the ocaml emitter's references flip to
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
- [x] **T25.6** — The independence audit and close-out: wasm and beam
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

Step 25 complete 2026-10-07 (T25.1–T25.6 on
`feat/target-independence`): no target reads its runtime from beside
the binary or the host build tree; the ocaml target works from a lone
release-layout binary wherever the OCaml toolchain is on PATH; the
typescript target likewise; all goldens byte-for-byte and `dune test`
green.

## M9 — For / While loops

The loop surface `CHECK.md` settled (2026-10-06): guaranteed tail calls
stay, and `for` / `while` join them. `for var i = 0; i < n; i = i + 1 { ... }`
is paren-less with exactly three clauses, the header `var` scoped to
header and body; `while cond { ... }` is condition-only; `break` and
`continue` are bare statements bound to the nearest enclosing loop; no
`do`/`while`, no `+=`/`++`. The rationale: loops are the native shape
for the vectorizer and the OpenMP parallel-loop rung (the HPC gate),
they remove the tail-position proof burden from loop code, and they
pair with `var` — while the var-escape rule (E4012) already fences the
Go loop-capture trap. The design lives in `CHECK.md` and the README;
each step's plan file is written when the step starts.

### Step 26 — Loop surface: lexer, parser, checker, interpreter

**Prereq:** Step 25.
**Done when:** the README's loop snippets run verbatim through
`emo run`; the CHECK.md worked example (`for var i = 0; i < 100;
i = i + 50`) prints `i = 0` then `i = 50`; a 10M-iteration `while`
keeps the stack flat; every refusal — a reserved word used as an
identifier, a missing clause, `;` outside a `for` header,
`break`/`continue` outside a loop — has its own diagnostic;
`dune test` green.

- [x] **T26.1** — Keywords: reserve `for`, `while`, `break`,
      `continue` in the lexer; the LSP completion list and the VS Code
      grammar flip in lockstep; code using the four words as
      identifiers reports a clear reserved-word diagnostic. (Done 2026-10-11.)
- [x] **T26.2** — Parser: `while cond { }` and the three-clause `for`
      — no omissions, the post clause an assignment, `;` a token legal
      only inside a `for` header, `suppress_block_sugar` set on the
      `while` condition and all three `for` clauses so the trailing
      `{` opens the body; AST nodes for the four statements. (Done 2026-10-11.)
- [x] **T26.3** — Checker: the header `var` scoped to header+body in
      the existing depth model; `break`/`continue` bind to the nearest
      enclosing loop and are rejected outside one; `definitely_returns`
      accounts for loops so `return`-reachability stays sound;
      capturing the header `var` in an arrow block stays E4012. (Done 2026-10-11.)
- [x] **T26.4** — Interpreter: the four statements in `eval_stmt`; the
      iteration runs a host loop, never recursion — 10M iterations
      flat; `continue` runs a `for`'s post clause first; the step
      budget counts each iteration. (Done 2026-10-11.)
- [x] **T26.5** — Example and rejections: `examples/loops` — the
      worked example, `while` counting, `break`/`continue`, nested
      loops — golden through `emo run`; the parser and checker
      rejection corpus pinning every refusal. (Done 2026-10-11.)
- [x] **T26.6** — README alignment: the README (English + zh-CN)
      already documents the settled syntax — verify it against the
      implemented surface and reconcile any drift. (Done 2026-10-11.)

Step 26 close-out (2026-10-11, on `feat/loops`): the loop surface is
live in the lexer, parser, checker, and interpreter, one commit per
task. `;` became a token whose only legal home is a `for` header
(E2025), and the header's shape is parse-time law — the init clause a
`var`, the post clause an assignment, no clause optional (E2026), with
block sugar suppressed in every clause. The checker splits the loop
into two scopes — header, then body as its child — so the header `var`
sits a level below any arrow block in the body and capturing one is
the ordinary var-escape error (E4012); `break`/`continue` bind to the
nearest loop through a `loop_depth` field that arrow blocks reset to
zero (E4022 outside a loop), and no loop shape counts as a return
point. The interpreter runs each iteration as an OCaml tail loop with
a fresh body frame — 10M iterations verified flat — `continue` still
runs a `for`'s post clause, and the step budget counts every
iteration, which is what keeps the restricted config profile
terminating now that loops exist. `examples/loops` is golden through
the interpreter; the six backends refuse the loop statements loudly
until step 27 lowers them.

### Step 27 — Loops on every target: IR and the six backends

**Prereq:** Step 26.
**Done when:** `examples/loops` compiles on c, ocaml, typescript,
wasm, beam, and riscv64, each printing byte-for-byte what `emo run`
prints (goldens in CI); a 10M-iteration loop stays flat on every
target; the tail-call guarantee is untouched (`loops_tail` unchanged);
`dune test` green.

- [x] **T27.1** — IR: the loop statements in `emo_ir`'s `stmt` and the
      Ast→IR lowering — the header `var` as a loop-scoped mutable
      binding; one node set, every backend a case. (Done 2026-10-11.)
- [x] **T27.2** — c: the emitted C's own `while`/`for` with native
      `break`/`continue`; `return` inside a loop rides the existing
      branch-to-epilogue. (Done 2026-10-11.)
- [x] **T27.3** — ocaml: native `while`/`for` over the existing `ref`
      discipline for the header `var`; `break`/`continue` lower
      through the one mechanism the plan file records (a done flag or
      a local exception — decided, never a silent fallback).
      (Done 2026-10-11 — the mechanism: one pair of local exceptions
      per loop, `Break_N`/`Continue_N`; `continue` unwinds to the
      handler above the post, `break` past the whole while.)
- [x] **T27.4** — typescript: native `while`/`for` in the emitted
      body; `break`/`continue` are the target language's own.
      (Done 2026-10-11. Also fixed a pre-existing backend bug the
      loops golden exposed: `stmts` emitted the rest of a chain before
      its head — sprintf arguments evaluate right-to-left — so a `var`'s
      ref registration landed after the statements that needed it; the
      head now emits first. The self-tail-call driver loop gained the
      `__emo_driver` label so a tail call inside a loop continues the
      driver, not the Emo loop.)
- [x] **T27.5** — wasm: structured control flow — `Loop` with `Br_if`
      on the condition; `break` branches out of the loop block,
      `continue` to the head, the post clause running first.
      (Done 2026-10-11. For lowers to `block $exit { init; loop $head {
      test; br_if $exit; block $post { body } post; br $head } }`, so a
      `continue` lands on the post and a `break` leaves past it; frame
      depths are tracked for statement-level ifs and case dispatches so
      branch depths stay relative-correct inside nested control flow.)
- [x] **T27.6** — beam: the loop lowers to a tail-recursive local
      function — condition guard, body, recursive call with the
      rebound variables; `break` threads a done marker.
      (Done 2026-10-11. Each loop is a hidden module function taking
      the header `var` plus every outer binding the body reads or
      assigns, threaded through the recursive calls; a done flag
      marks `break`, `continue` applies the post first. The body
      emits as a tail chain — ifs weave the rest into their arms,
      jumps truncate the dead rest — so every jump is a genuine tail
      call; Core Erlang's `do` only tail-calls its last operand.)
      (Also fixed: the single-statement `Assign_var` path registered
      the shadow before evaluating the value, so `n = n + 1` read the
      variable it was defining.)
- [x] **T27.7** — riscv64: labels and conditional branches — the loop
      head a label, `break`/`continue` jumps.
      (Done 2026-10-11. While is `head: test; beqz exit; body; j head`;
      a `for` puts a post label between the body and the jump back, so
      `continue` lands on the post and `break` leaves past it. The
      header `var` is a frame slot, the existing discipline. The value
      heap's no-reclamation arena — shared with the pre-loop
      tail-recursive idiom — still bounds long-running programs;
      unchanged by this task.)
- [x] **T27.8** — Goldens and benchmarks: `examples/loops` on all six
      target golden lists; a plain-loop row beside `loops_tail` in
      `benchmarks/results.md`; the CI groups; close-out. (Done
      2026-10-11. The riscv64 target gained `/` and `%` — `div`/`rem`
      with a zero-division abort — so the example boots there; the
      plain-loop benchmark records the ocaml target's dynamic-by-
      construction number beside the c target and the interpreter.)

Step 27 close-out (2026-10-11, on `feat/loops`): the loop statements
lower on all six targets, one commit per task. The IR carries
While/For/Break/Continue with the header `var` as a loop-scoped mutable
binding, and assignment lowering resolves innermost-first so a header
`var` updates itself under a same-named module-level `var`. c emits its
own `while` and a `while(1)` form whose continue label runs the post;
ocaml uses the ref discipline and a pair of local exceptions per loop;
typescript uses the target's native `for` with a labeled driver loop
for tail calls; wasm lowers to block/loop/br_if with a post block;
beam threads every free variable through a hidden recursive function
with a done flag; riscv64 uses labels and jumps — and gained `/` and
`%` so the example boots. `examples/loops` is golden on all six targets
plus the interpreter, and the plain-loop benchmark row records the
dynamic-by-construction ocaml number beside the c target.

## M10 — Error handling

The error model `CHECK.md` settled (2026-10-11): expected failures are
values — `(R.ok, value)` / `(R.error, reason)` off the built-in `R`
enum — matched in `case` or assert-bound through a binding pattern
(`const (R.ok, body) = f()`); a violation raises the one `Exception`
class, and a raise ends the process — no catch construct, on any
target. `R` sits in the spec-core tier (`CHECK.md`, type layering), so
every target including riscv64 gets it; the stdlib migration moves the
~220 raise sites to the convention, package by package. The design
lives in `CHECK.md` and the README (both languages); each step's plan
file is written when the step starts.

### Step 28 — Error-handling surface: R, binding patterns, raise discipline

**Prereq:** Step 27.
**Done when:** the README's exception snippets run verbatim through
`emo run`; an error tuple flowing into `const (R.ok, body)` ends the
process with the case-no-match runtime error; `raise "str"` and
`raise user` each get their own diagnostic; the built-in names `R` and
`Exception` refuse user redeclaration; the uncaught report prints
non-empty `data`; `dune test` green.

- [x] **T28.1** — Built-in `R { ok, error }`: bound in the checker's
      root env and the interpreter's global frame (the `Exception`
      precedent); `R.ok` / `R.error` construct and pattern-match
      everywhere enum members already do; `enum R` / `class R` report
      a reserved-name diagnostic.
- [x] **T28.2** — Parser: `const`/`var` accept a full pattern in
      place of the name (`Ast.Binding` carries it); the `const (`
      form stops being a hard error, breaking no grammar.
- [x] **T28.3** — IR: the pattern binding desugars to a one-arm
      `case` wrapping the block remainder — no new IR nodes, the six
      backends see only existing ones.
- [x] **T28.4** — Checker: pattern bindings check through
      `check_pattern` against the initializer's type; `raise`'s
      operand must be an `Exception` instance (its own E-code for
      everything else); the uncaught diagnostic appends non-empty
      `data`.
- [x] **T28.5** — Interpreter: pattern-binding evaluation, mismatch
      riding the case-no-match runtime error; the raise-operand
      discipline at run time; existing goldens re-recorded where the
      uncaught format changed.
- [x] **T28.6** — Example and rejections: `examples/errors` — the
      README snippets verbatim (ok/error matching, the assert-match
      binding, a violation raising) — golden through `emo run`; the
      matching example golden on all six targets byte-for-byte
      (riscv64 runs the matching half; its raise refusal unchanged);
      the rejection corpus pinning every new diagnostic.
- [x] **T28.7** — README alignment: the README (English + zh-CN)
      already documents the settled surface — verify it against the
      implemented one and reconcile any drift.

### Step 29 — The stdlib migration: tuples replace raises, package by package

**Prereq:** Step 28.
**Done when:** every stdlib package's data-driven failures return
`(R.error, reason)` and only contract violations raise; every package
golden green on its declared targets; `dune test` green.

- [x] **T29.1** — `file` + `os`: open/read/write and permission
      misses, missing paths return tuples; the native raise sites (os
      runtime, interp + ocaml + c) return instead; waitpid decoding
      untouched.
- [x] **T29.2** — `json` + `yaml` (+ `internal/float`): parse and
      accessor failures return tuples — the two biggest sites, ~150.
- [x] **T29.3** — `xml` + `base64` + `bufio` + `slog` + `http` +
      `sync`: the same split; `http`'s refused/unresolved/deadline
      failures become tuples, per the README's network section.
      (`xml`/`base64` decode failures and the whole `net` surface
      return tuples; `bufio`/`slog`/`sync` keep their raises — every
      one is a caller mistake.)
- [x] **T29.4** — Goldens: every touched package's error-path
      fixtures re-recorded to match `(R.error, why)`; package goldens
      green on all declared targets.
- [x] **T29.5** — Docs: the per-package pages under `docs/stdlib/`
      (and the zh-CN mirrors) reworded raise → returns; error-message
      tables updated.

### Step 30 — Checker strictness: Box typing and cross-module value signatures

The checker pass on `feat/checker` (2026-10-11): the two divergences the
loops step recorded, plus what unblinding them exposed. Decisions in
CHECK.md.

- [x] **T30.1** — `Box.new` types as `Box[T]`: the checker's constructor
      special case beside `List.new`/`Map.new`, so `read`/`replace`
      check against the cell and every other member — including a bare
      member access — is refused at check time (the bare `x.v`
      divergence; the stdlib's Box state was wholly unchecked). Two
      latent c-side deviations fell out the moment receivers carried
      types: `emo_box_replace` answered with the box while every other
      target answers with the new value (aligned), and the emitter's
      `to_string` dispatch arm hijacked statically-typed instance
      receivers, printing the debug repr instead of calling the class's
      method (instances now dispatch by class first, the conversion
      only when no method carries the name).
- [x] **T30.2** — Cross-module value signatures: defs and foreigns as
      their declared `FuncType`s, consts/vars as their initializer's
      types, and the `emo` groups into a program-wide registry — all
      pre-registered beside the type tables. A qualified call checks
      through `check_apply`; a bare member read resolves or reports
      E5004 statically; group members type (a bare `Math.tau` read as
      Unknown even same-module before); a local shadows a module of the
      same name, the runtime's rule. Two pre-existing checker bugs fell
      out: `longest_module_prefix` walked the path's suffixes, never its
      prefixes, and the empty dotted path passed as a module prefix —
      bare member access on any non-simple receiver (`foo(1).field`)
      read as Unknown.
- [x] **T30.3** — A capitalized value name resolving to no type, group,
      or module reports E4003 where it is written, in a program check
      (the runtime's value-carrying builtins stay legal); the lone-file
      view keeps the old silence, like every cross-file gap it cannot
      see through. The json/yaml interfaces declare `get` (a
      self-referencing signature; json gains the four raising scalar
      variants its classes already answered with). Checker and project
      tests; the CHECK.md entry; every target's goldens green.

## M11 — The standard library

The bundled stdlib is a milestone of its own: one package per step, each
shipping its API reference and a runnable golden. The steps run `json`
(31) through `bufio` (37), then the native-binding `sqlite3` (38) and
the SQL parser `sql`.

### Step 31 — The standard library: `json` · `plan/step-31-stdlib-json.md`

**Prereq:** Step 11 (packages) + step 25 (target independence).
**Done when:** `require "json"` decodes and encodes JSON on every
target the compiler ships, byte-identically — strict offset-bearing
errors, exactly round-tripping numbers, a value tree of ordinary Emo
data over the shared runtimes, zero per-target runtime work beyond the
typescript UTF-8 bytes fix; goldens on all six paths; `dune test`
green.

- [x] **T31.1** — The spec and the skeleton: the package
      `stdlib/registry/json/0.1.0` (`package.emo` over the five tested
      targets, `json.emo` with the value model — `JsonKind`, the
      `Json` interface, seven payload classes, the factories — and
      `internal/float.emo` for the numeric machinery) embedded by
      rebuild. Verification: a factory-built value encodes,
      interpreted. (Done 2026-10-09.)
- [x] **T31.2** — The typescript bytes fix: `to_bytes` encodes UTF-8
      and `Bytes.to_string` decodes UTF-8 in the ts prelude; all
      existing ts goldens byte-for-byte. (Done 2026-10-09: the
      interpreter, c, and typescript agree on a non-ASCII
      round-trip.)
- [x] **T31.3** — The decoder: the byte-level scanner and
      recursive-descent parser over the RFC 8259 grammar — escapes
      with surrogate pairs, exact `Int64`/`Float64` numbers, the depth
      cap, offset-bearing errors. (Done 2026-10-09: decode rounds
      decimals once, to nearest with ties to even — `strtod`'s
      answer — via exact long division in `internal/float.emo`.)
- [x] **T31.4** — The encoder: compact and pretty forms; string
      escaping; integers through `Int64.to_string`; the
      shortest-round-trip float formatter. (Done 2026-10-09: π prints
      `3.141592653589793`, denormal-min prints `5.0e-324`, max prints
      `1.7976931348623157e+308`; a float always stays visibly a
      float.)
- [x] **T31.5** — The golden example: `examples/json_demo` wired into
      the interpreter-bootstrap and typescript golden lists (one
      `expected.txt`); c, wasm, and beam wait on the cross-module
      follow-up below. (Done 2026-10-09.)
- [x] **T31.6** — The edge fixtures: `examples/json_edge` — escape
      matrix, surrogate pairs, the 512-array cap round-tripped,
      duplicate keys, number boundaries, round-trips, pretty form —
      wired into the interpreter-bootstrap list. (Done 2026-10-09;
      flushed out the missing empty-container guards in the compact
      encoder.)
- [x] **T31.7** — The docs and close-out: `docs/stdlib/json.md` and
      its zh-CN mirror; `dune build @fmt` and `dune test` green.
      (Done 2026-10-09.)

Step 31 close-out (2026-10-09, on `feat/stdlib`): `require "json"`
decodes and encodes byte-identically on the interpreter, the ocaml
target, and the typescript target — goldens `json_demo` (bootstrap +
ts) and `json_edge` (bootstrap) green, `dune build @fmt` and
`dune test` green end to end. The package is ordinary pure Emo; the c,
wasm, and beam targets stay blocked on one checker step — cross-module
type names ("cross-module types stay unchecked this step", step 10) —
with the minimal repros and the backend fixes this step already landed
recorded in `plan/step-31-stdlib-json.md`. Compiler fixes riding this
step: the span type table keyed by file (multi-module type
corruption), the typescript tail-call rewrite's argument
temporaries + string escapes + interface separators, the c `emo_send`
argument array + unknown-receiver vtable fallback + mutual-tail
cluster entry dispatch, and the wasm interface-dispatch `Ref_cast` +
field display-name resolution.

### Step 32 — The standard library: `yaml` · `plan/step-32-stdlib-yaml.md`

**Prereq:** Step 31 (the json package — the tree design and the float
machinery this package mirrors). **Done when:** `require "yaml"`
decodes and encodes YAML 1.2 (core schema) byte-identically on the
targets the checker carries — block/flow, quoted scalars with the
YAML escape set, block scalars with chomping, duplicate keys
last-win, numbers at their boundaries; goldens green on
interpreter/ocaml/typescript; c, wasm, and beam wait on the
cross-module-types follow-up shared with step 31.

- [x] **T32.1** — The package and the parser: `stdlib/registry/yaml/
      0.1.0` embedded by rebuild; the value model, the block/flow
      parser. (Done 2026-10-09.)
- [x] **T32.2** — The encoder: block style; plain-when-unambiguous
      strings; empty-container flow forms. (Done 2026-10-09.)
- [x] **T32.3** — The goldens: `examples/yaml_demo` (bootstrap +
      typescript) and `examples/yaml_edge` (bootstrap). (Done
      2026-10-09.)
- [x] **T32.4** — The docs: `docs/stdlib/yaml.md` + zh-CN mirror;
      `dune build @fmt` and `dune test` green. (Done 2026-10-09.)

Step 32 close-out (2026-10-09, on `feat/stdlib`): the yaml package
mirrors the json package's tree design and passes its goldens on the
interpreter, ocaml, and typescript; c, wasm, and beam remain gated on
the cross-module-types checker step shared with step 31. The package
also flushed out the typescript runtime's field-shadows-method
dispatch bug (fixed in `ts_runtime.ts`: E.method now falls through to
the prototype's method when the own property is not a function).

### Step 33 — The standard library: `xml` · `plan/step-33-stdlib-xml.md`

**Prereq:** Step 31 (the json package — the tree design and the
byte-scanner patterns this package follows). **Done when:**
`require "xml"` decodes and encodes well-formed XML byte-identically
on the verified targets — elements with quoted attributes, self-
closing form, the five entities plus character references, CDATA as
raw text, comments / PIs / declaration / DOCTYPE skipped, mixed
content, offset-bearing errors; goldens green on
interpreter/ocaml/typescript/c; wasm and beam wait on the
cross-module-types follow-up shared with steps 31–32.

- [x] **T33.1** — The package, the value model, and the decoder.
      (Done 2026-10-09.)
- [x] **T33.2** — The encoder. (Done 2026-10-09.)
- [x] **T33.3** — The goldens: `examples/xml_demo` (bootstrap + c +
      typescript) and `examples/xml_edge` (bootstrap). (Done
      2026-10-09.)
- [x] **T33.4** — The docs: `docs/stdlib/xml.md` + zh-CN mirror;
      `dune build @fmt` and `dune test` green. (Done 2026-10-09.)

Step 33 close-out (2026-10-09, on `feat/stdlib`): the xml package —
the leanest of the three format packages (XML is all text, so no
float machinery) — passes its goldens on the interpreter, ocaml,
typescript, AND c (xml_demo rides the c_goldens list). The package
also flushed out the exact-buffer `to_string().substring(byte_count)`
out-of-bounds pattern across all three format packages (fixed:
exact-fill buffers return `to_string()` directly). wasm and beam
remain gated on the cross-module-types checker step.

### Step 34 — The standard library: `os` · `plan/step-34-stdlib-os.md`

**Prereq:** Step 23 (the c target) and step 25 (target independence —
the standalone ocaml runtime needs the dispatch too). **Done when:**
`require "os"` gives a program process identity, fork / execv /
waitpid / _exit, a pipe, raw unbuffered fd file IO, and the directory
surface; every failing call raises naming the system call; waitpid
answers the kernel's raw 16-bit status with pure-Emo decoders;
list_dir answers byte-order-sorted names without `.` and `..`;
goldens green on interpreter/ocaml/c; ts/wasm/beam refuse the package
by declaration.

- [x] **T34.1** — The checker signatures, the `os_` runtime
      implementation prefix, and the interpreter's Unix-backed
      dispatch. (Done 2026-10-09.)
- [x] **T34.2** — The c runtime's `emo_os_*` POSIX implementations
      and the c emitter's dispatch. (Done 2026-10-09.)
- [x] **T34.3** — The standalone ocaml runtime's dispatch. (Done
      2026-10-09.)
- [x] **T34.4** — The package: thin wrappers, the wait-status
      decoders, the fork/pipe discipline. (Done 2026-10-09.)
- [x] **T34.5** — The golden: `examples/os_demo` on the bootstrap
      and c_goldens lists. (Done 2026-10-09.)
- [x] **T34.6** — The docs: `docs/stdlib/os.md` + zh-CN mirror;
      `dune build @fmt` and `dune test` green. (Done 2026-10-09.)

Step 34 close-out (2026-10-09, on `feat/stdlib`): the os package —
the second runtime-backed package after net, and the first reaching
into process machinery — verified on the interpreter, ocaml, and c
targets; the os_demo golden exercises fork+pipe+waitpid (child exits
7 through _exit, the parent decodes the raw status) beside the raw IO
and directory surfaces. Unlike the format packages, os crosses
modules with native types only, so the c target takes it without the
cross-module-types checker step; ts/wasm/beam are refused by the
package's targets declaration.

### Step 35 — The standard library: `base64` · `plan/step-35-stdlib-base64.md`

**Prereq:** Step 31 (the json package — the byte-scanner discipline).
**Done when:** `require "base64"` encodes with the standard alphabet
and `=` padding and decodes strictly — alphabet-only, padding only in
the final quantum, canonical zero padding bits — with the offending
byte offset on every rejection; the golden rides ALL five lists
(bootstrap, c, typescript, wasm, beam), byte-identical everywhere.

- [x] **T35.1** — The package: the arithmetic alphabet both
      directions, the strict decoder, offset-bearing errors. (Done
      2026-10-09.)
- [x] **T35.2** — The wasm fixes: the `&&`/`||` left-operand cast and
      the zero-length byte-copy guard. (Done 2026-10-09.)
- [x] **T35.3** — The beam fixes: the logical operators, the tuple
      index, and `Make_exception`. (Done 2026-10-09.)
- [x] **T35.4** — The golden: `examples/base64_demo` on all five
      lists. (Done 2026-10-09.)
- [x] **T35.5** — The docs: `docs/stdlib/base64.md` + zh-CN mirror;
      `dune build @fmt` and `dune test` green. (Done 2026-10-09.)

Step 35 close-out (2026-10-09, on `feat/stdlib`): the base64 package
is the first standard-library package on all five goldens — and the
step flushed out four latent backend bugs no shipped example had ever
reached: the wasm `&&`/`||` left operand skipped its `ref.cast` (this
was the wall gating json/yaml/xml out of the wasm goldens), the wasm
zero-length byte copies were do-whiles that trapped on
`"".to_bytes()`, the beam logical operators called `emo_add` on two
booleans, and the beam tuple index used `lists:nth` on an Erlang
tuple; beam also gained `Make_exception` (the exception object is its
message). The json/yaml/xml wasm gate should be re-examined against
these fixes — the `&&` wall is gone, though their cross-module class
types may still be gated by the step-31 follow-up.

Format-package backend follow-up (2026-10-14, on `develop`): the
re-examination is done — `json_demo`, `yaml_demo`, and `xml_demo` now
ride the wasm, beam, and c golden lists. `String.substring` had no
wasm or beam runtime; wasm gained an in-bounds byte copy and beam a
`binary:part/3` behind the interpreter's range check. Two wasm class
bugs surfaced behind it: the class-pad formula `ordinal * (max_fields
+ 1) + field_count` gave (ordinal 0, one field) and (ordinal 1, zero
fields) the same two-field struct, so WasmGC merged their RTTs and
`ref.test` could not tell `YamlNull` from `YamlBool` (a decoded null
answered as `YamlBool`, which read as a dispatch bug); each class's
total field count is now `(ordinal + 1) * (max_fields + 1) + 2`,
unique per class and clear of the two all-anyref runtime shapes. The
`get` method in the runtime also shadowed every class's `get` method on
both targets (`doc.get("k")` lowered to Bytes indexing); both backends now test
Bytes/instance at runtime and fall back to the Bytes accessor.

### Step 36 — The standard library: `slog` · `plan/step-36-stdlib-slog.md`

**Prereq:** Step 35 (base64 — the native-types-only surface shape).
**Done when:** `require "slog"` logs one line per record, logfmt or
JSON, filtered by a minimum level; loggers are ordinary values — an
opaque handle carrying name, level, and format — attrs are a
`Map[String, String]` with keys strict to one alphabet, and the golden
rides the bootstrap, c, and typescript lists byte-identical; wasm and
beam refuse the package until their runtimes implement `Map`.

- [x] **T36.1** — The package: the ordered levels and the two
      formats, the handle pack/parse, the logfmt and JSON renderers,
      strict keys and exact errors. (Done 2026-10-09.)
- [x] **T36.2** — The golden: `examples/slog_demo` — both formats,
      filtering, a child logger, quoting and escaping, UTF-8, and
      `enabled` — on the bootstrap, c, and typescript lists. (Done
      2026-10-09.)
- [x] **T36.3** — The docs: `docs/stdlib/slog.md` + zh-CN mirror;
      `dune build @fmt` and `dune test` green. (Done 2026-10-09.)

Step 36 close-out (2026-10-09, on `feat/slog`): the slog package is
the first standard-library package whose golden needed zero compiler
changes — the step-35 wasm/beam fixes held, and `Map` on
interp/ocaml/c/typescript carried the whole surface. The design
answers "a logger without a framework": the handle packs
`name/level/format` in plain sight so the package holds no state at
all, records carry no timestamp (no clock — deterministic output, a
caller with a time passes it as an attribute), and attribute keys are
strict to one alphabet shared with the handle's percent-escaping. The
manifest declares the three targets that work today and widens when
the wasm/beam `Map` gap closes.

### Step 37 — The standard library: `bufio` · `plan/step-37-stdlib-bufio.md`

**Prereq:** Step 36 (slog — the zero-compiler-change golden shape).
**Done when:** `require "bufio"` reads and writes through a
fixed-size buffer over two one-method structural interfaces —
`Reader` with line, delimiter, peek, discard, and one-level unread;
`Writer` with coalescing writes, explicit flush, and never a silent
discard — the fd and in-memory adapters cover the concrete streams,
the golden rides the bootstrap and c lists byte-identical, and the
c-backend cross-module dispatch is sound (an instance answers through
its vtable, once, and Void method statements keep their calls).

- [x] **T37.1** — The package: the two interfaces, the four
      adapters, the `Reader` and `Writer` surfaces, strict sizes and
      exact errors. (Done 2026-10-09.)
- [x] **T37.2** — The golden: `examples/bufio_demo` — in-memory
      streams, an 8-byte buffered file write that really flushes,
      read back through two stacked readers — on the bootstrap and c
      lists. (Done 2026-10-09.)
- [x] **T37.3** — The c-backend fixes: the runtime dispatch for
      untyped receivers (`emo_dynamic_builtin` + the runtime method
      table), the single evaluation of the receiver, and the Void
      statement-method emission. (Done 2026-10-09.)
- [x] **T37.4** — The docs: `docs/stdlib/bufio.md` + zh-CN mirror;
      `dune build @fmt` and `dune test` green. (Done 2026-10-09.)

Step 37 close-out (2026-10-09, on `feat/bufio`): the bufio package is
the first standard-library package whose state isBoxes inside an
ordinary class — the buffer, cursor, source, and last-read byte live
in `Box`es, and the class stays immutable around them. The step
flushed out three latent c-backend bugs in the cross-module
method-call path: the name hijack that sent `read_line` on a user
class to the socket implementation, the receiver expression evaluated up to
three times by the dispatch, and Void method statements compiled to
nothing. All three are fixed in the runtime dispatch
(`emo_dynamic_builtin`), which evaluates the receiver once and hands
instances to their vtable before any runtime method. The package rides `os`,
so its manifest declares the ocaml and c targets and widens when
those surfaces reach the other runtimes.

### Step 38 — The standard library: `sqlite3` · `plan/step-38-stdlib-sqlite3.md`

**Prereq:** Step 23 (the c target's direct C ABI) + step 24 (the embedded stdlib).
**Done when:** `require "sqlite3"` on the c target opens a database, executes DDL, prepares statements, binds int / float / text / null parameters, and reads typed columns — with no `--cclib` and no hand-compiled shim on the consumer's side; the manifest's `link` field and package-carried `.c`/`.h` sources land with it; every other target refuses (resolution's `targets` gate, or the non-c build's E5007), the interpreter at run time (E3009); `dune test` green.

- [x] **T38.1** — The manifest's `link` field: parse (strict, optional, bare names only), tests.
- [x] **T38.2** — Packages carry `.c`/`.h`: `Registry.collect_files` and `gen-stdlib-data.sh` collect and embed them; publish and checksums flow through unchanged.
- [x] **T38.3** — The build wiring: `load_deps`/`compile_inputs` collect each dependency's C sources and link libraries; the c target's cc invocation and cache key take them; the non-c gate (E5007).
- [x] **T38.4** — The `sqlite3` package: manifest, `internal/ffi.emo`, `emo_sqlite3_shim.c`, the `Database`/`Statement` public surface.
- [x] **T38.5** — `examples/sqlite3_demo` golden on the c target (gated on a sqlite3 probe, beside `cc_available`), plus the native-dependency tests in `test/emo_project`.
- [x] **T38.6** — The docs: the CHECK.md entry, README (+ zh-CN), `docs/c-backend.md` (+ zh-CN), `docs/stdlib/sqlite3.md` (+ zh-CN), the stdlib tours.

Step 38 close-out (2026-10-12, on `feat/sqlite3`): the package system learns to carry native code — a manifest gains the optional `link` field (bare library names; a flag- or path-shaped entry is E5103), and `.c`/`.h` sources ride the package tree into collection, checksums, embedding, and publishing — so the c target compiles and links a dependency's native inputs with no consumer-side flags. The `sqlite3` package is the first consumer: a `foreign def` binding over a package-carried exact-ABI shim (`emo_sqlite3_shim.c`, every signature `int64_t`/`double`/`bool`/`const char *`), c-target only, raising per the `os` convention until the error-handling migration lands.

---

## M12 — Visualization (`plot`)

T0 has landed: `plot` emits a bar chart to SVG, byte-identical on all
five hosted targets, built on the internal `Buffer`, scales/ticks, the
`Renderer` interface with `SvgRenderer`, and the declarative
`figure`/`axes`/`mark` values. The numeric substrate and the `math`
package (sequencing A) are done. This milestone finishes the design's
sequencing B–E: the rest of the T0 surface, the `Table` and channels,
the T1 dataset charts, then the terminal and PNG renderers. Design and
recorded decisions live in `docs/visualization.md`; the package's
current surface in `docs/stdlib/plot.md`; the language enablers this
work touches in `docs/temp-visual-check.md`. Out of scope (decision 9):
interactive/GUI charts, an EmoUI canvas, 3D, animation. Each step's plan
file is written when the step starts.

### Step 39 — Compiler and language enablers for plotting · `plan/step-39-plot-enablers.md`

Independent of the plot steps; each unblocks or de-risks work below.
**Done when:** the enabler's own tests pass and the affected plot code
uses it.

- [x] **T39.1** — Type `self.field` precisely (R2 in
      `docs/temp-visual-check.md`) with the emitters aligned, so a mark's
      style fields need not be stored flat. Today a native-typed field
      read on a dynamic receiver is still boxed, and the emitters key
      their native/dynamic choice on the expression's static type alone.
- [x] **T39.2** — A class method named like a runtime method is not
      shadowed (R3). `length` answers its own method on every target;
      `examples/length_method` is the regression.
- [x] **T39.3** — `math`'s opt-in native fast path: separate `*_native`
      `foreign def` functions on `c`/`ocaml` (`math.exp` pure and
      byte-identical, `math.exp_native` the pinned fast path; decision
      15), documented as target-pinned. Off the native targets the
      definitions are inert: the interpreter raises E3009 at the call
      and the emitters refuse the call.
      `examples/math_native` is the regression.
- [x] **T39.4** — File and fix the `ocaml` specialization defect the
      plot spike hit (`non-native expression in specialized body`,
      `Type_ref`), so specialized native bodies lower the same as the
      interpreter. The native emitter lowers type values, enum members,
      field reads, and def values (the last when its def specializes,
      with the wrappers in the native rec group); container literals
      leave the predicate, so those bodies stay dynamic.
      `examples/specialize_shapes` is the regression.

### Step 40 — T0 completion: continuous axes and the remaining marks

**Prereq:** Step 39 optional (T39.1 eases the style classes).
**Done when:** `examples/plot_demo` grows line/scatter/area/histogram
panels and stays byte-identical on all five targets; `dune test` green.

- [x] **T40.1** — Extend the `Mark` interface beyond the categorical
      `y_max`/`bands`/`x_labels` (continuous x and y ranges, `y_min`, the
      point/line primitives a `DrawContext` needs), keeping `Bar` as its
      first implementation.
- [x] **T40.2** — `plot.mark.line` and `LineStyle`.
- [x] **T40.3** — `plot.mark.scatter` and `ScatterStyle`.
- [x] **T40.4** — `plot.mark.area` and `AreaStyle`.
- [x] **T40.5** — `plot.mark.hist` (bin counting) and `HistStyle`.
- [x] **T40.6** — `Axes` draw: a continuous x scale, the y domain
      inferred from every mark's range, and per-mark dispatch (replacing
      today's bar-only `first_labels`/`bands` path).
- [x] **T40.7** — Demos and goldens: one figure per new mark, all five
      targets byte-for-byte.

### Step 41 — Figure fidelity: scales, domains, legend, grid, themes, color

**Prereq:** Steps 39–40.
**Done when:** every field the T0 values already declare is rendered —
log scales, domains, grid, legend, theme — and `DrawContext` is typed
against the `Renderer` interface, not `SvgRenderer`.

- [x] **T41.1** — `Scale.log`: log axes with correct tick placement and
      formatting.
- [x] **T41.2** — `Domain.auto` / `Domain.fixed`: domain fields on
      `Axes` and inference from the marks (decision 19).
- [x] **T41.3** — Legend rendering for `with_legend` (decision 20's
      draw-order rule; one shared legend under faceting, T41.7).
- [x] **T41.4** — Grid rendering from `Figure.grid`, driven by the
      theme's grid style.
- [x] **T41.5** — `Theme` as a value on `Figure` (background and
      foreground, the grid/axis/title/label styles, a palette, a
      colormap, spacing, the default size; decision 24) with
      `with_theme`.
- [x] **T41.6** — `plot.rgb` validating the 0–255 range and draw-time
      validation of raw triples (decision 21), on the T41.5 colormaps'
      `Float64` interpolation; the `color` channel's column-kind
      dispatch rides T42.3's channels (decision 24).
- [x] **T41.7** — The figure half of faceting (decision 23): the
      `rows × cols` panel grid separated by the theme spacing, blank
      cells for the missing tail, `Share.all` drawing every panel on
      the union domain, and the title above the grid; sorted levels,
      per-panel level labels, and the one shared legend ride the chart
      layer (T43.6, through T42.3's `facet_*` channels).
- [x] **T41.8** — Decouple `DrawContext` from the concrete
      `SvgRenderer`: type it against the `internal` `Renderer` interface
      so a terminal or raster renderer can join (the prerequisite for
      Steps 44–45).

### Step 42 — Table and channels

**Prereq:** Step 40.
**Done when:** `plot.table` / `plot.table_missing` build a validated
`Table`, and the chart layer resolves channels through the vocabulary.

- [x] **T42.1** — `enum Presence { present, absent }` and the parallel
      `Map[String, Array[Presence]]` for missing numbers, with the
      statistics skipping `absent` entries (decision 25). The type is
      public at the `plot` root; a numeric column is read through
      `plot.observed`, which drops the `absent`
      entries and raises when a presence array disagrees with its
      values. Verified on all six paths — interp, c, ocaml, ts, wasm,
      beam — with the skip and the mismatch raise byte-identical.
      (`observed` landed as `internal.stats.observed`; the 2026-10-20
      refactor moved it to the root so the statistics module references
      nothing from the package root — the root calls in, and one
      direction is all a module graph may bend.)
- [x] **T42.2** — `plot.table(numbers, labels)` and
      `plot.table_missing(numbers, presence, labels)`: column-oriented
      `Table`, shape violations raising (decision 4/10). The builders
      share one shape check — no name claimed by both kinds, one length
      across every column, a presence column beside each numeric column
      with no strays — and the accessors check the column's kind
      (`number` / `presence` / `label`, beside the `rows` count).
      Verified on all six paths — interp, c, ocaml, ts, wasm, beam —
      with the demo golden byte-identical (`plot_demo` grew a table
      section) and eight shape violations raising the same message on
      every path. Printing the presence columns exposed enum `to_str`
      rendering the qualified name on `ts` and having no rendering at
      all on `wasm`/`beam`; all three now render the bare member — the
      interpreter's rule — so the golden holds byte-for-byte.
- [x] **T42.3** — Channels `Map[String, String]` (decision 16): the
      vocabulary `x`/`y`/`color`/`size`/`marker`/`dash`/`facet_row`/`facet_col`,
      unknown channels an error, each family reading only the channels it
      supports — carrying T41.6's column-kind `color` dispatch through
      the theme's palette and colormap (decision 24). The checks live in
      `internal/channels.emo` — the vocabulary and the per-family reads
      (relational full set; distributions and categorical without the
      point aesthetics; matrix facets only), plus the byte-order
      comparison and `sorted_levels` the categorical color reads the
      palette through, since a `String` answers `==` but not `<`. The
      dispatch is public at the root as `plot.channel_colors(table,
      name, theme)`: a label column through the palette by the level's
      sorted position, a number column normalized over its observed span
      through the colormap (a constant column at the low end), absent
      slots keeping their place at the low end. Verified on all six
      paths — interp, c, ocaml, ts, wasm, beam — with the happy outputs
      and five raise messages byte-identical: unknown channel, two family
      violations, unknown column, all-absent color column. The demo grew
      a channels section; the chart functions that take the mapping
      arrive with Step 43. (The 2026-10-20 chart layer replaced the
      per-family reads with a per-chart check — each chart carries its
      own supported list, since the charts of one family read different
      aesthetics — so the four family wrappers are gone and the
      unsupported-channel message names the chart.)

### Step 43 — T1 dataset charts

**Prereq:** Steps 41–42.
**Done when:** every `plot.*` chart in decision 17 is implemented on the
T0 marks, with fixtures byte-identical on all five targets.

- [x] **T43.1** — Statistics: descriptives, binning, KDE, ECDF, box
      statistics, and OLS with a confidence band; `normal_quantile` and
      `normal_cdf` internal to `plot` (decision 13). Landed in
      `internal/stats.emo`: `sort` (a bottom-up merge sort through the
      ArrayBuilder), `quantile`, `describe`, `histogram_bins` (the
      `hist` mark's own `bin_index`, so a column and a mark built from
      it always agree), `ecdf`, `box_stats` (Tukey whiskers and fliers),
      `ols` with `ols_band` (the large-sample band, its critical value
      the Acklam `normal_quantile`), `normal_cdf` (Zelen–Severo), and
      the `exp` behind the KDE, carried internal by the
      `scale.log10` precedent so `plot` stays dependency-free. Verified
      on all six paths — interp, c, ocaml, ts, wasm, beam — with
      hand-checked values and the raise paths byte-identical.
- [x] **T43.2** — Relational: `plot.scatter`, `plot.line`, `plot.reg`.
      Each chart reads a `Table` through the channel mapping and answers
      a whole `Figure` — one axes, labelled from the channel's column
      names, carrying the marks the mapping builds. `x` and `y` are
      required and numeric; rows where either is absent drop out, and a
      chart with no drawable row raises. The reads are per chart —
      scatter `color`/`size`/`marker`, line `color`/`marker`/`dash`, reg
      only the pair — and a channel the chart does not read raises. The
      `color` dispatch rides T42.3's: a label column splits the rows
      into one series per sorted level (palette color, the level in the
      legend, a level two grouping channels share named once), a number
      column colors a scatter's points through the colormap — which
      grew the `Scatter` mark per-point color and size overrides, the
      `size` channel's span normalization reading the same way (half to
      one and a half times the style's size). Grouping channels read
      label columns and pick each level's marker (the six shapes,
      wrapping) and dash (the four patterns); groups form over the
      channels' combined levels, ordered by their sorted positions. The
      line draws each series in the rows' own order — row order is
      intent. `reg` draws the points, the OLS line (`fit`), and the 95%
      confidence band under them first, sampled over the kept span at
      fifty grid points through `ols_band` — which gave `plot.mark` its
      sixth mark, `band` (one polygon, upper curve forward and lower
      back, the factory checking matched lengths and ascending xs). The
      facet channels pass the check and raise until the chart layer's
      panel splitting lands. Verified on all six paths — interp, c,
      ocaml, ts, wasm, beam — with the demo golden byte-identical
      (`plot_demo` grew a relational section: a grouped scatter with the
      size channel, a two-level line with the dash channel, a reg with
      its band) and thirteen raise messages byte-identical.
- [x] **T43.3** — Distributions: `plot.hist`, `plot.kde`, `plot.ecdf`,
      `plot.box`, `plot.violin`. The first three read one numeric
      column — required through the new single-`x` read — and draw one
      mark per `color` level through the T43.2 grouping, the levels in
      their sorted order: `hist` counts into equal-width bins spanning
      the kept values' shared range, the square root of the count of
      them, so the levels compare on one grid; `kde` draws one density
      curve per level, the bandwidth Silverman's rule answers (new
      `internal.stats.silverman`: 0.9 × min(σ, IQR/1.34) × n^(−1/5),
      the fifth root through the carried `exp` and `scale.log10`, a
      column whose values do not spread raising); `ecdf` draws the
      staircase, each value's cumulative proportion stepping at the
      value. `box` and `violin` sit on the `x` column's levels — a
      number column there raises — and summarize each level's `y`
      through the Tukey statistics: `box` draws the whiskers, the
      quartile box, the median line, and the fliers, `violin` a
      mirrored density per level over the same Silverman bandwidth and
      grid shape, the densities normalized across the row — a level
      whose values do not spread raises naming the level. Both gave
      `plot.mark` two marks: `BoxPlot` (named for the language's `Box`)
      and `Violin`, flat parallel arrays over the categorical face, the
      factories checking matched lengths. The `color` channel is not
      read by `box` or `violin` yet. Verified on all six paths —
      interp, c, ocaml, ts, wasm, beam — with the demo golden
      byte-identical (`plot_demo` grew a distribution section: a
      two-class score table through all five charts) and ten raise
      messages byte-identical. Landing the demo exposed two beam
      runtime bugs, both fixed in the same commit: `emo_g6_sci` trimmed
      with `string:trim(binary, trailing, binary)` — the third argument
      is a character list, so any float whose %g form needs scientific
      notation died in a function_clause (the KDE's small densities are
      the first figures to draw one) — and the %g decimal tail kept
      Erlang `compact`'s final `.0` where the interpreter's %g says
      `204`, now stripped.
- [x] **T43.4** — Categorical: `plot.bar`, `plot.count`, `plot.strip`,
      `plot.point`. All four sit on the `x` column's levels — a number
      column there raises. `bar` and `point` need the `y` channel and
      aggregate each level's observed values by their mean — one bar
      per level, and one stamped, connected mean walking the bands in
      their sorted order. `count` needs no `y` at all: one bar per
      level, its height the number of rows the level carries. `strip`
      draws the raw points at their bands' centers, one mark per
      `color` level through the T43.2 grouping — the points unjittered
      and in the rows' own order, so overlapping points are the data.
      Two marks joined `plot.mark`: `Strip` (a scatter that declares
      the bands, styled with the existing `ScatterStyle`) and `Point`
      (a connected mean row, styled with the existing `LineStyle` plus
      a `point_style` default) — the categorical faces of the two T0
      marks, so the axis labels the levels they draw on. `bar`, `count`,
      and `point` do not read the `color` channel yet. Verified on all
      six paths — interp, c, ocaml, ts, wasm, beam — with the demo
      golden byte-identical (`plot_demo` grew a categorical section: a
      two-region sales table through all four charts) and eight raise
      messages byte-identical.
- [x] **T43.5** — Matrix: `plot.heatmap`, `plot.clustermap`. Both read
      the whole table as a matrix — the numeric columns the cells'
      columns, the rows the cells' rows, exactly one label column
      naming the rows (none or several number them from 1) — and the
      mapping carries only the facet channels, so it is normally empty.
      Each cell takes its color where its value sits on the cells' own
      span through the theme colormap, a constant matrix at the low end.
      `clustermap` reorders the rows and the columns by average-linkage
      clustering over their euclidean distances (new
      `internal.stats.cluster_order`: the base distance matrix, then
      merges of the closest alive pair by mean pairwise distance, each
      merge ordering its halves by their smallest leaf, the dead flags
      a `Map` since arrays do not index-assign); the trees are not
      drawn, the order is the clustering. The `Heatmap` mark joined
      `plot.mark` — pre-colored cells row major, no style, out of the
      legend — and the `Mark` interface grew `y_labels`, the categorical
      y face: `draw_axes` lets a mark carrying row names own the y
      annotation at its band centers, the way `x_labels` owns the x
      one, so a heatmap ticks names on both axes while every other mark
      answers an empty list. The charts pin the axes domains to the
      exact cell counts through `with_x_domain`/`with_y_domain`, so no
      nice ceiling leaves a dead band. Verified on all six paths —
      interp, c, ocaml, ts, wasm, beam — with the demo golden
      byte-identical (`plot_demo` grew a matrix section: a 4 × 4
      correlation table as heatmap and clustermap) and five raise
      messages byte-identical.
- [x] **T43.6** — Apply faceting, palettes, and themes at the chart
      layer; demos and byte-identical goldens — carrying T41.7's level
      splitting, per-panel level labels, and the one shared legend.
      Every chart now reads the `facet_row` and `facet_col` channels:
      each names a label column, and its sorted levels split the chart
      into panels — rows × cols, one channel alone a strip — every cell
      drawing the chart over the rows it holds, so a level combination
      with no rows stays blank, and the facet columns stay out of a
      heatmap's row-name rule. The panels compare: the figure keeps
      `Share.all` with blank cells out of the union (the matrix charts
      keep their own cell grids under `Share.none`); each panel is
      titled from its levels — `time = Lunch`, both facets joined —
      through the new `Axes.title` (`with_title`); the axis labels sit
      at the outer edge only; and the panels' legends give way to one
      legend for the whole figure at its right, once by label, through
      the new `Figure.shared_legend` (`with_shared_legend`), which also
      takes that column out of the grid's width. The chart layer's
      palette and colormap resolution is unchanged — group colors
      resolve through the theme palette by the level's sorted position
      and numeric colors through the colormap at build time, so the
      same level is the same color in every panel. Each chart also
      answers its single-panel form as `<chart>_axes` — fourteen public
      cores over a `panel_axes` kind dispatch the faceted assembler
      loops through — with `rows_of` the sub-table a cell draws. The
      landing exposed one more beam gap, fixed in the same commit:
      indexing a value whose static type is dynamic (an array that
      started as a bare `[]`) fell to `lists:nth` even when the value
      was a tuple — `emo_index` now dispatches on `is_tuple` at
      runtime. `refuse_facets` is gone. Verified on all six paths —
      interp, c, ocaml, ts, wasm, beam — with the demo golden
      byte-identical (`plot_demo` grew three faceted figures: a 1 × 2
      scatter with the shared legend, a 2 × 2 with a blank cell, and a
      2 × 1 histogram) and five probe answers byte-identical.

### Step 44 — Terminal renderer

**Prereq:** Step 41 (T41.8's `Renderer` decoupling).
**Done when:** a figure renders to a terminal through the same Layer 0
value graph, proving the contract is format-agnostic.

- [x] **T44.1** — A Unicode `Renderer` implementation (blocks or braille
      for marks, text labels) behind the `internal` `Renderer`
      interface. `internal/term.emo`'s `TermRenderer` answers the same
      six calls as `SvgRenderer` onto a grid of braille cells: four
      figure pixels make a column and eight a row, so a cell is two dots
      by four with a terminal glyph's aspect, and the default 640 × 480
      figure prints as 160 columns by 60 rows. Color is one ink — every
      color becomes a level from 0 to 8, how many of a cell's eight dots
      it lights, from its Rec. 601 luminance contrast against the paper,
      the figure background the renderer is built with, all in integer
      arithmetic. The fills (`rect`, `circle`, and `polygon`, the last a
      scanline even-odd fill sampled at the dot centers) halftone at
      their level through one dispersed dot order and clear the dots the
      level leaves dark, so a paper-colored fill paints paper — a legend
      panel covers what is under it, and the theme's own background rect
      is a no-op; a line is one dot wide through Bresenham, solid from
      level 2, every fourth dot at level 1, cleared at level 0, with a
      dash pattern three dots on and two off; text lands as characters
      on the row holding the middle of its glyphs, from its anchor,
      always over the dots in its cells, split by UTF-8 sequence; and
      anything off the grid is clipped. The figure walk left `svg()` for
      a renderer-agnostic `render(r, fig)` — `svg` and the new
      `plot.terminal(fig)` differ only in the renderer they construct —
      and the SVG goldens stayed byte-identical. Two target gaps
      surfaced and were cleared on the package side: the `c` target
      refuses the bitwise operators on a dynamic word (a byte read back
      from a `Bytes` field), so the cell update is arithmetic —
      `(cur / bit) % 2` tests the bit and `cur ± bit` flips it; and the
      `typescript` runtime's `String.length()` counts UTF-16 code units
      where every other path counts UTF-8 bytes, which overran the
      `Buffer` the moment it carried three-byte braille — `Buffer.to_string`
      now sums the encoded chunks' byte lengths, and the divergence
      itself is recorded in `CHECK.md`. Verified on all six paths —
      interp, c, ocaml, ts, wasm, beam — with four probes byte-identical
      (a bar figure, a two-line figure with a dashed legend entry, the
      heatmap, and the dark theme), and `dune test` green.
- [x] **T44.2** — Wire it through a CLI/demo path and test that the same
      figure renders through SVG and the terminal. `examples/plot_demo`
      now holds four of its figures as values — the bar figure, the
      two-line figure with its dashed legend entry, the regression chart
      with its band and points, and the heatmap — prints each as SVG
      where it always did, and prints the same four values again through
      `plot.terminal` at the end, so one `Figure` value reaches both
      renderers and both outputs sit in one golden: `expected.txt` grew
      by the four terminal renders (244 lines) with its SVG prefix
      byte-identical, and the standing golden suites pin it on all six
      paths — interp and the `c`, `ocaml`, `typescript`, `wasm`, and
      `beam` builds — byte-for-byte (`dune test` green, 0 failures). The
      four figures between them exercise every primitive the renderers
      answer: `rect` fills and the frame's lines, the dashed line and the
      legend panel, the band `polygon` with `circle` markers, and the
      heatmap's cells across the ink levels. `docs/stdlib/plot.md` (and
      its `zh-CN` mirror) gained `terminal` in the surface, a terminal
      paragraph under Output — the cell geometry, `with_size(320.0, 240.0)`
      for an 80-column terminal, the ink rule, what does not render — the
      worked example printing both, and the landed list naming the second
      renderer; `docs/visualization.md`'s Layer 0 records the landing;
      `plan/README.md` marks Step 44 done. Step 44's exit holds: a figure
      renders to a terminal through the same Layer 0 value graph, and the
      contract is format-agnostic.

### Step 45 — PNG renderer

**Prereq:** Step 44.
**Done when:** `plot.png(fig)` emits a valid PNG on all five targets,
from the same value graph, with no host image library.

- [x] **T45.1** — Pure-Emo DEFLATE with stored blocks. `internal/png.emo`
      opens the PNG backend's byte level with `deflate_stored`: the raw
      DEFLATE stream over an `Array[Int64]` of bytes, one block per 65535
      bytes behind its five-byte header — BFINAL/BTYPE, LEN, and the
      one's complement of LEN — and a single empty final block for empty
      input. The byte arrays are `Array[Int64]` rather than `Bytes`: an
      element read stays a static Int64, and the checksums and the
      Huffman packer ahead need bitwise work the dynamic world refuses
      (the term renderer's arithmetic-bit rule). Verified against an
      external decompressor and across the paths at once: seven probes —
      empty, one byte, a 255-byte run, the 256, 65535, and 65541
      boundaries, and a varied 70000 — decompress byte-identical to
      their inputs under Python's zlib on the interpreter, and the c,
      ocaml, typescript, wasm, and beam builds print the probe's 201,640
      lines byte-identical to it (`dune test` green).
- [ ] **T45.2** — Fixed-Huffman DEFLATE, CRC32, and Adler-32.
- [ ] **T45.3** — A scanline polygon/line rasterizer with supersampling.
- [ ] **T45.4** — Text through the Hershey stroke font.
- [ ] **T45.5** — `plot.png(fig)`, its demo, and goldens.

---

## M13 — Unit testing

The testing surface settled on `feat/unit-test` (2026-10-12): a `test/`
directory at the project root — every `.emo` file under it is a test
file, every top-level `def test_*` a test — and assertions as builtins
(`expect_equal` / `expect_true` / `expect_false` / `expect_fail`) whose
failure raises the one `Exception` class, caught per test by the OCaml
runner (Emo has no catch; the runner is the only place a raise can be
trapped). No new syntax constructs. Work began on this branch: partial
implementations of T46.1–T46.5 and T46.7 sit in the tree unreviewed —
each is finished against its task definition below, not merged as
found.

### Step 46 — Unit test framework: `emo test` and the `expect_*` builtins

**Prereq:** none beyond develop.
**Done when:** `emo test` in a project with a `test/` directory runs
every `def test_*`, reporting pass/fail/error per test with captured
output and exiting 0/1/65 by the family; the `expect_*` builtins raise
real `Exception`s in the interpreter and refuse honestly on compiled
targets; `emo new` scaffolds a passing test; `dune test` green.

- [x] **T46.1** — `expect_*` builtins in the interpreter: registered
      in `global_env`, dispatched in `apply_builtin`, raising via an
      `expect_raise` helper on the `net_raise` precedent (a real
      `Exception` instance; the message names the assertion, and
      `expect_equal` renders both values); arity E3007 / type E3001
      follow the existing builtin style. Eval tests: pass and fail
      paths, message rendering, the error codes.
- [x] **T46.2** — Checker + IR surface: `expect_*` signatures in the
      checker's `empty_env` (Unknown value params, Void results — the
      `println` pattern) and the four `expect_*` names in `is_builtin`'s
      bare-name list, so a compiled program naming one meets the
      backend's standard honest refusal (riscv refuses every builtin
      generically; c / ocaml / ts / wasm / beam gain refusal arms
      wherever their builtin dispatch is exhaustive). Checker tests
      for the signatures.
- [x] **T46.3** — `reset_output` in the evaluator: the default sink
      named and restorable after `set_output` redirection (the
      runner's per-test capture).
- [x] **T46.4** — Runner core in `emo_project`: `prepare_root`
      (discovery at the working directory, the manifest search from
      there), the `test_outcome` / `test_result` types, and
      `run_tests` — the whole tree checked first (`Static_errors`
      out), test modules by the `test/` first segment, `def test_*`
      collected from the module env (`ArrowBlock` only; a
      parameterized `test_*` is a collection error, never a call),
      each test in its own `Emo_sched_det.run` with output captured
      and restored; `Emo_raise` fails the test, `Emo_eval.Error`
      errors it. Project tests: mixed outcomes, the collection error,
      no `test/` directory, a static error in a test module.
- [x] **T46.5** — `emo test` subcommand: reporting (one line per
      test, the rendered diagnostic and captured output on failure,
      the summary line), exit codes 0/1/65, registration in the root
      command group, help text naming the convention. CLI tests: a
      passing project and a failing one, end-to-end.
- [x] **T46.6** — `emo new` scaffolds `test/greet.emo` with a passing
      `test_greet` (builtins need no manifest dep) and the hint
      mentions `emo test`; scaffold goldens updated.
- [x] **T46.7** — `examples/test_demo/`: a small module, passing
      tests under `test/`, `expected.txt` for the golden harness;
      reconcile the per-target golden builds (a compiled build leaves
      every `test/` module out, so the example's tests cannot reach a
      backend that refuses `expect_*`; product code still does).
- [x] **T46.8** — Docs: README gains the Testing section (the
      convention, the command, the builtins, a raise failing only the
      one test), mirrored in `docs/zh-CN/README.zh-CN.md`.

## M14 — CSV read/write

The `csv` package reads and writes RFC 4180 records — UTF-8 only —
from the bundled registry like the other format packages. It needs no
per-target runtime work: bytes and arrays carry the whole surface, so
the golden rides all five target lists.

### Step 47 — The standard library: `csv` · `plan/step-47-stdlib-csv.md`

**Prereq:** Step 35 (base64 — the byte-scanner discipline and the
all-five-golden shape) and step 31 (json — the format-package
conventions).
**Done when:** `require "csv"` decodes RFC 4180 text into
`Array[Array[String]]` and encodes it back, byte-identical on all five
targets — strict quoting, CRLF/LF/CR records, a leading BOM ignored,
every byte validated as UTF-8, offset-bearing errors, and a one-byte
delimiter pair for TSV; goldens on all five paths; `dune test` green.

- [x] **T47.1** — The package: `stdlib/registry/csv/0.1.0` (manifest
      over all five targets, `csv.emo` with the record model, the
      strict decoder, the canonical encoder, the UTF-8 validator, the
      delimiter pair).
- [x] **T47.2** — The goldens: `examples/csv_demo` on the bootstrap,
      c, typescript, wasm, and beam lists; `examples/csv_edge` on the
      bootstrap list — every record shape, the malformed matrix, the
      UTF-8 boundaries, the BOM, and the encoder's quoting rule.
- [x] **T47.3** — The TypeScript UTF-8 fix: the runtime's decoder
      rejected 3-byte lead bytes E8–EF (`b < 0xe8`), so U+8000–U+FFFF
      decoded as U+FFFD; `csv_demo` flushed it.
- [x] **T47.4** — The wasm `!` fix: unary `!` read the `$vbool` field
      without the `ref.cast` `&&`/`||` already emitted, so any module
      using `!` failed WebAssembly validation; `bad_utf8`'s
      `!continuation(…)` flushed it.
- [x] **T47.5** — The docs: `docs/stdlib/csv.md` and its zh-CN
      mirror; the stdlib tour and README package lists.

## M15 — EmoUI

EmoUI is the declarative UI framework the language's syntax was shaped
to serve: UIs composed as trees of components that render from explicit
state, with no template language — the UI is plain Emo. One shared
application module (components, `update`, `view`, written against the
portable `ui` core) renders on a terminal, a server-rendered page, a
macOS/AppKit window, and a GTK 4 window, with the browser DOM following
its own runtime path; each platform may ship its own component library,
but the way components are called and composed is identical. The design
and its evidence are `docs/emo-ui.md`, `docs/emo-ui-check.md`,
`spike/components`, and `spike/emo-ui-probe`; the EmoUI packages live in
this repository under `projects/emo-ui/` (`CHECK.md`, the in-tree
project layout), while the compiler-side gates the design found (the
native packaging mechanism and the browser runtime path) and the
terminal-input package also land in the tree. The `c` target's long-running memory is the fourth
thing a UI forces and the one it does not get for free: the 2026-10-14
arena-scope spike settled that the cheap fix does not exist, so it is
scheduled separately (**M16**, step 49) and the native backends are
demo scale until it lands — the limit documented, not papered over.
(It landed 2026-10-17; the demo-scale note is retired — see M16.)

### Step 48 — EmoUI · `plan/step-48-emo-ui.md`

**Prereq:** Step 23 (the `c` target and `foreign def`) and step 25
(target independence); the cross-module type names (2026-10-14) and the
C→Emo callback contract (2026-10-11) are already in `develop`.
**Done when:** the shared portable app module answers byte-for-byte on
the debug and SSR backends across all five hosted targets and drives the
TUI, macOS, GTK 4, and browser backends through thin per-platform
entries; the composition syntax is identical on every backend; the
native packaging mechanism is settled so a native UI backend is a
`require` rather than a hand-copied shim build; no language change was
required.

**Decisions settled here (2026-10-14; full text in `docs/emo-ui.md`):**

1. EmoUI is a **project of its own**, not a standard-library package; a
   later split moving the portable core and the pure-Emo backends into
   the stdlib is possible once stable, not v1. *(Revised 2026-10-15 by
   decision 11: hosted in this repository under `projects/emo-ui/`, not
   in a separate repository created up front. It remains not a stdlib
   package.)*
2. The tree type is a **multi-module `ui.Node`** (interface spine plus
   concrete classes with typed props), not a stringly-tagged class and
   not one class per platform with no core.
3. **Children are an explicit `Array[Node]`**; trailing blocks are for
   callbacks and iteration and must `return` their value — no implicit
   child collection, so the README's illustrative tree is revised.
4. **Layout is a portable vocabulary mapped to native layout** (CSS
   flexbox / GTK boxes / AppKit stack views / a TUI cell grid), not a
   shared Emo layout engine; the TUI keeps a small Emo box model.
5. **Style is a typed value** with a factory and `with_*` copies — no
   stringly map and no default parameters (E4009).
6. **State is Elm** over explicit primitives; events are typed messages
   registered Emo-side and exposed to the backend as `Int64` tags.
7. **The backend is an Emo interface** (`mount`/`patch`/`run`); the
   nine-verb `ui_*` contract is the native implementation detail.
8. **Platform libraries share convergent names**; platform-specific
   components carry the platform package's name at the call site.
9. **Sequencing: TUI and SSR first, native toolkits next, the browser
   DOM last.**
10. **No new syntax**; a checked block/function type is the one language
    ask worth weighing later, and it is not a gate.
11. **The EmoUI packages live in this repository under
    `projects/emo-ui/`** (settled 2026-10-15, `CHECK.md`). The directory
    is named for the eventual repository so `git subtree split` can
    extract it later with its history; `projects/emo-os/` and
    `projects/emo-shell/` are reserved by the same decision and stay
    empty until scheduled. Terminal input (T48.5) settles with it as a
    standard-library package in the `sqlite3` shape.

- [x] **T48.1** — The portable `ui` core package: the `Node` spine and
      primitives, the typed `Style` with `with_*` copies, the layout
      vocabulary, and the `Backend` interface. Pure Emo, all five hosted
      targets — which makes the two codegen defects the A/B spelling
      spike found part of this task. **Both landed 2026-10-15:** the `c`
      class metadata tables moved out of the `<cname>__<member>`
      namespace a method's symbol occupies (`vt_<cname>_fields` /
      `vt_<cname>_methods`, joining `vt_<cname>` and `iface_<name>`), and
      the `ocaml` native `String` `+` gained its `= Emo_check.String`
      branch emitting `(^)` in `emit_native_expr`; the two fixtures under
      `spike/emo-ui-spelling/codegen/` are the regression, and its
      `check.sh` asserts their build and their run. **The package landed
      2026-10-15** as `projects/emo-ui/` — `ui.emo` beside its own
      `package.emo` (`emo/ui`, declaring all five hosted targets) —
      and it settles the children question the spike left to it:
      children stay an explicit `Array[Node]`, and a list that is not
      known until it is walked is built with `ArrayBuilder`, not with an
      Emo `Array.append` loop. `projects/emo-ui/check.sh` is the
      package's gate. Writing it turned up one more toolchain defect,
      fixed here: `emo emoji build` named each target's output
      `emoji-<target>`, a stem the `beam` target refuses as a module
      name, so the pre-publish gate could not pass for any package
      declaring all five.
- [x] **T48.2** — The Elm loop: `App` (model/`update`/`view`), the
      `ui.on(msg)` tag registry and `ui.dispatch(tag)`, and
      `ui.run(view, update, model, backend)`; tag round-trip tests and a
      retained `patch` versus a full rebuild. **Landed 2026-10-15** as
      `projects/emo-ui/ui.emo` plus its `test.emo` (fourteen assertions,
      run by `./check.sh`). The tag table is a `Registry` object the loop
      owns and hands to `view` rather than the module-level table Layer 5
      sketched, because a module-level `const` re-runs its initializer on
      every read on the compiled targets and a module-level `var` is
      `ocaml`-only (`CHECK.md`). The loop compiles on `ocaml`,
      `typescript` and `beam`; `c` refuses the bare defs `ui.run` takes
      and `wasm` the two-argument dynamic call `update` needs — the same
      loop with its two functions behind a `Handler` interface builds on
      all five (`CHECK.md`, `projects/emo-ui/probe/`).
- [x] **T48.3** — The headless `debug` backend: the tree rendered to a
      stable text form, the byte-identical golden harness. **Landed
      2026-10-15** as `projects/emo-ui/debug.emo` (a module of the core's
      own package, so the core's test can use it) plus
      `projects/emo-ui/golden/` (a package in the consumer's position,
      `deps { "emo/ui" = "0.1.0" }`, reached through a registry
      `./check.sh` stages). The text form is one node per line, two
      spaces per level, props then a style summary in a fixed field
      order; `Debug` implements `Backend` over it by logging every tree
      the loop hands it, and its `run()` drives nothing — headless means
      no input source, so events are stepped by hand. `golden/main.emo`
      is one screen carrying every primitive, both `w=`/`h=` branches,
      all four `Align` values, an empty prop and nested containers;
      `expected.txt` is the interpreter's output, identical on `ocaml`,
      `c`, `typescript` and `beam`, while `wasm` cannot lower the core
      (the loop's shape, T48.2). Two silent cross-target divergences fell
      out and are recorded with minimal pairs (`CHECK.md`): operands were
      evaluated in the target's order, `ocaml`'s being the reverse of the
      others' — fixed 2026-10-17, left to right on every target — and an
      enum does not interpolate to the same bytes on `typescript` or at
      all on `beam` (`probe/eval_order`, `probe/enum_print`).
- [x] **T48.4** — `ui-tui`: the cell-grid layout (the small Emo box
      model) and ANSI painting; a scripted-input golden. **Landed
      2026-10-16** as `projects/emo-ui/tui/` (package `emo/ui_tui`:
      `ui_tui.emo` and `test.emo`), declaring the four hosted targets
      that can write stdout — `wasm`'s runtime has no `printf`, so the
      terminal backend is not a `wasm` package. The box model is the
      core's `Style` measured in cells: a column stacks, a row lines up,
      and `padding`, `gap`, `align`, `grow`, `width` and `height` place
      every child; `screen(root, w, h)` returns the grid as
      `Array[String]` so the arithmetic is testable without bytes, and
      `paint(root, w, h)` writes the frame as ANSI (clear, home, one row
      per line), the escape byte coming through `printf("%c", [27])`
      because a string literal's escapes are the minimal set and 0x1b is
      not one of them. `Tui` implements `ui.Backend` over that, and
      `Input`/`Script` are the scripted event source: `run()` pulls tags
      from the input and hands them to the loop's sink until the input
      says there are no more, which is what makes the golden terminal-
      free (T48.5 replaces the source, not the seam). `tui/golden/` is a
      consumer of both packages (`deps` on `emo/ui` and `emo/ui_tui`):
      one screen carrying a row with a centered shorter child, a scroll
      with a growing spacer, a fixed-width text input and two buttons,
      driven by a script that clicks Add, Add, Sub. `expected.txt` is
      the interpreter's output, identical on `ocaml`, `typescript` and
      `beam`; `c` compiles the backend and refuses the golden's loop
      shape (`Global`), which is T48.2's open decision now three targets
      deep rather than two. `tui/check.sh` is the gate (the package
      type-checks, thirteen assertions run, the four declared targets
      build, `wasm`'s `printf` refusal is pinned, and the golden's bytes
      are compared). Two `beam` defects the golden forced are fixed here,
      both recorded in `CHECK.md`: a bare def as a `Block` was emitted as
      a remote fun to a non-exported function, which `erlc` accepted but
      the loader left uncallable (`main/0` raised `undef`), and a `case`
      inside a loop body that rebound an outer `var` never threaded the
      rebinding out, so a `while` whose exit a branch set never ended.
      `test/emo_cli`'s `beam_block` and `beam_var` groups are the
      regressions. `examples/tui_menu/` is the usage demo — the same
      pattern with a four-row menu and a longer script — and the same
      gate checks it on every target it declares.
- [x] **T48.5** — Terminal input: raw mode and key events, as a
      **standard-library package in the `sqlite3` shape** —
      package-carried `.c`/`.h` reached through `foreign def`, gated by
      the manifest's `targets` — rather than a UI-framework or
      compiler-side artifact (settled 2026-10-15, `CHECK.md`); line mode
      first. **Landed 2026-10-18** as `stdlib/registry/term/0.1.0/`
      (package `term`, `targets = ["c"]`): `term.emo` is the surface,
      `internal/ffi.emo` the `foreign def`s, and `emo_term_shim.c` the
      C side of the exact ABI, checked against the generated
      `emo_defs.h` at compile time. `read_line` keeps its terminator,
      so a blank line and the end of input are different answers;
      `enable_raw` and `restore` save and put back the termios setting,
      and the exit path restores it too; `read_key` answers a `Key`
      member plus a code (a Unicode scalar for `char`, `0`–`26` for
      `ctrl`) and decodes the arrow, Home/End, Insert/Delete, Page
      Up/Page Down, F1–F12, Shift-Tab and Alt sequences, with a lone
      Esc settled after 50 ms. `size` and `is_tty` answer from the
      terminal driver. Scalar and String returns keep the generated
      struct names out of the ABI; the tuples are shaped in Emo. A
      plain `require` reaches the package — the embedded registry
      carries it — and the interpreter refuses it with E3009.
      `test/emo_cli`'s `term` group carries a pipe through line mode,
      key decoding, and the failure values; `examples/term_demo` is the
      runnable demo and rides in `c_goldens`. Raw mode is the one path
      a pipe cannot carry: the group pins its refusal off a tty, and
      the mode itself was checked over a pty while the package was
      built. Reference: `docs/stdlib/term.md`.
- [x] **T48.6** — `ui-ssr`: the node tree to HTML plus a stylesheet,
      byte-identical on all five hosted targets; forms and links as the
      interaction model. **Landed 2026-10-18** as
      `projects/emo-ui/ssr/` (package `emo/ui_ssr`: `ui_ssr.emo` and
      `test.emo`), declaring all five hosted targets. The renderer is
      pure Emo and names no host: three entry points — `page(title,
      root)` for a whole document, `fragment(root)` for a region a
      browser swaps in, `stylesheet(root)` for the CSS alone — walk the
      same pre-order tree, so the classes a page's markup carries are
      the ones its stylesheet defines. A node's class comes from
      interning on its base declarations and its `Style`
      (`e0`, `e1`, … in document order), which writes an equal style
      once and still keeps a `row` and a `column` apart; every prop
      reaching markup is escaped byte by byte through `substring(i, 1)`,
      so a multi-byte character rides through unchanged. The renderer
      adds the three nodes only a server round trip has anywhere to put
      — `form(action, children, style)`, `link(href, label, style)`,
      `field(name, value, style)` — while a `ui.button` inside a form
      submits its event tag as `event` and the core's `text_input`
      stays a read-only view of the model. `Ssr` implements `ui.Backend`
      by printing the document on `mount` and the fragment on `patch`;
      `run()` returns because a server has no input source, and
      `deliver(tag)` is the request that steps one event. `test.emo`
      pins escaping, the rule shape, interning and one assertion per
      node kind in twelve assertions; `golden/` renders a tree with
      every primitive, every `Align`, fractional extents and escapable
      text, and its bytes are the interpreter's on all five targets;
      `examples/ssr_page/` is the usage demo. `ssr/check.sh` is the gate
      and `../check.sh` runs it.
      The task also closed the `wasm` half of T48.2's open finding: its
      `Call_value`, `Closure` and `Global` lowering now allocate a
      function/struct type pair per arity (`closure_type`,
      `emo_wasm.ml`), so a `Block` value is first-class at any arity —
      the core loop's two-argument calls now lower. The core golden and
      `probe/def_shape` therefore build for `wasm`, and the core golden's
      bytes are the interpreter's on all five targets; `c` still refuses
      a bare def name (`Global`), which is the one refusal the gates pin
      (the SSR package's own `test.emo` reaches it through `ui.run`).
- [x] **T48.7** — The native packaging mechanism: per-package manifest
      fields (`pkg_config` and/or compile/link flags, plus whatever
      collects `.m`); the app-level build-script path is not the
      supported one. The gate for T48.8 and T48.9. **Landed 2026-10-18**:
      the manifest gains `pkg_config` — bare pkg-config modules whose
      `--cflags` compile the package's sources and whose `--libs` join
      the link — and `frameworks` — bare macOS frameworks, linked as
      `-framework NAME`; both refuse empty, flag-shaped, and
      path-shaped entries, so the manifest stays data. `.m` joins
      `.c`/`.h` in the collected set (dependency resolution, the
      embedded stdlib, and publish) and is compiled under `-fobjc-arc`,
      the c target's fixed Objective-C policy. Resolved flags enter the
      c build's cache key, an unresolvable module exits 69 with the
      install prompt, and `emo emoji build` passes a package's own
      native inputs the way a dependency's are passed, so the
      pre-publish gate links what consumers get.
- [x] **T48.8** — `ui-macos`: the nine-verb AppKit shim over the callback
      contract; the convergence corpus runs. Demo scale — the `c`
      target's long-running memory is step 49 (`CHECK.md`).
      **Landed 2026-10-18**: `projects/emo-ui/macos/` carries the
      point box model (`box.emo`, pure, so the interpreter tests it),
      the nine foreign verbs (`ui_macos.emo`, with `ui.Events` crossing
      as the callback pair) and `shim.m`, the only Objective-C outside
      `spike/`;
      `corpus/` runs one portable application on it under
      `EMO_GUI_AUTOTEST` and prints the pinned bytes. Getting there
      gave the `c` target def-as-value (`Global`): a capture-less
      closure over a per-def dynamic thunk, which closed the loop's
      last refusal and put `c` in every corpus run.
- [x] **T48.9** — `ui-gtk`: the GTK 4 shim, built with `pkg-config`;
      the convergence corpus runs. Demo scale, as T48.8.
      **Landed 2026-10-18**: `projects/emo-ui/gtk/` is the package
      `emo/ui_gtk`, declaring the `c` target and
      `pkg_config = ["gtk4"]`; the point box model (`box.emo`), the nine
      foreign verbs and the `Gtk` class (`ui_gtk.emo`), and `shim.c`
      mirror the macOS backend, with GtkFixed's top-left origin needing
      no y flip and the same `ui.Events` callback pair crossing the ABI.
      `corpus/` runs the same application, script, and pinned bytes.
      `gtk/check.sh` builds and runs natively where `pkg-config gtk4`
      answers, and otherwise compiles the same generated C in the
      `emo-ui-gtk-build` container (GTK 4 plus Xvfb), so the gate runs
      from a macOS host too.
- [x] **T48.10** — The browser runtime path: a browser-safe split of the
      TypeScript runtime (or a `dom_*` family in the runtime) plus the
      bundling step; the gate for T48.11.
      **Landed 2026-10-18**: the TypeScript runtime is now `ts_core.ts`
      — host-free, with a host object for output, process context,
      shutdown, method dispatch, and runtime implementations — plus
      `ts_node.ts` (the networking section, AsyncLocalStorage, the net
      method table) and `ts_browser.ts` (line-buffered console output,
      one page pid, the `dom_*` family). The compiler concatenates
      core+node into `ts_prelude` and core+browser into
      `ts_browser_prelude`, both as generated data.
      The `dom_*` family is thirteen calls — root, element, text,
      set_text, set_style, set_prop, append, clear, connect, value,
      sink, title, viewport — over Int64 handles into a host-side node
      table; the checker types them in every frame and the IR treats the
      prefix as a runtime implementation like `net_`. `emo build
      --target browser` emits one `.js` bundle: the emitter refuses
      processes (`do`, `<-`, `receive`) and every non-`dom_` runtime
      implementation by name, and the `typescript` target refuses
      `dom_*` by name. The bundling step is the CLI's — it strips the
      types with Node's own `module.stripTypeScriptTypes` (Node >=
      22.13), caches the JavaScript, and reports 69 when Node is
      missing or too old. The `browser` target joins `known_targets` and
      `emo/ui`'s manifest, and `emo doctor` reports it. Tests pin a
      bundle with no host imports running against a stub page, an event
      reaching the sink with its tag, the three refusals by name, and
      the doctor line.
- [x] **T48.11** — `ui-browser`: the DOM backend over the browser path;
      the convergence corpus runs. **Landed 2026-10-18**:
      `projects/emo-ui/browser/` is the package `emo/ui_browser`,
      declaring the `browser` target and pinned against `emo/ui`.
      `css.emo` maps a `Style` to the declarations the browser's own
      layout engine consumes — no point box model lives here, unlike
      macOS and GTK — and `test.emo` checks that mapping as values on
      the interpreter in 27 assertions. `ui_browser.emo` is the `Dom`
      class over the `dom_*` calls: `mount` sets the title, the
      page-root declarations and the sink; `render` builds one element
      per node, with a `button` carrying its tag as the `name`/`value`
      pair the SSR markup uses; `patch` rebuilds the tree, as every
      backend does; `run()` returns, because the page owns the loop.
      `corpus/` is the convergence consumer — the same application, the
      same `0,0,1,2` script and `expected.txt` — and `page.mjs` is the
      stub page the gate runs it in. `browser/check.sh` is the package's
      gate and skips where Node < 22.13 leaves no bundle to build.
- [x] **T48.12** — The convergence corpus: one sample application on
      every backend, with the same portable app module throughout.
      **Landed 2026-10-18**: `projects/emo-ui/corpus/` is the package
      `emo/ui_corpus`, the shared application — a counter as its state,
      an input and a submit button as its form, a scrolled list, and
      the three tags `view` registers — written once and consumed by
      every backend. `corpus/debug`, `corpus/ssr` and `corpus/tui` are
      thin entries under its own gate; `macos/corpus`, `gtk/corpus` and
      `browser/corpus` are thin entries under their packages' gates. Only
      the backend package and the entry module name the platform.
      `corpus/check.sh` pins the debug and SSR entries byte-for-byte on
      all five hosted targets (`ocaml`, `c`, `typescript`, `wasm`,
      `beam`) and the terminal entry on `ocaml`, `c`, `typescript` and
      `beam`, with its `wasm` refusal stated by name. The
      corpus also exposed a `wasm` codegen defect — a `ref.func` to a
      program def was absent from the declarative element segment — now
      fixed and pinned by a CLI test (`CHECK.md`). No language change
      was required.
- [x] **T48.13** — Docs: the README's EmoUI section revised to the
      array-children spelling and the settled decisions; `docs/emo-ui.md`
      settled into decided design where README-eligible; the EmoUI
      package references in its own repository.
      **Landed 2026-10-18**: the README's EmoUI section states the
      settled design — `Array[ui.Node]` children (with `ArrayBuilder`
      for a list that is walked), one `ui.Node` tree type and its
      lowercase constructors, the typed `Style` with `with_*` copies,
      the Elm loop over the loop's `Registry` and `Int64` tags, the
      `ui.Backend` seam, the backend packages, and the convergence
      corpus — and drops the stale claims that reactivity primitives
      live in the standard library and that UI events are process
      messages. `docs/emo-ui.md` now opens with a status note: the
      settled design lives in the README and the package references,
      and the note is kept as the assessment, the evidence, the
      rejected alternatives and the open questions, with the README
      authoritative on settled points; finding 1, the recommendation
      and decision 3 record that the README tree has been revised. The
      EmoUI repository carries the package references under
      `projects/emo-ui/docs/` — `ui`, `debug`, `ui_tui`, `ui_ssr`,
      `ui_macos`, `ui_gtk`, `ui_browser` and `ui_corpus` — in the
      `docs/stdlib/term.md` format: manifest, `def` signatures, and the
      behavior a caller can rely on, with an index. The Chinese
      translations of both READMEs and the two design docs were updated
      in step.

---

## M16 — Value-family reclamation

The `c` target's reclamation model (T23.5, 2026-10-11) counts references
over the identity-bearing cells — instances, closures, `Box` — and lets
every value-semantic kind (strings, tuples, arrays, maps, lists, bytes,
enums, boxed scalars) sit in a bump arena until process exit. A UI
re-runs `view()` per event on exactly those kinds, which is what turned
a tidiness item into a product problem. The 2026-10-14 arena-scope spike
measured the cost, ruled out the cheap fixes, and settled the direction:
a region reclaims 100% of the arena's bytes and 0% of the leak, because
identities are `malloc`'d outside it and the arena's aggregates retain
them across its boundary — and the reset strands those refcounts
permanently. The real fix is refcounting the value families, and it is
this milestone (`CHECK.md`, `spike/arena-scope/`). Nothing here is a
prerequisite for step 48: the native backends are built at demo scale
with the limit documented. (The note retired 2026-10-17 — the
milestone landed and the working set is flat; the T49.4 gate pins it.)

### Step 49 — Value-family reclamation · `plan/step-49-value-reclamation.md`

**Prereq:** none — explicitly not a prerequisite for step 48.
**Done when:** a long-running `c`-target program holds a flat working
set — arena bytes and identity liveness stop rising per render and track
the live tree — array growth is linear rather than quadratic, every
existing golden on every target is byte-identical, and the interpreter
and the non-`c` targets are untouched.

- [x] **T49.1** — The runtime: extend the identity discipline
      (`emo_identity_kind`, `emo_retain`/`emo_release`, and the
      constructors that store into aggregates) from the three identity
      kinds to the value families, so a value cell can reach refcount
      zero and an aggregate releases what it holds; includes the audit
      that no value-family construction can form a cycle. The emitter
      already retains and releases every dynamic binding
      (`emo_c.ml:1851`, `:423`), so this starts runtime-side.
      **Landed 2026-10-17.** Every cell is counted and individually
      freed; the emitter's `may_own` widened to every dynamic type, so
      each construction pools its birth and each claim handout lands in
      the statement's pool; the tail-rebind and hoisted-binding
      barriers take the new claim before dropping the old; `Map.remove`
      hands back a claim; the dynamic→native String crossing copies.
      The cycle audit: the immutable families are structurally acyclic,
      the mutable identities join the documented cycle-leak class. The
      live-count probe returns to baseline across a value-family churn;
      the native transient buffers stay the T49.2 remainder.
- [x] **T49.2** — The granularity: decide what the autorelease pool owns
      now that every dynamic type may own memory, and implement it —
      expression-internal temporaries are the hard half, `may_own` plus
      the constructor audit that follows (`emo_c_runtime.c:1753`).
      **Landed 2026-10-17: String joined the dynamic world** (`CHECK.md`
      carries the written weighing — the wider pool and the smarter
      emitter were rejected as unsound or as the ownership analysis the
      pool exists to erase). Typed `String` positions are cells; the
      leaf string builders answer self-pooled births (no arena
      intermediate, no frame of their own); the general constructors
      still pool at the emitter; the runtime's own transients (printf
      buffer, file/net reads, argv, list_dir names) are malloc'd and
      freed within their calls. The churn probe holds RSS flat across
      3 000 / 30 000 / 120 000 iterations with the live count at zero,
      and every golden stays byte-identical.
- [x] **T49.3** — The array shape: an O(1) append or a builder, so
      growing a k-element array is not quadratic in bytes and retains;
      T48.1's children representation depends on the answer. **Settled
      2026-10-15 — a builder, and a new language-level type
      (`ArrayBuilder`) rather than an `Array` representation change.**
      `new()` / `push` / `length` / `get` / `to_array`, on the
      interpreter and all five hosted targets (`riscv64` refuses it by
      name, exit 65, the `Map` precedent); the first statically-typed
      `push` pins the element type of the `const` binding at the base of
      the pushed chain (`docs/intro/syntax.md`, Mutability). The second
      shape this task names — a conversion back from `List` to an
      indexable `Array` — is deliberately not taken. This answers the
      array half without touching the runtime, so step 49's "array growth
      is linear rather than quadratic" criterion is now reachable through
      the language rather than through T49.1; T48.1's representation
      question was unblocked here and is **answered** by the core
      (2026-10-15): children are an explicit `Array[Node]`, and the
      container is what builds a dynamic child list.
- [x] **T49.4** — The gate: the spike's render ladder and region probes
      as a checked-in test that fails today and passes after, on the `c`
      target, with `dune test` green. **Landed 2026-10-17** —
      `emo_arena_bytes` joined the runtime's probes, and the
      `c_flat_working_set` group runs the spike's render shape (view
      rebuild, style maps, append-built children, a layout walk) at two
      rungs: both deltas — arena bytes and live cells — pin at exactly
      zero. The region probes' work is done by the refcount model
      itself (`arena_mark`/`arena_reset` stayed out of the shipped
      runtime).
- [x] **T49.5** — Docs: `CHECK.md`, `docs/emo-ui.md` and its zh-CN
      mirror, and step 48's demo-scale notes updated to point here.
      Landed 2026-10-17 — `CHECK.md`'s entry reads as the landed
      decision, `docs/emo-ui.md`'s ask 4 and the layer caveats point at
      the flat working set, and every demo-scale note carries its
      retirement.

---

## M17 — Cross-target conformance

A 2026-10-14 target-feasibility survey checked the concurrency promises
against every implementation and found three places where the rules and
the code disagreed (`CHECK.md`, cross-target invariants). Two of them
were never open design questions: `docs/intro/concurrency.md` already
promises that an unhandled error "kills only the offending process", and
`docs/intro/syntax.md` already promises a snapshot copy at the process
boundary for Map, Box, List and ArrayBuilder — with the interpreter, the
standalone OCaml runtime and BEAM all honouring both, and
`stdlib/registry/sync/0.1.0/sync.emo` stating the send rule outright for
a handle. The `c` target was the one implementation that diverged, so
the work here is conformance, not language design: no promise moves and
no README changes. The third item is the same shape on the emitter side —
the capability table is the intended sole gate on `foreign def`, but it
admits `Float64`/`String`/`Bool` on every target, so a `foreign def`
reached the `wasm` and `beam` emitters past it. The milestone's own
finding is that the survey's cost estimate for the `raise` gap was
wrong, and by a wide margin: the mechanism it assumed — `setjmp` /
`longjmp` plus a reference-count drain at every unwound C frame — was
never needed, because the runtime's autorelease pool is already a
heap-allocated frame chain hung off the fiber, and the fiber teardown
path already existed. Everything here is runtime- and emitter-local.

### Step 50 — Cross-target conformance · `plan/step-50-cross-target-conformance.md`

**Prereq:** none.
**Done when:** a spawned `c`-target process that raises dies alone while
its parent runs on; a mutable value sent between `c`-target processes
arrives as a snapshot; `foreign def` refuses by name on `wasm` and
`beam` with exit 65; every existing golden on every target is
byte-identical; and `CHECK.md` records all three as settled with the
`typescript` send gap named as the remainder.

- [x] **T50.1** — The `foreign def` refusal: `emo_wasm.ml` and
      `emo_beam.ml` refuse a `foreign def` per function, beside the code
      that would have lowered it, with `Emo_ir.Lower_error` — the
      riscv precedent — so the CLI renders it as exit 65. The survey's
      open guess ("a clean refusal downstream or a silently absent
      symbol") resolved to the second: the IR carries the symbol on an
      otherwise ordinary `func` record with an empty body, so both
      emitters were emitting a real function for a declaration that has
      no Emo body. Refined by T39.3: the declaration now imports cleanly
      on every target, and the refusal moved to the call.
- [x] **T50.2** — The `c` target's `raise` ends the logical process:
      `emo_raise` drains the current fiber's frame chain and halts it
      when it is not the root, keeping the render-and-`exit(1)` path for
      a raise outside the scheduler or in the root (`docs/intro/
      concurrency.md`). `halt()` routes through the same drain — it
      leaked its whole frame chain, the one other site with the same
      shape. No emitter change and no unwinder: the frame chain is on the
      heap and the fiber-teardown path already existed.
- [x] **T50.3** — The `c` target's `send` snapshots: `emo_deep_copy`
      rebuilds the mutable kinds at the send and the mailbox owns the
      copy, following the interpreter's own rule over the kinds this
      runtime has. One emitter line followed from it — the mailbox take
      releases its only claim, so the receive scan now holds its own.
- [x] **T50.4** — Docs: `CHECK.md`'s cross-target entry rewritten as
      settled with the corrected cost estimate, `docs/intro/
      concurrency.md`'s by-reference sentence fixed, T23.6's note
      updated, the gates table updated, and this milestone added. The
      `typescript` target's share-on-send is recorded as the entry's open
      remainder rather than fixed here, because the fix belongs with the
      browser-runtime split (T48.10).

---

## M18 — TLS on the `c` target

TLS was never missing from the standard library — `net_tls_connect`,
`net_tls_connect_insecure` and `net_listen_tls` exist as builtins, the
interpreter's scheduler and the standalone OCaml runtime implement them
through the opam `ssl` library, `typescript` maps them onto
`node:tls`, and `http`'s `https://` routes through `net.tls_connect`
in plain Emo source. The gap was the `c` target, the default: the
three names fell to `emo_unsupported`, so `https` was dead precisely
where `emo build` runs by default. The work is conformance, not
surface: the C runtime lands the three builtins against the system
OpenSSL/LibreSSL with the ocaml scheduler as the semantic reference,
the linkage keys on IR use so a program that never touches TLS never
links OpenSSL, the prototypes are hand-declared because no target
platform owes the build OpenSSL headers, and the user-level-FFI route
was evaluated and refused (`CHECK.md`).

### Step 51 — TLS on the `c` target · `plan/step-51-tls-c-target.md`

**Prereq:** none.
**Done when:** an `https://` request runs end-to-end on `c` (the
captive TLS server, byte-identical to the interpreter's
`expected.txt`); the verified handshake, the verify-fail pin, the
insecure roundtrip and the server-side TLS echo are green on the
interpreter and on `c`; a non-TLS `c` build neither links nor requires
OpenSSL (the `nm` pin) and every existing golden on every target stays
byte-identical; the runtime-manufactured reason strings are
byte-identical across interp / `c` / the standalone ocaml runtime; and
the docs carry the story (`docs/stdlib/net.md`, `docs/stdlib/http.md`,
the zh-CN mirrors).

- [x] **T51.1** — The linkage gate: the fenced TLS section in
      `emo_c_runtime.c`/`.h` — hand-written prototypes plus the frozen
      constants, real bodies under `EMO_HAS_TLS` and `emo_unsupported`
      bodies without — the emitter's explicit arms for the three names
      with its IR-walk `uses_tls` flag, and the CLI's conditional
      `-DEMO_HAS_TLS` + `-lssl -lcrypto` through the cclib slot behind
      a pre-flight probe whose failure names the fix; the c_goldens
      `nm` pin proving a non-TLS build references no `SSL_` symbol.
- [x] **T51.2** — The client handshake: TCP via the existing
      `emo_net_connect`, then nonblocking `SSL_connect` parking on
      `WANT_READ`/`WANT_WRITE` (a wait-writable hook joins the
      scheduler's poll loop); `TLS_client_method`, the TLS 1.2–1.3
      window, the system trust store, SNI, `SSL_set1_host` +
      `SSL_get_verify_result`, the version-floor refusal carrying the
      library's own version string, the
      `the TLS handshake with <host>: ` reason prefix, and the CA +
      server-certificate fixture (`SAN=localhost,127.0.0.1`) with a
      verified loopback handshake driven through `SSL_CERT_FILE`.
- [x] **T51.3** — The data plane and the insecure variant: read/write
      route through the `fd → SSL*` side table with the same parking
      discipline, `close()` runs `SSL_shutdown` and frees, timeouts
      match the ocaml conn's semantics, and
      `net_tls_connect_insecure` is the same path with verification
      off.
- [x] **T51.4** — The server side: `net_listen_tls` loads the PEM pair
      (refusing with the ocaml-matching
      `cannot load the TLS certificate for <host>:<port>` shape),
      listeners register fd → context, `accept` performs `SSL_accept`
      and registers the conn; an in-program TLS echo server + client
      on `127.0.0.1:0`, on the interpreter and on `c`.
- [x] **T51.5** — The goldens: `examples/https_roundtrip` against the
      harness's captive ocaml-ssl TLS server, `expected.txt` taken
      from the interpreter and byte-identical on `c`, registered in
      c_goldens; a TLS roundtrip test for the standalone OCaml
      runtime, which implemented TLS but never tested it.
- [x] **T51.6** — Docs: `docs/stdlib/net.md`'s TLS limitation becomes
      the implemented story (ocaml-ssl / node:tls / system
      OpenSSL-LibreSSL, with the floor stated),
      `docs/stdlib/http.md`'s "`https` needs TLS, which `c` refuses"
      retired, the zh-CN mirrors, the gates table and
      `plan/README.md`'s status table updated.

## M19 — Map on `wasm` and `beam`

`Map` is the one capability builtin the two remaining hosted targets
refuse: the interpreter, `c`, `ocaml`, and `typescript` implement it,
while `wasm` and `beam` reject a map literal at lowering (`the
wasm/beam target does not support Map yet`, a refusal dating from when
the two runtimes shipped in T16–T18). The refusal has grown
load-bearing: the `plot` package's `Table` and channel vocabulary are
Map-shaped (decision 4/10/16, Step 42 blocked on it), `slog`'s manifest
narrows itself while the gap stands, and `Exception.new(data:)` — a
Map — cannot carry crash context on either target (`CHECK.md` records
the standing note). The mechanism exists on both sides already: `wasm`
lowers the mutable `List` through WasmGC structs (`$vlist` over `$lnode`
nodes, runtime functions 61–67) and `beam` through the process
dictionary keyed by a fresh ref (`emo_list_new`, the `{'emo_list', K}`
tag), each with the same shape of method surface Map needs. M19 lands
Map through those precedents — the insertion order, the six key kinds,
structural `==` (content equality, insertion order irrelevant, the
interpreter's rule), and the `{key: value}` rendering byte-identical
with the four targets that have it — and closes the recorded `wasm`
send-snapshot remainder that the new mutability makes reachable
(`CHECK.md`, step 50). Mutable kinds stay process-local on `beam` (the
`List` precedent — a tag sent across processes fails loudly at first
use, `emo_no_list` today, `emo_no_map` beside it); `riscv64` stays the
one refusal, the capability tier frozen.

### Step 52 — Map on `wasm` and `beam`

**Prereq:** none (the interpreter and the `c`/`typescript`
implementations are the semantic reference).
**Done when:** a map program — literals, `Map.new`, the seven methods,
structural `==`, the `{key: value}` print, aliasing through two
bindings — runs byte-identical on all six paths (interp, c, ocaml, ts,
wasm, beam); `Exception.new(data:)` carries data on `wasm` and `beam`;
`send` delivers a snapshot on `wasm`; `slog` declares the two targets
and its golden joins their lists; every existing golden on every target
stays byte-identical; the docs carry the story.

- [x] **T52.1** — The wasm runtime's map structures: a `$vmap` — key
      array, value array, count, in the `$vbuilder` doubling-buffer
      shape, linear-scan lookup (plot-scale maps are small, and the
      array order *is* the insertion order) — with the runtime
      functions `map_new`, `map_get` (E3004
      `no key ... in this Map` on a miss, the interpreter's error),
      `map_set` (an existing key keeps its first-insert position),
      `map_has`, `map_remove` (compaction preserving relative order),
      `map_len`, `map_keys`, `map_values`, `map_str` (the
      `{key: value}` rendering in insertion order, elements and keys
      through the shared `to_str`), and the boxed-primitive key
      equality helper; appended after the array/builder renderings with
      the index table and `runtime_count` updated (main stays at 60,
      List at 61–67, the map ops following).
- [x] **T52.2** — The wasm lowering: `Map_lit` builds through
      `map_new` (the emitter packs `Map.new`'s variadic pairs), the
      seven methods dispatched on the receiver's `MapType`, structural
      `==`, and `to_string` wired; the two `Lower_error` refusals in
      `emo_wasm.ml` (the `Map_lit` arm and the `MapType` method arm)
      deleted, and the stale `Make_exception` comment updated so
      `Exception.new(data:)` lowers.
- [x] **T52.3** — The wasm send snapshot: `rt_send` deep-copies the
      message before it joins the mailbox — Map, Box, List, and
      ArrayBuilder rebuilt (a map copy preserving insertion order), the
      immutable kinds and `Pid` passing through — the `c` runtime's
      `emo_deep_copy` rule, closing the recorded conformance remainder
      (`CHECK.md`, step 50); the `cross_target` corpus pins it on
      `wasm`.
- [x] **T52.4** — The beam runtime's map helpers under the
      `emo_list_new` discipline: `emo_map_new/1` mints a fresh ref and
      stores `{Order, Pairs}` — the insertion-order key list and an
      Erlang map key→value — in the process dictionary behind
      `{'emo_map', K}`; `emo_map_get/2` (the interpreter's E3004
      message on a miss), `emo_map_set/3` (first-insert position kept),
      `emo_map_has/2`, `emo_map_remove/2` (the order list filtered),
      `emo_map_length/1`, `emo_map_keys/1`, `emo_map_values/1`,
      `emo_map_str/1`, and `emo_map_equal/2` (same size, per-key value
      equality, order irrelevant); keys are the six hashable primitives
      compared with `=:=`, so `1` and `1.0` stay distinct.
- [x] **T52.5** — The beam lowering: `Map_lit` → `emo_map_new`, the
      method arms splitting on the `{'emo_map', K}` tag where a name
      serves several types (`get`, `length`, `to_string` — the bytes
      precedent), structural `==` through `emo_map_equal`, and the
      stale `Make_exception` comment updated so `Exception.new(data:)`
      carries data on `beam`.
- [x] **T52.6** — The golden: `examples/map_demo` — a literal,
      `Map.new(pairs)`, the seven methods, insertion order through
      `keys()`/`values()`, first-insert positions, removal, aliasing,
      `==` (equal content in different insertion order, and unequal
      maps), the `{key: value}` print, and an `Exception.new` carrying
      `data` — `expected.txt` taken from the interpreter and
      byte-identical in all five golden lists; the check-time key-kind
      pin (E4020) rides the existing diagnostics tests.
- [x] **T52.7** — The stdlib widening: `slog`'s manifest gains `wasm`
      and `beam` (its close-out's recorded condition — declares the
      targets that work today, widens when the gap closes), and
      `slog_demo` joins the wasm and beam golden lists byte-for-byte.
- [x] **T52.8** — The docs: `docs/demo-targets.md`'s capability story
      (the `wasm`/`beam` Map refusals retire; `riscv64` stays the one),
      `docs/stdlib.md`'s slog row, `docs/visualization.md`'s
      five-target Table claim now literally true, `CHECK.md`'s T16.5
      note (`slog` waits on `Map`) recording its resolution, the zh-CN
      mirrors, and `plan/README.md`'s status table.
