# `wasm` 包

用 Emo 写的 WebAssembly 运行时——正如 wazero 是用 Go 写的运行时。它解码并验证二进制模块,然后执行它:一个骑在核心 spec 的 MVP 加符号扩展、饱和转换、批量内存、引用类型、多值返回五个扩展之上的解释器。验收线是官方 spec 套件,而且已经到达:每条 `assert_malformed` 与 `assert_invalid` 的二进制用例都在正确的阶段被拒绝,供应商化的运行语料里每条 `assert_return` 与 `assert_trap` 都逐位精确应答(25135 条命令,零 pending,零 failed)。

包即边界:内脏住在 `internal/` 之下,别的包能看到的只有这个根。跨过边界的是句柄——模块句柄指认一个已加载的模块,实例句柄指认一次活的实例化——一切失败都以 `(R.error, reason)` 应答,从不 raise。

目标:`["ocaml", "c"]`。参考:[`docs/zh-CN/stdlib/wasm.md`](stdlib/wasm.md) · 示例:`examples/wasm_demo`。

## 引入

`require "wasm"`,manifest 里钉住包:

```emo
deps {
  "wasm" = "0.1.0"
}
```

## 一条程序里的整条阶梯

```emo
case wasm.load(module_bytes(hex)) {
  (R.error, why) -> { println("load " + why) }
  (R.ok, module) -> {
    case wasm.instantiate(module, [("env", "log", -> (args Array[(Int64, Int64)]) {
      println("env log " + args[0][1].to_string())
      return wasm.i64(0)
    })]) {
      (R.error, why) -> { println("inst " + why) }
      (R.ok, inst) -> {
        case wasm.call(inst, "fac", [wasm.i64(10)]) {
          (R.error, trap) -> { println("trap " + trap) }
          (R.ok, results) -> {
            case wasm.as_i64(results[0]) {
              (R.ok, v) -> { println("fac(10) = " + v.to_string()) }
              (R.error, why) -> { println(why) }
            }
          }
        }
      }
    }
  }
}
```

## 表面

```emo
wasm.decode(data Bytes)                       // (Bool, String, Int64, String)——诊断判定
wasm.load(data Bytes)                         // (R, Int64)——验证 + 物化;模块句柄
wasm.instantiate(module Int64, imports Array[(String, String, Block)])  // (R, Int64)——实例句柄
wasm.call(inst Int64, name String, args Array[(Int64, Int64)])          // (R, Array[(Int64, Int64)])
wasm.get_global(inst Int64, name String)      // (R, (Int64, Int64))
wasm.register_instance(inst Int64, name String)  // Int64——绑进 import 命名空间
wasm.describe(module Int64)                   // String——一行计数摘要
wasm.read_memory(inst Int64, ptr Int64, len Int64)   // (R, Bytes)
wasm.write_memory(inst Int64, ptr Int64, data Bytes) // (R, Int64)——写入的字节数
```

`decode` 是判定报告者——`(ok, phase, offset, message)`,phase 是 `"malformed"` 或 `"invalid"`——给想要字节偏移写明白的工具。`load` 是执行面骑的那扇门。

## 值模型

一个 wasm 值是一对 `(kind, bits)` `Int64`——运行时自己的位模式模型,在这里一次写清:

| kind | 含义 | `bits` 携带 |
| --- | --- | --- |
| 127 | `i32` | 无符号 32 位模式 |
| 126 | `i64` | 全 64 位模式 |
| 125 | `f32` | 无符号 32 位模式 |
| 124 | `f64` | 全 64 位模式 |
| 112 | `funcref` | 函数索引,null 为 `-1` |
| 111 | `externref` | 宿主值,null 为 `-1` |

是位模式,不是数:这是 NaN 载荷在 load、store、`reinterpret` 之间逐位存活的唯一方式。构造器造一个,读取器读回来:

```emo
wasm.i32(v Int64)          wasm.i64(v Int64)
wasm.f32(v Float64)        wasm.f64(v Float64)
wasm.i32_from_bits(bits Int64)   // 精确模式构造器,
wasm.f32_from_bits(bits Int64)   // 给 NaN 载荷与逐位精确的活
wasm.f64_from_bits(bits Int64)

wasm.as_i32(v) (R, Int64)  // 带符号读出——i32 走它的 32 位二进制补码,
wasm.as_i64(v) (R, Int64)  // 浮点走自己的模式;kind 不符即错误
wasm.as_f32(v) (R, Float64)
wasm.as_f64(v) (R, Float64)
```

