# The emo toolchain: building and installing the CLI

Written 2026-10-07. The decided facts and the automation that ships
with the repository.

## The CLI is built by dune, not by the c target

`emo` — the command-line tool — is written in OCaml, and the `c`
target compiles *Emo* source to C. The compiler therefore cannot build
itself: the one step that needs an OCaml toolchain is building `emo`
itself, and self-hosting is explicitly not a goal
([`plan/README.md`](../plan/README.md)).

So "building the emo CLI on the c target" is not a thing, and the
phrase means its opposite — the division of labor is:

1. **Build `emo` once with dune** (release profile). The product is a
   single self-contained binary: every backend, the standard library
   embedded as generated data, and the C runtime inside.
2. **Everything after that needs no OCaml.** The installed binary's
   default build path is the `c` target: `emo build` invokes the
   system `cc` and nothing else, so a machine with the installed
   binary builds Emo programs with no OCaml toolchain — verified by
   step 24's acceptance (a lone binary in an empty directory runs,
   checks, builds, installs dependencies, and publishes) and reported
   per target by `emo doctor`.

## The justfile automates exactly this chain

| Recipe | What it does |
| --- | --- |
| `just build` | Compile the release binaries — `emo` and `emo-lsp`, the artifacts every other recipe uses. |
| `just install [PREFIX]` | The dev install: symlinks in `~/.local/bin` (default) to this tree's build output — every `dune build` here refreshes `emo` and `emo-lsp` immediately. Re-runnable; verify with `emo doctor`. |
| `just install-dev` | The source install through the opam switch. |
| `just uninstall [PREFIX]` | Remove the installed `emo` and `emo-lsp` links. |
| `just package` | Assemble this platform's distributable archive into `dist/` — one platform, for quick checks; a release builds all three through `devtools/build-release.sh`. |
| `just release TAG` | The whole release on this machine: tag and push to the source host, build and test all three archives (macOS arm64 natively, both Linux architectures in Docker — `just release-image` builds their images once), notarize, and publish to the download site. |
| `just test` | The full test suite. |

## The ocaml target needs only the OCaml toolchain

Since step 25 (target independence), every target runtime rides inside
the `emo` binary as generated data — the C runtime, the TypeScript
prelude, and the ocaml target's standalone runtime
(`emo_ocaml_runtime.ml`) alike. `emo build --target ocaml` writes the
runtime and the emitted program side by side and hands both to the
target's own `ocamlopt`; nothing is looked up beside the binary or in
the host build tree. The target therefore works on any installation
shape — a lone release-layout binary included — wherever the OCaml
toolchain is on PATH: `ocamlfind` with the `unix` and `ssl` packages
the runtime itself uses (opam brings both). Without it, `emo build`
and `emo doctor` name the toolchain; there is no source-install
conditional and no version matching against shipped libraries, because
none ship.

Notes from the implementation: dune marks its outputs read-only, so
the install recipe copies to an incoming name, strips, and `mv`s into
place (an `mv` needs write permission on the directory only, which is
what makes re-installs work); `just package` requires
`devtools/package-release.sh`, which resolves its output directory to
an absolute path before staging — a relative `dist` argument would
otherwise resolve from inside the staging directory and fail.

## The repl's line editor

