# Step 08 — Gradual Type Checker

**Milestone:** M2 · **Prereq:** steps 01–07 · **Status:** not started

## Goal

The built-in type-checking pass from the README: annotations optional except
on signatures, unannotated code inferred with **only certain errors reported**,
annotated code checked strictly, typing structural and flow-sensitive. Runs
before evaluation (`emo run` refuses to run a program with certain errors);
`emo check` becomes functional.

## Scope

### In

- **Type language** (in `emo_check`) — `Unknown` (dynamic), the primitives
  (`Int`, `Float`, `Bool`, `Char`, `String`), `ClassType(name, fields)`,
  `InterfaceType(name, methods)`, `EnumType(name)`, `ArrayType(elem)`,
  `TupleType(elems)`, `BoxType(elem)`, `FuncType(params, ret)` — the
  tuple annotation mirrors the literal, `(Int, String)`. Parameterized
  spellings exist as annotation vocabulary only (`Array[User]`,
  `Box[Int]`) — no generics machinery, per the README; a
  `Box[T]`-annotated receiver gets its method checks from the parameter:
  `read` yields `T`, `replace` takes `T`.
- **Signature enforcement** (parser already rejects missing annotations;
  the checker verifies the consequences):
  - `def` bodies checked against their declared signatures — `return`
    expressions must conform, parameter uses carry the declared types.
  - `init` exempt: its return type is the class.
  - Arrow blocks: parameters are annotated (parse-enforced), return types
    are **inferred**; inference failure on an arrow block used in an
    annotated position is an error asking for an explicit annotation.
- **Local inference** — `const` / `var` bindings get their type from the
  initializer; assignments to a `var` must conform; rebinding type drift is
  an error when the binding is annotated, tolerated as `Unknown`-widening
  when it is not (a certain-error-only report: never a false positive).
- **Flow-sensitive narrowing** — `if x.is(T) { ... }` narrows `x` to `T`
    within the branch; the else branch keeps the pre-test type merged; on
  merge after the `if`, take the union-safe result (back to `Unknown` unless
  both branches agree). Narrowing applies uniformly to classes, interfaces
  (structural conformance check of the receiver's class), and enums.
- **Structural interface conformance** — a value conforms to an interface
  when its (known) class provides every method with compatible signatures;
  no declaration, exactly the README rule. Unknown receivers stay unchecked.
- **Certain-errors-only discipline** — with `Unknown` inputs the checker
  stays silent rather than guessing; every reported error must be provable.
  This is the contract that makes gradual typing trustworthy, and it gets a
  dedicated test category: programs with `Unknown` regions must produce
  **zero** false positives.
- **`var` escape rule** (README, Syntax) — capturing a `var` binding in an
  arrow block that can outlive its block is a compile error; a
  straightforward approximation (any arrow block nested deeper than the
  `var`'s block referencing it) is acceptable if conservative — the README
  demands the error exist, not a borrow checker.
- **Call-site checks** against known callees: arity, unknown named argument,
  positional-after-named misuse, return-type usage.
- **`case` checking & exhaustiveness** — pattern types are checked against
  the scrutinee's type when decidable (literal kinds, qualified enum
  members belonging to that enum, tuple patterns matching arity and
  element types, guard conditions must be `Bool`). When
  the scrutinee is a decidable enum, branches must cover every member or
  include `_`, else a compile error naming the missing members; type not
  decidable → no requirement (the gradual-typing corollary). A guarded
  branch does not count toward coverage — its `when` may be false — so a
  guarded-only match still needs `_`. The check nests one level into
  tuples: when the scrutinee is a decidable `(SomeEnum, ...)` tuple, the
  branches' first-element patterns must cover every member of `SomeEnum`
  (or include `_`) — giving the enum-tag-in-tuple idiom compile-time
  exhaustiveness. This delivers the README's
  enum-matching promise. Numeric indexing on a tuple-typed receiver is
  length-checked at compile time (strictness pays).
- `emo check <path>` prints diagnostics (E4xxx codes) and exits non-zero on
  any error; `emo run` runs the same pass first.

### Out

- Generics, type constraints (do not exist by design).
- Pattern matching / destructuring checks (undecided syntax).
- Cross-module checking (step 09 loads the graph; this step checks one
  compilation unit).

## Tasks

- [ ] Type representation + annotation collection pass.
- [ ] Statement/expression checking with `Unknown` discipline.
- [ ] Signature checks; arrow-block inference.
- [ ] Flow environments with narrowing on `is()`.
- [ ] Structural interface conformance.
- [ ] `var`-escape detection.
- [ ] Call-site checking; named-argument validation.
- [ ] `case` checking: pattern typing, `when` guards as `Bool`,
      exhaustiveness on decidable enums and on the first tuple element of
      decidable `(Enum, ...)` scrutinees (guarded branches don't count).
- [ ] `emo check` command; wire into `emo run`.
- [ ] Test categories: strict-annotated rejections, inference successes,
      zero-false-positive corpus.

## Acceptance

```emo
class Admin {
  def init() { }
  def revoke() String {
    return "revoked"
  }
}

def act(u String) String {
  return u.revoke()      # error[E4001]: String has no method `revoke`
}

def greet(name) {        # error[E4002]: parameter `name` needs a type
  return name
}

def ok(u) String {       # Unknown receiver — no error reported
  return u.to_string()
}
```

- Every README example type-checks clean.
- Annotated-error corpus (wrong return type, bad named arg, `var` escape,
  narrowing misuse) all rejected with correct spans.
- Zero-false-positive corpus passes with no diagnostics.
- `dune test` green.

## Open design items

- The exact escape analysis approximation for `var` capture should be
  documented in `docs/` once chosen.
