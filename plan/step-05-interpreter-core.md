# Step 05 — Interpreter: Core Values & Evaluation

**Milestone:** M1 · **Prereq:** step 04 · **Status:** done

## Goal

A tree-walking evaluator for expressions, bindings, and control flow with
dynamically tagged values — the runtime semantics the README prescribes:
"types are dynamic at runtime, statically checked at compile time". After
this step, function-only Emo programs run.

## Scope

### In

- **Value type** in `emo_eval` — every value carries a runtime tag:
  `Int`, `Float`, `Bool`, `Char`, `String`, `Tuple`, `Array`, `Box`,
  `ArrowBlock` (closure), `BuiltinFn`, plus placeholders filled in step 06
  (`ClassDef`, `Instance`, `EnumMember`, `TypeValue`, `Module`). Deep
  equality `==` per value kind.
- **Environments** — lexical scope chain; `const` vs `var` recorded so a
  runtime assignment to a `const` is an error (the parse-time rebinding rule
  from step 04 plus this covers the dynamic case).
- **Arithmetic & logic** — `Int`/`Float` ops with promotion on mixed numeric
  operands; `/` and `%`; comparisons on numbers; `==` / `!=` on all values;
  `&&` / `||` / `!` on `Bool` only; `+` on `String + String` and
  `Char + Char`? No — string concatenation is `String + String`; `Char` gets
  `.to_string()`. Anything else is a runtime type error with the operand
  tags named in the message.
- **String interpolation** — evaluate parts left to right, stringify with
  the same rule as `.to_string()`.
- **Calls** — arrow blocks and builtins; **tail calls are guaranteed**: calls
  in tail position of a block evaluate via an explicit loop (rebind
  callee/args/env and iterate), never by growing the OCaml stack. This is a
  README-level guarantee and the foundation of receive loops; test it with a
  million-iteration recursive loop.
- **`if` / `return`** — condition must be `Bool` at runtime (dynamic check
  with a clear error); `return` unwinds via exception to the nearest function
  frame (explicit returns only — no last-expression value exists anywhere).
- **`case`** — first-match evaluation, top to bottom, over the step 03
  pattern set: qualified enum members by value equality, literals by `==`,
  bindings bind, `_` matches, tuple patterns match by position. A scrutinee
  matching no branch and no `_` is a runtime error that terminates with a
  diagnostic naming the value's runtime tag — never a silent skip.
- **Arrays** — literal `[a, b, c]`, indexing `a[i]`, `length()`. Arrays are
  immutable values (decided — README, Mutability): fixed length, no in-place
  element assignment, `==` compares element-wise; transforming operations
  return new arrays. Mutation of "an array" is rebinding a `var` or using
  the future `Box`. Because contents never change, the evaluator may
  share structure freely — copy semantics stay observably identical.
- **Tuples** — `(a, b, c)` literals under the README content rule: commas
  make a tuple (`()`, `(a, b)`); a single operator-free value in
  parentheses is a one-element tuple (`(a)`); an operator inside makes it
  a group (`(sum * 3)`); `(a,)` is rejected. Immutable value type, `==`
  element-wise, numeric indexing `t[0]`, `length()`. The natural message
  envelope — `(reply_to, request)` pairs feed receive patterns in step 11.
- **`Box`** — the mutable cell (README, Mutability), implemented from M1:
  `Box.new(v)` constructs, `box.read()` reads, `box.replace(v)` replaces —
  the entire operation set; there is deliberately no functional-update
  sugar. An OCaml `ref` under the hood. Snapshot-on-send semantics arrive
  with processes (step 11); in M1 a Box is simply program-local state —
  and the legal way for closures to hold long-lived mutable state, since
  capturing a `var` is a compile error.
- **Minimal builtin surface** — `print(value)` (provisional name), and
  `.to_string()` on every primitive. Nothing else; the real library is a
  later concern.

### Out

- Classes, enums, interfaces (step 06) — their parse trees evaluate to a
  clear "not yet" error meanwhile.
- Mutable collections, `Map`, string methods beyond the minimum.

## Tasks

- [x] Value ADT + equality; environment chain.
- [x] Expression evaluation with tag-checked operators.
- [x] Interpolation; `print` builtin; `.to_string()`.
- [x] Closure capture (lexical, by reference to the environment).
- [x] Tail-call loop in the evaluator; deep-recursion test.
- [x] `if` / `return` semantics; runtime type errors with spans.
- [x] Alcotest suites running real programs end to end (assert on captured
      stdout).

## Acceptance

```emo
def fib(n Int) Int {
  if n < 2 {
    return n
  }
  return fib(n - 1) + fib(n - 2)
}

const greeting = -> (name String) {
  return "hello, ${name}"
}

print(fib(20))                 // 6765
print(greeting("emo"))         // hello, emo

def count_down(n Int) Int {
  if n == 0 {
    return 0
  }
  return count_down(n - 1)
}
print(count_down(1000000))     // stack stays flat — tail calls work
```

- `dune test` green, including the deep-recursion case.

## Open design items

- `print` as the builtin name is provisional; settle it in the README when
  the I/O surface is designed.
