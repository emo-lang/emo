# Implementation Plan

The reference implementation of Emo is written in OCaml 5 (self-hosting is
explicitly not a goal). This directory breaks the work into MVP-first,
incrementally shippable steps — one file per step, executed in order.

## Milestones

- **M1 — MVP interpreter (steps 01–07):** single-file Emo programs run through
  `emo run` / `emo repl` with a hand-written pipeline: lexer → recursive-descent
  parser → tree-walking evaluator.
- **M2 — Compile-time experience (steps 08–10):** the built-in gradual type
  checker, the structural module system (directory tree = module tree), and
  packages with MVS resolution.
- **M3 — Concurrency & networking (steps 11–12):** processes and message
  passing on an effects-based scheduler, plus the direct-style networking API.
- **M4 — Compilation targets (steps 13–14):** native code generation, then
  wasm / TypeScript / BEAM / riscv64.

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
- No loop keyword is planned: iteration is recursion plus collection methods,
  which is why tail calls are guaranteed (README, Concurrency). If a loop form
  ever becomes necessary, it goes through `CHECK.md` first — and it must bind
  fresh per-iteration variables: the Go pre-1.22 for-loop closure capture
  trap is the cautionary tale. Emo today is structurally immune to it — every
  recursion/method-call iteration is a fresh frame, and capturing a `var` in
  a closure is a compile error (README, Syntax).
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
| 07 | CLI & diagnostics (`run`, `repl`, `check`) | done |
| 08 | Gradual type checker | done |
| 09 | Structural module system | done |
| 10 | Packages & version resolution | done |
| 11 | Processes & message passing | done |
| 12 | Networking library | done |
| 13 | Native backend | done |
| 14 | Other targets (wasm / TS / BEAM / riscv64) | in progress (TS, Wasm promoted) |
| 15 | TypeScript target | in progress |
| 16 | Wasm target (WasmGC) | in progress |
| 17 | BEAM target (Core Erlang) | done |
| 18 | Function groups (`emo` keyword) | done |
| 19 | The systems layer (wasm runtime + EmoOS primitives) | done |
| 20 | Wasm runtime: decoder & validator | done |
| 21 | Wasm runtime: interpreter core & spec goldens | not started (plan written at start) |
| 22 | RISC-V target (freestanding RV64) | not started (tasks written) |
