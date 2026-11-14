# The `wasm` package

A WebAssembly runtime written in Emo — the way wazero is a runtime
written in Go. It decodes and validates a binary module, then executes
it: an interpreter over the core spec's MVP plus the sign-extension,
saturating-conversion, bulk-memory, reference-type, and multi-value
extensions. The bar is the official spec suite, and the bar is met:
every `assert_malformed` and `assert_invalid` binary case is rejected
in the right phase, and every `assert_return` and `assert_trap` in the
vendored run corpus answers bit-exactly (25135 commands, zero pending,
zero failed).

The package is the boundary: its guts live under `internal/`, and the
only thing another package sees is this root. Handles cross the edge —
a module handle names a loaded module, an instance handle a live
instantiation — and every failure answers `(R.error, reason)`, never a
raise.

Targets: `["ocaml", "c"]`. Reference:
[`docs/stdlib/wasm.md`](stdlib/wasm.md) · Demo: `examples/wasm_demo`.

## Using the package

`require "wasm"`, with the package pinned in your manifest:

```emo
deps {
  "wasm" = "0.1.0"
}
```

## The ladder, in one program

```emo
case wasm.load(module_bytes(hex)) {
  (R.error, why) then { println("load " + why) }
  (R.ok, module) then {
    case wasm.instantiate(module, [("env", "log", -> (args Array[(Int64, Int64)]) {
      println("env log " + args[0][1].to_string())
      return wasm.i64(0)
    })]) {
      (R.error, why) then { println("inst " + why) }
      (R.ok, inst) then {
        case wasm.call(inst, "fac", [wasm.i64(10)]) {
          (R.error, trap) then { println("trap " + trap) }
          (R.ok, results) then {
            case wasm.as_i64(results[0]) {
              (R.ok, v) then { println("fac(10) = " + v.to_string()) }
              (R.error, why) then { println(why) }
            }
          }
        }
      }
    }
  }
}
```

## The surface

```emo
wasm.decode(data Bytes)                       // (Bool, String, Int64, String) — the diagnostic verdict
wasm.load(data Bytes)                         // (R, Int64) — validate + materialize; the module handle
wasm.instantiate(module Int64, imports Array[(String, String, Block)])  // (R, Int64) — the instance handle
wasm.call(inst Int64, name String, args Array[(Int64, Int64)])          // (R, Array[(Int64, Int64)])
wasm.get_global(inst Int64, name String)      // (R, (Int64, Int64))
wasm.register_instance(inst Int64, name String)  // Int64 — bind into the import namespace
wasm.describe(module Int64)                   // String — a one-line count summary
wasm.read_memory(inst Int64, ptr Int64, len Int64)   // (R, Bytes)
wasm.write_memory(inst Int64, ptr Int64, data Bytes) // (R, Int64) — the bytes written
```

`decode` is the verdict reporter — `(ok, phase, offset, message)`, the
phase `"malformed"` or `"invalid"` — for tooling that wants the byte
offset spelled out. `load` is the entry the execution surface rides.

## The value model

A wasm value is a `(kind, bits)` pair of `Int64`s — the runtime's own
bit-pattern model, documented once here:

| kind | meaning | `bits` carries |
| --- | --- | --- |
| 127 | `i32` | the unsigned 32-bit pattern |
| 126 | `i64` | the full 64-bit pattern |
| 125 | `f32` | the unsigned 32-bit pattern |
| 124 | `f64` | the full 64-bit pattern |
| 112 | `funcref` | the function index, `-1` for null |
| 111 | `externref` | the host value, `-1` for null |

Bit patterns, not numbers: this is the only way NaN payloads survive
loads, stores, and `reinterpret` exactly. The constructors build one,
the accessors read one back:

```emo
wasm.i32(v Int64)          wasm.i64(v Int64)
wasm.f32(v Float64)        wasm.f64(v Float64)
wasm.i32_from_bits(bits Int64)   // the exact-pattern constructors,
wasm.f32_from_bits(bits Int64)   // for NaN payloads and bit-exact work
wasm.f64_from_bits(bits Int64)

wasm.as_i32(v) (R, Int64)  // the signed readings — an i32 through its
wasm.as_i64(v) (R, Int64)  // 32-bit two's complement, the floats through
wasm.as_f32(v) (R, Float64) // their patterns; a kind mismatch is an error
wasm.as_f64(v) (R, Float64)
```

## The host interface

`instantiate`'s second argument is the host table — `(module, name, fn)`
triples whose closures serve the module's function imports. The
signature is uniform: the closure takes the argument array
(`Array[(Int64, Int64)]`) and answers one value; an import whose
signature has no result sees the return dropped, and an import wanting
more than one result cannot be served by the table (the link refuses).

