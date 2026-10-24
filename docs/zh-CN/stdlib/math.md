# `math` 包

标准库其余部分所依赖的浮点函数,没有任何包依赖:标量、2 的幂、超越函数、误差函数及其补函数、gamma 对、复数算术、 radix-2 FFT、BLAS1 核心与稠密求解器。

普通函数全是纯 Emo,写在五个宿主目标共享的标量运算之上,所以每个函数都逐字节相同:超越函数用固定顺序的级数与范围归约,系数以字面量写死在源码里,同样的运算、同样的顺序在每个目标上产出同样的位——这正是绘图 golden 所依赖的性质。宿主侧的更快档位在独立的 `fastmath` 包里,钉在 `c` 和 `ocaml` 上;本包在全部五个目标上保持逐字节一致。

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

## 标量

```emo
def abs(x Float64) Float64
def min(a Float64, b Float64) Float64
def max(a Float64, b Float64) Float64
def clamp(x Float64, lo Float64, hi Float64) Float64
def sqrt(x Float64) Float64
def hypot(a Float64, b Float64) Float64
```

`abs` 给出绝对值;`min`/`max` 给出两值中的较小/较大者(`NaN` 比较为 false,所以 `min`/`max` 返回第二个参数);`clamp(x, lo, hi)` 把 `x` 限到 `[lo, hi]`。`sqrt` 是核心方法 `x.sqrt()` 的函数形态。`hypot` 在平方之前按较大者的指数重缩放两个模长,溢出和下溢都动不了它;非有限参数 raise。

## 2 的幂

```emo
def pow2(n Int64) Float64
```

`pow2(n)` 把 `n` 直接写进指数位,`exp` 所做的缩放因而是精确的、无需乘法循环。可达范围是 `[-1074, 1023]`:指数超过 `1023` raise,低于 `-1074` 下溢为零。

## 指数与对数

```emo
def exp(x Float64) Float64
def exp2(x Float64) Float64
def log(x Float64) Float64
def log10(x Float64) Float64
def log2(x Float64) Float64
def pow(base Float64, exponent Float64) Float64
```

`exp` 先把参数归约成 `2^k * exp(r)`——`k` 是 `x / ln2` 的最近整数,`|r| <= ln2 / 2`——然后用一个短 Taylor 级数求 `exp(r)`,再乘以一个精确的 2 的幂。越过 `x ≈ 709.78` 答案离开指数范围,raise;低于 `x ≈ -745` 下溢为零。`exp2` 在地板处劈开——整数部分交给 `pow2`,小数部分交给 `exp` 的级数——越过 `1024` raise。

`log` 把参数拆成 `x = m * 2^e`,`m` 落在 `[sqrt(1/2), sqrt(2))`,再用 atanh 级数 `2 * (z + z^3/3 + z^5/5 + ...)`(`z = (m-1)/(m+1)`)求 `log(m)`;次正规参数先放大、再减掉放大自身的对数。`log10` 用 `log` 乘以 `1 / ln10`。`log2` 复用 `log` 的分解——指数部分单独作答,所以每个 2 的幂(一路到次正规)都精确作答。

`pow(base, exponent)` 在正底数时即 `exp(exponent * log(base))`;零底数按极限作答(`0^0` 是 `1`),负底数在这里没有实数答案——Emo 没有复数结果——所以 raise。

## 三角函数

```emo
def sin(x Float64) Float64
def cos(x Float64) Float64
def tan(x Float64) Float64
def atan(x Float64) Float64
def atan2(y Float64, x Float64) Float64
def asin(x Float64) Float64
def acos(x Float64) Float64
```

`sin` 与 `cos` 先做分裂 π/2 的范围归约——精确到 `|x| <= 2^20`,越界以及非有限参数都会 raise——再在归约后的数对上跑固定阶 Taylor 级数。`tan` 是两条归约级数的商,带上象限符号与倒数开关;它的极点在二进制浮点里不可达,所以自己没有定义域 raise。

反三角对把参数折叠进固定阶奇级数的射程:`|x| = 1` 之上走倒数恒等式,之下走 `tan(π/12)` 折叠。`asin` 的根号由精确因子 `(1 − x)` 与 `(1 + x)` 构造,`x` 逼近一时不抵消;`acos` 共享同一核心。两者在 `|x| > 1` 时 raise。`atan2` 围绕 `atan` 拼装象限:它的坐标轴是带符号的零——各自保留符号——原点(两参数皆零)raise,那是唯一没有角度的点。

## 双曲函数

```emo
def sinh(x Float64) Float64
def cosh(x Float64) Float64
def tanh(x Float64) Float64
```

都是 `exp` 的复合。`sinh` 在半以下走短奇级数——那里 `(e^x − e^−x)/2` 会抵消;`cosh` 只做加法。`sinh` 与 `cosh` 在 `e^x` 离开指数范围时 raise,即 `exp` 的规则。`tanh` 在 `|x| = 20` 饱和到 ±1——公式到一的差距已在半个 ulp 之下——所以没有任何参数会在进入商之前撞上 `exp` 的上溢。三者在非有限参数上 raise。

