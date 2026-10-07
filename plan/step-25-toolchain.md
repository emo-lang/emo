# Step 25 — Toolchain distribution & release (v1.0.0)

**Milestone:** M9 — Toolchain · **Prereq:** step 24 (the `c` target; the
`native` → `ocaml` rename landed with it) · **Related:**
`docs/toolchain-distribution.md` (the design record this step
schedules), `CHECK.md` ("Binary / CLI tool distribution mechanism" —
the direction is settled there; "release tooling itself is
unscheduled" is what this step changes), `plan/step-24-c-target.md`
(the backend being distributed) · **Status:** not started (tasks
written)

## Why this step exists

M8 made *built programs* self-contained: `emo build --target c`
needs only the system `cc`. The *tool* is still a source-checkout or
opam-switch artifact. The pieces of a distribution already exist in
embryo — the C runtime ships as generated data inside the compiler
(not installed files), the stdlib resolves next to the running
binary (`../../stdlib/registry` through the realpath), `emo publish`
uploads through an embedded uploader program — but nothing assembles
them into something downloadable, and three commands a product
needs (`emo new`, `emo install`, `emo doctor`) do not exist. The CLI
today is `run`/`repl`/`check`/`build`/`deps`/`publish`/`version`.

Meanwhile the defaults still assume a source install: `emo build`
defaults to `--target ocaml`, which a binary-only machine can never
satisfy, and the dependency cache defaults to the temp directory.
v1.0.0 is the release where the tool is downloadable and the
defaults match the download. The decided direction
(`CHECK.md`, `docs/toolchain-distribution.md`): prebuilt binaries
per platform on GitHub Releases as the primary channel, `opam` and a
Homebrew formula as the source-building alternatives, `emo doctor`
as the check-and-guide command; a self-service toolchain downloader
was rejected and stays rejected.

## Goal

The release workflow, run on a version tag, produces signed
per-platform archives (Linux x86_64/aarch64, macOS x86_64/arm64)
whose binaries pass end-to-end acceptance on every platform. A
machine with only the installed binary — no OCaml, no opam, no
repository — runs, checks, and builds Emo programs through the `c`
target, scaffolds with `emo new`, installs dependencies with
`emo install`, and diagnoses its environment with `emo doctor`.

Boundaries, stated plainly:

- **The public registry service is a separate milestone.** The tool
  ships speaking the filesystem registry plus the bundled stdlib;
  `emo publish` already speaks HTTP. A registry fetch client over
  HTTP lands with the service it talks to, not before.
- **Native Windows is not a v1.0.0 platform.** WSL2 is the supported
  Windows path (`docs/toolchain-distribution.md`); the ucontext
  fibers and non-blocking-fd sockets of the C runtime are the
  recorded port. Microsoft Trusted Signing stays the recorded
  signing route for when that port lands.
- **The c backend's recorded follow-ups** (retain/release emission,
  the zero-copy buffer rung, cross-module type propagation) are
  backend work; they stay with the backend line and do not gate this
  milestone.

## Decisions to settle here (before the gated task)

All four close in `CHECK.md` at T25.1:

- **The default build target — flip `ocaml` → `c`.** A distributed
  binary carries no OCaml toolchain; out of the box, `emo build`
  must work on the download. The `ocaml` target remains for source
  installs and, on a prebuilt installation without its runtime,
  refuses with a message that says exactly that (never raw
  ocamlfind spew).
- **Stdlib: embed, not sidecar.** The bundled stdlib ships as
  generated data inside the compiler — the C runtime's own
  mechanism ("installed files beside the binary" is the rejected
  shape: it breaks single-file channels like a Homebrew binary and
  every unzipped-in-the-wrong-place archive). `EMO_REGISTRY` keeps
  overriding.
- **`emo install` semantics.** It is the project-dependencies front
  end — resolve, fetch, lock, ready to run. Global executable
  installation (the cargo-install shape) is out of scope for 1.0.
- **The dependency cache location.** The temp-directory default
  becomes a durable user cache; `$TMPDIR` is wiped by the OS and a
  product cannot re-fetch on every build.

## Tasks

- [ ] **T25.1** — Design-gate closure and the default target: the
      four settlements above recorded in `CHECK.md`; the `emo build`
      default flips to `c`, with the resolution-gate tests and the
      CI groups re-pointed (the c goldens already cover the target
      itself — nothing new to prove, only the default moves).
