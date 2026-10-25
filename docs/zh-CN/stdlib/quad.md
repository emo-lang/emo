# `quad` 包

netlib 的 QUADPACK 自适应求积,vendored 进包树,收在今天 FFI 唯一放行的形状之后——一个标量回调。被积函数是单方法接口,工作区归 C shim 所有(固定 500 个子区间的上限),收敛失败按值返回,不是违规。没有任何包依赖。

vendored 的翻译是原 Fortran 的 f2c C 转译(`dqags`、`dqagse`、`dqk21`、`dqelg`、`dqpsrt`,以及无穷区间三件套 `dqagi`、`dqagie`、`dqk15i`),其中 QUADPACK 的 `d1mach` 机器常数改写为它们在 IEEE-754 binary64 下的字面量,libf2c 已全部清除。原 Fortran 是 netlib QUADPACK(R. Piessens、E. de Doncker、K.U.Leuven),按致谢条款自由分发。

## 使用这个包

```emo
require "quad"
```

标准库随编译器一起发布,但它的包和其他依赖一样带版本:`require "quad"` 需要在 manifest 的 `deps` 块里钉上 `"quad" = "0.1.0"`。

## 被积函数

```emo
interface Integrand {
  def at(x Float64) Float64
}
```

一个带 `at` 方法的类直接可积——回调契约把实例带过 C ABI,实例携带的状态跟着走:

```emo
class CircleQuarter {
  def at(x Float64) Float64 {
    return 4.0 / (1.0 + x * x)
  }
}
```

被积函数不得再调用 `quad.integrate`;嵌套求积在被污染回调槽之前就会被自己的 reason 拒绝。

## 有限区间

```emo
def integrate(f Integrand, a Float64, b Float64, epsabs Float64,
  epsrel Float64) (R, (Float64, Float64))
```

在 `[a, b]` 上以 `max(epsabs, epsrel·|i|)` 精度求积:QUADPACK 的全局自适应 21 点 Gauss–Kronrod 规则(`dqags`/`dqagse`),ε-算法(`dqelg`)在细分历史上外推误差。成功时答案是 `(R.ok, (value, abserr))`——估计值与其误差界。端点奇异性正是这对例程的主场:`∫₀¹ ln x dx` 外推出 −1 并满足容差,普通自适应规则只会干磨。

## 无穷区间

```emo
enum InfiniteRange { from_bound, to_bound, whole_line }

def integrate_infinite(f Integrand, range InfiniteRange, bound Float64,
  epsabs Float64, epsrel Float64) (R, (Float64, Float64))
```

有限之外的三种区间,用名字命名而不是用无穷的界拼写:`from_bound` 积 `[bound, +∞)`,`to_bound` 积 `(−∞, bound]`,`whole_line` 积整条实轴并忽略 `bound`(传 `0.0`,QUADPACK 自己的约定)。变换后的 15 点规则(`dqagi`/`dqagie`/`dqk15i`)把每个区间映到 (0, 1],然后同一套自适应机器接管。

## 错误码映射

QUADPACK 的每个失败码都以 netlib 自己的措辞回答 `(R.error, reason)`;收敛失败是求积的预期结果,决定权在调用方:

| `ier` | reason |
|---|---|
| 1 | 已达最大细分数(500)——在难点处切开区间,对各子区间分别求积 |
| 2 | 舍入误差阻止了请求容差的达成;误差可能被低估 |
| 3 | 积分区间内部某些点上出现极端恶劣的被积行为 |
| 4 | 算法不收敛——外推表中检出舍入误差,返回的结果就是能拿到的最好结果 |
| 5 | 积分很可能发散,或收敛极慢 |
| 6 | 输入无效——`epsabs <= 0` 且 `epsrel < max(50·机器精度, 0.5e-28)` |
| 7 | 某个被积函数又调用了 `integrate`——不支持嵌套求积 |

码 6 是 QUADPACK 的有效性检验:`epsabs = 0` 时 `epsrel` 必须达到 `1.11e-14`——五十个机器精度——否则调用拒绝。

## 目标与可复现性

仅 `c`——vendored 翻译与 shim 都是构建编译链接的原生代码。其余目标上 `require` 在装载期失败(E5007);解释器下调用抛 E3009,`emo run` 无法执行触及这个包的程序——用 `emo build --target c` 构建。

求解器自身的算术是逐运算精确的 IEEE-754(构建带 `-ffp-contract=off`;vendored 代码不用超越函数——唯一一个分数幂写成 `x*sqrt(x)`,而 `sqrt` 按 IEEE-754 是精确的),所以细分路径在每个宿主上落在同一批子区间。答案的位是被积函数自身的算术加上这条路径:纯算术或 `math` 纯级数的被积函数处处逐字节一致;调用 libm 的被积函数把答案交给宿主——与 `fastmath` 同一条规则。

参考:[`docs/zh-CN/stdlib/math.md`](math.md)(纯数值表面) · 示例:`examples/quad_demo`。
