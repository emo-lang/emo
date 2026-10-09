# `yaml` 包

标准库的 YAML 读写器:YAML 1.2(核心模式)解码为 `Yaml` 值树——与
json 包的设计互为镜像——并以块风格编码回去。纯 Emo 写在共享运行时
之上;两个包相互独立——引入 yaml 不需要引入 json。

## 使用包

```emo
require "yaml"
```

`require` 与清单严格配对:`yaml` 必须钉在 `package.emo` 里:

```emo
package {
  name = "acme/myapp"
  version = "0.1.0"
  targets = ["ocaml", "c", "typescript", "wasm", "beam"]

  deps {
    yaml = "0.1.0"
  }
}
```

## 值

解码得到的文档是一个 `Yaml`:接口之下,每种 YAML 类别对应一个类——
`YamlNull`、`YamlBool`、`YamlInt`、`YamlFloat`、`YamlString`、
`YamlArray`、`YamlObject`——由 `YamlKind` 枚举区分。标量访问器直接
挂在接口上;类别不符就抛出:

```emo
def as_bool() Bool
def as_int() Int64
def as_float() Float64
def as_string() String
```

数组与对象的容器挂在具体类上,通过 `is()` 收窄到类之后读取:

```emo
const doc = yaml.decode(text)
if doc.is(YamlObject) {
  println(doc.get("service").as_string())
  println(doc.get("ports").items().length().to_string())
}
```

- `YamlArray` 持有 `items Array[Yaml]`,应答 `items()`。
- `YamlObject` 持有 `entries Array[(String, Yaml)]`,应答
  `entries()`;`get(key)` 返回 `key` 下的值——键重复时取最后一个——
  键缺失则抛出。
- 映射键是字符串(plain 键 `8080:` 保留其文本)。
- 每个访问器都抛出普通的 Emo 异常,写明期望什么、实际是什么;
  `is_null?()` 与 `kind()` 用于不加猜测地判别。

## 解码

```emo
def decode(text String) Yaml
```

严格、按行解析,遵循 YAML 1.2 核心模式:块映射与块序列(嵌套、
紧凑的 `- key: value` 形式、键下同层缩进的序列)、流式集合
(`[a, b]`、`{k: v}`)、单双引号标量(YAML 转义集,含 `\xXX`、
`\uXXXX`、`\UXXXXXXXX` 与代理对)、注释、`|` 字面与 `>` 折叠块标量
(带 `+`/`-` chomping),以及可选的前导 `---`。plain 标量按核心
模式解析:`null`/`~`、`true`/`false`(含大小写变体)、十进制整数、
`0x`/`0o` 整数、带 `.inf`/`.nan` 的浮点;其余一律是字符串。超出
Int64 的整数拒绝;浮点只舍入一次,就近取偶。

一切不支持的构造都带字节偏移抛出:锚点与别名、标签、多文档输入、
多行 plain/引号标量、多行流式、缩进中的 tab。

## 编码

```emo
def encode(v Yaml) String
```

块风格,两空格缩进,无尾随换行。字符串在"不会被误读"时按 plain
打印(绝不会解析成 `null`、布尔或数字;首尾无空格;无指示符字符;
内部无 `: ` 或 ` #`);其余以标准转义双引号输出。映射与序列为空时
打印 `{}` / `[]`。浮点与 json 包同为最短往返形式;非有限浮点抛出。

## 构造值

工厂函数与类别一一对应:

```emo
const doc = yaml.object([
  ("service", yaml.string("gateway")),
  ("ports", yaml.array([yaml.int64(8080)])),
  ("tls", yaml.object([("enabled", yaml.bool(true))])),
])
println(yaml.encode(doc))
```

## 错误

遵循标准库的约定,一切失败——输入非法、键缺失、访问器类别不符、
不支持的构造——都抛出普通的 Emo 异常,写明到底哪里失败(解码时还
带字节偏移)。没有错误码,没有 nil。
