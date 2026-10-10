# Step 04 — Parser: Declarations

**Milestone:** M1 · **Prereq:** step 03 · **Status:** done

## Goal

Parse the full single-file language surface: functions, classes, interfaces,
enums, `raise`, and the naming-convention rules that belong to syntax. After
this step the README's code examples all parse completely.

## Scope

### In

- **Program shape** — a file is a sequence of top-level items: `def`,
  `class`, `interface`, `enum`, `const` / `var` bindings, and expression
  statements, executed/registered in order.
- **`def`** — `def name(param Type, ...) ReturnType { ... }`.
  - Names: `snake_case`, optionally ending in `?` (predicate methods);
    camelCase is a parse error.
  - Return type is **required** on `def` and **forbidden-but-defaulted** on
    `init` (`init` returns the class it constructs — no type declaration
    allowed, per the README exemption).
  - Parameters: type-declared, positional; `def` parameters do not have
    defaults (undecided feature — not built).
- **`class`** — body contains exactly one `init` and any number of `def`s
  (provisional: a missing or duplicated `init` is an error — strictness
  first). Fields are *not declared*: the field set is whatever `init`
  assigns via `self.x = ...` (collected here for later stages).
  No inheritance syntax exists and none is added.
- **`interface`** — body is method signatures only (`def greet() String`,
  no body, no `init`).
- **`enum`** — `enum Color { red, green, blue }`; members are bare
  lower_snake identifiers. No payloads — `enum Color(String)` or
  Rust-shaped variants are rejected by construction.
- **`raise`** — statement `raise <expression>`; the catch form is undecided
  (`CHECK.md`) and intentionally absent.
- **Naming conventions enforced here** (they are syntactic in Emo): type
  positions (`class` / `interface` / `enum` names, types in declarations) must be
  `UPPER_IDENT`; function/variable/parameter names and enum members must be
  lower_snake; method names may end in `?` only on `def`s, and `?` names are
  not valid as variables. Violations are errors with precise spans.
- **`const` / `var`** distinction is carried on the binding node; whether a
  `var` may be reassigned is a later-stage check, but `const` rebinding in
  the same scope is rejected at parse time.
- Basic multi-error recovery: after a declaration error, resync at the next
  top-level keyword and keep parsing — report as many errors as possible in
  one pass.

### Out

- `require` (step 10), pattern matching, mixins (undecided), default
  arguments, visibility keywords (do not exist structurally).

## Tasks

- [x] Declaration AST nodes; top-level item sequence.
- [x] `def` parsing with the `init` exemption and `?`-name rules.
- [x] `class` (single-`init` rule, field collection from `self.x =`).
- [x] `interface` signature-only bodies.
- [x] `enum` member lists.
- [x] `raise` statement.
- [x] Naming-convention checks with spans; multi-error resync.
- [x] Golden tests: `User`, `Greeter` / `English`, `Color` examples from the
  README parse cleanly; convention violations produce the expected errors.

## Acceptance

- The README's `User`, `Greeter`, `English`, `welcome`, and `Color` snippets
  parse to golden ASTs.
- Negative tests: camelCase `def`, `UPPER` variable, `enum Color(String, Int)`,
  duplicate `init`, a declared `init` return type — each rejected with the
  right message and span.
- `dune test` green.

## Open design items

- Exactly-one-`init` per class is a provisional decision (the README only
  fixes that `init` is the sole field-assignment window).

## Settled during this step

- **At most one `init` per class** — the README's `English` class carries no
  `init`, so a missing `init` is legal (stateless class, no fields); a
  duplicate `init` remains an error. The `class_init` node is optional.
- **Parameterized trailing blocks** — a call may take a block argument after
  `->` on the same line (`list(users) -> (user User) { ... }`), mirroring the
  empty-parens sugar; parameters still require type declarations.
