# `crypto` 包

标准库的原语层:哈希、MAC、密钥派生、AEAD 密码、一个签名方案、一个
密钥协商——每个协议都由这些零件搭起来,但不往上再走一步(没有 TLS、
没有证书、没有密钥存储)。纯 Emo 写在 `Int64` 与 `Bytes` 之上,所以
包声明的每个 target 回答相同的字节:golden 骑着解释器、`ocaml`、`c`、
`typescript`、`wasm`、`beam`,每一行都与 RFC 和 NIST 的向量一致,也——
凡 Go 标准库带有该原语之处——与提交机器上 Go 自家 `crypto` 包生成的值
一致。

包由一个根模块和八个子模块组成,按限定名调用:

| 模块 | 内容 |
|---|---|
| `crypto` | 常量时间比较与 hex 编解码 |
| `crypto.sha2` | SHA-256、SHA-224、SHA-512、SHA-384、SHA-512/224、SHA-512/256——流式与一次式 |
| `crypto.sha3` | SHA3-224/256/384/512 与 SHAKE128/256 |
| `crypto.hash` | `Hash` 接口与 SHA-2 家族上的 HMAC |
| `crypto.kdf` | SHA-2 家族上的 HKDF 与 PBKDF2 |
| `crypto.cipher` | ChaCha20、Poly1305、ChaCha20-Poly1305,AES 及其 CTR、CBC、GCM |
| `crypto.sign` | Ed25519 |
| `crypto.ecdh` | X25519 |
| `crypto.legacy` | SHA-1 与 MD5,只为既有数据 |

## 使用包

```emo
require "crypto"
```

标准库随编译器一起发布,但它的包和其他依赖一样带版本:`require "crypto"` 需要在 manifest 的 `deps` 块里钉上 `"crypto" = "0.1.0"`。

```emo
const digest = crypto.sha2.sha256("abc".to_bytes())
println(crypto.hex_encode(digest))
```

## Bytes 是载体

密钥、nonce、摘要、tag、签名,以及算法读取的每一个输入,都以 `Bytes`
进、以 `Bytes` 出。String 不能在每个 target 上承载裸字节——在
`typescript` 上 String 是 UTF-8 文本,摘要里 0x80 及以上的字节会解码成
U+FFFD——所以包不假装可以。文本只在一处保持为文本:`hex_encode` 以
String 回答 ASCII 渲染,`hex_decode` 把它读回来。要哈希文本的调用方
交出 `text.to_bytes()`,在每个 target 上都精确。

## 错误二分

标准库的规则贯穿始终,下面每个函数都写明自己的情况:

- **调用方的错误 raise。** 密钥、nonce、seed 或点的长度不对;计数器越
  界;输出长度为负;迭代次数小于一;CBC 密文不是十六的正整数倍。这些
  是合同违约——是程序错了,不是数据错了——raise 的消息以 `crypto:`
  开头。
- **数据原因是值。** 验不过的 tag、读不回来的填充、不是这把密钥的签
  名、全零的共享密钥、不是 hex 的 hex 字符串。这些回答 `(R.error, reason)`,
  reason 以 `crypto:` 开头;能这样失败的函数,正是答 `(R, …)` 的那些。

伪造无论什么形状都得到同一个答案:翻一个字节、错的 AAD、截断的盒子、
错的密钥——`open` 对它们一律回答 `(R.error, "crypto: authentication failed")`,
`ed25519_verify` 对每一个坏签名回答 `false`,答案本身不透露是哪一步没过。

## 根模块:比较与 hex

```emo
def constant_time_compare(a Bytes, b Bytes) Bool
def hex_encode(data Bytes) String
def hex_decode(text String) (R, Bytes)
```

`constant_time_compare` 回答两段字节是否相等,把每一对的 XOR 累进同
一个字,于是比较的形状不取决于第一处差异在哪;长度也进同一个累加
器,长度不等回答 false。比较 tag 和摘要走它,绝不用 `==`。

`hex_encode` 每字节答两个小写字符;`hex_decode` 是它的严格逆——偶数个
字符、每个数字大小写都收——其余都是值 `(R.error, "crypto: hex_decode odd length 3")`
或 `(R.error, "crypto: hex_decode expects a hex digit at byte 4")`,偏移指向第一个
出错的字节。

## `crypto.sha2`——SHA-2 家族

