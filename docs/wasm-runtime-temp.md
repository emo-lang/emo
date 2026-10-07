# The wasm runtime — how to use it (temporary notes)

> **Temporary.** These are working notes on the runtime that lives in
> `runtime/wasm/`, not a decided design document. They record how the
> runtime is used today; they do not extend the plan or the README. The
> authoritative material is `runtime/wasm/README.md`,
> `plan/step-19-wasm-runtime.md`, `plan/step-20-wasm-decoder.md`, and
> `plan/step-21-wasm-interpreter.md`.

## What it is

It is **not** a wasmtime-style tool that runs `.wasm` files from a
command line. It is a WebAssembly interpreter — decoder, validator, and
executor — written in Emo and driven by the official spec suite. There
is no CLI, no WASI, no JIT, and no way to consume it from outside its
own package today.

- Location: `runtime/wasm/`.
  - Public entry point: `wasm.emo`.
  - Drivers: `main.emo` (decoder smoke), `spec.emo` (full decoder
    corpus), `runs.emo` / `runs-smoke.emo` (interpreter command corpus).
  - Implementation under `internal/`: `reader.emo` (byte cursor,
    LEB128, type-stack validator), `decode.emo`, `model.emo`,
    `instance.emo` (instance model, interpreter, linking, the
    `spectest` host), `store.emo`, `value.emo`, `ints.emo`,
    `floats.emo`, `runlist.emo`.
- Coverage: the MVP plus the sign-extension, saturating-conversion,
  bulk-memory, reference-type, and multi-value extensions. Explicitly
  out of scope: function references, SIMD, GC, threads, WASI.

## Ways to use it

### A. Run the acceptance gates

```bash
dune build src/emo_cli/emo.exe            # build emo first

cd runtime/wasm
dune test                  # smoke: 40 decoder cases + 58 run commands + fixtures
dune build @wasm_spec      # all 3456 binary module cases (decoder/validator)
dune build @wasm_runs      # all 25135 run commands (interpreter, ~1 minute)
```

Both full aliases currently pass: `@wasm_runs` reports
`claimed 25135, pending 0, failed 0`, and `@wasm_spec` reports
`claimed 40, pending 0, failed 0` on its smoke prefix. The aliases are
defined in `runtime/wasm/dune`, so they must be run **from
`runtime/wasm/`**.

### B. Decode and validate only (the public surface)

`wasm.emo` exposes exactly three definitions:

| Function | Returns |
| --- | --- |
| `wasm.smoke()` | an identity string |
| `wasm.decode(data Bytes)` | `(ok, phase, offset, message)`; `phase` is `"malformed"` or `"invalid"`, and bad input **never raises** |
| `wasm.load(data Bytes)` | `(ok, phase, offset, message, handle)`; on success `handle` is the module handle (an index into the registry), `-1` on failure |

### C. Execute a module (the internal surface)

The instance/execution layer is not re-exported publicly; it lives in
`internal.instance`:

| Function | Description |
| --- | --- |
| `instantiate(handle) -> (ok, trap, inst)` | resolve imports, initialize globals/memory/tables, lay out element and data segments, run the start function |
| `register_instance(inst, name) -> Int64` | bind an instance into the import namespace (for other modules to import) |
| `call(inst, export, args) -> (ok, results, trap)` | invoke an exported function; a trap is a value, never a raise |
| `get_global(inst, name) -> (ok, (kind, bits), trap)` | read a global export |
| `describe(handle) -> String` | a one-line count summary of a loaded module |

The value model is a tagged `(kind, bits)` pair: `127=i32`, `126=i64`,
`125=f32`, `124=f64`, `112=funcref`, `111=externref`. Construct
arguments with `internal.value.i32/i64/f32/f64(...)` and read results
back out of `bits`.

A minimal, verified host program (placed inside `runtime/wasm/`):

```emo
// Read a .wasm from disk -> validate -> instantiate -> call an export.
const bytes  = file_read("demo-fac.wasm").to_bytes()
const loaded = wasm.load(bytes)
println("load ok=" + loaded[0].to_string() + " " + loaded[1])
if !loaded[0] { return 1 }

const inst = internal.instance.instantiate(loaded[4])
if !inst[0] { println("inst " + inst[1]); return 1 }

const r = internal.instance.call(inst[2], "fac", [internal.value.i64(10)])
println("fac(10) = " + r[1][0][1].to_string())   // -> 3628800
```

Run it with:

```bash
cd runtime/wasm
../../_build/default/src/emo_cli/emo.exe run your.emo
```

`emo run` must be invoked from inside the package directory so that
`wasm.*` and `internal.*` resolve; running
`runtime/wasm/fac-fixture.emo` from the repository root also works.

For cross-module linking, see `link-fixture.emo`: instantiate module A,
`register_instance(instA, "A")`, then instantiate module B and its
imports resolve through the register namespace.
`host-fixture.emo` exercises the built-in `spectest` host
(print/global/table/memory).

## Limits (why it is not wasmtime)

1. **No CLI and no argv.** `plan/step-20` deferred argv, so every driver
   hardcodes its path (e.g. `cli.run("testdata/cases.smoke.txt")`).
2. **`internal/` is subtree-private** (enforced by the compiler). Code
   outside the package cannot see `instantiate` / `call`, so **an
   external package cannot execute a module at all** — only `decode` /
   `load`. From a package in `/tmp`, even `wasm.load` fails with
   `E4003` (no dependency declared and `wasm.*` not in scope). Making
   it usable from outside requires re-exporting an execution layer in
   `wasm.emo`.
3. **Imports come from only two sources:** the register namespace and
   the `spectest` host. There is no WASI and no `emo` host module, so
   it **cannot run the output of `emo build --target wasm`**. That is
   the self-hosting exit criterion in the plan, which needs GC types
   and is out of this rung.
4. **It is not a publishable package.** `package.emo` declares
   `deps {}`, dependencies go through the central registry at exact
   versions, and there is no documented path dependency; the package is
   an in-repo fixture, and the plan says it leaves the repository only
   after it passes the vendored suite and Emo reaches 1.0.

## What would make it usable

- Re-export an execution surface from `wasm.emo` (e.g.
  `instantiate`, `call`, `get_global`) with a defined host interface.
- Give the `emo` CLI or a standalone driver access to argv (the gap
  step 20 left open), or add an `emo wasm run foo.wasm` subcommand.
- To run real-world `.wasm`, add WASI / an `emo` host module and more
  proposals (GC and beyond).
