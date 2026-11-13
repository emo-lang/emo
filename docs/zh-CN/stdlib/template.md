# `template` 包

纯 Emo 写的文本模板引擎:文本加洞,从 `json` 上下文渲染——形状是 Go
`text/template` 的机制、Emo 自己的表面,五个托管目标逐字节给出相同答
案。服务端页面(`httpd`)、邮件、报表、生成的配置都从这里渲染。引擎里
没有任何运行时 `eval`,checker 也看不见模板里的表达式——模板的表达
式是 json 树上的数据路径,从来不是 Emo 代码。

## 使用包

```emo
require "template"
```

manifest 里钉上准确版本:

```emo
deps {
  "json" = "0.1.0"
  "template" = "0.1.0"
}
```

## 接口

```emo
def render(text String, ctx json.Json) (R, String)   // 一次成型:解析 + 渲染
def new() Set                                        // 空集合

// Set:
def with(name String, text String) (R, Set)          // 把 text 解析成 name
def render(name String, ctx json.Json) (R, String)   // 按名字渲染一个成员
```

`template.render(text, ctx)` 是渲一次的门:一次调用里解析并渲染。`Set`
是解析一次、渲染多次的形状——启动时用 `with` 搭好(每次调用都解析,坏
模板在第一次渲染之前就被拒绝),然后按名字逐请求渲染。`with` 应答新的
集合(builder-copy 形状),重定义一个名字会被拒绝——静默替换是调用方应
该看见的错误。

模板是带**动作**的文本。`{{ user.name }}` 从上下文渲染一个值;
`{{ name | upper }}` 在它上面跑过滤器管道;`{{ if }}` / `{{ else if }}` /
`{{ else }}` / `{{ end }}` 选择;`{{ for x in e }}` 遍历数组或对象;
`{{ template "name" e? }}` 引用集合里的具名模板;`{{- ` 和 ` -}}` 修剪
相邻空白;`{{! ... }}` 注释。

```emo
const text = "Hello, {{ user.name | upper }} of {{ user.city }}!"
const ctx = json.object(entries: [
  ("user", json.object(entries: [
    ("name", json.string("ada")),
    ("city", json.string("上海"))
  ]))
])
case template.render(text, ctx) {
  (R.error, why) -> { println("refused: " + why) }
  (R.ok, out)    -> { println(out) }        // Hello, ADA of 上海!
}
```

## 上下文是 json 树

`ctx` 是 `json.Json`——`json` 包解码和编码的值树——所以
`json.decode(text)` 可以直接渲染,程序自己的记录也用同一批构造器
(`json.string`、`json.int64`、`json.object`、`json.array`……)进上下文。
上下文根必须是对象:它的键就是模板点名的路径。

值的分工——洞渲染什么、拒绝什么:

- **字符串** 原样渲染。
- **整数** 十进制渲染(`3` → `3`)。
- **浮点** 走 `float` 包的精确十进制文本,与 `json.encode` 写出的同一
  份文本——`19.5` → `19.5`。
- **布尔** 渲染 `true` / `false`。
- **null** 拒绝:`template: at byte 214, `user.nick` is null and
  cannot render`。null 洞几乎总是数据形状出了意外;用
  (`{{ if user.nick }}...{{ end }}`) 守住它,或者给个兜底
  (`{{ user.nick | default("anon") }}`)。
- **数组或对象** 拒绝(`... is an array and cannot render`)——用
  `{{ for }}` 遍历它,或者用 `| length` / `| join`。

## 路径

路径是裸点分名加可选的方括号访问器——没有 Go 的点,没有 `$`:

```emo
{{ title }}            // 根键
{{ user.name }}        // 点分:对象逐键下钻
{{ users[0].name }}    // 数组下标(0 起,越界受检)
{{ m["a b"] }}         // 带引号的键(用语言的字符串转义)
```

**第一段**解析到最近的 `for` 绑定,否则解析到上下文根的键;更深的段在
数据里走。没有父级上溯,没有穿过数据的作用域链,没有根转义:绑定遮住
根里同名的键,作者给绑定起名时避开冲突。循环里裸名仍然够得着根
(`{{ for u in users }}` 里 `{{ title }}` 照常)——但循环元素要把绑定
拼出来:`{{ u.name }}`。

每次解析都在渲染时受检。缺键、中途类型不对、下标越界,都以
`(R.error, reason)` 应答,点名路径、字节、事实:

```emo
{{ user.phone }}       // `user.phone`: the object holds no key `phone`
{{ user.name.first }}  // `user.name` is a string, not an object
{{ tags[5] }}          // `tags[5]`: index 5 of 2
```

## 真值

`{{ if }}` 和 `{{ for }}` 的空判共用一条规则——**不是零值**:
`null`、`false`、`0`、`0.0`、空字符串、空数组、空对象为假;其余皆真。

```emo
{{ if tags }}Tags: {{ tags | join(", ") }}{{ end }}
{{ if premium }}premium{{ else if trial }}trial{{ else }}free{{ end }}
```

