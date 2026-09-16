# CHECK

Pending design decisions — deliberately kept out of the README until they are settled.

- Mixin mechanism: include syntax, single vs. multiple includes, name-collision rules.
- Match syntax: pattern matching, destructuring, guards — enum exhaustiveness checking depends on it.
- Exception catching syntax (`raise` is decided; the catch form is not).
- String escape rules, and whether raw strings are needed.
- Mutable-cell primitive: keyword and method names.
- Package management:
  - Manifest file name.
  - Lockfile name.
  - Scope prefix format.
  - Version-range expression for dependencies (exact-only for now).
  - Binary / CLI tool distribution mechanism.
  - CLI command names.
