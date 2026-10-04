# Step 19 — The systems layer (wasm runtime + EmoOS primitives)

**Milestone:** M6 · **Prereq:** steps 01–18 · **Status:** not started

## The project

A **WebAssembly runtime written in Emo** — decoder, validator, and
interpreter, the way wasmtime is a runtime written in Rust — and, on
the same primitive layer, the road to **EmoOS**: an operating-system
kernel developed in Emo. The two consumers pull the same mechanisms,
so the layer is designed once, with a single gate:

> **The unification gate:** a primitive lands in this layer only when
> it can name both consumers — or one consumer plus a concrete
> near-term need. Nothing speculative, nothing single-purpose.

Ladder (each rung gets its own step plan when it starts):

1. **Step 19 (this step)** — the systems layer: bitwise operators,
   the `Bytes` buffer, the fixed-width integer family's first
   members, float bit reinterpretation, and file reading.
2. **Step 20** — the runtime's binary decoder and validator (module
   model, LEB128, sections, type-stack checking).
3. **Step 21** — the interpreter core, host imports, and conformance
   goldens from the official spec test suite.
4. **M7 (EmoOS)** — the kernel path, on the same layer (below).

Decided now, applies to the whole project:

- **Written in Emo.** The OCaml host only runs it; no native-code
  assist inside the runtime in this ladder.
- **Conformance bar: the official spec suite.** A vendored subset of
  the WebAssembly spec tests is the golden source. The first rung
  targets the core spec (numbers, control flow, calls, memories,
  tables, imports/exports).
- **GC proposal is the exit sign, not the entry.** When the
  interpreter grows struct/array/ref support, the acceptance test is
  running Emo's own `--target wasm` goldens *inside the Emo-written
  runtime*. Until then the spec suite is the bar.
- **No JIT in this ladder.** Interpreter-first; tiered engines are a
  separate project.

## Why these primitives — the mechanism matrix

Surveying both consumers against today's surface (operators are
`== != < <= > >= + - * / % && ||` only; String has `length` /
`substring` / `split`; stdlib is `net` + `http`; Int is the host's
63-bit signed integer):

| Mechanism | wasm runtime needs it for | EmoOS needs it for |
| --- | --- | --- |
| Bitwise `& \| ^ << >> ~` | LEB128, masking, wrap arithmetic, opcode dispatch | page tables, MMIO registers, permission bits, flag words |
| Byte buffer (`Bytes`) | parsing `.wasm` images; the modeled linear memory | disk blocks, framebuffers, boot image, heap arenas |
| Fixed-width integers | `i32`/`i64` semantics; u32/u64 module fields (sizes, offsets, indices) | addresses (u64), page entries (u32/u64), sizes, register words |
| Float bit bridge | NaN canonicalization, `copysign`, reinterpret ops | (rare, but the same bridge) |
| File reading | loading modules from disk | — (the kernel's "file" is the boot image) |

The kernel pulls two things the runtime does not, and both are
already answered by existing mechanisms:

- **The machine escape hatch** (port io, `cli`/`sti`, asm): the
  `foreign def` FFI is that hatch on the near path — generated C
  wrappers link `outb`/`inb`-style shims; the FFI upgrade from the
  embedding study (Int/`Bytes` crossing, callbacks) is what widens it.
- **Freestanding execution**: the near path reuses the native
  pipeline — MirageOS proved OCaml unikernels work, and the native
  backend emits OCaml; solo5/QEMU gives the compile → boot → debug
  loop without new codegen. The far path — a freestanding codegen —
  is the *same* investment a tiered wasm engine needs, which is the
  deepest unification: one machine-code story behind both.

## The decided semantics

- **Bitwise operators on integer types**: `&` (and), `|` (or), `^`
  (xor), `<<` (shift left), `>>` (arithmetic shift right), `~`
  (prefix not). Ruby/Swift lineage; `&&`/`||` stay boolean-only.
  Integers only — other operand types are type errors, never
  silently coerced.
- **Precedence**: `~` sits with unary `-`; `<< >>` sit with `* / %`;
  `& ^ |` sit with `+ -`. All left-associative. One tier per class.
- **`Bytes` — a new core type**: a fixed-length mutable byte
  sequence. `Bytes.new(n)` (zero-filled), `String.to_bytes()` /
  `Bytes.to_string()` (raw reinterpretation, documented as such),
  `length`, `get(i)` / `set(i, v)` bounds-checked (E3004 family),
  and little-endian multi-byte accessors `get_u16_le` / `get_u32_le`
  / `get_u64_le` / `set_u16_le` / `set_u32_le` / `set_u64_le` — the
  exact shape of wasm memory ops and kernel block ops. Big-endian
  variants wait for a consumer.
- **The fixed-width integer family, designed once, staged by
  demand**: signed `Int8`/`Int16`/`Int32`/`Int64` and unsigned
  `Byte`/`UInt16`/`UInt32`/`UInt64` (Swift-lineage names), all with
  wrap-around two's-complement arithmetic (the rule the BEAM backend
  already proved) and the bitwise operators above. **No implicit
  widening or narrowing — conversions are explicit named methods.**
  This step lands the first two members a consumer names today:
  `Int64` (the runtime's `i64`; also the float-bit bridge's carrier)
  and `Byte` (the `Bytes` element). Later members land in steps 20–21
  (`Int32` for wasm) and M7 (`UInt32`/`UInt64` for kernel addresses)
  — the gate cuts both ways: no speculative types either.
