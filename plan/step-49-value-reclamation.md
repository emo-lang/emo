# Step 49 — Value-family reclamation

**Milestone:** M16 — Value-family reclamation · **Related:**
`spike/arena-scope` (the feasibility spike and every number below),
`CHECK.md` (the settled decision), `docs/TASKS.md` M15 (the consumer
that forced the question) · **Status:** landed 2026-10-17 — T49.1
through T49.5 complete on `feat/m16-value-family-reclamation`; the
render loop holds a flat working set and the T49.4 gate pins it.

## Why this step exists

The `c` target's reclamation model landed 2026-10-11 (T23.5): reference
counting over the identity-bearing cells — instances, closures, `Box` —
plus a frame-scoped autorelease pool. Every value-semantic kind
(strings, tuples, arrays, maps, lists, bytes, enums, boxed scalars) is
bump-arena resident and freed only at process exit
(`src/emo_codegen/c/emo_c_runtime.c:96`).

That is a defensible trade for a short-lived program and the wrong one
for a long-running one. EmoUI is the first long-running workload the
language has: a UI re-runs `view()` on every event, and the tree it
builds is made of exactly the unreclaimed kinds — an `Array[Node]` of
instances, style maps, and strings, discarded and rebuilt per frame.

The 2026-10-14 arena-scope spike asked whether a region could close that
gap cheaply, measured it, and answered no: the region reclaims the arena
bytes and none of the leak that grows the process, and the shape of the
mechanism makes that half permanently unrecoverable. Its verdict was to
schedule the real fix on its own terms rather than ship a region first.
This step is that scheduling.

## Not a prerequisite for step 48

Kept here because it is the kind of decision that gets quietly reversed.
**T48.8 and T48.9 are built at demo scale with the limit documented**,
and this step is scheduled on its own terms. Gating the native backends
on this would trade a shippable macOS/GTK backend for a memory property
the demo does not need — and the spike's own point is that the region
shortcut would have made the eventual fix harder, not that the backends
had to wait for it.

## What the spike established

Four facts, all measured in `spike/arena-scope/`; the README there
carries the tables and the reproduction.

1. **The cost is real and rises superlinearly.** The render ladder
   allocates 20 KB per render at 25 nodes and 998 KB at 400, with
   `bytes/node` climbing 804 → 2,496. At 60 fps that is ~60 MB/s with no
   end.
2. **The identity leak is separate and unbounded.** 820 identities per
   render at 400 nodes (~49,000/s), each a `calloc`'d cell whose
   refcount can never reach zero, because the arena array holding the
   reference is itself never freed.
3. **A region reclaims 100% of the bytes and 0% of the identities.**
   Identities are `malloc`'d outside the arena; the arena's aggregates
   retain them across the region's boundary. A raw reset frees the bytes
   and cannot run the releases — it does not know which words in the
   reclaimed range are pointers, let alone identities — so the
   references it drops are stranded permanently. The log-and-replay
   repair is O(k²) per render, since `emo_array_append` copies and
   re-retains every element.
