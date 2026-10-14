# Modules and Visibility

Emo's module system is fully structural: no `import`, no `export`, no visibility keywords, and no naming conventions carrying visibility. **The directory tree is the module tree:**

```
shop/
  order.emo           # module shop.order
  pricing.emo         # module shop.pricing
  internal/
    discounts.emo     # module shop.internal.discounts — subtree-private
  checkout.emo        # module shop.checkout
```

- **The path is the module.** A file automatically becomes the module at its path — no registration, no declaration.
- **References are qualified paths.** Nothing is imported; paths are used directly, like URLs. When a path is long, an ordinary `const` binding aliases it — no new syntax, since an import statement was only ever an alias assignment:

  ```emo
  const order = shop.order

  def checkout(cart Cart) Decimal {
    const total = order.total(cart)
    return total
  }
  ```

- **Visibility is structural.** Definitions inside functions and blocks are private by scoping; module-level definitions are public (addressable by their qualified paths); and an `internal/` directory is subtree-private, enforced by the compiler — everything under `shop/internal/` is usable within `shop` and its descendants, and a compile error anywhere else.
- **Type names are module-qualified paths, exactly like values.** A type reference is a path: `ui.VNode` names `ui.emo`'s `VNode` from another module, a bare `Order` names the current module's own type, and package-relative forms work as they do for values (`internal.svg.Renderer` inside a package). `is()` narrows across the boundary, and construction follows the same rule — `sync.WaitGroup.new(2)`, `ui.Point.new(...)` — the declaring module loading on first use. Two modules may therefore declare the same type name: they are two distinct types, each addressed by its module. The privacy rule reaches types as it reaches values: a type declared under `internal/` resolves only within its subtree.
- **The dependency graph is explicit.** Path references are the dependency declarations, giving automatic module discovery, incremental compilation, and compile-time cycle detection.
