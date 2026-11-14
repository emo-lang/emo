# Macros

Emo's metaprogramming mechanism is the compile-time macro: an ordinary `def` marked `// #macro` that runs during compilation, receives the decorated declaration as a syntax tree, and returns replacement trees which are spliced into the program and then checked like any other code. Applications are written `// @name` above the declaration being transformed. The working design, including the rejected alternatives and the later steps, lives in [`docs/macros.md`](../macros.md); a task-oriented walkthrough — the directives, the `Syntax` API, the quote surface, worked recipes, and the error table — is the [macro guide](../macro-guide.md).

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

- **Declared shape**: a macro takes zero or more leading compile-time **scalar** parameters (`Int64`, `String`, `Bool`, `Float64`, `Byte`, `Char`) followed by exactly one trailing `Syntax` parameter — the decorated tree — and returns `Syntax` (E4302 otherwise). `Syntax` is a reserved, compile-time-only type — spelled and named nowhere outside a `#macro` def (E4301).
- **Checked before run**: the macro body type-checks like any def; a macro that does not typecheck is rejected before it ever executes.
- **Deterministic by construction**: the body runs on the compiler's own interpreter with every effect refused and every host-touching builtin (`rand_bytes`, the `os_*` family) refused (E3030). No effect system is needed to say this — the hooks simply do not exist in the compile-time profile. A step budget bounds the run, so a runaway macro fails the build instead of hanging the compiler.
- **Erasure**: after expansion the `#macro` defs are gone — no runtime binding exists, and the shipped program carries no machinery its data never asked for.
- **Checked after splice**: the generated code is checked with the module. A wrapper that forwards the wrong arity, or binds a value the signature forbids, fails the build with the ordinary checker errors, located at the splice.
- **Refusal is a raise**: a macro that cannot wrap a shape — a multi-parameter def, a `Void` result — says so with `raise Exception.new("...")`, and the raise surfaces as the expansion's compile error (E4308) carrying the message.

Recursion inside a decorated def's body refers to the final, decorated binding — the body is checked after all expansions, against the post-expansion declarations. Names the macro fabricates come from `Syntax.gensym`, which hands out fresh names that cannot collide with user code.

## Application arguments

The application supplies the macro's leading scalar parameters: `// @memoize(2)` evaluates `2` at compile time and binds it to `memoize`'s `limit`. The parentheses touch the directive's name (E2034), the arguments are ordinary comma-separated expressions on the directive's own line, role directives take none (E2035), and both the arity (E4306) and each argument's type against the declared parameter (E4307) are checked statically, in the builtins-only environment the expansion evaluates them in — so a name the compile-time profile cannot see fails at checking with the same answer.

## The quotation surface

`quote { ... }` — a contextual spelling: the template only where `quote` sits in an operand-start position (`=`, `(`, `,`, `[`, `return`, `do`, `->`) with a brace following on the same line; every other `quote` is an ordinary name, which is why the standard library's JSON escaper `quote(s)` and sql's `== quote {` condition-ending are untouched — lays a macro's generated code out as ordinary code: the body parses as items over the quote's own token stream (real spans, real errors), and each `${expr}` hole splices an expression tree evaluated in the macro body at expansion time. Lifting stays explicit — `${Syntax.ident(name)}` splices a name, `${Syntax.lit_int(limit)}` a literal; a hole producing a non-expression tree is an error (E4309). Declaration structure inside the template is literal (the constructors own a def's name, parameters, and result), string interpolation inside a quoted string stays the generated code's own, and `quote` outside a macro body is the ordinary compile-time-window error (E4301). `Syntax.new_def` takes a whole quote as its body, and `Syntax.seq` flattens, so a macro's splice is simply the declarations it wrote.

## The `Syntax` API

The value handed to a macro is the decorated def's tree; the value it returns is spliced in its place — one declaration, or a flat sequence of them (`Syntax.seq`). Readers: `Syntax.name`, `Syntax.params`, `Syntax.param_name`, `Syntax.result`. Constructors: `Syntax.rename`, `Syntax.new_def` (a def from a name, parameter trees, a result type tree, and a body — an array of statement trees or one whole quote), `Syntax.ident`, `Syntax.lit_string`, `Syntax.lit_int`, `Syntax.lit_bool`, `Syntax.lit_float`, `Syntax.interp`, `Syntax.call`, `Syntax.call_stmt`, `Syntax.expr_stmt`, `Syntax.const_stmt`, `Syntax.return_stmt`, `Syntax.empty_map`, `Syntax.const_item` (the module-level constant a macro splices for its generated runtime state), `Syntax.gensym`. A macro application must produce declarations — an expression or statement fragment alone is an error (E4303).

The worked examples are [`examples/trace_macro_demo`](../../examples/trace_macro_demo/main.emo) — a `trace` macro whose forwarding call is built from the wrapped declaration's own parameter trees, so it can never drift from the signature — and [`examples/memoize_macro_demo`](../../examples/memoize_macro_demo/main.emo) — a `memoize` macro with a compile-time capacity argument, a private `Map` constant, and a quote-laid-out wrapper whose cache hits skip the computation and whose evictions recompute it, visible in the output.

## Class application

The application seat widens to classes: `// @derive_eq` above a `class` hands the class tree to the macro, which reads the field list (`Syntax.fields`, `Syntax.field_name` — names; the AST does not carry field types) and returns the transformed class — `Syntax.with_methods(class, methods)` appends generated defs as ordinary methods, checked with the module like any other. `Syntax.name` answers a class's name; `Syntax.new_param`, `Syntax.named_type`, `Syntax.self_expr`, `Syntax.bin_eq`, `Syntax.bin_and`, and `Syntax.member` build the generated bodies. The role side stays def-only — `// #macro` above a class is an error, as is an application above any other item.

The worked example is [`examples/derive_eq_macro_demo`](../../examples/derive_eq_macro_demo/main.emo): `@derive_eq` generates an `eq?` method comparing every field pairwise — the generated equality cannot forget a field the class declares, which is the drift this mechanism exists to remove.

A macro body is self-contained: it names only its parameters, the `Syntax` namespace, and the builtins. The compiler checks the macro domain before any macro body runs — the `#macro` defs and the applications' compile-time arguments — and checks the whole module after expansion, which is where a call site naming a method the derivation does not produce fails.

## Cross-module macros

A macro module is an ordinary module whose `#macro` defs have no runtime presence: the application resolves through the program's macro table, and the spelling is qualified, the same path shape a value reference takes — `// @eq_macros.derive_eq` in one module applies the macro declared in the sibling `eq_macros.emo`. A bare `@macro` resolves in the declaring module only, and a same-name local macro shadows the outside one. The compile-time argument checks hold across modules (arity and types against the outside macro's declared parameters), and the self-contained rule applies to macro bodies everywhere. The worked example is [`examples/derive_shared_macro_demo`](../../examples/derive_shared_macro_demo/main.emo): a derivation written once, applied to two classes in another module.

## What macros are not

Runtime code generation — `eval`, open classes, `method_missing` — is rejected as a language mechanism: generated code that does not exist at checking time cannot be checked, an evaluator in every runtime defeats the freestanding targets, and runtime structure defeats the type-feedback performance story. Emo's runtime extensibility units already exist: defs are first-class values (`Block`), dispatch tables are `Map`s, and the OS-level extension unit is a process. What macros add is the compile-time half — derivation, compile-time-checked DSLs, and the elimination of per-signature wrapper boilerplate that would otherwise drift.
