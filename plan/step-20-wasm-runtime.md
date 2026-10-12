# Step 20 — The systems layer (wasm runtime)

**Milestone:** M6 · **Prereq:** steps 01–07 · **Status:** complete

## The project

A **WebAssembly runtime written in Emo** — decoder, validator, and
interpreter, the way wasmtime is a runtime written in Rust. The
layer is designed once, with a single gate:

> **The unification gate:** a primitive lands in this layer only when
> it names a concrete near-term need. Nothing speculative.

Ladder (each rung gets its own step plan when it starts):

1. **Step 20 (this step)** — the systems layer: bitwise operators,
   the `Bytes` buffer, the fixed-width integer family's first
   members, float bit reinterpretation, and file reading.
2. **Step 21** — the runtime's binary decoder and validator (module
   model, LEB128, sections, type-stack checking).
3. **Step 22** — the interpreter core, host imports, and conformance
   goldens from the official spec test suite.

The package boundary, the spec-data split, and the condition for leaving
this repository are recorded in `plan/step-21-wasm-decoder.md`; they
bind the whole ladder, and they are what keeps an in-repo runtime from
growing into an in-repo language.

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

Surveying the runtime against today's surface (operators are
`== != < <= > >= + - * / % && ||` only; String has `length` /
`substring` / `split`; stdlib is `net` + `http`; Int is the host's
63-bit signed integer):

| Mechanism | wasm runtime needs it for |
| --- | --- |
| Bitwise `& \| ^ << >> ~` | LEB128, masking, wrap arithmetic, opcode dispatch |
| Byte buffer (`Bytes`) | parsing `.wasm` images; the modeled linear memory |
| Fixed-width integers | `i32`/`i64` semantics; u32/u64 module fields (sizes, offsets, indices) |
| Float bit bridge | NaN canonicalization, `copysign`, reinterpret ops |
| File reading | loading modules from disk |

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
  exact shape of wasm memory ops. Big-endian
  variants wait for a consumer.
- **The fixed-width integer family, designed once, staged by
  demand**: signed `Int8`/`Int16`/`Int32`/`Int64` and unsigned
  `Byte`/`UInt16`/`UInt32`/`UInt64` (Swift-lineage names), all with
  wrap-around two's-complement arithmetic (the rule the BEAM backend
  already proved) and the bitwise operators above. **No implicit
  widening or narrowing — conversions are explicit named methods.**
  This step lands the first two members a consumer names today:
  `Int64` (the runtime's `i64`; also the float-bit bridge's carrier)
  and `Byte` (the `Bytes` element). Later members land in steps 21–22
  (`Int32` for wasm) — the gate cuts both ways: no speculative types
  either.
- **`Float.to_bits() Int64` / `Float.from_bits(v Int64) Float`** —
  bit reinterpretation for the interpreter's float stage.
- **`file` stdlib package** — `file.read(path String) String` returns
  the raw bytes as a `String`; scheduler-direct like `net`;
  `targets = ["native"]` (today `["ocaml", "c"]`) until other targets grow io.
  (It stays in this layer because the runtime names it.)

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
  (created in T20.4 with a `package.emo` and a smoke module so the
  directory is real from day one).
- Goldens per task; the bit-op and bytes examples join every target's
  CI group.

### Out

- The decoder, validator, and interpreter themselves — steps 21–22.
- Remaining width-family members (`Int8`, `Int16`, `Int32`,
  `UInt16`, `UInt32`, `UInt64`), big-endian accessors, atomics,
  volatile MMIO ordering — pulled, not speculative.
- SIMD, threads — recorded, not gated.
- JIT / tiered engines, freestanding codegen, WASI — separate
  projects.

## Tasks

- [x] **T20.1** — Bitwise operators (`& | ^ << >> ~`) on integer
      types: lexer, parser, checker, interpreter, and all four
      backends; `examples/bit_ops/` golden through `emo run` and
      every target's CI group.
- [x] **T20.2** — The `Bytes` core type: construction, bounds-
      checked get/set, little-endian accessors, String interop; all
      four backends; golden example. The u64 accessors wait for
      `Int64` (T20.4) — 63-bit host Int cannot carry them. Known wasm
      gap: printing a raw `Bytes` value writes the buffer's bytes
      instead of the `Bytes[n]` label — the `to_str` bytes branch
      interacts with something subtle in the chain and is backed out;
      `to_string()` (raw) and every other method work. Revisit with the
      label as a `to_str` caller-side wrapper.
- [x] **T20.3** — `file.read` stdlib package (native, scheduler-
      direct); a golden example reading a file from disk. Ships
      `file.write` too — the demo writes its own data file, which
      keeps the golden independent of the working directory. The
      write handler closes the channel before resuming the process:
      the resumption runs synchronously, and read-your-own-write
      beats descriptor hygiene. Tests resolve the registry through
      EMO_REGISTRY pointed at the sandbox's stdlib copy.
- [x] **T20.4** — `Int64` and `Byte`: literals, wrap-around
      arithmetic, comparisons, explicit conversions; all four
      backends; golden example. `runtime/wasm/` package skeleton
      created here.

## Close-out

The layer's primitives are in: bitwise operators, `Bytes`,
`Int64`/`Byte` with float bit reinterpretation, and `file.read` /
`file.write`. Int64 and Byte ride the existing integer
representations on every target — OCaml `int64`/`int`, Erlang
integers masked to signed 64 bits, wasm's `$vint` struct, TS
`BigInt`/`number` — so no backend grew a new value model; what each
one added was the wrap rule (Byte's results mask to 256 after add,
sub, mul, shl, bnot) and the explicit conversions.

Two backend notes worth keeping. Erlang has no way to write a float
bit-string *pattern* in Core Erlang text — OTP 29's `erlc` aborts with
an internal consistency check on any float segment, so `from_bits`
goes back through `binary_to_term` on an ETF float header. And Emo
prints floats by OCaml's `%g` rule, which Erlang's own format has
neither the thresholds nor the zero-stripping for; both the BEAM
runtime and the wasm host implement that rule themselves.

The wasm golden flushed out two runtime bugs the earlier examples never
reached: `bytes_from_mem` read linear memory at `i` instead of
`ptr + i`, and `int_str` took its digits with signed division, which
mangles `INT64_MIN`. Both are fixed.

The checker has one caveat for backend authors: `emo_check` records an
expression's type by its start offset, so when a call and its receiver
begin at the same offset the outer type wins. A method's receiver
cannot be dispatched on `ety` — dispatch on the structural type or on
a runtime test instead.
