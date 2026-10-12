# Renumbering — remaining work

Tracking the step/Task renumbering to the final scheme.

## Goal

- **Steps `01–46`, continuous**, in the tracker's document order.
- **Milestones `M1–M13`** (continuous labels).
- **EmoOS dropped.**
- The **phantom** "Self-contained hosted native backend" assessment takes
  **no number** (its plan file drops the number: `plan/hosted-native-ffi.md`).

## Done on `task/renumbering` (commit `3086c69`)

- `docs/TASKS.md`: the 46 `### Step NN` headings, all `TNN.x`, the `Prereq`
  lines, the in-prose `Steps …` references, and the Milestones table.
- `plan/`: the 33 step files renamed to the new numbers, titles and contents
  renumbered; `plan/step-23-hosted-native-ffi.md` → `plan/hosted-native-ffi.md`.
- `plan/README.md`: milestone ranges and status table.

## Mapping (old → new)

```
01–06 → 01–06
07 → 08     08 → 09     09 → 10     10 → 11     11 → 12     12 → 13
13 → 14     14 → 15     16 → 16     15 → 17     17 → 18     18 → 07
19 → 20     20 → 21     21 → 22     22 → 19
24 → 23     25 → 24     26 → 25
27 → 26     28 → 27     29 → 28     30 → 29     31 → 30
32 → 31     33 → 32     34 → 33     35 → 34     36 → 35     37 → 36
38 → 37     39 → 38
40 → 39     41 → 40     42 → 41     43 → 42     44 → 43     45 → 44
46 → 45     47 → 46
```

(The phantom `23` is retired and takes no number.)

## Remaining

### 1. Step/Task references in the rest of the repo

Files that still carry the pre-renumber numbers (old → new per the mapping
above). Each line lists the tokens found in that file.

