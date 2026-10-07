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

- [x] **T26.1** — The principle and the ts embed: the principle above
      recorded in `CHECK.md`; `ts_prelude.ts` embedded as generated
      data (the C runtime's dune rule pattern) and the typescript arm
      stops reading the filesystem. Verification: a lone release-layout
      binary compiles a typescript program; the ts goldens stay
      byte-for-byte.
- [x] **T26.2** — The emitted-code inventory and the standalone
      skeleton: emit the golden subset through the ocaml emitter and
      collect mechanically every host symbol the emitted code
      references; the inventory is the standalone runtime's contract,
      recorded in this step's plan. The skeleton
      (`emo_ocaml_runtime.ml`) compiles with plain `ocamlopt` — zero
      `emo_*` dependencies — and a fixture proves it from the build
      directory alone.
- [x] **T26.3** — The value and scalar core: the value ADT, strings
      and their operations, print/interpolation rendering,
      arithmetic/comparison dispatch, and the case/error paths the
      inventory names, in the standalone runtime. Each piece covered
      by a fixture compiled against the runtime alone.
- [x] **T26.4** — The scheduler and IO: the effects-based scheduler,
      file IO, and the networking surface, per the dependency policy
      above. Fixtures: a process program and an HTTP roundtrip
      compiled against the standalone runtime alone.
- [x] **T26.5** — The cutover: the ocaml emitter's references flip to
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

## The emitted-code inventory (T26.2 — the standalone runtime's contract)

Collected mechanically by `devtools/ocaml-runtime-inventory.sh` (2026-10-07):
the golden corpus — every `examples/` entry with an `expected.txt`, sixteen
programs spanning objects, function groups, bytes, fixed-width math,
processes, file IO, TCP/UDP/TLS networking — emitted through the ocaml
emitter; the script greps every host-module reference out of the emitted
sources and fails on any module outside the two below. The reference counts
(across the corpus) stand behind each name. The standalone runtime
(`src/emo_codegen/ocaml/emo_ocaml_runtime.ml`) must carry every symbol with
the same arity and behavior; the two module names are load-bearing — the
emitter's qualified paths resolve through them.

- **Emo_eval** — the values and the builtin bridge. The `value` type;
  constructors the emitted code names: `Int64` (232), `String` (147),
  `Tuple` (49), `Float` (21), `Byte` (23), `Obj` (16), `EnumMember` (16),
  `Array` (14), `Bool`, `Void`, `Char`, `CompiledFn` (5), `TypeValue` (4)
  — the remaining constructors (`Bytes`, `Box`, `Pid`, the socket handles,
  `ClassDef`, `Instance`, `EnumType`, `EmoGroup`) are constructed only
  inside the runtime; the `CompiledFn.fdesc` field (5); `call_builtin`
  (161), behind which stands the whole builtin table (`println`, `halt`,
  `self_pid`, `file_read`/`file_write`, the `net_*` family — the corpus
  exercises fourteen names; the table ports whole, not just the corpus
  subset).
- **Emo_runtime** — operators, dispatch, process operations, scheduler
  hookup. `Return_signal` (120) and `Arity_error`; errors `arity_error`
  (111), `no_return`, `case_error`; unboxing `unbox_bool` (34),
  `unbox_int64` (16), `unbox_float64`, `unbox_string`, and the boxes
  `box_int64` (12), `box_float64`, `box_string`, `box_new`; arithmetic
  `add` (65), `sub` (14), `mul` (12), `div`, `modulo`, `negf` (9);
  bitwise `bit_and`, `bit_or`, `bit_xor`, `bit_not`, `shl` (6), `shr`,
  `shl_i64`, `shr_i64`; comparison `lt` (6), `gt` (9), `ge` (5), `eq`
  (21), `ne`, `not_` (`le`, `and_`, `or_` complete the ported surface);
  rendering `interpolate` (28), `to_string`; collections and objects
  `index` (21), `field` (17), `obj_set_field` (13), `new_obj` (16),
  `method_call` (132), `apply_value` (5), `exception_new`, `bytes_new`;
  processes `spawn_args` (7), `send` (11), `receive` (7), `payload_items`
  (12) (+ `bind_items`, `self_pid`, `spawn`, `raise_`, `halt`); the
  scheduler `run` (16) and `register_interface`.

Reshapes the standalone runtime is allowed (and records here): spans and
diagnostics stay compiler-side, so `Emo_raise` carries the value only, the
effect constructors drop their span fields, and the interpreter-only
AST-carrying variants (`ArrowBlock`, `BuiltinFn`, `Module`, closure-backed
class definitions) drop out of the ADT — compiled functions are always
`CompiledFn`.

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
- ~~The ocaml runtime's dependency policy~~ — settled at the T26.4
  port (CHECK.md): the core stands on the OCaml standard library plus
  `unix`, which ships with the compiler; `ssl` is the one opam-package
  dependency, declared by the build invocation and refused with a
  clear message when absent. eio drops out entirely — the standalone
  scheduler is the deterministic poll loop the compiled path already
  ran on, so the open item below closes with it.
- ~~Whether the standalone ocaml runtime later drops eio for a
  hand-rolled poll loop~~ — settled by the same port: there never was
  an eio dependency to drop. The det scheduler (Unix poll, no eio)
  is what compiled programs ran on; the standalone runtime carries it
  as-is.
