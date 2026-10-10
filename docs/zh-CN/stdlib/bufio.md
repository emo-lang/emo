# `bufio` 包

标准库的带缓冲 IO:在任意字节流前面放一块固定大小的内存缓冲,读方
用少量大读取替代大量小读取,写方把零碎写入合并成少量大写入,双方
在原始字节块之上获得整行读取和读到分隔符为止的读取。形态参照 Go
的 `bufio`:结构化小接口之上的 `Reader` 和 `Writer`,具体流的适配
器,以及由调用方显式定大小的缓冲区。

包是 `os` 之上的纯 Emo,所以它运行在 `os` 运行的目标上:ocaml 和
c 这两个有 Unix 形态宿主的目标。

## 使用包

```emo
require "bufio"
```

`require` 与清单严格配对:`bufio`(以及它依赖的 `os`)必须钉在
`package.emo` 里:

```emo
package {
  name = "acme/myapp"
  version = "0.1.0"
  targets = ["ocaml", "c"]

  deps {
    bufio = "0.1.0"
    os = "0.1.0"
  }
}
```

## 流的两个形状

两个接口,各一个方法,承载全部抽象:

```emo
interface ByteReader {
  def read(n Int64) String
}

interface ByteWriter {
  def write(data String) Int64
}
```

`read(n)` 返回至多 `n` 字节——只在流结束时更少——流耗尽后返回空
字符串,与 `os.read` 的约定完全一致。`write(data)` 要么收下全部字
节要么抛出;返回值是收下的字节数。任何具有匹配 `read` 或 `write`
方法的类都按形状满足接口——带缓冲的 `Reader` 本身就是
`ByteReader`,所以读取器可以层层叠加。

适配器交出具体的流:

```emo
def fd_reader(fd Int64) FdReader
def fd_writer(fd Int64) FdWriter

def bytes_reader(data String) BytesReader
def bytes_writer() BytesSink
```

fd 适配器通过 `os.read` 和 `os.write` 读写,文件、管道和其他一切
描述符流走同一个接口。内存中的一对让缓冲逻辑在没有幕后事物的情
况下可用:`BytesReader` 供给一个字符串的字节,`BytesSink` 收集交
给它的东西——它的 `to_string` 把积累的内容取回来,且不取空。

## 流结束是一个值

Emo 没有错误通道,所以流结束绝不是异常:空字符串表示流结束,与
`os.read` 定下的规则相同。`raise` 只留给调用者自己的错误——负的
数量、超过缓冲区的 peek、不是单字节的分隔符——以及底层流的失败
原样穿透。

`read_line` 有意保留行终止符:终止符是数据,空行必须与流结束可区
分,而且文件的最后一行可能没有终止符。只在有终止符时剥掉它:

```emo
const line = r.read_line()
if line != "" {
  var text = line
  if bufio.window(line, line.length() - 1, 1) == "\n" {
    text = bufio.window(line, 0, line.length() - 1)
  }
  // ...
}
```

## Reader

```emo
def default_size() Int64
def reader(src ByteReader) Reader
def reader_size(src ByteReader, size Int64) Reader
```

`default_size` 是 4096。大小必须为正——零或负的缓冲在构造时抛出。

```emo
def read(n Int64) String
def read_byte() String
def read_string(delim String) String
def read_line() String
def peek(n Int64) String
def discard(n Int64) Int64
def unread_byte() Void
def buffered() Int64
def reset(src ByteReader) Void
def fill_once() Bool
def fill_until(need Int64) Void
def consume_through(delim String, acc String) String
```

- `read(n)` — 至多 `n` 字节:先出缓冲,缓冲空了再读一次流。少于
  `n` 表示流已倾其所有;空字符串表示流结束。
- `read_byte()` — 一个字节,作单字节字符串;流结束时空字符串。
- `read_string(delim)` — 读到单字节分隔符的下一次出现为止,含终
  止符,跨多次填充累积:超出一个缓冲区大小的分隔符也能完整送达。
  空字符串表示流在任何字节到达之前就结束了;没有终止符的末尾残
  行按原样返回。
- `read_line()` — `read_string("\n")` 的别名:下一行,含终止符,
  流结束时空字符串。
- `peek(n)` — 填充到至少 `n` 字节在缓冲中,然后原样交回这 `n` 个
  字节,不消费。超过缓冲区大小的 peek 永远无法满足,抛出。
- `discard(n)` — 跳过至多 `n` 字节,返回实际跳过的数量。
- `unread_byte()` — 把最近读的一个字节推回去,一次:下一次读取
  会重新交回它。读取与推回之间发生填充会丢失该字节,调用抛出。
- `buffered()` — 缓冲中就绪、未被调用者读走的字节数。
- `reset(src)` — 从头开始:缓冲清空,读取从 `src` 继续。

`fill_once`、`fill_until` 和 `consume_through` 是上面各方法共享
的填充与扫描机制;包里的一切都在表面上,所以它们也是,源码中的
文档注释写明各自的约定。

## Writer

```emo
def writer(sink ByteWriter) Writer
def writer_size(sink ByteWriter, size Int64) Writer
```

```emo
def write(data String) Int64
def write_byte(b String) Void
def flush() Void
def buffered() Int64
def available() Int64
def reset(sink ByteWriter) Void
def push(data String) Int64
def write_rest(data String) Void
```

- `write(data)` — 缓冲字节,缓冲满时落盘。不小于整个空缓冲的写入
  直接通向 sink,不绕道缓冲。返回收下的字节数——永远是全部,否则
  抛出失败。
- `write_byte(b)` — 缓冲一个字节,作单字节字符串传入。
- `flush()` — 把缓冲中的每个字节交给 sink。sink 自身的失败原样穿
  透。
- `buffered()` — 等待下一次 flush 的字节数;`available()` — 缓冲
  自主落盘前剩余的空间。
- `reset(sink)` — 先冲刷未落盘的内容,再从 `sink` 从头开始。与
  Go 的 `Reset` 不同,这里不丢弃任何东西:会静默丢数据的包不严格。

`Writer` 必须在流结束前 `flush`——没有析构函数,缓冲里的尾巴归调
用者负责。

## 示例

`examples/bufio_demo` 端到端演练全部表面——内存流、经 8 字节缓冲
真实落盘的文件写入、再经两层叠加的读取器读回——其金子输出在解释
器和 c 目标上逐字节校验。
