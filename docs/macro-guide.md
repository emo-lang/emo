# Macro guide

A macro is an ordinary `def` that runs during **compilation**: it receives the decorated declaration as a syntax tree, returns replacement trees, and the compiler splices them in before checking — so everything a macro generates is real, checked Emo code, on every target. This guide shows how to write and apply one. The language-level rules live in [Macros](intro/macros.md); the design record and rejected alternatives in [`design/macros.md`](../design/macros.md).

## The two directives

Directives are `//` lines whose first token is `#` or `@` — reserved, checked like any syntax, each on its own line directly above the declaration:

```emo
// #macro
def trace(f Syntax) Syntax {
  ...   // runs at compile time
}

// @trace
def double(n Int64) Int64 {
  return n * 2
}
```

- **`// #macro`** declares the def below a macro. Its signature must be scalar parameters followed by exactly one `Syntax` parameter, returning `Syntax` — the `Syntax` parameter is the decorated declaration's tree.
- **`// @name`** applies the macro. After expansion, the decorated declaration is replaced by whatever the macro returned, and the macro def itself is **erased** — it has no runtime presence.
- An unknown `#name` or `@name` is a compile error, so a typo (`// #macor`) can never silently become a comment.
- Directives stack: several lines above one declaration apply nearest-first (the line closest to the declaration goes first).
- `@name` with a dotted path (`// @eq_macros.derive_eq`) applies a macro from a sibling module; a bare name is local, and a same-name local macro shadows the outside one.

After expansion the module reads like hand-written code — see for yourself:

```
emo dump main.emo          # the expanded surface, what the targets compile
emo dump main.emo --raw    # the file as parsed — directives, macro defs
```

## A first macro, line by line

The worked example is [`examples/trace_demo`](../examples/trace_demo/main.emo) — the macro below wraps a def so every call logs its arguments and answer:

```emo
// #macro
def trace(f Syntax) Syntax {
  const name = Syntax.name(f)               // "double"
  const params = Syntax.params(f)           // the parameter trees
  const ret = Syntax.result(f)              // the result type tree
  const hidden_name = Syntax.gensym(name)   // a fresh, collision-free name
  const original = Syntax.rename(f, hidden_name)
  const wrapper = Syntax.new_def(name, params, ret, [
      Syntax.call_stmt("println", [
        Syntax.interp([
          Syntax.lit_string("trace: " + name + "("),
          Syntax.ident(Syntax.param_name(params[0])),
          Syntax.lit_string(")")
        ])
      ]),
      Syntax.const_stmt("r",
        Syntax.call(Syntax.ident(hidden_name), [Syntax.ident(Syntax.param_name(params[0]))])),
      Syntax.return_stmt(Syntax.ident("r"))
    ])
  return Syntax.seq(original, wrapper)
}
```

Reading it: the original def moves to a hidden name (`double__1`), and the visible name becomes a wrapper that logs, forwards with the **wrapped declaration's own parameter trees**, and returns. The forwarding call is built from the same trees the signature came from — it cannot drift from the signature, which is the class of mistakes this mechanism exists to remove.

## The `Syntax` API

Readers take a declaration apart; constructors build trees. A macro application must produce declarations (one def/class, or a flat sequence) — an expression fragment alone is an error.

| Reader | Answers |
| --- | --- |
| `Syntax.name(f)` | the def's or class's name |
| `Syntax.params(f)` | a def's parameter trees |
| `Syntax.param_name(p)` | a parameter's name |
| `Syntax.result(f)` | a def's result type tree |
| `Syntax.fields(f)` | a class's field trees (names; no types — see limits) |
| `Syntax.field_name(fd)` | a field's name |

