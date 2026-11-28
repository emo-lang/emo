# Emo 语言导览

这个导览是一份可以读、也可以跑的程序。每个标记为 `run` 的 Emo 块都会在
检查文档时编译成 Wasm 并执行;每个程序后面的块就是它打印的内容，一字不差。
这里没有示意性的伪代码。

如果你只有十分钟，读快速开始和头两章;如果你有一个下午，读完全部并把例子
敲一遍。

## 0 · 快速开始

Emo 的程序就是从上到下读的声明与语句。类是值类型，函数就是普通的 `def`,
购物车不过是一个 Item 数组:

```emo run id=quickstart
class Item {
  def init(name String, price Int64) {
    self.name = name
    self.price = price
  }
}

def total(items Array[Item]) Int64 {
  var sum = 0
  for var i = 0; i < items.length(); i = i + 1 {
    sum = sum + items[i].price
  }
  return sum
}

const cart = [Item.new(name: "tea", price: 12), Item.new(name: "cake", price: 30)]
println("${cart.length()} items, ${total(cart)} yuan")
```

```output
2 items, 42 yuan
```

那段程序里的一切都是普通语法:绑定是 `const` 或 `var`，调用有括号，
`for` 循环有三个子句，`return` 写在明处。Emo 没有隐式的"最后表达式作为
返回值"，没有继承，也没有模板语言。

## 1 · 值与绑定

`const` 绑定一次;`var` 绑定可变值，作用域是所在的块。数字、字符串与布尔
都是普通值，字符串里的 `${...}` 可以运行任意表达式:

```emo run id=values
const name = "Emo"
var visits = 3
visits = visits + 1
const ratio = 2.5
const flag = visits > 3
println("${name}: ${visits} visits, ratio ${ratio}, flag ${flag}")
println("7 / 2 = ${7 / 2}, 7 % 2 = ${7 % 2}")
println("1 + 2 * 3 = ${1 + 2 * 3}")
```

```output
Emo: 4 visits, ratio 2.5, flag true
7 / 2 = 3, 7 % 2 = 1
1 + 2 * 3 = 7
```

字符串是 UTF-8 字节序列，`Char` 是一个码点。字符串长度按字节计;
`chars()` 按码点遍历:

```emo run id=values-strings
const greeting = "hello"
println("${greeting}, world")
println(greeting.length())
println("a" + "b")
const c = '世'
println(c)
println(c.to_int64())
```

```output
hello, world
5
ab
世
19990
```

## 2 · 控制流

`if` 只有一种语句形状，`else` 可选;没有 `else if`，进一步的判断是可见地
嵌套的 `if`。单行形式是表达式，用来选一个值:

```emo run id=control-if
const n = 42
if n % 2 == 0 {
  println("${n} is even")
} else {
  println("${n} is odd")
}
const size = if n >= 40 { "big" } else { "small" }
println(size)
```

```output
42 is even
big
```

`for` 接受三个用 `;` 分隔的子句，并在头部绑定索引。`while` 判断一个条件。
`break` 离开最近的循环，`continue` 跳到下一次迭代，并先运行 `for` 的
post 子句:

```emo run id=control-loops
for var i = 1; i <= 3; i = i + 1 {
  println("i = ${i}")
}

var n = 3
while n > 0 {
  println("countdown ${n}")
  n = n - 1
}

for var j = 0; j < 6; j = j + 1 {
  if j == 1 {
    continue
  }
  if j == 4 {
    break
  }
  println(j)
}
```

```output
i = 1
i = 2
i = 3
countdown 3
countdown 2
countdown 1
0
2
3
```

## 3 · 函数与块

`def` 声明函数或方法。参数类型必须显式;返回类型写在参数表之后，声明了
返回类型的函数必须在每条路径上返回。实参可以按位置或按名字传递——具名
实参保持参数顺序:

```emo run id=functions-def
def area(width Int64, height Int64) Int64 {
  return width * height
}

def is_wide?(w Int64) Bool {
  return w > 100
}

println(area(3, 4))
println(area(width: 2, height: 5))
println(is_wide?(120))
```

```output
12
10
true
```

箭头块是匿名函数，调用可以把尾随块作为最后一个实参。接收块的函数把参数
声明为 `Block`，并像函数一样调用它:

