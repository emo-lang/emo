# Atomics — Box's synchronized sibling, sequentially consistent

## The decision

`Atomic` joins `core` as **Box's synchronized sibling**: a mutable
single-value cell whose operations are individually atomic (decided
2026-10-25). Sequential consistency is the only memory order — every
operation, and `fence()`, places itself in one total order that all contexts
agree on; no memory-order parameter exists anywhere in the surface. The first
cut covers two payloads, `Int64` and `Bool`, and nothing else: atomics on any
other payload refuse at check time, named.

The immediate demand comes from EmoOS: an interrupt body and the thread code
it interrupts share one address space on metal, and a read-modify-write built
from `peek` and `poke` cannot survive an interrupt firing between them. The
construct is a general one — it lands in `core`, on every target — but metal
is where sharing gets sharp, and it is the reason the work is scheduled now.

## Why a construct earns its place

- **Ordinary field access stays exactly what it is.** No hidden locks, no
  synchronization toll on code that shares nothing; `Atomic` is the only type
  that pays for synchronization, and only where the programmer asked.
- **Message passing remains the core sharing channel.** `Atomic` is not a
  second concurrency model — it is one cell whose reads and writes are honest
  under preemption, beside the process model, not instead of it.
- **The class of mistakes it closes has no other spelling.** A counter that a
  preemption context bumps while ordinary code runs, a flag cleared exactly
  once: `peek` + `poke` cannot do it (an interrupt fires between them), and a
  plain `Box` cannot do it (unsynchronized cross-context sharing is
  undefined — see Data races below). One construct, and that class of lost
  updates is closed.

## The surface

The type vocabulary follows the container family: `Atomic[Int64]` and
`Atomic[Bool]` are the two spellings that check, and a bare `Atomic` means
"either payload" the way a bare `Box` means "any element". One type taking
its payload as a parameter — no per-width family of atomic type names.
`Atomic.new(0)` constructs; the cell's payload is the argument's type.

```emo
const served = Atomic.new(0)     // an Atomic[Int64]
served.fetch_add(1)              // the value the cell held before the add
served.compare_exchange(1, 0)    // (true, 1) when it swapped
```

`Atomic[Int64]`:

| Operation | Returns | What it does |
| --- | --- | --- |
| `load()` | `Int64` | reads the value the cell holds |
| `store(v)` | — | replaces the value |
| `exchange(v)` | `Int64` | replaces the value, returns the previous one |
| `compare_exchange(expected, new)` | `(Bool, Int64)` | swaps when the cell holds `expected`; returns whether it swapped and the value the cell held before the call, either way |
| `fetch_add(v)` | `Int64` | adds `v`, returns the previous value |
| `fetch_sub(v)` | `Int64` | subtracts `v`, returns the previous value |
| `fetch_and(v)` / `fetch_or(v)` / `fetch_xor(v)` | `Int64` | bitwise read-modify-write, returns the previous value |

`Atomic[Bool]`:

| Operation | Returns | What it does |
| --- | --- | --- |
| `load()` / `store(v)` / `exchange(v)` | `Bool` / — / `Bool` | the same shape as the `Int64` cell |
| `compare_exchange(expected, new)` | `(Bool, Bool)` | the same pair contract |
| `fetch_and(v)` / `fetch_or(v)` / `fetch_xor(v)` | `Bool` | logical read-modify-write, returns the previous value |

The rules the tables sit on:

- **Every read-modify-write returns the value the cell held before the
  operation** — that is what the `fetch_` in the names says.
- **A mismatch in `compare_exchange` is not an error.** `(false, actual)` is
  the answer, and the caller decides what to do with it; nothing raises.
- **Wrap-around follows the `Int64` rule**: `fetch_add`/`fetch_sub` are
  64-bit two's-complement wrap, identical on every target.
- **`fence()` is a free function in `core`, not a method** — it fences the
  program, not a cell: a full sequential-consistency barrier over all memory
  accesses, ordinary and volatile (`peek`/`poke`) alike.
- **Refusals, per strictness-first.** `fetch_add`/`fetch_sub` refuse on
  `Atomic[Bool]` — arithmetic is not Bool's vocabulary; the bitwise family
  is. Payloads outside the two refuse by name: `Atomic[Float64]` has no
  honest lock-free read-modify-write across targets, and non-scalars —
  strings, containers, boxes, a nested `Atomic` — are not cells at all.
- **`==` compares by the values the cells hold now**, each operand read as an
  atomic load — the same structural rule the mutable family follows.

## Sequential consistency only

- One order, one behavior to learn. The operations are strong enough that a
  reader can reason locally: a read-modify-write never loses an update, a
  `load` never observes a torn value, and everything the program did before a
  `store` or a `fence()` is visible to every context that observes what
  follows.
- The kernels this language wants are correctness work, not the last few
  percent of throughput out of a lock-free structure. Weak orders buy that
  last few percent at the price of a second, invisible program — the price is
  refused.
- Targets that carry weaker orders natively keep them behind the FFI; the
  Emo surface lowers to sequential consistency on every target that admits
  atomics at all.

## Copy semantics — how a cell becomes shared

- Emo processes share no memory: a value crossing a process boundary is
  copied, and a mutable value is copied as a snapshot — mutability never
  crosses a process boundary.
- **`Atomic` is the declared exception, and the same exception on every
  target: copying an `Atomic` value copies the handle, and both sides hold
  the same cell.** The precedent is a `Pid` — copying a pid does not copy the
  process. The shared handle is safe because every operation on the cell is
  atomic; sharing it is what the type is for.
