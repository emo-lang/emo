# Emo macros: compile-time declaration transformers

Working design for the `feat/decorator` track. Decisions recorded here were
made with the author on 2026-11-09; undecided items stay in the open-questions
section and out of the README until settled. When step 1 lands, the decided
sections graduate into `docs/intro/` (English) and `docs/zh-CN/` (Chinese).

## Summary

Emo grows one metaprogramming mechanism: **compile-time macros**. A macro is
an ordinary `def` marked with the `// #macro` directive; it runs during
compilation, receives the decorated declaration's syntax tree, and returns
replacement syntax trees that are spliced into the program and then checked
like any other code. Applications are written with the `// @name` directive
above the declaration being transformed.

Value-level decorators (a runtime wrapper applied to a def, Python's
decorator shape) are deliberately **not** a separate mechanism: macros
express them by generating the forwarding code, and the generated forwarder
knows the signature, so it can never drift from the wrapped def.

## Motivation, and why the construct earns its place

The rule: a construct exists only when ordinary code cannot express the
thing, or when it removes a whole class of mistakes. Three things ordinary
Emo code cannot do today:

1. **Rebind a def in place.** A def is an immutable binding; there is no way
   to wrap `double` so that every existing call site — in this module and in
   importers — sees the wrapped version. Wrapping under a new name forces
   editing every call site and leaves the original name unwrapped.
2. **Write one generic wrapper for any signature.** A `Block` is opaque: no
   signature introspection, no variadic forwarding, and an 8-argument call
   limit. Every hand-written wrapper is pinned to one signature.
3. **See code structure.** A function receives values; no library routine can
   ask "what is this expression spelled like", "what fields does this class
   declare", or "what does this format string contain". Derivation (equal,
   JSON, copy), compile-time-checked DSLs (SQL, format strings, routes), and
   registration glue all need exactly that.

Hand-written wrappers drift from the wrapped def when signatures change —
a real class of human error. A macro's generated code is built from the
declaration itself and cannot drift. That is the class of mistakes removed,
and it is the reason the construct exists.

What macros are deliberately **not**: a runtime `eval`, open classes, or
`method_missing`. Runtime code generation is rejected as a language
mechanism — it defeats static checking, it would put a compiler or
interpreter into every runtime including the freestanding EmoOS target, and
it breaks the type-feedback performance story. Emo's runtime extensibility
units already exist: defs are first-class values (`Block`), dispatch tables
are `Map`s, and the OS-level extension unit is a process. Compile-time
generation is the missing half, and it is the half that keeps strictness.

## The two directive namespaces

Directives are line comments with a reserved first token. A `//` comment
whose first token is `#` or `@` is **not a comment** — it is a directive,
and the compiler checks it like any other syntax. Every other comment is
prose and stays inert.

### `#` — the role namespace (compiler-owned, fixed set)

```emo
// #macro
def trace(f Syntax) Syntax {
  ...   // ordinary Emo, runs at compile time
}
```

`// #macro` declares that the def below is a macro: it executes during
compilation, not at runtime. The set of `#` names is fixed by the compiler;
`#macro` is its only member in step 1. An unknown `#name` is a compile
error (E2029) — a typo such as `// #macor` can never silently downgrade
into prose.

### `@` — the application namespace (names resolve in scope)

```emo
// @trace
def double(n Int64) Int64 {
  return n * 2
}
```

`// @name` applies the macro `name` to the declaration below. At compile
time the decorated declaration's tree is handed to the macro, the macro's
returned trees are spliced in its place, and the spliced result is checked
and compiled like ordinary code. `@name` resolves like any other name: it
must refer to a def declared `// #macro` in the same module (step 1) or an
imported module (later step). Applying `@` to a name that is not a macro is
an error (E4300), so the two namespaces never blur.

### Grammar and placement rules

- Form: `// #name` or `// @name`; application directives may carry
  arguments, `// @name(expr, ...)` (step 2 — see open questions).
