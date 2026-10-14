# Native Builds

`emo build` compiles a program to a standalone native binary — one command, one executable, no separate install step for applications. The default target is `c`: the emitted C compiles with the system `cc`, so a build needs no OCaml toolchain; `--target ocaml` emits OCaml for the backend that builds Emo itself:

```console
$ emo build main.emo -o myapp
built myapp
```

- **The runtime ships inside the binary.** The scheduler and the networking stack are libraries of the backend: a program that spawns processes and serves HTTP runs identically compiled, with no interpreter and no runtime download.
- **The compiled output is held to the interpreter's standard.** Every example compiles to a binary whose output matches `emo run` byte-for-byte — asserted in CI, not assumed.
- **Types feed performance.** Functions whose types are fully known compile to specialized native code — unboxed numbers, direct calls — while regions the checker cannot pin down keep dynamic semantics. `benchmarks/` records the numbers (the same fully type-declared program runs measurably faster specialized than with `--no-specialize`).
- **Builds are incremental.** The build caches by content hash: an unchanged program (and unchanged runtime) rebuilds without invoking the toolchain, and the build reports `(cached)`.
- **C interop is a `foreign def`.** The declaration names the C symbol — the `c` target calls it directly through the C ABI; the `ocaml` target marshals through a generated C wrapper:

  ```emo
  foreign def sqrt(x Float64) Float64 = "sqrt"
  ```

  `Float64`, `String`, and `Bool` cross the boundary today; other types are refused by the checker. Link additional C libraries with `--cclib` (`emo build main.emo --cclib m`). Foreign definitions run only in compiled programs — `emo run` refuses them. A target that cannot honor a `foreign def` refuses it at check time: `c` and `ocaml` honor it, while `wasm`, `typescript`, `beam`, and the freestanding `riscv64` refuse.
- **C calls back into Emo through an interface.** A `foreign def` parameter may name a single-method interface — the callback type. The `c` target passes the C side a generated trampoline plus the object as an opaque `void *userdata`; the callback's C signature is the method's parameters (marshaled like any foreign argument) followed by the trailing `void *userdata`, and invoking it dispatches to the receiver's own method:

  ```emo
  interface Handler {
    def on_click(tag Int64) String
  }

  foreign def set_handler(h Handler) Void = "set_handler"

  set_handler(MyHandler.new())   # the C side calls cb(tag, data) later
  ```

  The callback method's parameters stay in the marshaling tier (`Float64`, `String`, `Bool`, `Int64`), and its return adds `Void`. Two objects of different classes both satisfying the interface each dispatch to their own method — the object rides in the userdata. On targets without the contract the parameter refuses at check time, like any unhonored `foreign def`.
- **Compound data crosses as a struct shape.** A `foreign def` parameter whose type is a tuple — or a carrier class — passes a C struct by value: the element types in order are the layout, a nested tuple nests a struct within the struct, and a class instance contributes its init-assigned fields (the class's shape is its init signature). A compound return comes back as a tuple:

  ```emo
  foreign def stretch(r ((Float64, Float64), Float64)) (Float64, Float64) = "stretch"

  stretch(((1.0, 2.0), 3.0))   # a struct of a struct and a scalar, by value
  ```

  The `c` target declares the same `typedef struct` the C side sees — in `emo_defs.h`, so a shim compiles against the real layouts — and the by-value calling convention is the C compiler's job. Shape fields stay in the marshaling tier; a class-typed return refuses (name the tuple), and so does every target without the mechanism.
- **The default build needs only a C compiler.** The `c` target invokes the system `cc`; `--target ocaml` requires the OCaml toolchain — the same one that builds Emo itself.