Resolution order: the explicit table first, then the register
namespace (`register_instance`), then the built-in `spectest` host the
spec suite's imports name — so an entry naming `("spectest",
"print_i32")` overrides the built-in host for that import.

The table is strict about itself: every entry must name an import of
the module being instantiated — an entry that names nothing is the
caller's typo, and the link refuses it (`host function `env.log`
matches no import of this module`) instead of carrying it silently.

One refusal is part of the contract: a host closure must not call back
into this package. Re-entrancy would ride through the interpreter's
machine state (the operand stack, the current instance, the store) —
the rung records it, a later one may lift it.

## Memory

`read_memory` and `write_memory` are the host's door into the
instance's linear memory 0, bounds-checked like the store's own
accessors — an out-of-bounds range answers `(R.error, "out of bounds
memory access")`. They are how data crosses in both directions without
resorting to exported functions: the demo writes `"EMO"` and the
module's `i32.load8_u` reads `'E'` back; the module stores at 16 and
`read_memory(inst, 16, 4)` reads it back.

## Handles and lifetime

Module and instance handles are indexes into the package's own tables;
nothing frees them, and a program's wasm state lives as long as the
program does. A module loads once and instantiates many times;
`register_instance` publishes an instance's exports to modules loaded
later, which is how two modules link (the corpus's `linking.wast`
family exercises it).

## The CLI: `emo wasm run`

The CLI executes a `.wasm` artifact through the same package, driving
its own interpreter over an embedded driver — the compiler never
links the runtime, so a lone `emo` binary runs an artifact with no
registry and no project of its own:

```bash
emo wasm run demo.wasm
```

The module loads, validates, and instantiates — its start function
runs, as the spec says it does — and then the entry ladder follows:
the `_start` export, then `main`, then the one-line `describe`
summary for a module that names neither (initialization is running
it). Results print one per line in the runtime's `value : kind`
format. Every failure — a bad artifact, a failed link (the import's
name in the reason), a trap — reaches you as the reason on stderr
with exit 1, never a raise or a backtrace.

The host table stays empty at this rung: a module whose imports
`wasm` cannot serve (anything beyond `spectest`) links-fails
honestly. WASI and the `emo` host module are the next rung. The
doctor's wasm line names the command; it needs no external tools.

## WASI: the rung other toolchains' modules run on

The built-in host grew `wasi_snapshot_preview1` — the surface real
toolchains emit (clang/wasi-sdk, `rustc --target wasm32-wasip1`).
Twelve functions are implemented; everything else in the namespace
link-refuses with the function's name — no silent stubs:

| function | answers |
| --- | --- |
| `args_sizes_get`, `args_get` | the argv (`emo wasm run`'s extra arguments; argv[0] is the artifact's name) |
| `environ_sizes_get`, `environ_get` | an empty environment |
| `proc_exit(code)` | unwinds; the CLI maps the code to its exit code |
| `fd_write` | fds 1 and 2 write through the process output channel, iovec bytes raw; other fds EBADF |
| `fd_close`, `fd_seek` | no-op success / ESPIPE on 1 and 2, EBADF elsewhere |
| `fd_fdstat_get` | fd 1/2 answer character device with full rights (what wasi-libc's tty check reads at startup) |
| `random_get` | OS entropy through the `rand` package (Rust's `RandomState` seeds through it even in a hello world) |
| `clock_time_get` | ENOSYS — the fixture pins the refusal; the `time` package carries its own clock imports |
| `sched_yield` | success |

Resolution order: the explicit host table first (a caller may override
any `wasi_snapshot_preview1` import), then the wasi host, then the
register namespace, then `spectest`. Import signatures are checked
against the table's shape — a mistyped import binds to nothing. The
errno values are preview1's numbering (EBADF 8, EINVAL 28, ENOSYS 51,
ESPIPE 69), pinned by the package's fixture.

The `emo` host module the ladder once named stays deferred: no
producer names it — a foreign module cannot, it does not know Emo —
and a construct earns its place with a concrete consumer. A module
wanting Emo's host surface takes it through the explicit host table,
which serves any module name an Emo program chooses.

The live check: `rustc --target wasm32-wasip1` hello world — real
wasi-libc — prints through `emo wasm run` with argv counting and
`process::exit`'s code riding through; a HashMap-seeding module
answers through `random_get`. WASI's stdout is the process output
channel: a module that prints and then exits (or traps) still has its
bytes delivered.

## Conformance

The vendored spec suite rides with the package:

```bash
cd stdlib/registry/wasm/0.1.0
dune test          # the smoke slices of both corpora
dune build @wasm_spec   # all 3456 binary module cases (decoder/validator)
dune build @wasm_runs   # all 25135 run commands (interpreter, ~1 minute)
```

`devtools/vendor-wasm-spec` regenerates the case lists from a pinned
spec checkout; the pinned revision and the licence live in the
package's `testdata/README.md`.

## What it is not

- **WASI preview1's filesystem half stays out.** No preopens, no
  `path_open` — a module asking refuses at the link, naming the
  function; the file story opens when the runtime's own file
  semantics are decided as WASI preopens, a rung of its own.
- **No GC types.** The interpreter targets the core spec's MVP plus
  the five extensions above — function references, SIMD, GC, threads,
  and memory64 stay out. The GC proposal is the exit sign: when it
  lands, the runtime runs the output of `emo build --target wasm`.
- **No re-entrancy.** A host closure calling back into the package
  corrupts the machine state; refused this rung.
- **`["ocaml", "c"]` only, honestly.** The interpreter consumes the
  package wherever it runs; the two compiled targets are the ones
  verified byte-for-byte (the demo's golden is identical on both).
