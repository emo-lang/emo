# Arena reclamation at a region granularity

A spike off step 48 (EmoUI), answering one question before `ui-macos`
(T48.8) and `ui-gtk` (T48.9) are built:

> A UI re-runs `view()` on every event. Can the `c` target reclaim what
> a render allocates, at some region granularity — at what safety rule,
> and at what cost?

**Verdict: no — not as a standalone mechanism, and not as a T48.8
prerequisite.** The region is easy to build and does exactly what it
says: at the boundary a UI can safely name it reclaims 100% of the
arena. What it does not reclaim is the leak that costs the process —
and the shape of the mechanism makes that leak permanently
unrecoverable. The sound answer is refcounting the value families, and
that is its own milestone. Until then the `c` target's UI story is
demo-scale, and the honest move is to say so in the docs rather than to
ship a region.

The reasoning is under [Verdict](#verdict); the numbers it rests on are
below.

## Where this starts from

T23.5 landed the `c` target's reclamation model on 2026-10-11
(`CHECK.md:18`): reference counting over the identity-bearing cells —
instances, closures, `Box` — plus a frame-scoped autorelease pool. Every
value-semantic kind (strings, tuples, arrays, maps, lists, bytes, enums,
boxed scalars) is bump-arena resident and freed only at process exit
(`src/emo_codegen/c/emo_c_runtime.c:96`). `CHECK.md:37` recorded that as
open at the time of the spike (the cross-target invariants entry, item
2); the settled entry below is what came of it.

A UI is the first workload that turns that into a product problem rather
than a tidiness one, which is why the question was asked here.

## How the probes are built

Nothing under `src/` changes. Each probe is compiled against a runtime
that is the compiler's **own** emitted `emo_c_runtime.{c,h}` with
`runtime/probe_arena.{c,h}` appended:

```sh
cat .emo-build/emo_c_runtime.c runtime/probe_arena.c > build/<probe>/emo_c_runtime.c
```

The appended block only *adds* functions — `arena_bytes`, `arena_chunks`,
`arena_mark`, `arena_reset` — so a diff against the stock runtime shows
zero removed or modified lines, and the probes measure the shipped
runtime rather than a variant of it. (The compiler embeds the runtime
with a blank line added at each end; that is the only difference between
`.emo-build/emo_c_runtime.c` and `src/emo_codegen/c/emo_c_runtime.c`.)

Three things make this work, and each one costs time if you meet it
unprepared:

- **`emo build` must be allowed to fail.** It writes `.emo-build/main.c`
  and then invokes `cc`; the probes call `emo_arena_*`, which the stock
  runtime does not define, so the link fails *after* the emit. `build.sh`
  runs it with `|| true`, keeps the log as `stock-pass.log`, and refuses
  to continue if `main.c` is missing or older than the probe — which is
  what a cache short-circuit would look like.
- **A quoted include resolves against the including file's directory
  first.** `.emo-build/main.c` says `#include "emo_c_runtime.h"`, and
  would find `.emo-build`'s stock header before any `-I` path. `build.sh`
  therefore copies `main.c` next to the appended runtime, in `build/`,
  rather than overwriting anything in `.emo-build`.
- **The flags have to match.** The appended runtime is compiled with the
  same set `emo build` uses (`-O2 -ffp-contract=off -std=c11 -Wall
  -Wno-deprecated-declarations … -lm`), so the binary differs from a
  stock one in nothing but the added probes.

## The numbers

### P1 — what a render costs

`probe1_render_churn.emo` renders a tree in `spike/components/app.emo`'s
shape — `view()` rebuilds everything, children arrays grow by repeated
`.append`, every node carries a style `Map`, layout walks the tree
depth-first accumulating `Draw` commands into a second append-built
array — and doubles the node count each rung. 100 renders per rung.

**Without a region** (one event = one `view()` + one `paint()` + drop):

| nodes | bytes/render | ×prev | bytes/node | ids/render | leaked ids |
| ----: | -----------: | ----: | ---------: | ---------: | ---------: |
|    25 |       20,104 |     — |        804 |         41 |      4,100 |
|    50 |       42,728 | 2.12× |        855 |         82 |      8,200 |
|   100 |      129,848 | 3.03× |      1,298 |        205 |     20,500 |
|   200 |      339,208 | 2.61× |      1,696 |        410 |     41,000 |
|   400 |      998,528 | 2.94× |      2,496 |        820 |     82,000 |

Two things are worth separating.

**The arena cost is superlinear.** The `bytes/node` column is the direct
evidence: 804 bytes per node at 25 nodes, 2,496 at 400 — each additional
node costs more than the last. The `×prev` column says the same thing
from the other side: a doubling costs 2.1–3.0×, between linear and
quadratic, which is what a quadratic term riding on a large linear one
looks like. (The spike's pre-registered expectation was "roughly 4× per
doubling"; measured, it is 2.1–3.0×, and the `bytes/node` column is the
better evidence of the same fact.)

The quadratic term is the layout walk. `layout_step` appends one `Draw`
per leaf onto a growing array, and `emo_array_append` allocates a cell of
`8·(len+2)` bytes each time, so n appends cost Σ 8(j+2) ≈ **4n²** — about
645 KB of the 998 KB measured at n = 400. The children-building chains
contribute only linearly, because each panel is a fixed 20 leaves
(~92n bytes); the remainder is per-node allocation, since every `label()`
builds a style `Map` and a `Map` is several arena cells. These probes do
not separate the last two contributions, and the verdict does not turn on
the split.

At 400 nodes that is **~1 MB per render**. At 60 fps, ~60 MB/s with no
end.

**The identity leak is linear and permanent.** 820 identities per render
at 400 nodes — two per node, one `VLeaf` and one `Draw`. At 60 fps,
~49,000 objects per second, each a `calloc`'d cell that nothing can ever
free. This is the leak that ends the process: it is `malloc` memory with
a refcount that will never reach zero, because the arena array holding
the reference is itself never freed.

### P2 — what a region reclaims, exactly

`probe2_region_clean.emo` builds 4,000 `Leaf` instances into arena arrays
inside a region, reads them, and returns only an `Int64`:

```console
outside the region  bytes=0 chunks=0 ids=0
inside  the region  bytes=563200 chunks=9 ids=4000
reset reclaimed     bytes=563200
outside the region  bytes=0 chunks=0 ids=4000
arena  : 563200 bytes in, 0 left  -> reclaimed
rent   : 4000 identities in, 4000 left  -> leaked
```

The arena is returned to exactly where it started, chunks and all. Every
identity survives. That contrast is the spike's central result and it is
not a rounding error at either end: 100% reclaimed, 0% reclaimed.

### P3 — the boundary a UI reaches for first

`probe3_region_escape.emo` closes the region where a component library
would naturally propose to — around `view()`. It is unsound, and the
probe shows the failure rather than arguing it:

```console
region open : children=60 (read inside the region)
region closed: reclaimed 18200 bytes; the arena now holds 104
the root instance is malloc'd, so it survived the reset...
the native Float64 480.0 survived too - it is a C double, not a cell
...but the array the instance holds was arena memory. Reading it now:
runtime error: only strings, Bytes, tuples, arrays, and Lists have a length
exit=70
```

The instance cell is `malloc`'d, so the reset does not touch it; the
`Array[VNode]` it holds is arena memory, so the reset does. The tree's
shape survives and its contents do not — the stale pointer now reads a
poisoned cell. `emo_arena_reset` poisons reclaimed bytes with `0xAA`
before handing them back, which is not a valid cell kind, so the first
dereference a stale value reaches reports a corrupted cell instead of
whatever the allocator happened to leave there. Reading freed memory is
undefined behaviour either way; the poison is only what makes it fail
the same way on every run.

(The arena holds 104 bytes after the reset, not 0: something allocates
before the top-level mark is taken. The mark is where it is, not at the
start of time.)

### P1, second ladder — a region at a boundary that *is* sound

Then the region is moved to where it can be correct: around the whole
event, after the model is extracted and before the frame is discarded.
Only an `Int64` model and a native `Float64` cursor cross that boundary.

| nodes | bytes/render | chunks | ids/render | leaked ids |
| ----: | -----------: | -----: | ---------: | ---------: |
|    25 |            0 |      0 |         41 |      4,100 |
|    50 |            0 |      0 |         82 |      8,200 |
|   100 |            0 |      0 |        205 |     20,500 |
|   200 |            0 |      0 |        410 |     41,000 |
|   400 |            0 |      0 |        820 |     82,000 |

The arena column is flat at zero — the region does its job perfectly.
The identity column is **identical to the unregioned ladder, rung for
rung**. The region reclaims the bytes and none of the objects.

## Verdict

The spike set three criteria for itself before measuring.

**V1 — the cost is real and rising. Passes.** Both columns rise
monotonically; `bytes/node` climbs 804 → 2,496.

**V2 — the cost is large at a realistic node count, with a superlinear
term visible. Passes.** ~1 MB per render at 400 nodes, and the
`bytes/node` column is the superlinear term showing itself.

**V3 — some region boundary reclaims a stated fraction of the render's
bytes while reading nothing created inside it after the reset. Passes.**
The event-scoped region reclaims 100% and reads nothing it freed.

Three passes would mean "implement it". What decides the other way is a
fourth fact, which the criteria did not anticipate because it is not
about the region's boundary — it is about what the region is made of.

**The arena is not the whole heap, and every region straddles the
boundary.** Identities — instances, closures, `Box` — are `malloc`'d
individually, outside the arena, by design (`emo_idcell_new`,
`emo_c_runtime.c:121`). The arena's aggregates retain the identities they
store (`:390`, `:402`, `:407`, `:911`). So in a UI, every children array
inside a region holds references *out* of that region, into `malloc`
memory the reset knows nothing about. A raw region reset can free the
bytes; it cannot run the releases, because it does not know which words
in the reclaimed range are pointers, let alone which are identities.

Two consequences, and both are visible above:

- The reset reclaims arena bytes and 0% of the object leak — the objects
  are on the other side of the boundary.
- The references it dropped without releasing make those refcounts
  permanently unrecoverable. Without a region, the array pins its
  identities and a future fix could free both together. With one, the
  array's bytes are gone and the identities are stranded at a refcount
  nothing can decrement to zero.

The obvious repair is to log the retains the arena performed and replay
them in reverse at the reset. That log is the size of the problem it is
solving: `emo_array_append` re-retains **every** element on **every**
append (`emo_c_runtime.c:407-419`), so building a k-element array by k
appends performs ~k²/2 retains. The array-of-children shape a UI builds
is exactly that shape, so the log is quadratic per render — as large as
the data it exists to reclaim. (This one is read from the runtime source
rather than measured; the probe surface reports cell counts, not
refcount magnitudes.)

**So: do not implement region reclamation for T48.8.** It would buy
~60 MB/s of arena growth at 400 nodes and leave ~49,000 objects/s
allocated forever, while making that half of the leak harder to fix
later. Document the limit; schedule the real fix.

## What this rules out, and what is left

**Ruled out: per-fiber arenas.** Tempting because a finished fiber's
arena could be freed wholesale with no analysis at all. But `send`
passes pointers into the shared arena and retains them
(`emo_c_runtime.c:1988`), and `spawn` arguments likewise (`:1924`), so
per-fiber arenas require copy-on-send for every value family — the escape
analysis, relocated to the hot path of the concurrency model, which is
the same trade in a worse place. Not prototyped.

**Ruled out: making identities arena-resident again**, so that a region
contains everything it holds. That would make the raw reset sound, and it
would also remove the only reclamation the target has — the refcounting
T23.5 just landed. The region would then be the *only* mechanism, which
runs straight back into P3: the boundary a UI can name is not always a
boundary nothing escapes.

**What is left: extend refcounting to the value families** — the Swift
model this codebase already cites in `CHECK.md:18`. The case for it is
better than expected. The emitter is already written for it: it retains
every dynamic binding regardless of kind (`emo_c.ml:1851`) and releases
every dynamic binding at scope exit (`:423`), and the runtime's
`emo_retain`/`emo_release` are no-ops on the value families purely
because `emo_identity_kind` whitelists three kinds (`:143`). Flipping
that whitelist is most of the runtime change; no emitter change is needed
for bindings. Value families are immutable and built bottom-up, so no
cycles.

The case against is where the cost lands. The pool's contract is
*statement*-level, and arena semantics let expression-internal temporaries
— a nested `emo_str_concat`, a chained `.append` — leak for free.
Reclaiming those means widening `may_own` to every dynamic type and
auditing every constructor: reintroducing, at subexpression granularity,
the ownership analysis the pool exists to erase (`emo_c_runtime.c:1753`).
**That is a milestone, not a prerequisite.** It should be scheduled on
its own terms, and T48.8 and T48.9 should be built at demo scale with the
limit written down.

### A side finding for EmoUI

`Array` has no O(1) append. `emo_array_append` copies and re-retains the
whole array, and there is no builder beside it, so *any* dynamically
sized array costs O(k²) — and `List`, the O(1) deque, has no conversion
back to an indexable `Array`, so building children through it only moves
the quadratic step to the end. EmoUI's decided design is children as an
explicit `Array[Node]` (`docs/emo-ui.md`, decision 3) rebuilt per render,
which is exactly the shape this hits. Worth knowing before T48.1 writes
the portable core: either the core needs a different children
representation, or the language needs a cheap array builder.

## The landed `CHECK.md` entry

This section was written as a proposal; the entry **landed 2026-10-14**,
in expanded form, immediately after the cross-target-invariants entry —
it is the settled half of that entry's second item:

> - `c` target long-running memory: **settled (2026-10-14, the
>   arena-scope spike) — region reclamation is not viable as a standalone
>   mechanism; the value families need refcounting, and that is its own
>   milestone (`plan/step-49-value-reclamation.md`).** …

So the verdict's "schedule the real fix" has a name: **M16 —
Value-family reclamation (step 49)**, spec in
`plan/step-49-value-reclamation.md`. T48.8 and T48.9 are built at demo
scale with the limit documented rather than gated on it, and `Array`'s
missing O(1) append — the side finding below — is that step's T49.3.

The other half of `CHECK.md:37` — the `c` target's `raise` ending the
program rather than the process — is the sibling a GUI also makes
visible, and stays open.

## Reproducing

```sh
./build.sh && ./run.sh
```

`build.sh` compiles the three probes (expecting, and logging, the failed
first link); `run.sh` diffs each probe's output and exit code against
`expected/`. The output is deterministic run to run — no addresses are
printed — so a diff means the runtime changed, which is what the checked-in
outputs are for. Override the compiler with `EMO=/path/to/emo`.

`build/` is generated and ignored; `expected/` is checked in.
