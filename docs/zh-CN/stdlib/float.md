# `float` 包

IEEE binary64 值与它的十进制文本之间的精确转换,中途不经过任何宿主的格式化原语:十进制字面量变成离它最近的那些位,`Float64` 变成能精确读回它的最短十进制文本。两个方向都是纯粹的 `Int64` 运算——一个方向用 ASCII 数字缓冲区,另一个方向用 base-256 limb——写在包的 `internal` 子树里,所以五个宿主目标都逐字节相同。没有 `strtod`,也没有 `printf`。

格式类包是它的调用方:`json`、`sql`、`yaml` 都经由这一份实现读写数字,所以同一个字面量无论由哪种格式承载都解析出同样的位,算法也只有一个地方需要修。

## 使用这个包

```emo
require "float"
```

`require` 与清单严格配对:`float` 必须在 `package.emo` 里钉住:

```emo
package {
  name = "acme/myapp"
  version = "0.1.0"
  targets = ["ocaml", "c", "typescript", "wasm", "beam"]

  deps {
    float = "0.1.0"
  }
}
```

## 表面

```emo
def parse_exact(neg Bool, digits Bytes, n Int64, e10 Int64) Int64
def finite_bits(bits Int64) Bool
def to_text(x Float64) String
```

## 解码

`parse_exact(neg, digits, n, e10)` 给出 `(-1)^neg * 0.digits * 10^e10` 的位模式,并且是正确舍入的:就近舍入、平局取偶,与 `strtod` 给出同一个答案。`digits` 装有效数字的 ASCII 数字字节,`n` 是它的个数;`e10` 是十进制指数。扫描器把读到的东西原样交出来,自己不做任何归一化——前导零只是移动指数,小数点后的尾随零不改变任何东西——超过 800 位有效数字上限的部分只用来定 sticky 舍入。这个上限卡在每一个精确平局之外:一个平局最多需要 768 位有效数字,所以没有平局会因为上限而丢掉尾巴。

无论值是多少,答案都是一个位模式。超出 binary64 范围时是无穷的位模式;低于下界时值下溢——舍入到最小 denormal,或者舍入到零。`finite_bits` 说明一个位模式到底是不是值:全 1 的指数拼出无穷或 NaN,而 beam 二者都没有——它的 `from_bits` 直接拒绝这样的位模式。

## 范围检查属于调用方

解码是给答案而不是 raise,因为只有调用方知道越界的数字意味着什么:对 `json` 和 `sql` 来说它是坏输入——没有 binary64 装得下的数——所以它们先查 `finite_bits`,给出 `(R.error, …)`,而不是把值建出来。在 beam 上这个顺序有实打实的理由:那里不存在的值不能先建出来再丢掉。

## 编码

`to_text(x)` 打印能精确读回 `x` 的最短十进制文本。值的数字是精确的——整数乘上 5 的幂,而不是舍入后的近似——最短宽度靠逐个尝试得到:先一位有效数字,再两位,直到某个候选能通过 `parse_exact` 读回原值;十七位总能做到。零打印成 `0.0`(带符号位时是 `-0.0`),而非有限值根本没有十进制文本,所以 `to_text` raise。

## 目标与性能

目标:全部五个(`ocaml`、`c`、`typescript`、`wasm`、`beam`)。

这里没有任何一处调用宿主的浮点格式化,所以没有哪个目标的行为能渗进答案。每个辅助函数都是纯尾递归——全程没有重新赋值——所以特化后端把整个包一起收下。

## 在哪里被跑到

这个包没有自己的示例:它是构件,跑它的地方是格式类包的示例——`examples/json_demo`、`examples/sql_demo`、`examples/yaml_demo`。
