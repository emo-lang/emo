# CHECK

Pending design decisions — deliberately kept out of the README until they are settled.

- Mixin mechanism: include syntax, single vs. multiple includes, name-collision rules.
- How a process obtains its own pid (needed for the reply pattern), and the pid's type-annotation spelling.
- Exception catching syntax (`raise` is decided; the catch form is not).
- String escape rules, and whether raw strings are needed.
- Numeric literal formats: hexadecimal, binary, digit separators (decimal-only for now).
- C FFI binding-surface syntax (blocks step 13's FFI task).
- Package management:
  - Manifest file name.
  - Lockfile name.
  - Scope prefix format.
  - Version-range expression for dependencies (exact-only for now).
  - Binary / CLI tool distribution mechanism.
