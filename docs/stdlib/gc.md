# The `gc` Package

The GC heap's collector: mark-sweep written in pure Emo over the
object-model doors the interpreter run admits ([`docs/gc-heap.md`](../gc-heap.md)
is the design note). One source serves every host that answers the same
doors; the interpreter run is the first, and on every build target the
whole family refuses at check time (E4032) — this package resolves
there and its doors refuse in the program, so the honest seat is the
run alone.

## Using the package

```emo
require "gc"
```

The standard library ships with the compiler, but its packages are
versioned like any other: `require "gc"` needs `"gc" = "0.1.0"` in the
manifest's `deps` block.

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

## The struct accessors

```emo
def s_new(fields Int64) Int64             // allocate, answer the handle
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

## The collector

```emo
def collect() Int64    // mark from the roots, sweep the rest, answer the words reclaimed
```

One full collection: the walk starts at the roots the interpreter run
answers, follows every odd word with the mark bit cutting cycles,
drains the worklist to the end of the graph, and frees everything
unmarked. It answers the number of physical words the sweep took back.
A root that reaches a freed block dies loudly at the door (E3050) —
the same stale-handle end every door gives.

## What raises

A caller's mistake raises: an even nonzero word stored or read as a
reference. A data mistake is the heap's own error — the doors'
E3050–E3055 (a stale handle, the wrong block kind, a slot out of
`0..n`, a double free, a negative or oversized allocation) named in
[`docs/gc-heap.md`](../gc-heap.md).