- **`Float.to_bits() Int64` / `Float.from_bits(v Int64) Float`** —
  bit reinterpretation for the interpreter's float stage.
- **`file` stdlib package** — `file.read(path String) String` returns
  the raw bytes as a `String`; scheduler-direct like `net`;
  `targets = ["native"]` until other targets grow io. (The kernel
  side does not need it; it stays in this layer because the runtime
  names it.)

## Scope

### In

- Lexer/parser/AST: the six operator tokens; `Int64` and `Byte`
  literals.
- Checker: operator typing (integer types, strict); the two new core
  types; explicit-conversion rule.
- Interpreter: the operators, the `Bytes` accessors, float bits,
  `Int64`/`Byte` arithmetic; `file.read` under the effects scheduler.
- All four backends for everything above; per-backend representation
  notes live in the tasks.
- `runtime/wasm/` — the empty Emo package the runtime will grow in
  (created in T19.4 with a `package.emo` and a smoke module so the
  directory is real from day one).
- Goldens per task; the bit-op and bytes examples join every target's
  CI group.

### Out

- The decoder, validator, and interpreter themselves — steps 20–21.
- The kernel itself — M7; this layer only guarantees its primitives.
- Remaining width-family members (`Int8`, `Int16`, `Int32`,
  `UInt16`, `UInt32`, `UInt64`), big-endian accessors, atomics,
  volatile MMIO ordering — pulled, not speculative.
- SIMD, threads — recorded, not gated.
- JIT / tiered engines, freestanding codegen, WASI — separate
  projects, shared far-term investment noted above.

## Tasks

- [ ] **T19.1** — Bitwise operators (`& | ^ << >> ~`) on integer
      types: lexer, parser, checker, interpreter, and all four
      backends; `examples/bit_ops/` golden through `emo run` and
      every target's CI group.
- [ ] **T19.2** — The `Bytes` core type: construction, bounds-
      checked get/set, little-endian accessors, String interop; all
      four backends; golden example.
- [ ] **T19.3** — `file.read` stdlib package (native, scheduler-
      direct); a golden example reading a file from disk.
- [ ] **T19.4** — `Int64` and `Byte`: literals, wrap-around
      arithmetic, comparisons, explicit conversions; all four
      backends; golden example. `runtime/wasm/` package skeleton
      created here.
