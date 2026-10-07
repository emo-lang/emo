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
   step 25's acceptance (a lone binary in an empty directory runs,
   checks, builds, installs dependencies, and publishes) and reported
   per target by `emo doctor`.

## The justfile automates exactly this chain

| Recipe | What it does |
| --- | --- |
| `just build` | Compile the release binary — the single artifact every other recipe uses. |
| `just install [PREFIX]` | The c-target install: the standalone binary into `~/.local/bin` by default, atomically replaced and stripped. Re-runnable; verify with `emo doctor`. |
| `just install-dev` | The source install through the opam switch. |
| `just uninstall [PREFIX]` | Remove the standalone binary. |
| `just package` | Assemble this platform's distributable archive into `dist/` — the artifact `release.yml` drafts a GitHub Release from. |
| `just test` | The full test suite. |

## The ocaml target needs only the OCaml toolchain

Since step 26 (target independence), every target runtime rides inside
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

## References

- [`docs/toolchain-distribution.md`](toolchain-distribution.md) — why
  the distribution has this shape (the design record).
- [`plan/step-25-toolchain.md`](../plan/step-25-toolchain.md) — the
  step that built it (M9 — Toolchain, released as v0.25.9).
- [`plan/step-26-target-independence.md`](../plan/step-26-target-independence.md)
  — the step that freed the targets from the installation shape (M10 —
  Target independence).
- [`.github/workflows/release.yml`](../.github/workflows/release.yml)
  — the per-platform release automation.
