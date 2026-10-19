# Running Every Target

This guide walks one scaffolded project, `demo`, through every compilation target and shows how each artifact is run. The interpreter is not a target: `emo run` evaluates the module tree directly, while `emo build` produces an artifact for a named target — `c` (the default), `ocaml`, `typescript`, `browser`, `wasm`, `beam`, or `riscv64`.

Every command below was run end to end on the reference host (Node 26, OTP 29, QEMU 11.1, clang 21).

## The scaffold

```console
$ emo new demo
created demo — next: cd demo && emo run main.emo, or emo test
```

The scaffold writes:

```
demo/
├── package.emo        # name, version, targets, deps
├── main.emo           # greet + println("Hello, world!")
├── test/greet.emo
└── .gitignore         # .emo-build/
```

`package.emo` starts with `targets = ["ocaml", "c"]`. That field has two jobs. When the package is consumed as a **dependency**, a build whose target is not in the list is refused by the resolution gate before any emission. `emo emoji build` also builds exactly the declared list. A direct `emo build --target X <entry>` on the project's own entry file is not blocked by it — all seven targets below build from the default scaffold. A package meant to build everywhere declares all of them:

```emo
targets = ["ocaml", "c", "typescript", "browser", "wasm", "beam", "riscv64"]
```

Check the environment per target before building:

```console
$ emo doctor
emo v0.26.1018-alpha
stdlib: embedded in the binary
c:          ok (Apple clang version 21.0.0) — compiles and runs
ocaml:      ok — ocamlfind with the unix and ssl packages found
typescript: ok (v26.12.0)
browser:    ok (v26.12.0)
beam:       ok
wasm:       ok — no external tools needed
riscv64:    ok (QEMU emulator version 11.1.2)
```

## The seven targets at a glance

| Target | Build | Artifact | Run |
| --- | --- | --- | --- |
| interpreter (not a target) | none | — | `emo run main.emo` |
| `c` (default) | `emo build main.emo` | native executable `main` | `./main` |
| `ocaml` | `emo build --target ocaml main.emo -o demo-ocaml` | native executable | `./demo-ocaml` |
| `typescript` | `emo build --target typescript main.emo -o demo-ts` | one `demo-ts.ts` | `node demo-ts.ts` |
| `browser` | `emo build --target browser main.emo -o app` | one `app.js` | `<script src="app.js">` in a page |
| `wasm` | `emo build --target wasm main.emo -o demo-wasm` | `demo-wasm.wasm` + `.wat` | a JS host providing the `emo` imports |
| `beam` | `emo build --target beam main.emo -o demo` | `demo.core` + `demo.beam` | `erl -noshell -pa . -eval 'demo:main(), ...'` |
| `riscv64` | `emo build --target riscv64 main.emo -o demo-riscv` | freestanding ELF | `qemu-system-riscv64 ... -kernel` or `emo run --target riscv64` |

## Interpreter

```console
$ emo run main.emo
Hello, world!
$ emo test
ok test.greet.test_greet
1 test, 1 passed
```

`emo run` evaluates the module tree directly and produces no artifact. `emo build` does not accept `--target` as a way to run; `emo run --target` supports only `riscv64` today.

## `c` (the default target)

```console
$ emo build main.emo            # the output stem defaults to the entry's stem: main
built main
$ ./main
Hello, world!

$ emo build main.emo -o demo-c
$ ./demo-c
```

The artifact is a standalone native binary that needs no OCaml runtime; the only requirement is the system `cc`. The emitted `main.c`, `emo_c_runtime.c/.h`, and content-hashed cache binaries live under `.emo-build/`; an unchanged program reuses `cache-*` and reports `(cached)`.

## `ocaml`

```console
$ emo build --target ocaml main.emo -o demo-ocaml
built demo-ocaml
$ ./demo-ocaml
Hello, world!
```

The target needs the OCaml toolchain: `ocamlfind` with the `unix` and `ssl` packages (an opam switch provides both). `emo` writes `main.ml` and `emo_ocaml_runtime.ml` into `.emo-build/`, compiles the runtime first, then links the program with `-open Emo_ocaml_runtime`. This is the only target that needs a toolchain beyond `cc`.

## `typescript`

```console
$ emo build --target typescript main.emo -o demo-ts
built demo-ts.ts
$ node demo-ts.ts
Hello, world!
```

The artifact is one self-contained `.ts` file: the TypeScript runtime prelude plus the program. There is no `tsc` step and no `package.json`; Node's own type stripping runs it (available behind `--experimental-strip-types` from Node 22.6, on by default from 23.6). The runtime is the Node host — processes, sockets, and HTTP work — while the `dom_*` family is refused by name.

## `browser`

```console
$ emo build --target browser main.emo -o app
built app.js
```

```html
<!doctype html>
<html>
  <body>
    <div id="emo-root"></div>
    <script src="app.js"></script>
  </body>
</html>
```

- The artifact is a plain script: no `import`, no `require`, no `process`. Including it with a `<script>` tag runs it.
- The page host supplies `document`/`window`, line-buffered `console` output, and the thirteen `dom_*` calls. The mount point is `#emo-root`, falling back to `document.body`.
- Building needs Node >= 22.13, whose `module.stripTypeScriptTypes` strips the bundle's types. The browser itself needs nothing.
- Processes (`do`, `<-`, `receive`) and every runtime capability outside `dom_*` are refused at emission with a diagnostic that names the capability. Server-side rendering uses `ui_ssr` and does not need this target.

