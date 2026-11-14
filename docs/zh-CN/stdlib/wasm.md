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
  (R.error, why) then { println("load " + why) }
  (R.ok, module) then {
    case wasm.instantiate(module, [("env", "log", -> (args Array[(Int64, Int64)]) {
      println("env log " + args[0][1].to_string())
      return wasm.i64(0)
    })]) {
      (R.error, why) then { println("inst " + why) }
      (R.ok, inst) then {
        case wasm.call(inst, "fac", [wasm.i64(10)]) {
          (R.error, trap) then { println("trap " + trap) }
          (R.ok, results) then {
            case wasm.as_i64(results[0]) {
              (R.ok, v) then { println("fac(10) = " + v.to_string()) }
              (R.error, why) then { println(why) }
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

## WASI:其他工具链的模块赖以运行的一环

内建宿主长出了 `wasi_snapshot_preview1`——真实工具链(clang/wasi-sdk、`rustc --target wasm32-wasip1`)发射的表面。十二个函数已实现;命名空间里其余一切在链接时以函数名拒绝——没有哑根:

| 函数 | 应答 |
| --- | --- |
| `args_sizes_get`、`args_get` | argv(`emo wasm run` 的多余实参;argv[0] 是工件名) |
| `environ_sizes_get`、`environ_get` | 空环境 |
| `proc_exit(code)` | 解卷;CLI 把代码映射为退出码 |
| `fd_write` | fd 1 和 2 走进程输出通道,iovec 字节原样;其余 fd EBADF |
| `fd_close`、`fd_seek` | 1/2 上无操作成功 / ESPIPE,其余 EBADF |
| `fd_fdstat_get` | fd 1/2 应答字符设备带全权(wasi-libc 启动时的 tty 探测读的就是它) |
| `random_get` | 经 `rand` 包的 OS 熵(真 hello world 里 Rust 的 `RandomState` 就靠它播种) |
| `clock_time_get` | ENOSYS——fixture 钉住这个拒绝;`time` 包经自己的两个导入读时钟 |
| `sched_yield` | 成功 |

解析序:显式宿主表最先(调用者可覆盖任何 `wasi_snapshot_preview1` import),然后 wasi 宿主,再 register 命名空间,再 `spectest`。import 签名对着表逐项检查——签错的 import 什么都绑不上。errno 值是 preview1 的编号(EBADF 8、EINVAL 28、ENOSYS 51、ESPIPE 69),由包的 fixture 钉死。

梯子曾点名的 `emo` 宿主模块继续缓议:没有生产者点名它——外来模块不可能,它不认识 Emo——而一个构造要落地需要具体的消费者。想要 Emo 宿主表面的模块走显式宿主表,Emo 程序点名什么模块名它就伺候什么。

live check:`rustc --target wasm32-wasip1` 的 hello world——真 wasi-libc——经 `emo wasm run` 打印,argv 计数与 `process::exit` 的退出码一路骑通;播种 HashMap 的模块经 `random_get` 应答。WASI 的 stdout 就是进程输出通道:先打印再退出(或 trap)的模块,字节照样送达。

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

- **WASI preview1 的文件系统半边仍在门外。** 无 preopen、无 `path_open`——点名的模块在链接时拒绝并带函数名;文件的故事等运行时自己的文件语义被定为 WASI preopen 之时再开,那是独立的一环。
- **没有 GC 类型。** 解释器瞄准核心 spec 的 MVP 加上述五个扩展——函数引用、SIMD、GC、线程、memory64 都在门外。GC proposal 是出口信号:它落地之日,运行时就能跑 `emo build --target wasm` 的输出。
- **没有重入。** 宿主闭包回调进本包会腐蚀机器状态;本环拒绝。
- **只有 `["ocaml", "c"]`,诚实声明。** 解释器在它跑的任何地方消费这个包;两个编译 target 是逐字节验证过的(demo 的金测在两边逐字节一致)。
