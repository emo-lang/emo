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
| Build a native program with `emo build` | the target's own toolchain on PATH — `cc` for the default `c` target; `ocamlfind` (with `unix`, `ssl`) for the `ocaml` target (corrected 2026-10-07, see the step-26 update below) | only a direct machine-code backend would remove `cc` |
| A self-contained output binary | the runtime already rides inside the output on every target | static linking of the remaining C dependencies (libc, OpenSSL), per platform |

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
  detects the target toolchains and, when one is missing, prints the
  platform's install command — `brew install ocaml opam
  && opam install ocamlfind ssl`, `apt install ocaml ocaml-findlib
  libssl-dev`, or the project's own setup script. With the user's consent it
  may run the system package manager. It does not download OCaml itself.
  (The `emo_runtime.cmxa` version check below is obsolete — no `.cmxa` ships,
  see the step-26 update.)
- **Provision through the ecosystem.** Publish Emo as an opam package and a
  Homebrew formula; `opam install emo` then brings a matching OCaml,
  `ocamlfind`, and runtime, with the version relationship enforced by the
  package manager. `CHECK.md` already lists `opam` and Homebrew as the
  source-building channels.
- **Version matching is mandatory.** The user's `ocamlopt` must match the
  `emo_runtime.cmxa` the tool ships; `emo doctor` turns a mismatch into one
  clear message rather than a raw toolchain error. *(Obsolete since
  2026-10-07: no `.cmxa` ships — see the step-26 update below.)*

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

## Update 2026-10-07: the release tooling is scheduled and landed (step 25)

The deferral above held until the `c` backend shipped (step 24); M9 —
Toolchain (`plan/step-25-toolchain.md`) now schedules what this
document left unscheduled:

- **The tag-triggered release workflow**
  (`.github/workflows/release.yml`) builds the release binary on four
  platforms — Linux x86_64/aarch64 (Ubuntu 22.04, the oldest
  supported glibc: 2.35) and macOS x86_64/arm64 — runs the test suite
  against the release build, and packages through
  `devtools/package-release.sh`: the binary, the license, and nothing
  else, since the standard library rides inside the binary. Linux
  archives are verified in a clean `ubuntu:22.04` container, not on
  the builder. The draft GitHub Release carries `SHA256SUMS`.
- **macOS signing and notarization complete locally.** Hosted runners
  hold no Developer ID private key, so `release.yml` drafts the macOS
  archives unsigned by design; `devtools/notarize-release.sh`
  (`just notarize <tag>`) then signs them with the keychain's
  Developer ID Application identity — hardened runtime, timestamped —
  submits through notarytool (a keychain profile, an App Store Connect
  API key trio, or Apple ID credentials), re-uploads the archives,
  and refreshes `SHA256SUMS`. A flat executable cannot carry a staple
  (stapler embeds tickets only into .app/.dmg/.pkg), so Gatekeeper
  validates the notarized binary's ticket online at first run.
- **Native Windows is deferred, recorded as the blocker it is.** The
  C runtime's processes are POSIX `ucontext` fibers and its sockets
  are non-blocking fds (T24.9/T24.10); a native Windows port is that
  scheduler and IO layer re-based on Windows primitives, and the
  prebuilt channel waits for it. WSL2 remains the supported Windows
  path, and Microsoft Trusted Signing stays the recorded signing
  route for when the port lands.
- **`emo doctor` replaced the interim shape above**: it is the
  target-aware environment check — a cc compile-and-run smoke for the
  default `c` target, the ocaml target reported as needing a source
  install on a prebuilt machine — and its exit code reflects only
  what is actually broken. *(Corrected 2026-10-07: the ocaml line
  reports the toolchain, never the installation shape — see the
  step-26 update below.)*

## Update 2026-10-07: target independence (step 26)

Step 26 (`plan/step-26-target-independence.md`) removed the
installation-shape question this document kept answering. The
runtime-independence principle: a target's runtime is written in the
target's language, carried as generated data inside the compiler, and
compiled by the target's own toolchain on the user's machine — the
host contributes only the emitter. Concretely:

- **The `emo_runtime.cmxa` story is gone.** The ocaml target's runtime
  is now `emo_ocaml_runtime.ml` — one standalone file (values, the
  deterministic scheduler, file and socket IO, TLS) riding the compiler
  as generated data, the C runtime's mechanism. `emo build --target
  ocaml` writes it next to the emitted `main.ml` and invokes the
  target's `ocamlopt`; no `.cmxa` is looked up beside the binary or in
  the host build tree, none ships, and the version-matching rule above
  has nothing left to match.
- **The ocaml target works on any installation shape.** Verified from
  the release layout: a lone `emo` binary in an empty directory builds
  the golden subset wherever the OCaml toolchain is on PATH —
  `ocamlfind` with the `unix` and `ssl` packages the runtime itself
  uses. "A source install brings the ocaml target" is no longer the
  story; the toolchain is.
- **eio leaves the link line.** The provisional plan kept `eio_main` as
  a target-side dependency; the port settled otherwise — the standalone
  scheduler is the deterministic poll loop compiled programs already
  ran on (Unix, no eio), so the runtime declares `unix` (ships with the
  compiler) and `ssl` (the one opam dependency), refused with a clear
  message when absent.
- **`emo doctor` lost its installation line.** The
  "installation: source/prebuilt" report is gone — every target's line
  names its own toolchain, and the exit code reflects only what is
  actually broken.

## References

- `CHECK.md` — "Binary / CLI tool distribution mechanism".
- `docs/native-backend.md` — the emit-OCaml pipeline and the OCaml-toolchain
  requirement.
- `docs/runtime-and-freestanding.md` — runtime versus freestanding, and what a
  native output carries.
- `docs/industrial-software.md` — the FFI gate.
- `plan/step-23-hosted-native-ffi.md` — the `c` backend assessment.
