# The OCaml backend

`emo build --target ocaml` emits one OCaml source file and compiles it
with the OCaml toolchain into a standalone binary. It is the backend that
builds Emo itself, and the one target whose build needs a toolchain
beyond the system `cc`: `ocamlfind` with the `unix` and `ssl` packages.
The default target is `c` — see [`docs/c-backend.md`](c-backend.md).

## The pipeline

```
parse → check → lower (Emo_ir) → specialize → emit OCaml → ocamlopt → binary
```

The mid-level IR (`Emo_ir`, `src/emo_ir`) and the specialization pass
(`Emo_ir.specialize`) are shared with every other backend; they are
described in [`docs/c-backend.md`](c-backend.md). What is specific to
this backend is emission and toolchain:

- **Emission** (`Emo_codegen.emit`) prints one OCaml source file. Dynamic
  code compiles to `Emo_eval.value`-passing functions calling the target
  runtime (`src/emo_codegen/ocaml/emo_ocaml_runtime.ml`); specialized
  functions compile to native OCaml types — unboxed `int`/`float`/`bool`
  arithmetic, direct calls.
- **The CLI** (`emo build --target ocaml`) writes `main.ml` and
  `emo_ocaml_runtime.ml` into `.emo-build/`, compiles the runtime on its
  own, and links the program against it with `-open Emo_ocaml_runtime`
  (`ocamlfind ocamlopt -package unix,ssl`). The runtime rides the
  compiler as generated data (step 25), so the build never looks up an
  `emo_runtime.cmxa` in a host build tree.

## Stage A: emitting OCaml source

The plan left one implementation choice open: emit OCaml **source text**,
or construct OCaml **module trees** in memory (via the compiler
libraries) and compile those. Step 14 ships source emission:

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

Revisit only if another target wants to share the constructed-tree path —
the IR, not the emitter, is the layer backends have in common.

## C FFI

The binding surface is `foreign def`; its capability table and the `c`
backend's direct-ABI route are in
[`docs/c-backend.md`](c-backend.md):

```emo
foreign def sqrt(x Float64) Float64 = "sqrt"
```

The OCaml backend compiles through generated wrappers: a raw OCaml
external receives boxed `value` arguments (wrong for a C `double`), and
symbol names like `sqrt` collide with primitives the OCaml compiler
inlines (with a broken encoder on ARM64 macOS). `emo build` therefore
generates a C wrapper per binding — `.emo-build/ffi_stubs.c` — that
unboxes at the boundary (`Double_val` / `String_val` / `Bool_val` in,
`caml_copy_double` / `caml_copy_string` / `Val_bool` out), and takes
`Float64`, `String`, and `Bool` only.

The other FFI tiers stay with the `c` backend: `Int64` parameters, `Void`
returns, struct shapes, and callbacks all refuse on `ocaml` at check time
(E4200), as does anything outside the marshaling tier. Link additional C
libraries with `--cclib` (`emo build main.emo --cclib m`), which adds
`-l<lib>` to the link; a cclib naming an existing file enters the build's
cache key by content. `foreign def` runs only in compiled programs — the
interpreter refuses it with E3009.
