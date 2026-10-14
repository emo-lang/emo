# Per-package dependency isolation — implemented

Written 2026-10-12, on `feat/plot`. A temporary working note, not decided
design. It recorded a gap found while landing the package short-name prefix
(the fix that made `plot.mark` real) and the two directions to choose
between. English-only on purpose, like `temp-visual-check.md`.

**Decision (2026-10-12): Option A — implemented.** Per-package dependency
scoping and transitive dependency resolution are in the working tree.
Own-subtree-first precedence is retained, so the pinned shadowing tests
still hold. The earlier "Option B" note is superseded.

## What landed

1. **Transitive resolution.** `Emo_pkg.Registry.index_closure` indexes the
   roots and then each indexed package's own `pv_deps`, iterating to a
   fixpoint; `Emo_project.resolve_deps` uses it. A package's own `deps` are
   now in the resolver index, so `acme/y` pinning `acme/z` resolves.

2. **Per-package visibility.** `project` (and `Emo_check.ctx`) carry
   `package_deps : (string list * string list) list` — a package prefix →
   the scoped names it declares in its manifest, with the root project at
   `[]`. A reference from package `P` resolves only within:

   - `P`'s own subtree (own-subtree-first, unchanged), or
   - a package short name `P` declares in its deps.

   The root project's entry carries its declared names plus the standard-
   library requires that resolve implicitly (2026-10-14, CHECK.md): an
   unscoped `require` is a visible dependency of `[]` without a manifest
   entry.

   A head that names a module somewhere but is out of scope reports
   **E5008** (`the package `x` does not declare `q` in its deps`; the root
   is labelled `the project`). The checker normalizes the *longest module
   prefix* of a dotted path (`module_prefix_of`) so calls and member reads
   agree, and the root cannot reach a transitive dependency it never
   declared.

3. **`require`/manifest pairing is per owning package.** The pairing check
   used to compare every module's `require` against the *project* manifest;
   a package's internal `require` now answers to that package's own deps
   block.

## Why E5008 and own-subtree-first coexist

Own-subtree-first means `q.qq()` inside a package that has its own `q`
submodule resolves to `shadow.q` and never consults the visibility rule —
so the shadowing fixtures (own submodule wins, `100`) still hold. E5008
fires only when the relative form is not a module and the absolute head is
a module the package did not declare.

## Tests

`test/emo_project/emo_project_test.ml`, `registry_dir` fixtures:

- `nested_tools` — own-subtree reference (`internal.helper`) and
  `nested_tools.mark`-style addressing.
- `shadow` + `q` — own-subtree-first precedence; interpreter (`100`) and IR
  (`shadow__q__qq`) agree.
- `leaf_tools` / `trans_tools` — a declared transitive dep resolves, and
  `trans_tools`' own `require` pairs with `trans_tools`' manifest.
- Root referencing `leaf_tools` without declaring it — E5008.
- `rogue_tools` referencing `leaf_tools` it never declared — E5008.

`dune test` green (91 in the project suite).

## Fixed along the way (earlier, already committed)

The first cut of relative resolution disagreed across stages: the checker
and IR were own-subtree-first, but the evaluator only made `current_package`
live during a module's top-level load, so a def body ran absolute-first
(`emo run` printed `9`, `emo build --target c` printed `100`). The loader
now pre-binds the package root's direct submodule names into each module's
environment (a def body's closure captures it), the dynamic
`current_package` hack is gone, and the IR's relative test matches on
**prefix**.

## Notes

- The visibility rule is enforced in the **checker**; `emo run` and
  `emo build` both check, so the runtime never sees an out-of-scope
  reference. The IR and evaluator still resolve own-subtree-first and take
  declared deps absolutely, matching the checker.
- `Registry.index_closure` re-indexes per discovery batch; fine at current
  scale, and the registry can enumerate versions per name so the loop is
  bounded by the reachable package set.