```
.github/workflows/ci.yml :: T22.4
.github/workflows/release.yml :: T25.6 T25.7
CHECK.md :: step 13 step 21 step 23 step 24 step 25 step 27 step 28 step-12 step-15 step-19 step-23 step-24 step-25 T24.10 T24.3 T24.4 T24.5 T24.8 T24.9 T26.1 T26.4
benchmarks/plain_loop/main.emo :: step 27
devtools/gen-stdlib-data.sh :: step-25 T25.2
devtools/notarize-release.sh :: T25.7
devtools/ocaml-runtime-inventory.sh :: step-26 T26.2
devtools/package-release.sh :: T25.2 T25.6 T25.7
devtools/vendor-wasm-spec :: step 20 step 21
docs/industrial-software.md :: step 22 step-22
docs/native-backend.md :: step 08 step 13 Step 13 step 14
docs/numeric-width.md :: step 14 step 17
docs/rtos-assessment.md :: step 14 step 22 step-14 step-22
docs/runtime-and-freestanding.md :: step 22 step-22 step-23
docs/toolchain-distribution.md :: step 24 step 25 step 26 Step 26 step-23 step-25 step-26 T24.10 T24.9
docs/toolchain.md :: step 25 step 26 step-25 step-26
docs/var-escape.md :: step 08
docs/wasm-runtime-temp.md :: step 20 step-19 step-20 step-21
docs/xv6.md :: step 13 step-14 step-22
docs/zh-CN/industrial-software.md :: step 22 step-22
docs/zh-CN/native-backend.md :: 步骤 08 步骤 13 步骤 14
docs/zh-CN/numeric-width.md :: step 14 step 17
docs/zh-CN/rtos-assessment.md :: step 14 step-14 step-22
docs/zh-CN/runtime-and-freestanding.md :: step-22 step-23
docs/zh-CN/toolchain-distribution.md :: 步骤 24 步骤 25 步骤 26 step-23 step-25 step-26 T24.10 T24.9
docs/zh-CN/toolchain.md :: 步骤 25 步骤 26 step-25 step-26
docs/zh-CN/wasm-runtime-temp.md :: step 20 step-19 step-20 step-21
docs/zh-CN/xv6.md :: step 13 step-14 step-22
docs/zh-CN/zig-backend.md :: step 22 T12.5
docs/zig-backend.md :: Step 22 T12.5
dune-project :: T25.8
examples/http_roundtrip/main.emo :: step 12
runtime/wasm/README.md :: step 20 Step 20 step 21 step-20
runtime/wasm/cli.emo :: T20.4
runtime/wasm/dune :: step 20 step 21 T21.2 T21.3 T21.4 T21.5 T21.6 T21.7 T21.8 T21.9
runtime/wasm/fac-fixture.emo :: T21.7
runtime/wasm/float-convert-fixture.emo :: T21.5
runtime/wasm/float-fixture.emo :: T21.5
runtime/wasm/host-fixture.emo :: T21.9
runtime/wasm/instance-fixture.emo :: T21.2
runtime/wasm/int-fixture.emo :: T21.4
runtime/wasm/internal/decode.emo :: step 20 T20.14 T20.4 T20.6 T20.7
runtime/wasm/internal/error.emo :: step 20
runtime/wasm/internal/floats.emo :: T21.5
runtime/wasm/internal/instance.emo :: step 21 step-20 steps 20 T21.2 T21.7 T21.8 T21.9
runtime/wasm/internal/ints.emo :: T21.4
runtime/wasm/internal/model.emo :: step 20 T20.14 T20.15 T20.7 T20.8 T20.9
runtime/wasm/internal/reader.emo :: step 20 T20.10 T20.15 T20.17 T20.9
runtime/wasm/internal/runlist.emo :: T21.1
runtime/wasm/internal/store.emo :: T21.11 T21.6
runtime/wasm/internal/value.emo :: T21.3 T21.5
runtime/wasm/leb-fixture.emo :: T20.6
runtime/wasm/link-fixture.emo :: T21.8
runtime/wasm/store-fixture.emo :: T21.6
runtime/wasm/testdata/README.md :: Step 20 step 21 Step 21
runtime/wasm/type-fixture.emo :: step 20 T20.7
runtime/wasm/value-fixture.emo :: T21.3
runtime/wasm/wasm.emo :: Step 20 step-20
src/emo_cli/emo_cli.ml :: step 22 step 24 step 26 T25.3 T25.4 T25.5
src/emo_codegen/c/emo_c_runtime.c :: T24.5
src/emo_codegen/c/emo_c_runtime.h :: step-24 T24.10 T24.2 T24.3 T24.4 T24.5 T24.6 T24.7 T24.8 T24.9
src/emo_codegen/dune :: step 26
src/emo_codegen/emo_beam.ml :: step-17 T17.1 T17.4
src/emo_codegen/emo_c.ml :: step-24 T24.10 T24.4 T24.5 T24.8
src/emo_codegen/emo_codegen.ml :: step 26
src/emo_codegen/emo_riscv.ml :: step-22 T22.2 T22.3
src/emo_codegen/ocaml/emo_ocaml_runtime.ml :: step 26 step-06 step-26 T26.2 T26.4
src/emo_codegen/ts/ts_runtime.ts :: T30.3
src/emo_eval/emo_eval.ml :: step-06
src/emo_ir/emo_ir.ml :: step 08
src/emo_parser/emo_parser.ml :: step 13
src/emo_pkg/dune :: T25.2
src/emo_pkg/emo_pkg.ml :: step 8 T25.2 T25.4
src/emo_project/emo_project.ml :: T25.2
test/emo_check/emo_check_test.ml :: step-08 T8.7
test/emo_cli/emo_cli_test.ml :: step 47 T16.1 T16.2 T22.1 T22.4 T24.1 T24.10 T24.2 T24.3 T24.4 T24.5 T24.6 T24.7 T24.8 T24.9 T25.3 T25.5
test/emo_eval/emo_eval_test.ml :: step-06
test/emo_ocaml_runtime/emo_ocaml_runtime_test.ml :: step 26
test/emo_pkg/emo_pkg_test.ml :: T25.2
test/emo_project/emo_project_test.ml :: Step 13 step 15 Step 47 T25.1 T25.4
test/emo_sched/emo_sched_test.ml :: T12.1
```

Notes:
- A few references are **not** step numbers semantically and must not be
  rewritten blindly — e.g. `T12.5` in `docs/zig-backend.md` and
  `T8.7`/`T12.1` in tests are task IDs, but `step 06`/`step-06` in the
  interpreter files are step numbers that still map.
- Some `step 23` / `step-23` occurrences in `CHECK.md` and
  `docs/toolchain-distribution.md` / `docs/runtime-and-freestanding.md`
  refer to the **phantom** assessment, not the C target — review before
  rewriting.

#### Subtasks

Item 1 is split so each piece can be executed and reviewed on its own.
Every piece applies the same old → new mapping above; the only pieces that
need a human read are the toolchain / phantom ones (1.3, 1.4) and their
zh-CN mirrors (1.5).

