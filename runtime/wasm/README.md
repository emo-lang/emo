# The Emo-written WebAssembly runtime

This package is a WebAssembly runtime — decoder, validator, and
interpreter — written in Emo, the way wasmtime is written in Rust.
Step 20 of the language plan grew the decoder and validator; step 21
the interpreter, the linking layer, and the `spectest` host.

## What it offers

Two entry points on the package surface:

- `wasm.load(bytes)` — validate and materialize a module: the step-20
  verdict, plus a handle to the loaded module on success. The module
  records stay inside the package, so a caller never sees an
  unvalidated module.

- `wasm.decode(bytes)` — decode and validate a binary module. It
  reports `(ok, phase, offset, message)`: `ok` is true when the module
  decodes and validates; otherwise `phase` is `"malformed"` (the byte
  shape is wrong — bad LEB128, section ordering, truncated vectors)
  or `"invalid"` (the bytes decode but the module does not type —
  stack mismatches, unknown indices, non-constant initializers), with
  `offset` the byte position the failure was detected at. It never
  raises for bad input.

- `wasm.smoke()` — the package's identity string.

The module model itself stays behind the package boundary, under
`internal/` — `decode.emo` walks the sections, `reader.emo` holds the
byte cursor, LEB128, and the type-stack validator, `model.emo` carries
the module model and the semantic passes, `instance.emo` the instance
model, the interpreter, linking, and the `spectest` host, and the
`value`/`ints`/`floats`/`store` modules the runtime values and their
operations. What the runtimes of other packages can see is only what
the root module re-exports.

## The execution surface

`internal.instance` carries the live-module layer the run corpus
drives: `instantiate(handle)` resolves imports through the register
namespace and `spectest`, evaluates global initializers, lays out the
element and data segments with the spec's trap-on-overflow, and runs
the start function; `register_instance` binds an instance to an import
name; `call(inst, export, args)` invokes an export and returns its
values or the first trap; `get_global` reads a global export. Traps are
values — a trap never raises. Funcrefs pack their owning instance and
function index, so a table shared by import carries a call back to its
defining instance.

## What it refuses

The corpus is the MVP plus the sign-extension, saturating-conversion,
bulk-memory, reference-type, and multi-value extensions the official
suite pins — nothing newer (no function references, no SIMD). v128
values and the multi-memory memarg flag reject as out of scope. Names
must be valid UTF-8 by the spec's definition. A constant expression
may be `t.const`, `ref.null`, `ref.func`, or `global.get` of an
imported immutable global — anything else does not type, and a
non-constant but well-formed instruction reports `invalid`, not
`malformed`.

## The corpus and how it runs

`testdata/cases.all.txt` vendors the binary-form module cases of the
official spec suite (3456 cases; provenance and licence in
`testdata/README.md`). Every case carries its expected verdict:
`ok`, `malformed`, or `invalid`. The runners print one verdict line
per claimed case and a summary; any disagreement fails.

- `dune test` runs the smoke subset — forty representative cases in
  `testdata/cases.smoke.txt`, diffed against `expected.txt`. A
  regression in any claimed case turns the default test red.
- `dune build @wasm_spec` runs the full list against
  `spec.expected.txt`. This is step 20's acceptance gate; the language
  tests do not depend on it, because the suite is large and a language
  change has no reason to re-run it.

To re-claim cases after a capability lands, use
`devtools/vendor-wasm-spec` (flip/unflip); the tool refuses to operate
silently, so a claim is always deliberate.

## The run corpus and how it runs

`testdata/runs.all.txt` vendors the spec suite's *commands* — the
interpreter's corpus (25135 commands; the format and its provenance are
in `testdata/README.md`). Each command is a module instantiation, a
registration, or an invocation with its expected values or trap.

- `dune test` runs the smoke slice — 58 commands in
  `testdata/runs.smoke.txt`, diffed against `runs.expected.txt`.
- `dune build @wasm_runs` builds the driver natively and runs the full
  list against `runs.all.expected.txt` in about a minute. It is step
  21's acceptance gate: every `assert_return` matches bit-exactly, every
  `assert_trap` traps, and nothing is pending.

The run driver is compiled rather than interpreted: the evaluator is
correct but cannot carry the loop-heavy memory tests (its own recursion
limit), while the native backend emits boxed `Int64`. The two share the
same source.

## Why a wasm runtime lives in a language repository

It is the language's most demanding customer: a real consumer that
justifies primitives through the plan's unification gate, never an
argument that skips it. The package is the boundary — nothing under
`src/` reads anything here, and nothing here names a compiler module.
The runtime leaves this repository when it passes the vendored suite
and Emo reaches 1.0; until then it stays, growing one rung per step.
