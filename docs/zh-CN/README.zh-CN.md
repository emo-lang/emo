# Emo

Emo 是一门通用编程语言，用 OCaml 5 实现。

仓库：<https://github.com/emo-lang/emo>

## Emo 是什么？

Emo 是**简洁、显式、直观**的。它汲取了三十年开源编程语言的经验——它们的优点与它们的教训——并围绕三条核心原则设计：

- **高表达力的语法。** 代码应当读起来自然，说它所做的事。
- **最小惊讶原则。** 语言规则应当符合程序员直觉；事物应当按你期望的方式工作。
- **多编译目标。** Emo 编译为原生可执行文件、WebAssembly、其他语言（如 TypeScript）、BEAM 虚拟机，以及裸机（`riscv64` 目标——见 EmoOS）。

## 语法

Emo 的语法推崇显式：一切皆可见其本来面目——调用长得像调用，return 写在明处，块只有一种形状。

- **调用总是使用紧贴被调者的显式括号。** 没有可选括号调用；每个调用都可见地是调用，让初学者读得清、解析器无需消歧。括号必须紧贴被调者——`f (a)` 中间有空格是错误，绝不是静默的调用。
- **调用可以拿一个尾随块作为最后一个参数。** 紧跟右括号之后，块附着在调用上：`page(title: "Home") { ... }` 传零参块，`list(users) -> (user User) { ... }` 传带参块。块必须紧贴调用，与括号一样——这就是 UI 树与回调背后的唯一记法。
- **块只有一种形式**：`{ ... }` 与 `-> (x) { ... }`——后者是带参块，也是匿名函数。不以 `return` 结尾的块是 Void 块；返回值的块必须在每条路径上 return。
- **函数与方法用 `def` 定义**，顶层与类内统一。`def` 是箭头块的具名形式：`def total(cart Cart) Decimal { ... }` 与 `const total = -> (cart Cart) { ... }` 相配。
- **绑定分 `const`（不可变）与 `var`（可变，块作用域）**——常量与变量，顾名思义。`var` 绑定不能逃出其块；在比块活得久的闭包里捕获它，是编译错误。
- **参数可按位置或按名传递。** 给定 `def hello(name String)`，`hello("world")` 与 `hello(name: "world")` 都是合法调用。具名形式是 props 与选项的自然形状：`page(title: "Home") { ... }`。
- **类型注解为后缀，以空格分隔**：参数写作 `name String`，返回类型写作 `def full_name() String`。**参数类型永远显式；返回类型可以省略，省略即声明该函数为 Void**——省略的返回类型不是无类型，而是一个签名所能做出的最强声明。`init` 例外——它返回所构造的类，因此不声明返回类型。箭头块（`-> (cart Cart) { ... }`）参数总是带注解但返回类型推断；推断失败时，编译器报错要求显式注解。接口方法永远声明返回类型——签名是契约。其他位置，注解仍然可选（见类型系统）。
- **谓词方法以 `?` 结尾**：`def is_older?() Bool` 在调用处读起来自然。
- **`return` 双向服从签名。** 声明了返回类型的函数必须在每条路径上以 `return` 结束——没有"最后一个表达式即返回值"的规则，编译器拒绝任何落空的路径。Void 函数是精确的镜像：它完全不写 `return`——连 `return void` 也不行——函数体就此结束。
- **`if` 只有一种形状。** `if <cond> { ... }` 加可选的 `else { ... }`——没有 `else if`、`elif` 或任何链式形式；进一步的判断是 `else` 块内可见嵌套的 `if`。与所有控制流一样，`if` 是语句。
- **`case` 将值与模式匹配。** 分支为 `pattern -> { ... }`，首中即停，分支可带守卫：`Color.red when signal.is_bright?()`。模式包括：限定名的枚举成员（`Color.red`——裸小写名是绑定模式，因为成员与变量共享小写空间）、按值匹配的字面量、匹配一切的 `_`。与所有控制流一样，`case` 是语句：结果通过显式 `return` 或绑定离开分支。无分支匹配的 scrutinee 是运行时错误——绝不静默跳过。
- **元组是 `(a, b, c)`。** 定长、异构、不可变的值，按元素比较；注解形式与字面量一致——`(Int64, String)`。括号规则按内容判定，没有尾逗号形式：有逗号就是元组（`()`、`(a, b)`）；括号里是单个无运算符的值，就是一元素元组（`(a)`——给单独的值加分组没有意义）；含运算符的表达式是分组（`(sum * 3)`、`x && (y || z)`）。`(a,)` 是语法错误——一元素元组写作 `(a)`——`(` 直接接着 `(` 也不行：`((x))` 与 `f((a, b))` 永不解析；内联的元组实参应先绑定到名字。逗号之后的嵌套合法且永不相邻：`(a, (b, c))`。在 `case` 模式中，括号永远是元组模式，按位置解构：`(Color.red, count) -> { ... }`。
- **命名遵循严格的大小写约定，由编译器强制。** 所有类型以大写字母开头——内置的（`String`、`Int64`、`Bool`、`Float64`、`Char`）与用户定义的（`class Foo`、`interface Bar`、异常如 `class Exception`）皆然。其余一切——变量、关键字、函数名——小写，且函数名只用 snake_case；不允许 camelCase。
- **字符串永远是双引号，插值只有一种形式。** `"hello, ${name}"`——花括号里是任意表达式。转义是最小集 `\n \r \t \\ \' \"`。单引号表示 `char` 类型：`'a'` 是一个字符，`"a"` 是长度为一的 String。
- **`println(value)` 输出一行**——值的 `.to_string()` 渲染加换行。每个原语都实现 `.to_string()`，插值用同一渲染。
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
- **没有继承——单继承与多继承都没有。** 复用靠鸭子类型的函数、组合与接口，而不是类层次。

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
- 接口是编译期契约：检查器在带注解的位置验证形状，而运行时分发保持鸭子类型，零开销。
- 窄化统一适用：`if g.is(Greeter) { ... }` 对接口与类同样有效。

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

