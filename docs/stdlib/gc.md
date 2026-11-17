# The `gc` Package

The GC heap's allocator and collector: the free list and mark-sweep
written in pure Emo over the object-model doors the interpreter run
admits ([`docs/gc-heap.md`](../gc-heap.md) is the design note). The
arena is the host's; everything on top of it — the carving, the free
geometry with its split and merge, the tracing, the sweep — is this
package. One source serves every host that answers the same doors; the
interpreter run is the first, and on every build target the whole
family refuses at check time (E4032) — this package resolves there and
its doors refuse in the program, so the honest seat is the run alone.

## Using the package

```emo
require "gc"

gc.arena(65536)   // once per run: the arena the allocator carves from
```

The standard library ships with the compiler, but its packages are
versioned like any other: `require "gc"` needs `"gc" = "0.1.0"` in the
manifest's `deps` block. `arena` makes the heap — a finite arena is
the point, and an allocation no free range can answer is the loud end.

## The object model in one breath

A heap word is self-describing by parity: an even word is a scalar
(stored shifted left one bit), an odd word is a reference — the handle
a block answers at allocation — and `0` is null. A `struct` is a fixed
field count, an `array` a counted word run, and slot 0 of every block
is the collector's header. The accessors below shift so caller field
indices start at 0; slot 0 stays the collector's.

The mutator discipline: a handle a collection must respect lives in a
root — `ref_new` — and a collection allocates nothing. A bare `var`
holding a handle is invisible to the collector; the block it names
dies at the next `collect`.

## The word tags

```emo
def is_ref(w Int64) Bool    // the odd bit — a slot's kind is the word's kind
```

## The arena and the allocator

```emo
def arena(words Int64) Void     // heap_new + the free list starts whole
def free_words() Int64          // the arena's not-yet-carved words
def addr_of(h Int64) Int64      // a handle's header offset
```

The free geometry is this package's own data: two maps keyed by a
range's start and by the word past its end. Allocation is first fit,
the take splitting the range it chooses; a release merges with
whichever neighbor the maps name.

## The struct accessors

```emo
def s_new(fields Int64) Int64             // take from the free list, carve
def s_set(b Int64, i Int64, v Int64) Void         // store a scalar
def s_get(b Int64, i Int64) Int64                 // load a scalar
def s_set_ref(b Int64, i Int64, h Int64) Void     // store a handle or null
def s_get_ref(b Int64, i Int64) Int64             // load a handle or null
```

The `_ref` pair refuses an even nonzero word — a scalar parked where a
reference belongs — and lets null through: `0` is the empty reference,
tested with `is_ref` or `!= 0`.

## The array accessors

```emo
def a_new(n Int64) Int64                  // allocate, answer the handle
def a_len(a Int64) Int64                  // the word count
def a_set(a Int64, i Int64, v Int64) Void         // store a scalar
def a_get(a Int64, i Int64) Int64                 // load a scalar
def a_set_ref(a Int64, i Int64, h Int64) Void     // store a handle or null
def a_get_ref(a Int64, i Int64) Int64             // load a handle or null
```

## Float arrays

```emo
def fa_new(n Int64) Int64                  // kind 3: every slot raw Float64 bits
def fa_set(a Int64, i Int64, v Float64) Void   // exact
def fa_get(a Int64, i Int64) Float64           // exact
```

A float's 64 bits cannot ride the parity scalar lane (the shift
round-trip only preserves words whose top bit repeats), so floats
have their own block kind: no parity on the slots, no references
inside, and the collector traces the block without walking its
words. Bytes ride the scalar lane:

```emo
def s_set_byte(b Int64, i Int64, v Byte) Void  // 0..255, range-checked on read
def s_get_byte(b Int64, i Int64) Byte
def a_set_byte(a Int64, i Int64, v Byte) Void
def a_get_byte(a Int64, i Int64) Byte
```

## Compaction

```emo
def compact() Int64          // mark, slide, rewrite references, answer the tail
def free_ranges() Int64      // ranges in the geometry — one after a compaction
```

The slide moves every live block to the arena's low end: every
reference — fields and roots — rewrites through the forwarding map,
and the free geometry resets to the one range behind it.
Fragmentation is a state the heap passes through, not one it keeps.

## The collector

```emo
def collect() Int64    // mark from the roots, sweep the rest, answer the words reclaimed
```

The sweep hands each unreached block's range back to the free
geometry, merged with its neighbors — the words a collection frees
are the words the next allocation carves from, as the demo's second
generation shows.

One full collection: the walk starts at the roots the interpreter run
answers, follows every odd word with the mark bit cutting cycles,
drains the worklist to the end of the graph, and frees everything
unmarked. It answers the number of physical words the sweep took back.
A root that reaches a freed block dies loudly at the door (E3050) —
the same stale-handle end every door gives.

## What raises

A caller's mistake raises: an even nonzero word stored or read as a
reference; an allocation no free range can answer (`gc: the arena has
no free range for the request`). A data mistake is the heap's own
error — the doors' E3050–E3052 and E3054–E3057 (a stale handle, the
wrong block kind, a word out of range, a negative or oversized
allocation, a carve over a bound block, a second arena) named in
[`docs/gc-heap.md`](../gc-heap.md).
