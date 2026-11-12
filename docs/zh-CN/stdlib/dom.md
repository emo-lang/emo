# `dom` 包

只读的 DOM:严格 HTML 解析成 `Node` 树,用 CSS 选择器查询——goquery 的形状,纯 Emo 写成,骑共享运行时,五个托管目标回答一致。

## 引入

```emo
require "dom"
```

manifest 里钉上精确版本:

```emo
deps {
  "dom" = "0.1.0"
}
```

## 解析:严格,不合成骨架

```emo
def parse(text String) (R, Document)
def encode(n Node) String
```

解析是严格的,与 `xml.decode` 同一方向:格式错误的输入以 `(R.error, reason)` 加字节位置回答,**绝不**返修一棵树。本包不合成 `html` / `head` / `body`——树忠实反映源码,片段解析出它点名的那些元素;`doc.roots()` 放源码顶层的那些节点(通常是一个 doctype、`html` 元素、以及它们周围的文本和注释)。

文档必须满足的规则:

- 每个开标签必须闭合,嵌套诚实:闭标签点名的必须是栈顶那个元素,否则解析失败并同时点名两边(`</i>` does not close the open `<b>` from byte 0`)。
- 十四个 void 元素(`br`、`img`、`input`、`meta`……)没有闭标签,也只有它们可以自闭合:`<br>` 和 `<br/>` 都行,`<div/>` 拒绝。
- 标签名和属性名折叠为小写(HTML 的规则);`script`/`style` 的内容是原始文本,`title`/`textarea` 是只含字符引用的文本,各自到大小写不敏感的闭标签为止——里面的标记不解析。
- 属性值双引号、单引号、不带引号或无值(`checked`);同一元素上重复的属性名拒绝。
- 文本解码 `&amp;` 式字符引用:六个常用命名实体(`amp`、`lt`、`gt`、`quot`、`apos`、`nbsp`)加 `&#ddd;` 和 `&#xhh;`。裸 `&` 和文本里的裸 `<` 拒绝——写成 `&amp;` / `&lt;`。格式良好但未知的名字(`&copy;`)按字面透传:源码写的就是这个。
- 注释和 `<!doctype ...>` 作为节点入树;CDATA 段和处理指令拒绝。
- 嵌套深过 512 拒绝。

## 节点模型

```emo
enum NodeKind { element, text, comment, doctype }

interface Node {
  def kind() NodeKind
  def id() Int64                    // 文档序号
  def is_element?() Bool
  def as_element() Element          // 调用者的断言;错类即 raise
  def tag() String                  // 元素;其他节点拒绝
  def attrs() Array[(String, String)]
  def attr(name String) (R, String)
  def children() Array[Node]
  def parent() (R, Node)
  def text() String
  def encode() String
}
```

`Element`、`TextNode`、`CommentNode`、`DoctypeNode` 实现这一整张脸;非元素对元素访问器拒绝,xml 的规则。`id()` 是解析器给的文档序号——两个节点比较身份就比它,在任何 Selection 操作中保持稳定。`parent()` 在文档根上回答 `(R.error, reason)`。元素上的 `text()` 是后代文本;文本和注释节点上是自身;doctype 是 `<!` 与 `>` 之间的文本。

`Document` 另有:

```emo
def roots() Array[Node]
def all() Selection        // 每个节点,文档序
def find(sel String) (R, Selection)
def encode() String
```

`encode` 写出规范化 HTML——属性双引号,`&` `<` `>` 转义,void 元素不带闭标签——所以 `parse(encode(x))` 复现这棵树;它与源码不逐字节相同,是规范化的。

## Selection

一个 `Selection` 是有序的一组节点;每个操作都回答新的 Selection,树本身永不被修改。门面跟 goquery 走:

```emo
sel.length() Int64
sel.nodes() Array[Node]
sel.at(i) (R, Node)
sel.eq(i) Selection        // 负数从尾部数;越界得空
sel.first() Selection
sel.last() Selection
sel.slice(start, end) Selection   // end 开区间;越界收敛,jQuery 的 slice

sel.attr(name) (R, String)       // 首节点;严格门
sel.attr_or(name, fallback) String
sel.text() String                // 每个节点的文本,按序
sel.html() String                // 首节点的 inner 标记
sel.outer_html() String

sel.find(sel) (R, Selection)     // 后代中命中的
sel.children() Selection          // 元素子节点
sel.children_filtered(sel) (R, Selection)
sel.contents() Selection          // 含文本和注释

sel.parent() Selection
sel.parents() Selection           // 由近及远
sel.parents_filtered(sel) (R, Selection)
sel.closest(sel) (R, Selection)   // 最近的祖先或自身

sel.next() Selection
sel.next_all() Selection          // 文档序
sel.next_filtered(sel) (R, Selection)
sel.prev() Selection
sel.prev_all() Selection          // 由近及远
sel.prev_filtered(sel) (R, Selection)
sel.siblings() Selection
sel.siblings_filtered(sel) (R, Selection)

sel.filter(sel) (R, Selection)    // 命中的那些
sel.not(sel) (R, Selection)       // 未命中的(非元素永不算命中,留下)
sel.has(sel) (R, Selection)       // 有命中后代者
sel.is?(sel) (R, Bool)            // 任一节点命中

sel.each(f Block) Selection       // f(i Int64, one Selection);可链
sel.each_with_break(f Block) Bool // f 答 false 提前停;整体答是否走完
```

凡是收选择器的门都先编译选择器;编译不过就从那扇门答错误。遍历按节点 id 去重并保持文档序(`parents` 和 `prev_all` 保持各自自然的由近及远序,与 goquery 一致)。`each` 骑尾随块:

```emo
sel.each() -> (i Int64, one dom.Selection) {
  println(i.to_string() + " " + one.text())
}
```

## 选择器

引擎对每扇门把选择器编译一次,在树上从右往左匹配:

- 复合选择器:类型(`div`,折叠为小写)、`*`、`.class`(大小写敏感,可多个:`.a.b`)、`#id`(大小写敏感)、属性测试——`[attr]`、`[attr=v]`、`^=`、`$=`、`*=`、`~=`、`|=`,值带引号或裸写。
- 组合器:后代(空白)、`>`、`+`、`~`;逗号分组(`h1, h2`)。
- 伪类:`:first-child`、`:last-child`、`:only-child`、`:nth-child(an+b)`(还有 `odd`、`even`、`2`、`-n+3`)、`:nth-last-child(...)`、`:first-of-type`、`:last-of-type`、`:only-of-type`、`:nth-of-type(...)`、`:not(compound)`、`:empty`、`:root`,以及 goquery 的 `:contains("text")`——对元素文本的大小写敏感子串测试。根元素按第一个孩子读,和浏览器读 `html` 一个意思。

其余一律带位置拒绝:伪元素(`::before` 及单冒号那些名字)、未知伪类、选择器字符串转义、畸形的属性测试、悬空的组合器。拒绝是收到选择器的那扇门答出的值——`find` 从不悄悄匹配成空。

## 错误

预期失败通篇是值,xml 的形状:

```emo
case dom.parse(page) {
  (R.error, why) -> { println(why) }   // "dom: ... at byte 84"
  (R.ok, doc)    -> { ... }
}
```

解析 reason 带字节位置和嵌套错误的两端;选择器 reason 带选择器内部的位置。节点无法诚实回答的访问器(文本节点上的 `tag()`)raise——调用者的断言,json 的规则。

## 示例

[`examples/dom_demo`](../../examples/dom_demo/) 让一页 HTML 走过 find、切片、属性、伪类、遍历、过滤、`each` 和编码回环;[`examples/dom_edge`](../../examples/dom_edge/) 走过严格拒绝、字符引用的角落、原始文本、属性形状、片段和选择器编译器的拒绝。两者在解释器和各编译目标上逐字节一致。

## 限制

- 无 DOM 修改:本包只读和查询;构建或改造树不是它的事。
- 无 HTML5 树构建:不合成 `html`/`head`/`body`,无隐式闭合(`<li>a<li>b` 拒绝),无 foster parenting——只严格读源码点名的东西。
- 只带六个常用命名字符引用;完整 HTML5 实体表不带。格式良好但未知的名字按字面透传。
- 选择器转义(`\.`)、命名空间、作为伪类的 `:has(...)`、大小写不敏感旗标都不带;伪元素拒绝。`has` 以 `Selection` 方法存在。
- `Add` / `AddBack` / `End`(选择器栈那几扇门)不带。
