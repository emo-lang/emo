# Toolchain distribution

Written 2026-10-06. The decided direction and its rationale; project-state
claims reflect the repository as of that date.

The question: how is the Emo toolchain distributed as a usable binary, when
`emo build` compiles emitted OCaml with the user's own OCaml toolchain?

## The problem is three problems

Binary distribution is usually discussed as one thing. The `emo build`
pipeline —

```
parse → check → lower → specialize → emit OCaml → ocamlfind ocamlopt → binary
```

— has three separable dependencies, and they do not have the same answer:

| Goal | Requirement today | Removed by |
| --- | --- | --- |
| Run the tool (`emo run`/`repl`, `wasm`/`beam`/`typescript` builds) | a self-contained `emo` executable | already met — `ocamlopt` links the OCaml runtime into a native executable |
| Build a native program with `emo build` | `ocamlfind` + `ocamlopt`, the Emo runtime `.cmxa`, and the OCaml stdlib headers on the user's machine | only the `c` backend (or a direct machine-code backend) |
| A self-contained output binary | the OCaml and Emo runtimes already ride inside the output | static linking of the remaining C dependencies (libc, OpenSSL), per platform |

The distribution decision in `CHECK.md` targets the **second** row: dropping
the OCaml-toolchain dependency *from the tool*. Static-linking the emit-OCaml
output does not touch it — the dependency is at build time, not run time, so
a bigger binary buys nothing here. The `c` backend is what replaces
`ocamlfind ocamlopt` with `cc`; it does not remove `cc`, only lowers the bar.

## The decided direction

- **The `c` backend is deferred to after 1.0.** Until it lands, the emit-OCaml
  backend stays, and `emo build` (the native/`ocaml` target) requires the
  user's OCaml toolchain. This is documented, not hidden.
- **Ship the tool now.** A native `emo` binary already carries the OCaml
  runtime, so distribution for `emo run`/`repl` and the wasm/beam/typescript
  targets needs no external toolchain today.
- **A check and a guide, not a downloader.** A toolchain check (`emo doctor`)
  detects `ocamlfind`/`ocamlopt`, verifies the version against the
  `emo_runtime.cmxa` shipped beside the binary, and, when they are missing or
  mismatched, prints the platform's install command — `brew install ocaml opam
  && opam install ocamlfind`, `apt install ocaml ocaml-findlib`, or the
  project's own setup script. With the user's consent it may run the system
  package manager. It does not download OCaml itself.
- **Provision through the ecosystem.** Publish Emo as an opam package and a
  Homebrew formula; `opam install emo` then brings a matching OCaml,
  `ocamlfind`, and runtime, with the version relationship enforced by the
  package manager. `CHECK.md` already lists `opam` and Homebrew as the
  source-building channels.
- **Version matching is mandatory.** The user's `ocamlopt` must match the
  `emo_runtime.cmxa` the tool ships; `emo doctor` turns a mismatch into one
  clear message rather than a raw toolchain error.

## Platforms: native Windows and WSL2

The emit-OCaml pipeline is POSIX-wired, so **native Windows is not a supported
target** — and the cause is not OCaml alone, but what the runtime links:

- the emitted program's link line hardcodes `eio_posix` (`src/emo_cli/emo_cli.ml`),
  so a built program is POSIX-only;
- the runtime links `unix` and `ssl` (OpenSSL bindings), and the scheduler is
  OCaml 5 effects on Eio (`src/emo_sched/dune`).

One consequence worth stating plainly: even a prebuilt Windows `emo` could run
the interpreter and the `wasm`/`beam`/`typescript` targets, but `emo build`'s
native target would not work on Windows, because OCaml does not cross-compile
readily. OCaml itself supports Windows, but it is the least-exercised
configuration — the `Unix` module is a subset, the package ecosystem is
POSIX-heavy, and the OCaml 5 effects/multicore runtime is least tested there.

**WSL2 is the supported Windows path.** WSL2 is a real Linux kernel in a
lightweight VM, so Emo sees an ordinary Linux environment: `eio_posix`,
`unix`, and `ssl` (`libssl-dev`) all work, the OCaml/opam toolchain installs as
usual, and the Linux prebuilt channel applies. Notes: install OCaml/opam inside
WSL, not a Windows OCaml; keep the project on the Linux filesystem (`~/…`), not
`/mnt/c/…`, where cross-boundary I/O is slow and defeats incremental builds;
use WSL2, not WSL1, whose syscall-translation layer is a poor fit for the OCaml
5 effects runtime.

Native Windows binaries are a later effort; lifting the POSIX wiring is part of
what a portable runtime — the `c` backend, or a dedicated port — must address.

## Rejected: a self-service toolchain downloader

An `emo toolchain download` command that fetches and installs OCaml was
considered and rejected:

- It would make Emo a partial package manager and a redistributor of an
  entire compiler — per-platform builds, signing, checksums, and supply-chain
  trust become the project's responsibility.
- OCaml has no single official prebuilt binary per platform, `ocamlfind` is a
  separate package, and native OCaml on Windows is awkward — exactly where an
  automatic installer is most wanted.
- The download would have to stay version-matched to the shipped `.cmxa`, so
  the downloader and the tool are coupled.
- It is a subsystem the `c` backend will obsolete, and removing a "download
  the toolchain" command is disruptive to users who adopted it. A check
  creates no such lock-in.

If a downloader is ever built it must be pinned and checksummed — never
`curl | sh` — and labelled a temporary facility.

## The `c` backend is not only about distribution

Deferring it to after 1.0 is a scheduling choice, not a claim that
distribution is its only purpose. The same backend is also the route to
native builds without OCaml, outputs that do not carry the OCaml runtime, a
real C FFI (pointers, structs, arrays, callbacks — the hard gate in
`docs/industrial-software.md`), and HPC codegen (vectorization, OpenMP
pragmas). Those timelines are independent of distribution.

## References

- `CHECK.md` — "Binary / CLI tool distribution mechanism".
- `docs/native-backend.md` — the emit-OCaml pipeline and the OCaml-toolchain
  requirement.
- `docs/runtime-and-freestanding.md` — runtime versus freestanding, and what a
  native output carries.
- `docs/industrial-software.md` — the FFI gate.
- `plan/step-23-hosted-native-ffi.md` — the `c` backend assessment.
