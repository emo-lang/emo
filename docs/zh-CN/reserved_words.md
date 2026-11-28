# 保留字

Emo 保留一组小而固定的词。lexer 在标识符之前识别它们，所以它们都不能
用作变量、参数、字段、函数、类、接口、枚举或函数组的名字。任何需要
名字的位置，保留字都会得到一条说明这一点的编译错误：

```text
expected a def name, found `if` (a reserved word)
```

保留字是小写且大小写敏感的。它们的大写拼写(`Def`、`Class`、`Self`)
是普通类型名。

## 完整清单

| 词 | 作用 |
| --- | --- |
| `break` | 离开最近的外层循环。 |
| `case` | 模式匹配语句。 |
| `class` | 类声明。 |
| `const` | 不可变绑定。 |
| `continue` | 跳到下一次循环迭代。 |
| `def` | 函数或方法定义。 |
| `do` | 从一次调用启动进程，并给出它的 pid。 |
| `else` | `if` 的另一分支。 |
| `emo` | 函数组声明;`emo.` 引导运行时命名空间。 |
| `enum` | 枚举声明。 |
| `for` | 三子句循环。 |
| `if` | 条件语句，或单行条件表达式。 |
| `interface` | 接口声明。 |
| `raise` | 抛出一个 `Exception`。 |
| `receive` | 从进程邮箱选择性接收。 |
| `require` | 把一个包的短名引入作用域。 |
| `return` | 从函数返回。 |
| `self` | 类方法内的当前实例。 |
| `then` | 引入 `case` 或 `receive` 分支的体。 |
| `var` | 可变的块作用域绑定。 |
| `when` | `case` 或 `receive` 分支上的守卫。 |
| `while` | 条件循环。 |

## 声明

- **`def`** 定义函数或方法，顶层与类内的形式相同：
  `def total(cart Cart) Decimal { ... }`。`def` 的名字可以 `?` 结尾以表示
  谓词;其他名字不行(见下文)。
- **`class`** 声明类。所有字段都在 `init` 里通过 `self.x = ...` 产生，
  类没有继承。
- **`emo`** 声明函数组——一组有名字、无状态的函数与常量：没有实例、
  没有字段、没有 `init`。后面跟一个点时，`emo` 引导编译器的运行时
  命名空间：`emo.file_read(path)` 到达标准库 `file.read` 所包装的
  运行时门。
- **`interface`** 声明一组方法签名。满足是结构性的，没有 `implements`
  声明。
- **`enum`** 声明一组封闭的具名值：`enum Color { red, green, blue }`。

```emo
class User {
  def init(name String) {
    self.name = name
  }

  def display_name() String {
    return self.name
  }
}

interface Greeter {
  def greet() String
}

emo Math {
  const tau = 6

  def abs(x Int64) Int64 {
    if x < 0 {
      return 0 - x
    }
    return x
  }
}
```

## 绑定

- **`const`** 引入不可变绑定。
- **`var`** 引入可变绑定，作用域是它所在的块。`var` 不能逃出它的块;
  在生命周期长于该块的闭包里捕获它，是编译错误。

两者都接受一个完整模式来代替普通名字。不匹配的模式是运行时错误。

```emo
const (R.ok, body) = file.read(path)
var count = 0
```

## 控制流

- **`if`** / **`else`**——只有一种语句形状：`if cond { ... }`，可选
  `else { ... }`。没有 `else if`;进一步的判断是嵌套在 `else` 块里的
  `if`。单行形式是表达式，两个分支都必需：
  `const label = if n >= 90 { "high" } else { "low" }`。
- **`for`**——三子句循环：`for var i = 0; i < 100; i = i + 1 { ... }`。
  三个子句都必需，且 `;` 只在 `for` 头部合法。
- **`while`**——条件循环：`while running { ... }`。
- **`break`** 离开最近的外层循环，**`continue`** 跳到下一次迭代，并先
  执行 `for` 的 post 子句。两者在循环之外都是错误。
- **`case`** 用模式匹配一个值。分支写作 `pattern then { ... }`，第一个
  匹配者胜出，没有分支匹配的被匹配值是运行时错误。枚举匹配在类型可
  判定的地方必须覆盖每个成员。
- **`when`** 给分支加守卫：
  `Color.red when signal.is_bright?() then { ... }`。
- **`then`** 引入分支的体：每个 `case` 与 `receive` 分支都读作
  `pattern then { ... }`(有守卫时，守卫位于模式与 `then` 之间)。
  箭头不进分支位置——`->` 只属于参数化的块、匿名函数，别的都不属于。