枚举是一个封闭、名义的命名值集合——仅此而已。刻意排除在成员上携带数据的反模式：当一个值必须属于已知集合且携带数据时，惯用形状是装在元组里的枚举标签——`(Outcome.ok, value)`——在 `case` 与 `receive` 中直接解构。更重的多态数据是用接口组织的类，失败路径是异常。

```emo
enum Color { red, green, blue }
```

- 成员是该类型的全部值——无法从集合之外构造枚举值。
- 成员是不可变值：可 `==` 比较、可哈希、可作 map 键。
- 在 `case` 中匹配枚举必须覆盖每个成员；在类型可判定处，检查器报告缺失的成员。

### 异常（Exceptions）

错误即异常。异常是普通的类实例，这样抛出：

```emo
raise Exception.new(message: "something went wrong")
```

未捕获的异常只杀死出错的进程，监督是库层面的事（见并发）。没有受检异常。

### 可变性（Mutability）

可变性分层，且每层都显式：

- `const` 绑定永不改变；`var` 绑定在块内可变且不能逃出。
- 数组是不可变值：长度固定、内容绝不原地修改——变换数组的操作返回新数组，`==` 按元素比较。
- 类字段只在 `init` 内赋值，此后冻结。
- 长寿命的可变状态——每进程一份——住在 `Box` 里：`Box.new(0)` 构造，`box.read()` 读取，`box.replace(v)` 替换——刻意没有别的。把 Box 发给另一个进程送达的是快照副本，可变性永不跨越进程边界。

## 类型系统

Emo 是渐近类型的：**运行时类型动态，编译期静态检查**。

