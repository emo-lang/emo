# Shop

The module system demo: the directory tree is the module tree — no
import, no export, no registration.

```console
emo run main.emo
```

Run it from this directory: the working directory is the project root,
and every `.emo` file becomes the module at its path.

What to notice:

- **The path is the module.** `order.emo` is the module `order`;
  referencing it is a plain qualified path — `order.total(cart)` in
  `checkout.emo`. Nothing is imported; paths are used directly.
- **A long path gets an ordinary `const` alias.** `pricing.emo` writes
  `const discounts = internal.discounts` — no import statement was ever
  needed, because an import was only ever an alias assignment.
- **`internal/` is subtree-private, enforced by the compiler.** Every
  module in this tree may use `internal.discounts`; a reference from
  any other project is a compile error. Try it: add
  `print(internal.discounts.seasonal(3))` to another example's program
  and run `emo check` on it.
- **The dependency graph is the references.** `main.emo` depends on
  `checkout` and `pricing`; `pricing` depends on `internal.discounts` —
  discovery, build order, and cycle detection all read the same paths.

Layout:

```
shop/
  main.emo                    # the entry — runs the scenario
  checkout.emo                # module checkout
  order.emo                   # module order
  pricing.emo                 # module pricing
  internal/
    discounts.emo             # module internal.discounts — private
```

The golden output is in `expected.txt`.