## 宿主接口

`instantiate` 的第二个实参是宿主表——`(module, name, fn)` 三元组,其闭包伺候模块的函数 import。签名统一:闭包收实参数组(`Array[(Int64, Int64)]`),应答一个值;签名无结果的 import 看到返回值被丢弃,想要多于一个结果的 import 无法由这张表伺候(链接拒绝)。

解析序:显式表最先,然后 register 命名空间(`register_instance`),然后 spec 套件点名的内建 `spectest` 宿主——所以一条 `("spectest", "print_i32")` 条目会为那个 import 覆盖内建宿主。

这张表对自身严格:每条条目必须指认被实例化模块的一个 import——什么都没指认的条目是调用者的笔误,链接会拒绝它(`host function `env.log` matches no import of this module`),而不是默默带着它。

一条拒绝是契约的一部分:宿主闭包不得回调进本包。重入会骑过解释器的机器状态(操作数栈、当前实例、store)——本环记录它,后续的环或许解除它。

## 内存

`read_memory` 与 `write_memory` 是宿主进出实例 0 号线性内存的门,像 store 自己的访问器一样先查边界——越界区间以 `(R.error, "out of bounds memory access")` 应答。它们是数据双向穿行而不必借道导出函数的路:demo 写下 `"EMO"`,模块的 `i32.load8_u` 读回 `'E'`;模块存到 16,`read_memory(inst, 16, 4)` 读回来。

## 句柄与寿命

模块与实例句柄是包自己表里的索引;没有东西释放它们,一个程序的 wasm 状态与程序同寿。一个模块加载一次、实例化多次;`register_instance` 把一个实例的导出发布给后来加载的模块——这正是两个模块链接的方式(语料的 `linking.wast` 家族就在考它)。

## CLI:`emo wasm run`

CLI 经同一个包执行 `.wasm` 工件——驱动自家解释器跑一个嵌入式 driver——编译器永不链接运行时,所以一个孤零零的 `emo` 二进制在既无 registry 又无项目的情况下就能跑工件:

```bash
emo wasm run demo.wasm
```

模块加载、验证、实例化——它的 start 函数在此运行,spec 就是这么说的——然后走入口阶梯:先 `_start` 导出,再 `main`,两者都不指认的模块应答一行 `describe` 摘要(初始化就是在运行它)。结果按运行时的 `value : kind` 格式逐行打印。一切失败——坏工件、链接失败(原因里带着 import 的名字)、trap——都以原因落到 stderr 并以退出码 1 收场,从不 raise,从不回溯。

本环宿主表保持为空:模块的 import 若 `wasm` 伺候不了(`spectest` 之外的),链接就诚实地失败。WASI 与 `emo` 宿主模块是下一环。doctor 的 wasm 行点名这条命令;它不需要任何外部工具。

## 一致性

供应商化的 spec 套件随包同住:

```bash
cd stdlib/registry/wasm/0.1.0
dune test          # 两个语料的 smoke 切片
dune build @wasm_spec   # 全部 3456 条二进制模块用例(解码器/验证器)
dune build @wasm_runs   # 全部 25135 条运行命令(解释器,约 1 分钟)
```

`devtools/vendor-wasm-spec` 从钉住版本的 spec checkout 重出用例清单;钉住的修订与许可证住在包的 `testdata/README.md` 里。

## 它不是什么

- **没有 WASI,也没有 `emo` 宿主模块。** 来自其他工具链的模块在其 import 被表、register 命名空间或 `spectest` 伺候时即可运行——仅此而已。`emo` 宿主模块(及其牵出的 WASI 表面)是阶梯的下一环。
- **没有 GC 类型。** 解释器瞄准核心 spec 的 MVP 加上述五个扩展——函数引用、SIMD、GC、线程、memory64 都在门外。GC proposal 是出口信号:它落地之日,运行时就能跑 `emo build --target wasm` 的输出。
- **没有重入。** 宿主闭包回调进本包会腐蚀机器状态;本环拒绝。
- **只有 `["ocaml", "c"]`,诚实声明。** 解释器在它跑的任何地方消费这个包;两个编译 target 是逐字节验证过的(demo 的金测在两边逐字节一致)。
