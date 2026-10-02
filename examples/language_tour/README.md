# Language tour

One program that introduces Emo's core ideas in reading order — every
section prints what it just demonstrated.

```console
emo run main.emo
```

What to notice:

- **Everything is visibly what it is.** Calls carry parentheses, `return`
  is written out, and mutability is spelled (`const` vs `var` vs `Box`).
- **Classes are immutable value types.** Fields are assigned only inside
  `init` and freeze afterwards; two instances with equal content are
  `==`. Named arguments (`User.new(name: "王晓明", age: 28)`) read at the
  call site.
- **Interfaces are contracts by shape.** Neither `Machine` nor `Friend`
  declares `implements` — the consumer's `Greeter` annotation is the
  whole contract, and `g.is(Machine)` narrows the same value in place.
- **Enums are closed sets; data rides in tuples.** `(Outcome.ok, value)`
  is destructured directly in `case`, with guards where a branch needs
  one.
- **Chinese text is ordinary string data** — printed, interpolated, and
  compared without ceremony.
- **A trailing block is the one callback notation.** `walk(xs, 0) ->
  (v Int) { ... }` passes a parameterized block to an ordinary function.

The golden output is in `expected.txt`.
