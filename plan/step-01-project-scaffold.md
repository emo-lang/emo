# Step 01 — Project Scaffold & CLI Skeleton

**Milestone:** M1 · **Prereq:** none · **Status:** done

## Goal

A building, tested OCaml 5 project with an `emo` CLI wired end to end: argument
parsing, shared diagnostics plumbing, and subcommand entry points that
intentionally do nothing yet. No Emo language functionality in this step.

## Scope

### In

- `dune-project` (latest stable dune `lang` version at implementation time)
  and the workspace layout under `src/`.
- Library skeleton, one dune library per compiler stage so later steps fill
  them in without restructuring:

  ```
  dune-project
  src/
    emo_support/   # spans, source buffers, diagnostic types, error codes
    emo_lexer/     # step 02
    emo_parser/    # steps 03–04 (hand-written recursive descent)
    emo_ast/       # AST shared by parser / eval / checker, steps 03+
    emo_eval/      # steps 05–06
    emo_check/     # step 08
    emo_cli/       # the `emo` binary
  test/            # alcotest suites, one per library
  examples/        # created in step 07 (acceptance programs)
  ```

- CLI binary with subcommands (names are provisional — see open items):
  `emo run <file>`, `emo repl`, `emo check <path>`, `emo version`.
- `emo version` prints `emo 0.0.1`; every other subcommand prints
  `not implemented yet` and exits non-zero.
- Diagnostic core: `Span` (file, line, col, start, stop), `Severity`
  (error / warning), a `Diagnostic` record with message + span, and a renderer
  that prints them to stderr. Language stages will reuse exactly this.
- Test harness (alcotest) with a smoke test per library; CI workflow
  (`.github/workflows/ci.yml`: setup-ocaml, `dune build`, `dune test`, on
  Linux + macOS) alongside the existing website deploy workflow.
- `.ocamlformat` with the `conventional` profile.

### Out

- Any lexing, parsing, or evaluation of Emo code.
- Publishing, installation scripts, release tooling.

## Dependencies to add

- `cmdliner` — CLI parsing (standard OCaml choice).
- `alcotest` — test framework.

## Tasks

- [x] Create `dune-project` and `src/` library skeletons with placeholder
      modules that compile.
- [x] Implement `emo_support`: span, severity, diagnostic, renderer; unit
      tests for the renderer.
- [x] Implement `emo_cli` with cmdliner; wire the four subcommands to
      placeholder actions.
- [x] Add alcotest smoke tests and the CI workflow.
- [x] Add `.ocamlformat`; format the tree once (`dune build @fmt` passes).

## Acceptance

- `dune build` and `dune test` pass from a clean checkout.
- `emo version` prints `emo 0.0.1`.
- `emo run anything.emo` exits non-zero with the placeholder message.
- CI runs green on both Linux and macOS.

## Open design items

- CLI command names are pending (`CHECK.md`, "Package management / CLI
  command names"). This step uses `run` / `repl` / `check` provisionally;
  rename mechanically once settled.
