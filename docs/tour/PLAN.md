# Emo language tour — development plan

**Status:** M0–M3 landed (2026-11-27); M4 optional · **Owner:** docs ·
**Prereq:** none
**Related:** `examples/language_tour/` (the one-program reference it
complements), `docs/demo-targets.md` (the wasm run path),
`justfile` (`example`, the golden-runner pattern), `devtools/`
(the shell tooling convention), `README.md` (the documentation map).

## Why

New users need one path from "I have heard of Emo" to "I can write a
small program with classes, collections, errors, and JSON". The docs
today are complete but reference-shaped: `docs/intro/*` assumes a
reader who already knows what to look for, and `examples/language_tour`
is one long program rather than a step-by-step introduction.

The tour is a Markdown document whose every Emo snippet is compiled and
run, so the prose cannot drift from the language. Markdown is the
source; the code blocks are the tests.

## Goal

- One Markdown file per language: `docs/tour.md` (English) and
  `docs/zh-CN/tour.md` (Chinese), containing a quick start plus ten
  chapters.
- Every ```` ```emo run ```` block is a self-contained program compiled
  to Wasm and executed by `emo run --target wasm`; its stdout is
  compared byte for byte with the `output` block beside it.
- A single command, `just tour`, verifies the whole tour locally, and
  the same command is the gate when CI returns.

## Non-goals

- No new language construct, CLI subcommand, or compiler flag in this
  plan. `emo tour` and a website Run button are deferred (M4).
- No networking chapter: the Wasm target refuses `net`/`http`. Those
  features stay in `docs/intro/networking.md`.
- No interpreter-only material (`emo test`, `expect_*`) as runnable
  blocks; a `no-run` mention points at the testing guide instead.
- No sandbox for untrusted input: the runner executes this
  repository's own Markdown, not user-submitted code.

## Decisions settled here

1. **Markdown is the source of truth.** Both the rendered site and the
   checker read the same file; there is no separate example tree to
   keep in sync.
2. **Every Emo fence is executable unless it says `no-run`.** An
   unlabeled ```` ```emo ```` block is a check failure, so snippets
   cannot silently rot.
3. **Execution is `emo run --target wasm`.** The command already builds
   and runs under Node with the bundled host; the tour does not carry
   its own host or Node script.
4. **Each block is its own project.** A per-block temporary directory
   with a generated `package.emo` keeps snippets independent and
   copy-pasteable, and guarantees the reader can run any block alone.
5. **The runner is a devtool, not a CLI command.** It lives at
   `devtools/tour-check.sh`, mirroring `just example`'s shell style.
   Shipping the tour inside the binary (`emo tour`) is M4, only if it
   earns its place.
6. **Expected output is visible.** A ```` ```output ```` block directly
   after a run block is its exact stdout. Readers see what the program
   prints, and the checker compares it.
7. **Bilingual parity is mechanical.** `--pair` compares the run blocks
   and their outputs between the English and Chinese files; prose is
   free to differ.

## Format specification (normative)

### Fences

````markdown
### Functions and blocks

```emo run id=functions
def apply_twice(n Int64, f Block) Int64 {
  return f(f(n))
}

