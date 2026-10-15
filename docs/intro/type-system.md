# Type System

Emo is gradually typed: **types are dynamic at runtime, but statically checked at compile time**.

- Runtime semantics are dynamically typed — every value carries a type tag. This aligns natively with BEAM and keeps everyday code free of type ceremony.
- **Integer types are width-explicit: the default integer type is `Int64`.** It is 64-bit two's complement with wrap-around — arithmetic is performed modulo 2⁶⁴, so overflow behaves identically whether a program runs natively, on Wasm, on the BEAM, or on bare metal. Integer literals without type declarations are `Int64`; there is no width-less `Int` spelling (see `docs/numeric-width.md`).
- **Float types are width-explicit: the default float type is `Float64`.** It is IEEE 754 binary64 on every target, so floating-point behavior is identical everywhere. Float literals without type declarations are `Float64`; there is no width-less `Float` spelling.
- **Numeric literals** are decimal, hexadecimal (`0xFF`), binary (`0b1010_1010`), or octal (`0o755`), with `_` as a digit separator (`1_000_000`). There is no leading-zero octal and no width suffix — bare literals stay `Int64`/`Float64`.
- The compiler has a built-in type-checking pass. Type declarations are optional across the language — except on function signatures, where parameter types are explicit and an omitted return type declares Void — and code without them is still inferred and checked, reporting only errors that are certain; code with them is checked strictly.
- Typing is structural, and an `is` test narrows — after `if user.is(Admin)`, `user` is an `Admin` inside the branch, and never past it — matching duck-typing intuition.
- There is no generics machinery: no generic definition syntax and no type-constraint system. Parameterized types exist only as type-declaration vocabulary (e.g. `Array[User]`, `Map[String, Int64]`, `Box[Int64]`) serving the checker and library signatures; application code relies on inference and rarely sees any type spelling at all. A parameter that receives a block is declared `Block`.
- The container types also take a bare spelling — `List`, `Box`, `Map`, `ArrayBuilder` — meaning "any elements": a `Map` parameter accepts a `Map[String, Int64]` as readily as a `Map[Int64, User]`, and values read back from it are checked progressively. A bare `ArrayBuilder` is the one of the four whose element type is not simply "any": it stays unknown until the first statically-typed `push` settles it, and every later `push` is checked against that.
- Strictness defaults high and can be relaxed explicitly.
- Type information feeds back into performance: modules with sufficiently complete type knowledge can be specialized (unboxed representations, direct dispatch) on the `ocaml` and `c` backends.