| Constructor | Builds |
| --- | --- |
| `Syntax.rename(f, new_name)` | the def, renamed |
| `Syntax.new_def(name, params, result, body)` | a def; `body` is an array of statement trees or one whole `quote` |
| `Syntax.seq(a, b)` | a sequence (nesting flattens) |
| `Syntax.with_methods(class, methods)` | the class with the def trees appended as methods |
| `Syntax.ident(s)` / `Syntax.self_expr()` | a name / `self` |
| `Syntax.lit_string(s)` / `lit_int(n)` / `lit_bool(b)` / `lit_float(f)` | literal expressions |
| `Syntax.interp(parts)` | `"a${x}b"` from text and expression trees |
| `Syntax.call(f, args)` / `Syntax.call_stmt(f, args)` | a call expression / statement |
| `Syntax.member(e, name)` | `e.name` |
| `Syntax.bin_eq(l, r)` / `Syntax.bin_and(l, r)` | `l == r` / `l && r` |
| `Syntax.empty_map()` | `{}` — the generated-state constant |
| `Syntax.const_item(name, e)` | a module-level `const` |
| `Syntax.new_param(name, type_tree)` | a parameter |
| `Syntax.named_type(s)` | a named type tree (`Bool`, the class's own name, …) |
| `Syntax.gensym(base)` | a fresh, collision-free name |

## The quote surface

`Syntax.new_def`'s statement list covers generated wrappers, but laying a body out as **code** reads better. `quote { ... }` parses its braces as ordinary Emo (real spans, real errors), and each `${expr}` hole splices an expression tree evaluated in the macro body:

```emo
const wrapper = Syntax.new_def(name, params, ret, quote {
  if ${cache}.has(${arg}) {
    return ${cache}.get(${arg})
  }
  const r = ${Syntax.ident(hidden_name)}(${arg})
  ${cache}.set(${arg}, r)
  return r
})
```

Holes splice **expression trees** — lifting stays explicit: `${Syntax.ident(name)}` for a name, `${Syntax.lit_int(limit)}` for a literal. Declaration structure inside the template is literal (a def's name, parameters, result stay with the constructors), and string interpolation inside a quoted string stays the generated code's own.

## Application arguments

A macro's leading scalar parameters (`Int64`, `String`, `Bool`, `Float64`, `Byte`, `Char`) are supplied by the application, evaluated at compile time, and checked statically — arity and type — at the application site:

```emo
// #macro
def memoize(limit Int64, f Syntax) Syntax {
  ...   // `limit` is an Int64 here, usable like any compile-time value
}

// @memoize(2)
def slow_double(n Int64) Int64 {
  return n * 2
}
```

A macro that cannot wrap the shape it was given — a `Void` result, a multi-parameter def when the recipe needs one — refuses by raising:

```emo
if Syntax.params(f).length() > 1 {
  raise Exception.new("memoize wraps a single-parameter def")
}
```

The raise surfaces as the expansion's compile error, carrying the message.

## Class derivation

The application seat also takes classes: `// @derive_eq` above a `class` hands the class tree to the macro, which reads the field list and appends generated methods with `Syntax.with_methods` — they live inside the class like hand-written ones, checked with the module. The worked example is [`examples/derive_eq_demo`](../examples/derive_eq_demo/main.emo):

```emo
// #macro
def derive_eq(f Syntax) Syntax {
  const name = Syntax.name(f)
  const fields = Syntax.fields(f)
  const po = Syntax.new_param("other", Syntax.named_type(name))
  var acc = Syntax.lit_bool(true)
  var have = false
  var i = 0
  while i < fields.length() {
    const fname = Syntax.field_name(fields[i])
    const cmp = Syntax.bin_eq(
        Syntax.member(Syntax.self_expr(), fname),
        Syntax.member(Syntax.ident("other"), fname))
    acc = if have { Syntax.bin_and(acc, cmp) } else { cmp }
    have = true
    i = i + 1
  }
  const eq = Syntax.new_def("eq?", [po], Syntax.named_type("Bool"), [
      Syntax.return_stmt(acc)
    ])
  return Syntax.with_methods(f, [eq])
}

// @derive_eq
class Point {
  def init(x Int64, y Int64) {
    self.x = x
    self.y = y
  }
}
```

The generated equality cannot forget a field the class declares — that is the drift this mechanism removes.

## Sharing macros across modules

A macro module is an ordinary module whose `#macro` defs have no runtime presence. Apply from another module with the qualified spelling, the same path shape a value reference takes:

```emo
// @eq_macros.derive_eq
class Point { ... }
```

The pilot lives in [`examples/derive_shared`](../examples/derive_shared/main.emo) — one derivation in `eq_macros.emo`, two classes applying it in `main.emo`.

## Rules and limits

- **Macro bodies are self-contained**: they name only their parameters, the `Syntax` namespace, and the builtins. A helper is itself `// #macro` (erased with the rest) or the logic moves inline.
- **Determinism is by construction**: the compile-time profile refuses every effect and every host-touching builtin (`rand_bytes`, the `os_*` family), and printing. A step budget bounds the run.
- **Splices are checked**: generated code fails the build like hand-written code — a wrong-arity forwarder dies with the ordinary checker errors.
- **Recursion in a decorated def refers to the final, decorated binding** — the generated wrapper is what exists, so it is what the body sees (this differs from Python on purpose).
- **Declaration structure is constructor-owned**: holes splice expression trees; a def's name, parameters, and result are built with the API. Field trees carry names, not types, so a type-aware derivation (JSON) waits on that gap.
- **Package boundaries**: macros resolve within the package tree; a require-scoped library macro is the named follow-up.

## Error codes

| Code | Meaning |
| --- | --- |
| E2029–E2035 | directive placement and shape (unknown role, floating, in-body, duplicate, bad form) |
| E3030 | an effect or host builtin inside a macro body |
| E4300 | unknown macro, or `@` on a non-macro |
| E4301 | `Syntax` / `quote` outside the compile-time window |
| E4302 | a macro's signature is not scalars + `Syntax` → `Syntax` |
| E4303 | a splice that is not declarations / a body that is not statements |
| E4304 | a macro that never returns a tree (or returns a non-tree) |
| E4306 / E4307 | application arity / argument type |
| E4308 | a macro raised — refusal with a message |
| E4309 | a quote hole that is not an expression tree |
| E4310 | applying `@` to a macro def |

## The four runnable pilots

[`examples/trace_demo`](../examples/trace_demo/main.emo) — the minimal wrap. [`examples/memoize_demo`](../examples/memoize_demo/main.emo) — an application argument, generated runtime state (a private `Map`), and a quote-laid-out wrapper. [`examples/derive_eq_demo`](../examples/derive_eq_demo/main.emo) — class derivation. [`examples/derive_shared`](../examples/derive_shared/main.emo) — the same derivation applied from a sibling module. Each runs byte-identically on the interpreter and the compiled targets.
