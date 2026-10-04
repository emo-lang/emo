# Step 18 — Function groups (`emo` keyword)

**Milestone:** M5 · **Prereq:** steps 01–17 · **Status:** in progress

## Goal

`emo Foo { def ... const ... }` declares a **function group**: a named,
stateless set of functions and constants, called as `Foo.hello()` and
`Config.version`. It fills the utility-namespace gap (today: dummy
classes or bare top-level defs) and doubles as the language's signature
syntax — the keyword appears at the declaration and disappears at the
use site.

## The decided semantics

- **Keyword**: `emo` — reserved word now; the construct's reading is
  "the Emo group named Foo". Docs call the concept **函数组 (function
  group)**; not "a class without instances".
- **Members**: `def` and `const` only. Every member is implicitly
  static (there are no instances and no `self`).
- **No mutable state**: no init, no fields, no `var` — purity is the
  selling point; state wants a class.
- **Not a value**: groups cannot be passed around, stored, or satisfy
  interfaces.
- **Naming**: uppercase-first group name, like classes. Member names
  follow defs.
- **No nesting** in v1 (no `emo A { emo B {} }`).
- **Privacy**: inherits the file's rules (`internal/` and friends work
  unchanged).

## Lowering

A group member lowers to a plain function with a mangled name
(`mangle(mpath, "Foo__hello")`; consts as zero-arg thunks, the same
shape the entry's `const` already uses), and `Foo.member(args)` lowers
to an ordinary resolved `Call`. No new IR nodes; every backend that
emits functions and qualified calls gets groups for free.

## Scope

### In

- Parser: `emo` keyword + group items (`def`, `const`); `emo` reserved.
- Checker: group symbol registration; uppercase-name check;
  `Foo.member` / `Foo.member(args)` resolution (dotted like
  `internal.discounts`, arity-checked like defs); unknown-member and
  not-a-group errors.
- IR: group members as mangled functions (defs + zero-arg const
  thunks).
- All four backends — expected near-zero backend code.
- Golden example `examples/function_group/` run through the
  interpreter and all targets' CI groups.
- README (English + zh-CN) documents the syntax.

### Out

- Nesting, group generics, group-as-value, mutable group state —
  recorded, not gated.
- Wasm target remains IO-free; nothing group-specific there.

## Tasks

- [ ] **T18.1** — Parser, checker, IR lowering, native pipeline;
      `examples/function_group/` golden through `emo run`.
- [ ] **T18.2** — The typescript, wasm, and beam goldens for the
      example; README (en + zh-CN).
