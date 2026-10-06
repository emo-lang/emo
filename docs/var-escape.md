# The `var`-escape rule

Emo's Syntax section states: `var` bindings are block-scoped, and
capturing one in a closure that can outlive its block is a compile
error. This document records how the compiler (step 08, `emo_check`)
decides when a capture is an error.

## The rule as implemented

The checker's flow environment tracks two pieces of information for
every binding:

- `depth` — the nesting depth of the block that introduced the binding
  (the program is depth 0; each `if` / `case` / arrow-block body is one
  level deeper);
- `block_depth` — the depth at which the innermost enclosing arrow
  block was *written* (absent, `-1`, outside any arrow block).

A reference to a `var` is a compile error (**E4012**) when it appears
inside an arrow block whose definition depth is greater than the
depth of the block that introduced the `var`:

```emo
def probe(flag Bool) Int64 {
  if flag {
    var x = 1
    if flag {
      const g = -> {
        return x      // error[E4012]: the var `x` cannot be captured ...
      }
      return g()
    }
  }
  return 0
}
```

## The approximation, and what it does not catch

This is the conservative-but-simple approximation the plan called for,
not a borrow checker:

- A `var` and an arrow block in the *same* block are accepted
  (`var x = 1` next to `const g = -> { return x }`), even though `g`
  could in principle be returned. The checker does not track whether
  the block value escapes.
- A `var` captured from the same depth as the arrow block is likewise
  accepted.

The rule as implemented is therefore narrower than the README's
worst-case reading: it rejects exactly the captures where the `var`'s
block provably encloses the arrow block's definition — the shape where
the closure outlives the variable by construction. Everything else is
left to runtime discipline (`Box` is the intended carrier for
long-lived mutable state).

## Why `Box` is unaffected

`Box` values are immutable references; capturing a `const` bound to a
`Box` in any closure is always sound, which is why the README points
at `Box` as the way for closures to hold long-lived mutable state.