- Why not snapshot-on-copy: on the BEAM a shared cell cannot be un-shared —
  the runtime's atomic array is reached through a reference, and a reference
  copied is a cell shared. A snapshot rule for `Atomic` would be a rule one
  target silently breaks. One rule every target can keep: the handle is
  copied, the cell is shared, every access is synchronized.
- This is what makes the construct earn its place on every target, not only
  metal: a service and its clients incrementing one cell, a flag a parent
  sets and its children read — written once, run identically everywhere, and
  the same logic runs unchanged under the interpreter in the dual-run
  harness and under QEMU (EmoOS T3.8).

## The per-target matrix

| Target | Cell mechanism | Op coverage | `fence()` |
| --- | --- | --- | --- |
| interpreter | exact no-ops | full set | no-op |
| `ts` | exact no-ops | full set | no-op |
| `wasm` | exact no-ops | full set | no-op |
| `c` | `__atomic` builtins, sequential-consistency order | full set | `__atomic_thread_fence` |
| `ocaml` | the `Atomic` module, one scheduler domain | full set; bitwise `fetch_*` as compare-and-set loops | no-op |
| `beam` | the runtime's `atomics` array | full set; bitwise `fetch_*` as compare-exchange loops | no-op |
| `riscv64` | AMOs, LR/SC, `fence` — runtime helpers in the generated image | full set | the `fence` instruction |

The honesty notes behind the rows:

- **The hosted no-ops are exact, not approximations.** Every Emo process on
  those targets cooperates on one OS thread and switches only at defined
  points, so sequential consistency holds vacuously and a no-op is a correct
  lowering. The operations still exist and still check — payload scope and
  refusals are check-time everywhere.
- **`ocaml`.** `Atomic.fetch_add`/`fetch_sub` are native and return the
  previous value; the bitwise family has no native read-modify-write and
  lowers to compare-and-set loops. A loop can retry, but the contract — the
  previous value returned, no lost update — is exact.
- **`beam` supersedes the one-line choice recorded before this note** (the
  EmoOS README's per-target honesty, 2026-10-25, named `counters` with CAS
  and the bitwise ops refusing). `counters` cannot serve the surface
  honestly: its read-modify-write (`add`/`sub`) reports only `ok` and returns
  no previous value. The runtime's `atomics` array can: sequential
  consistency is its documented behavior, the cells are signed 64-bit
  wrapping at 2⁶⁴ (the `Int64` rule), `exchange` and `compare_exchange`
  return exactly what the pair contract needs, and `add_get`/`sub_get`
  recover the previous value exactly under the wrap rule — `previous = new −
  v` wraps back to the truth. Only the bitwise family lowers to
  compare-exchange loops, the same fallback the `ocaml` row already carries.
  An `Atomic[Bool]` maps to 0/1 in the cell.
- **`riscv64` is the real one.** `amoswap.d.aqrl` for `store` and
  `exchange`, the fence-bracketed load (`fence rw,rw; ld; fence r,rw`) for
  `load`, LR/SC (`lr.d.aqrl`/`sc.d.rl`) for `compare_exchange` — and, while
  the cell's word is a boxed value in the dynamic model, for the `fetch_*`
  family as well: the loop decodes the word, computes under the wrap rule,
  boxes, and swaps against the exact word it read, re-reading when the cell
  moved meanwhile. `fence()` is the `fence rw, rw` instruction. These are
  runtime helpers in the generated image (landed with T1.6); the AMO
  arithmetic (`amoadd` and its family) is the direct form the moment Stage
  B (S2) gives the cell a raw `Int64` word.

## Data races — what is defined, what is not

Defined:

- **Message passing** — a value crosses a process boundary by copy.
- **Operations on an `Atomic` cell** — they place the cell's history in the
  sequential-consistency total order, on every target that admits the op.
- **`peek`/`poke`** — volatile by definition: never elided, never reordered
  against each other. `fence()` widens that pairwise rule into a full
  barrier; it cannot make a `peek`-then-`poke` pair atomic — nothing does,
  and raw-memory read-modify-write is not a construct.
- **Unsynchronized sharing where contexts never run simultaneously** — the
  interleaving is the scheduler's defined switch points, so nothing
  simultaneous is ever missed.

Undefined — **unsynchronized cross-context sharing of a `Box` field**: when
two contexts that can execute simultaneously reach the same ordinary memory
without atomics or fences ordering them, the behavior is undefined. The
contexts that make this real:

- **an interrupt body against the thread code it interrupted, on metal** —
  the case the ISR discipline already answers with preallocated rings and
  raw memory;
- **SMP harts** — parked on the roadmap; the same clause covers them when
  unparked;
- **any future context the runtime runs simultaneously.**

The language answers by naming it, not by hiding it: ordinary field access
never pays a hidden synchronization toll, and no runtime papers over the
race. The fixes are the ones this note provides — an `Atomic` cell when the
shared state is a value, `peek`/`poke` with `fence()` and the single-writer
ring discipline when the shared state is raw memory. A program that shares
outside these is wrong, and no target where the race is real makes it
accidentally right.

The compiler's line, per strictness-first: the payload scope and the op set
are checked loudly and early; cross-context reachability is not decidable at
check time, so the semantics above is the contract, not a diagnostic.

## What this closes

`rtos-assessment.md` listed "atomics with memory barriers (ISR-versus-task
races)" among what kernel code needs and the language lacked; `xv6.md` named
volatile/atomics/barriers one of the three theoretical blockers for an
operating system written in Emo. This note is the language-side answer: the
lowering arrives per target with T1.4–T1.6 of the EmoOS tracker, the
decisions are recorded in `CHECK.md` (T1.2), and the language surface lands
with T1.3.
