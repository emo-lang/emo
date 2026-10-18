# 各 target 的运行方式

本文用一个脚手架项目 `demo` 走遍所有编译 target，说明每个产物如何运行。解释器不是 target：`emo run` 直接把模块树交给求值器，而 `emo build` 为指定 target 产出文件——`c`（默认）、`ocaml`、`typescript`、`browser`、`wasm`、`beam`、`riscv64`。

以下命令均在参考主机上端到端跑通（Node 26、OTP 29、QEMU 11.1、clang 21）。

## 脚手架

```console
$ emo new demo
created demo — next: cd demo && emo run main.emo, or emo test
```

生成的结构：

```
demo/
├── package.emo        # name、version、targets、deps
├── main.emo           # greet + println("Hello, world!")
├── test/greet.emo
└── .gitignore         # .emo-build/
```

`package.emo` 初始为 `targets = ["ocaml", "c"]`。这个字段有两个作用：该包作为**依赖**被别人使用时，目标不在列表里的构建会在发射前被解析门拒绝；`emo emoji build` 也只构建列表里的 target。直接对项目自己的入口执行 `emo build --target X <entry>` 不受它阻挡——下面七个 target 都能用默认脚手架直接构建。要让包在所有后端可构建，就声明全部：

```emo
targets = ["ocaml", "c", "typescript", "browser", "wasm", "beam", "riscv64"]
```

构建前先按 target 检查环境：

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

## 七个 target 一览

| Target | 构建 | 产物 | 运行 |
| --- | --- | --- | --- |
| 解释器（非 target） | 无 | — | `emo run main.emo` |
| `c`（默认） | `emo build main.emo` | 原生可执行文件 `main` | `./main` |
| `ocaml` | `emo build --target ocaml main.emo -o demo-ocaml` | 原生可执行文件 | `./demo-ocaml` |
| `typescript` | `emo build --target typescript main.emo -o demo-ts` | 单文件 `demo-ts.ts` | `node demo-ts.ts` |
| `browser` | `emo build --target browser main.emo -o app` | 单文件 `app.js` | 页面里 `<script src="app.js">` |
| `wasm` | `emo build --target wasm main.emo -o demo-wasm` | `demo-wasm.wasm` + `.wat` | 提供 `emo` imports 的 JS 宿主 |
| `beam` | `emo build --target beam main.emo -o demo` | `demo.core` + `demo.beam` | `erl -noshell -pa . -eval 'demo:main(), ...'` |
| `riscv64` | `emo build --target riscv64 main.emo -o demo-riscv` | freestanding ELF | `qemu-system-riscv64 ... -kernel` 或 `emo run --target riscv64` |

## 解释器

```console
$ emo run main.emo
Hello, world!
$ emo test
ok test.greet.test_greet
1 test, 1 passed
```

`emo run` 直接对模块树求值，不产生产物。`emo build` 的 `--target` 不是运行方式；`emo run --target` 今天只支持 `riscv64`。

## `c`（默认 target）

```console
$ emo build main.emo            # 输出名默认取入口的文件名 stem：main
built main
$ ./main
Hello, world!

$ emo build main.emo -o demo-c
$ ./demo-c
```

产物是独立原生二进制，不需要 OCaml runtime，唯一要求是系统 `cc`。生成的 `main.c`、`emo_c_runtime.c/.h` 和按内容哈希命名的缓存都在 `.emo-build/` 下；程序未变时复用 `cache-*` 并报告 `(cached)`。

## `ocaml`

```console
$ emo build --target ocaml main.emo -o demo-ocaml
built demo-ocaml
$ ./demo-ocaml
Hello, world!
```

该 target 需要 OCaml 工具链：`ocamlfind` 加 `unix`、`ssl` 两个包（opam switch 具备）。`emo` 把 `main.ml` 和 `emo_ocaml_runtime.ml` 写进 `.emo-build/`，先编译 runtime，再用 `-open Emo_ocaml_runtime` 链接程序。它是唯一在 `cc` 之外还需要另一套工具链的 target。

## `typescript`

```console
$ emo build --target typescript main.emo -o demo-ts
built demo-ts.ts
$ node demo-ts.ts
Hello, world!
```

产物是一个自包含的 `.ts` 文件：TypeScript runtime 前导加程序本身。没有 `tsc` 步骤，也没有 `package.json`；由 Node 自带的类型剥离运行（Node 22.6 起可用 `--experimental-strip-types`，23.6 起默认开启）。运行时是 Node 宿主——进程、socket、HTTP 都可用——而 `dom_*` 系列会被按名拒绝。

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

- 产物是普通脚本：没有 `import`、没有 `require`、不碰 `process`。用 `<script>` 引入即执行。
- 页面宿主提供 `document`/`window`、按行缓冲的 `console` 输出，以及十三个 `dom_*` 调用。挂载点是 `#emo-root`，没有则退回 `document.body`。
- 构建需要 Node >= 22.13，用 `module.stripTypeScriptTypes` 剥掉 bundle 里的类型；浏览器本身不需要任何东西。
- 进程（`do`、`<-`、`receive`）和 `dom_*` 之外的 runtime 能力都会在发射时以点名诊断拒绝。服务端渲染走 `ui_ssr`，不需要这个 target。

