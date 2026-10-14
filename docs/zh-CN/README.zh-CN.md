# Emo

Emo 是一门通用编程语言，用 OCaml 5 实现。

仓库：<https://github.com/emo-lang/emo>

## Emo 是什么？

Emo 是**简洁、显式、直观**的。它汲取了三十年开源编程语言的经验——它们的优点与它们的教训——并围绕三条核心原则设计：

- **高表达力的语法。** 代码应当读起来自然，说它所做的事。
- **最小惊讶原则。** 语言规则应当符合程序员直觉；事物应当按你期望的方式工作。
- **多编译目标。** Emo 编译为原生可执行文件、WebAssembly、其他语言（如 TypeScript）、BEAM 虚拟机，以及裸机（`riscv64` 目标——见 EmoOS）。

## 安装

预编译二进制是最快的起步方式。二进制内嵌标准库——无需安装其他东西（用 `emo build` 构建时才需要 C 编译器，那是默认 target）。从 [GitHub Releases](https://github.com/emo-lang/emo/releases) 下载你平台的归档，然后：

```console
$ unzip emo-<version>-macos-arm64.zip
$ ./emo-<version>-macos-arm64/bin/emo run hello.emo
```

Homebrew，来自项目自有 tap：

```console
$ brew install emo-lang/tap/emo
```

opam 从源码构建，并额外带来 `ocaml` 编译目标：

```console
$ opam install emo
```

Windows：WSL2 是受支持路径——在 WSL 内按 Linux 的方式安装；原生 Windows 构建在等待运行时移植（见 `docs/toolchain-distribution.md`）。

无论从哪个渠道安装，`emo doctor` 都会按 target 检查环境并说出缺什么。

## 语法

Emo 的语法推崇显式：一切皆可见其本来面目——调用长得像调用，return 写在明处，块只有一种形状。

- **调用总是使用紧贴被调者的显式括号。** 没有可选括号调用；每个调用都可见地是调用，让初学者读得清、解析器无需消歧。括号必须紧贴被调者——`f (a)` 中间有空格是错误，绝不是静默的调用。
- **调用可以拿一个尾随块作为最后一个参数。** 紧跟右括号之后，块附着在调用上：`page(title: "Home") { ... }` 传零参块，`list(users) -> (user User) { ... }` 传带参块。块必须紧贴调用，与括号一样——这就是 UI 树与回调背后的唯一记法。
- **块只有一种形式**：`{ ... }` 与 `-> (x) { ... }`——后者是带参块，也是匿名函数。不以 `return` 结尾的块是 Void 块；返回值的块必须在每条路径上 return。
- **函数与方法用 `def` 定义**，顶层与类内统一。`def` 是箭头块的具名形式：`def total(cart Cart) Decimal { ... }` 与 `const total = -> (cart Cart) { ... }` 相配。
- **绑定分 `const`（不可变）与 `var`（可变，块作用域）**——常量与变量，顾名思义。两者都能用完整模式代替名字：`const (R.ok, body) = file.read(path)` 解构元组，不匹配的模式是运行时错误——与 `case` 无分支匹配的 scrutinee 同一条规则。`var` 绑定不能逃出其块；在比块活得久的闭包里捕获它，是编译错误。
- **参数可按位置或按名传递。** 给定 `def hello(name String, count Int64)`，`hello("world", 3)` 与 `hello(name: "world", count: 3)` 都是合法调用，且都按参数声明顺序读：`hello(count: 3, name: "world")` 是错误，命名参数之后再写位置参数（`hello(name: "world", 3)`）同样是错误。调用末尾的块是唯一例外——它按构造就是调用的最后一个实参，附加书写时更是读起来根本不像实参：`page(title: "Home") { ... }`。具名形式是 props 与选项的自然形状。
- **类型声明为后缀，以空格分隔**：参数写作 `name String`，返回类型写作 `def full_name() String`。**参数类型永远显式；返回类型可以省略，省略即声明该函数为 Void**——省略的返回类型不是无类型，而是一个签名所能做出的最强声明。`init` 例外——它返回所构造的类，因此不声明返回类型。箭头块（`-> (cart Cart) { ... }`）参数总是带类型声明但返回类型推断；推断失败时，编译器报错要求显式类型声明。接口方法永远声明返回类型——签名是契约。其他位置，类型声明仍然可选（见类型系统）。
- **谓词方法以 `?` 结尾**：`def is_older?() Bool` 在调用处读起来自然。
- **`return` 双向服从签名。** 声明了返回类型的函数必须在每条路径上以 `return` 结束——没有"最后一个表达式即返回值"的规则，编译器拒绝任何落空的路径。Void 函数是精确的镜像：它完全不写 `return`——连 `return void` 也不行——函数体就此结束。
- **`if` 语句只有一种形状。** `if <cond> { ... }` 加可选的 `else { ... }`——没有 `else if`、`elif` 或任何链式形式；进一步的判断是 `else` 块内可见嵌套的 `if`。与所有控制流一样，这个 `if` 是语句。
- **单行 `if` 表达式选取一个值。** `const label = if n >= 90 { "high" } else { "low" }`——两个分支各持恰好一个表达式，分支类型必须一致(`Unknown` 静默合流)，条件是 Bool,`else` 分支不可省略。整个构造必须保持在一行内：其中任何位置的换行都是语法错误，并指向出错的记号。需要多行才能算出的值，用 `if` 语句显式计算并绑定。
- **`case` 将值与模式匹配。** 分支为 `pattern -> { ... }`，首中即停，分支可带守卫：`Color.red when signal.is_bright?()`。模式包括：限定名的枚举成员（`Color.red`——裸小写名是绑定模式，因为成员与变量共享小写空间）、按值匹配的字面量、匹配一切的 `_`。与所有控制流一样，`case` 是语句：结果通过显式 `return` 或绑定离开分支。无分支匹配的 scrutinee 是运行时错误——绝不静默跳过。
- **循环是 `for` 与 `while`。** `for var i = 0; i < 100; i = i + 50 { ... }` 在头部绑定索引——作用域限于循环——并有三个以 `;` 分隔的子句：init、condition、post。三个子句都不可省略；init 必须是 `var` 声明，post 是完整写出的赋值（`i = i + 1`——没有 `+=` 或 `++`）。`while cond { ... }` 只带条件、不绑定，变量在循环前声明。两者都是语句，形态与 `if` 一样无括号；`;` 只在 `for` 头部合法。`break` 跳出最近的外层循环，`continue` 跳到下一次迭代（在 `for` 中先执行 post 子句）；两者在循环外都直接报错，而且循环永远不满足声明的返回类型——函数仍然必须以 `return` 结束。
- **元组是 `(a, b, c)`。** 定长、异构、不可变的值，按元素比较；类型声明形式与字面量一致——`(Int64, String)`。括号规则按内容判定，没有尾逗号形式：有逗号就是元组（`()`、`(a, b)`）；括号里是单个无运算符的值，就是一元素元组（`(a)`——给单独的值加分组没有意义）；含运算符的表达式是分组（`(sum * 3)`、`x && (y || z)`）。`(a,)` 是语法错误——一元素元组写作 `(a)`——`(` 直接接着 `(` 也不行：`((x))` 永不解析；先把内层的值绑定到名字。`Map.new(("a", 1), ("b", 2))` 的成对元组是例外——每个实参的括号就是这对元组本身，不是嵌套。逗号之后的嵌套合法且永不相邻：`(a, (b, c))`。在 `case` 模式中，括号永远是元组模式，按位置解构：`(Color.red, count) -> { ... }`。
- **Map 是 `{ "key": value }`** ——可变、保持插入序的哈希表。`{}` 是空 map；键与值是任意表达式，其类型在条目间按与数组元素完全相同的规则统一；键必须是可哈希的原语类型——`String`、`Int64`、`Byte`、`Bool`、`Char`、`Float64`——可证明不可哈希的键是编译错误。`Map.new(("a", 1), ("b", 2))` 从 `(key, value)` 对构建；后出现的对覆盖先出现的。方法面：`get`（键缺失是运行时错误）、`set`（插入或替换并返回 map，`m.set("a", 1).set("b", 2)` 可链式；替换保持键的位置）、`has`、`remove`（不存在时是空操作，返回 map）、`length`、`keys`、`values`——后两者按插入序返回数组。`==` 比较条目、与顺序无关；map 发给另一个进程送达的是快照副本；`m[k]` 索引是编译错误——读取的形式是 `get`。
- **命名遵循严格的大小写约定，由编译器强制。** 所有类型以大写字母开头——内置的（`String`、`Int64`、`Bool`、`Float64`、`Char`）与用户定义的（`class Foo`、`interface Bar`）皆然。其余一切——变量、关键字、函数名——小写，且函数名只用 snake_case；不允许 camelCase。
- **字符串永远是双引号，插值只有一种形式。** `"hello, ${name}"`——花括号里是任意表达式。转义是最小集 `\n \r \t \\ \' \"`。单引号表示 `char` 类型：`'a'` 是一个字符，`"a"` 是长度为一的 String。
- **`println(value)` 输出一行**——值的 `.to_string()` 渲染加换行。每个原语都实现 `.to_string()`，插值用同一渲染。
- **`printf(format, data)` 提供 C 风格的格式化输出。** `printf("hello: %s\n", ["world"])`——格式是 `String`，参数装进一个 `Array`，从左到右依次消费。转换符与 C 一致：`%d %i %u %o %x %X` 对应 `Int64`（无符号与十六进制形式按 64 位位模式读取）、`%c` 对应 `Char`、`Byte` 或 `Int64`（一个字节，按 C 的 unsigned char 转换）、`%s` 对应 `String`、`%f %F %e %E %g %G` 对应 `Float64`，`%%` 输出字面百分号。旗标（`-`、`+`、空格、`#`、`0`）、宽度、精度遵循 C17 §7.21.6.1——`%*d` 从数组取宽度，负的 `*` 宽度表示左对齐。所有目标上的渲染逐字节一致：浮点数半途情形按偶数舍入，`%g` 按舍入后的指数切换风格。在 Emo 中没有意义的形式一律报错而非猜测——`%n`、`%p`、十六进制浮点 `%a`、长度修饰符（`ll`、`h`、`z`……）全部拒绝。当格式与数据都是字面量（或数组元素类型已知）时，检查器会静态核对：转换类型错误、数量错误、格式串畸形都是编译错误；动态的格式或数组留到运行时检查，不匹配是运行时错误。
- **注释是 `//` 到行尾；没有块注释。**

### 类（Classes）

`class` 是用户定义类型的唯一记法：方法住在类体内，紧挨它们所属的类型。

```emo
class User {
  def init(name String, age Int64) {
    self.name = name
    self.age = age
  }

  def full_name() String {
    return self.name + " " + self.age.to_string()
  }

  def is_older?() Bool {
    return self.age > 35
  }
}
```

- **`init` 是字段赋值的唯一窗口。** 字段通过 `init` 内的 `self.x = ...` 诞生；在其他任何地方给 `self.x` 赋值都是编译错误。因此类是不可变的值类型：实例在赋值时复制（底层写时复制），内容相等的两个实例即 `==`。
- **`self` 隐式传入、显式使用**——签名里没有 `self`，但体内总是写明（`self.name`），字段永不与局部变量混淆。
- **没有继承——单继承与多继承都没有。** 复用靠鸭子类型的函数、组合与接口，而不是类层次。也没有 mixin 或 `include`：把另一个类型的方法拼进类里，只是换了个拼写的继承，一样带来方法解析与命名冲突问题。也没有方法提升：一个类的方法就是它类体里定义的那些，形状不会从别的类型那里增长——这也是一个类型不会"意外满足"某个接口的原因。

### 接口（Interfaces）

多态是结构化的：`interface` 声明一组方法签名，任何形状匹配的类都满足它——无需 `implements` 声明。

```emo
interface Greeter {
  def greet() String
}

class English {
  def greet() String {
    return "Hello"
  }
}

def welcome(g Greeter) String {
  return g.greet()
}
```

- 接口属于消费者：实现方无需知道接口的存在。
- 接口是编译期契约：检查器在带类型声明的位置验证形状，而运行时分发保持鸭子类型，零开销。
- 窄化只走向类目标：`if g.is(English)` 在分支内把 `g` 变为类 `English`。接口目标（`g.is(Greeter)`）是运行时的形状测试——它把 `Unknown` 值窄化为该接口，而对已有类型的值保持原类型不变，因为 Emo 没有交集类型。

### 函数组（Function Groups）

`emo` 声明一个**函数组**：一组有名字、无状态的函数与常量。没有实例、没有 `init`、没有字段——成员就是全部，通过组名调用：

```emo
emo Math {
  const tau = 6

  def abs(x Int64) Int64 {
    if x < 0 {
      return 0 - x
    }
    return x
  }
}

Math.abs(0 - 7)   // 6
Math.tau          // 6
```

- **组不是类。** 没有可实例化的东西，也没有可传递的东西——它是一个函数命名空间。关键字出现在声明处，在使用处消失：`Math.abs(7)` 从不提及它。
- **成员通过组引用**——`Math.abs(7)`、`Config.version`——而在组内它们裸写可见，如同静态方法在自己的类里那样。
- **组设计上无状态**：没有 `var`、没有字段、没有 `init`。要状态，用类和 `Box`。

### 枚举（Enums）

枚举是一个封闭、名义的命名值集合——仅此而已。刻意排除在成员上携带数据的反模式：当一个值必须属于已知集合且携带数据时，惯用形状是装在元组里的枚举标签——内置的 `R` 正是为 ok/error 这一对而生，`(R.ok, value)` 与 `(R.error, reason)`——在 `case` 与 `receive` 中直接解构。更重的多态数据是用接口组织的类；失败路径是错误元组，只有契约违例才抛出。

```emo
enum Color { red, green, blue }
```

- 成员是该类型的全部值——无法从集合之外构造枚举值。
- 成员是不可变值：可 `==` 比较、可哈希、可作 map 键。
- 在 `case` 中匹配枚举必须覆盖每个成员；在类型可判定处，检查器报告缺失的成员。

### 异常（Exceptions）

错误分两类，Emo 让这条分界线可见。**预期内的失败**——文档格式错、文件不存在、连接被拒——是普通的值：调用成功返回 `(R.ok, value)`，失败返回 `(R.error, reason)`，reason 是精确说明失败原因的字符串（`json: expected array element at byte 3`）。`R` 是内置枚举，无需导入；这一对用匹配处理，而不是捕获：

```emo
case file.read(path) {
  (R.ok, body)   -> { println(body) }
  (R.error, why) -> { println("read failed: ${why}") }
}
```

当失败不在预期之内时，绑定模式把这一点说出口——不匹配的模式是运行时错误，让进程响亮地结束：

```emo
const (R.ok, body) = file.read(path)
```

**违例**——被破坏的契约、bug——用抛出表达。`Exception` 是语言中唯一的异常类，携带 `message` 与可选的 `data` Map；Map 装机器可读的上下文（对端地址、文件描述符），供崩溃报告与监督库读回：

```emo
raise Exception.new(message: "queue drained below zero")
raise Exception.new("connect timed out", { "op": "connect", "peer": host })
```

抛出无法被捕获——Emo 没有 catch 构造——且 `raise` 的操作数必须是 `Exception` 实例。两个内置名字都是保留的：任何声明——无论何种形式——都不能取 `Exception`,也不能取结果枚举 `R`。未捕获的异常只杀死出错的进程，监督是库层面的事（见并发）。没有受检异常。

### 可变性（Mutability）

可变性分层，且每层都显式。可变面是一个封闭的五件套——`var`、`Box`、`Bytes`、`List`、`Map`——各自是独立的值类型，没有一个由另一个搭建；除此之外没有任何东西会原地修改。这五者的修改都经别名可见——通过一个绑定做的修改，其余所有绑定都看得见——而 `==` 处处保持结构化：`Box` 按内容比较，`List` 按元素比较，`Map` 按条目比较，`Bytes` 按字节比较。

- `const` 绑定永不改变；`var` 绑定在块内可变且不能逃出。
- 数组是不可变值：长度固定、内容绝不原地修改——变换数组的操作返回新数组，`==` 按元素比较。
- `Bytes` 是定长的可变字节缓冲：`Bytes.new(n)` 分配 `n` 个字节，`get` 与 `set` 逐个寻址（旁边还有小端的多字节访问器），`==` 按内容比较。长度终生不变——`set` 替换字节，不增长缓冲。
- Map 是唯一可变的集合：`Map.new(("foo", "bar"), ("hello", 123))` 只把每个元组当作初始化来源——键和值被读进一个全新的 map，返回值就是这个 map 本身；后面的对覆盖前面的值，键保持首次插入的位置。`set` 与 `remove` 原地修改 map（各自返回 map），键在更新时保持其插入位置，`==` 比较条目而非顺序。键必须是原始类型——非原始类型的键是错误。map 发给另一个进程送达的是快照副本，map 的可变性同样永不跨越进程边界。
- 类字段只在 `init` 内赋值，此后冻结。
- 长寿命的可变状态——每进程一份——住在 `Box` 里：`Box.new(0)` 构造，`box.read()` 读取，`box.replace(v)` 替换——刻意没有别的。把 Box 发给另一个进程送达的是快照副本，可变性永不跨越进程边界。
- `List` 是 Box 旁边的双端队列：Box 守着一个单元格，List 在两端原地增删。`List.new([1, 2, "foo"])` 只把数组当作初始化来源——元素被复制进一个全新的双端队列，返回值就是这个队列本身；数组不会被保留，两者从此看不到彼此的任何修改。`list.push_front(x)` 与 `list.push_back(x)` 在两端插入并返回该列表；`list.pop_front()` 与 `list.pop_back()` 移除并给出元素；`list.length()` 计长。对空 List 弹出是运行时错误，与越界索引同理；`==` 按元素比较。把 List 发给另一个进程送达的是快照副本——可变性永不跨越进程边界。

## 类型系统

Emo 是渐近类型的：**运行时类型动态，编译期静态检查**。

- 运行时语义是动态类型的——每个值带类型标签。这与 BEAM 天然对齐，让日常代码免于类型仪式。
- **整数类型的位宽是显式的：默认整数类型是 `Int64`。** 它是 64 位二进制补码、回绕——算术按模 2⁶⁴ 进行，溢出行为在原生、Wasm、BEAM、裸机上完全一致。无类型声明的整数字面量是 `Int64`；不存在不带位宽的 `Int` 拼写（见 `docs/numeric-width.md`）。
- **浮点类型的位宽是显式的：默认浮点类型是 `Float64`。** 它在每个目标上都是 IEEE 754 binary64，浮点行为处处一致。无类型声明的浮点字面量是 `Float64`；不存在不带位宽的 `Float` 拼写。
- **数值字面量**可用十进制、十六进制（`0xFF`）、二进制（`0b1010_1010`）或八进制（`0o755`），并用 `_` 作数字分隔符（`1_000_000`）。不存在前导零八进制，也没有宽度后缀——裸字面量保持 `Int64`/`Float64`。
- 编译器内置类型检查。类型声明在全语言可选——函数签名的参数类型除外，返回类型可省略（省略即 Void）——无类型声明的代码仍被推断与检查，只报告确定的错误；有类型声明的代码严格检查。
- 类型是结构化的，`is` 测试会窄化——`if user.is(Admin)` 之后，`user` 在分支内是 `Admin`，且不会泄漏到分支之外——符合鸭子类型直觉。
- 没有泛型机制：没有泛型定义语法，也没有类型约束系统。参数化类型只作为类型声明词汇存在（如 `Array[User]`、`Map[String, Int64]`、`Box[Int64]`），服务检查器与库签名；应用代码依赖推断，几乎看不到任何类型拼写。接收块的参数类型声明为 `Block`。
- 容器类型另有裸拼写——`List`、`Box`、`Map`——表示「任意元素」：`Map` 参数同样乐于接受 `Map[String, Int64]` 或 `Map[Int64, User]`，从中读回的值按渐进规则检查。
- 严格度默认高，可显式放宽。
- 类型信息反哺性能：类型知识足够完整的模块可在 `ocaml` 与 `c` 后端特化（去箱表示、直接调用）。

## 模块与可见性

Emo 的模块系统完全是结构化的：没有 `import`、没有 `export`、没有可见性关键字、也没有承载可见性的命名约定。**目录树即模块树：**

```
shop/
  order.emo           # 模块 shop.order
  pricing.emo         # 模块 shop.pricing
  internal/
    discounts.emo     # 模块 shop.internal.discounts —— 子树私有
  checkout.emo        # 模块 shop.checkout
```

- **路径即模块。** 文件自动成为其路径上的模块——无需注册、无需声明。
- **引用即限定路径。** 什么都不导入；路径直接使用，如同 URL。路径太长时，普通 `const` 绑定为其起别名——没有新语法，因为 import 语句本来就只是别名赋值：

  ```emo
  const order = shop.order

  def checkout(cart Cart) Decimal {
    const total = order.total(cart)
    return total
  }
  ```

- **可见性是结构化的。** 函数与块内的定义因作用域私有；模块级定义是公开的（可按限定路径寻址）；`internal/` 目录是子树私有的，由编译器强制——`shop/internal/` 之下的 everything 可在 `shop` 及其后代内使用，在其他任何地方都是编译错误。
- **类型名与值一样，是模块路径限定的。** 类型引用就是一条路径：其他模块里的 `ui.VNode` 指向 `ui.emo` 的 `VNode`，裸名 `Order` 指本模块自己的类型，包内的相对写法与值一致（包内的 `internal.svg.Renderer`）。`is()` 能跨边界收窄，构造遵循同一条规则——`sync.WaitGroup.new(2)`、`ui.Point.new(...)`——声明类型所在的模块在首次使用时加载。因此两个模块可以有同名类型：它们是两个不同的类型，各自以模块寻址。隐私规则对类型与值同样生效：`internal/` 下声明的类型只在其子树内解析。
- **依赖图是显式的。** 路径引用就是依赖声明，带来自动模块发现、增量编译与编译期循环检测。

## 包管理

包直接嵌入模块系统：包名成为顶层模块路径前缀。库没有 `install` 步骤——依赖解析是构建的副作用。使用包用 `require`：

```emo
require "acme/json_tools"

def parse_config(text String) json_tools.Json {
  return json_tools.parse(text)
}
```

- **`require` 是把包的短名带入作用域的文件级语句。** 包侧无需对应物——包的公开面就是它的模块树。完全限定的路径永远可用。
- **包的模块树挂载在短名之下。** 包根的 `<short>.emo` 就是 `require` 绑定的模块 `<short>`;其余文件或目录都是它的子节点——`plot/internal/svg.emo` 就是 `plot.internal.svg`,`plot/mark.emo` 就是 `plot.mark`——所以两个包的 `internal` 和 `mark` 永不冲突。包内部引用以包根为基准书写(`plot.emo` 里的 `internal.scale` 即 `plot.internal.scale`),因此一个包无论单独构建还是挂载在前缀下,编译结果一致。
- **标准库无需 manifest 条目,第三方包需要。** 官方标准库独占顶层短名（`json.decode()`、`http.get(url)`）并随编译器一起发布，所以 `require "json"` 隐式解析——连同这个依赖所拉入的标准库包。带 scope 的包（`acme/json_tools`）必须钉在 `deps` 里：require 一个没有钉的包是编译错误——严格优先，manifest 只因显式操作而改变。

- **中心注册表，端点可配置。** 包按 `name@version` 通过中心注册表寻址，由全局内容寻址缓存支撑、跨项目共享——没有每项目的依赖副本。注册表端点读 `EMO_REGISTRY` 环境变量——全局或每项目设置——服务私有与本地部署；未设置时，标准库的内置注册表随编译器附带并默认服务。
- **限定作用域的包名。** 第三方包在 scope 前缀下命名，归属显式，抢注无立足之地；scope 前缀成为模块路径前缀。官方标准库独占顶层短名（`json.decode()`、`http.get(url)`）。
- **manifest 是 Emo 配置文件**，以受限 profile 书写（可终止、密闭、无副作用）。**依赖是精确版本**——开发与测试所用的版本——并且 **targets 声明包支持的编译目标**。绑定原生代码的包还在可选的 `link` 字段里声明要链接的系统库：

  ```emo
  package {
    name = "acme/json_tools"
    version = "0.1.0"
    targets = ["ocaml", "wasm"]
    link = ["sqlite3"]

    deps {
      json = "2.3.1"
      http = "1.4.2"
    }
  }
  ```

- **包可以自带原生代码。** 包目录树里的 `.c`、`.h` 文件是包的一部分——与 `.emo` 模块一同被收集、校验、发布。c 目标会把依赖包的 C 源文件编进程序，并链接其 `link` 字段声明的库，所以消费 `sqlite3` 这类原生绑定包只需 `require`——不用 `--cclib`，不用手写 shim。`link` 只接受裸库名。包的原生输入只有 c 目标兑现；其他目标在构建期拒绝这样的依赖，manifest 的 `targets` 则在解析期拒绝。

- **版本是语义化的（major.minor.patch），按最小版本选择（MVS）解析。** 当不同的包要求同一依赖的不同版本时，满足所有要求的最小版本胜出——对精确要求，取所命名的最高者。升级永远是显式操作。lockfile（`package.lock`）记录带校验和的解析结果，应纳入版本控制；`emo deps resolve` 写它，`emo deps update` 在 pin 变化后重新生成，`emo deps list` 读它——构建从不静默重写。校验和是对包内收集到的源文件（`.emo`，以及可能存在的 `.c`/`.h`）的 SHA-256：按路径排序，逐文件以 `path \0 content \0` 喂入——与注册表在发布时重算的摘要是同一个算法。（注册表协议冻结前校验和是 MD5；旧编译器写出的 lockfile 删掉重新 resolve 即可。）
- **目标兼容性在解析期检查。** 不支持当前构建目标的依赖，会以清晰的错误在解析期失败，而不是编译中途。
- **发布用 `emo publish`，在包根目录运行。** 命令校验 manifest（`owner/name` 形式的包名、合法的版本号），把全部收集到的源文件——`.emo` 及可能存在的 `.c`/`.h`，含子目录——加上可选的根部 `README.md` 打成确定性的 `.emoji` 归档（gzip tar，路径排序、元数据清零：同样输入永远产出同样字节），POST 到注册表。端点来自 `--registry`、`EMO_REGISTRY` 或最近一次 `emo emoji login`；API token 来自 `--token`、`EMO_TOKEN` 或该 registry 对应的已存登录——已存 token 只会发给铸造它的那个 registry。`--dry-run` 只在本地校验与打包，打印归档名、大小、校验和与文件清单，不发请求。版本不可变：发布已存在的版本会被拒绝——在 manifest 里 bump `version`。
- **共享包生命周期是 `emo emoji`** —— 以归档格式本身命名的命令组。`emo emoji new acme/string_tools` 脚手架一个可发布的包（`owner/name` 的 manifest、以包命名的公共模块、README）；`emo emoji build` 在 manifest 声明的每个目标下编译包的入口模块——发布前的门禁；`emo emoji login` 向注册表验证账号，并存入一个 push/yank/read 的 API token（`~/.config/emo/credentials`，0600，每个 registry 一个块，过期时间随 token 一并记录——`--expires-in-days` 可限定 token 的寿命），之后发布既不需要 flag 也不需要环境变量——有终端时询问邮箱与密码（密码关闭回显读取），否则从 stdin 读入两行；token 过期后，注册表会以专用错误码拒绝，`emo publish` 会提示重新 `emo emoji login`；`emo emoji publish` 与 `emo publish` 是同一次上传。

## 并发

Emo 自带围绕**进程与消息传递**的原生并发模型，精神上属于 actor 模型。这个选择是刻意的：它原生映射到 BEAM 进程，而 `ocaml` 后端用构建于 OCaml 5 effects 之上的调度器实现——与 Eio 这类运行时同源。

并发语义由以下决策塑造：

- **`do` 启动进程并返回其 pid。** `do work(item)` 在新进程中运行该调用；`do` 表达式的值是新进程的 pid，调用自身的结果被丢弃。
- **`pid <- message` 发送。** `<-` 把消息投递到进程的信箱，两侧永远各写一个空格——紧贴的 `a<-b` 是语法错误而非猜测，与负数比较写作 `a < -b`。
- **`receive` 的分支与 `case` 相同。** `receive { ... }` 扫描信箱找第一条匹配任一分支的消息；不匹配的消息留在队列，无匹配时进程阻塞——选择性接收来自普通的模式，没有独立机制。
- **进程用 `self_pid()` 得知自己的 pid。** 惯用的应答模式一行写完——`sender <- (self_pid(), request)`——元组直接在接收方的分支模式中解构。Pid 是 `Pid` 类型的透明值，按身份比较，渲染为 `<pid 3>`。
- **`halt()` 停止当前进程。** 未处理的错误也一样，两者都只杀死出错的进程；核心只提供监督所需的进程退出信号——kill、wait 与重启策略是库的地盘。
- 消息传递是核心并发原语；共享内存原语不属于核心语义。
- 数据默认不可变，因此消息在 BEAM 上按复制传递、在 `ocaml` 与 `c` 后端按引用传递，而可观察语义完全相同。
- 尾调用有保证；递归是 receive 循环的惯用形状。
- 崩溃隔离与监督在两个后端上都是库层面：未处理的错误只杀死出错的进程。

## 网络

网络是一等公民：几乎所有现代程序都要联网。Emo 提供统一的异步网络 API。在 `ocaml` 后端上，它运行在与并发运行时同一个 effects 调度器之上——非阻塞 socket 由调度器挂起与唤醒，TLS 由 OpenSSL 绑定提供；在 TypeScript 目标上它跑在 Node 的事件循环上，每次调用由生成代码里的 `await` 落地。`net` 与 `http` 包声明 `targets = ["ocaml", "c", "typescript"]`，依赖解析在其他一切目标上拒绝它们；`c` 目标只实现 TCP。

API 是**直接风格**：网络调用看起来像普通的阻塞调用，调度器在底层切换进程。没有 `async`/`await`，因此没有函数着色——任何函数都能做 IO，API 生态保持单轨。超时以秒计，每个失败——连接被拒、名字无法解析、超期、socket 关闭——返回 `(R.error, reason)`，reason 写明对端、操作与原因。

socket 面是标准库的 `net` 包；HTTP 在 `http` 包：

- **Socket。** `net.connect(host, port, timeout)`、`net.connect_unix(path, timeout)`、`net.tls_connect(host, port, timeout)` 与 `net.tls_connect_insecure(host, port, timeout)`——证书验证默认开启，insecure 变体是显式、可见危险的退出——返回 `TcpConn`。`net.listen(host, port)`、`net.listen_unix(path)`、`net.listen_tls(host, port, cert_path, key_path)` 返回 `TcpListener`；`net.udp_bind(host, port)` 返回 `UdpSocket`；`net.resolve(host)` 把名字解析为地址。完整 API 文档见 [docs/zh-CN/stdlib/net.md](docs/zh-CN/stdlib/net.md)。
- **连接。** `read_line()`、`read_exactly(n)`、`read_all()`、`write(data)`、`close()`——优雅关闭先投递待写数据。`set_timeout(seconds)` 约束其后的操作（默认无超时；`0.0` 无限等待）。监听者服务 `accept()` 并报告 `port()`；数据报 socket `send_to(host, port, data)` 与 `recv_from()`，并报告 `port()`。
- **HTTP。** `http.get(url)`、`http.post(url, body)`、`http.put(url, body)`、`http.delete(url)` 与通用的 `http.request(method, url, headers, body, timeout)` 返回携带 `status`、`headers`、`body` 的 `HttpResponse`。重定向从不自动跟随：3xx 是和其他一样的响应，跟随它是调用者的显式动作。服务器侧，`http.serve(listener) -> (conn TcpConn) { ... }` 是每连接一进程的助手，`http.serve_requests(listener) -> (req HttpRequest) { ... }` 解析每个请求并写回处理者的 `HttpResponse`——处理者是普通的 Emo 函数。完整 API 文档见 [docs/zh-CN/stdlib/http.md](docs/zh-CN/stdlib/http.md)。

分层是常规的：socket（TCP/UDP/Unix 域，加 TLS）住在 `net` 包，HTTP（客户端与服务器）住在建立于其上的 `http` 包。TLS 在 `ocaml` 上是 OpenSSL 绑定，在 `typescript` 上是 Node 的 `tls`；`c` 目标拒绝它。

## 原生构建

`emo build` 把程序编译为独立的原生二进制——一条命令、一个可执行文件，应用无需单独的安装步骤。默认 target 是 `c`：发射的 C 由系统 `cc` 编译，构建不需要 OCaml 工具链；`--target ocaml` 发射 OCaml，走构建 Emo 自身的那个后端：

```console
$ emo build main.emo -o myapp
built myapp
```

- **运行时随二进制附带。** 调度器与网络栈是后端的库：生成进程、服务 HTTP 的程序编译后运行如一，没有解释器、没有运行时下载。
- **编译产物以解释器为标准。** 每个示例编译为二进制后，其输出与 `emo run` 逐字节一致——在 CI 中断言，而非假设。
- **类型反哺性能。** 类型完全已知的函数编译为特化的原生代码——去箱数字、直接调用——检查器无法钉住的区域保持动态语义。`benchmarks/` 记录数字（同一全带类型声明的程序，特化后明显快于 `--no-specialize`）。
- **构建是增量的。** 构建按内容哈希缓存：未变化的程序（与运行时）重建时不调用工具链，构建报告 `(cached)`。
- **C 互操作是一条 `foreign def`。** 声明给出 C 符号名——`c` 目标经 C ABI 直调；`ocaml` 目标通过生成的 C 包装封送：

  ```emo
  foreign def sqrt(x Float64) Float64 = "sqrt"
  ```

  `Float64`、`String` 与 `Bool` 现在可跨界；其他类型被检查器拒绝。用 `--cclib` 链接额外的 C 库（`emo build main.emo --cclib m`）。外部定义只在编译程序中运行——`emo run` 拒绝它们。无法兑现 `foreign def` 的目标会在检查期拒绝它：`c` 与 `ocaml` 能兑现，而 `wasm`、`typescript`、`beam` 与 freestanding 的 `riscv64` 都会拒绝。
- **C 经接口回调进 Emo。** `foreign def` 的参数可以名一个单方法接口——它就是回调类型。`c` 目标向 C 侧传递一个生成的 trampoline 和作为不透明 `void *userdata` 的对象；回调的 C 签名是该方法的参数（与任何 foreign 实参同样封送）后跟收尾的 `void *userdata`,调用它即分发到接收者自己的方法：

  ```emo
  interface Handler {
    def on_click(tag Int64) String
  }

  foreign def set_handler(h Handler) Void = "set_handler"

  set_handler(MyHandler.new())   # C 侧稍后调用 cb(tag, data)
  ```

  回调方法的参数留在封送层（`Float64`、`String`、`Bool`、`Int64`）,返回额外允许 `Void`。满足同一接口的两个不同类的对象各自分发到自己的方法——对象就骑在 userdata 里。没有该契约的目标在检查期拒绝该参数,与任何无法兑现的 `foreign def` 一致。
- **复合数据以 struct 形状跨界。** 类型为 tuple——或载体类——的 `foreign def` 参数按值传递一个 C 结构体:元素类型按序就是布局,嵌套 tuple 在结构体内再嵌一层结构体,类实例贡献它 init 赋值的字段(类的形状就是它的 init 签名)。复合返回以 tuple 回来:

  ```emo
  foreign def stretch(r ((Float64, Float64), Float64)) (Float64, Float64) = "stretch"

  stretch(((1.0, 2.0), 3.0))   # 结构体内嵌结构体加标量,按值传递
  ```

  `c` 目标声明与 C 侧相同的 `typedef struct`——落在 `emo_defs.h`,shim 对着真实布局编译——按值的调用约定交给 C 编译器。形状字段留在封送层;类类型返回会拒绝(请写 tuple),没有该机制的目标同样拒绝。
- **默认构建只需要一个 C 编译器。** `c` 目标调用系统 `cc`；`--target ocaml` 需要 OCaml 工具链——与构建 Emo 本身相同的那个。

## 测试

`emo test` 运行项目的测试。约定与模块树一样是结构性的：项目 `test/` 目录下的每个 `.emo` 文件都是测试文件，其中的每个顶层 `def test_*` 都是一个测试。根部的 `test.emo` 文件是普通模块，不是测试文件——目录才是标记。

```emo
// test/arithmetic.emo
def test_add() {
  expect_equal(3, main.add(1, 2))
}
```

- **断言是 `expect_*` 内建。** `expect_equal(expected, actual)` 按语言的结构化 `==` 比较；`expect_true(value)` 与 `expect_false(value)` 接受 Bool；`expect_fail(message)` 无条件失败。断言失败抛出唯一的 `Exception` 类——与任何契约违例同一纪律——消息点名断言并渲染双方值：`expect_equal: expected 3, got 2`。
- **每个测试隔离运行。** 运行器在独立的调度器运行中调用每个测试并捕获其输出，一个测试的进程、输出与失败不会泄漏到下一个。raise——无论是断言还是其他——只失败当前测试；运行时错误(`E30xx`)判为 error，单独报告。
- **先检查整棵树。** `emo test` 对每个模块(含测试文件)执行与 `emo run` 相同的静态阶段;任何地方有静态错误即以退出码 65 中止。全部通过退出 0,有失败或错误退出 1。测试函数不接受参数——带参数的 `def test_*` 会被报告,绝不调用。

## 配置

Emo 就是自己的配置语言：配置文件只是一个 Emo 表达式，加载它就是求值这个表达式。无需学习另一种格式——块、字面量、字符串插值与方法调用都可用于配置。

配置文件在受限 profile 下求值：

- **保证终止**——求值在步数预算下进行，每一次循环迭代都计入预算。
- **求值是密闭的**——结果只依赖文件内容与显式声明的输入；没有隐藏的文件系统或网络访问。
- **无副作用**——求值配置产出数据，别无其他。

因为类型检查器是内置的，配置 schema 只是类型声明，由同一遍检查——不需要第二种 schema 语言。

为了与外部世界互操作，JSON/YAML/TOML 仍作为交换格式受支持：标准库读写它们，Emo 是事实源，那些格式是导出品。

## EmoUI

[EmoUI](https://github.com/emo-lang/emo-ui) 是用 Emo 写的组件式 UI 框架：UI 组合为组件树，从响应式状态渲染。Emo 的语法就是为它塑形的，原则是**没有模板语言——UI 就是普通的 Emo 代码**，与配置同一哲学。组件树是带块的嵌套调用（示意语法）：

```emo
page(title: "Home") {
  navbar() {
    logo()
    menu(routes)
  }

  list(users) -> (user User) {
    card(user) {
      text(user.name)
      text(user.bio)
    }
  }
}
```

这里的一切都是普通语法（见语法）：显式括号的调用、单一形式的块、具名参数。组件树由普通函数调用组成——组件定义为函数（`def card(user User) Component { ... }`），或作为类通过同名小写工厂函数暴露（`def card(user User) Component { return Card.new(user) }`）。从调用者一侧，每个组件都是小写函数；大写类型从不被调用，`.new` 从不出现在树里。属于这个领域的一条规则：结构化字面量不可变，所以 props 与组件树是普通的不可变数据。

响应式是显式的而非隐式的：

- 响应式原语住在标准库里，语义显式、可预测——没有隐藏的依赖图。
- 编译器感知优化它们：静态可判定的更新编译为定向刷新，而非运行时 diff。

这些决策与核心设计互相咬合：props 由内置类型检查器检查（渐近类型），UI 事件是进程消息（一个 UI 进程加信箱，在 Emo 并发之上给出 Elm 架构），平台后端只消费组件树及其响应式更新——语言层不知道任何平台细节。

## EmoOS

Emo 的触角伸到操作系统层：这门语言有能力写内核，于是 Emo 内核加 Emo shell——上面再放 EmoUI——构成完整的操作系统，EmoOS。

`riscv64` 编译目标是裸机目标。它假设没有 OS、没有 libc、没有默认运行时；构建 freestanding 的 RISC-V 镜像——内核开发循环是编译、启动、调试，不需要硬件。QEMU 只是这个循环的默认运行器，不属于目标本身；同一镜像可原样运行在真实 RISC-V 硬件上。

写内核从四个方面塑造语言：

- **分层核心库。** `core`（整数、字符串、元组、控制流）零运行时依赖，是内核代码唯一可用的层；标准库需要运行时。
- **显式的内存原语。** 裸内存访问（`peek`/`poke` 及其伙伴）作为显式命名的库函数提供——危险的操作可见地危险。
- **可插拔运行时。** GC、分配器与调度器是裸机目标上可替换的组件，而非注入的默认——内核可以选择最小 GC、arena 或静态分配。
- **单语言闭环。** 内核用 `riscv64` 目标构建，而 shell 与用户程序构建为普通的原生二进制——一门语言贯通系统两侧。

## 实现

Emo 的参考实现用 OCaml 5 编写。自举明确不是目标：Emo 的参考实现保持在 OCaml。

Emo 通过 `foreign def` 与 C 互操作：`c` 后端经 C ABI 直接调用符号，`ocaml` 后端则经生成的 C 包装器编组。

## 文档

文档在 `docs/` 之下。本 README 的中文翻译是 [`docs/zh-CN/README.zh-CN.md`](docs/zh-CN/README.zh-CN.md)。

- [`docs/zh-CN/c-backend.md`](docs/zh-CN/c-backend.md) —— 默认目标：发射 C、C 运行时，以及 C FFI。
- [`docs/zh-CN/ocaml-backend.md`](docs/zh-CN/ocaml-backend.md) —— 发射 OCaml 的后端，以及 OCaml 工具链要求。
- [`docs/zh-CN/toolchain.md`](docs/zh-CN/toolchain.md) —— `emo` CLI 的构建与安装:为何 dune 是唯一需要 OCaml 的一步,以及 justfile 自动化。
- [`docs/zh-CN/toolchain-distribution.md`](docs/zh-CN/toolchain-distribution.md) —— 工具链如何分发：OCaml 依赖、`emo doctor`、以及推迟 `c` 后端。
- [`docs/zh-CN/runtime-and-freestanding.md`](docs/zh-CN/runtime-and-freestanding.md) —— "runtime" 与 "freestanding" 各指什么,以及它们如何对应 Emo 的各目标。
- [`docs/zh-CN/numeric-width.md`](docs/zh-CN/numeric-width.md) —— 所有目标上显式位宽的数值类型。
- [`docs/var-escape.md`](docs/var-escape.md) —— `var` 逃逸规则(暂无中文)。
- [`docs/zh-CN/stdlib.md`](docs/zh-CN/stdlib.md) —— 标准库导览:每个包的用途与对外接口。
- [`docs/zh-CN/stdlib/`](docs/zh-CN/stdlib/) —— 标准库 API 文档(`file`、`os`、`bufio`、`net`、`http`、`json`、`yaml`、`xml`、`base64`、`csv`、`float`、`math`、`plot`、`slog`、`sync`、`sql`、`sqlite3`)。
- [`docs/zh-CN/lsp.md`](docs/zh-CN/lsp.md) —— 语言服务器与 VS Code 扩展。
- [`docs/zh-CN/industrial-software.md`](docs/zh-CN/industrial-software.md)、[`docs/zh-CN/sql-database.md`](docs/zh-CN/sql-database.md)、[`docs/zh-CN/rtos-assessment.md`](docs/zh-CN/rtos-assessment.md)、[`docs/zh-CN/xv6.md`](docs/zh-CN/xv6.md)、[`docs/zh-CN/visualization.md`](docs/zh-CN/visualization.md) —— 可行性与市场评估。
- [`docs/zh-CN/TASKS.md`](docs/zh-CN/TASKS.md) —— 实现任务清单。

## 许可

Emo 以 [MIT License](LICENSE) 发布。
