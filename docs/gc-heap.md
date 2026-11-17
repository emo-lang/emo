# The GC heap — the arena, the object model, and the collector in Emo

## The decision

The GC bootstrap (plan/step-89) opens the track the runtime-independence
principle has been waiting for: a garbage collector written in Emo, the
way the wasm runtime is. The interpreter run is the first host. Step 90
moved the last piece of the machine into place: the heap is one **arena**
of words, the allocator — the `gc` package's own free list — carves and
releases blocks through `heap_carve`/`heap_release`, and the words move
through the raw `heap_load`/`heap_store` lane. The object model above
the arena — the fixed **struct** block, the counted **array** block,
the rooted **ref**, mark-sweep, the free list with its split and
coalesce — is Emo code. One source serves every host that answers the
same doors; the arena the interpreter simulates *is* the spec, and a
target whose memory is real implements the same doors over a granted
region (plan/step-90-gc-ladder.md names the ladder: allocator, payload
packing, the compacting collector, the real-memory hosts).

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

- **One arena.** `heap_new(words)` makes it, once per run; a real host
  grants a region instead. Every address the allocator works in is a
  word offset into that arena.
- **A word is self-describing by parity.** An even word is a scalar,
  stored shifted left one bit; an odd word is a reference, the handle
  a block answers at carve; `0` is null and rides reference slots.
  The tag is the heap's entire typing discipline: a collector can walk
  a heap it did not type, and the same bit rule is the riscv64 dynamic
  value model's — the spec transfers.
- **A handle carries the address and the generation:**
  `(gen << 42) | (offset << 1) | 1`. The generation grows with every
  binding of an offset, so a handle minted before a release dies
  loudly at the next binding of the same words — the stale-handle end
  survives the arena, no tombstones needed.
- **Slot 0 is the header word.** It packs the magic (bits 63:48), the
  kind (47:46 — 1 struct, 2 array), the generation (45:24), the
  collector's mark bit (23), and the logical size (22:0, at most 2^23
  words). The data sits in slots 1..n; the accessors in the `gc`
  package shift so caller field indices start at 0.
- **The doors split by duty.** The host keeps the arena, the binding
  of offsets to blocks, and the checked field access (`struct_get` and
  friends validate kind, generation, and bounds). The allocator's raw
  lane — `heap_load`/`heap_store`, unchecked inside the arena — is
  what the free list and the mark bit work through; the mutator never
  touches it, the same discipline that keeps slot 0 the collector's.

## The doors

| Door | Signature | What it does |
| --- | --- | --- |
| `heap_new(words)` | `Int64 → Int64` | makes the arena, once per run; answers its word count |
| `heap_load(addr)` | `Int64 → Int64` | reads one arena word — the allocator's raw lane |
| `heap_store(addr, w)` | `Int64 → Int64 → Void` | writes one arena word |
| `heap_carve(addr, n, kind)` | `Int64 → Int64 → Int64 → Int64` | binds a range as a block (writes the header), answers the handle |
| `heap_release(h)` | `Int64 → Void` | unbinds a block, zeroes its header |
| `heap_rebind(h, addr)` | `Int64 → Int64 → Int64` | moves one block's binding (the words ride the raw lane) |
| `heap_slide(pairs)` | `Array[Int64] → Array[Int64]` | the compaction door: every bound block, destination order, moved and rebound in one sequence |
| `heap_float_bits(f)` | `Float64 → Int64` | the bit-cast: a float's exact 64 bits |
| `heap_bits_float(w)` | `Int64 → Float64` | the bit-cast back |
| `float_array_get(a, i)` | `Int64 → Int64 → Int64` | a float array's raw bits, checked |
| `float_array_set(a, i, w)` | `Int64 → Int64 → Int64 → Void` | writes raw bits, checked |
| `struct_get(b, i)` | `Int64 → Int64 → Int64` | reads slot `i` (0 header, 1..n data), checked |
| `struct_set(b, i, w)` | `Int64 → Int64 → Int64 → Void` | writes slot `i`, checked |
| `array_len(a)` | `Int64 → Int64` | answers the logical word count |
| `array_get(a, i)` / `array_set(a, i, w)` | — | the array's slots, same rule |
| `block_kind(h)` | `Int64 → Int64` | 1 struct, 2 array |
| `block_size(h)` | `Int64 → Int64` | the logical size |
| `ref_new(w)` | `Int64 → Ref` | creates a root cell holding word `w` |
| `ref_read(r)` | `Ref → Int64` | reads the root's word |
| `ref_write(r, w)` | `Ref → Int64 → Void` | re-points the root |
| `ref_roots()` | `→ Array[Ref]` | the live roots, one major cycle later — the moving collector re-points them |
| `heap_blocks()` | `→ Array[Int64]` | every bound block's handle, address-ordered |
| `heap_words()` | `→ Int64` | physical words over the bound blocks |