- A directive occupies its own line, immediately above the declaration it
  attaches to. A blank line or any other token between directive and
  declaration leaves it floating — a parse error (E2030).
- Directives stack: several lines above one declaration, **the line closest
  to the declaration applies first** (bottom-up), matching the reading
  order of wrapping.
- Directives attach to top-level declarations only (`def` in step 1;
  `class` arrives with the derive step). A directive above a top-level
  statement, inside a body, or trailing a file is an error (E2031).
- A declaration may carry at most one `@` application per macro name —
  duplicates are an error (E2032).
- A `@` application never decorates a `#macro` def — macros do not compose
  onto macros (E4310). The error is explicit, not a silent ignore.

## The macro model

### Declaration shape

A macro is a def whose single parameter and result are the builtin type
`Syntax`:

```emo
// #macro
def trace(f Syntax) Syntax { ... }
```

`Syntax` is a reserved name (the same registry that guards the other
builtins). It is a compile-time-only type: using it outside a `#macro` def
is an error (E4301), and no runtime value of it exists. A `#macro` def whose
signature is not exactly `(Syntax) -> Syntax` is an error (E4302).

### Compile-time execution

Macro bodies are ordinary Emo and are type-checked like ordinary Emo
(strictness applies to macro authors first of all). They execute on the
compiler's own reference interpreter in a restricted profile:

- **Deterministic by construction.** The compile-time interpreter wires no
  effect hooks: no console, no file system, no network, no clock, no
  entropy. A macro that reaches for an effect fails the compilation with an
  explicit error; there is no effect system to design because the hooks
  simply do not exist in that profile.
- **Budgeted.** The restricted runner keeps its step budget, so a runaway
  macro fails the build with a clear diagnostic instead of hanging the
  compiler.
- **Checked before run.** A macro body is checked like any def; a macro that
  does not typecheck is rejected before it ever executes.

### Erasure

After expansion, `#macro` defs are **erased from the program**. They are
compile-time equipment; no runtime binding exists for them, and calling one
at runtime is an ordinary unknown-name error. This keeps the shipped
program free of machinery its data never asked for.

### Hygiene

The strict rule: every name in generated code must be either written by the
macro author inside the macro body's own scope, or explicitly constructed —
there is no accidental capture. Names the macro fabricates at run of
compile time (loop temporaries, hidden forwarder names) come from
`Syntax.gensym`, which hands out fresh names that cannot collide with user
code. Unresolvable free names in a splice are ordinary unknown-name errors
at the splice site — visible, located, and loud.

### Ordering and recursion

Application is bottom-up for stacks of directives. A macro sees the
declaration **as written, undecorated by any directive that applies after
it** — each application transforms the result of the previous one, and the
lines are processed nearest-first. Recursion inside a decorated def's body
refers to the **final, decorated** binding: the body is checked after all
expansions, against the module's post-expansion declarations. (This differs
from Python, where a recursive def re-enters its own wrapper; here the
generated code is what exists, so it is what the body sees. The behavior is
a consequence of the model, not a special rule.)

## The `Syntax` API (step 1 surface)

Minimal, constructor-based; a quotation surface (`quote { ... }` with
`${...}` holes, reusing the string-interpolation mental model) is the
step-2 ergonomics layer and stays an open question until then.

Readers:

- `Syntax.name(f) -> String` — the def's name
- `Syntax.params(f) -> Array[Syntax]` — the parameter trees
- `Syntax.param_name(p) -> String` — a parameter's name
- `Syntax.result(f) -> Syntax` — the result type tree
  (a decorated def must declare a result type in step 1; `Void`-resulting
  defs are refused by the pilot macro, not by the model)

Constructors:

- `Syntax.rename(f, new_name) -> Syntax` — the def tree, renamed
- `Syntax.new_def(name, params, result, body) -> Syntax` — a new def;
  `params` is an array of parameter trees, `body` an array of statement
  trees (`def` itself is a reserved word and cannot be a member name)
- `Syntax.seq(a, b) -> Syntax` — a sequence of trees (the splice result of
  a macro application may replace one declaration with several)