```emo
class Digest {
  def write(data Bytes) Void
  def sum() Bytes
  def reset() Void
  def size() Int64
  def block_size() Int64
}

def new() Digest
def new224() Digest
def sha256(data Bytes) Bytes
def sha224(data Bytes) Bytes

class Wide {
  def write(data Bytes) Void
  def sum() Bytes
  def reset() Void
  def size() Int64
  def block_size() Int64
}

def new512() Wide
def new384() Wide
def new512_224() Wide
def new512_256() Wide
def sha512(data Bytes) Bytes
def sha384(data Bytes) Bytes
def sha512_224(data Bytes) Bytes
def sha512_256(data Bytes) Bytes
```

一次式回答整段输入的摘要:SHA-256 为 32 字节,SHA-224 为 28,SHA-512
为 64,SHA-384 为 48,SHA-512/224 为 28,SHA-512/256 为 32。两个类是
流式形状:`write` 吸收任意多段、任意大小的数据,`sum` 回答到目前为止
写入的全部内容的摘要并**让状态保持原样**——继续写就继续这条流,没有
写入就再 `sum` 一次回答同一个摘要——`reset` 把哈希器回到初始状态。
`size` 是摘要长度,`block_size` 是压缩块(`Digest` 64 字节,`Wide`
128)。`Digest` 承载两个 32 位字变体,`Wide` 承载四个 64 位字变体;工
厂名字就是变体。这里没有任何东西 raise。

## `crypto.sha3`——SHA-3 与 SHAKE

```emo
def sha3_224(data Bytes) Bytes
def sha3_256(data Bytes) Bytes
def sha3_384(data Bytes) Bytes
def sha3_512(data Bytes) Bytes
def shake128(data Bytes, length Int64) Bytes
def shake256(data Bytes, length Int64) Bytes
```

Keccak-f[1600] 置换之上的 FIPS 202。四个哈希回答 28、32、48、64 字节;
两个可扩展输出函数恰好回答 `length` 字节,任意长度,挤压按标准所述跨
过 rate 继续。负的 `length` raise。只做一次式:流式形状等一个消费者。

## `crypto.hash`——`Hash` 接口与 HMAC

```emo
interface Hash {
  def write(data Bytes) Void
  def sum() Bytes
  def reset() Void
  def size() Int64
  def block_size() Int64
}

def hmac_sha256(key Bytes, data Bytes) Bytes
def hmac_sha224(key Bytes, data Bytes) Bytes
def hmac_sha512(key Bytes, data Bytes) Bytes
def hmac_sha384(key Bytes, data Bytes) Bytes
def hmac_sha512_224(key Bytes, data Bytes) Bytes
def hmac_sha512_256(key Bytes, data Bytes) Bytes
```

`Hash` 是每个哈希器以形状作答的结构式接口——`crypto.sha2.Digest` 与
`crypto.sha2.Wide` 不用点名就满足它,所以收 `h crypto.hash.Hash` 参数
的函数两者都握得住。HMAC 函数(RFC 2104)回答 `data` 在 `key` 下、以
所指哈希算的 tag:密钥可以是任意长度——长于块先哈希,短于块补零——
tag 的长度是哈希的长度。一次式;比较 tag 走
`crypto.constant_time_compare`。这里没有任何东西 raise。

## `crypto.kdf`——HKDF 与 PBKDF2

```emo
def hkdf_sha256(ikm Bytes, salt Bytes, info Bytes, length Int64) Bytes
def hkdf_sha256_expand(prk Bytes, info Bytes, length Int64) Bytes
// …sha224、sha512、sha384、sha512_224、sha512_256 各有同样的一对

def pbkdf2_sha256(password Bytes, salt Bytes, iterations Int64, length Int64) Bytes
// …sha224、sha512、sha384、sha512_224、sha512_256 各有同样的一个
```

`hkdf_<alg>` 是 RFC 5869 的 extract-then-expand:伪随机密钥是
`hmac_<alg>(salt, ikm)`——空的 `salt` 代表 RFC 规定的哈希长度零字节——
输出是在 `info` 上展开的 `length` 字节。`hkdf_<alg>_expand` 单独是第二
步,给已经握有伪随机密钥的调用方(extract 步不另外导出:它*就是*那次
HMAC 调用)。构造自身的规则 raise:负的 `length`,以及超过哈希长度 255
倍的 `length`。