const double = -> (x Int64) { return x * 2 }
println(apply_twice(3, double))
```

```output
12
```
````

- The info string is `emo` followed by exactly one of `run` or
  `no-run`, then optional `key=value` attributes.
- Attributes: `id=<slug>` (required to be unique; defaults to the
  nearest heading slug plus the block's ordinal), `deps=<a,b>`
  (comma-separated stdlib package names), `timeout=<seconds>`
  (default 10).
- A block's body is a complete entry module (`main.emo`): top-level
  statements, defs, and class declarations are all allowed.
- A `run` block's expected stdout is the next fenced block whose info
  string is exactly `output`, with only whitespace between them. No
  `output` block means stdout must be empty. A stray `output` block is
  a parse error.
- A fence must start in column 0; a body line starting with three
  backticks is a parse error (it would close the fence).
- `no-run` blocks are listed in the report by id, so their count stays
  visible.

### Validation rules

| Check | Failure |
| --- | --- |
| every `emo` fence carries `run` or `no-run` | parse error, names the line |
| `id` unique per file | parse error |
| every `require "x"` has a matching `deps=` entry | parse error |
| every `deps=` entry is required by the block | parse error |
| `run` block exits 0, stderr empty | block failure |
| stdout equals the `output` block | block failure, prints a diff |
| at least one run block per chapter | parse warning |

### Placement

- `docs/tour.md` — English, the authored source.
- `docs/zh-CN/tour.md` — Chinese translation, same block sequence.
- Linked from `README.md` → Documentation → Guides and from
  `docs/zh-CN/README.md` → 文档 → 指南.
- `examples/language_tour/` stays: it is the one-program, all-target
  golden; the final chapter points at it as the next read.

## Execution model

For each `run` block, in document order:

1. Parse the Markdown into an ordered list of
   `{id, code, deps, timeout, expect}` records.
2. Create a temporary directory `tour-<id>/`.
3. Write the generated manifest:

   ```emo
   package {
     name = "emo/tour/<id>"
     version = "0.1.0"
     targets = ["wasm"]

     deps {
       "json" = "0.1.0"
     }
   }
   ```

4. Write `main.emo` with the block body unchanged.
5. Run, with the temporary directory as the working directory:

   ```console
   emo run --target wasm --no-color main.emo
   ```

   `emo run` requires the working directory to hold `package.emo`
   (E5010), which is why the runner never executes a block in place.

6. Capture stdout and stderr, enforce the timeout externally (the
   `--curfew` flag governs only the interpreter's own run, which the
   Wasm target refuses), and compare stdout with `expect` byte for
   byte.
7. Delete the temporary directory unless `--keep`; on failure, print
   the id, the block's starting line, the captured stderr, and a
   unified diff of expected versus actual with temporary paths
   rewritten to `<tour>/<id>`.

Environment: `EMO_REGISTRY` unset (the bundled stdlib is the registry),
`NO_COLOR=1`. The runner requires `emo` (built by the recipe) and
`node`; either missing is a distinct, named failure.

Optional artifact mode for the website: `--emit-dir DIR` builds each
block with `emo build --target wasm -o DIR/<id>` and keeps the
`.wasm` + `.wat` pair beside the run.

## Tooling

### `devtools/tour-check.sh`

```
devtools/tour-check.sh [--keep] [--filter ID] [--emit-dir DIR] FILE...
devtools/tour-check.sh --pair EN.md ZH.md
```

- Shell + awk, no new dependency; follows `just example`'s style and
  its `cmp -s` byte comparison. An `awk` extractor turns the Markdown
  into one record per block; the shell runner builds and runs each one.
- Report: one `ok` / `FAIL` line per block (the id and the source line
  on a failure, plus stderr and a unified diff) and a summary
  (`N blocks, M ok, K failed, S skipped`); exit 0 on success, 1 on any
  block failure, 2 on a parse error, 3 on a missing tool.
- Blocks run sequentially in document order. The measured cost of the
  full tour (22 runnable blocks) is about six seconds, so parallelism
  does not earn its place; `--jobs` stays out.
- `--pair` compares the `(info, code, output)` sequence of two files,
  ignoring prose.
- `devtools/tour-check-selftest.sh` pins the rejection paths: an
  unlabeled fence, a duplicate id, a `require` without `deps`, a stray
  `output` block (all exit 2), wrong stdout, and a program that does
  not compile (both exit 1).

### `justfile`

```just
tour:
    dune build src/emo_cli/emo.exe
    devtools/tour-check.sh docs/tour.md docs/zh-CN/tour.md
    devtools/tour-check.sh --pair docs/tour.md docs/zh-CN/tour.md

tour-selftest:
    devtools/tour-check-selftest.sh
