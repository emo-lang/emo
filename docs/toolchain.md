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
| `just build` | Compile the release binary — the single artifact every other recipe uses. |
| `just install [PREFIX]` | The dev install: a symlink in `~/.local/bin` (default) to this tree's build output — every `dune build` here refreshes `emo` immediately. Re-runnable; verify with `emo doctor`. |
| `just install-dev` | The source install through the opam switch. |
| `just uninstall [PREFIX]` | Remove the installed `emo` link. |
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