`pbkdf2_<alg>` 是 RFC 8018 的 PBKDF2,以 HMAC-`<alg>` 为伪随机函数:从
口令与盐经 `iterations` 轮得到 `length` 字节。负的 `length` raise,小于
一的 `iterations` 也 raise;次数本身是调用方的数字——包里没有工作因子
政策,经典的 4096 次编译后两秒、解释器一分钟。

## `crypto.cipher`——ChaCha20-Poly1305 与 AES

```emo
def chacha20(key Bytes, nonce Bytes, counter Int64, data Bytes) Bytes
def poly1305(key Bytes, message Bytes) Bytes
def chacha20_poly1305_seal(key Bytes, nonce Bytes, plaintext Bytes, aad Bytes) Bytes
def chacha20_poly1305_open(key Bytes, nonce Bytes, sealed Bytes, aad Bytes) (R, Bytes)

def aes_encrypt_block(key Bytes, block Bytes) Bytes
def aes_decrypt_block(key Bytes, block Bytes) Bytes
def aes_ctr(key Bytes, iv Bytes, data Bytes) Bytes
def aes_cbc_encrypt(key Bytes, iv Bytes, plaintext Bytes) Bytes
def aes_cbc_decrypt(key Bytes, iv Bytes, ciphertext Bytes) (R, Bytes)
def aes_gcm_seal(key Bytes, nonce Bytes, plaintext Bytes, aad Bytes) Bytes
def aes_gcm_open(key Bytes, nonce Bytes, sealed Bytes, aad Bytes) (R, Bytes)
```

**ChaCha20**(RFC 8439)回答 `data` 与密钥流的 XOR,密钥流来自 32 字节
密钥、12 字节 nonce 和初始块 `counter`(0 到 2^32 − 1)。**Poly1305**
回答 `message` 在 32 字节一次性密钥下的 16 字节 tag。**ChaCha20-Poly1305**
是 AEAD:`seal` 回答密文后接 16 字节 tag,`aad` 参与认证但不加密;
`open` 把这个盒子收回来,tag 验过时回答 `(R.ok, plaintext)`,没过时回
答 `(R.error, "crypto: authentication failed")`——翻一个字节、错的 AAD、
比 tag 还短的盒子、错的密钥,都是同一个值。密钥不是 32 字节、nonce 不
是 12 字节、计数器越界,都 raise。

**AES**(FIPS 197)收 16、24 或 32 字节的密钥——其余 raise——
`aes_encrypt_block`/`aes_decrypt_block` 是密码及其逆在一个 16 字节块上
的运算(别的长度 raise)。`aes_ctr`(SP 800-38A)回答 `data` 与密钥流的
XOR,16 字节 `iv` 是初始计数块,全部 128 位按大端递增;调用方的 `iv`
被复制,不被推进。`aes_cbc_encrypt` 用 PKCS#7 填充——每个填充字节都写
着填充自身的长度,所以输出永远是十六的倍数,本来就是整倍数的明文会多
出一整块——`aes_cbc_decrypt` 回答去掉该填充的明文:密文不是十六的正整
数倍 raise,填充读不回来是值 `(R.error, "crypto: invalid padding")`。
**GCM**(SP 800-38D)是 AEAD:12 字节 nonce(别的长度 raise),密文后
接 16 字节 tag,`open` 回答与 ChaCha20-Poly1305 相同的两个值。GHASH 是
纯位运算,没有查表。

两条构造无法替调用方强制的合同:

- **nonce 重用会不可挽回地破坏两个 AEAD。** 一对密钥与 nonce 只加密一
  次。流模式和计数器模式对密钥与计数块也是同一条规矩。
- **CBC 解密回答填充失败时不隐藏时序**,一个让攻击者观察到哪些密文失
  败的系统就是 padding oracle。先认证再解密——用 `hmac_sha256` 加
  `constant_time_compare` 做 encrypt-then-MAC,或者干脆用 GCM。

## `crypto.sign`——Ed25519

```emo
def ed25519_public(seed Bytes) Bytes
def ed25519_sign(seed Bytes, message Bytes) Bytes
def ed25519_verify(public Bytes, message Bytes, signature Bytes) Bool
```