```emo run id=functions-blocks
const double = -> (n Int64) { return n * 2 }
println(double(21))

def apply_twice(n Int64, f Block) Int64 {
  return f(f(n))
}
println(apply_twice(3, double))

def each(xs Array[Int64], f Block) {
  for var i = 0; i < xs.length(); i = i + 1 {
    f(xs[i])
  }
}

each([1, 2, 3]) -> (v Int64) {
  println(v * 10)
}
```

```output
42
12
10
20
30
```

函数可以用元组一次返回多个值，绑定模式把它拆开:

```emo run id=functions-tuples
def min_max(xs Array[Int64]) (Int64, Int64) {
  var lo = xs[0]
  var hi = xs[0]
  for var i = 1; i < xs.length(); i = i + 1 {
    if xs[i] < lo {
      lo = xs[i]
    }
    if xs[i] > hi {
      hi = xs[i]
    }
  }
  return (lo, hi)
}

const (lo, hi) = min_max([4, 1, 9, 3])
println("min ${lo}, max ${hi}")
```

```output
min 1, max 9
```

## 4 · 类与接口

`class` 是用户定义类型的唯一写法。字段只在 `init` 里通过 `self.x = ...`
产生，别处都不行——类是值类型，内容相等的实例 `==`:

```emo run id=objects-values
class Point {
  def init(x Int64, y Int64) {
    self.x = x
    self.y = y
  }

  def shifted(dx Int64, dy Int64) Point {
    return Point.new(x: self.x + dx, y: self.y + dy)
  }
}

const p = Point.new(x: 1, y: 2)
const q = p.shifted(3, 4)
println(p)
println(q)
println(p == Point.new(x: 1, y: 2))
```

```output
#Point(x: 1, y: 2)
#Point(x: 4, y: 6)
true
```

方法返回 Bool 时以 `?` 结尾。"修改"值的方法返回一个新实例，原值不变:

```emo run id=objects-methods
class Ticket {
  def init(price Int64, sold Bool) {
    self.price = price
    self.sold = sold
  }

  def sell() Ticket {
    return Ticket.new(price: self.price, sold: true)
  }

  def available?() Bool {
    return !self.sold
  }

  def describe() String {
    if self.available?() {
      return "ticket ${self.price}: available"
    }
    return "ticket ${self.price}: sold"
  }
}

const t = Ticket.new(price: 80, sold: false)
println(t.describe())
println(t.sell().describe())
println(t.available?())
```

```output
ticket 80: available
ticket 80: sold
true
```

`interface` 声明方法签名，满足是结构性的——没有 `implements` 声明，没有
继承。接口属于使用方:类永远不需要知道它存在:

```emo run id=objects-interfaces
interface Greeter {
  def greet() String
}

class English {
  def greet() String {
    return "Hello"
  }
}

class Chinese {
  def greet() String {
    return "你好"
  }
}

def welcome(g Greeter) String {
  return g.greet() + "!"
}

println(welcome(English.new()))
println(welcome(Chinese.new()))
```

```output
Hello!
你好!
```

## 5 · 枚举与 `case`

`enum` 是一组封闭的具名值。`case` 用一个值去匹配模式;分支写作
`pattern then { ... }`，第一个匹配者胜出，枚举匹配必须覆盖每个成员:

```emo run id=enums-color
enum Color {
  red,
  green,
  blue
}

def name(c Color) String {
  case c {
    Color.red then { return "red" }
    Color.green then { return "green" }
    Color.blue then { return "blue" }
  }
}

println(name(Color.red))
println(name(Color.blue))
```

```output
red
blue
```

分支可以带 `when` 守卫，元组被匹配值可以一次匹配多个事实。`_` 匹配任何
东西:

```emo run id=enums-case
def mood(n Int64) String {
  case n {
    0 then { return "zero" }
    _ when n < 0 then { return "negative" }
    _ then { return "positive" }
  }
}

def classify(n Int64) String {
  case (n % 2, n > 10) {
    (0, true) then { return "even and big" }
    (0, false) then { return "even and small" }
    (_, _) then { return "odd" }
  }
}

println(mood(0))
println(mood(-5))
println(mood(7))
println(classify(12))
println(classify(2))
println(classify(9))
```

```output
zero
negative
positive
even and big
even and small
odd
```

## 6 · 集合

