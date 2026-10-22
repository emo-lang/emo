# Emo 与 netlib —— 一份评估

写于 2026-10-22。这是一份技术可行性评估,不是已定的设计决策;文中
关于项目状态的描述以写作日期的仓库为准。

问题:以 [netlib](https://netlib.org/liblist.html) 为基础,给 Emo
造一套高性能数学函数库,到底有多难?

## 结论

**可行——但目标的两半互相拉开,诚实的方案必须把它们分开。**
"基于 netlib"买到的是正确性广度与参考语义,不是速度:netlib 发布
的是参考实现,它的 BLAS 在矩阵乘法上比调优后裔(OpenBLAS、BLIS、
MKL、Accelerate)慢一到两个数量级。而"高性能"在今天的 Emo 里横着
几道编译器级的门:数组在任何位置都过不了 FFI,数组是装箱且值语义
的,C 运行时只有一条 OS 线程。与此同时,地基已经打好:`math` 包
0.1.0 已落在 `develop`,带着五目标逐字节一致的超越函数与 opt-in
原生快速通道。分阶段给结论:

| 阶段 | 目标 | 代价 |
|---|---|---|
| 1 | 全目标、逐字节一致的正确性库——完整超越函数、复数 FFT、BLAS1、一个小型稠密求解器——netlib 作算法与检验基线 | 纯包级工作;延伸已落地的 `math` |
| 2 | 标量原生加速——QUADPACK 求积与特殊函数经现有 FFI 绑入 | 纯包级工作;推广 `*_native` 先例 |
| 3 | 数组级性能——BLAS2/3 与 LAPACK 子集原生绑定 | 数组 FFI 之门:marshaling、可变视图、unboxed `Float64Array`、foreign 线程语义——一次编译器 step,与 SQL 数据库、工业软件两份评估撞的是同一扇门 |

## netlib 到底提供什么

netlib 是数值计算社区的参考软件库,自上世纪 80 年代汇编至今仍在
维护;内容自由可用,绝大多数属公有领域或宽松许可——LAPACK 本体
采用 BSD 风格许可。目录分层如下:

- **BLAS**——向量/矩阵内核;**LAPACK**——稠密线性方程组、最小
  二乘、特征值问题(EISPACK 与 LINPACK 是其先祖,实际已被取代);
  **ScaLAPACK/ARPACK**——分布式与稀疏变体。
- **FFTPACK**——傅里叶变换;**QUADPACK**——自适应求积;
  **MINPACK**——非线性最小二乘;**ODEPACK**——初值常微分方程。
- **特殊函数**——CEPHES、fdlibm,以及 Cody & Waite 的 ELEFUNT
  检验体系,初等函数的经典验证套件。
- **TOMS**——ACM Transactions on Mathematical Software 算法集;
  **SLATEC**——合并的 DOE 库。

一切皆为 Fortran 77,`f2c` 是标准的 C 转译途径,源码可整个搬进
包树,无许可负担。

性能的告诫必须放在同一句话里:这些是参考实现,为清晰与可移植而
写。快速的后裔重建了内核——SIMD、缓存分块、多核调度——速度恰恰
来自这些工作,而不是算法本身。在 Emo 里基于 netlib 源码追求
"高性能",要么接受参考实现级的吞吐,要么链接调优库——后者是外部
二进制依赖,与全本地、静态、三平台的发布管线相抵触。

## Emo 现在站在哪里

六个事实决定整份评估的走向(仓库状态,2026-10-22):

1. **`math` 包已存在**(`stdlib/registry/math/0.1.0`,已落
   `develop`)。纯 Emo:标量(`abs`、`min`、`max`、`clamp`、
   `sqrt`);`exp`、`log`、`log10`、`pow` 用固定阶级数加 range
   reduction,建在 `Float64.to_bits` / `Float64.from_bits` 位级对
   之上——同样的运算按同样的顺序在五个宿主目标上产出同样的位,
   plot 的 SVG 金样正依赖于此。违反定义域抛 `Exception`,因为
   beam 目标的浮点根本装不下 NaN 与无穷。
2. **原生快速通道的形状已定型**:opt-in 的 `exp_native` /
   `log_native` / `log10_native` / `pow_native`,以 `foreign` 定义
   钉在 `c` 与 `ocaml` 两目标。其余目标上这些定义是惰性的——
   `require "math"` 照常,只有调用被拒(解释器 E3009,发射器
   lower error)——输出跟随宿主 libm,故不逐字节一致。
3. **FFI 在任何位置都不放行数组。** 标量参数为
   `Float64`/`String`/`Bool`(外加 c 上的 `Int64` 与 `Void`
   返回);struct 形状与单方法接口回调走同一批标量。`Array[T]`
   出现在参数、字段或回调签名里一律 E4200——而且在 typescript、
   wasm、beam、riscv64 目标上,连标量调用都在 lowering 阶段被拒。
4. **数组是装箱且值语义的。** C 运行时里数组是 tagged word 向量,
   每个元素装箱;索引带界检查;不存在 unboxed 的扁平浮点数组
   (`Bytes` 即 u8,是唯一的 unboxed 存储)。LAPACK 式的原地更新,
   跨任何未来的 marshaling 边界都得深拷贝。
5. **只有一条 OS 线程。** Emo 进程是单线程上的 ucontext fiber,
   带运行队列;没有原生并行,而一次长 foreign 调用占用唯一线程,
   拖停所有进程。
6. **native-only 代码的打包机制已被验证**:清单声明
   `targets = [...]`,装载时以 E5007 强制;`os` 以 ocaml+c 发布,
   `sqlite3` 与 `term` 仅 c,各自的原生源码随包树携带。

检验侧同样现成:金样纪律、`float` 包的精确十进制转换(可作测试
oracle)、`plot`(结果目检)。

## 优势

- **最难的坑已经被填。** 跨平台 libm 差异是数值库难做确定性的经典
  原因;`math` 用位级运算上的固定阶级数回答了它,代价是手写算法。
  这份代价如今是摊薄的既有机制,不是悬而未决的问题。
- **netlib 契合度最高的一层是特殊函数**——标量进、标量出,配
  ELEFUNT 这套现成的验证体系。这正是现有 FFI 与 `*_native` 模式
  已经覆盖的形状。
- **标量形态的组件今天就能绑,零编译器工作。** QUADPACK 的自适应
  求积是标量进出、被积函数以回调供给——在现有回调契约之内。ODE
  右端函数同理。
- **分发零摩擦。** 公有领域与宽松许可的 Fortran,经 `f2c` 一次性
  转译,作为包原生源码 vendored,静态链接——发布管线原封不动。
- **语言面对数值代码有真资产**:显式 `Float64`/`Int64` 宽度、无
  隐式转换的严格检查、内建位级转换——级数代码已经验证了这些原料。

## 劣势

1. **数组 FFI 之门是最硬的一道。** BLAS、LAPACK、FFTPACK、MINPACK
   的每个入口都是数组进、数组出;今天任何位置都是 E4200。过门需要
   marshaling、unboxed `Float64Array`、可变(别名)视图——Fortran
   惯例是原地 in-out,而 Emo 数组是值语义,每次调用深拷贝会吃掉
   全部收益。与 SQL 数据库、工业软件两份评估撞的是同一扇门,而且是
   一次编译器 step,不是包级工作。
2. **纯 Emo 对数组类工作的性能天花板很低。** 元素装箱、索引带界
   检查、无 SIMD、单线程:BLAS1 与小型 BLAS2 尚可接受;矩阵乘法与
   大型 FFT 距调优库的数字差一到两个数量级。
3. **一致性纪律随表面积放大。** 任何绑 libm 或 netlib 的函数都只在
   c/ocaml 可用,且与纯 Emo 孪生版本 ULP 不同,金样只能按目标分开
   或 native-only。`math` 目前在四个函数上扛着这个张力;数值库会把
   它摊到整个包。
4. **没有并行可提供。** 调优 BLAS 的数字来自 SIMD 内核、缓存分块、
   多核调度,与算法同等重要;Emo 运行时三者皆无,且长 foreign 调用
   运行期间阻塞所有进程。
5. **API 面是设计工作,不是翻译工作。** 无运算符重载(哲学使然)、
   值语义数组、以异常替代带内错误码:Fortran 签名直接翻译是错配
   的,包需要一套有意设计的、不可变的、Emo 原生的 API。

## 建议的形状

- **阶段 1——正确性库,全目标。** 补齐超越函数面(`sin`/`cos`/
  `tan`、反函数、双曲函数——同一级数纪律),移植 FFTPACK 的
  radix-2 复数变换,纯 Emo 写 BLAS1,加一个小型稠密求解器(高斯
  消元,gesv 形状)。每步可交付,金样全程逐字节一致,netlib 作
  算法与检验基线。
- **阶段 2——标量原生加速。** 经现有 FFI 把 QUADPACK 与特殊函数
  以 opt-in `*_native` 变体绑入,以 ELEFUNT 作验收套件。这同时度量
  opt-in 模式在更宽函数面上是否划算,为阶段 3 的排期提供依据。
- **阶段 3——数组之门,作为独立的编译器 step。** 带 mutable 视图
  的数组 marshaling、unboxed `Float64Array`、foreign 调用的显式
  线程占用语义。落地后,LAPACK 子集按 `os`/`sqlite3` 模式以
  c-only 包发布。OpenBLAS 级性能继续挂起,直到 unboxed 数组的地板
  量出来。

定位随阶段而来:交付物是"正确性优先、带原生快速通道"的数值库,
不是"高性能"——这个词在阶段 3 有实测数字之前,不进任何宣传口径。

## 参考资料

- netlib 库列表:<https://netlib.org/liblist.html>
- LAPACK:<https://www.netlib.org/lapack/>
- QUADPACK:<https://www.netlib.org/quadpack/>
- FFTPACK:<https://www.netlib.org/fftpack/>
- f2c:<https://www.netlib.org/f2c/>
- ELEFUNT:<https://www.netlib.org/elefunt/>
- OpenBLAS:<https://www.openblas.net/>
