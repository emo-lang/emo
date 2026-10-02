# CHECK

Pending design decisions — deliberately kept out of the README until they are settled.

- Mixin mechanism: include syntax, single vs. multiple includes, name-collision rules.
- Exception catching syntax (`raise` is decided; the catch form is not).
- Whether raw strings are needed. The escape set settled in step 12: `\n \r \t \\ \' \"`.
- Numeric literal formats: hexadecimal, binary, digit separators (decimal-only for now).
- C FFI binding-surface syntax (blocks step 13's FFI task).
- Binary / CLI tool distribution mechanism.