4. **The boundary a UI reaches for first is unsound**, demonstrated as a
   corrupt read rather than argued: a region closed around `view()`
   leaves the root instance alive (it is `malloc`'d) holding an array
   that no longer exists.

Two mechanisms the spike ruled out, so they are not re-proposed here:
**per-fiber arenas** (`send` and `spawn` pass arena pointers across and
retain them, so a per-fiber arena demands copy-on-send for every value
family), and **making identities arena-resident again** (that removes
the refcounting T23.5 landed and leaves the region as the only
mechanism, straight back into fact 4).

## Goal

A long-running `c`-target program holds a **flat working set**: the bytes
a render allocates and the objects it creates are both released as it
drops them, so identity liveness and arena bytes stop rising per event
and track the live tree instead. The reference workload is the spike's
render loop; the property is measured, not asserted.

## Scope

### In

- **The runtime change:** extend the identity discipline —
  `emo_identity_kind`, `emo_retain`/`emo_release`, and the constructors
  that store into aggregates — from the three identity kinds to the
  value families, so a value cell's refcount reaches zero and an
  aggregate releases what it holds.
- **The granularity question:** the autorelease pool's contract is
  *statement*-level, and arena semantics let expression-internal
  temporaries leak for free (a nested `emo_str_concat`, a chained
  `.append`). Reclaiming those means widening `may_own` to every dynamic
  type and auditing every constructor (`emo_c_runtime.c:1753`). This is
  where the cost lands, and the step's hardest half.
- **The array-growth shape:** an O(1) append, or a builder beside
  `Array`. Building a k-element array by k appends costs Σ 8(j+2) bytes
  and ~k²/2 retains, and the EmoUI children array is exactly that shape.
- **The measurement:** the spike's probes become a checked-in gate on
  the `c` target, so the property has a before/after number rather than
  a claim.
- **Docs:** the `CHECK.md` item stops being a limit and becomes a
  landed decision; `docs/emo-ui.md`'s ask 4 is answered; step 48's
  demo-scale notes are retired.

### Out

- **A tracing GC.** The reclamation model is settled — no tracing GC
  (`CHECK.md`); this step is the refcount half of it completed.
- **Region reclamation, and per-fiber arenas.** Ruled out by the spike,
  recorded as ruled out in `CHECK.md`.
- **The other targets.** The interpreter and `ocaml`/`typescript`/
  `wasm`/`beam` each carry their own runtime; this property is the `c`
  target's. Their goldens must stay byte-identical, which is the
  constraint this step works under rather than a thing it changes.
- **Shrinking the arena** (returning chunks to the OS). Peak footprint
  is a different question from growth; it is unmeasured and belongs with
  its own evidence, not bundled here.

## Tasks

- [x] **T49.1** — The runtime: extend the identity discipline to the
      value families, so a value cell can reach refcount zero and an
      aggregate releases what it stores. The emitter already retains
      every dynamic binding on entry (`emo_c.ml:1851`) and releases it
      at scope exit (`:423`), so this starts as a runtime-side change;
      where the emitter must change is what T49.2 finds. Includes the
      audit that no value-family construction can form a cycle.
- [x] **T49.2** — The granularity: decide what the pool owns now that
      every dynamic type may own memory, and implement it —
      expression-internal temporaries are the hard half, `may_own` and
      the constructor audit that follows.
- [x] **T49.3** — The array shape: an O(1) append or a builder, so
      growing a k-element array is not quadratic in bytes and retains.
      The spike's P1 ladder is the before/after measurement; T48.1's
      children representation depends on the answer. **Settled
      2026-10-15 — a builder, as a new language-level type
      (`ArrayBuilder`) rather than an `Array` representation change**
      (open item 2 below, now closed). This landed ahead of steps T49.1
      and T49.2 and does not depend on either: it removes the per-element
      `Array.append` copy from the language's side, so the acceptance
      criterion "array growth is flat in the element count" holds for a
      program that builds with it, while the arena's own accounting is
      still T49.1's. The builder's growth follows the `Map` doubling and
      its retired buffers stay arena-resident, so the leak this step
      exists to close is unchanged by it.
- [x] **T49.4** — The gate: the render loop and the region probes as a
      checked-in test that fails today and passes after, on the `c`
      target, with every existing golden byte-identical and `dune test`
      green.
- [x] **T49.5** — Docs: `CHECK.md`, `docs/emo-ui.md` and its zh-CN
      mirror, and step 48's demo-scale notes updated to point here.

## Acceptance

- Arena bytes and identity liveness are flat across the spike's render
  ladder where both rise today, and track the live tree rather than the
  total ever allocated.
- Every existing golden on every target is byte-identical; the
  interpreter and the non-`c` targets are untouched.
- Array growth is flat in the element count rather than quadratic, with
  the retain count that goes with it.
- No source change outside the `c` target's runtime and the emitter's
  ownership vocabulary.

## Open design items

1. **The pool's contract.** Statement-level was enough while only
   identities could own memory. Widening `may_own` to every dynamic type
   reintroduces ownership analysis at subexpression granularity — the
   thing the pool exists to erase. A wider pool, a smarter emitter, and
   a different aggregate representation are all on the table and have
   not been weighed against each other in writing.
2. **Whether the append fix is a runtime or a language change.**
   **Settled 2026-10-15 — a surface change: a new `ArrayBuilder` type**
   (T49.3). An O(1) append inside the existing `Array` would have been a
   representation change, and the surveyed spellings (`Array.concat`,
   a type-directed `append`, a conversion back from `List`) each left the
   nested-array hole or the copy in place. EmoUI's children shape was the
   first consumer and did not decide it alone: the argument that settled it
   is that the language had no sub-quadratic way to build an array of
   unknown length at all, which is a gap independent of any one caller.
3. **Peak, not just growth.** See the Scope note: unmeasured, and not
   this step's acceptance criterion.

## Evidence

`spike/arena-scope/` — P1 (the render ladder: what a render costs), P2
(a region reclaims 100% of the bytes and 0% of the identities), P3 (the
first boundary a UI proposes is unsound). `./build.sh && ./run.sh`
reproduces every number from a clean tree.
