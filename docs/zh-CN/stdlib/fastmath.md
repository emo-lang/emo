# `fastmath` 包

直接绑定平台 `libm` 的宿主数学函数:数值表面的性能档位,与 `math` 同一标量表面、宿主库的速度。没有任何包依赖。

这里的一次调用就是一次纯粹的逐调用 libm 绑定——不重结合、不松弛浮点规则——所以快,而且在好的宿主库上通常至少与可移植级数同样准。但位跟随宿主:不跨平台逐字节相同。需要可复现位的程序 require `math`;需要速度的程序 require 这个包。

## 使用这个包

```emo
require "fastmath"
```

标准库随编译器一起发布,但它的包和其他依赖一样带版本:`require "fastmath"` 需要在 manifest 的 `deps` 块里钉上 `"fastmath" = "0.1.0"`。

## 常量

```emo
const e = 2.718281828459045
const pi = 3.141592653589793
```

与 `math` 的完全一致,两个包可以随意混用。

## 函数

`math` 的整个标量表面,不带后缀——包限定名本身就说明是原生。快速通道最初的四个(`exp`、`log`、`log10`、`pow`),三角三件套与反三角,双曲三件套,底二对与溢出安全的斜边,误差函数与其补函数,以及伽马对:

```emo
foreign def exp(x Float64) Float64 = "exp"
foreign def log(x Float64) Float64 = "log"
foreign def log10(x Float64) Float64 = "log10"
foreign def pow(base Float64, exponent Float64) Float64 = "pow"

foreign def sin(x Float64) Float64 = "sin"
foreign def cos(x Float64) Float64 = "cos"
foreign def tan(x Float64) Float64 = "tan"
foreign def asin(x Float64) Float64 = "asin"
foreign def acos(x Float64) Float64 = "acos"
foreign def atan(x Float64) Float64 = "atan"
foreign def atan2(y Float64, x Float64) Float64 = "atan2"

foreign def sinh(x Float64) Float64 = "sinh"
foreign def cosh(x Float64) Float64 = "cosh"
foreign def tanh(x Float64) Float64 = "tanh"

foreign def exp2(x Float64) Float64 = "exp2"
foreign def log2(x Float64) Float64 = "log2"
foreign def hypot(a Float64, b Float64) Float64 = "hypot"

foreign def erf(x Float64) Float64 = "erf"
foreign def erfc(x Float64) Float64 = "erfc"

foreign def tgamma(x Float64) Float64 = "tgamma"
foreign def lgamma(x Float64) Float64 = "lgamma"
```

`sqrt` 不在这里:它在每个目标上本来就是 `Float64` 方法,一条硬件指令。`math` 的非标量表面——复数算术、FFT、BLAS1、稠密求解器——本里程碑没有原生档;那是 netlib 评估阶段 3 的事。

## 契约与 `math` 不同

`math` 在溢出和定义域边界上 raise,因为五目标逐字节一致产不出 NaN 或无穷。这个包没有卫兵:宿主 libm 的行为就是契约,越界参数返回宿主所返回的——无穷、NaN、次正规。调用方在调用前过滤数据。

## 目标

`ocaml` 与 `c`,能绑定宿主符号的两个目标。其余目标上 `require` 在装载期失败(E5007);解释器没有可绑定的 foreign 实现,调用抛 E3009。

## 精度记录

原生档自己的电池在 `examples/fastmath_elefunt`,一个仅 `c` 的伴生金测:与 `math` 的电池同一套恒等式、同一条样本流,跑在这些绑定上,按行打印「是否在写明的位损失预算内」的判定而不是原始位数——于是金测在不同宿主 libm 上都成立。预算远高于合理宿主库的损失、远低于坏函数的损失;由消去主导的行带着恒等式自身的地板,写明在源码里。

参考:[`docs/zh-CN/stdlib/math.md`](math.md)(纯孪生表面) · 示例:`examples/fastmath_demo`、`examples/fastmath_elefunt`。
