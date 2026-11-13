# Step 72 — The wasm package: the execution surface and the host interface

**Milestone:** M35 · **Prereq:** steps 20–22 (the runtime), 56 · **Status:** done

The Emo-written wasm runtime (`runtime/wasm/`, steps 20–22) decodes,
validates, and executes WebAssembly modules — the full core spec, the
official suite green at 3456 module cases and 25135 run commands. What it
is not is *usable*: the execution layer (`instantiate` / `call` /
`get_global`) lives under `internal/`, no package outside it can execute a
module, imports resolve only through the register namespace and the
`spectest` host, and the package itself is an in-repo fixture no manifest
can declare. `docs/wasm-runtime-temp.md` recorded exactly this gap.

This step closes the first rung of the ladder the temp notes pointed at.
The rungs, decided now:

1. **Step 72 (this step)** — the execution surface and the host
   interface, exported from the package root, with the package moved
   into the bundled registry as the `wasm` stdlib package.
2. **Step 73** — the CLI rung: `emo wasm run` executes a `.wasm`
   artifact. Its plan is written when it starts; the decided direction
   is that the CLI drives its own interpreter over an Emo driver that
   reads the artifact path through `os.argv` (M26 landed it) — the
   compiler never links the runtime, so the step-20 boundary holds in
   both directions.
3. **Step 74** — the host-module rung: an `emo` host module (and the
   WASI surface that reality demands) so modules from other toolchains
   run. Its plan is written when it starts.

## Decisions binding this step

**The package is the boundary — now with a registry edge.**
`stdlib/registry/wasm/0.1.0/` is the package's home, resolved like every
bundled package: a user project declares `"wasm" = "0.1.0"` in `deps`
and the interpreter (or the `ocaml` target) runs it. Everything the
package offers crosses that deps edge and nothing else; its guts stay
under `internal/`. The conformance harness — `testdata/`, the two
drivers' smoke slices, the `wasm_spec` / `wasm_runs` aliases — moves
with the package, so the package remains the conformance home. The
split condition from step 21 stands unchanged: the runtime leaves the
repository after the vendored suite passes and Emo reaches 1.0; until
then it is a bundled package, not a published one.

**The boundary against the compiler holds.** No file under `src/` reads
anything under `stdlib/registry/wasm/`; the dependency never runs the
other way. Step 73's CLI rung runs the driver through the interpreter
as data, never as a linked module — the coupling the boundary forbids
is OCaml reaching the runtime's files, not the CLI invoking Emo code.

**Errors are values, in the house shape.** The M10 split
(`(R.ok, value)` / `(R.error, reason)`, matched by `case`) governs the
new surface. The runtime predates the convention; its ad-hoc
`(ok, phase, offset, message)` tuples retire from the public root as
the surface grows.

## Goal

An ordinary Emo program:

```emo
const loaded = wasm.load(bytes)          // (R, handle)
case loaded {
  (R.error, why) -> { ... }
  (R.ok, module) -> {
    const inst = wasm.instantiate(module, [
      ("env", "log", -> (args Array[(Int64, Int64)]) {
        return wasm.i64(0)
      })
    ])
    ...
    const r = wasm.call(inst, "fac", [wasm.i64(10)])
    ...
  }
}
```

loads a module from bytes, satisfies its imports with Emo closures,
instantiates it, calls its exports, reads its globals, and moves bytes
through its linear memory — every failure an `R.error` with a reason,
never a raise.

## Scope

### In

- The move: everything under `runtime/wasm/` relocates to
  `stdlib/registry/wasm/0.1.0/` — `wasm.emo`, `internal/`, the package
  manifest, the drivers and fixtures, `testdata/`, the package README,
  and the dune rules that carry the smoke slice and the two aliases.
  The root `dune` comment and `devtools/vendor-wasm-spec`'s output
  paths follow; plan steps 20–22 stay as history.
- The public execution surface on the package root, over the R split:
  `load` (migrating from the five-tuple to `(R, handle)`), `instantiate`,
  `call`, `get_global`, `read_memory`, `write_memory`,
  `register_instance`, `describe`. `decode` keeps its diagnostic
  four-tuple — it *is* the verdict reporter, and the corpus harness's
  shape.
- The value constructors: `i32`, `i64`, `f32`, `f64` (and the
  `from_bits` pair for exact float patterns), the documented
  `(kind, bits)` encoding, and the `as_*` accessors the demo needs to
  read results back.
- The host-import interface: an import table of
  `(module, name, fn)` triples, the uniform host signature
  `-> (args Array[(Int64, Int64)]) (Int64, Int64)`, and the resolution
  order explicit table → register namespace → `spectest`.
- A `wasm_demo` example with a golden: load → host → instantiate →
  call → memory round-trip, self-contained, no Node, byte-identical
  across its runs.
- Docs: `docs/wasm.md` (EN + zh) as the runtime's real reference,
  replacing the retired temp notes; the `docs/stdlib.md` row and
  section; the root README row.

### Out