数组是定长值，写作 `[a, b, c]`;`ArrayBuilder` 通过 push 增长，用
`to_array()` 交出数组:

```emo run id=collections-arrays
const xs = [3, 1, 4, 1, 5]
println(xs)
println(xs.length())
println(xs[0] + xs[4])

const ys = ArrayBuilder.new()
ys.push(2)
ys.push(7)
println(ys.to_array())
println(ys.length())
```

```output
[3, 1, 4, 1, 5]
5
8
[2, 7]
2
```

`Map` 可变且保持插入顺序，写作 `{ "key": value }`。`get` 读一个键，`set`
插入或替换并返回这个 map，`keys()`/`values()` 按插入顺序作答:

```emo run id=collections-maps
const ages = { "alice": 30, "bob": 25 }
ages.set("bob", 26)
println(ages)
println(ages.get("bob"))
println(ages.keys())
println(ages.has("carol"))
```

```output
{"alice": 30, "bob": 26}
26
[alice, bob]
false
```

## 7 · 错误是值

可能因数据而失败的调用返回元组:`(R.ok, value)` 或 `(R.error, reason)`。
`R` 是内建的结果枚举;用 `case` 匹配，编译器会把两个分支都看在眼里:

```emo run id=errors-matching
def parse_flag(raw String) (R, String) {
  if raw == "on" {
    return (R.ok, "flag is on")
  }
  return (R.error, "flag: expected `on`")
}

case parse_flag("on") {
  (R.ok, value) then { println(value) }
  (R.error, why) then { println("read failed: ${why}") }
}

case parse_flag("off") {
  (R.ok, value) then { println(value) }
  (R.error, why) then { println("read failed: ${why}") }
}
```

```output
flag is on
read failed: flag: expected `on`
```

绑定模式断言形状并绑定载荷。不匹配的模式是运行时错误，所以只在调用方已经
知道该调用不会失败时使用:

```emo run id=errors-binding
def half(n Int64) (R, Int64) {
  if n % 2 != 0 {
    return (R.error, "half: odd input")
  }
  return (R.ok, n / 2)
}

const (R.ok, value) = half(8)
println(value)
```

```output
4
```

违例——破坏调用纪律，而不是数据——用 `raise`。`:raise` 借用这个关键字，
改写成异常构造器。这个块不执行:raise 会结束进程，没有可通过的运行可
展示:

```emo no-run id=errors-raise
def check(n Int64) Int64 {
  if n < 0 {
    :raise "check: negative input"
  }
  return n
}
```

## 8 · 模块与包

文件就是模块，目录就是模块路径。包是模块前缀:`require "json"` 把标准库
的 JSON 包引入作用域，manifest 钉住版本。没有安装步骤——编译器把标准库
带在二进制里。

```emo run id=modules-json-decode deps=json
require "json"

const (R.ok, doc) = json.decode("{\"name\": \"tea\", \"price\": 12}")
if doc.is(json.JsonObject) {
  println(doc.get("name").as_string())
  println(doc.get("price").as_int())
}
```

```output
tea
12
```

同一个包也能构造文档，不只是读取。对象与数组由显式的键值对和数组搭起来，
`encode` 写出紧凑形式:

```emo run id=modules-json-build deps=json
require "json"

const order = json.object([
  ("id", json.int64(7)),
  ("tags", json.array([json.string("fresh"), json.string("hot")]))
])
println(json.encode(order))
```

```output
{"id":7,"tags":["fresh","hot"]}
```

## 9 · 进程

进程很便宜:`do call()` 启动一个，并给出它的 pid。消息用 `<-` 发送，
`receive` 用分支去匹配邮箱头部的消息。语言还提供**选择性**接收——一个
守卫(`n when n > 3`)或一个头部不匹配的模式会让邮箱被扫描，不匹配的
消息留在队列里——但本树中的 Wasm 后端只分派头部，所以下面的可运行块都用
FIFO 接收。

```emo run id=processes-pingpong
def worker(boss Pid, n Int64) {
  boss <- n * 2
}

const me = self_pid()
do worker(me, 21)
receive {
  answer then { println(answer) }
}
```

```output
42
```

消息按到达顺序排队，每个 `receive` 取走头部。在 Wasm 上 `receive` 必须是
它所在体的最后一条语句，所以第二次取用要写成一个独立函数:

