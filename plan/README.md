# Implementation Plan

The reference implementation of Emo is written in OCaml 5 (self-hosting is
explicitly not a goal). This directory breaks the work into MVP-first,
incrementally shippable steps — one file per step, executed in order.

## Milestones

- **M1 — MVP interpreter (steps 01–08):** single-file Emo programs run through
  `emo run` / `emo repl` with a hand-written pipeline: lexer → recursive-descent
  parser → tree-walking evaluator.
- **M2 — Compile-time experience (steps 09–11):** the built-in gradual type
  checker, the structural module system (directory tree = module tree), and
  packages with MVS resolution.
- **M3 — Concurrency & networking (steps 12–13):** processes and message
  passing on an effects-based scheduler, plus the direct-style networking API.
- **M4 — Compilation targets (steps 14–19):** native code generation, then
  wasm / TypeScript / BEAM / riscv64.
- **M13 — The standard library (steps 31–38):** the bundled stdlib
  packages — `json`, `yaml`, `xml`, `os`, `base64`, `slog`, `bufio`, and the
  native-binding `sqlite3` — each with a full API reference and a runnable
  golden, on every target it declares. (The full milestone list is in
  `docs/TASKS.md`.)
- **M15 — EmoUI (step 48):** one declarative EmoUI tree renders on a
  terminal, a server-rendered page, a macOS/AppKit window, and a GTK 4
  window behind thin per-platform entries, with the browser DOM following
  its own runtime path; the portable core and the pure-Emo backends answer
  byte-for-byte, the composition syntax is identical everywhere, and
  per-platform component libraries share convergent names. The design is
  `docs/emo-ui.md`.
- **M16 — Value-family reclamation (step 49):** the `c` target reclaims
  the value-semantic kinds as well as the identity cells, so a
  long-running program's arena bytes and identity liveness stay flat
  across renders; array growth becomes linear. Scheduled when the
  2026-10-14 arena-scope spike ruled region reclamation out
  (`spike/arena-scope`, `CHECK.md`). Not a prerequisite for step 48 —
  the native UI backends are built at demo scale with the limit
  documented.
- **M18 — TLS on the `c` target (step 51):** the three existing `net`
  TLS builtins — implemented on the interpreter, the standalone OCaml
  runtime and `typescript` since step 13 — land on the default target,
  the C runtime binding the system OpenSSL/LibreSSL behind
  hand-declared prototypes and IR-keyed conditional linkage, so
  `http`'s `https://` works end-to-end on `c` while a non-TLS build
  never links OpenSSL. Conformance, not surface: the ocaml scheduler
  is the semantic reference. Decisions settled 2026-10-17
  (`CHECK.md`, `plan/step-51-tls-c-target.md`).

## Ground rules

- Every step ends with the repo building, `dune test` green, and the step's
  acceptance examples passing. Do not start the next step on a red build.
- `README.md` (repo root) is the design source of truth. Where the README is
  silent on an implementation detail, the step file names a **provisional
  decision**, marked as such; once settled, language-surface decisions move
  into the README and library-level ones into `docs/`. Never silently.
- Pending design decisions live in `CHECK.md`. Steps that depend on an open
  decision list it under "Open design items" — settle it in `CHECK.md` /
  `README.md` *before* implementing that task.
- Strictness first: when in doubt, reject early with a clear diagnostic. No
  auto-fixing, no implicit additions, no silent fallbacks.
- Loop forms are being added: the decided direction (2026-10-06) is to keep
  guaranteed tail calls *and* add C-style `for`/`while`; the surface is settled
  (README, Syntax and `CHECK.md`) and implementation is unscheduled. The Go pre-1.22
  loop-capture trap is already prevented — a `var` cannot escape its block,
  and capturing one in a closure that outlives the block is a compile error
  (README, Syntax) — so the earlier fresh-binding caution is subsumed.
- Compiler sources live under `src/` as dune libraries; `website/` is the
  docs site and unrelated to the compiler. Acceptance example programs live
  under `examples/` once step 07 creates it.

## Status