- `Syntax.ident(s) -> Syntax`, `Syntax.lit_string(s) -> Syntax`
- `Syntax.interp(parts) -> Syntax` — an interpolated string expression
- `Syntax.call(f, args) -> Syntax` — a call expression
- `Syntax.call_stmt(f, args) -> Syntax` — a call statement
- `Syntax.expr_stmt(e) -> Syntax`, `Syntax.const_stmt(name, e) -> Syntax`,
  `Syntax.return_stmt(e) -> Syntax` — statement wrappers
- `Syntax.gensym(base) -> String` — a fresh, collision-free name

The pilot macro (`examples/trace_demo`) is written entirely against this
surface, which is the proof that the surface is complete enough to be
useful.

## Pipeline mapping

Parse → **expand** → check → codegen / eval. Expansion is a new pass
between parsing and checking, per module:

1. Scan the module's items for `#macro` defs (a declaration-level scan; no
   checking needed to know a def is a macro).
2. Check the module once with directives validated — this checks the macro
   bodies themselves and rejects bad directive use.
3. For each application, run the macro body on the decorated tree in the
   restricted interpreter, splice the result in place, and erase the macro
   defs.
4. Check the expanded module; everything downstream (all four targets) is
   untouched by construction.

Step 1 scopes macros to **the module that declares them**. Cross-module
macro resolution rides the same preregistration tables the checker already
carries (`pdefs`/`pvalues`/`program_types`) and is scheduled with the
derive step, where cross-package derivation is the actual use.

## The ladder

1. **Step 1 — directive infrastructure + pilot `@trace`.** Lexer directive
   capture, AST directive attachment, parser consumption with adjacency
   rules, checker validation (the full strictness error set), the expansion
   pipeline, the restricted compile-time interpreter profile, the `Syntax`
   API above, and `examples/trace_demo` proving the chain: tree in, trees
   out, call sites transparent, byte-identical output across targets.
2. **Step 2 — `@memoize` + application arguments + quotation.** Proves
   compile-time argument evaluation (`// @memoize(100)` — arguments are Emo
   expressions, evaluated at compile time, checked against the macro's
   declared parameter list) and generated runtime state (a private `Map`
   const the wrapper consults), and lands the `quote` surface.
3. **Step 3 — `@derive` on classes.** Application onto `class`
   declarations, one macro generating several defs (equality, JSON) from
   the field list — the highest-leverage step, and the one that pulls
   cross-module macros in.

## Trade-offs recorded

- **The `@` sigil.** `@name` above a declaration is recognizable from Java
  and Kotlin annotations and from Python decorators. The single-language
  fingerprint test is passed because the form lives in the directive layer,
  not the grammar; the semantics are compile-time expansion, not Python's
  runtime wrapping; and the surrounding language shares nothing else with
  Python. The author's stated reason for choosing `@` stands: Python
  programmers should feel at home. The alternatives (`// +trace` and
  friends) were rejected as less readable with no additional cleanliness.
- **Visual salience.** A directive looks like a comment until you see the
  `#`/`@` first token. The reserved first token is what makes directives
  greppable and distinct from prose; syntax highlighting and the formatter
  treat them as significant lines. This is weaker salience than a keyword
  would give, and it is accepted in exchange for zero grammar footprint.
- **Toolchain obligations.** The formatter must never merge, move, or drop
  directive lines; the LSP must surface them as annotations, not comments;
  both ride on the same lexer change.

## Error codes

Parser-level directive errors take E2029–E2032 (next free codes in the
parser's range), checker-level macro errors take E4300+ (verified free at
assignment time). Codes are finalized as the diagnostics land.

## Open questions (deliberately undecided)

- The quotation surface (`quote { ... }`, hole semantics, whether holes
  accept plain values in leaf positions) — designed when step 2 starts.
- Application arguments' exact checking story — with step 2.
- Cross-module macro tables — with step 3.
- Macro application onto `class` and the derive API — with step 3.
