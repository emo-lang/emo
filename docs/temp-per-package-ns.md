# Per-package dependency isolation — open decision

Written 2026-10-12, on `feat/plot`. A temporary working note, not decided
design. It records a gap found while landing the package short-name prefix
(the fix that made `plot.mark` real) and the two directions to choose
between. It is English-only on purpose, like `temp-visual-check.md`.

**Decision (2026-10-12): Option B.** Own-subtree-first stays, pinned by
tests; per-package isolation and transitive resolution are recorded here as
open defects to pick up later.

## What is landed

The compiler now mounts a package's tree under its short name
(`json.emo` → `json`, `internal/float.emo` → `json.internal.float`,
`mark.emo` → `plot.mark`), and a package's own references are written
against its package root (`internal.float` in `json.emo` means
`json.internal.float`). Uncommitted on top of that landing is the
consistency fix below.

## The gap: there is no per-package dependency isolation

All packages share **one program-wide module namespace**. `require` gates
only the strict `require`/manifest pairing check; a *reference* resolves
against the global module table (`module_paths`), with no notion of what a
given package is allowed to see.

Observed (temporary fixture registry): package `p` declares `deps {}` but
its body calls `q.qq()`; an app depending on both `p` and `q` runs it and
prints `9`. `p` sees `q` only because `q` is the app's other direct
dependency and is registered globally — nothing declared it for `p`.

The shadowing this exposes is a symptom, not the cause: because there is
one namespace, a package `p` that has its own submodule `q` while a
dependency short name `q` also exists gives `q.x` two readings. Any
precedence rule (own-subtree-first or dependency-first) silently picks one.
With real isolation the ambiguity either cannot arise or becomes a
diagnosable error.

### Current precedence (undecided, currently pinned by behavior only)

`relativize` is **own-subtree-first**: inside package `P`, `a.b` first
resolves to `P.a.b` when that is a known module, else to the absolute
`a.b`. The checker, the IR, and the evaluator now agree on this (see
"Fixed" below), but it is a heuristic standing in for isolation.

## Prerequisite defect: transitive dependencies do not resolve

`Emo_project.resolve_deps` builds the resolver index from the app's
**direct** deps only:

```ocaml
Emo_pkg.Registry.index reg (List.map fst manifest.deps)
```

`Registry.index` indexes exactly the names it is given, and `Resolve.solve`
walks the closure from that index. So a package's own `deps` are never
indexed: an app depending on `acme/y` (which pins `acme/z`) fails with
`acme/z: no such version`. This is latent today because the standard
library packages mostly declare `deps {}` and every test app also declares
each transitive package directly. Per-package isolation cannot be enforced
meaningfully until this works.

Fix: index the **transitive closure** — start from the roots, index each
version's `pv_deps` names, and iterate to a fixpoint (the registry can
enumerate versions per name, so this is a bounded loop over discovered
names).

## Option A — implement per-package dependency scoping

Inside package `P`, a qualified reference `a.b.c` resolves only within:

- `P`'s own subtree (`P.a.b...`), or
- a package short name `a` that `P`'s manifest declares in `deps`.

Anything else is a compile error (new code, e.g. `E5008 "module `x` is not
in package `P`'s dependency set"`). A name that is both `P`'s own submodule
and a declared dep short name is a conflict — report it rather than pick.

This removes the leak and turns the shadowing into a diagnostic.

Needs:
1. Fix transitive resolution (above), or `deps(P)` names are not even
   registered.
2. Thread a per-package visibility map, not just the prefix list:
   `project` gains `package_deps : (string list * string list) list`
   (package prefix → its declared dep short names). The root project is the
   implicit package with prefix `[]` and the app manifest's deps.
3. Resolution (checker `relativize`/`module_prefix_known`, IR
   `relativize_in`, evaluator's module env bindings) consults the visible
   set instead of the global table; an out-of-set head is rejected.
4. Tests: `p` referencing an undeclared `q` errors; nested package deps
   resolve; the `P.q` vs dep `q` conflict errors; the interpreter/compiled
   equivalence still holds.

Scope: `emo_pkg` (index closure), `emo_project`, `emo_check`, `emo_ir`,
`emo_eval`, plus fixtures/tests. Largest of the two options.

## Option B — pin the current rule and record the gap, defer (chosen)

Keep own-subtree-first, and:
1. An interpreter-vs-IR equivalence test for the shadowing case pins the
   consistency fix: `run_entry` returns `100`, and the IR's `shadow__pick`
   body calls `shadow__q__qq`. Both are in `test/emo_project`.
2. An own-subtree-first precedence test: the same fixture's interpreter
   output is `100`, not the dependency's `9`.
3. This file records the two open defects: no per-package isolation, and
   transitive deps do not resolve.

Smallest change; the language keeps a documented global namespace where any
package can name any registered module.

## Fixed along the way (already in the working tree)

The first cut of relative resolution disagreed across stages: the checker
and IR were own-subtree-first, but the evaluator only made `current_package`
live during a module's top-level load, so a def body ran absolute-first
(`emo run` printed `9`, `emo build --target c` printed `100`). Now the
loader pre-binds the package root's direct submodule names into each
module's environment (a def body's closure captures it), the dynamic
`current_package` hack is gone, and the IR's relative test matches on
**prefix** (a directory module like `internal` is not a file module). The
three stages agree; `dune test` is green (86 tests).

## Recommendation

Option A — it is the semantics the design implies ("packages slot into the
module system", a package name is a module-path prefix). It does require
fixing transitive resolution first, and it is the larger change.
