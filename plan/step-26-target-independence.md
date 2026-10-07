# Step 26 — Target independence (runtimes decoupled from the host)

**Milestone:** M10 — Target independence · **Prereq:** step 25 (the
toolchain whose claims this step corrects) · **Related:**
`docs/toolchain.md` (the host/target distinction this step completes),
`CHECK.md` (the backend-naming and runtime-language decisions this
step generalizes), `src/emo_codegen/c/` (the runtime-as-generated-data
pattern being generalized) · **Status:** not started (tasks written)

## Why this step exists

The host/target distinction (2026-10-07): the host language answers
"how was emo built"; the targets answer "what does emo turn your
program into". Fully honoring it means the host contributes only the
emitters — every target's runtime must live in the target's own
ecosystem, never beside the binary and never in the host build tree.

The audit found three of five targets already satisfy this:

- **c** — the runtime is standalone C (`src/emo_codegen/c/`), carried
  as generated data inside the compiler, compiled by the user's `cc`
  at program-build time. The pattern to generalize.
- **wasm** — the runtime (38 functions) compiles into the module; the
  3 imports are the ABI with the wasm *engine*, a different axis from
  the compiler's host language.
- **beam** — one self-contained Core Erlang module standing on OTP
  (the target ecosystem's standard library, as libc is to c); the
  user's `erlc` compiles it.

Two do not:

- **typescript** — the runtime prelude is a *side file*
  (`ts_prelude.ts`, found beside the binary). A release archive ships
  only `bin/emo`, so the typescript target is broken on every
  installed binary today — the same class of bug T25.2 fixed for the
  stdlib and T24 fixed for the C runtime.
- **ocaml** — the runtime *is* the host: eight host libraries
  (`emo_runtime.cmxa` and friends) looked up in the host build tree
  and linked by the host toolchain. It works only inside the
  repository, which is why the T25.1 refusal points at a source
  install — and why that guidance is itself wrong: `opam install emo`
  installs only the executable (verified: seven files, zero `.cmxa`),
  so the ocaml target is unavailable on *every* installation shape
  except the in-tree build.

The user's goal this step schedules: target generation stays the
host's job (the emitters are the compiler), but target runtimes become
fully independent of the host language — so a future host rewrite
(Go, Rust) touches only the emitters, and the ocaml target becomes
usable wherever the *target's* toolchain exists, on any installation.

## Goal

No target's runtime is looked up beside the binary or in the host
build tree: c, ocaml, and typescript runtimes ride inside the compiler
as generated data; wasm and beam runtimes ride inside the emitted
module. `emo build --target ocaml` works on any installation where the
OCaml toolchain (ocamlfind, unix, ssl, eio) is on PATH — no `.cmxa`
lookup, no installation-shape conditionals — and the typescript target
works from the release layout.

## Decisions to settle here

- **The runtime-independence principle (CHECK.md, before T26.1):** a
  target's runtime is written in the target's language, carried as
  generated data inside the compiler, and compiled by the target's own
  toolchain on the user's machine. The host contributes only the
  emitter.
- **The ocaml runtime's dependency policy (before T26.4):** the
  standalone runtime's core (values, strings, scheduler) has zero
  dependencies beyond the OCaml standard library; networking keeps
  `eio_main`/`ssl` as target-ecosystem opam dependencies — declared in
  the runtime's header, refused with a clear message when absent.
  Provisional; settle finally when the scheduler and IO port.

## Tasks

- [ ] **T26.1** — The principle and the ts embed: the principle above
      recorded in `CHECK.md`; `ts_prelude.ts` embedded as generated
      data (the C runtime's dune rule pattern) and the typescript arm
      stops reading the filesystem. Verification: a lone release-layout
      binary compiles a typescript program; the ts goldens stay
      byte-for-byte.
- [ ] **T26.2** — The emitted-code inventory and the standalone
      skeleton: emit the golden subset through the ocaml emitter and
      collect mechanically every host symbol the emitted code
      references; the inventory is the standalone runtime's contract,
      recorded in this step's plan. The skeleton
      (`emo_ocaml_runtime.ml`) compiles with plain `ocamlopt` — zero
      `emo_*` dependencies — and a fixture proves it from the build
      directory alone.
- [ ] **T26.3** — The value and scalar core: the value ADT, strings
      and their operations, print/interpolation rendering,
      arithmetic/comparison dispatch, and the case/error paths the
      inventory names, in the standalone runtime. Each piece covered
      by a fixture compiled against the runtime alone.
- [ ] **T26.4** — The scheduler and IO: the effects-based scheduler,
      file IO, and the networking surface, per the dependency policy
      above. Fixtures: a process program and an HTTP roundtrip
      compiled against the standalone runtime alone.
- [ ] **T26.5** — The cutover: the ocaml emitter's references flip to
      the standalone runtime; the arm emits runtime + `main.ml` and
      invokes `ocamlopt` (ocamlfind only for the packages the runtime
      itself uses); the `.cmxa` machinery, the library scan in
      `find_ocamlfind`, and the beside-binary lookup are deleted. The
      refusal and doctor wording become installation-independent —
      "the ocaml target needs the OCaml toolchain on PATH" — no
      source-install conditional. All ocaml goldens and tests
      byte-for-byte; the lone-binary verification: an installed binary
      with an OCaml toolchain builds the golden subset.
- [ ] **T26.6** — The independence audit and close-out: wasm and beam
      recorded as verified-independent (runtime inside the module /
      one OTP-standing module — no tasks, evidence noted here); the
      docs corrected (`docs/toolchain.md`,
      `docs/toolchain-distribution.md` — the true ocaml-target story
      replaces "a source install brings the ocaml target");
      `benchmarks/results.md`'s ocaml column re-run against the
      standalone runtime to confirm no regression; close-out.

## Acceptance

- No target reads its runtime from beside the binary or the host build
  tree: c, ocaml, ts embedded as generated data; wasm, beam inside the
  emitted module.
- `emo build --target ocaml` works on any installation where the OCaml
  toolchain is on PATH — verified from the release layout — and
  refuses elsewhere with the toolchain named, no installation-shape
  conditionals.
- The typescript target works from the release layout.
- All goldens byte-for-byte; `dune test` green;
  `benchmarks/results.md` ocaml numbers within noise of the pre-cutover
  build.
- `docs/toolchain.md` and `docs/toolchain-distribution.md` carry the
  corrected ocaml-target story.

## Open design items

- ~~The runtime-independence principle~~ — settled before T26.1
  (CHECK.md): the host contributes only the emitter; runtimes live in
  the target's language as generated data.
- ~~The ocaml runtime's dependency policy~~ — settled before T26.4:
  zero-dep core; `eio_main`/`ssl` as target-ecosystem opam
  dependencies, refused with a clear message when absent.
- Whether the standalone ocaml runtime later drops eio for a
  hand-rolled poll loop — open, driven by the same pressure that may
  one day drop the host's eio dependency; not this step's scope.
