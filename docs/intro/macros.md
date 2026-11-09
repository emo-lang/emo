# Macros

Emo's metaprogramming mechanism is the compile-time macro: an ordinary `def` marked `// #macro` that runs during compilation, receives the decorated declaration as a syntax tree, and returns replacement trees which are spliced into the program and then checked like any other code. Applications are written `// @name` above the declaration being transformed. The working design, including the rejected alternatives and the later steps, lives in [`design/macros.md`](../../design/macros.md).

## The two directive namespaces

A `//` comment whose first token is `#` or `@` is not a comment — it is a directive, and the compiler checks it like any other syntax. Every other comment is prose and stays inert.

- **`#` is the role namespace** — compiler-owned, what the declaration below *is*. `// #macro` declares that the def below runs at compile time and is erased from the program after expansion. The set of `#` names is fixed; an unknown one is a compile error (E2029), so a typo such as `// #macor` can never silently downgrade into prose.
- **`@` is the application namespace** — `// @name` applies the macro `name` to the declaration below. `@name` resolves like any other name: it must refer to a def declared `// #macro` in the same module. Applying `@` to a name that is not a macro is an error (E4300), so the two namespaces never blur.

Placement rules: a directive occupies its own line, immediately above the declaration it attaches to (a blank line leaves it floating — E2030); directives stack, with the line closest to the declaration applying first; a directive inside a body or above a statement is an error (E2031); one macro is not applied twice to the same declaration (E2032); a macro def takes no applications (E4310).

```emo
// #macro
def trace(f Syntax) Syntax {
  ...   // ordinary Emo, runs at compile time
}

// @trace
def double(n Int64) Int64 {
  return n * 2
}
```

## The macro model

- **Declared shape**: a macro takes exactly one `Syntax` parameter and returns `Syntax` (E4302 otherwise). `Syntax` is a reserved, compile-time-only type — spelled and named nowhere outside a `#macro` def (E4301).
- **Checked before run**: the macro body type-checks like any def; a macro that does not typecheck is rejected before it ever executes.
- **Deterministic by construction**: the body runs on the compiler's own interpreter with every effect refused and every host-touching builtin (`rand_bytes`, the `os_*` family) refused (E3030). No effect system is needed to say this — the hooks simply do not exist in the compile-time profile. A step budget bounds the run, so a runaway macro fails the build instead of hanging the compiler.
- **Erasure**: after expansion the `#macro` defs are gone — no runtime binding exists, and the shipped program carries no machinery its data never asked for.
- **Checked after splice**: the generated code is checked with the module. A wrapper that forwards the wrong arity, or binds a value the signature forbids, fails the build with the ordinary checker errors, located at the splice.

Recursion inside a decorated def's body refers to the final, decorated binding — the body is checked after all expansions, against the post-expansion declarations. Names the macro fabricates come from `Syntax.gensym`, which hands out fresh names that cannot collide with user code.

## The `Syntax` API

The value handed to a macro is the decorated def's tree; the value it returns is spliced in its place — one def, or a sequence of them (`Syntax.seq`). Readers: `Syntax.name`, `Syntax.params`, `Syntax.param_name`, `Syntax.result`. Constructors: `Syntax.rename`, `Syntax.new_def` (a def from a name, parameter trees, a result type tree, and statement trees), `Syntax.ident`, `Syntax.lit_string`, `Syntax.interp`, `Syntax.call`, `Syntax.call_stmt`, `Syntax.expr_stmt`, `Syntax.const_stmt`, `Syntax.return_stmt`, `Syntax.gensym`. A macro application must produce declarations — an expression or statement fragment alone is an error (E4303).

The worked example is [`examples/trace_demo`](../../examples/trace_demo/main.emo): a `trace` macro that moves the original def to a hidden name and makes the visible name a wrapper logging every call's arguments and answer — at every call site, including ones in other modules. The forwarding call is built from the wrapped declaration's own parameter trees, which is why it can never drift from the signature.

## What macros are not

Runtime code generation — `eval`, open classes, `method_missing` — is rejected as a language mechanism: generated code that does not exist at checking time cannot be checked, an evaluator in every runtime defeats the freestanding targets, and runtime structure defeats the type-feedback performance story. Emo's runtime extensibility units already exist: defs are first-class values (`Block`), dispatch tables are `Map`s, and the OS-level extension unit is a process. What macros add is the compile-time half — derivation, compile-time-checked DSLs, and the elimination of per-signature wrapper boilerplate that would otherwise drift.
