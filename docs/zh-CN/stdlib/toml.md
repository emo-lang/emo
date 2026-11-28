# `toml` 包

标准库的 TOML 读取与写出工具：TOML 1.1.0 解码为 `Toml` 值树（设计
与 json、yaml 包一致），再以文档形式编码回去。纯 Emo 实现，跑在共享
运行时之上；数字走 `float` 包的精确十进制转换——json、yaml、sql 共用
的那一个——各包彼此独立，require toml 不会连带 require json。

## 使用包

```emo
require "toml"
```

标准库随编译器一起发布，但各包和其他包一样带版本：`require "toml"`
需要在 manifest 的 `deps` 块里写上 `"toml" = "0.1.0"`。

## 值

解码得到的文档是一个 `Toml`：每个 TOML 类别一个类、共享一个接口。
TOML 没有 null，所以树里只有七个类别：`TomlBool`、`TomlInt`、
`TomlFloat`、`TomlString`、`TomlDateTime`、`TomlArray`、`TomlTable`,
用 `TomlKind` 枚举区分。标量访问器都在接口上，类别不符就 raise：

```emo
def as_bool() Bool
def as_int() Int64
def as_float() Float64
def as_string() String
def as_datetime() TomlDateTime
```

`TomlDateTime` 是一个独立的类，持有解析出的字段，每个部分一个方法：

```emo
def datetime_kind() TomlDateTimeKind   // toffset、tlocal_datetime、tlocal_date、tlocal_time
def year() Int64                        // Int64 字段;该形式没有的部分为 0
def month() Int64
def day() Int64
def hour() Int64
def minute() Int64
def second() Int64                      // 60 直接放行:RFC 3339 的闰秒
def nanosecond() Int64                  // 九位;规范要求更多位数一律截断
def offset_minutes() Int64              // 仅 toffset 携带:Z 为 0,东为正,西为负
def to_text() String                    // 规范文本,decode 能读回相同字段
```

数组和表把容器放在具体类上，经 `is()` 收窄后读取：

```emo
const (R.ok, doc) = toml.decode(text)
if doc.is(toml.TomlTable) {
  println(doc.get("title").as_string())
  const ports = doc.get("ports")
  if ports.is(toml.TomlArray) {
    println(ports.items().length().to_string())
  }
}
```

- `TomlArray` 持有 `items Array[Toml]`，提供 `items()`。
- `TomlTable` 持有 `entries Array[(String, Toml)]`，按文档顺序提供
  `entries()`;`get(key)` 返回 `key` 下的值，缺键 raise。
- 键是字符串：裸键 `1979` 和带引号的 `"1979"` 命名同一个键——decode
  拒绝任何键的第二种写法，所以不存在歧义。
- 每个访问器 raise 的是普通 Emo 异常，说明期望什么、得到了什么;
  `kind()` 无需猜测即可判别。

## 解码

```emo
def decode(text String) (R, Toml)
```

严格按 TOML 1.1.0 实现：裸键、带引号键和点分键;四种字符串形式
(basic、literal 和两种多行形式，含行尾 `\` 与 `\e`/`\xHH` 转义，
代理项必须成对);十进制、十六进制、八进制、二进制整数，下划线只在
数字之间;浮点数带小数部分和/或指数部分(只允许小写 `e`——文法本身
的写法——小数点两侧都必须有数字);全部四种日期时间形式(按 1.1
秒可省略，按 RFC 3339 允许小写 `t` 和 `z`，空格分隔符采取试错回退，
普通日期后面跟着其他文本时仍按日期读);数组带注释和尾逗号;inline
table 可跨行，带注释和尾逗号(均为 1.1);表、表数组，以及它们之间
的重复定义规则。

整个文档装配为一棵根表，条目按文档顺序排列。重复定义规则就是规范
的规则：任何写法下键只能定义一次;点分键造出的表不能再用 header
打开(`a.b = 1` 之后的 `[a.b]` 拒绝);inline table 一旦闭括号就不
再增长;`[[x]]` 只向数组追加;`[x]` 对隐式超表最多声明一次——
`[x.y.z.w]` 之后的 `[x]` 是规范自己给出的例外，可以工作。

所有不支持的东西都以 `(R.error, reason)` 返回，带字节偏移：`inf`
和 `nan` 浮点拼写(它们命名了包所声明的每个目标都无法承载的值);
超出 `Int64` 的整数;各种形状的畸形输入。reason 是 String，准确
说明错在哪——`toml: key \`a\` is defined twice at byte 6`。浮点
只舍入一次，就近取偶。

## 编码

```emo
def encode(v Toml) String     // 文档形式;v 必须是表
```

每个表先输出自己的标量与 inline 数组条目，然后每个子表一个
`[a.b]` 段、每个表数组的元素一个 `[[a.b]]` 段——这是表自身的文本
能表达的顺序，因为一个表的条目必须连续。元素并非全为表的数组走
inline，表元素也一并 inline;空数组同样走 inline，`[[x]]` 没有空的
写法。键能被裸键文法承载就输出裸键，否则输出带引号形式。字符串
输出为单行 basic string 加标准转义。浮点用与 json 包相同的
最短往返形式。`decode(encode(v)) == v` 在值层面成立;先定义子表、
后定义标量的文档会被编码为标量先行——这是格式唯一强制的重排。

树自身的 `encode()` 是值的字面形式——标量输出原文，数组输出
inline `[ ... ]`，表输出 inline `{ k = v, ... }`，日期时间走
`to_text()`。

## 构造值

工厂与类别一一对应(TOML 没有 null，也没有 datetime 工厂——直接
`TomlDateTime.new(...)` 构造)：

```emo
const doc = toml.table([
  ("service", toml.string("gateway")),
  ("ports", toml.array([toml.int64(8080)])),
  ("tls", toml.bool(true)),
])
println(toml.encode(doc))
```

`toml.float64(x)` 对非有限输入 raise——与 `decode` 的拒绝一致。

## 错误

划分遵循标准库的约定。畸形输入、不支持的值、规范拒绝的每一种重复
定义——数据可以是任何东西——都是 `decode` 的 `(R.error, reason)`
值，reason 是 String，准确说明错在哪(在哪个字节偏移)：匹配它，
不要猜。类别不符的访问器和缺键是调用方对文档的错误断言——那些
raise，终结进程。没有错误码，没有 nil。
