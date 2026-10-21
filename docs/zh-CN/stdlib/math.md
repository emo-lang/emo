# `math` 包

标准库其余部分所依赖的初等浮点函数,没有任何包依赖。普通函数全是纯 Emo,写在五个宿主目标共享的标量运算之上,所以每个函数都逐字节相同:超越函数用固定顺序的级数与范围归约,同样的运算、同样的顺序在每个目标上产出同样的位——这正是绘图 golden 所依赖的性质。另有一条需要显式选择的 `*_native` 路径,直接调用宿主 `libm`,只钉在 `c` 和 `ocaml` 上。

## 使用这个包

```emo
require "math"
```

标准库随编译器一起发布,但它的包和其他依赖一样带版本:`require "math"` 需要在 manifest 的 `deps` 块里钉上 `"math" = "0.1.0"`。

## 常量

```emo
const e = 2.718281828459045
const pi = 3.141592653589793
```

## 表面

```emo
def abs(x Float64) Float64
def min(a Float64, b Float64) Float64
def max(a Float64, b Float64) Float64
def clamp(x Float64, lo Float64, hi Float64) Float64
def sqrt(x Float64) Float64
def exp(x Float64) Float64
def log(x Float64) Float64
def log10(x Float64) Float64
def pow(base Float64, exponent Float64) Float64
foreign def exp_native(x Float64) Float64 = "exp"
foreign def log_native(x Float64) Float64 = "log"
foreign def log10_native(x Float64) Float64 = "log10"
foreign def pow_native(base Float64, exponent Float64) Float64 = "pow"
```

`abs` 给出绝对值;`min`/`max` 给出两值中的较小/较大者(`NaN` 比较为 false,所以 `min`/`max` 返回第二个参数);`clamp(x, lo, hi)` 把 `x` 限到 `[lo, hi]`。`sqrt` 是核心方法 `x.sqrt()` 的函数形态。

## 超越函数

`exp` 先把参数归约成 `2^k * exp(r)`——`k` 是 `x / ln2` 的最近整数,`|r| <= ln2 / 2`——然后用一个短 Taylor 级数求 `exp(r)`,再乘以一个精确的 2 的幂(直接写进指数位)。

`log` 把参数拆成 `x = m * 2^e`,`m` 落在 `[sqrt(1/2), sqrt(2))`,再用 atanh 级数 `2 * (z + z^3/3 + z^5/5 + ...)`(`z = (m-1)/(m+1)`)求 `log(m)`。`log10` 用 `log` 乘以 `1 / ln10`。`pow(base, exponent)` 即 `exp(exponent * log(base))`。

## 原生快路径

`exp_native`、`log_native`、`log10_native`、`pow_native` 经 `foreign def` 绑定宿主 C 库的 `exp`、`log`、`log10`、`pow`,只钉在能绑定宿主符号的 `c` 和 `ocaml` 两个目标上;它们的结果跟随宿主 `libm`,因此不跨平台逐字节相同。

在其他目标上这些定义是惰性的,而不是加载期错误,所以 `require "math"` 照常可用:解释器绑定一个调用时才抛 E3009 的值,`typescript`、`wasm`、`beam`、`riscv64` 发射器跳过该绑定,只在调用它时拒绝。名字特意与纯函数区分开——调用点一眼就能看出选的是哪一套实现。

## 域外参数是契约违反

这些函数有定义域,域外参数是程序错误而非数据:它 raise `Exception`,而不是返回某个特殊值。

- `log` 的非正数,`log10` 同理;
- `exp` 的上溢(参数约大于 709.78);
- `pow` 的负底数,或零的负指数。

这里不能返回 NaN 或无穷:beam 目标的 Erlang 浮点根本无法表示二者,一个要在每个目标上逐字节相同的包不能产出它们。调用方在调用前过滤数据——对数坐标丢掉非正值,核密度估计把指数保持在范围内。

## 目标与性能

目标:全部五个(`ocaml`、`c`、`typescript`、`wasm`、`beam`)。

普通函数在所有目标上都能运行。`*_native` 函数只在 `c` 和 `ocaml` 上可运行;在其他目标上它们能正常声明,只有被调用时才拒绝,所以导入这个包在用到原生函数之前没有代价。

另见:`examples/math_demo`(纯函数)与 `examples/math_native`(原生路径)。
