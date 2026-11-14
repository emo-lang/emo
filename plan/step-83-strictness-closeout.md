# Step 83 — The strictness closeout

**Milestone:** M44 — Strictness first, finished · **Prereq:** none ·
**Related:** `CHECK.md`'s four open checker gaps (the T45.2 shadow entry,
the T45.3 chained-builtin entry, the atomic goldens' `Bytes.new` item,
the `:chain` entry's mixed-payload note), `src/emo_check/emo_check.ml`,
`src/emo_eval/emo_eval.ml` · **Status:** planned.

## Why this step exists

Four checker gaps are on the books as found-not-fixed, and they share
one shape: the compiler stays silent where the strictness rule says it
should speak. Each was found by real code tripping over it (the DEFLATE
packer's shadowed `r`, `Buffer`'s `to_bytes` emptying every SVG, the
atomic goldens' `Bytes.new`, the `:chain` track's mixed-payload probe),
each was dodged or recorded rather than fixed, and each is exactly the
class of human mistake "strictness first" exists to surface — a silent
rebind, a silently drained temporary, a silently `Unknown` payload, a
silently contradictory ladder. One step closes all four.

## Goal

Every program one of these four shapes describes is refused at check
time with the construct and the span named, on every target (the checks
are target-free); the existing corpus sweeps clean under the new rules;
and the chained-builtin form — the one gap that is a runtime bug and
not a check — answers the receiver's real value on the interpreter and
every compiled target, pinned by a golden.

## Decisions settled here

- **A block may not shadow an outer binding (T45.2's fork, side (a)).**
  The entry names the two answers: refuse the shadow, or make block
  scoping the rule and the interpreter's flat rebind the bug. The
  strictness rule decides: a `const` (or `var`) inside a block sharing
  a name with an outer binding is a compile error naming both spans —
  a silent rebind of a `var` by a same-named `const` is precisely the
  mistake class the checker exists for, and the interpreter's flat
  rebind is the odd target out (the other five already split three
  ways). The package-side style rule ("declare once, assign in
  branches") stays idiomatic — it compiles.
- **The chained-builtin temporary lives across the chained call
  (T45.3).** `b.to_bytes().length()` answers 0 because the
  interpreter's temporary drains before the chained builtin reads its
  receiver; a builtin on a builtin-method or interface-method result
  has answered correctly in the goldens for steps, so the fix is the
  interpreter's own lifetime (the twin of the `emit_const_thunk` drain
  T48.2 removed on `c`), then a probe of all five compiled targets —
  the entry's "untested" clause closed — with the chained forms pinned
  in `examples/builtin_names`, where the instance-first dispatch
  already lives.
- **`Bytes.new` types as `Bytes`, and the Bytes rules go
  Unknown-tolerant first (the atomic goldens' item 4, in the entry's
  own order).** Typing `Bytes.new(n)` as `Bytes` without the tolerance
  pass would start failing every registry `Bytes.new` receiver indexed
  by a field or a dynamic value (E4004 on `Unknown`); the tolerance
  pass lands first, then the constructor rule, then
  `Atomic.new(Bytes.new(4))` checks clean and joins the constructor
  golden.
- **A ladder's arms on one enum member agree on the payload (the
  `:chain` track's gap).** The checker's rule: where the same enum
  member appears in more than one arm of a ladder (`case`, `receive`,
  or `:chain`'s rewrite) with tuple payloads, the payload types must
  agree across the arms — and with the scrutinee's type when the
  scrutinee is typed. `(R.ok, 1)` beside `(R.ok, "x")` is a
  contradiction about the scrutinee's own type, not two honest arms;
  the arms agreeing where the scrutinee is silent is the check that
  closes it. The rule is enum-ladder-wide, not `R`-specific.

## Tasks

- **T83.1** — The shadow refusal: the checker refuses a block binding
  whose name matches an outer binding, both spans named; the
  interpreter's flat rebind retires with the refusal (the six targets
  cannot disagree about a program that no longer checks). Sweep the
  corpus (the DEFLATE packer already compiles the idiomatic way).
- **T83.2** — The chained-builtin lifetime: the interpreter keeps the
  temporary across the chained builtin's read; probe the five compiled
  targets for the same split; pin the chained forms in
  `examples/builtin_names`.
- **T83.3** — `Bytes` typing: the Unknown-tolerant pass over the Bytes
  method rules, then the `Bytes.new` constructor rule;
  `Atomic.new(Bytes.new(4))` checks clean and joins the constructor
  golden; the registry's `Bytes.new` receivers resolve as before.
- **T83.4** — The ladder-payload rule: arms on one enum member agree on
  tuple payload types (and with a typed scrutinee); the refusal names
  the member and both payload types; `:chain`'s rewrite inherits the
  check through its nested `case`.
- **T83.5** — The sweep and the docs: full-corpus `emo check` under the
  new rules (the four refusals' own negative goldens join
  `test/emo_cli`), the checker sections of `docs/intro/type-system.md`
  and `docs/intro/syntax.md` (+ zh-CN mirrors) stating the four rules.

## Acceptance

All four shapes refuse at check time with the construct and span named;
`b.to_bytes().length()` answers the real count on the interpreter and
every compiled target; `Atomic.new(Bytes.new(4))` checks clean; the
corpus sweeps clean; `dune runtest` green with the new goldens (the
auto-test rule's requested-run clause applies).
