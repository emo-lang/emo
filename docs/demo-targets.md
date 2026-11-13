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
wasm:       ok v26.12.0 — `emo run --target wasm` runs it
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
| `wasm` | `emo build --target wasm main.emo -o demo-wasm` | `demo-wasm.wasm` + `.wat` | a JS host providing the `emo` imports (`emo run --target wasm` runs one under Node with the bundled host) |
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

One flag belongs to the interpreter's own run: `emo run --curfew SECONDS` hands the evaluation a wall-clock deadline. A program reads the clock through the standard library's `time` package, but a runaway program need not cooperate — so the deadline that ends it lives here, in the toolchain: the evaluator checks the deadline every 65,536 steps, and past it the run ends with exit 124 (the number `timeout(1)` answers) and the verdict on stderr. A `--target` artifact does not consult the curfew, and `--curfew` together with `--target` is refused. The flag exists for the playground ([`projects/emo-playground`](../projects/emo-playground)), whose server gives every submission one; nothing else is asked to use it.

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

The artifact is a **WasmGC** module (values are GC structs and arrays) plus a readable `.wat` sibling. It is not a WASI executable: printing, exceptions, float formatting, and the file system are host imports. The module has exactly these:

| Import | Signature | Purpose |
| --- | --- | --- |
| `emo.println` | `(i32 ptr, i32 len) -> ()` | print one line from linear memory |
| `emo.abort` | `(i32 ptr, i32 len) -> ()` | uncaught exception / abort |
| `emo.float_str` | `(f64) -> (i32 ptr, i32 len)` | format a float by the `%g` rule into memory (scratch at 60000) |
| `emo.file_read` | `(i32 ptr, i32 len) -> (i32 tag, i32 size)` | read a whole file; the answer waits for `fetch` |
| `emo.file_write` | `(i32 ptr, i32 len, i32 dptr, i32 dlen) -> (i32 tag, i64 count)` | write a file; the answer waits for `fetch` |
| `emo.fetch` | `(i32 buf, i32 cap) -> i32` | copy the stashed answer into the guest's buffer |
| `emo.os_open` | `(i32 ptr, i32 len, i32 mode) -> (i32 tag, i64 fd)` | open a descriptor (0 read, 1 write, 2 append) |
| `emo.os_read` | `(i64 fd, i64 n) -> (i32 tag, i32 size)` | read up to n bytes; empty string = end of file |
| `emo.os_write` | `(i64 fd, i32 dptr, i32 dlen) -> (i32 tag, i64 count)` | write to a descriptor |
| `emo.os_close` | `(i64 fd) -> (i32 tag, i64 zero)` | close a descriptor |
| `emo.os_list_dir` | `(i32 ptr, i32 len) -> (i32 tag, i32 size)` | list a directory; NUL-separated names, byte-order sorted |
| `emo.os_mkdir` | `(i32 ptr, i32 len) -> (i32 tag, i64 zero)` | create a directory |
| `emo.os_rmdir` | `(i32 ptr, i32 len) -> (i32 tag, i64 zero)` | remove a directory |
| `emo.os_unlink` | `(i32 ptr, i32 len) -> (i32 tag, i64 zero)` | remove a file |
| `emo.os_rename` | `(i32 optr, i32 olen, i32 nptr, i32 nlen) -> (i32 tag, i64 zero)` | rename |
| `emo.os_getcwd` | `() -> (i32 tag, i32 size)` | the working directory |
| `emo.os_chdir` | `(i32 ptr, i32 len) -> (i32 tag, i64 zero)` | change the working directory |
| `emo.rand_bytes` | `(i64 n) -> (i32 tag, i32 size)` | n bytes from the host's entropy source (Node's CSPRNG), through `fetch` |
| `emo.time_now_ms` | `() -> i64` | the wall clock, UTC epoch milliseconds (the `time` package's clock half) |
| `emo.time_mono_ns` | `() -> i64` | the monotonic clock, nanoseconds floor'd from `performance.now()` |

Every syscall answers `(tag, …)` — tag 0 ok, tag 1 error — and stashes its payload (the file contents, or the whole reason text `file: cannot read …: …` / `os: …: …`, formatted by the host) for the guest's `fetch` call, which copies it into a buffer the guest bump-allocated. Descriptors live in the host; 0/1/2 are stdio, files count from 3. The `time` package's timing half has no import: the driver runs the whole program synchronously inside one call to `main`, so `time.sleep` raises at the call naming the capability.

It exports `main` (the entry, called after instantiation) and `mem` (the linear memory the host must use to decode strings; the guest's bump allocator starts at 65536, so page 0 stays the host's). Running it therefore means supplying an `emo` host — or just `emo run --target wasm main.emo`, which builds and runs the module under Node with the bundled host (`emo doctor` reports whether Node is present).

```console
$ emo run --target wasm main.emo
Hello, world!
```

A hand-rolled host implements exactly the imports above; the smallest one covers the three every module needs (`run-wasm.mjs`):

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
- The **file system is the host's own**: `file`, `os`'s fd/directory half, `bufio`, and `rand` run through the syscalls, with reasons byte-identical with the `ocaml` and `c` targets. There is no argv and no network — anything needing a socket (`net`, `http`) or FFI (`sqlite3`) is still refused by the resolution gate, and `os`'s process half (`fork`, `execv`, `waitpid`, `pipe`, `getpid`, `getppid`, `_exit`) raises at the call, naming the capability: a WasmGC module has no process to fork.
- **A second engine vouches for the shape**: every wasm golden is compile-validated by the wasmtime CLI (`devtools/wasmtime-smoke.sh` — cranelift's validator over the whole module: the GC type hierarchy, the multi-value signatures, the block nesting). Node stays the execution host; wasmtime's CLI cannot supply the custom `emo` imports a non-WASI module needs.
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
