# Protocols

Emo's metaprogramming is a small, closed registry of **language protocols**: named methods the language dispatches on, spelled plainly and enforced by the compiler. No marker prefix or suffix distinguishes a protocol method — the registry carries the distinction, and the compiler states it at both ends: a definition with the wrong signature is a compile error, and a registry call on a type without the method is a compile error wherever the type is known.

This is the explicit-protocols school: the language's generic operations are ordinary methods with documented names, and the language says exactly which names it dispatches on. Magic metaprogramming — hooks for missing methods, methods defined at runtime, open classes — is not a variant Emo declines to implement; the declaration shapes make it impossible, because a class's method set is exactly its own `def`s.

## The registry

The registry is the `emo` module — the language's own function group, present in every program without a `require`, the way `R` and `Exception` are. Its surface is the complete list of language protocols:

| Entry | Dispatches to | Contract |
| --- | --- | --- |
| `emo.to_string(x)` | `x.to_string()` | `def to_string() String` |
| `emo.length(x)` | `x.length()` | `def length() Int64` |

A method name with no registry entry is an ordinary method — nothing dispatches on it.

The keyword does double duty: `emo Name { ... }` declares a function group, and in expression position `emo.` accesses the language's own. No package may bind under the short name `emo`.

## Dispatch

**Calls.** `emo.f(x, rest...)` is `x.f(rest...)`: the receiver is always the first argument, the rest pass through in order — named arguments and a trailing block included, so `emo.f(x, indent: 2)` is `x.f(indent: 2)`.

**Constructs.** The rendering path is one rule, shared everywhere a value becomes text:

- `println(value)` writes `emo.to_string(value)` plus a newline.
- Interpolation renders each `${...}` part with `emo.to_string`.
- A container renders its elements with the same entry — `[Point.new(1, 2)]` prints `[(1, 2)]`.
- A class without `to_string` renders as its structure dump — `#Point(x: 1, y: 2)`, strings quoted inside, byte-identical on every target. This is a defined default, not a silent fallback: every value answers `to_string()`. (A target that cannot render an instance at all refuses loudly, the freestanding target's standing shape.)

What stays out of rendering: `printf("%s", ...)` takes a `String` — convert explicitly with `emo.to_string(x)`; `+` never concatenates a non-`String` — interpolation is the join.

**Contracts.** A protocol name inside a class or interface body carries its exact contract: `def to_string` must be `() String`, `def length` must be `() Int64`. Any other signature is a compile error stating the contract — the rule `init` already follows. Protocol names are ordinary identifiers everywhere else: a top-level function, group member, binding, parameter, or field named `to_string` is fine. A protocol method is defined, never declared — there is no conformance clause; satisfaction is structural, exactly as with interfaces.

```emo
class Point {
  def init(x Int64, y Int64) {
    self.x = x
    self.y = y
  }

  def to_string() String {
    return "(${self.x}, ${self.y})"
  }
}

println(Point.new(1, 2))           // (1, 2)
println([Point.new(1, 2)])         // [(1, 2)]
println("at ${Point.new(1, 2)}")   // at (1, 2)
```

Calling `emo.f(x, ...)` where `x`'s type lacks the method is a compile error wherever the type is known, a runtime error otherwise; the missing-method error names a near-miss definition (`to_str`) when one exists. `println` never errors for a missing `to_string` — the default rendering is its answer.

## What is not a protocol

`==` is not a protocol and has no entry: equality is structural by language rule on every type, with nothing to override. The registry dispatches methods, never operators — `a + b`, `a < b`, and `a == b` never call user code; a domain type spells named methods (`v.plus(w)`).

There are no hooks for missing methods: calling an absent method is an error, never a callback. There is no second rendering entry beside `to_string` — one hook, one defined default. No truthiness conversion — a condition is a `Bool`. No custom `case` matchers.

## How an entry earns its place

Two questions, both required:

1. **Is the method load-bearing in the language surface?** Either a construct dispatches on it — `to_string` is dispatched by `println`, interpolation, and container rendering — or the builtins themselves carry it as the canonical shared name — `length`, which `Array`, `String`, `Map`, `List`, `Bytes`, and `ArrayBuilder` all implement as `def length() Int64`.
2. **Is the contract closed?** The signature must state exactly, so the checker can verify it at the definition and at the call. An operation whose arguments relate to each other cannot be an entry: a collection transform (`emo.map(x, fn)`) would have to relate `fn` to `x`'s elements, which the type system cannot state — and every use would be an explicit call anyway, where `x.map(fn)` is already the direct form. Collection operations, if they come, are the collection types' own methods.

The registry grows by design decision, and it grows slowly. Generic programming over shapes is what interfaces are for — the registry is the language's own reserved set, and its value is its scarcity.