```emo
if n >= 90 {
  println("high")
} else {
  println("low")
}

for var i = 0; i < 100; i = i + 1 {
  if i == 10 {
    break
  }
  if i % 2 == 0 {
    continue
  }
}

case color {
  Color.red when signal.is_bright?() then {
    println("bright red")
  }
  Color.red then {
    println("dark red")
  }
  Color.green then {
    println("green")
  }
}
```

## 函数与错误

- **`return`** 从函数返回。声明了返回类型的函数必须在每条路径上以
  `return` 结束;没有"最后一个表达式就是返回值"的隐式规则。Void 函数
  完全不写 `return`。
- **`raise`** 抛出异常。它的操作数必须是 `Exception` 实例，而且抛出
  无法捕获。`:raise` 糖把这个词借作自己的名字，并改写成下面写出的
  构造调用。

```emo
def discount(cart Cart) Int64 {
  if cart.total() < 0 {
    raise Exception.new(message: "negative total")
  }
  return cart.total() * 9 / 10
}
```

## 进程

- **`do`** 从一次调用启动进程，并给出新进程的 pid;调用自身的结果被
  丢弃。它的操作数必须是调用：`const worker = do work(item)`。
- **`receive`** 接受与 `case` 相同的分支，扫描邮箱，取第一条匹配任一
  分支的消息。不匹配的消息留在队列里，什么都不匹配时进程阻塞。

```emo
receive {
  (from, request) then {
    from <- (self_pid(), handle(request))
  }
}
```

## 模块与包

- **`require`** 是文件级语句，把一个包的短名引入作用域：
  `require "acme/json_tools"`。每个 `require` 在 manifest 里都配对一条
  `deps` 钉，标准库也不例外。

## 保留字面量

**`true`** 与 **`false`** 是 Bool 字面量。lexer 把它们作为字面量 token
发出，所以它们和上面的关键字一样不能用作名字。

## 编译器保留的名字

有两个大写名字内建于每个程序，不能声明：

- **`R`**——内建的结果枚举，成员为 `ok` 与 `error`。
- **`Exception`**——内建的异常类。

与上面清单里的词不同，它们不是 lexer 关键字;checker 拒绝用其中任一
名字声明的类、接口、枚举或函数组。

## 模式通配符

在模式里——`case` 或 `receive` 的分支，或绑定的模式——**`_`** 匹配
任何东西，且不绑定任何东西：

```emo
case pair {
  (_, count) then {
    println(count)
  }
}
```

`_` 不是关键字;通配含义只在模式位置适用。

## 其他保留形式

- **尾部的 `?`** 保留给 `def` 名字。它必须是名字的最后一个字符，其他
  任何声明或绑定都不能使用。
- **`@`、`$` 与 `#`** 在字符串与字符字面量之外没有含义;lexer 拒绝
  它们。

## 看似特殊但未保留的词

下面两个词看起来特殊，其实是普通标识符：

- **`foreign`** 只在顶层条目的开头选择 C FFI 形式，那里 `foreign def`
  声明一个到 C 符号的绑定。别处它是普通名字。
- **`init`** 只在类内的 `def` 上命名构造器。类之外，`def init` 是错误;
  名为 `init` 的绑定没问题。
- **`quote`** 只在操作数起始位置、且同一行后跟花括号时打开宏模板——
  在 `=`、`(`、`,`、`[`、`return`、`do` 或 `->` 之后，如
  `const t = quote { ... }`。别处它是普通名字：标准库的 JSON 转义器
  被调作 `quote(s)`，sql 的 `data.get(i) == quote` 结束一个 `if`
  条件，其 `{` 打开的是条件体。

## `to_string` 与 `length`

`to_string` 与 `length` 处处都是普通标识符：绑定、字段、参数、顶层
函数、函数组成员，以及类或接口的方法，都能不经特殊规则地使用这两个
名字。没有任何语言构造按它们分派——`to_string` 只应答显式调用。

## 指令命名空间

第一个 token 是 `#` 或 `@` 的注释不是注释——它是指令，而这个命名空间
是保留的：未知的指令名是编译错误，所以以这两个符号开头的普通文字不能
出现。角色侧(`#`)归编译器所有，`#macro` 是其唯一成员;应用侧(`@`)
在作用域内解析宏名。规则住在 [macros.md](intro/macros.md)。

## 糖命名空间

冒号加名字的形式(`:chain`、`:foreach`、`:raise`、`:when`，以及日后的
糖)根本不是保留字：冒号与一个普通标识符配对——或与某个糖借用的关键字
配对，如 `:raise` 借用 `raise`、`:when` 借用 `when`——在编译器的糖表里
查找。未知的 `:name` 是编译错误，但糖形式所用的词——`chain`、`from`
——在其他任何地方仍是合法标识符。(`:chain` 的成功体用 `then` 写，
与引入每个 `case` 和 `receive` 分支体的保留字相同。)见
[syntax.md](intro/syntax.md)。
