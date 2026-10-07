# wasm 运行时——如何使用（临时笔记）

> **临时文档。** 这里是对 `runtime/wasm/` 中运行时的使用笔记,不是已落定的设计文档。它只记录运行时今天如何使用,不扩展计划或 README。权威材料是 `runtime/wasm/README.md`、`plan/step-19-wasm-runtime.md`、`plan/step-20-wasm-decoder.md` 和 `plan/step-21-wasm-interpreter.md`。

## 它是什么

它**不是** wasmtime 那种从命令行运行 `.wasm` 文件的工具。它是一个用 Emo 编写、由官方 spec 测试集驱动的 WebAssembly 解释器——解码器、校验器和执行器。目前没有 CLI、没有 WASI、没有 JIT,也无法在自己的包之外使用它。

- 位置:`runtime/wasm/`。
  - 公开入口:`wasm.emo`。
  - 驱动:`main.emo`(decoder smoke)、`spec.emo`(全量 decoder 语料)、`runs.emo` / `runs-smoke.emo`(解释器命令语料)。
  - `internal/` 下的实现:`reader.emo`(字节游标、LEB128、类型栈校验器)、`decode.emo`、`model.emo`、`instance.emo`(实例模型、解释器、链接、`spectest` host)、`store.emo`、`value.emo`、`ints.emo`、`floats.emo`、`runlist.emo`。
- 覆盖范围:MVP 加上 sign-extension、saturating-conversion、bulk-memory、reference-type 和 multi-value 扩展。明确不支持:function references、SIMD、GC、threads、WASI。

## 使用方式

### A. 跑验收闸门

```bash
dune build src/emo_cli/emo.exe            # 先构建 emo

cd runtime/wasm
dune test                  # smoke:40 个 decoder case + 58 条 run 命令 + 各 fixture
dune build @wasm_spec      # 全量 3456 个二进制模块 case(decoder/validator)
dune build @wasm_runs      # 全量 25135 条 run 命令(解释器,约 1 分钟)
```

两个全量 alias 目前都通过:`@wasm_runs` 报告 `claimed 25135, pending 0, failed 0`,`@wasm_spec` 的 smoke 前缀报告 `claimed 40, pending 0, failed 0`。这些 alias 定义在 `runtime/wasm/dune`,因此必须**从 `runtime/wasm/` 目录**执行。

### B. 只做解码与校验(公开面)

`wasm.emo` 只暴露三个定义:

| 函数 | 返回 |
| --- | --- |
| `wasm.smoke()` | 一个标识字符串 |
| `wasm.decode(data Bytes)` | `(ok, phase, offset, message)`;`phase` 为 `"malformed"` 或 `"invalid"`,坏输入**从不抛异常** |
| `wasm.load(data Bytes)` | `(ok, phase, offset, message, handle)`;成功时 `handle` 是模块句柄(注册表下标),失败为 `-1` |

### C. 执行一个模块(内部面)

实例/执行层没有对外 re-export,位于 `internal.instance`:

| 函数 | 说明 |
| --- | --- |
| `instantiate(handle) -> (ok, trap, inst)` | 解析 import、初始化 global/memory/table、铺 element 与 data 段、运行 start 函数 |
| `register_instance(inst, name) -> Int64` | 把实例绑定到 import 命名空间(供其他模块 import) |
| `call(inst, export, args) -> (ok, results, trap)` | 调用导出函数;trap 是值,绝不抛异常 |
| `get_global(inst, name) -> (ok, (kind, bits), trap)` | 读取 global 导出 |
| `describe(handle) -> String` | 已加载模块的一行计数摘要 |

值模型是带标签的 `(kind, bits)` 对:`127=i32`、`126=i64`、`125=f32`、`124=f64`、`112=funcref`、`111=externref`。用 `internal.value.i32/i64/f32/f64(...)` 构造参数,再从 `bits` 读回结果。

一个经过验证的最小宿主程序(放在 `runtime/wasm/` 内):

```emo
// 从磁盘读 .wasm -> 校验 -> 实例化 -> 调用导出。
const bytes  = file_read("demo-fac.wasm").to_bytes()
const loaded = wasm.load(bytes)
println("load ok=" + loaded[0].to_string() + " " + loaded[1])
if !loaded[0] { return 1 }

const inst = internal.instance.instantiate(loaded[4])
if !inst[0] { println("inst " + inst[1]); return 1 }

const r = internal.instance.call(inst[2], "fac", [internal.value.i64(10)])
println("fac(10) = " + r[1][0][1].to_string())   // -> 3628800
```

运行:

```bash
cd runtime/wasm
../../_build/default/src/emo_cli/emo.exe run your.emo
```

`emo run` 必须在包目录内调用,`wasm.*` 与 `internal.*` 才能解析;从仓库根目录跑 `runtime/wasm/fac-fixture.emo` 也可以。

跨模块链接见 `link-fixture.emo`:实例化模块 A,`register_instance(instA, "A")`,再实例化模块 B,B 的 import 就会通过注册命名空间解析。`host-fixture.emo` 演示内置的 `spectest` host(print/global/table/memory)。

## 限制(为什么它不是 wasmtime)

1. **没有 CLI,也没有 argv。** `plan/step-20` 推迟了 argv,所以每个驱动都把路径写死在源码里(如 `cli.run("testdata/cases.smoke.txt")`)。
2. **`internal/` 是子树私有的**(由编译器强制)。包外代码看不到 `instantiate` / `call`,所以**外部包根本无法执行模块**——只能 `decode` / `load`。在 `/tmp` 里建一个包,连 `wasm.load` 都会以 `E4003` 失败(未声明依赖且 `wasm.*` 不在作用域)。要让它对外可用,需要在 `wasm.emo` 里 re-export 一层执行 API。
3. **import 只有两个来源:** 注册命名空间和 `spectest` host。没有 WASI,也没有 `emo` host 模块,所以它**无法运行 `emo build --target wasm` 的产物**。那正是计划里的 self-hosting 退出标准,需要 GC 类型,不在本阶梯内。
4. **它不是可发布的包。** `package.emo` 声明 `deps {}`,依赖走中心 registry 的精确版本,没有文档化的 path 依赖;这个包是仓库内的 fixture,计划说它只有通过 vendored suite 且 Emo 达到 1.0 之后才离开本仓库。

## 怎样才可用

- 从 `wasm.emo` re-export 一层执行面(如 `instantiate`、`call`、`get_global`),并定义稳定的 host 接口。
- 让 `emo` CLI 或独立 driver 能访问 argv(step 20 留下的空档),或增加 `emo wasm run foo.wasm` 子命令。
- 想运行真实世界的 `.wasm`,还需补 WASI / `emo` host 模块以及更多提案(GC 等)。