## `wasm`

```console
$ emo build --target wasm main.emo -o demo-wasm
built demo-wasm.wasm
$ ls demo-wasm.*
demo-wasm.wasm  demo-wasm.wat
```

The artifact is a **WasmGC** module (values are GC structs and arrays) plus a readable `.wat` sibling. It is not a WASI executable: `println`, exceptions, and float formatting are host imports. The module has exactly three:

| Import | Signature | Purpose |
| --- | --- | --- |
| `emo.println` | `(i32 ptr, i32 len) -> ()` | print one line from linear memory |
| `emo.abort` | `(i32 ptr, i32 len) -> ()` | uncaught exception / abort |
| `emo.float_str` | `(f64) -> (i32 ptr, i32 len)` | format a float by the `%g` rule into memory |

It exports `main` (the entry, called after instantiation) and `mem` (the linear memory the host must use to decode strings). Running it therefore means supplying an `emo` host. A Node host (`run-wasm.mjs`):

```js
import { readFile } from "node:fs/promises";

const bytes = await readFile(process.argv[2]);
const module = await WebAssembly.compile(bytes);
let mem;
const dec = new TextDecoder();
const instance = await WebAssembly.instantiate(module, {
  emo: {
    println: (ptr, len) => {
      process.stdout.write(dec.decode(new Uint8Array(mem.buffer, ptr, len)) + "\n");
    },
    abort: (ptr, len) => {
      console.error("ABORT: " + dec.decode(new Uint8Array(mem.buffer, ptr, len)));
      process.exit(1);
    },
    float_str: (f) => {
      const encoded = new TextEncoder().encode(String(f));
      new Uint8Array(mem.buffer, 60000, encoded.length).set(encoded);
      return [60000, encoded.length];
    },
  },
});
mem = instance.exports.mem;
instance.exports.main();
```

```console
$ node run-wasm.mjs demo-wasm.wasm
Hello, world!
```

Points to keep in mind:

- The host must support **WasmGC** (Node 22+ enables it in V8 by default). An MVP-only runtime, or a WASI-only one, cannot run the module.
- `mem` exists only after instantiation, while the `start` section runs during instantiation. Keep host callbacks behind a closure variable assigned after `WebAssembly.instantiate` resolves.
- There is no argv, filesystem, or network. Pure computation and `println` work, and the pure standard-library packages run — the format packages, `float`, `math`, `plot`, `sql`, `sync`, `slog`; anything needing a process, file, socket, or FFI is refused by the resolution gate.
- The in-repo `runtime/wasm/` is a different thing: an Emo-written WebAssembly decoder/interpreter covering the MVP and a few extensions. It explicitly cannot run the GC modules `emo build --target wasm` emits.

## `beam`

```console
$ emo build --target beam main.emo -o demo
built ./demo.beam
$ ls demo.*
demo.beam  demo.core
```

- The compiler emits Core Erlang text (`demo.core`) and invokes the system `erlc` to assemble `demo.beam`. `erlc` must be on `PATH`.
- **The module name is the output file's stem** (`erlc` requires the `.core` stem to equal the module atom), and it must be a valid BEAM atom: a lower-case letter followed by letters, digits, `_`, or `@`. Build with `-o demo`, not `-o demo-beam`; the latter exits 65 and explains the rule.
- The entry is the exported `main/0`. Run it with:

```console
$ erl -noshell -pa . -eval 'demo:main(), erlang:halt(0).'
Hello, world!
```

`-pa .` adds the current directory to the code path (so `demo.beam` must be there), `-noshell` skips the interactive shell, and `erlang:halt(0)` ends the VM explicitly — without it `erl` keeps running. This is the command the BEAM golden tests use.

- The artifact is an ordinary `.beam`, ready for a release or for another Erlang/Elixir module to call `demo:main()`. The CLI does not generate an escript or a release.
- Emo processes map onto native BEAM processes (`do` to `spawn`, `<-` to `!`, `receive` to selective receive), so concurrency is real on this target. `foreign def` and the net/http packages are refused for now; the pure standard-library packages — `slog` among them — run.

## `riscv64`

```console
$ emo build --target riscv64 main.emo -o demo-riscv
built demo-riscv.elf
$ qemu-system-riscv64 -machine virt -nographic -kernel demo-riscv.elf
... OpenSBI boot messages ...
Hello, world!
```

Or build and boot in one command:

```console
$ emo run --target riscv64 main.emo
```

It writes the ELF to `.emo-build/emo_run.elf` and runs the QEMU command above.

- The artifact is a freestanding ELF: no OS, no libc, no default runtime. `println` goes through the SBI console ecall.
- Building needs the GNU cross binutils: `riscv64-unknown-elf-as`/`-ld` or `riscv64-elf-as`/`-ld`. The development loop needs `qemu-system-riscv64`.
- The same image boots on real RISC-V hardware, where the board supplies OpenSBI; QEMU is the default runner for the loop, not part of the target.
- `spawn`/`send`/`receive` and `foreign def` are refused on this target with clear diagnostics — and it stays the one target that refuses `Map`.

## Two things that trip people up

1. `.emo-build/` is the build cache. Every `-o` merely copies the cached artifact out; if a change does not appear, remove that directory first (the scaffold already ignores it in `.gitignore`).
2. `emo build --target typescript|browser|wasm|beam|riscv64` does not check the entry project's own `targets` list, but it does check every `require`d **dependency** — a package that does not declare the target is refused before emission, as a resolution error.
