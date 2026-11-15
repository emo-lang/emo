# Step 86 — The standard library's manual pages: `emo man`

**Milestone:** M47 — The library's manual · **Prereq:** step 24 (the
toolchain: the standard library rides the binary as generated data) ·
**Related:** `docs/stdlib/`, `docs/stdlib.md`, `docs/toolchain.md`,
`devtools/gen-stdlib-data.sh` · **Status:** done — every page renders
from the binary, `emo man` lists the pages and `emo man <package>`
renders one, and the page data regenerates from the docs.

## Why this step exists

The standard library's reference was repository-only. A developer with
the release binary had the packages inside it but no way to ask what a
package exports, what a call takes and answers, or what the examples
look like — the docs did not ship, and no command answered the
question. The docs already carry the whole answer (signatures,
parameters, results, examples); the missing piece was a door from the
terminal, beside the compiler that ships the packages.

## Goal

`emo man` lists the pages the bundled standard library carries; `emo
man <package>` renders that package's reference page as a man page —
NAME, SYNOPSIS (the manifest's pin and the `require`), DESCRIPTION
(the doc's own sections, signatures and examples intact), SEE ALSO —
from page data generated into the binary at build time. `emo man
stdlib` renders the overview.

## Decisions settled here

- **The docs are the source of truth, embedded rather than copied.**
  `docs/stdlib.md` and `docs/stdlib/*.md` are the reference; a build
  rule runs `devtools/gen-man-data.sh` and generates the `(name,
  markdown)` module the CLI carries, the same route the stdlib sources
  take (T24.2). An installed binary answers with nothing beside it,
  and editing a page plus rebuilding is the whole update.
- **The renderer reads the docs' own Markdown subset.** Headings,
  paragraphs, fenced code, bullets, numbered lists, tables, inline
  code, links, and emphasis; body text at the man indent reflowed to
  `COLUMNS` (80 unset), code indented and never reflowed, and a table
  too wide for the page shrunk and wrapped cell by cell. No Markdown
  library joins the toolchain for this.
- **A page's NAME line comes from the overview's table**, the same
  sentence the repository's package table shows; a package without a
  row falls back to its first sentence. SYNOPSIS takes the version
  from the embedded manifest, so the pin shown is the one the
  compiler resolves, not a copy that can drift.
- **The overview is a page too.** `emo man stdlib` renders
  `docs/stdlib.md`, and the page is listed among the packages.
- **The pager is used only when it can run.** With stdout a terminal
  and `MANPAGER` (or `PAGER`) naming an executable on `PATH`, the page
  is piped through it; a stale or mistyped pager prints the page
  instead of swallowing it.
- **An unknown name refuses.** `emo man nope` prints `no manual entry
  for \`nope\`` on stderr and exits 65, naming the command that lists
  the pages.

## Acceptance

- `emo man` lists every bundled package, one line each, with the
  overview's summary and the package's targets.
- `emo man json` prints `JSON(3)`, the NAME line, the SYNOPSIS pin and
  `require`, and the doc's sections (`USING THE PACKAGE`, `VALUES`,
  `DECODE`, `ENCODE`, …) with signatures and examples.
- `emo man stdlib` prints the overview, its package table wrapped to
  the terminal.
- Every page in `docs/stdlib/` renders; `emo man nope` exits 65.
- `dune build --profile release src/emo_cli/emo.exe` is green, and
  `test/emo_cli`'s `man` group compiles.

## Tasks

- [x] **T86.1** — The data: `devtools/gen-man-data.sh` generates the
      `(name, markdown)` module from `docs/stdlib.md` and
      `docs/stdlib/*.md`; `src/emo_cli/dune` carries the rule and the
      generated module.
- [x] **T86.2** — The renderer: `src/emo_cli/emo_man.ml` — the
      Markdown subset, the man layout (header, NAME, SYNOPSIS,
      DESCRIPTION, SEE ALSO), the package list from the overview's
      table, and the pager with its runnable check.
- [x] **T86.3** — The command: `emo man [package]` in `emo_cli.ml`,
      the `man` group in `test/emo_cli`.
- [x] **T86.4** — The docs and tracking: `docs/toolchain.md` and
      `docs/stdlib.md` + zh mirrors, this step,
      `plan/README.md`'s milestone bullet and status row,
      `docs/TASKS.md`'s M47 section + zh mirror, CHECK.md's settle
      record.
