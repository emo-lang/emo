# The C backend

`emo build`'s default target emits C source, compiles it with the system
`cc`, and links a standalone binary that carries Emo's own C runtime — no
OCaml toolchain, no OCaml runtime. It is the self-contained hosted
backend of step 23. The other hosted backend, `--target ocaml`, emits
OCaml and is described in [`docs/ocaml-backend.md`](ocaml-backend.md).

## The pipeline

```
parse → check → lower (Emo_ir) → specialize → emit C → cc → binary
```

- **`Emo_ir`** (`src/emo_ir`) is the mid-level IR every backend lowers
  to. It is a program of named functions over typed values: each
  expression carries the step 09 checker's type, qualified references
  are resolved to module-qualified names, and class method tables are
  explicit. Adding a backend means lowering from the IR, never from the
  AST again (step 15's targets).
- **Specialization** (`Emo_ir.specialize`) is a fixed-point pass over
  the IR: a function specializes when every value in it is native
  (parameters, locals, intermediates) and its calls go only to other
  specialized functions. Specialized functions keep their dynamic
  wrapper, so call sites without type declarations and first-class
  references still work.
- **Emission** (`Emo_codegen.C.emit`, `src/emo_codegen/emo_c.ml`) prints
  one C translation unit plus `emo_defs.h`. Native types cross as C
  scalars; dynamic code lowers to the tagged-word value model of the
  runtime.
- **The CLI** (`emo build --target c`) writes `main.c`,
  `emo_c_runtime.c`, `emo_c_runtime.h`, and `emo_defs.h` into
  `.emo-build/` and runs one `cc -O2 -std=c11` invocation over them. The
  result is a single executable; building a package is just `emo build` —
  there is no separate install step.

## The runtime

The C runtime (`src/emo_codegen/c/emo_c_runtime.c` and `.h`) is ordinary
C compiled by the same `cc` invocation as the emitted program. It carries
the dynamic value model (one tagged word, cell kinds in the header word),
the string layout, the reference-counting discipline over the
identity-bearing objects, and the scheduler. The runtime is carried as
generated data inside the compiler (step 25), so a build looks nothing up
beside the `emo` binary. The decisions are recorded in CHECK.md and
`plan/step-23-c-target.md`.

## C FFI

The binding surface is `foreign def`, which names the C symbol:

```emo
foreign def sqrt(x Float64) Float64 = "sqrt"
```

The C backend calls the symbol directly through the C ABI — no wrapper
generator. The capability table (CHECK.md) is per target, and `c` is the
widest tier:

- **Parameters** may be `Float64`, `String`, `Bool`, or `Int64` (the
  pointer-sized carrier for opaque handles), a single-method interface (a
  callback), or a struct shape.
- **Returns** may be `Float64`, `String`, `Bool`, `Int64`, `Void` — the
  shape of a fire-and-forget call — or a tuple of marshaling types.
- **Struct shapes** cross by value. A tuple parameter is a C `struct`
  whose members are the element types in order, and a nested tuple nests
  a struct within the struct; a carrier class is the same shape spelled
  with a class — every field assigns a same-named init parameter, in
  order, and every field stays in the tier. A compound **return** crosses
  back as a tuple; a class-typed return refuses ("name the tuple"),
  because a C value cannot carry an object identity. Identical layouts
  share one `typedef`.
- **Callbacks**: an interface-typed parameter expands to two adjacent C
  parameters, the function pointer and an opaque `void *userdata`. The
  callback's C signature is the method's marshaled parameters followed by
  the trailing `void *userdata`, and the generated trampoline dispatches
  through `emo_send`. Interfaces stay single-method and in the marshaling
  tier.

Every externally linkable declaration of the program — its defs, foreign
symbols, tail-call clusters, class constructors and methods, and the
struct typedefs — is also written to `.emo-build/emo_defs.h`, so an FFI
shim compiles against the compiler's own declarations: a signature that
drifts breaks at cc time in both directions instead of silently at run
time.

Anything else refuses at check time (E4200). Link additional C libraries
with `--cclib` (`emo build main.emo --cclib m`): bare names become `-l`
flags, `-`/`/`-prefixed values pass verbatim, and a cclib naming an
existing file (a shim object) enters the build's cache key by content, so
editing it invalidates the cached binary. `foreign def` runs only in
compiled programs — the interpreter refuses it with E3009. The `ocaml`
backend honors `Float64`/`String`/`Bool` only, through generated C stubs
([`docs/ocaml-backend.md`](ocaml-backend.md)).

## Package-carried native code

A package that binds a C library keeps the whole link inside its
manifest and its tree, so consumers pass no flags at all:

- **The manifest's optional `link` field names the system libraries.**
  `link = ["sqlite3"]` turns into `-lsqlite3` on the c target's cc
  invocation. Bare names only — a flag- or path-shaped entry is refused
  at manifest read (`--cclib` keeps the verbatim-flag role).
- **`pkg_config` names pkg-config modules; `frameworks` names macOS
  frameworks.** The modules' `--cflags` join the compile and their
  `--libs` join the link, and each framework becomes `-framework NAME`.
  Both fields hold bare names, refused at manifest read when an entry is
  empty, flag-shaped, or path-shaped, so no flag fragment rides a
  manifest. A module pkg-config cannot resolve fails the build with 69
  and the install prompt, not raw compiler output.
- **`.c`, `.h`, and `.m` files in the package's tree are part of the
  package.** They are collected, checksummed, embedded in the compiler's
  bundled stdlib, and published beside the `.emo` modules, and the c
  target compiles a dependency's C and Objective-C sources in the
  program's one cc invocation. This is where the out-parameter shims
  live: a package's `foreign def`s bind the shim's exact-ABI wrappers
  (as the `sqlite3` package does), and the shim compiles against the
  generated `emo_defs.h`, so a signature drift breaks at cc time in
  both directions. Objective-C is compiled under ARC (`-fobjc-arc`),
  the c target's fixed policy for `.m`; clang ignores the flag on `.c`
  translation units, so one command still builds both.
- **Only the c target honors a package's native inputs.** The
  manifest's `targets` refuses the package at resolution on the other
  targets; a package that declares the current target while carrying
  native sources, `link`, `pkg_config`, or `frameworks` makes the build
  refuse with E5007 rather than silently dropping them. Sources enter
  the build's cache key by content, libraries and resolved flags by
  name, so changing a pkg-config module's flags rebuilds.

A target that cannot honor a `foreign def` refuses it at check time
rather than compiling a broken call: today the c target and the `ocaml`
backend can, while `wasm`, `typescript`, `beam`, and the freestanding
`riscv64` (until C interop lands) refuse. Per-target availability is also
declared through the manifest's `targets` mechanism, so a package is
rejected at resolution.