`{{ for }}` 带循环体和可选的 `{{ else }}`(零个元素、或零个条目时走):

```emo
{{ for i, t in tags }}{{ i }}:{{ t }} {{ end }}     // 0:go 1:emo
{{ for k, v in flags }}{{ k }}={{ v }} {{ end }}    // bold=true italic=false
{{ for x in empty }}row{{ else }}nothing{{ end }}
```

绑定的形式:**一个名字**绑定元素(数组)或值(对象);**两个名字**绑定
下标和元素,或键和值。数组、对象以外的东西参与遍历一律拒绝——null 也
一样,所以可选列表像 null 洞一样用 `{{ if }}` 守。

## 引用

`{{ template "name" }}` 渲染同一集合里的具名模板。不带管道时,被引模板
的上下文根就是调用方的根;带管道时,管道的值成为被引模板的根——点语义
去掉点。绑定不过引用边:被引模板只看见自己的根。

```emo
const (R.ok, s1) = template.new().with("page", "{{ template \"header\" }}{{ for r in rows }}{{ template \"row\" r }}{{ end }}{{ template \"footer\" }}")
const (R.ok, s2) = s1.with("header", "# {{ title }}\n")
const (R.ok, s3) = s2.with("row", "- {{ item }} x{{ qty }}\n")
const (R.ok, set) = s3.with("footer", "total: {{ rows | length }} rows\n")
```

未定义的名字在渲染时拒绝(`no template named `ghost``),引用循环骑到深
度上限(64)并在理由里点名它拒绝的链条,被引模板里的渲染错误带着它的名
字:`template: in `row`, ...`。

## 修剪标记与注释

`{{- ` 修剪动作之前文本的全部尾随空白;` -}}` 修剪动作之后文本的全部
前导空白。两者都贴在各自的动作上;短横必须贴住定界符
(`{{- if x }}...{{ end -}}`)。`{{! ... }}` 是注释——什么都不渲染,到
第一个 `}}` 结束。

```emo
"A\n  {{- if bold -}}\n  B\n  {{- end -}}\n  C"   // 渲染 ABC
"x{{! a note }}y"                                  // 渲染 xy
```

## 过滤器

七个,固定且 ASCII 安全——语言自己的 `String.lower` 就是 ASCII,Unicode
大小写映射器要等跨 target 一致的表:

```emo
{{ name | upper }}          // ASCII 大写
{{ name | lower }}          // ASCII 小写
{{ padded | trim }}         // 两端去 ASCII 空白
{{ tags | length }}         // 数组的条目、对象的条目、字符串的字节
{{ tags | join(", ") }}     // 元素按洞的规则渲染再拼接
{{ nick | default("anon") }} // 只有 null 落空——"" 是值
{{ bio | escape_html }}     // & < > " ' → &amp; &lt; &gt; &quot; &#39;
```

管道从左到右串(`{{ tags | join("|") | lower }}`),过滤器的实参是路径
或 `String` / `Int64` / `Bool` 字面量(`{{ scores[0] | default(0) }}`)。
类型不对在渲染时拒绝,理由带着过滤器名和拿到的类型
(`` `upper` expects a string, got a float ``)。

没有自定义过滤器表、没有算术、没有比较:过滤器实参不算东西,
`{{ a > b }}` 不是东西。模板渲染;程序计算——在 Emo 里预计算,把结果放
进上下文。

## 错误

每个失败都是值 `(R.error, reason)`;什么都不 raise。理由带着包前缀、事
实、模板里的字节位置;被引模板里的渲染错误带上它的名字
(`in `row`, `);引用深度上限点名链条。

解析从严(`dom.parse` 的方向):未闭合的 `{{`、空动作、不配对的
`{{ end }}` / `{{ else }}`、`{{ for }}` 缺 `in`、未知的过滤器名、过滤
器元数不对、悬着的 `.` 或 `[`、没闭合的字符串或注释、路径里的保留字、
嵌套超过 512,全部在解析时拒绝——绝不修一棵树凑合。动作之外的裸 `}}`
是文本,不是错误——代码生成模板的静态文本里到处是收口的嵌套花括号。

## 边界

- **目标:** 全部五个——`ocaml`、`c`、`typescript`、`wasm`、`beam`
  (纯 Emo,骑在字符串、数组和 json 树上)。
- **模板住在字符串里** ——文件的文本由 `file.read` 送进同一个 `with`
  调用;包自己不碰文件系统。
- **没有日期过滤器**——时间戳作为数据到达(`time` 包的 `format`
  家族在程序里做格式化),过滤器表因此保持固定且 ASCII 安全。
- `escape_html` 是显式的,不自动——上下文感知的 HTML 自动转义
  (`html/template` 那台机器)是后续弧线,`dom` 包是可能的地基。

参考:[`docs/zh-CN/stdlib/template.md`](stdlib/template.md) · 示例:
`examples/template_demo`、`examples/template_edge`。
