# Numeric width — width-explicit types on every target

## The decision

Numeric types are width-explicit. **`Int64`** is the default integer
type: 64-bit two's complement with wrap-around on every target —
arithmetic is performed modulo 2⁶⁴, and overflow behaves identically
whether a program runs natively, on Wasm, on the BEAM, or on bare
metal. **`Float64`** is the default float type: IEEE 754 binary64 on
every target (decided 2026-10-05).

There are no width-less `Int` or `Float` spellings and none will be
added as aliases; integer literals without type declarations are
`Int64` and float literals without type declarations are `Float64`
(the `Int64` part supersedes an earlier same-day decision that kept the
`Int` spelling without an `Int64` name).

The implementation now spells the types `Int64` and `Float64`
(checker, stdlib, examples, runtime); the mechanical rename landed on
its own, ahead of the `ocaml` route below.

## Why the types are named by width

The 63-bit mapping below (now history) and the bare `Int` spelling share
a root: a name that does not say its width invites the C question — "how
wide is `int` *here*?" — and that is exactly the ambiguity this decision
removes. Width-suffixed names:

- say what they are — everything is visibly what it is;
- leave no natural-width type for FFI code to misproject (C's `int`
  is 32-bit on mainstream ABIs; its `float` and `double` differ in
  width too, and a width-less `Float` beside them is a standing trap);
- follow the systems-language lineage (Zig spells `i32`/`i64` and
  `f32`/`f64`) — the implementation-defined-width `int` is the C
  outlier, and the cautionary tale.

## Int64: one integer, every target

`Int64` is 64-bit two's complement with wrap-around on every target.
Each target reaches it with the representation it already had:

| Target | Representation | Semantics |
| --- | --- | --- |
| Wasm | `i64` | 64-bit wrap — conforms |
| BEAM | masked Erlang integer (step 18) | 64-bit wrap — conforms |
| TypeScript | `BigInt` wrapping at 64 bits | 64-bit wrap — conforms |
| `ocaml` | OCaml `int64` (boxed `Int64 of int64` in the dynamic layer) | 64-bit wrap — conforms |
| `c` | `uint64_t` (the tagged word in the dynamic layer) | 64-bit wrap — conforms |
| `riscv64` | boxed 64-bit cell | 64-bit wrap — conforms |

The BEAM backend masks small integers to signed 64 bits, because
Erlang's integers are arbitrary-precision and an unmasked add would
upgrade to a bignum instead of wrapping.

## The `ocaml` route (settled)

The `ocaml` backend carries `Int64` as OCaml's `int64` in both layers —
boxed in the dynamic value (`Int64 of int64`), and as the specialized
parameter, local, and result type with arithmetic emitted as
`Int64.add`-style operations — so its wrap-around matches every other
target (settled 2026-10-11, tracked in `CHECK.md`).

An earlier mapping put the integer on OCaml's `int`, which is 63 bits on
64-bit platforms — one machine-word bit is the runtime's immediate/pointer
tag — and `(2^62) * 2` therefore landed on different values there than on
Wasm and BEAM. The `Int64` rename and the boxed-`Int64` route removed that
deviation: the host `int` was an implementation candidate, not the
definition.

The alternative — unboxed two-word (hi/lo) emulation on OCaml `int` — was
not taken: its RV32 motivation is moot (the freestanding target is
`riscv64`, with native 64-bit registers), and the `c` target (the default
since step 24) is where specialized numeric performance lives.

## Float64: already uniform

Unlike the integer, the float needs no fix: it is IEEE 754 binary64 on
every target today — OCaml `float`, Wasm `f64`, Erlang floats, and JS
`number` in the TypeScript backend. Every target already conforms, so
the decision here is the name alone; display and parsing rules stay
target-independent by construction.

## RISC-V 32-bit is a codegen problem, not a semantics one

The bare-metal target is named for the ISA (`riscv64`, step 15). A
future `riscv32` implements the same `Int64` with register pairs:
carry chains for add/sub, hi/lo splits for mul/div — the textbook
`long long` technique. On
RV32 the roles invert: `Int32` is the register-width fast path,
`Int64` the emulated one — semantics unchanged, performance
characteristics differ by target. The costs (two registers and 8 bytes
per value, 2–4× arithmetic) belong to the target, not the language;
narrowing `Int64` to 32 bits on RV32 would be a different language, so
it is off the table. `riscv32` is not scheduled — it follows
`riscv64` only when real hardware demands it.

## Int32 (surface settled; its own step when scheduled)

`Int32` will join as the second, explicitly-named integer type: 32-bit
two's complement, wrapping at 2³². It does not exist to fix the
default integer — the decision above does that. Its motivation:

- **FFI.** C `int32_t` parameters need a landing type (`foreign def`
  admits `Float64`/`String`/`Bool`/`Int64` per target, but has no 32-bit
  landing type).
- **Bare metal.** MMIO and device registers are 32-bit on RV32;
  `peek`/`poke` need exact widths.
- **RV32 performance.** The register-width escape hatch where
  native-width arithmetic beats emulated 64-bit in hot loops.

Constraints, per strictness-first:

- The default integer is `Int64`; literals without type declarations
  are `Int64`; no type-guided literal typing.
- No implicit conversions in either direction; mixed arithmetic
  (`Int64 + Int32`) is rejected; conversions are explicit calls named
  with the existing pattern (`Int32.from_int64(x)` / `x.to_int32()`).
- `Int32` wraps at 32 bits, by the same modulo rule.

## Float32 (surface settled; its own step when scheduled)

`Float32` will join as the second, explicitly-named float type: IEEE
754 binary32. Its motivation:

- **FFI.** C `float` parameters need a landing type distinct from
  `double`.
- **Bare metal.** Device registers and firmware structures use
  binary32.
- **Memory bandwidth.** Half the bytes of `Float64` for numeric arrays
  where precision is already bounded.

Constraints, per strictness-first (same shape as `Int32`):

- The default float is `Float64`; float literals without type
  declarations are `Float64`; no type-guided literal typing.
- No implicit conversions in either direction; mixed arithmetic
  (`Float64 + Float32`) is rejected; conversions are explicit calls
  (`Float32.from_float64(x)` / `x.to_float32()`).
- `Float32` rounds to binary32 per operation (correctly rounded via a
  binary64 ALU — 53 bits cover 2×24+2); display uses binary32
  shortest round-trip.
