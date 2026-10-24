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

```emo
foreign def exp(x Float64) Float64 = "exp"
foreign def log(x Float64) Float64 = "log"
foreign def log10(x Float64) Float64 = "log10"
foreign def pow(base Float64, exponent Float64) Float64 = "pow"
```

## 契约与 `math` 不同

`math` 在溢出和定义域边界上 raise,因为五目标逐字节一致产不出 NaN 或无穷。这个包没有卫兵:宿主 libm 的行为就是契约,越界参数返回宿主所返回的——无穷、NaN、次正规。调用方在调用前过滤数据。

## 目标

`ocaml` 与 `c`,能绑定宿主符号的两个目标。其余目标上 `require` 在装载期失败(E5007);解释器没有可绑定的 foreign 实现,调用抛 E3009。

参考:[`docs/zh-CN/stdlib/math.md`](math.md)(纯孪生表面) · 示例:`examples/fastmath_demo`。