RFC 8032 的 Ed25519。私钥是 RFC 称作 private key 的 32 字节 seed——其
余一切都由包从它派生,所以各门只收 seed、不收别的,而 seed 就是任意 32
字节的熵(`rand.bytes(32)`)。`ed25519_public` 回答 32 字节公钥;
`ed25519_sign` 回答消息的 64 字节签名,先 R 后 S,确定性的——同样的
seed 与消息永远回答同样的字节;`ed25519_verify` 回答该签名是否是此公
钥对此消息的签名。

验证器检查不带 cofactor 的群等式 [S]B = R + [k]A,即 Go 的
`crypto/ed25519` 检查的形式,并对错的消息、翻过的字节、不是 64 字节的
签名、不小于群阶的 S(RFC 拒绝的可塑孪生,于是每个签名恰有一种被接受
的形式)、解不出点的公钥,一律回答 `false`——同一个 `false`。seed 或公
钥不是 32 字节 raise。

## `crypto.ecdh`——X25519

```emo
def x25519(scalar Bytes, point Bytes) (R, Bytes)
def x25519_public(scalar Bytes) Bytes
```

RFC 7748 的 X25519,Curve25519 上的 Diffie-Hellman 函数。私钥是任意 32
字节——函数在入口处 clamp 它们,所以调用方只需要熵——`x25519_public`
回答 32 字节公钥,即标量乘以基点。`x25519(scalar, point)` 回答自己的标
量与对方公钥的共享密钥:`(R.ok, secret)`,32 字节;或当密钥算出全零
时回答 `(R.error, "crypto: x25519 low-order point")`——对方的点是小阶
点,密钥里没有这一侧的贡献。这就是 RFC 7748 §6.1 描述、Go 的
`crypto/ecdh` 执行的 contributory 检查;想要裸函数的全零答案的调用方
在这里拿不到。点的最高位按 RFC 要求被忽略。标量或点不是 32 字节 raise。

两侧派生同一个密钥:

```emo
const alice = crypto.ecdh.x25519_public(a)
const bob = crypto.ecdh.x25519_public(b)
// x25519(a, bob) 与 x25519(b, alice) 回答同样的 32 字节
```

把密钥交给密钥派生函数(`hkdf_sha256`,`info` 里放上两边的公钥)之后
再当密钥用。

## `crypto.legacy`——SHA-1 与 MD5

```emo
def sha1(data Bytes) Bytes
def md5(data Bytes) Bytes
```

**两者对一切安全用途都是坏的。** SHA-1 自 2017 年起有构造出的碰撞,
MD5 自 2004 年起;两者都回答不了任何新问题——不能做签名,不能做对手
能影响的完整性检查,不能做口令哈希。它们在这里是因为世界上的既有数据
仍需核对:旧 manifest 里的校验和、遗留协议里的指纹。模块名就是警告。
只做一次式——SHA-1 为 20 字节,MD5 为 16——这里没有任何东西 raise。
DES、RC4 与 DSA 不在包里,也不会进来。

## 常量时间:逐 target 承诺了什么

纪律是**源码级**的:在处理秘密的原语实现里,没有分支、没有内存下标取
决于秘密字节。Poly1305 与 Curve25519 的域算术是固定形状的肢算术加掩码
选择;Ed25519 标量乘是 double-and-add-always,无论标量是什么都是 256
步,带掩码选择;X25519 梯子经掩码交换;模群阶的标量归约是固定次数的掩
码试减;GHASH 无分支;`constant_time_compare` 累加每一个字节。有两处不
同,并如此写明:

- **AES 的 SubBytes 是以秘密字节为下标的查表。** S-box 是一张推导出的
  256 字节表(不是五张 T-table),周围的域乘无分支,但查表本身是一次地
  址取决于秘密的内存访问——共享机器上经典的缓存时序信道。`c` 上的
  AES-NI shim 是日后的可选加固。
- **公开数据可以随意比较、随意分支:** 验证器最后的相等判断、点解码、
  hex 解码、长度检查。这些路径上没有秘密。

源码纪律在每个 target 上变成什么,是该 target 的代码生成器与运行时的
性质,诚实的说法要逐 target 给。**包保证的是源码里的纪律,仅此而已;
没有任何一个 target 做过时序泄漏的测量。**

