# `json` 包

标准库的 JSON 读写器,用纯 Emo 写在共享运行时之上——字节、接口,以及
包内 `internal` 子树里的精确十进制浮点机制。没有针对单个目标的运行时
代码:所有能编译这门语言的目标,回答都逐字节一致。

## 使用包

```emo
require "json"
```

`require` 与清单严格配对:`json` 必须钉在 `package.emo` 里:

```emo
package {
  name = "acme/myapp"
  version = "0.1.0"
  targets = ["ocaml", "c", "typescript", "wasm", "beam"]

  deps {
    json = "0.1.0"
  }
}
```

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
const doc = json.decode(text)
if doc.is(JsonObject) {
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
def decode(text String) Json
```

严格、字节级、遵循 RFC 8259:重复键在 `get` 里后者获胜,前导零与
尾逗号拒绝,`\uXXXX` 转义连同代理对一起解码成 UTF-8,一切失败都带
字节偏移抛出——`json: expected array element at byte 3`。嵌套超过
512 层时抛出,而不是赌栈不会爆。能装进 `Int64` 的整数解码为
`JsonInt`;带小数或指数的一律解码为 `JsonFloat`,只做一次舍入,
就近取偶——与 `strtod` 同一答案。越界的数字(`1e400`)抛出,而不是
凭空造一个无穷大。

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

遵循标准库的约定,一切失败——输入非法、键缺失、访问器类别不符、
数字越界、浮点非有限——都抛出普通的 Emo 异常,写明到底哪里失败
(解码时还带字节偏移)。没有错误码,没有 nil。
