# Examples

Each directory is a runnable demo project. Every program's compiled
binary matches the interpreter byte-for-byte (asserted by the
`bootstrap` test suite); the demos here are chosen to show the
language's design, not just its features.

## The guided tour

- **[`language_tour/`](language_tour/)** — the core ideas in one
  narrated program: classes as immutable value types, structural
  interfaces, enums with the tuple-tag idiom, the mutability layers,
  and trailing blocks. Start here.
- **[`pipeline/`](pipeline/)** — concurrency as an assembly line:
  `do` / `<-` / `receive` with deterministic output from concurrent
  processes.
- **[`tcp_echo/`](tcp_echo/)** — direct-style networking: a server and
  a client in one program, with the standard library resolved through
  the registry.
- **[`numerics/`](numerics/)** — the native backend: `foreign def` C
  bindings and a specialized numeric kernel, compiled to one binary.

## Acceptance examples

- **[`fib/`](fib/)** — recursion, tail calls, and an arrow function.
- **[`hello_world/`](hello_world/)** — the smallest program.
- **[`objects/`](objects/)** — classes, enums, interfaces, equality.
- **[`shop/`](shop/)** — the module system: the directory tree is the
  module tree, with an `internal/` private subtree.
- **[`http_roundtrip/`](http_roundtrip/)** — an HTTP server and client
  round-trip on localhost in one direct-style program.

Each demo that produces deterministic output carries an
`expected.txt`; run the program and compare.