- 运行时语义是动态类型的——每个值带类型标签。这与 BEAM 天然对齐，让日常代码免于类型仪式。
- **整数类型的位宽是显式的：默认整数类型是 `Int64`。** 它是 64 位二进制补码、回绕——算术按模 2⁶⁴ 进行，溢出行为在原生、Wasm、BEAM、裸机上完全一致。无注解的整数字面量是 `Int64`；不存在不带位宽的 `Int` 拼写（见 `docs/numeric-width.md`）。
- **浮点类型的位宽是显式的：默认浮点类型是 `Float64`。** 它在每个目标上都是 IEEE 754 binary64，浮点行为处处一致。无注解的浮点字面量是 `Float64`；不存在不带位宽的 `Float` 拼写。
- 编译器内置类型检查。注解在全语言可选——函数签名的参数类型除外，返回类型可省略（省略即 Void）——未注解的代码仍被推断与检查，只报告确定的错误；已注解的代码严格检查。
- 类型是结构化且流敏感的——`if user.is(Admin)` 之后，`user` 窄化为 `Admin`——符合鸭子类型直觉。
- 没有泛型机制：没有泛型定义语法，也没有类型约束系统。参数化类型只作为注解词汇存在（如 `Array[User]`、`Box[Int64]`），服务检查器与库签名；应用代码依赖推断，几乎看不到任何类型拼写。接收块的参数注解为 `Block`。
- 严格度默认高，可显式放宽。
- 类型信息反哺性能：类型知识足够完整的模块可在原生后端特化（去箱表示、直接调用）。

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
- **依赖图是显式的。** 路径引用就是依赖声明，带来自动模块发现、增量编译与编译期循环检测。

## 包管理

包直接嵌入模块系统：包名成为顶层模块路径前缀。库没有 `install` 步骤——依赖解析是构建的副作用。使用包用 `require`：

```emo
require "acme/json_tools"

def parse_config(text String) Json {
  return json_tools.parse(text)
}
```

- **`require` 是把包的短名带入作用域的文件级语句。** 包侧无需对应物——包的公开面就是它的模块树。完全限定的路径永远可用。
- **`require` 与 manifest 严格配对。** require 一个 `deps` 里没有的包是编译错误——严格优先，manifest 只因显式操作而改变。

- **中心注册表，端点可配置。** 包按 `name@version` 通过中心注册表寻址，由全局内容寻址缓存支撑、跨项目共享——没有每项目的依赖副本。注册表端点读 `EMO_REGISTRY` 环境变量——全局或每项目设置——服务私有与本地部署；未设置时，标准库的内置注册表随编译器附带并默认服务。
- **限定作用域的包名。** 第三方包在 scope 前缀下命名，归属显式，抢注无立足之地；scope 前缀成为模块路径前缀。官方标准库独占顶层短名（`json.decode()`、`http.get(url)`）。
- **manifest 是 Emo 配置文件**，以受限 profile 书写（可终止、密闭、无副作用）。**依赖是精确版本**——开发与测试所用的版本——并且 **targets 声明包支持的编译目标**：

  ```emo
  package {
    name = "acme/json_tools"
    version = "0.1.0"
    targets = ["native", "wasm"]

    deps {
      json = "2.3.1"
      http = "1.4.2"
    }
  }
  ```