```

The repository has no checked-in CI workflow today; `just tour` is the
gate. If a workflow returns, it runs the same recipe after the existing
Wasm/Node setup.

## Content outline

One file, quickstart first; each chapter is a heading, prose, one to
three runnable blocks, and their outputs.

| # | id | Chapter | Blocks |
| --- | --- | --- | --- |
| 0 | `quickstart` | A ten-minute program, read top to bottom | 1 |
| 1 | `values` | Bindings, numbers, Bool, strings, interpolation | 2 |
| 2 | `control-flow` | `if`/`else`, `for`, `while`, `break`/`continue` | 2 |
| 3 | `functions` | `def`, named arguments, trailing blocks, `-> (x)`, `?` | 3 |
| 4 | `objects` | `class`, `init`, methods, value semantics, `interface` | 3 |
| 5 | `enums` | `enum`, `case`, patterns, `when`, exhaustiveness | 2 |
| 6 | `collections` | `Array`, `List`, `Map`, `ArrayBuilder`, iteration | 2 |
| 7 | `errors` | `(R.ok, v)` / `(R.error, why)`, binding patterns, `raise` | 3 |
| 8 | `modules` | `require`, manifest `deps`, `internal/` (with `json`) | 2 |
| 9 | `processes` | `do`, `<-`, `receive`: a ping-pong | 2 |
| 10 | `business` | JSON config + order validation + Map report | 1 |

Roughly 23 runnable blocks; target under three minutes on a developer
machine.

The business chapter is the payoff: a small order-report program that
parses a JSON config, validates line items through `(R, …)` values,
totals them by category in a `Map`, and prints a report.

## Tasks

### M0 — Spike

- [x] T0.1 — Write this plan to `docs/tour/PLAN.md`. (Done 2026-11-27.)
- [x] T0.2 — Implement `devtools/tour-check.sh`: parse fences, generate
      the manifest, build with `emo build --target wasm`, run under the
      compiler's bundled Node host, compare, report.
- [x] T0.3 — Add the first blocks (`quickstart`, `values`, `errors`) to
      `docs/tour.md` and make them pass; the rest of the tour followed.
- [x] T0.4 — Measure the per-block cost: 22 runnable blocks run in about
      six seconds (≈0.2 s per block after a ≈1.5 s host build), so the
      gate stays sequential and `--jobs` is not added.

**Acceptance:** met — `devtools/tour-check.sh docs/tour.md` is green and
the timing is recorded above.

### M1 — English core

- [x] T1.1 — Chapters 0–5 authored (eight runnable blocks), all passing.
- [x] T1.2 — `just tour` wired; `README.md` and `docs/zh-CN/README.md`
      link the tour.
- [x] T1.3 — `devtools/tour-check-selftest.sh` pins the rejection paths:
      an unlabeled `emo` fence, a duplicate id, a `require` without
      `deps`, and a stray `output` block exit 2; wrong stdout and a
      program that does not compile exit 1.

**Acceptance:** met — `just tour` is green; every Emo fence is labeled;
`docs/tour.md` renders on GitHub without broken blocks.

### M2 — Chapters and translation

- [x] T2.1 — Chapters 6–10 authored, the business slice included.
- [x] T2.2 — `docs/zh-CN/tour.md` translated; `--pair` green.
- [x] T2.3 — A prose review pass: every claim is backed by a block, and
      the one `no-run` block states why it cannot run. The Wasm receive
      limit (head-only dispatch) is stated in the processes chapter and
      its runnable blocks stay FIFO.

**Acceptance:** met — both files pass, and `--pair` reports identical
executable payloads.

### M3 — Polish

- [x] T3.1 — Failure output: id, source line, stderr, unified diff, and
      temporary paths rewritten to `<tour>/<id>`.
- [x] T3.2 — Timing budget recorded (≈6 s for 22 blocks); no `--jobs`.
- [x] T3.3 — The tour is linked from the docs index in both READMEs and
      from the final chapter's "where next" list.

**Acceptance:** met — a broken block fails with a readable report and a
non-zero exit (pinned by the selftest); the green run is under budget.

### M4 — Optional

- [ ] T4.1 — `emo tour` reads the Markdown embedded in the binary,
      the way `emo man` reads `docs/stdlib/`.
- [ ] T4.2 — The website renders a Run button over
      `projects/emo-playground`'s run path.

Each M4 item starts only if it earns its place; neither blocks M0–M3.

## Risks and mitigations

- **Per-block build cost.** Measured: 22 runnable blocks in ≈6 s
  (≈0.2 s per block after a ≈1.5 s host build). Sequential is well under
  the budget, so parallelism is not added.
- **Wasm `receive` dispatches the head only.** A guard, or a shape the
  head does not match, aborts with the case-no-match death instead of
  scanning past the message; selective receive remains the interpreter
  and native surface. The processes chapter says so and keeps its
  runnable blocks FIFO.
- **Node availability and version.** The Wasm target is WasmGC and needs
  a recent Node. The runner names the missing tool; `emo doctor` already
  reports it.
- **Diagnostics that leak temporary paths.** Normalize before printing.
- **Wasm capability gaps.** No `net`/`http`; `file`/`os` work only
  partly through the host. Keep the runnable surface to pure Emo and the
  pure stdlib packages; state the gaps in prose.
- **Output drift from formatting.** All goldens use the language's own
  `%g` rendering and insertion-ordered `Map`, so bytes are stable.
- **Translation drift.** `--pair` covers code and output; prose is
  covered by review, as everywhere else in `docs/zh-CN/`.
- **Prose claims that the code does not test.** Every chapter must make
  its point in a block; prose explains, it does not assert untested
  behavior.

## Open questions

1. One file or two (`quick.md` + `full.md`)? Proposal: one file, with
   the quickstart as chapter 0, until the full file passes ~10 minutes
   of reading.
2. Should `no-run` blocks be allowed at all? Proposal: yes, but capped
   by review and counted in the report; the alternative is omitting the
   topic.
3. Does the tour eventually ship in the binary? Deferred to M4.

## Acceptance summary

Met 2026-11-27:

- `docs/tour.md` and `docs/zh-CN/tour.md` exist and are linked.
- Every `emo` fence is labeled; every `run` block passes on
  `emo build --target wasm` + the compiler's bundled host.
- `just tour` (both files + `--pair`) is green; `just tour-selftest`
  covers the rejection paths.
- A broken block fails loudly with a readable report.
- The whole run takes about six seconds.