**Float arrays (kind 3).** A float's 64 bits cannot ride the parity
lane — the shift round-trip only preserves words whose top bit
repeats, so half of all doubles would corrupt. Floats get their own
block kind: every data slot is raw bits (`heap_float_bits`/
`heap_bits_float` are the conversions), there are no references
inside, and the collector traces a float array without walking its
words. Bytes fit the scalar lane exactly (0..255 round-trips the
shift); the `gc` package's byte accessors check the range on read.
`struct_new`/`array_new` retired at step 90: allocation is the
allocator's — the package's `take` runs first fit over its own free
ranges and calls `heap_carve` — and a door that minted blocks behind
the free list's back was a policy hole. `heap_free` retired with them:
the sweep releases through `heap_release` and hands the range back to
the geometry itself.

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

## The compaction (Emo, not the host)

`collect` marks and sweeps; `compact` does all that and then slides.
The live blocks — address order, destinations from zero — go to
`heap_slide` as `(handle, offset)` pairs, and the host validates the
contiguity, moves the words, and rebinds each block in one sequence
(sliding left keeps every write at or before the next read, so the
pass cannot clobber a source it has not taken). The package rewrites
every reference through its forwarding map — fields first, then the
roots, which is why `ref_roots` answers `Ref` cells — and resets the
free geometry to the one range behind the slide. Fragmentation is a
state the heap passes through, not one it keeps.

## The allocator (Emo, not the host)

The free geometry is the `gc` package's own data: two maps, `by_start`
(start → size) and `by_end` (end → start). Allocation is first fit —
the take splits the range it chooses and leaves the remainder — and a
release merges with whichever neighbor the two maps name, no scan. The
arena is finite (`heap_new` says how many words exist) and an
allocation no range can answer is the loud end: `gc: the arena has no
free range for the request`. `gc.arena(words)` starts the run,
`gc.free_words()` reads the geometry, `gc.addr_of(h)` decodes a
handle's offset — the reuse the demo prints is the allocator's
address answer, not a count.

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
| E3050 | not a live block: an even word, an unbound offset, a stale generation, a heap no `heap_new` has made |
| E3051 | the wrong kind: a struct door on an array block or the reverse |
| E3052 | a slot out of the block's `0..n`, or an arena word past the arena |
| E3054 | a negative size |
| E3055 | a block or arena past the size guards (2^23 / 2^41 words) |
| E3056 | `heap_carve` overlapping a bound block |
| E3057 | `heap_new` making a second arena |
| E4032 | the check-time refusal, one per door, off the interpreter |

E3053 (the double free) retired with `heap_free` at step 90 — a
released block is unbound, and the second release is E3050 like any
stale handle.

## What this closes

The bootstrap proof, grown by the ladder: the allocator and the
collector are Emo code, the interpreter is their host, and
`examples/gc_demo` is the acceptance — a rooted chain and a traced
array survive the collection that kills four thousand unrooted nodes,
the cycle (the shape reference counting can never reclaim) dies the
moment its root lets go, and the second generation's allocations land
*inside the words the sweep gave back* (word 18 and word 12027 — the
junk field's and the cycle's own address space) with the arena never
growing. The goldens: the demo's seventeen lines byte-for-byte on the
interpreter run, `gc_heap_tests` in the checker suite, and the
`gc_refusal` negative goldens naming every door on every refusing
target.

The ladder ahead (plan/step-90-gc-ladder.md): float and byte payload
packing (T90.2), the moving/compacting collector the offset handles
already make rewritable (T90.3), and the real-memory hosts — a `c`
target runtime, the riscv64 tagged-word heap — answering the same
doors over a granted region with the same Emo allocator and collector
compiled in (T90.4).