- **版本是语义化的（major.minor.patch），按最小版本选择（MVS）解析。** 当不同的包要求同一依赖的不同版本时，满足所有要求的最小版本胜出——对精确要求，取所命名的最高者。升级永远是显式操作。lockfile（`package.lock`）记录带校验和的解析结果，应纳入版本控制；`emo deps resolve` 写它，`emo deps update` 在 pin 变化后重新生成，`emo deps list` 读它——构建从不静默重写。校验和是对包内 `.emo` 源文件的 SHA-256：按路径排序，逐文件以 `path \0 content \0` 喂入——与注册表在发布时重算的摘要是同一个算法。（注册表协议冻结前校验和是 MD5；旧编译器写出的 lockfile 删掉重新 resolve 即可。）
- **目标兼容性在解析期检查。** 不支持当前构建目标的依赖，会以清晰的错误在解析期失败，而不是编译中途。
- **发布用 `emo publish`，在包根目录运行。** 命令校验 manifest（`owner/name` 形式的包名、合法的版本号），把全部 `.emo` 源文件——含子目录——加上可选的根部 `README.md` 打成确定性的 `.emoji` 归档（gzip tar，路径排序、元数据清零：同样输入永远产出同样字节），POST 到注册表。端点来自 `--registry` 或 `EMO_REGISTRY`，API token 来自 `--token` 或 `EMO_TOKEN`；`--dry-run` 只在本地校验与打包，打印归档名、大小、校验和与文件清单，不发请求。版本不可变：发布已存在的版本会被拒绝——在 manifest 里 bump `version`。

## 并发

Emo 自带围绕**进程与消息传递**的原生并发模型，精神上属于 actor 模型。这个选择是刻意的：它原生映射到 BEAM 进程，而原生后端用构建于 OCaml 5 effects 之上的调度器实现——与 Eio 这类运行时同源。

并发语义由以下决策塑造：

- **`do` 启动进程并返回其 pid。** `do work(item)` 在新进程中运行该调用；`do` 表达式的值是新进程的 pid，调用自身的结果被丢弃。
- **`pid <- message` 发送。** `<-` 把消息投递到进程的信箱，两侧永远各写一个空格——紧贴的 `a<-b` 是语法错误而非猜测，与负数比较写作 `a < -b`。
- **`receive` 的分支与 `case` 相同。** `receive { ... }` 扫描信箱找第一条匹配任一分支的消息；不匹配的消息留在队列，无匹配时进程阻塞——选择性接收来自普通的模式，没有独立机制。
- **进程用 `self_pid()` 得知自己的 pid。** 惯用的应答模式一行写完——`sender <- (self_pid(), request)`——元组直接在接收方的分支模式中解构。Pid 是 `Pid` 类型的透明值，按身份比较，渲染为 `<pid 3>`。
- **`halt()` 停止当前进程。** 未处理的错误也一样，两者都只杀死出错的进程；核心只提供监督所需的进程退出信号——kill、wait 与重启策略是库的地盘。
- 消息传递是核心并发原语；共享内存原语不属于核心语义。
- 数据默认不可变，因此消息在 BEAM 上按复制传递、在原生后端按引用传递，而可观察语义完全相同。
- 尾调用有保证；递归是 receive 循环的惯用形状。
- 崩溃隔离与监督在两个后端上都是库层面：未处理的错误只杀死出错的进程。

## 网络

网络是一等公民：几乎所有现代程序都要联网。Emo 提供统一的异步网络 API。在原生后端上，它运行在与并发运行时同一个 effects 调度器之上——非阻塞 socket 由调度器挂起与唤醒，TLS 由 OpenSSL 绑定提供。网络能力仅限原生后端：`net` 与 `http` 包声明 `targets = ["native"]`，依赖解析在其他一切目标上拒绝它们。

API 是**直接风格**：网络调用看起来像普通的阻塞调用，调度器在底层切换进程。没有 `async`/`await`，因此没有函数着色——任何函数都能做 IO，API 生态保持单轨。超时以秒计，每个失败——连接被拒、名字无法解析、超期、socket 关闭——抛出普通的 Emo 异常，其消息写明对端、操作与原因。

socket 面是标准库的 `net` 包；HTTP 在 `http` 包：