## `wasm`

```console
$ emo build --target wasm main.emo -o demo-wasm
built demo-wasm.wasm
$ ls demo-wasm.*
demo-wasm.wasm  demo-wasm.wat
```

产物是一个 **WasmGC** 模块（值用 GC struct/array 表示），外加一份可读的 `.wat`。它不是 WASI 可执行文件：`println`、异常和浮点格式化都是宿主 import，模块恰好有三个：

| Import | 签名 | 用途 |
| --- | --- | --- |
| `emo.println` | `(i32 ptr, i32 len) -> ()` | 从线性内存打印一行 |
| `emo.abort` | `(i32 ptr, i32 len) -> ()` | 未捕获异常 / abort |
| `emo.float_str` | `(f64) -> (i32 ptr, i32 len)` | 按 `%g` 规则把浮点格式化进内存 |

导出只有 `main`（入口，实例化后调用）和 `mem`（宿主解码字符串所需的线性内存）。因此运行它意味着自己提供 `emo` 宿主。下面是 Node 宿主（`run-wasm.mjs`）：

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

要点：

- 宿主必须支持 **WasmGC**（Node 22+ 的 V8 默认支持）。只支持 MVP 或只有 WASI 的运行时跑不了这个模块。
- `mem` 在实例化之后才存在，而 `start` 段在实例化期间执行。宿主回调要放在闭包变量后面，等 `WebAssembly.instantiate` 完成后再赋值。
- 没有 argv、文件系统和网络。纯计算和 `println` 可用；该子集之外的 stdlib 包会被解析门拒绝。
- 仓库里的 `runtime/wasm/` 是另一回事：它是用 Emo 写的 WebAssembly 解码/解释器，覆盖 MVP 和少数扩展。它明确**不能**运行 `emo build --target wasm` 发射的 GC 模块。

## `beam`

```console
$ emo build --target beam main.emo -o demo
built ./demo.beam
$ ls demo.*
demo.beam  demo.core
```

- 编译器发射 Core Erlang 文本（`demo.core`），再调用系统 `erlc` 汇编成 `demo.beam`。`erlc` 必须在 `PATH` 上。
- **模块名是输出文件的 stem**（`erlc` 要求 `.core` 的 stem 等于模块 atom），且必须是合法的 BEAM atom：小写字母开头，后接字母、数字、`_` 或 `@`。用 `-o demo`，不要用 `-o demo-beam`；后者会以 65 退出并解释这条规则。
- 入口是导出的 `main/0`，这样运行：

```console
$ erl -noshell -pa . -eval 'demo:main(), erlang:halt(0).'
Hello, world!
```

`-pa .` 把当前目录加入 code path（所以 `demo.beam` 要在那里），`-noshell` 不进入交互 shell，`erlang:halt(0)` 显式结束 VM——没有它 `erl` 会一直挂着。BEAM 金测用的就是这条命令。

- 产物就是标准 `.beam`，可以直接放进 release，或被其他 Erlang/Elixir 模块调用 `demo:main()`。CLI 不生成 escript 或 release。
- Emo 的进程模型映射到 BEAM 原生进程（`do` → `spawn`、`<-` → `!`、`receive` → selective receive），所以这个 target 上的并发是真并发。`foreign def` 和 net/http 包目前会被拒绝。

## `riscv64`

```console
$ emo build --target riscv64 main.emo -o demo-riscv
built demo-riscv.elf
$ qemu-system-riscv64 -machine virt -nographic -kernel demo-riscv.elf
... OpenSBI 启动信息 ...
Hello, world!
```

或者一条命令完成“构建 + 启动”：

```console
$ emo run --target riscv64 main.emo
```

它把 ELF 写到 `.emo-build/emo_run.elf`，再执行上面的 QEMU 命令。

- 产物是 freestanding ELF：无 OS、无 libc、无默认 runtime。`println` 走 SBI console ecall。
- 构建需要 GNU cross binutils：`riscv64-unknown-elf-as`/`-ld` 或 `riscv64-elf-as`/`-ld`。开发循环需要 `qemu-system-riscv64`。
- 同一镜像能在真实 RISC-V 硬件上启动，OpenSBI 由板子提供；QEMU 只是开发循环的默认 runner，不属于 target 本身。
- `spawn`/`send`/`receive` 和 `foreign def` 在这个 target 上会以清晰诊断拒绝。

## 两个容易踩的坑

1. `.emo-build/` 是构建缓存目录。每次 `-o` 只是把缓存里的产物拷出来；如果改动没有生效，先删掉这个目录（脚手架已把它写进 `.gitignore`）。
2. `emo build --target typescript|browser|wasm|beam|riscv64` 不检查入口项目自己的 `targets` 列表，但会检查每个被 `require` 的**依赖**——没声明该 target 的包会在发射前以解析错误被拒绝。
