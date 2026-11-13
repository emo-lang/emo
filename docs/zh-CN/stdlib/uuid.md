# `uuid` 包

RFC 9562 的 UUID 标准库包:标识符是一个不可变的 16 字节值,各个版本
是具名的门,文本形式和字节形式都是严格的转换。纯 Emo,骑共享运行时
——摘要来自 `crypto`,熵来自 `rand`——所以每个 target 逐字节给出同样
的答案。

值是不透明的,这是 RFC 自己的建议(6.12 节):UUID 被构造、比较、排
序、渲染,它的字段只在 RFC 点名的地方读回。UUID 就是任意 16 字节
——`parse` 严格针对文本,不针对比特,所以自定义和保留的布局坐同一
个值。

## 使用包

```emo
require "uuid"
```

标准库随编译器一起发布,但它的包和其他依赖一样带版本:`require
"uuid"` 需要在 manifest 的 `deps` 块里钉上 `"uuid" = "0.1.0"`。

## 值

`Uuid` 是一个类,也是普通的值:不可变,赋值即拷贝,`==` 按字节比较。
从不是 16 字节的字节数构造 UUID 会 raise——这个类型按定义就是 16 字节。

```emo
def to_string() String      // 小写 hex-and-dash,RFC 9562 自己的形式
def to_bytes() Bytes        // 那 16 字节,大端字段序(第 4 节)
def version() Int64         // 第 6 个字节的高 4 位,0 到 15
def variant() UuidVariant   // ncs、rfc、microsoft、future(表 1)
def is_nil?() Bool          // 128 位全零(5.9 节)
def is_max?() Bool          // 128 位全一(5.10 节)
def compare(other Uuid) Int64
```

`to_string` 是协议方法,所以 `println(id)` 打印的就是标识符本身——
小写 hex-and-dash,RFC 的 ABNF 定义的形式,无论解析它的文本是什么大
小写。

`compare` 是 RFC 9562 的排序(6.11 节):大端字节从左到右比较——在前
答 `-1`,在后答 `+1`,相等答 `0`。这是数据库索引免费拿到的顺序,也
是时间有序的版本排序所用的顺序。

`variant` 按表 1 的读法读第 8 个字节的最高位:`ncs`(Apollo NCS 向后
兼容区间,Nil UUID 落在这里)、`rfc`(本文档的 variant,版本 1 到 8
落在这里)、`microsoft`,以及 `future`(Max UUID 落在这里)。

## 构造

```emo
def nil() Uuid                      // 00000000-0000-0000-0000-000000000000
def max() Uuid                      // ffffffff-ffff-ffff-ffff-ffffffffffff
def from_bytes(data Bytes) (R, Uuid)
def parse(text String) (R, Uuid)
def v4() (R, Uuid)
def v7(now_ms Int64) (R, Uuid)
def v3(namespace Uuid, name String) Uuid
def v5(namespace Uuid, name String) Uuid
def ns_dns() Uuid
def ns_url() Uuid
def ns_oid() Uuid
def ns_x500() Uuid
```

`from_bytes` 对任意 16 字节都回答值——UUID 就是这些字节,无论
version 和 variant 字段装着什么——长度不是 16 时以 `(R.error,
reason)` 拒绝。

`v3` 和 `v5` 是全函数且确定性:同样的 namespace 和 name 在每个
target 上永远回答同一个 UUID。任意 `Uuid` 都可以充当自定义
namespace,正如 6.6 节所安排;四个 namespace 门回答表 3 里 IANA 注册
的 ID,name 是它的 namespace 自己的规范所陈述的文本——DNS 的主机
名、URL 规范所陈述的 URL、点号不带前导点的 OID、X.500 的可分辨名。

## 版本

**v4**——122 个随机位,骑操作系统的熵源(`rand.bytes`,6.9 节),
version 和 variant 字段盖在抽取之上。通用的门:熵源拒绝时回答
`(R.error, reason)`,reason 是 `rand` 包自己的。

**v7**——Unix 纪元的毫秒数,从调用方自己的时钟(`time.now()`,
`time` 包)读出后传入——包本身不碰时钟——其上是 74 个随机位,即
RFC 的基础形状(5.7 节)。`v7(1645557742000)` 是这通调用;时钟归调用方,同一毫秒里
铸出的两个 UUID 各不相同但无序——6.2 节的生成器状态计数器由调用方
自己跑。负的时间戳 raise;装不进 48 位字段的时间戳同样 raise——这
个字段诚实地管到公元 10889 年,再大就是单位错误,不是时间。

**v3 与 v5**——MD5 与 SHA-1,骑 namespace 和 name 的 UTF-8 字节,取
摘要的前 16 字节填进布局,version 和 variant 盖在上面(5.3、5.5 节)。
v3 走 `crypto.legacy.md5`,v5 走 `crypto.legacy.sha1`,对一切安全用
途都已攻破、为既有数据而存在;RFC 自己的建议——能用 v5 就用 v5——照
样成立。

不在包内的版本,点名:**v1、v2、v6** 需要格里高利时间戳、node 和
clock sequence 的生成器状态——RFC 第 8 节不鼓励的 MAC 地址,以及包
不持有的生成器状态(RFC 6.2 节说,不涉及旧式 UUIDv1 的系统应该改用
UUIDv7)。**v8** 不需要构造器:自定义布局就是调用方普通的 `Bytes`
代码——把第 6 个字节的高 4 位设成 `8`、第 8 个字节的最高两位设成
`10`,其余 122 位按设计填,把这 16 字节交给 `from_bytes`。

## 文本形式

`parse` 恰好接受规范的 hex-and-dash 形式,别的都不收:36 个字符,第
8、13、18、23 位是连字符,其余是十六进制数字。十六进制数字不区分大
小写,正如 RFC 自己的 ABNF 所读(两种大小写都是 HEXDIG),答案一律
渲染成小写。`{...}` 的花括号、`urn:uuid:` 前缀、以及 32 字符的无连
字符形式,是别的系统的表现法——调用方自己、可见地剥掉它们,然后再调
用。

每次拒绝都是 `(R.error, reason)`,reason 点名第一个出错的字节:

```
uuid: expected 36 characters, got 32
uuid: expected a dash at byte 8
uuid: expected a hex digit at byte 35
```

`MustParse` 没有门,因为 Emo 已经持有这个构造:绑定模式,不匹配即
raise。

```emo
const (R.ok, id) = uuid.parse(text)
```

## 向量

golden(`examples/uuid_demo`)骑 RFC 自己的向量:图 1 的例子被解析、
渲染、读回;附录 A.2 和 A.4 的 name-based 值——DNS 与
`www.example.com`,v3 `5df41881-3aed-3515-88a7-2f4a814cf09e`,v5
`2ed6657d-e927-568b-95e1-2665a8aea6a2`;表 3 的四个 namespace ID;
Nil 与 Max UUID;附录 A.6 的时间戳从一次 v7 抽取里读回;以及严格的
拒绝。随机的门只打印 RFC 对它们钉死的东西——version、variant、时间
戳、顺序,以及两次抽取不同——所以 golden 在解释器、`c`、`ocaml`、
`typescript`、`wasm`、`beam` 上逐字节一致。