- [ ] **T25.2** — The self-contained binary: the bundled stdlib as
      generated data inside the compiler; the registry endpoint
      becomes a filesystem directory or the embedded stdlib;
      `EMO_REGISTRY` still overrides. Verification: a lone `emo`
      copied into an empty directory runs, checks, and builds a
      stdlib-importing program — and `emo publish`'s embedded
      uploader works from it.
- [ ] **T25.3** — `emo new <name>`: the scaffold — `package.emo`
      (name, version, targets) and a hello-world `main.emo`, plus
      `.gitignore`. Strictness holds: an existing directory or
      clashing files refuse with clear errors, no `--force`. The
      scaffold is green the moment it exists — CI creates, checks,
      runs, and builds one.
- [ ] **T25.4** — `emo install`: read the manifest, resolve against
      the registry, fetch into the user cache, write
      `package.lock`; idempotent re-runs change nothing; each
      failure mode — no registry configured, unsatisfiable pin, a
      dependency lacking the requested target — gets its own clear
      message. `emo deps` keeps resolve/update/list as the explicit
      paths.
- [ ] **T25.5** — `emo doctor`: the target-aware environment check,
      replacing the interim ocaml-only shape in `CHECK.md`. Per
      target: `c` — a cc compile-and-run smoke; `ocaml` — the
      runtime `.cmxa` found in the switch, or the honest "prebuilt
      installation: the ocaml target needs a source install
      (`opam install emo`)"; `typescript` — node; `beam` — erlc;
      `wasm` — nothing. Plus the installation shape (prebuilt vs
      source), stdlib presence, and version. Exit non-zero only on
      what is actually broken.
- [ ] **T25.6** — Release packaging and CI: the tag-triggered
      workflow beside the existing CI — per-platform matrix builds
      (Linux x86_64/aarch64, macOS x86_64/arm64), release binaries
      through dune, the archive layout T25.1 settled,
      `SHA256SUMS`, a drafted GitHub Release. The Linux binary is
      portable — static or the oldest viable glibc — verified in
      clean containers, not on the builder.
- [ ] **T25.7** — Signing and the platform gates: macOS codesign
      (hardened runtime) → notarytool → staple, credentials in CI
      secrets — the solved-not-a-blocker from `CHECK.md`, now
      scheduled. Windows: WSL2 documented as the supported path,
      the native prebuilt recorded as deferred with the
      ucontext/socket port named as the blocker;
      `docs/toolchain-distribution.md` updated (both languages).
- [ ] **T25.8** — Provisioning channels and install docs: the
      Homebrew formula (own tap; core when the project qualifies)
      and the opam package — the source channel that brings the
      `ocaml` target. README install sections in both languages:
      prebuilt archives first, then brew, opam, WSL2.
- [ ] **T25.9** — Release acceptance and v1.0.0: on every shipped
      artifact, end to end — download, unpack, `emo doctor`,
      `emo new`, `emo run`, `emo install`, `emo build` (the `c`
      target) — including a stdlib-importing program and the golden
      subset executed from the installed binary. VERSION becomes
      1.0.0 in the release commit; annotated tag, release notes,
      close-out.

## Acceptance

- The release workflow, run on a tag, produces signed archives for
  Linux x86_64/aarch64 and macOS x86_64/arm64 with `SHA256SUMS`,
  drafted as a GitHub Release.
- On every shipped artifact: `emo doctor` healthy; `emo new` →
  `emo run` → `emo install` → `emo build` green on a machine with
  nothing but the archive's contents; a stdlib-importing program and
  the golden subset print byte-for-byte what the source tree prints.
- A binary-only machine (no OCaml, no opam) runs, checks, and builds
  through the `c` target; `--target ocaml` refuses with the
  source-install guidance.
- `emo new`, `emo install`, `emo doctor` exist with the strictness
  rules above; the CLI is `run`/`repl`/`check`/`build`/`deps`/
  `publish`/`new`/`install`/`doctor`/`version`.
- `dune test` green; the default-target flip carries the
  resolution-gate and CI groups with it.

## Open design items

- ~~Default build target~~ — settled at T25.1: `c`.
- ~~Stdlib embed vs sidecar~~ — settled at T25.1: embed.
- ~~`emo install` semantics~~ — settled at T25.1: the project
  front end; global executable installation out of scope for 1.0.
- Whether a pinned, checksummed install script rides T25.8 — it may
  fetch only Emo's own signed archives (never `curl | sh` of
  arbitrary toolchains, per the rejected-downloader rationale); if
  it cannot meet that bar, the archives alone ship.
