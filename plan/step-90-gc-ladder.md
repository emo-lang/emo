# Step 90 — The GC heap's ladder: the allocator, the payloads, the compaction, the hosts

**Milestone:** M51 — The GC ladder · **Prereq:** step 89 (the
bootstrap) · **Related:** `docs/gc-heap.md`, `docs/stdlib/gc.md`,
`examples/gc_demo/`, `CHECK.md` · **Status:** T90.1–T90.3 done; T90.4
open, one commit.

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

### T90.2 — The payloads (done)

The first design died in its own fixture: floats stored as shifted
bit-casts in scalar slots corrupt — the shift round-trip only
preserves words whose top bit repeats (3.5 came back as −3.5), and
one slot mathematically cannot hold 64 bits plus a parity bit. The
landing is the real-GC answer: **float arrays as block kind 3** —
every slot raw Float64 bits through the bit-cast doors
(`heap_float_bits`/`heap_bits_float`) behind checked access
(`float_array_get`/`float_array_set`), no parity, no references
inside, and the collector traces a float array without walking its
words. Bytes fit the scalar lane exactly (0..255 round-trips the
shift) and the package's byte accessors check the range on read.
The family is twenty-two doors; the demo reads 3.5 and −2.25 back
exactly.

### T90.3 — The moving collector (done)

The hazard the design had to answer: rewriting fields through the
doors requires the words at their new addresses, and moving words
through the raw lane requires the new bindings live — any interleaving
of host-side rebinds with Emo-side copies walks into a clobber. The
landing is one door that does the whole slide atomically:
`heap_slide(pairs)` takes every bound block in destination order
(contiguous from zero, the host validates — a slide that misses a
block or breaks the order is E3056), moves the words, and rebinds,
all in one pass whose classic invariant — sliding left keeps every
write at or before the next read — makes it safe. The package runs
the policy: mark, compute destinations, call the slide, rewrite
fields and roots through its forwarding map (`ref_roots` answers
`Ref` cells now, so roots are re-pointable data), reset the geometry
to one range. `heap_rebind` stays as the one-block door behind it.
The demo punches a hole between three rooted allocations, compacts
(ranges 2 → 1, 65496 tail words back), and reads the survivors and
the chain through the new addresses. Twenty-four doors.

### T90.4 — The real-memory hosts (open)

The same doors over a granted region: a `c` target runtime first,
the riscv64 tagged-word heap behind it — the consumer the whole
track exists for. Scope lands when the rung opens.