- [x] **1.1 — CI, devtools & root config.** `.github/workflows/ci.yml`,
  `.github/workflows/release.yml`, `devtools/gen-stdlib-data.sh`,
  `devtools/notarize-release.sh`, `devtools/ocaml-runtime-inventory.sh`,
  `devtools/package-release.sh`, `devtools/vendor-wasm-spec`, `dune-project`.
- [x] **1.2 — `docs/` narrative (English).** `industrial-software.md`,
  `native-backend.md`, `numeric-width.md`, `rtos-assessment.md`,
  `var-escape.md`, `zig-backend.md`, `xv6.md`.
- [x] **1.3 — `docs/` toolchain & wasm-runtime (English; phantom review).**
  `toolchain.md`, `toolchain-distribution.md`, `runtime-and-freestanding.md`,
  `wasm-runtime-temp.md`.
- [x] **1.4 — `CHECK.md` (phantom review).**
- [x] **1.5 — `docs/zh-CN/` mirror.** `industrial-software.md`,
  `native-backend.md`, `numeric-width.md`, `rtos-assessment.md`,
  `runtime-and-freestanding.md`, `toolchain-distribution.md`, `toolchain.md`,
  `wasm-runtime-temp.md`, `xv6.md`, `zig-backend.md`.
- [x] **1.6 — `runtime/wasm/` runtime & fixtures.** `README.md`, `cli.emo`,
  `dune`, all `*-fixture.emo`, `wasm.emo`, `testdata/README.md`.
- [x] **1.7 — `runtime/wasm/internal/`.** `decode.emo`, `error.emo`,
  `floats.emo`, `instance.emo`, `ints.emo`, `model.emo`, `reader.emo`,
  `runlist.emo`, `store.emo`, `value.emo`.
- [x] **1.8 — `src/` OCaml sources.** `emo_cli/`, `emo_codegen/`,
  `emo_eval/`, `emo_ir/`, `emo_parser/`, `emo_pkg/`, `emo_project/`.
- [x] **1.9 — `test/` OCaml suites.** `emo_check`, `emo_cli`, `emo_eval`,
  `emo_ocaml_runtime`, `emo_pkg`, `emo_project`, `emo_sched`.
- [x] **1.10 — `examples/` & `benchmarks/`.** `benchmarks/plain_loop/main.emo`,
  `examples/http_roundtrip/main.emo`.

All ten are done. Verified by re-extracting every `step`/`Step`/`T`-id token
in the file list above: each now carries a **new** number. Three call-outs:

