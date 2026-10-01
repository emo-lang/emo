# Step 07 — CLI & Diagnostics: `run`, `repl`

**Milestone:** M1 complete · **Prereq:** steps 01–06 · **Status:** done

## Goal

Ship the MVP: `emo run file.emo` executes programs, `emo repl` gives an
interactive loop, and every stage reports through one polished diagnostic
renderer. This step adds no language semantics — it hardens what exists.

## Scope

### In

- **`emo run <file>`** — load, lex, parse, evaluate in order; on any stage
  error print diagnostics and exit non-zero (distinct exit codes per stage:
  lex/parse 65, eval 70, uncaught exception 1).
- **`emo repl`** —
  - Reads a line; if brackets are unbalanced (depth from the lexer), keep
    reading multi-line with a continuation prompt.
  - Evaluates each input in a persistent environment: definitions
    (`def` / `class` / ...) register, statements execute, expression lines
    print their value via `.to_string()` (provisional REPL convenience; not
    a language rule).
  - Ctrl-D / `exit` quits. Runtime errors print and the environment survives.
- **Diagnostics rendering** — one format used by all stages:
  ```
  error[E2003]: assigning to `self.age` outside `init`
    --> examples/user.emo:9:5
     |
   9 |     self.age = 36
     |     ^^^^^^^^^ fields freeze after `init`
  ```
  - Source excerpt with line numbers, caret span, stage-prefixed error
    codes (`E1xxx` lex, `E2xxx` parse, `E3xxx` eval runtime, later `E4xxx`
    check), optional hint line, color on TTY with `--no-color` honored.
  - Multi-error output: all recoverable errors from a single stage appear
    in one run, sorted by position, capped with a `--error-limit` (default
    20, strictness without flooding).
- **Uncaught exception report** — exception value, `.to_string()`, and the
  Emo call chain (function names + spans) collected by the evaluator.
- **`examples/` directory** — the step 05/06 acceptance programs plus the
  README's `User` / `Greeter` / `Color` samples, run by tests as end-to-end
  golden files (input + expected stdout).

### Out

- `emo check` (needs step 08 — the flag exists from step 01 and stays
  "not implemented").
- Debugger, watch mode, notebooks.

## Tasks

- [x] `run` command with stage pipeline and exit codes.
- [x] REPL: multi-line reading, persistent environment, value echo.
- [x] Diagnostic renderer completion (excerpts, codes, hints, colors,
      error limit); unit tests over golden renderings.
- [x] Uncaught-exception trace plumbing in the evaluator.
- [x] `examples/` golden tests wired into CI.
- [x] Manual pass: run each example, use the REPL interactively.

## Acceptance

- Every `examples/*.emo` runs with expected output in CI.
- A file with three parse errors reports all three in one run, at correct
  line:col, stable under `--no-color`.
- The REPL evaluates the step 06 acceptance block interactively.
- **M1 exit criteria:** a new user can write a single-file Emo program with
  functions, classes, enums, and exceptions, run it with `emo run`, and get
  readable errors when it is wrong.

## Open design items

- None new — close out any provisional decisions from steps 02–06 that
  shipped (`print`, trailing-block sugar) by promoting them into the README
  now that M1 proves them.
