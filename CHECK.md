# CHECK

Pending design decisions — deliberately kept out of the README until they are settled.

- Mixin mechanism: include syntax, single vs. multiple includes, name-collision rules.
- Exception catching syntax (`raise` is decided; the catch form is not).
- Whether raw strings are needed. The escape set settled in step 12: `\n \r \t \\ \' \"`.
- Numeric literal formats: hexadecimal, binary, digit separators (decimal-only for now).
- Numeric width: **settled** — numeric types are width-explicit: `Int64`/`Int32` and `Float64`/`Float32`; defaults are `Int64` and `Float64`; no width-less `Int`/`Float` spellings; bare literals default to the 64-bit type (decided 2026-10-05 — README, Type System; rationale in `docs/numeric-width.md`). Open: the native backend's route to 64-bit integer arithmetic on OCaml's 63-bit `int` — emit OCaml's boxed `Int64` vs unboxed two-word hi/lo emulation (the technique RV32 codegen will also need), plus the mechanical `Int` → `Int64` / `Float` → `Float64` rename across checker/stdlib/examples/docs.
- Int32 / Float32: agreed as future explicitly-named fixed-width types for FFI (`int32_t` / C `float` marshaling), bare-metal MMIO/device registers, and RV32 hot loops (`docs/numeric-width.md`). Open surface: explicit-only conversions, per-type wrap/rounding (literal typing settled — bare literals are `Int64`/`Float64`).
- C FFI binding-surface syntax: **settled in step 13** — `foreign def name(params) Ret = "c_symbol"`, `Float`/`String`/`Bool` only, compiled through generated C wrappers (see `docs/native-backend.md`).
- Binary / CLI tool distribution mechanism.