- `CHECK.md`'s phantom-reference `(step 23 leaned C: …)` became `(the
  hosted-native-FFI assessment leaned C: …)`; `plan/step-23-c-target.md` is
  the C target and stands as written.
- `step-06` maps to itself (`06 → 06`), so `step-06` is untouched; the
  `step-08` references became `step-09`.
- **False positive fixed by hand:** `src/emo_pkg/emo_pkg.ml:804`'s
  `step 8 (Int32.of_int i)` is a function call on a local `step`, not a
  step reference; a blind replacement to `09` would be an invalid OCaml
  literal. It was reverted to `step 8`. No other `step`-as-identifier hit
  was found (`conv_step2` in `instance.emo` was likewise left alone).

### 2. `docs/zh-CN/TASKS.md` — done

Mirrored the English work: the milestone table is `M1–M13`, EmoOS is gone
(0 occurrences), the 46 step sections are renumbered `01–46` and reordered
(function groups into M1 as 07, BEAM into M4 as 18, the wasm target before
TypeScript), every `T`-id is padded/mapped, and the prereqs, plan-file
references, and in-prose step references follow. The six prereqs whose
endpoint is not a plain old → new mapping (new `07`, `08`, `16`, `17`, `18`,
`20`) were set from the English. The structure now matches `docs/TASKS.md`
exactly — the same milestones with the same step numbers in the same order.

Done with a one-off script (`devtools/tmp-renumber-zh.py`, since moved to
`/Users/daqing/protected/tmp/`), verified with a mapped-backup line-multiset
diff: the only changed lines are the intended ones.

In-body `M`-refs still carry the pre-renumber labels, matching the English
(e.g. step 19's "M7 完成", the toolchain intro's "M8 把 … M9 把 …") —
those are item 5's scope.

### 3. EmoOS residuals in plan files — done

Beyond the four planned removals in `plan/step-20-wasm-runtime.md` (its
title, the two-consumer framing, the `EmoOS needs it for` table column,
the `M7 (EmoOS)` roadmap item), the same framing reached further: the
kernel paragraphs and the gate's "both consumers" clause there, the
kernel bullet and `M7` note in the step's own semantics, and the
"both consumers named" / "kernel path" / "two consumers" wording in
`plan/step-21-wasm-decoder.md` and `plan/step-22-wasm-interpreter.md`.
`plan/step-15-other-targets.md`'s three "EmoOS ambition/work/effort"
clauses are gone too. `EmoOS` now appears in `plan/` zero times.

Kept: the gate's name (`unification gate`) and its notes about the wasm
runtime itself; generic "kernel code" phrasing for the freestanding
target in `plan/step-15-other-targets.md` (a kernel is just the
freestanding use case, and `README.md` still records the EmoOS
ambition).

### 4. Semantic references — done

Human read of every semantic step reference:

- **Phantom mentions.** `CHECK.md` and the toolchain /
  runtime-and-freestanding docs are correct (the phantom is now only named
  `plan/hosted-native-ffi.md`). The audit turned up phantom `step 23`
  references in `plan/step-23-c-target.md` that items 1 and 3 missed — its
  `Milestone` line, the "Step 23 assessed…" paragraph, and "Step 23 marks this
  the fork…" — reworded to the hosted-native-FFI assessment, and its stale
  `plan/step-23-hosted-native-ffi.md` path fixed to
  `plan/hosted-native-ffi.md`.
- **`step NN` in the listed docs.** `docs/toolchain.md`,
  `docs/toolchain-distribution.md`, `docs/runtime-and-freestanding.md`,
  `docs/rtos-assessment.md`, and `docs/xv6.md` all point at the renumbered
  step (RISC-V → step 19, other-targets → step 15, native backend → step 14,
  target independence → step 25, toolchain → step 24).
- **Repo-wide sweep.** No `step NN` / `步骤 NN` outside 01–46, and no broken
  `plan/*.md` reference in any tracked file except the intentional old → new
  example in this file.

(Item 1's mechanical pass plus subtasks 1.3–1.5 carried the rest.)

### 5. Milestone labels outside the tracker (found while doing item 1)

Item 1's token list covered `step`/`T`-ids only, so milestone labels were
left untouched there. They are stale across the repo and are **not** a
purely mechanical mapping: old `M5` (Function groups) and old `M7` (EmoOS)
were dropped, so those must be reworded, not renumbered.

Old → new: `M1–M4` same; `M6 → M5`; `M8 → M6`; `M9 → M7`; `M10 → M8`;
`M11 → M9`; `M12 → M10`; `M13 → M11`; `M14 → M12`; `M15 → M13`.

Evidence (each is pre-renumber):

```
plan/step-07-function-group.md:3   M5  (function groups are in M1 now)
plan/step-18-beam.md:3             M5
plan/step-19-riscv64.md:3          M7  (EmoOS; RISC-V is in M4)
plan/step-20-wasm-runtime.md:3     M6  (→ M5)
plan/step-21-wasm-decoder.md:3     M6  (→ M5)
plan/step-22-wasm-interpreter.md:3 M6  (→ M5)
plan/step-23-c-target.md:3         M8  (→ M6)
plan/step-24-toolchain.md:3        M9  (→ M7)
plan/step-25-target-independence.md:3 M10 (→ M8)
plan/step-31..38-stdlib-*.md:3     M13 (→ M11)
docs/TASKS.md:52                   "T13.5, M12" gate row — M12 is Visualization now; error handling is M10
CHECK.md:26                        "M9, step 24" — M9 is For/While now; toolchain is M7
docs/toolchain.md:68,70            M9 — Toolchain, M10 — Target independence
docs/zh-CN/toolchain.md:60,62      same, in Chinese
docs/toolchain-distribution.md:118 "M9 — Toolchain"
docs/zh-CN/toolchain-distribution.md:102 "M9 — 工具链"
test/emo_check/emo_check_test.ml:1786  (M12) on the `R` enum — error handling is M10
docs/visualization.md:458          (CHECK.md, M12) — already correct (plot is M12)
```

Note the two `M12` uses mean opposite things: the visualization ones are
correct, the error-handling ones are old. A human read per site is needed.
