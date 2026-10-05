# CHECK

Pending design decisions — deliberately kept out of the README until they are settled.

- Mixin mechanism: include syntax, single vs. multiple includes, name-collision rules.
- Exception catching syntax (`raise` is decided; the catch form is not).
- Whether raw strings are needed. The escape set settled in step 12: `\n \r \t \\ \' \"`.
- Numeric literal formats: hexadecimal, binary, digit separators (decimal-only for now).
- Int width: **settled** — integer types are width-explicit; the default integer type is `Int64` (64-bit two's complement wrap-around on every target, bare literals are `Int64`, no width-less `Int` spelling; decided 2026-10-05 — README, Type System; rationale in `docs/int-width.md`). Open: the native backend's route to 64-bit arithmetic on OCaml's 63-bit `int` — emit OCaml's boxed `Int64` vs unboxed two-word hi/lo emulation (the technique RV32 codegen will also need), plus the mechanical `Int` → `Int64` rename across checker/stdlib/examples/docs.
- Int32: agreed as a future explicitly-named fixed-width type for FFI (`int32_t` marshaling), bare-metal MMIO, and RV32 hot loops (`docs/int-width.md`). Open surface: explicit-only conversions, wrap at 32 bits (literal typing settled — bare literals are `Int64`).
- C FFI binding-surface syntax: **settled in step 13** — `foreign def name(params) Ret = "c_symbol"`, `Float`/`String`/`Bool` only, compiled through generated C wrappers (see `docs/native-backend.md`).
- Binary / CLI tool distribution mechanism.
