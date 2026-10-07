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
| `just install-dev` | The source install through the opam switch — the route that also brings the `ocaml` compilation target. |
| `just uninstall [PREFIX]` | Remove the standalone binary. |
| `just package` | Assemble this platform's distributable archive into `dist/` — the artifact `release.yml` drafts a GitHub Release from. |
| `just test` | The full test suite. |

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
- [`.github/workflows/release.yml`](../.github/workflows/release.yml)
  — the per-platform release automation.