| Target | `Int64` 是什么 | 加上或失去了什么 |
|---|---|---|
| 解释器(`emo run`) | 树遍历求值器里装箱的 OCaml `int64` | 求值器每个操作都分配,它自身的控制流不受这条纪律约束;不能声称任何时序性质 |
| `ocaml` | OCaml 的 `int64`,很多位置是装箱的 | 算术编译成机器指令,但分配与 GC 在取决于数据的时刻运行;掩码选择是普通整数运算,编译器没有理由把它们改成分支——这不等于保证 |
| `c` | `int64_t` | 最直的一条路:掩码选择是普通整数运算;C 编译器仍可以合法地把 mask-and-xor 选择改写成分支,`Bytes` 访问器带边界检查(按下标分支,而下标永远不是秘密);机器码层面未经核验 |
| `typescript` | `BigInt` | 任意精度算术,代价取决于值的大小——从构造上就是时序信道,对这个 target 不做任何常量时间声称 |
| `wasm` | WebAssembly 的 `i64` | 算术是原生的;掩码选择变成什么由引擎的 JIT 决定,不做声称 |
| `beam` | Erlang 整数,每次运算后掩成 64 位 | 底下是任意精度——超出小整数范围的值变成堆上的 bignum——于是代价取决于值的大小,不做常量时间声称 |

实用的读法:在 `c` 与 `ocaml` 上,源码纪律值得拥有,也正是包所提供的;
在 `typescript`、`wasm`、`beam` 和解释器上,把包当作正确的、但不是抗侧
信道的,长期秘密不要放在这些 target 上,或不要放在共享硬件上。

## 向量

每个 golden 都是对 RFC 自身向量、以及(凡 Go 带有该原语之处)对提交机
器上 Go 标准库答案的一次 diff,两者一致后才冻结进 `expected.txt`:

- `examples/crypto_hash`——SHA-2 家族(RFC 6234 全套、55 到 129 字节的
  填充边界、0x00–0xFF 横扫、流式与 reset 面板)、SHA-3 家族与跨 rate 两
  个长度的 SHAKE、HMAC(RFC 4231 含 131 字节密钥)、HKDF(RFC 5869)与
  PBKDF2(RFC 7914 的一次与两次迭代)、legacy 一对、hex 编解码的边界——
  175 行与 Go 一致,在每个 target 上。
- `examples/crypto_aead`——ChaCha20 的块与流、Poly1305、ChaCha20-Poly1305
  的盒子连同三种伪造与跨块、跨 pad 边界的九个尺寸,对照 RFC 自身向量与
  一份按 RFC 直写的 Python 参照(Go 把这个构造留在标准库之外);AES 的
  三条 FIPS 197 已知答案及其逆、GCM 的 NIST 用例与九个尺寸、CBC 与 CTR
  各六个长度以及一次计数器进位——50 行与 Go 一致;在每个 target 上。
- `examples/crypto_sign`——RFC 8032 的五条向量(公钥、签名、验证)与六
  种拒绝——21 行与 Go 的 `crypto/ed25519` 一致,在每个 target 上。
- `examples/crypto_ecdh`——RFC 7748 的两条向量、§6.1 的双向交换、梯子的
  第一次迭代、两个低阶点拒绝及其原因、一次横扫——与 Go 的 `crypto/ecdh`
  一致,在每个 target 上。
- 仅 c——解释器十一到八十秒、编译后不到一秒:
  `examples/crypto_hash_million`(RFC 6234 的一百万个 `a`)、
  `examples/crypto_kdf`(4096 次迭代的 PBKDF2)、
  `examples/crypto_sign_sweep`(十三个消息长度)、
  `examples/crypto_ecdh_iterated`(RFC 7748 的一千次迭代)。

## Target 与性能

Target:全部五个——`ocaml`、`c`、`typescript`、`wasm`、`beam`——加解释
器,逐字节一致。解释器是慢的那条腿:一次 Ed25519 签名或验证约三分之一
秒,一次 X25519 协商约十分之一秒,一兆字节的 SHA-256 约二十秒,4096 次
迭代的 PBKDF2 一分钟,一千次 X25519 协商八十秒。编译后这些每一项都远
在一秒以内——一千次协商在 `c` 上 0.6 秒——所以交互式工作跑 `emo run`,
任何循环的东西跑构建产物。

熵不在这个包里:`rand.bytes` 是来源,`rand.drbg_sha256` 是可复现的流,
在独立的 `rand` 包里([`docs/zh-CN/stdlib/rand.md`](rand.md))。
