# Numerics

Foreign C bindings and a fully annotated numeric kernel, compiled to a
standalone binary.

```console
emo build main.emo -o numerics
./numerics
```

(On Linux, link the math library explicitly: `emo build main.emo
--cclib m`.)

What to notice:

- **`foreign def` binds a C symbol.** `sqrt` and `pow` come straight
  from the C math library; the build generates the marshaling wrappers
  and links them in. Only `Float64`, `String`, and `Bool` cross the
  boundary today.
- **This program is compiled-only by design.** The interpreter has no C
  linkage and refuses foreign definitions with a precise error — one
  command, one executable, no runtime download.
- **Types feed performance.** `growth` is fully annotated, so the
  compiler specializes it: unboxed float arithmetic and direct calls.
  Build the same program with `--no-specialize` and compare — the
  `benchmarks/` tree records what that difference is worth.
- The kernels stay idiomatic: recursion is the loop, tuples carry the
  two roots, and interpolation formats the table.
