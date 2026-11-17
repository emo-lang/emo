# The GC heap — `struct`, `array`, `ref`, and the collector in Emo

## The decision

The GC bootstrap (plan/step-89) opens the track the runtime-independence
principle has been waiting for: a garbage collector written in Emo, the
way the wasm runtime is. The interpreter run is the first host. It
grows the machine's object model — the fixed **struct** block, the
counted **array** block, and the rooted **ref** — as bare-name doors,
and the `gc` package implements mark-sweep over them in pure Emo. One
source serves every host that answers the same doors; the heap the
interpreter simulates *is* the spec, and a target whose memory is real
implements the same doors over real words.

This does not reopen T23.5. The hosted runtime's reclamation model —
reference counting for identity objects, arena for value families —
stands; this track is a library with its own managed heap, not a change
to any runtime's value model. What it answers first is the demand the
reclamation model cannot: a collector that walks cycles (reference
counting never reclaims them), and the freestanding target's missing
piece — `runtime-and-freestanding.md` lists "an allocator, a garbage
collector" as the runtime's own work, and on metal there is no host to
borrow either from.

## The object model

- **A word is self-describing by parity.** An even word is a scalar,
  stored shifted left one bit; an odd word is a reference, the handle a
  block answers at allocation; `0` is null and rides reference slots.
  The tag is the heap's entire typing discipline: a collector can walk
  a heap it did not type, and the same bit rule is the riscv64 dynamic
  value model's — the spec transfers.
- **A block is one of two kinds.** `struct` (kind 1) is fixed length,
  `array` (kind 2) carries its count. Ids grow from 1; a handle word is
  `(id << 1) | 1`.
- **Slot 0 is the collector's header.** The data sits in slots `1..n`;
  `block_size` answers the logical size `n`, and the physical slot run
  is `0..n`. The header's mark bit is the collector's private state —
  a real host would carry a physical header word, the interpreter's
  block table is its implementation of the same contract.
- **The doors are raw.** No accessor shifts, no bounds forgiveness: a
  slot index is a physical slot, checked loudly.

## The doors

| Door | Signature | What it does |
| --- | --- | --- |
| `struct_new(n)` | `Int64 → Int64` | allocates an `n`-field struct, answers the handle |
| `array_new(n)` | `Int64 → Int64` | allocates an `n`-word array, answers the handle |
| `struct_get(b, i)` | `Int64 → Int64 → Int64` | reads slot `i` (0 header, 1..n data) |
| `struct_set(b, i, w)` | `Int64 → Int64 → Int64 → Void` | writes slot `i` |
| `array_len(a)` | `Int64 → Int64` | answers the logical word count |
| `array_get(a, i)` / `array_set(a, i, w)` | — | the array's slots, same rule |
| `block_kind(h)` | `Int64 → Int64` | 1 struct, 2 array |
| `block_size(h)` | `Int64 → Int64` | the logical size |
| `ref_new(w)` | `Int64 → Ref` | creates a root cell holding word `w` |
| `ref_read(r)` | `Ref → Int64` | reads the root's word |
| `ref_write(r, w)` | `Ref → Int64 → Void` | re-points the root |
| `ref_roots()` | `→ Array[Int64]` | the live roots' words, one major cycle later |
| `heap_blocks()` | `→ Array[Int64]` | every live block's handle, id-ordered |
| `heap_free(h)` | `Int64 → Void` | frees one block (the sweep's only way out) |
| `heap_words()` | `→ Int64` | physical words over the live blocks |

## The roots

A `Ref` is one mutable word the interpreter can see. Every `Ref` value's
cell registers weakly: the host's own collector is the liveness oracle,
so a root the program dropped leaves the registry at its next major
cycle — no toll, no drop verb, and the use-after-drop class dies by
construction. `ref_roots()` forces a major cycle before it reads, so a
collection sees exactly what the mutator still holds; the snapshot is
ordered, the walk is order-free.

The mutator discipline is the rooted-handle rule (the shape
SpiderMonkey's `Rooted` keeps): a handle a collection must respect
lives in a `ref`; a bare `var` holding a handle is invisible to the
collector and the block it names dies at the next `collect`. A
collection allocates nothing — the worklist is host memory — and the
allocation points are ordinary package calls, so no pause protocol
exists to get wrong.

## The `gc` package

Pure Emo over the doors. The accessors carry the shift (`s_set` stores
`v << 1`, `s_get` answers `w >> 1`, the arithmetic shift round-trips
negatives), the `_ref` accessors refuse an even nonzero word — a scalar
parked where a reference belongs — while null passes. The accessors
shift field indices by one so caller fields start at 0 and slot 0
stays the collector's.

`collect()` is mark-sweep: mark from the roots through the odd words,
the header's bit cutting cycles; drain the worklist until the cursor
meets the builder's length (the walk goes as deep as the graph, not one
step past the roots); sweep `heap_blocks()`, freeing the unmarked and
clearing the marked. It answers the words the sweep reclaimed.

A root that reaches a freed block dies loudly at the door — E3050 —
the same stale-handle end every door gives.

## The per-target matrix

The admission principle is the raw-memory family's turned around: a
target admits the GC heap iff the target's memory is the collector's to
manage.

| Target | the doors |
| --- | --- |
| interpreter run | admits — the doors are the run's object model |
| `c`, `ocaml`, `typescript`, `browser`, `wasm`, `beam`, `riscv64` | refuse by name at check time (E4032) |

The interpreter run checks as the target `interpreter` (`emo run`'s
checking passes it; `emo check` and the LSP keep the hosted default,
so a gc-door program shows its refusal in the editor the way a
`peek8` program does off `riscv64`). A `Ref` crosses a process
boundary as the same cell — the registry is the run's own, and one
root either way. `heap_words` counts physical words; the interpreter's
own blocks, boxed values, and builder storage stay the host's memory
and are nobody's door to name.

## The errors

| Code | Reads |
| --- | --- |
| E3050 | not a live block: an even word, an unknown id, a stale (freed) handle |
| E3051 | the wrong kind: a struct door on an array block or the reverse |
| E3052 | the slot is out of the block's `0..n` |
| E3053 | `heap_free` frees a block twice |
| E3054 | a negative size |
| E3055 | a block past the size guard (2^26 words) |
| E4032 | the check-time refusal, one per door, off the interpreter |

## What this closes

The bootstrap proof: the collector is Emo code, the interpreter is its
first host, and `examples/gc_demo` is the acceptance — a rooted chain
and a traced array survive the collection that kills four thousand
unrooted nodes, and the cycle (the shape reference counting can never
reclaim) dies the moment its root lets go. The goldens: the demo's
nine lines byte-for-byte on the interpreter run, `gc_heap_tests` in
the checker suite, and the `gc_refusal` negative goldens naming every
door on every refusing target.

The ladder this step names but does not build: the allocator's free
list in Emo (the doors currently allocate from the interpreter's
table), float and byte payload packing, the moving or compacting
collector the `Ref` indirection already leaves room for, and the
real-memory hosts — a `c` target runtime, the riscv64 tagged-word
heap — answering the same doors over real words with the same Emo
collector compiled in.
