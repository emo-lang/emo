# Raw memory — `peek`/`poke`, volatile by definition

## The decision

`peek8` / `poke8` / `peek64` / `poke64` join `core` as free functions —
the `fence()` precedent: bare names, no import, no wrapper type. They are
volatile by definition (settled with the atomic memory model,
2026-10-25): never elided, never reordered against each other. The
surface settled the same day: two access widths, the byte lane and the
word lane, and an admission rule that keeps them freestanding-only.

The demand is EmoOS: the 16550A UART is driven through its registers at
`0x10000000`, frames and page tables are words in raw memory, and the
kernel owns every address on the machine. The construct is raw memory
itself — the untyped-memory discipline the kernel's design already
names — given a checked surface instead of an escape hatch.

## The surface

| Builtin | Signature | What it does |
| --- | --- | --- |
| `peek8(addr)` | `Int64 → Byte` | a volatile byte load, read unsigned (0–255) |
| `poke8(addr, b)` | `Int64 → Byte → Void` | a volatile byte store |
| `peek64(addr)` | `Int64 → Int64` | a volatile word load |
| `poke64(addr, v)` | `Int64 → Int64 → Void` | a volatile word store |

The rules the table sits on:

- **The width rides the payload type.** A `Byte` *is* eight bits and an
  `Int64` *is* sixty-four: there is no extension question to answer and
  no truncation to perform — the value that crosses is the value that
  fits. The byte lane reads unsigned, the MMIO-natural reading; a
  register's high bit survives as 128–255, not a negative number.
  Conversions are the existing, explicit ones: `Byte.from_int64` (0–255
  checked, out of range is a loud error), `Int64.to_byte` (the low
  eight bits), `Byte.to_int64` (widening, always safe).
- **`poke` answers `Void`.** A raw-memory read-modify-write is not a
  construct — `peek`-then-`poke` cannot survive an interrupt between
  them, and no fence changes that (the atomics note says exactly this).
  Answering the previous value would invite the pattern; answering
  nothing keeps the refusal honest. The synchronized form of a
  read-modify-write is an `Atomic` cell.
- **The address is exactly what the hardware sees.** `Int64`, no
  validation, no provenance — a raw physical (later virtual) address.
  A bad address **traps**: before the kernel installs its trap vector
  the trap is the firmware's reset; after (EmoOS M2) it is the kernel's
  trap path. That is the machine's defined behavior, named, not waved
  off as undefined.
- **Alignment and endianness are the caller's discipline.** MMIO
  registers are naturally aligned by bus protocol; memory is
  little-endian on the machine. No checks, and no byteswap construct —
  bit masks are the programmer's job, the discipline the kernel's
  design already declares.
- **Byte arithmetic keeps the family rule.** `Byte` operands wrap
  modulo 256, unsigned, identically on every target — the rule the
  hosted targets already run. Bitwise work stays in-type
  (`peek8(lsr) & 32B`); mixing widths refuses, as it does everywhere
  else, and `.to_int64()` crosses when the arithmetic wants to be wide.

The width set is deliberately `{8, 64}`. The 32-bit lane waits for
`Int32` — its surface is already settled (`docs/numeric-width.md`), and
when it lands, `peek32 : Int32` / `poke32(addr, v : Int32)` is the
honest shape for the first consumer (virtio MMIO, EmoOS T7.1). A 16-bit
lane has no consumer on the roadmap and is not built speculatively.

## Volatile — what the rule means

- The four builtins are never elided and never reordered against each
  other; `fence()` widens that pairwise rule into a full barrier over
  ordinary and volatile accesses alike (the atomics note's contract).
  Nothing makes a `peek`-then-`poke` pair atomic.
- On `riscv64` each builtin is one load/store instruction (`lbu`, `ld`,
  `sb`, `sd`) inside a runtime helper, emitted in program order — a
  backend with no optimizer keeps the rule by construction today, and
  Stage B keeps it when the ops inline into typed bodies (EmoOS T2.3).

## The per-target matrix

| Target | `peek8`/`poke8`/`peek64`/`poke64` |
| --- | --- |
| `riscv64` | admits — the volatile access helpers in the generated image |
| interpreter, `c`, `ocaml`, `ts`, `wasm`, `beam` | refuse by name at check time (E4028) |

The principle behind the rows: **a target admits `peek`/`poke` iff the
program owns the address space.** On a hosted target the runtime's heap
belongs to the host — tag bits, collectors, moving or not — so no
address the program could name is honest to read through, and a program
has no in-language way to obtain one in the first place. The atomics
no-op precedent does not carry over: an atomic no-op is exact because
nothing runs concurrently; a peek no-op would have to invent a value —
a silent fallback. Refusing is the honest row, and the rare hosted case
that truly needs raw C has `foreign def` already.

The dual-run harness (EmoOS T3.8) is unaffected by construction:
devices sit behind structural interfaces, the fake devices implement
those interfaces under the hosted interpreter, and interpreter-run code
never spells a `peek` — the named refusal enforces the seam instead of
trusting discipline.

## The Byte lane on riscv64 (what landed with this note)

The riscv64 value model gained the `Byte` immediate — immediate kind 3
in bits 3:1, the byte in bits 11:4 — completing what every hosted
target already carries: byte literals (`32B`), in-type arithmetic
wrapping modulo 256, comparisons, `to_string`, and the conversions.
Gaps that stay named rather than hidden:

- A `Byte` whose static type the IR lost — the result of a type-level
  method call, a module-level `const` read — reaches the dynamic
  dispatch, which answers only `to_string` on a Byte immediate and
  fails loudly. Parameters, locals, and ordinary expressions carry
  their types; bind before calling.
- `Bytes` buffers remain refused on riscv64: no consumer yet, separate
  work.

And one scheduled cost, not a gap: in the dynamic value model each
`peek` allocates a boxed cell — the exact cost Stage B exists to remove
(EmoOS T2.3 unboxes the lanes). Until then a polling loop is a heap
burner by construction, and the goldens stay away from one.

## What this closes

`xv6.md` named volatile access and barriers among the theoretical
blockers for an operating system in Emo; the atomics note answered the
barrier half, this note answers the volatile half. Landed 2026-10-26
with EmoOS T1.8. The goldens: the QEMU corpus `examples/peek_poke` (RAM
roundtrips on both widths, the little-endian byte picture, the Byte
arithmetic family, the 16550's line-status register read byte-wide —
0x60, the reset value) and a refusal golden per hosted target, each
naming E4028.
