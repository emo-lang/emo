# The native backend

How `emo build` turns an Emo program into a standalone binary, and the
one open design item step 13 settled: the shape of Stage A's OCaml
emission.

## The pipeline

```
parse → check → lower (Emo_ir) → specialize → emit OCaml → ocamlopt → binary
```

- **`Emo_ir`** (`src/emo_ir`) is the mid-level IR every backend lowers
  to. It is a program of named functions over typed values: each
  expression carries the step 08 checker's type, qualified references
  are resolved to module-qualified names, and class method tables are
  explicit. Adding a backend means lowering from the IR, never from the
  AST again (step 14's targets).
- **Specialization** (`Emo_ir.specialize`) is a fixed-point pass over
  the IR: a function specializes when every value in it is native
  (parameters, locals, intermediates) and its calls go only to other
  specialized functions. Specialized functions keep their dynamic
  wrapper so call sites without type declarations and first-class references still
  work.
- **Emission** (`Emo_codegen`) prints one OCaml source file. Dynamic
  code compiles to `Emo_eval.value`-passing functions calling the
  runtime (`src/emo_runtime`); specialized functions compile to native
  OCaml types — unboxed `int`/`float`/`bool` arithmetic, direct calls.
- **The CLI** (`emo build`) writes the source and C FFI stubs into
  `.emo-build/`, compiles with `ocamlfind ocamlopt`, and links the
  runtime libraries from the compiler's own build tree. The result is a
  single executable; building a package is just `emo build` — there is
  no separate install step.

## Stage A: emitting OCaml source

The plan left one implementation choice open: emit OCaml **source
text**, or construct OCaml **module trees** in memory (via the compiler
libraries) and compile those. Step 13 ships source emission:

- **Source text is one stable contract.** The emitted file is ordinary
  OCaml that the installed toolchain compiles — no dependency on
  compiler-libs internals, whose APIs change between OCaml releases. A
  constructed-tree emitter pins the backend to compiler-libs versions
  and turns every OCaml upgrade into a backend migration.
- **Debuggability is direct.** The generated file sits in
  `.emo-build/main.ml`; a toolchain error points at a readable line in
  a file the user can open.
- **The optimizer still applies.** `ocamlopt` runs the same Flambda /
  Closure middle-end over emitted source as over any other source;
  specialization happens in Emo's own pass (where Emo's type
  knowledge lives), and OCaml handles the machine-level work.
- **Costs.** Parsing and type-checking the emitted file spends time a
  tree emitter would save, and generated code cannot use features that
  only exist at the tree level (cross-module inlining hints). Neither
  matters at the current scale: the whole pipeline for the benchmark
  set is a few hundred milliseconds of toolchain work.

Revisit only if a step 14 target wants to share the constructed-tree
path — the IR, not the emitter, is the layer backends have in common.

## C FFI

The binding surface is `foreign def`:

```emo
foreign def sqrt(x Float64) Float64 = "sqrt"
```

The capability table (CHECK.md) is per target. The **c target** calls
the C symbol directly — no wrapper generator. Its parameters may be
`Int64`, `Float64`, `Bool`, or `String`, and its return may also be
`Void` — the shape of a fire-and-forget call (decided 2026-10-10);
opaque handles ride pointer-sized Int64s. The **OCaml-emitting
backend** compiles through generated wrappers: raw externals receive
boxed `value` arguments (wrong for a C `double`), and symbol names
like `sqrt` collide with primitives the OCaml compiler inlines (with a
broken encoder on ARM64 macOS), so `emo build` generates a C wrapper
per binding — `.emo-build/ffi_stubs.c` — that unboxes at the boundary
(`Double_val` / `String_val` / `Bool_val` in, `caml_copy_double` /
`caml_copy_string` / `Val_bool` out), and takes `Float64`, `String`,
and `Bool` only.

Every externally linkable declaration of the program — its defs,
foreign symbols, tail-call clusters, and class constructors and
methods — is also written to `.emo-build/emo_defs.h`, so an FFI shim
compiles against the compiler's own declarations: a signature that
drifts breaks at cc time in both directions instead of silently at
run time (2026-10-10).

Anything else is refused at check time (E4200). Link additional C
libraries with `--cclib` (`emo build main.emo --cclib m`): bare names
become `-l` flags, `-`/`/`-prefixed values pass verbatim, and a cclib
naming an existing file (a shim object) enters the build's cache key
by content, so editing it invalidates the cached binary. `foreign
def` runs only in compiled programs — the interpreter refuses it with
E3009.

A target that cannot honor a `foreign def` refuses it at check time
rather than compiling a broken call: today the c target and the
OCaml-emitting native backend can, while `wasm`, `typescript`, `beam`,
and the freestanding `riscv64` (until C interop lands) refuse.
Per-target availability is also declared through the manifest's
`targets` mechanism, so a package is rejected at resolution.
