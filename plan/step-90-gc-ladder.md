# Step 90 — The GC heap's ladder: the allocator, the payloads, the compaction, the hosts

**Milestone:** M51 — The GC ladder · **Prereq:** step 89 (the
bootstrap) · **Related:** `docs/gc-heap.md`, `docs/stdlib/gc.md`,
`examples/gc_demo/`, `CHECK.md` · **Status:** T90.1 done; T90.2–T90.4
open, one commit each.

## Why this step exists

Step 89 proved the collector could be Emo code; the heap it managed
was still the host's toy — a block table that minted ids and never
reused a word. The ladder's four rungs take the heap from toy to
machine: an allocator in Emo over a real arena (T90.1), the payloads
a real program stores (T90.2), the moving collector a fragmented heap
needs (T90.3), and the real-memory hosts that make the whole thing
load-bearing for EmoOS (T90.4). Each rung lands as its own commit;
the arena first, because the other three stand on it.

## The rungs

### T90.1 — The arena and the allocator (done)

The design decision of the step: the host keeps the *mechanism*, the
language owns the *policy*. One arena (`heap_new`, once per run, at
most 2^41 words); a raw lane (`heap_load`/`heap_store`, bounds only);
`heap_carve(addr, n, kind)` binding a range as a block and
`heap_release(h)` unbinding it; and the free geometry in Emo — two
maps (`by_start` start→size, `by_end` end→start), first fit over the
ranges, the take splitting its choice, a release merging with the
neighbors the maps name. `struct_new`/`array_new`/`heap_free` retired
at the same stroke: a door that minted blocks behind the free list's
back was a policy hole, and the sweep's release is the only way words
leave.

Handles became `(gen << 42) | (offset << 1) | 1` — the address the
allocator works in, plus a per-offset generation that outgrows every
handle minted before a release. The stale-handle end (E3050) survives
the arena with no tombstones; E3053 (the double free) retired with
`heap_free`, E3056 (carve overlap) and E3057 (a second arena) joined.
The header word at slot 0 packs magic/kind/generation/mark/size, and
the mark bit flips through the raw lane like any other header edit.

The acceptance grew: the demo's second generation allocates two
structs after everything collectable is freed, and first fit lands
them *inside the sweep's own words* — word 18 (the junk field's
address space) and word 12027 (the cycle's) — seventeen lines
byte-for-byte, `free words` back where it started, the arena never
growing.

Found and fixed on the way: `init` is Emo's constructor word — the
package's entry is `gc.arena`; module-level consts are lower_snake.

### T90.2 — The payloads (open)

Float and byte words packed beside the scalars and the references.
The lane stays Int64-with-parity; the plan is bit-cast doors
(`heap_float_bits`/`heap_bits_float`) and package accessors
(`s_set_float` and friends) that store the bits as shifted scalars —
the field's kind stays the mutator's knowledge, the same discipline
that already splits scalars from references.

### T90.3 — The moving collector (open)

Mark-compact over the arena: mark as today, compute the sliding,
rewrite every reference (fields and roots — `ref_roots` answers
`Ref` cells then, so the sweep can re-point them), move the words,
`heap_rebind` the metadata. The offset handles make references
rewritable data — the piece step 89's design left a door open for.

### T90.4 — The real-memory hosts (open)

The same doors over a granted region: a `c` target runtime first,
the riscv64 tagged-word heap behind it — the consumer the whole
track exists for. Scope lands when the rung opens.
