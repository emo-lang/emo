# `rand` 包

熵,以及一条可复现的流:为密钥、nonce、seed 提供 target 自己的随机字节
来源,为一切必须每次回答相同字节的东西——fixture、golden、测试密钥——
提供一个确定性生成器。答案是 `Bytes`,因为熵本来就是字节,而 String 不
能在每个 target 上承载它们。包依赖 `crypto`,确定性流骑着它的 HMAC。

## 使用包

```emo
require "rand"
```

标准库随编译器一起发布,但它的包和其他依赖一样带版本:`require "rand"` 需要在 manifest 的 `deps` 块里钉上 `"rand" = "0.1.0"`(`crypto` 经 `rand` 自己的 manifest 带进来)。

## 接口

```emo
def bytes(n Int64) (R, Bytes)
def drbg_sha256(seed Bytes, length Int64) Bytes
```

## 来源:`bytes`

`bytes(n)` 从操作系统的熵源回答 `n` 个字节,`(R.ok, bytes)`;来源拒绝
时回答 `(R.error, reason)`——reason 以 `rand:` 开头并带上来源自己的错误
(`rand: getentropy: …`、`rand: randomBytes: …`)。负的 `n` 是调用方的错
误,raise。每次调用都是一次新的抽取:两次抽取不同,没有任何缓存。

来源经一个运行时实现逐 target 绑定,包的 `targets` 名单恰好点出能诚实
提供它的那些 target:

| Target | 来源 |
|---|---|
| 解释器(`emo run`)、`ocaml` | `/dev/urandom`,读满计数 |
| `c` | `getentropy`,每次 256 字节 |
| `typescript` | Node 的 `crypto.randomBytes` |
| `beam` | `crypto:strong_rand_bytes` |
| `wasm` | 经规范宿主的 `rand_bytes` import 走 Node 的 `crypto.randomBytes`(step 56 的 syscall 家族)——不实现该 import 的手写宿主跑不了取熵的程序,正如跳过 `file_read` 的宿主读不了文件 |

一把密钥就是一次抽取,不需要别的:

```emo
case rand.bytes(32) {
  (R.ok, seed) -> {
    const public = crypto.sign.ed25519_public(seed)
    // …
  }
  (R.error, why) -> { println(why) }
}
```

## 流:`drbg_sha256`

`drbg_sha256(seed, length)` 回答只取决于 `seed` 的 `length` 个字节:同
样的 seed 在每个 target 上永远回答同样的字节。它是 SP 800-90A 的
HMAC-DRBG 配 HMAC-SHA-256,一次式形状——在 seed 上实例化,然后一次
Generate 出 `length` 字节;没有 reseed,没有附加输入,调用之间不带计数
器。构造里叫熵、nonce、个性化的那些,由调用方拼进这一个 `seed`。这条流
是同一条流:64 字节请求的前 32 字节就是 32 字节请求的答案。空 seed 是
合法的 seed(和任何别的 seed 一样,每次回答同样的字节)。负的 `length`
raise。

这是测试密钥与可复现 fixture 的生成器——golden 自己的形状——不是秘密
的来源:秘密的 seed 让没有它的人无法预测输出,但 seed 得先从 `bytes`
来。

```emo
const key = rand.drbg_sha256("fixture: tcp echo".to_bytes(), 32)
```

## 错误二分

| 调用 | raise | 以值回答 |
|---|---|---|
| `bytes(n)` | `n < 0` | 来源拒绝时 `(R.error, "rand: …")` |
| `drbg_sha256(seed, length)` | `length < 0` | — |

## 向量

`examples/rand_demo` 钉住这条流——空 seed、同一 seed 的 32、33、64 字节
(前缀性质)、另一个 seed、零长度——每一行冻结前都对着 Python 里独立写
出的公式核过,并对来源做冒烟:回答 32 字节、两次抽取不同、零计数回答零
字节。在解释器、`ocaml`、`c`、`typescript`、`beam` 上逐字节一致。

## Target

`ocaml`、`c`、`typescript`、`beam`、`wasm`,加解释器。确定性流是纯
Emo,随包一起在 `wasm` 上跑。