`emo repl` edits its input with a vendored
[linenoise](https://github.com/antirez/linenoise) — the library
redis-cli reads with — compiled into the binary through dune's
`foreign_stubs`. What the editor adds to the session:

- **History recall across sessions.** Every non-empty line joins the
  history as typed (up to 1000 entries), and the session's end saves it
  to the state file: `$EMO_STATE_DIR/repl-history` when set, else
  `$XDG_STATE_HOME/emo/repl-history`, else
  `$HOME/.local/state/emo/repl-history`. Up and down walk the entries;
  a file the system will not carry is one warning on stderr and the
  session continues — a missing file is a first session's normal shape
  and says nothing.
- **Multi-line editing.** Long lines wrap across the terminal's rows
  and stay editable; pasted input lands whole (bracketed-paste aware,
  large pastes folded for display).
- **The continuation prompt indents by bracket depth.** While the
  session is collecting an unbalanced block, `... ` grows two spaces
  per still-open `{`/`(`/`[` — the prompt shows where the block stands.
  The indent is visual guidance; the editor places no cursor beyond it.
- **Ctrl-C abandons, it does not kill.** The editor consumes Ctrl-C;
  the repl discards the pending input and renders a fresh prompt. An
  empty line's Ctrl-D ends the session, as EOF always has.

The editor takes the seat only when stdin and stdout are both
terminals. Pipes, redirects, and scripts keep the plain line-reading
path byte for byte — `emo repl`'s piped behavior, and every test that
drives the session, never touch the terminal machinery. The
`repl-history` file is written 0600 by the library; a second
concurrent session's save wins the file, which is the one known
limitation. TAB completion is deliberately absent — the callback
rides the binding, but what completes (keywords, the session's names,
required packages) is a design of its own.

## The standard library's reference pages

`emo man` reads the standard library's reference from inside the
binary — the same pages `docs/stdlib/` carries, one per package plus
[`docs/stdlib.md`](stdlib.md) as the overview:

```console
$ emo man            # list the pages the bundled library carries
$ emo man json       # render the json package's page
$ emo man stdlib     # the standard library's overview
```

A package page reads like a man page: NAME, SYNOPSIS with the
manifest's pin and the `require`, DESCRIPTION holding the doc's own
sections, and SEE ALSO. The renderer reads the Markdown subset the
pages are written in — headings, paragraphs, fenced code, bullets,
numbered lists, tables, inline code, links, and emphasis — and lays it
out for a terminal: body text at the man indent, reflowed to `COLUMNS`
(80 when unset); code blocks indented and never reflowed; a table too
wide for the page shrunk and wrapped cell by cell. When stdout is a
terminal and `MANPAGER` (or `PAGER`) names a command that can run, the
page is piped through it; otherwise it is printed.

The pages are not copied by hand: `devtools/gen-man-data.sh` generates
the `(name, markdown)` data module from `docs/stdlib.md` and
`docs/stdlib/*.md` at build time, so editing a page and rebuilding is
the whole update — the route the stdlib sources themselves take
(T24.2). The reference is English; the Chinese translations under
`docs/zh-CN/stdlib/` are for reading in the repository.

## The language's introduction pages

`emo docs` serves the introduction pages under `docs/intro/` from
inside the binary — the pages an AI harness reads as development
documentation alongside a project it is working on:

```console
$ emo docs            # list the pages the binary carries
$ emo docs syntax     # print the syntax page
$ emo docs type-system
```

Unlike `emo man`, which renders its pages for a terminal, `emo docs`
passes each page through as the markdown it is written in — the reader
is a program, which reads markdown and pipes, so there is no pager and
no layout. Without a topic named, the pages it carries are listed.
The pages ride the binary the same way the manual's do:
`devtools/gen-docs-data.sh` generates the `(name, markdown)` data
module from `docs/intro/*.md` at build time. The pages are English;
the Chinese translations under `docs/zh-CN/intro/` are for reading in
the repository.

## References

- [`docs/toolchain-distribution.md`](toolchain-distribution.md) — why
  the distribution has this shape (the design record).
- [`plan/step-24-toolchain.md`](../plan/step-24-toolchain.md) — the
  step that built it (M7 — Toolchain).
- [`plan/step-25-target-independence.md`](../plan/step-25-target-independence.md)
  — the step that freed the targets from the installation shape (M8 —
  Target independence).
- [`devtools/build-release.sh`](../devtools/build-release.sh) — the
  local release pipeline's build leg: all three archives, tested and
  smoke-verified on this machine.
- [`devtools/notarize-release.sh`](../devtools/notarize-release.sh)
  and [`devtools/publish-release.sh`](../devtools/publish-release.sh)
  — the legs that carry a built release through Apple notarization
  and onto the download site.
- [`plan/step-79-repl-linenoise.md`](../plan/step-79-repl-linenoise.md)
  — the step that brought the repl its line editor (M39).