## 误差函数及其补函数

```emo
def erf(x Float64) Float64
def erfc(x Float64) Float64
```

`erf` 在 `|x| < 2` 时从小到大求 Maclaurin 项之和——三十项,截断在交叉点远小于一个 ulp——越过之后骑 `1 − erfc`,此时补函数已经很小,减法无从抵消。`erfc` 是独立函数而不是 `1 − erf`:交叉点之上尾部由余 gamma 的连分数承载,答尾部全程不见 `1 −`;之下它就是 `1 − erf` 的级数。越过 `x ≈ 27.7` 尾部下溢为零,即射程底端的 `exp` 规则。两者在非有限参数上 raise。

## gamma 对

```emo
def tgamma(x Float64) Float64
def lgamma(x Float64) Float64
```

Lanczos 近似,一组固定系数——`g = 7`,九项——以字面量写死在源码里,构造上逐字节一致。半之上的正半轴直接跑级数;负半轴与其下的窄条通过反射公式 `Γ(x) = π / (sin(πx)·Γ(1−x))` 折到 `1 − x` 上,级数住在那里。

非正整数是极点——Γ 在那里没有值——两个函数都 raise。`tgamma` 只在答案装得进 `Float64` 时直接作答:越过 `x ≈ 171.62`(零之上),以及极点近旁模长越过天花板处,它 raise,即 `exp` 规则。`lgamma` 在那里作答——它的形式是同一乘积的对数,任何中间量都不离开射程——按 C 传统携带 `ln|Γ|`,即不带符号的模长;它在两个单位点上精确为零。

## 复数算术

```emo
def complex_add(z (Float64, Float64), w (Float64, Float64)) (Float64, Float64)
def complex_sub(z (Float64, Float64), w (Float64, Float64)) (Float64, Float64)
def complex_mul(z (Float64, Float64), w (Float64, Float64)) (Float64, Float64)
def complex_div(z (Float64, Float64), w (Float64, Float64)) (Float64, Float64)
def complex_abs(z (Float64, Float64)) Float64
def complex_conj(z (Float64, Float64)) (Float64, Float64)
def complex_scale(z (Float64, Float64), f Float64) (Float64, Float64)
def complex_from_polar(r Float64, theta Float64) (Float64, Float64)
```

一个复数值是 `Float64` 的 `(re, im)` 数对。除法走 Smith 算法,答案装得下商就装得下;模长走重缩放的 `hypot`;极坐标构造骑包自己的 `sin` 与 `cos`。零除数 raise。

复数向量的数组形态是**交错式**:一条平坦的 `Array[Float64]`,装着 `re, im, re, im, ...`——这正是 FFT 吃进和吐出的布局,无需转置拷贝。

## FFT

```emo
def fft(v Array[Float64]) Array[Float64]
def ifft(v Array[Float64]) Array[Float64]
```

仿 FFTPACK `cfftf`/`cfftb` 的 radix-2 复 FFT:交错数组上的迭代 Cooley–Tukey,前置位反转排列,旋转因子取自包自己的 `sin` 与 `cos`——表是逐字节相同的,而不是宿主 libm 的。`ifft` 乘 `1/n`,所以 `ifft(fft(v))` 答出 `v`。长度不是 2 的幂时 raise——混合基是以后的事,不是静默回退。

## BLAS1

```emo
def dot(x Array[Float64], y Array[Float64]) Float64
def nrm2(x Array[Float64]) Float64
def asum(x Array[Float64]) Float64
def iamax(x Array[Float64]) Int64
def scal(a Array[Float64], f Float64) Array[Float64]
def axpy(a Float64, x Array[Float64], y Array[Float64]) Array[Float64]
```

参照 reference BLAS 的 BLAS1 核心。累加顺序是固定的——每个核心从头到尾走一遍数组——这正是它们逐字节相同的原因。数组是值,所以 `scal` 与 `axpy` 回答新数组、从不就地写,长度不匹配则 raise。`nrm2` 带着reference BLAS 的缩放累加,任何平方都不会溢出。`iamax` 回答模最大者中首个元素的下标;空数组没有这样的下标,raise。

## 稠密求解器

```emo
def lu(a Array[Float64], n Int64) (Array[Float64], Array[Int64])
def solve(a Array[Float64], n Int64, b Array[Float64]) Array[Float64]
```

仿 LAPACK 的 `getrf`/`getrs`。矩阵是**扁平行主序**的 `Array[Float64]`,维度显式给出——不用嵌套数组,一个矩阵一次分配——与 FFT 的平面向量同一表示,每个目标按同样的顺序索引。

