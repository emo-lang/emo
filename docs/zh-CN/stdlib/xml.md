# `xml` 包

标准库的 XML 读写器:格式良好的 XML 解码为 `Xml` 值树——一个接口,
元素类与文本类——并可编码回去。纯 Emo 写在共享运行时之上。XML 一切
皆文本:任何东西都不会被强制转成数字或布尔,所有文本子节点(包括
纯空白的)都会保留,因此 encode(decode(x)) 能精确复现这棵树。

## 使用包

```emo
require "xml"
```

`require` 与清单严格配对:`xml` 必须钉在 `package.emo` 里:

```emo
package {
  name = "acme/myapp"
  version = "0.1.0"
  targets = ["ocaml", "c", "typescript", "wasm", "beam"]

  deps {
    xml = "0.1.0"
  }
}
```

## 值

解码得到的文档是一个 `Xml`:接口之下是 `XmlElement` 与 `XmlText`
两个类,由 `XmlKind` 枚举区分。标量访问器 `as_text()` 对文本节点
应答其字符,对元素拒绝。容器挂在元素类上,通过 `is()` 收窄读取:

```emo
const doc = xml.decode(text)
if doc.is(XmlElement) {
  println(doc.name())
  println(doc.attr("id"))
  println(doc.get("title").text())
}
```

- `XmlElement` 持有 `name String`、`attrs Array[(String, String)]`
  与 `children Array[Xml]`。访问器:`name()`、`attrs()`、
  `attr(name)`(属性缺失即抛出)、`children()`(全部子节点,按文档
  顺序)、`get(name)`(第一个该名字的子元素,缺失即抛出)、
  `text()`(子树内全部文本,按文档顺序拼接)。
- `XmlText` 持有其字符;`as_text()` 应答。
- 每个访问器都抛出普通的 Emo 异常,写明期望什么、实际是什么;
  `is_text?()` 与 `kind()` 用于不加猜测地判别。

## 解码

```emo
def decode(text String) Xml
```

严格并做良构性检查:元素按序嵌套闭合,闭合标签必须匹配,属性唯一
且带引号,文档恰好一个根。声明、注释、处理指令、无内部子集的
DOCTYPE 会被跳过;CDATA 段按原始文本解码;五个预定义实体加上
`&#ddd;` / `&#xhh;` 字符引用在文本与属性值里都会解码。名字按字面
处理——前缀保留在名字里,不做命名空间解析。一切失败都带字节偏移
抛出。

## 编码

```emo
def encode(v Xml) String
```

元素打印 `<name a="v">children</name>`,无子节点时自闭合
(`<name/>`)。文本转义 `&`、`<`、`>`;属性值额外转义 `"`。其余
内容按其本来的 UTF-8 直通——这棵树可以精确往返。

## 构造值

工厂函数与类别一一对应;属性与子节点用显式数组传入:

```emo
const note = xml.element("note", [], [
  xml.text("hello "),
  xml.element("b", [("k", "v")], []),
])
println(xml.encode(note))
```

## 错误

遵循标准库的约定,一切失败——标记非法、闭合标签不匹配、属性重复、
未知实体、元素或属性缺失——都抛出普通的 Emo 异常,写明到底哪里失败
(解码时还带字节偏移)。没有错误码,没有 nil。