- WASI and the `emo` host module — step 74.
- The CLI — step 73.
- Running the output of `emo build --target wasm` inside the runtime
  (the GC proposal's types) — the ladder's exit sign, unchanged.
- Host-function re-entrancy (a host import calling back into the
  instance) — refused this rung, recorded as a pressure note.
- Other compilation targets for the package: `["ocaml", "c"]` are
  claimed because both are verified byte-for-byte; the rest join when
  verified, never assumed. (The `c` claim forced a language-side task:
  the c backend grew module-level `var` — T72.6.)
- Performance work: the interpreter stays interpreter-first.
- The text format (`.wat`), threads, SIMD, exceptions, memory64 —
  unchanged from steps 21–22.

## Provisional decisions

Marked as provisional per `plan/README.md`; the settled ones move into
`docs/wasm.md` when the step closes.

- **Handles, not classes.** The module and instance handles stay
  opaque `Int64` indexes into the package's own tables — the shape
  `load` already returns. Cross-package classes carry target friction
  (the boxed-class rules on the compiled targets); handles carry none,
  and the package holds all state behind them, as it already does.
- **The value model on the surface is the runtime's own.** A wasm
  value is the `(kind, bits)` pair of `Int64`s the interpreter already
  uses (`127=i32`, `126=i64`, `125=f32`, `124=f64`, `112=funcref`,
  `111=externref`). The constructors wrap it; the encoding is
  documented once in `docs/wasm.md`. No second value model, no
  boxing layer.
- **The host signature is uniform.** Every host function is
  `-> (args Array[(Int64, Int64)]) (Int64, Int64)` — the argument
  array in, one tagged value out; an import whose function has no
  result answers the zero-tagged unit value. One signature means one
  call path through `call_host`, no arity dispatch, and the `Block`
  annotation absorbs every closure into the table (the httpd
  middleware pattern is the precedent). Import resolution consults the
  explicit table first, then the register namespace, then `spectest`.
- **`write_memory` reports what it wrote.** `(R, Int64)` — the byte
  count; `read_memory` returns `(R, Bytes)`. Both bounds-check through
  the store, which already traps as a value.
- **The old public tuples retire.** `load`'s five-tuple and the
  temp-notes' usage examples were pre-M10 shapes; the fixtures that
  exercise them move with the package and update in the same task.

## Tasks

Sizes: **S** is one short sitting, **M** an evening, **L** several.
Any prefix of this list leaves the repo building and `dune test` green.

- [x] **T72.1** — *The move.* **(M)** `runtime/wasm/` →
      `stdlib/registry/wasm/0.1.0/`, manifest and rules intact; the
      root `dune` comment, the alias wiring, and
      `devtools/vendor-wasm-spec`'s paths follow; the smoke slice and
      both aliases pass from the new home.
- [x] **T72.2** — *The public surface.* **(M)** The R-split execution
      defs on the package root (`load`, `instantiate`, `call`,
      `get_global`, `read_memory`, `write_memory`,
      `register_instance`, `describe`), the value constructors and
      `as_*` accessors, the package README's surface section. The
      fixtures update from the five-tuple `load`.
- [x] **T72.3** — *The host table.* **(M)** The `(module, name, fn)`
      import triples riding `instantiate`, the resolution order, the
      uniform host signature through `call_host`; fixtures: a module
      importing from `env` served by an Emo closure, the resolution
      order pinned, a missing import link-failing as before.
- [x] **T72.4** — *The demo golden.* **(S)** `examples/wasm_demo/`:
      a hand-built module (hex in Emo, reviewable) exercising load →
      host → instantiate → call → memory round-trip; the golden runs
      through the interpreter with the registry pointed at the bundled
      copy.
- [x] **T72.5** — *The docs.* **(S)** `docs/stdlib/wasm.md` EN + zh
      — what the package offers, the surface, the value encoding, the
      host interface, the limits (no WASI yet, no GC types,
      `["ocaml", "c"]` only); `docs/stdlib.md` row + section; the temp
      notes retire to the new reference; README rows; `docs/TASKS.md`
      and `plan/README.md` closed out.
- [x] **T72.6** — *The c backend's module-level `var`.* **(M)** The
      interpreter's dep-check universe resolves against the `c`
      target, so a package consumable across a deps edge must claim
      `c` — and the c backend refused `Global_var`/`Set_global_var`.
      One `static emo_value` cell per `pglobal`; reads hand out pooled
      claims, unboxing at native-typed sites; assignments ride the
      write barrier a local's overwrite uses; the cells initialize in
      declaration order at `emo_root_entry`'s start. The proof is
      byte-identity on every fixture and the demo, and the whole
      repo's `dune runtest` green.

## Acceptance

- A user project declaring `"wasm" = "0.1.0"` resolves the package
  from the bundled registry and runs the demo golden through the
  interpreter, byte-identical across runs.
- The package root exposes the execution surface over the R split;
  nothing outside `internal/` is needed to load, host, instantiate,
  call, and move memory.
- The default `dune test` still carries the smoke slice from the
  package's new home; the `wasm_spec` / `wasm_runs` aliases still
  report zero pending and zero failed.
- The boundary holds: no file under `src/` reads anything under
  `stdlib/registry/wasm/`, and nothing under the package names a
  compiler module.