`lu` 回答打包的因子——对角线之下是 L 的乘子(L 的单位对角线不存),对角线及其上是 U——以及主元向量,每项是被换到该步主元位上的行号,零基。主元恰为零时 raise,矩阵版的除以零;阈值就是精确零,不带容差。`solve` 是 `gesv` 的形状:分解,用同一批交换重排右端项,再穿过两个因子回代;右端项长度不是 `n` 时 raise。两者都不就地写;数组是值,答案是新的。

## 精度:电池记录

`examples/math_elefunt` 里的电池在这个表面上跑 Cody & Waite 的恒等式测试——`sin` 对照三倍角,`exp` 对照移位乘积,`log` 对照和式形式,gamma 递推,等等——参数取自固定在 example 里的线性同余生成器,所以每个目标抽到同一组样本。每个函数打印对照恒等式的最大与均方根位损失;golden 的 `expected.txt` 就是精度记录,退化即 diff。

落地时的记录(每行 512 个恒等式,种子 42):

```text
pow2 max 0.0 rms 0.0
sqrt max 0.994448 rms 0.32572
hypot max 0.0 rms 0.0
exp max 3.37783 rms 1.45827
exp2 max 3.3107 rms 1.43898
log max 2.86954 rms 0.623192
log2 max 1.42286 rms 0.348296
log10 max 1.52026 rms 0.397249
pow max 2.86016 rms 1.22208
sin max 7.72716 rms 2.01304
cos max 2.77636 rms 0.747501
tan max 1.98934 rms 0.506548
atan max 1.95692 rms 0.463365
atan2 max 1.29474 rms 0.110757
asin max 7.58068 rms 2.18379
acos max 4.45091 rms 1.23883
sinh max 3.51371 rms 1.41474
cosh max 8.0 rms 3.56214
tanh max 2.51866 rms 0.534811
erf max 14.5575 rms 12.3683
erfc max 29.4069 rms 25.3946
tgamma max 8.56078 rms 5.24082
lgamma max 4.55075 rms 0.838315
```

怎么读:恒等式是自洽性检查,不是外部真值,所以每行落在它恒等式自身的舍入所安放的位置。2 的幂与 `hypot` 重缩放两行量的本来就是精确算术,回答零。多数行为复合丢掉一两位——`pow` 与双曲 trio 继承 `exp` 和 `log` 的几个 ulp,而逼近函数零点的行(`sin` 近 π、`cosh² − sinh²` 的减法)诚实地放大。`erf` 与 `erfc` 两行扛着定义积分上的 Simpson 法则,它们的地板——天花板之下约十五位与三十位——是求积的,不是函数的。`tgamma` 行记录的是 Lanczos 形式自身随参数增大的变薄,是级数在大 `x` 处的继承。

## 更快的一档在 `fastmath`

宿主 libm 绑定不在这个包里。`fastmath` 包把同一标量表面直接绑到平台的 `libm` 上(`c` 和 `ocaml`)——一次调用就是一次纯粹的逐调用绑定,所以更快,但位跟随宿主,不跨平台逐字节相同。需要可复现位的程序 require `math`;需要速度的程序 require `fastmath`。

## 域外参数是契约违反

这些函数有定义域,域外参数是程序错误而非数据:它 raise `Exception`,而不是返回某个特殊值。

- `log`、`log2`、`log10` 的非正数;
- `exp` 越过 `x ≈ 709.78`、`exp2` 越过 `1024`;
- `pow` 的负底数,或零的负指数;
- 三角函数的非有限参数,以及 `|x| <= 2^20` 归约界之外;
- `asin` 与 `acos` 的 `|x| > 1`;`atan2` 的原点;
- `sinh` 与 `cosh` 在 `e^x` 离开指数范围处;`tanh`、`erf`、`erfc` 的非有限参数;
- gamma 对的极点——非正整数——以及 `tgamma` 答案离开指数范围处;
- `lu` 的奇异矩阵或维度不匹配,`solve` 的右端项长度不对,`fft` 的长度不是 2 的幂,BLAS1 核心的长度不匹配。

这里不能返回 NaN 或无穷:beam 目标的 Erlang 浮点根本无法表示二者,一个要在每个目标上逐字节相同的包不能产出它们。调用方在调用前过滤数据——对数坐标丢掉非正值,核密度估计把指数保持在范围内。

## 目标与性能

目标:全部五个(`ocaml`、`c`、`typescript`、`wasm`、`beam`)。整个包是纯的,在任何目标上导入都没有代价,每个答案都逐字节一致。

示例:`examples/math_demo`(标量与超越函数)、`examples/math_trig`、`examples/math_inverse_trig`、`examples/math_hyperbolic`、`examples/math_complex`、`examples/math_fft`、`examples/math_blas1`、`examples/math_solve`、`examples/math_special`(`erf`/`erfc`/`tgamma`/`lgamma`)、`examples/math_elefunt`(精度电池)。
