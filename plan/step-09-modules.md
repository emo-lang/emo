# Step 09 — Structural Module System

**Milestone:** M2 · **Prereq:** steps 01–08 · **Status:** not started

## Goal

The README's module system: the directory tree is the module tree, references
are qualified paths (plain member access — already parses as such), `internal/`
is subtree-private, and the reference graph is explicit for cycle detection
and incremental builds. After this step, multi-file projects work end to end.

## Scope

### In

- **Root discovery** — the project root is the nearest ancestor directory
  containing the package manifest (step 10 introduces the manifest itself;
  until then the root is the entry file's directory, a transitional rule
  replaced in step 10 — documented in both steps).
- **Module loading** — `shop/order.emo` is module `shop.order`:
  - A directory or file referenced as a member path evaluates to a `Module`
    value — a namespace whose members load lazily on first access.
  - `shop.order.total(cart)` is ordinary member access + call; no new syntax,
    no import statement, exactly the README's "the path is the module".
  - `const order = shop.order` aliasing works because modules are values.
- **`internal/` enforcement** — a module whose path contains an `internal`
  segment may only be referenced from modules sharing the parent of that
  segment (`shop/internal/discounts.emo` usable from `shop/*`, rejected
  elsewhere). Checked at compile time against the use-site's module path —
  a checker pass over the reference graph, erroring with both paths named.
- **Reference graph** — collect qualified-path references per module at check
  time:
  - **Cycle detection**: import cycles are compile errors, reported with the
    cycle's path chain.
  - Missing module (path resolves to no file/directory) is an error, not a
    silent nil.
  - Load order: topological, driven by the graph — the entry module's
    dependencies load before first evaluation.
- **Caching / incremental** — content-hash keyed: unchanged modules skip
  re-lex/parse/check within a `run`. On-disk incremental caching (across
  processes) is optional and may land later; correctness first.
- **Evaluation order semantics** — each module's top-level items evaluate
  once, on first load, in file order; this is the whole story (no separate
  link step, no registration).

### Out

- Packages, `require`, registry, manifest (step 10).
- Compiled artifact caching (step 13).
- Any visibility keywords — they do not exist structurally.

## Tasks

- [ ] Module path resolution (file ↔ module name, collisions are errors:
      `order.emo` twice under one path prefix).
- [ ] Lazy `Module` values wired into the evaluator's member access.
- [ ] Load-order orchestration; load-once semantics.
- [ ] Reference-graph extraction during checking.
- [ ] `internal/` subtree-privacy check.
- [ ] Cycle detection with chain reporting.
- [ ] In-process caching keyed by content hash.
- [ ] Multi-file test project under `examples/` mirroring the README's
      `shop/` tree.

## Acceptance

The README's shop tree works verbatim:

```
shop/
  order.emo
  pricing.emo
  internal/
    discounts.emo
  checkout.emo
```

```emo
# checkout.emo
const order = shop.order

def checkout(cart Cart) Decimal {
  const total = order.total(cart)
  return total
}
```

- `emo run shop/checkout.emo` loads the graph, evaluates once per module,
  produces correct output.
- Referencing `shop.internal.discounts` from `other/thing.emo` errors naming
  both modules; from `shop/pricing.emo` it succeeds.
- A two-module import cycle is rejected with the full chain.
- `dune test` green (multi-file fixtures).

## Open design items

- Transitional root rule (entry file's directory) must be swapped for
  manifest-based roots in step 10 — do not let it fossilize.
