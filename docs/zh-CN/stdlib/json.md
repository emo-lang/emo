# `json` 包

标准库的 JSON 读写器,用纯 Emo 写在共享运行时之上——字节、接口,以及
`float` 包的精确十进制转换。没有针对单个目标的运行时代码:所有能
编译这门语言的目标,回答都逐字节一致。

## 使用包

```emo
require "json"
```

标准库随编译器一起发布,但它的包和其他依赖一样带版本:`require "json"` 需要在 manifest 的 `deps` 块里钉上 `"json" = "0.1.0"`。

## 值

解码得到的文档是一个 `Json`:接口之下,每种 JSON 类别对应一个类——
`JsonNull`、`JsonBool`、`JsonInt`、`JsonFloat`、`JsonString`、
`JsonArray`、`JsonObject`——由 `JsonKind` 枚举区分。标量访问器直接
挂在接口上,不必先问类别就能一步取到载荷;类别不符就抛出:

```emo
def as_bool() Bool
def as_int() Int64
def as_float() Float64
def as_string() String
```

数组与对象的容器挂在具体类上,通过 `is()` 收窄到类之后读取:

```emo
const (R.ok, doc) = json.decode(text)
if doc.is(json.JsonObject) {
  println(doc.get("name").as_string())
  println(doc.get("tags").items().length())
}
```

- `JsonArray` 持有 `items Array[Json]`,应答 `items()`。
- `JsonObject` 持有 `entries Array[(String, Json)]`,应答
  `entries()`;`get(key)` 返回 `key` 下的值——键重复时取最后一个——
  键缺失则抛出。
- 每个访问器都抛出普通的 Emo 异常,写明期望什么、实际是什么;
  `is_null?()` 与 `kind()` 用于不加猜测地判别。

## 解码

```emo
def decode(text String) (R, Json)
```

严格、字节级、遵循 RFC 8259:重复键在 `get` 里后者获胜,前导零与
尾逗号拒绝,`\uXXXX` 转义连同代理对一起解码成 UTF-8。一切非法输入——
包括嵌套超过 512 层、数字超出 `Int64` 或浮点范围——都以
`(R.error, reason)` 返回,而不是凭空造一个值:reason 是 String,
写明到底哪里失败、在第几个字节——`json: expected array element at
byte 3`。能装进 `Int64` 的整数解码为 `JsonInt`;带小数或指数的一律
解码为 `JsonFloat`,只做一次舍入,就近取偶——与 `strtod` 同一答案。

## 编码

```emo
def encode(v Json) String
def encode_pretty(v Json) String
```

`encode` 是紧凑形式;`encode_pretty` 用两空格缩进。字符串转义
`"`、`\` 与控制字符(`\b \f \n \r \t` 用短形式,其余用 `\u00xx`);
其余内容按其本来的 UTF-8 直通。整数走 `Int64.to_string`。浮点打印
"读回来逐位相同"的最短十进制——`0.1`、`3.141592653589793`、
`5.0e-324`——并且始终看得出是浮点(`1.0`,绝不是 `1`),因此
编码 → 解码 → 编码是恒等变换,值与类别都不变。非有限浮点抛出:
JSON 没有它的拼法。

## 构造值

工厂函数与类别一一对应;对象的键值用显式数组传入:

```emo
const doc = json.object([
  ("name", json.string("王晓明")),
  ("age", json.int64(28)),
  ("tags", json.array([json.string("a"), json.null()])),
])
println(json.encode_pretty(doc))
```

## 错误

分界遵循标准库的约定。非法输入——数据可以是任何东西——是 `decode`
返回的值 `(R.error, reason)`,reason 是 String,写明到底哪里失败
(解码时还带字节偏移):用 `case` 匹配它,不要猜。访问器类别不符、
键缺失、把非有限浮点交给 `encode`,是调用方对文档的错误断言——
这些抛出,终结进程。没有错误码,没有 nil。
