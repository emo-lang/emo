# Step 91 — The GC heap's host ring closes: the riscv64 metal admits the doors

**Milestone:** M52 — The GC heap's riscv64 host · **Prereq:** step 90
(the ladder) · **Related:** `docs/gc-heap.md`, `docs/stdlib/gc.md`,
`examples/gc_demo/`, `examples/gc_metal/`, `CHECK.md` · **Status:**
done — the admission, the doors, the kinds, the acceptance and the
gold leg all landed.

## Why this step exists

The ladder's last rung was the track's own customer. The `c` host
proved the collector could manage real memory; an EmoOS user program
still ran on an image whose heap was nobody's to collect — the
freestanding target `runtime-and-freestanding.md` named when it listed
"an allocator, a garbage collector" as the runtime's own work. Step 91
puts the twenty-four doors on the riscv64 image: the same Emo
allocator and collector compiled into the program, the region the
image grants, and the demo's gold answering three hosts byte for
byte. The raise gap this host carried since the hash twin closes on
the same stroke, and the tagged value model grows the two kinds the
package's world needs on this host.

## The design

- **The region is the image's own `.bss`.** `emo_gc_region` reserves
  a one-mebibyte arena, the binding table (8192 entries of 32 bytes:
  offset, generation, kind, size), a 4096-cell root table, and the
  slide's staging — NOBITS, every profile. A request the region
  cannot answer is the loud end, the interpreter's texts on the wire.
- **The doors are runtime helpers compiled beside the program.** No
  host runtime to borrow: each door lowers to `call emo_gc_*`, the
  checked accessors validating kind, generation, and bounds against
  the binding table the way the interpreter's evaluator does. The
  thin helpers (call, then tail) push and pop `ra` — the first
  round's biggest wall was a stale return address there re-entering a
  helper until the arena walked dry.
- **The kinds join the tagged value model.** `Ref` is kind 12, the
  metal's `Map` kind 13 — both identity kinds under the runtime's own
  reference counting; a release reaching zero unlinks the root table
  and returns the block. `raise` closes its last gap: `Raise` lowers
  to `emo_raise`, rendering the exception value the `c` host's way (a
  bare message passes through, an `Exception` instance's message
  field comes out of field 0), an uncaught raise the loud end's print
  and exit. Module-level `var`s lower to cells in the image's static
  memory, the prologue initializing them before the body — the `gc`
  package's own `by_start`/`by_end` ride the image like any value.
- **The admission is the raw-memory family's own turn.**
  `base_env "riscv64"` takes the `gc_heap_bindings` beside the
  raw-memory ones; the `gc` package's manifest grows `riscv64`, the
  locks re-pin, and the E4032 refusal's text names the three hosts
  that admit. The kernel profile keeps its own rule: the doors answer
  bare, the package's `require` refuses (E5014).
- **The acceptance stays the demo.** `examples/gc_metal` is the
  demo's own source byte for byte (the parity case pins it), and the
  demo's 24 gold lines answer byte-for-byte on the interpreter, the
  `c` host and the metal.

## The debug round's six walls

The first green probe was not the whole story — the full demo found
six walls, each fixed in the emitter, each a class:

1. **The prologue double-pooled the module vars' births.** `emit_expr`'s
   arms pool their own births; the prologue pooled the same word
   again, and the first drain released a map the cell still held —
   the full demo's bump exhaustion, the found-not-fixed the round
   opened with.
2. **The Map's +8 field shift was half-taken.** The identity
   payload's word 0 is the tag, so count/cap/entries/mask/buckets
   live at +16 onward; `find`'s count read the tag (26), the append
   path read the mask out of the entries pointer, and
   `emo_map_new_empty` trusted an ident_new zeroing that never
   happened — freelist garbage as field values.
3. **The slide's pairs arrived as a raw builder's array.** A raw
   builder's `to_array` answers bare payloads under a −1 header; the
   door read them as boxed words, and the machine's answer was a
   silent OpenSBI reset loop — the `-d exec` trace's
   `cpu_io_recompile` naming the MMIO read. The door now dispatches
   on the array's own header.
4. **The forwarding map's keys split shapes.** A raw array's element
   read answers the bare word; the emitter's unbox hands the same
   value boxed — the mixed compare now matches one Int64 across both
   shapes, checking bit 31 because a bare 0 or 1 wears kind bits 0.
5. **The grow's rehash copied `next` and nothing else.** The second
   grow lost the first eight keys and values; the fingerprint was the
   map answering `has` for exactly the entries stored past the first
   cap.
6. **The allocator rounded sizes but never the cursor.** A
   phase-shifted arena stranded a block's base mid-line, and the
   tagged read's own mask cut the low five bits off — the object the
   read found was sixteen bytes early. The cursor rounds to the
   32-byte line first, the const region's own rule retold.

## The acceptance

- `dune runtest` exit 0, `@bootstrap` green, `@fmt` green.
- The metal leg rides `@emo_os` (`gc_metal`): the parity case pinning
  the metal demo's source to the demo's own, the kernel leg three
  boots against `expected.txt` byte for byte. `dune runtest` stays
  free of the QEMU legs.
- The demo's gold on the metal, three boots stable, both through the
  EmoOS kernel (the checksum feed, the gate's writes) and through
  QEMU's own boot of the user image (the debug vehicle, `-m 256M`
  keeping the DTB clear of the `.emo_ucall` window).

## What it leaves

The fold-back `hash` waits for — its engine returning to `crypto`,
now that the raise gap this step closed makes the machine take
`crypto` again — is a decision, not a wall, and stays with the
hash-twin record. The region's budget (the mebibyte arena, the 8192
bindings, the 4096 roots) is the image's to grow when a customer
outgrows it; the loud ends name the ceiling, no silent wrap.