```emo run id=processes-queue
def first(boss Pid) {
  boss <- "first"
}

def second(boss Pid) {
  boss <- "second"
}

def take() {
  receive {
    msg then { println(msg) }
  }
}

const me = self_pid()
do first(me)
do second(me)
take()
take()
```

```output
first
second
```

## 10 · 一个小业务切片

各部分在一个程序里会合:来自外部世界的 JSON、承载领域值的类、为可能出错
的数据准备的 `(R, …)`、为报表准备的 `Map`，以及用整数运算处理金额。它
解码一笔订单，逐行校验，按类别汇总，再加上税额——一个小服务的形状:

```emo run id=business deps=json
require "json"

class Line {
  def init(name String, category String, price Int64, qty Int64) {
    self.name = name
    self.category = category
    self.price = price
    self.qty = qty
  }

  def subtotal() Int64 {
    return self.price * self.qty
  }
}

def parse_line(item json.Json) (R, Line) {
  if item.is(json.JsonObject) {
    const name = item.get("name").as_string()
    const category = item.get("category").as_string()
    const price = item.get("price").as_int()
    const qty = item.get("qty").as_int()
    if qty <= 0 {
      return (R.error, "order: ${name} has no quantity")
    }
    return (R.ok, Line.new(name: name, category: category, price: price, qty: qty))
  }
  return (R.error, "order: line is not an object")
}

const text = "{\"tax\": 10, \"lines\": [{\"name\": \"tea\", \"category\": \"drink\", \"price\": 12, \"qty\": 2}, {\"name\": \"cake\", \"category\": \"food\", \"price\": 30, \"qty\": 1}, {\"name\": \"coffee\", \"category\": \"drink\", \"price\": 20, \"qty\": 1}]}"
const (R.ok, doc) = json.decode(text)
if doc.is(json.JsonObject) {
  const lines = doc.get("lines")
  if lines.is(json.JsonArray) {
    const totals = { "drink": 0, "food": 0 }
    const items = lines.items()
    for var i = 0; i < items.length(); i = i + 1 {
      case parse_line(items[i]) {
        (R.ok, line) then {
          const category = line.category
          if totals.has(category) {
            totals.set(category, totals.get(category) + line.subtotal())
          } else {
            totals.set(category, line.subtotal())
          }
        }
        (R.error, why) then {
          println("skip: ${why}")
        }
      }
    }
    var net = 0
    const categories = totals.keys()
    for var i = 0; i < categories.length(); i = i + 1 {
      net = net + totals.get(categories[i])
    }
    const tax = net * doc.get("tax").as_int() / 100
    println(totals)
    println("net ${net}, tax ${tax}, total ${net + tax}")
  }
}
```

```output
{"drink": 44, "food": 30}
net 74, tax 7, total 81
```

程序从不问"这会不会是 null":一个值就是 `Json`,`is()` 收窄证明它的
形状，解析失败是 `case` 处理的值。领域类承载算术，`Map` 让报表保持类别
首次出现的顺序。

## 11 · 接下来

你现在已经知道这门语言的形状:显式的调用、`const`/`var`、作为不可变值
类型的类、结构化接口、带守卫的 `case`、集合、`(R, …)` 错误、包，以及
进程。

接下来的阅读:

- [`examples/language_tour/`](../../../examples/language_tour/) —— 一个更长的
  程序，在每个目标上运行，并带有 golden 输出。
- [`docs/intro/syntax.md`](syntax.md) —— 完整语法参考，包括糖
  (`:chain`、`:foreach`、`:when`)与命名规则。
- [`docs/intro/type-system.md`](type-system.md) —— 渐近类型、显式
  位宽的数值与收窄。
- [`docs/stdlib.md`](../stdlib.md) —— 标准库:JSON、YAML、TOML、HTTP、SQL、
  crypto、绘图，等等。
- [`docs/intro/testing.md`](testing.md) —— `emo test` 与 `expect_*`
  断言(仅解释器，所以本导览不运行它们)。
- [`docs/intro/concurrency.md`](concurrency.md) —— 进程、消息传递与
  调度器。

语言之外，EmoUI 用同样的普通语法构建界面，EmoOS(及其桌面)把同样的代码
带到裸机，playground 在浏览器标签页里运行 Emo。范围地图从
[项目 README](../../../README.md) 开始。
