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

The pilot macros (`examples/trace_demo`, then `examples/memoize_demo`)
are written entirely against this surface, which is the proof that the
surface is complete enough to be useful.

## Application arguments (step 2)

A macro's signature is zero or more leading compile-time **scalar**
parameters (`Int64`, `String`, `Bool`, `Float64`, `Byte`, `Char`) followed
by exactly one trailing `Syntax` parameter (the decorated tree), returning
`Syntax` — `def memoize(limit Int64, f Syntax) Syntax`. The application
`// @memoize(2)` supplies the leading parameters: the parentheses touch
the directive's name (E2034), the arguments are ordinary comma-separated
Emo expressions on the directive's own line (E2033 when they drift), and
role directives take none (E2035).

The arguments are checked statically at the application site — arity
(E4306) and, per argument, type conformance against the declared
parameter (E4307) — in the builtins-only environment the expansion will
evaluate them in, so a name the compile-time profile cannot see fails at
checking with the same answer. They are then evaluated, in the protected
compile-time profile, and bound to the leading parameters; the trailing
`Syntax` parameter binds to the decorated tree. A macro body may `raise`
to refuse a shape it cannot wrap (a multi-parameter def, a `Void` result)
— the raise surfaces as the expansion's compile error (E4308) with the
exception's message.

## The quotation surface (step 2)

`quote { ... }` is the macro author's template — a **contextual** spelling, not a keyword: the template only where `quote` sits in an operand-start position (`=`, `(`, `,`, `[`, `return`, `do`, `->`) and a brace follows on the same line; every other `quote` stays an ordinary name. The rule was driven by the corpus, twice over: the standard library's JSON escaper is *called* as `quote(self.value)` (a keyword breaks it), and sql's `data.get(i) == quote` *ends an if condition* whose `{` opens the body (brace-follow alone breaks it) — both real uses the first two cuts of the rule rejected. `foreign` is the item-position precedent — and the body parses as
ordinary items over the quote's own token stream, so the tree carries the
file's real spans, and each `${expr}` hole parses in place and leaves a
compiler-owned placeholder identifier standing in the stream. When the
quote evaluates — during expansion, inside the macro body — each hole's
expression evaluates and its tree is substituted for the placeholder.
Holes splice **expression trees**; a hole producing anything else is an
error (E4309), and lifting stays explicit: `${Syntax.ident(name)}` for a
name, `${Syntax.lit_int(limit)}` for a literal. Declaration structure
inside the template is literal — a def's name, parameters, and result
stay with the constructors — and string interpolation inside a quoted
string stays the generated code's own runtime interpolation, so
compile-time string composition goes through holes. A placeholder
spelling (`__emo_quote_N`) is reserved inside quotes (E2036, which also
covers unclosed quotes and holes), and `quote` outside a macro body is
the ordinary compile-time-window error (E4301).

`Syntax.new_def`'s body parameter takes either an array of statement
trees or one whole quote (a sequence of item-level bindings lays out as
the body's statements). `Syntax.seq` flattens: nesting sequences is
concatenation, and a macro's splice result is the flat list of
declarations it produces.

## Class application and derivation (step 3)

The application seat widens to classes: `// @derive_eq` above a `class`
hands the class tree to the macro, which reads the field list and returns
the transformed class — `Syntax.fields` / `Syntax.field_name` read the
fields (names only; the AST does not carry field types, so a derivation
needing them waits on the checker's table, recorded below), and
`Syntax.with_methods(class, methods)` appends generated defs as ordinary
methods, checked with the module like any other. `Syntax.name` answers a
class's name. The supporting constructors: `Syntax.new_param`,
`Syntax.named_type`, `Syntax.self_expr`, `Syntax.bin_eq`, `Syntax.bin_and`,
`Syntax.member`. The role side stays def-only — `// #macro` above a class
is E2031, applications above any other item stay E2031, and the duplicate
rules (E2032) apply to classes like defs.

The pilot is [`examples/derive_eq_demo`](../../examples/derive_eq_demo/main.emo):
`@derive_eq` generates an `eq?` method comparing every field pairwise —
the generated equality cannot forget a field the class declares, which is
the drift this mechanism exists to remove — byte-identical across the
interpreter, the c binary, and the TypeScript output.

**The precheck narrowed with it.** Step 58's expansion prechecked the
whole raw module; derive breaks that, because a call site naming a
generated method would fail against the raw class before the macro ever
ran. The gate is now `check_macro_domain`: the `#macro` defs' shape and
bodies (quote holes included) plus every application's compile-time
arguments against the macro's declared parameters — application carriers
ride as hollow shells (signatures and directives intact, bodies emptied,
return type dropped to Void so a hollow Int64 shell cannot trip the
must-return rule). The module's full checking belongs to the expanded
module, which is where a call site naming a method the derivation does
not produce dies. One rule lands with the narrowing, stated as a
constraint: **a macro body is self-contained** — it names only its
parameters, the `Syntax` namespace, and the builtins; a helper def it
needs is itself declared `#macro` (erased with the rest) or the logic
moves inline.

Cross-module macros — `@name` resolving through a require — stay the
named follow-up: same-module derivation is the working core, and the
preregistration tables are where the resolution rides when it comes.

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

1. **Step 1 — directive infrastructure + pilot `@trace`** (landed, step
   58): lexer directive capture, AST directive attachment, parser
   consumption with adjacency rules, checker validation (the full
   strictness error set), the expansion pipeline, the restricted
   compile-time interpreter profile, the `Syntax` API, and
   `examples/trace_demo` proving the chain.
2. **Step 2 — `@memoize` + application arguments + quotation** (landed,
   step 59): compile-time argument evaluation against the macro's leading
   parameters, generated runtime state (a private `Map` constant the
   wrapper consults, with a drop-and-restart eviction policy at the
   limit), and the `quote` surface — `examples/memoize_demo` shows a hit
   skipping the computation and the eviction recomputing, byte-identical
   across targets.
3. **Step 3 — `@derive` on classes** (landed, step 60): application onto
   `class` declarations, the class reader/constructor API, and
   `examples/derive_eq_demo` — one macro generating the equality method
   from the field list. The expansion precheck narrowed to the macro
   domain (macro bodies + application arguments), because a generated
   method's call site must not be checked against the raw class. Still
   open in this step's territory: declaration-structure holes in the
   quote surface (a JSON derivation wants `def ${name}(...)`), field
   types on the class tree (the AST carries names only), and cross-module
   macros — each named below.

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

- Declaration-structure holes in the quote surface (`def ${name}(${params})
  ${ret}`) and holes inside class bodies — the constructors cover them
  today; the ergonomic surface waits for a derivation that actually needs
  it (JSON, with field types).
- Field types on the class tree — the AST carries field names only; a
  type-aware derivation (JSON) rides on the checker's field-type table or
  a richer field tree.
- Cross-module macro tables — `@name` through a require.
- JSON/string derivations beyond `eq?` — same shape, waits on the two
  items above.
