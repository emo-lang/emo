# `csv` 包

标准库的 CSV 读写器:把 RFC 4180 记录表示成字符串字段的数组,只认
UTF-8。纯 Emo 写在共享运行时之上——字节与数组——所以每个能编译本
语言的目标都逐字节给出相同答案。

## 使用包

```emo
require "csv"
```

标准库随编译器一起发布:`require "csv"` 无需在 `package.emo` 中声明。

## 接口

```emo
def decode(text String) (R, Array[Array[String]])
def encode(rows Array[Array[String]]) String

def decode_delimited(text String, delimiter String) (R, Array[Array[String]])
def encode_delimited(rows Array[Array[String]], delimiter String) String
```

解码结果是 `Array[Array[String]]`:按文档顺序排列的记录,每条记录是
一串字符串字段。这里没有表头的概念——第一条记录只有在调用方按表头
读它时才是表头。它就是普通数据,所以 `rows.length()` 是记录数,
`rows[i]` 是一条记录,`rows[i][j]` 是一个字段,两份文档可以用 `==`
直接比较。

两个 `_delimited` 函数接受单字节分隔符——TSV 用制表符,欧洲惯例用
分号。`decode`/`encode` 是同一套文法在逗号下的特例。

```emo
require "csv"

const (R.ok, rows) = csv.decode("name,city\r\n\"Smith, John\",上海\r\n")
println(rows[0][0] + " / " + rows[0][1])      // name / city
println(rows[1][0] + " / " + rows[1][1])      // Smith, John / 上海
println(csv.encode(rows))                     // 记录按 RFC 4180 写回
```

## 解码

`decode` 对 CSV 文法和 UTF-8 都很严格。每次拒绝都是值
`(R.error, reason)`,reason 指出第一个出错的字节:

- **记录**在 CRLF、LF 或单独的 CR 处结束;三种都接受,所以 CRLF
  文件、Unix 文件、老式纯 CR 文件都能读。(引号字段内部的 CR 和 LF
  是数据。)
- **末尾**的换行结束最后一条记录,不会再开出一条空记录:
  `"a,b\n"` 是一条记录。中间的空行是一条"一个空字段"的记录。
- **空输入**是零条记录;`"\n"` 是一条"一个空字段"的记录。
- **字段**一直延伸到分隔符、换行或输入结束。不做任何裁剪:
  `" a , b "` 就是 `[" a ", " b "]`。
- **引号字段**以 `"` 开头、以 `"` 结尾,内部可以放分隔符、CR 和
  LF,字面引号写成 `""`。非引号字段里出现 `"` 是错误,闭合引号与
  下一个分隔符或换行之间出现任何文本同样是错误。
- 记录之间**允许字段数不一致**——每条记录有几个字段是它自己的事,
  CSV 没有模式。
- 开头的单个 UTF-8 **BOM** 是文件的编码标记,解析前去掉;出现在别
  处的 BOM 就是普通数据。
- 整个输入必须是合法的 **UTF-8**,每个字符只有一种编码:过长编码、
  代理区、超出 U+10FFFF 的码点都被拒绝,所以 `decode` 只接受
  `encode` 能产出的东西。

## 编码

`encode` 是 RFC 的规范写法:

- 每条记录以 **CRLF** 结尾,最后一条也不例外;零条记录编码为空
  字符串。
- 字段恰好在含有分隔符、`"`、CR 或 LF 时被**加引号**。引号字段内
  的 `"` 写成 `""`。除此之外不转义、不发明字节、不裁剪空格——所以
  `decode(encode(rows))` 就是 `rows`。
- 字段字节按其本身的 **UTF-8** 原样通过;不是合法 UTF-8 的字段会
  抛出,而不是输出解码器会拒绝的字节。

## 错误

划分沿用标准库的约定。输入数据可以任意,所以**格式错误**在
`decode` 里是值 `(R.error, reason)`,reason 是一个 String,写明
错在哪里、字节偏移是几:

```
csv: unterminated quoted field at byte 0
csv: unexpected quote in an unquoted field at byte 2
csv: stray text after a closing quote at byte 3
csv: invalid UTF-8 sequence at byte 0
```

调用方自己的**错误**会抛出并结束进程:分隔符不是单个 ASCII 字节,
或是引号、换行(`csv: the delimiter must be one byte, got 3`);交给
`encode` 的记录没有任何字段;以及 `encode` 读不成 UTF-8 的字段。
没有错误码,没有 nil。

## 目标

全部五个——`ocaml`、`c`、`typescript`、`wasm`、`beam`——各自逐字节
一致。golden(`examples/csv_demo`)骑在每一张目标名单上;边界矩阵
(`examples/csv_edge`)骑在解释器和本机二进制名单上。