- **Socket。** `net.connect(host, port, timeout)`、`net.connect_unix(path, timeout)`、`net.tls_connect(host, port, timeout)` 与 `net.tls_connect_insecure(host, port, timeout)`——证书验证默认开启，insecure 变体是显式、可见危险的退出——返回 `TcpConn`。`net.listen(host, port)`、`net.listen_unix(path)`、`net.listen_tls(host, port, cert_path, key_path)` 返回 `TcpListener`；`net.udp_bind(host, port)` 返回 `UdpSocket`；`net.resolve(host)` 把名字解析为地址。
- **连接。** `read_line()`、`read_exactly(n)`、`read_all()`、`write(data)`、`close()`——优雅关闭先投递待写数据。`set_timeout(seconds)` 约束其后的操作（默认无超时；`0.0` 无限等待）。监听者服务 `accept()` 并报告 `port()`；数据报 socket `send_to(host, port, data)` 与 `recv_from()`，并报告 `port()`。
- **HTTP。** `http.get(url)`、`http.post(url, body)`、`http.put(url, body)`、`http.delete(url)` 与通用的 `http.request(method, url, headers, body, timeout)` 返回携带 `status`、`headers`、`body` 的 `HttpResponse`。重定向从不自动跟随：3xx 是和其他一样的响应，跟随它是调用者的显式动作。服务器侧，`http.serve(listener) -> (conn TcpConn) { ... }` 是每连接一进程的助手，`http.serve_requests(listener) -> (req HttpRequest) { ... }` 解析每个请求并写回处理者的 `HttpResponse`——处理者是普通的 Emo 函数。完整 API 文档见 [docs/zh-CN/stdlib/http.md](docs/zh-CN/stdlib/http.md)。

分层是常规的：socket（TCP/UDP/Unix 域，加 TLS）住在 `net` 包，HTTP（客户端与服务器）住在建立于其上的 `http` 包。TLS 在原生后端是 OpenSSL 绑定。

## 原生构建

`emo build` 把程序编译为独立的原生二进制——一条命令、一个可执行文件，应用无需单独的安装步骤：

```console
$ emo build main.emo -o myapp
built myapp
```

- **运行时随二进制附带。** 调度器与网络栈是后端的库：生成进程、服务 HTTP 的程序编译后运行如一，没有解释器、没有运行时下载。
- **编译产物以解释器为标准。** 每个示例编译为二进制后，其输出与 `emo run` 逐字节一致——在 CI 中断言，而非假设。
- **类型反哺性能。** 类型完全已知的函数编译为特化的原生代码——去箱数字、直接调用——检查器无法钉住的区域保持动态语义。`benchmarks/` 记录数字（同一全注解程序，特化后明显快于 `--no-specialize`）。
- **构建是增量的。** 构建按内容哈希缓存：未变化的程序（与运行时）重建时不调用工具链，构建报告 `(cached)`。
- **C 互操作是一条 `foreign def`。** 声明给出 C 符号名，通过生成的 C 包装封送：

  ```emo
  foreign def sqrt(x Float64) Float64 = "sqrt"
  ```

  `Float64`、`String` 与 `Bool` 现在可跨界；其他类型被检查器拒绝。用 `--cclib` 链接额外的 C 库（`emo build main.emo --cclib m`）。外部定义只在编译程序中运行——`emo run` 拒绝它们。
- **构建需要 OCaml 工具链**——与构建 Emo 本身相同的那个；没有第二个编译器要装。

## 配置

Emo 就是自己的配置语言：配置文件只是一个 Emo 表达式，加载它就是求值这个表达式。无需学习另一种格式——块、字面量、字符串插值与方法调用都可用于配置。

配置文件在受限 profile 下求值：

- **保证终止**——无界循环被禁用，迭代有界。
- **求值是密闭的**——结果只依赖文件内容与显式声明的输入；没有隐藏的文件系统或网络访问。
- **无副作用**——求值配置产出数据，别无其他。

因为类型检查器是内置的，配置 schema 只是类型注解，由同一遍检查——不需要第二种 schema 语言。

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

Emo 通过 OCaml 的一等 C FFI 与 C 互操作：在原生后端，Emo 二进制直接链接 C 库。

## 文档

文档在 `docs/` 之下。中文翻译维护在 `docs/zh-CN/`。

## 许可

Emo 以 [MIT License](LICENSE) 发布。
