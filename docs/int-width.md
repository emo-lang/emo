# Int width — one integer semantics on every target

## The decision

Integer types are width-explicit. The default integer type is
**`Int64`**: 64-bit two's complement with wrap-around on every target
— arithmetic is performed modulo 2⁶⁴, and overflow behaves identically
whether a program runs natively, on Wasm, on the BEAM, or on bare
metal (decided 2026-10-05).

There is no width-less `Int` spelling and none will be added as an
alias; unannotated integer literals are `Int64` (decided 2026-10-05,
superseding an earlier same-day decision that kept the `Int` spelling
without an `Int64` name).

The implementation still spells the type `Int` (checker, stdlib,
examples); the mechanical rename to `Int64` rides the same step as the
native fix below.

## Why the type is named `Int64`

The 63-bit defect below and the bare `Int` spelling share a root: a
name that does not say its width invites the C question — "how wide is
`int` *here*?" — and that is exactly the ambiguity this decision
removes. Width-suffixed names:

- say what they are — everything is visibly what it is;
- leave no natural-width integer for FFI code to misproject (C's `int`
  is 32-bit on mainstream ABIs; a width-less `Int` beside it is a
  standing trap);
- follow the systems-language lineage (Rust and Zig spell `i32`/`i64`)
  — the implementation-defined-width `int` is the C outlier, and the
  cautionary tale.

## Why: three targets, three integers

The decision replaces a status quo where each target answered "what is
an integer?" for itself:

| Target | Representation today | Semantics today |
| --- | --- | --- |
| Wasm | `i64` | 64-bit wrap — conforms |
| BEAM | masked Erlang integer (step 17) | 64-bit wrap — conforms |
| native | OCaml `int` (unboxed) | 63-bit wrap — deviates |

The native backend emits OCaml source and maps the integer onto
OCaml's `int`, which is 63 bits on 64-bit platforms: one bit of the
machine word is the runtime's immediate/pointer tag. (BEAM's small
integers pay four bits for the same purpose — which is why the BEAM
backend masks; unmasked Erlang integers would upgrade to bignums
instead of wrapping.) `(2^62) * 2` therefore lands on different values
on native and on Wasm/BEAM today.

That mapping put a host implementation detail into the language
semantics. The tag bit is the price OCaml's runtime pays for its value
model — unboxed ints, tag-free polymorphic comparison, GC stack
scanning — and it is not a price Emo passes on to its users. The host
`int` is an implementation candidate, not the definition.

## The native fix (open decision)

Implementing the decided semantics on the native backend means
producing 64-bit arithmetic from a 63-bit host `int`. Two routes — a
real tradeoff, to be settled before that work starts (tracked in
`CHECK.md`):

- **Emit OCaml's boxed `Int64`.** Semantically exact, but the host
  `Int64` is boxed — the specialization pass loses the unboxed
  arithmetic that motivated the current mapping.
- **Two-word (hi/lo) emulation on OCaml `int`.** Stays unboxed;
  add/sub become carry-chained pairs, mul/div split hi/lo — arithmetic
  expands roughly 2–4×. The same technique the future RV32 codegen
  needs (below), so the work is shared.

## RISC-V 32-bit is a codegen problem, not a semantics one

The bare-metal target is named for the ISA (`riscv64`, step 14). A
future `riscv32` implements the same `Int64` with register pairs:
carry chains for add/sub, hi/lo splits for mul/div — the textbook
`long long` technique, shared with the native hi/lo route above. On
RV32 the roles invert: `Int32` is the register-width fast path,
`Int64` the emulated one — semantics unchanged, performance
characteristics differ by target. The costs (two registers and 8 bytes
per value, 2–4× arithmetic) belong to the target, not the language;
narrowing `Int64` to 32 bits on RV32 would be a different language, so
it is off the table. `riscv32` is not scheduled — it follows
`riscv64` only when real hardware demands it.

## Int32 (agreed direction; its own step when scheduled)

`Int32` will join as the second, explicitly-named integer type. It
does not exist to fix the default integer — the decision above does
that. Its motivation:

- **FFI.** C `int32_t` parameters need a landing type (`foreign def`
  currently admits `Float`/`String`/`Bool` only).
- **Bare metal.** MMIO and device registers are 32-bit on RV32;
  `peek`/`poke` need exact widths.
- **RV32 performance.** The register-width escape hatch where
  native-width arithmetic beats emulated 64-bit in hot loops.

Constraints, per strictness-first:

- The default integer is `Int64`; unannotated literals are `Int64`;
  no type-guided literal typing.
- No implicit conversions in either direction; mixed arithmetic
  (`Int64 + Int32`) is rejected; conversions are explicit calls.
- `Int32` wraps at 32 bits, by the same modulo rule.