| Step | Focus | Status |
|------|-------|--------|
| 01 | Project scaffold & CLI skeleton | done |
| 02 | Lexer | done |
| 03 | Parser — expressions | done |
| 04 | Parser — declarations | done |
| 05 | Interpreter — core values & evaluation | done |
| 06 | Interpreter — classes, enums, interfaces | done |
| 07 | Function groups (`emo` keyword) | done |
| 08 | CLI & diagnostics (`run`, `repl`, `check`) | done |
| 09 | Gradual type checker | done |
| 10 | Structural module system | done |
| 11 | Packages & version resolution | done |
| 12 | Processes & message passing | done |
| 13 | Networking library | done |
| 14 | Native backend | done |
| 15 | Other targets (wasm / TS / BEAM / riscv64) | in progress (TS, Wasm promoted) |
| 16 | Wasm target (WasmGC) | in progress |
| 17 | TypeScript target | in progress |
| 18 | BEAM target (Core Erlang) | done |
| 19 | RISC-V target (freestanding RV64) | done (T19.1–T19.4; the `%g` float to-string lands as its own follow-up) |
| 20 | The systems layer (wasm runtime) | done |
| 21 | Wasm runtime: decoder & validator | done |
| 22 | Wasm runtime: interpreter core & spec goldens | in progress (tasks written) |
| 23 | C target (emit C) | done (close-out recorded; the native → ocaml rename landed; aligned 2026-10-10 — Void foreign returns, `emo_defs.h`, content-keyed caches, cross-module calls and types) |
| 24 | Toolchain distribution & release | done (M7 complete) |
| 25 | Target independence (runtimes decoupled from the host) | done (M8 complete; every runtime embedded, the ocaml target installation-independent) |
| 31 | The standard library: `json` | done on interpreter/ocaml/typescript/c (2026-10-10 on c — the landing flushed the c Bytes-arm guess on gradual receivers and the vtable's `_q`/`?` spelling); wasm, beam wait on their own capability walls |
| 32 | The standard library: `yaml` | done on interpreter/ocaml/typescript/c (2026-10-10 on c — flushed the trampoline's cluster-scope collision); wasm, beam wait on their own capability walls |
| 33 | The standard library: `xml` | done on interpreter/ocaml/typescript/c; the cross-module-types gate resolved (2026-10-10); wasm, beam wait on their own capability walls |
| 34 | The standard library: `os` | done on interpreter/ocaml/c; the browser and bytecode targets refuse the package (no process to fork) |
| 35 | The standard library: `base64` | done on every target — the first package on all five goldens; flushed out the wasm `&&` cast, the wasm zero-length copies, and the beam logical-op/tuple-index/Exception gaps |
| 36 | The standard library: `slog` | done on interpreter/ocaml/c/typescript; wasm, beam wait on `Map` support (attrs are a Map); loggers are values, no state, no clock — the first package whose golden needed zero compiler changes |
| 37 | The standard library: `bufio` | done on interpreter/ocaml/c; the package rides `os`, so wasm/beam/typescript refuse it at resolution like `os` does |
| 38 | The standard library: `sqlite3` | done on c — the first native-binding package: the manifest's `link` field and package-carried C sources land with it; every other target refuses at resolution, the interpreter at run time (E3009) |
| 48 | EmoUI | planned — decisions settled 2026-10-14 (`docs/emo-ui.md`, `plan/step-48-emo-ui.md`); the compiler-side gates are the native packaging mechanism, the browser runtime path, and terminal raw mode; the native backends are demo scale until step 49 lands |
| 49 | Value-family reclamation | planned — scheduled 2026-10-14 after the arena-scope spike ruled out region reclamation (`spike/arena-scope`, `CHECK.md`); direction settled, nothing implemented |
| 51 | TLS on the `c` target | planned — the three `net` TLS builtins land in the C runtime against the system OpenSSL/LibreSSL; decisions settled 2026-10-17 (`CHECK.md`, `plan/step-51-tls-c-target.md`); direction settled, nothing implemented |

The deep-C-FFI assessment (`plan/hosted-native-ffi.md`) precedes step 23; it is a design record, not a numbered step.
