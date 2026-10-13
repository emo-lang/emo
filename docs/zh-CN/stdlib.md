# 标准库

标准库是编译器自带的一组包:它们随编译器内置的 registry 一起分发,像普通依赖一样参与解析,也像普通依赖一样在 `package.emo` 里固定版本。使用一个包就是 `require`:

```emo
require "json"
```

同时在清单的 `deps` 下固定精确版本(如 `json = "0.1.0"`)。`require` 没有对应的 pin 是编译错误;包的 `targets` 不含本次构建目标的,在解析阶段直接拒绝——格式类包在所有目标上运行,系统类包只声明拥有 Unix 形态宿主的目标,网络类包声明 `ocaml`、`c` 与 `typescript`。

两条约定贯穿所有包:

- **预期内的失败是值,违例才抛出。** 可能因数据而失败的调用返回 `(R.ok, value)` 或 `(R.error, reason)`——reason 是以包名加冒号开头的字符串(`json: expected array element at byte 3`、`os: open_write notes.txt: Permission denied`;`file` 的错误以 `os:` 报出,因为系统调用由共享的 os 运行时执行)。没有错误码,没有 nil。抛出保留给契约违例:`Exception` 是唯一的异常类,可选的 `data` Map 装机器可读的上下文,不往消息里拼接,抛出即结束进程。流结束不是错误:空字符串表示流结束。
- **语言够用就用纯 Emo。** 格式类包和编解码器用 Emo 写在共享运行时之上,声明的每个目标都给出逐字节相同的答案。`os` 与 `file` 分发到 POSIX 支撑的运行时内建,也只有它们是仅原生目标;`net` 与 `http` 同样分发到运行时内建——在 `ocaml`/`c` 上由 POSIX 支撑,在 `typescript` 上由 Node 支撑。

各包一览:

| 包 | 提供的能力 | 目标 |
|---|---|---|
| [`file`](#file-包) | 整文件读写 | `ocaml`、`c` |
| [`os`](#os-包) | 进程、管道、裸 fd IO、目录 | `ocaml`、`c` |
| [`bufio`](#bufio-包) | 任意流上的缓冲读写 | `ocaml`、`c` |
| [`net`](#net-包) | TCP、UDP、Unix 域套接字、DNS、TLS | `ocaml`、`c`、`typescript` |
| [`http`](#http-包) | HTTP 客户端与服务器 | `ocaml`、`c`、`typescript` |
| [`json`](#json-包) | JSON 解码与编码 | 全部五个 |
| [`yaml`](#yaml-包) | YAML 1.2(core schema)解码与编码 | 全部五个 |
| [`xml`](#xml-包) | XML 解码与编码 | 全部五个 |
| [`base64`](#base64-包) | RFC 4648 base64 编解码 | 全部五个 |
| [`float`](#float-包) | binary64 与十进制文本的精确转换 | 全部五个 |
| [`math`](#math-包) | 浮点标量与初等函数 | 全部五个 |
| [`plot`](#plot-包) | 声明式二维图表,渲染为 SVG | 全部五个 |
| [`slog`](#slog-包) | 结构化日志,logfmt 或 JSON | `ocaml`、`c`、`typescript` |
| [`sync`](#sync-包) | 等待组:让一个进程等待 N 份工作完成 | 全部五个 |
| [`sql`](#sql-包) | SQL 文本解析为抽象语法树 | 全部五个 |

所有包版本均为 0.1.0。每个包在 [`docs/stdlib/`](../stdlib/) 下有完整的 API 参考(中文翻译在 [`docs/zh-CN/stdlib/`](stdlib/));程序直接调用的每个包在 `examples/` 下有可运行的示例。

## file 包

调度器上的直接风格整文件 IO:一次调用读入整个文件,一次调用写出整个文件。路径按原样使用(相对路径相对进程的工作目录解析)。

```emo
def read(path String) (R, String)
def write(path String, contents String) (R, Int64)
```

`read` 返回文件的字节,文件缺失或不可读时返回 `(R.error, reason)`。`write` 创建或截断,写完全部字节,返回写入的字节数。需要流式、缓冲或追加的 IO,用 `os` 和 `bufio`——`file` 是一次性读写的那一档。

```emo
require "file"

const (R.ok, n) = file.write("notes.txt", "hello from disk\n")
const (R.ok, text) = file.read("notes.txt")
println(text)
```

参考:[`docs/zh-CN/stdlib/file.md`](stdlib/file.md) · 示例:`examples/file_read`。

## os 包

进程级的外部接口:进程 id、`fork`、`execv`、`waitpid`、管道、工作目录、目录列举,以及裸(无缓冲、基于 fd 的)文件 IO——系统程序在构建任何东西之前需要的机器。

```emo
def getpid() Int64
def getppid() Int64
def fork() (R, Int64)
def waitpid(pid Int64) (Int64, Int64)
def execv(path String, argv Array[String]) Void
def _exit(status Int64) Void

def pipe() (R, (Int64, Int64))

def open_read(path String) (R, Int64)
def open_write(path String) (R, Int64)
def open_append(path String) (R, Int64)
def read(fd Int64, n Int64) (R, String)
def write(fd Int64, data String) (R, Int64)
def close(fd Int64) (R, Int64)

def list_dir(path String) (R, Array[String])
def mkdir(path String) (R, Int64)
def rmdir(path String) (R, Int64)
def unlink(path String) (R, Int64)
def rename(old_path String, new_path String) (R, Int64)
def getcwd() String
def chdir(path String) (R, Int64)
```

`fork()` 以 `(R.ok, pid)` 回答——子进程得 `0`,父进程得子进程的 pid——子进程通过 `_exit` 离开。`waitpid(pid)` 返回 `(pid, status)`,`status` 是内核原始的 16 位状态字,由 `wait_exited` / `wait_exit_code` / `wait_signaled` / `wait_signal` / `wait_stopped` / `wait_stop_signal` 这些助手解码。`open_write` 创建或截断,`open_append` 创建或追加;`read` 最多返回 `n` 字节,文件结束返回空字符串。`list_dir` 返回按字节序排序的目录项名,不含 `.` 和 `..`,两个目标上顺序一致。

目标:`["ocaml", "c"]`。参考:[`docs/zh-CN/stdlib/os.md`](stdlib/os.md) · 示例:`examples/os_demo`。

## bufio 包

缓冲 IO:在任意字节流前面放一块固定大小的内存缓冲,读方少量大块地读,写方把小写合并成大写,双方都获得整行和读到分隔符为止的读取。形状沿 Go 的 `bufio`:一个 `Reader` 和一个 `Writer`,架在两个单方法结构接口之上,具体流各有适配器,缓冲大小由调用方显式给定。

```emo
interface ByteReader {
  def read(n Int64) String
}

interface ByteWriter {
  def write(data String) Int64
}

def fd_reader(fd Int64) FdReader
def fd_writer(fd Int64) FdWriter
def bytes_reader(data String) BytesReader
def bytes_writer() BytesSink

def default_size() Int64          // 4096
def reader(src ByteReader) Reader
def reader_size(src ByteReader, size Int64) Reader
def writer(sink ByteWriter) Writer
def writer_size(sink ByteWriter, size Int64) Writer
```

任何具备匹配 `read` 或 `write` 的类都按形状满足接口,所以读缓冲可以层层堆叠。`Reader`:

```emo
r.read(n)            // 最多 n 字节;流结束返回 ""
r.read_byte()        // 一个字节,以单字节字符串返回
r.read_string(delim) // 读到下一个单字节分隔符(含分隔符)为止
r.read_line()        // read_string("\n") 的别名
r.peek(n)            // 取 n 字节但不消费;超过缓冲宽度则抛出
r.discard(n)         // 最多跳过 n 字节,返回实际跳过的数量
r.unread_byte()      // 把刚读的一个字节推回去,仅一次
r.buffered()         // 缓冲内未读的字节数
r.reset(src)         // 清空缓冲,改从 src 继续
```

`Writer`:

```emo
w.write(data)   // 写入缓冲,满了就刷出;大写入直通底层
w.write_byte(b) // 一个字节,以单字节字符串给出
w.flush()       // 把缓冲内的全部字节交给底层
w.buffered()    // 等待下次刷出的字节数
w.available()   // 距离自动刷出还剩的空间
w.reset(sink)   // 先刷出,再改挂到 sink
```

流结束是一个值——空字符串——绝不是异常;`read_line` 保留终止符,空行因此始终可以和流结束区分。`Writer` 在流结束前必须 `flush`:缓冲里的尾巴属于调用方。

目标:`["ocaml", "c"]`(构建在 `os` 之上,清单里一起固定)。参考:[`docs/zh-CN/stdlib/bufio.md`](stdlib/bufio.md) · 示例:`examples/bufio_demo`。

## net 包

套接字:TCP、UDP、Unix 域套接字、DNS 和 TLS——一层薄而可读的 Emo 源码,架在运行时的网络内建之上。直接风格:阻塞调用读起来和其他函数调用一样,套接字忙时调度器把进程停驻。每个失败——连接被拒、名字解析不出、超时——都以 `(R.error, reason)` 返回,reason 写明对端、操作与原因。

```emo
def resolve(host String) (R, Array[String])
def connect(host String, port Int64, timeout Float64) (R, TcpConn)
def listen(host String, port Int64) (R, TcpListener)
def connect_unix(path String, timeout Float64) (R, TcpConn)
def listen_unix(path String) (R, TcpListener)
def tls_connect(host String, port Int64, timeout Float64) (R, TcpConn)
def tls_connect_insecure(host String, port Int64, timeout Float64) (R, TcpConn)
def listen_tls(host String, port Int64, cert_path String, key_path String) (R, TcpListener)
def udp_bind(host String, port Int64) (R, UdpSocket)
```

超时以秒计;`0.0` 表示无限等待。`tls_connect` 按系统信任库验证对端证书;`tls_connect_insecure` 是显式、可见危险的退出。

```emo
conn.read_line()          // (R, String) —— 一行,不含终止符
conn.read_exactly(n)      // (R, String) —— 恰好 n 字节
conn.read_all()           // (R, String) —— 读到对端关闭为止
conn.write(data)          // (R, TcpConn) —— 经解构的 (R.ok, conn) 链式写入
conn.close()              // (R, TcpConn)
conn.set_timeout(seconds) // TcpConn

listener.accept()         // (R, TcpConn) —— 停驻直到连接到来
listener.port()           // Int64 —— 绑定的端口
listener.close()          // (R, TcpListener)
listener.set_timeout(seconds)

socket.send_to(host, port, data) // (R, UdpSocket)
socket.recv_from()               // (R, (String, String, Int64)) —— 数据、主机、端口
socket.port()                    // Int64
socket.close()                   // (R, UdpSocket)
socket.set_timeout(seconds)
```

EOF 绝不是静默的部分结果:对端提前关闭时 `read_exactly` 以 reason 失败,行中途中闭是错误元组,`read_all` 是唯一把 EOF 当作正常读完的读取。Unix 域监听器没有端口——对它调 `port()` 是错误。

目标:`["ocaml", "c", "typescript"]`。在 `c` 上本包只覆盖 TCP;UDP、Unix 域套接字、`net.resolve` 与 TLS 在 `c` 上运行时被拒绝。参考:[`docs/zh-CN/stdlib/net.md`](stdlib/net.md) · 示例:`examples/tcp_echo`。

## http 包

构建在 `net` 之上的纯 Emo HTTP 客户端与服务器。全程直接风格;每个请求一条连接,交换完成后关闭;重定向从不自动跟随——3xx 和其他响应一样。

```emo
def get(url String) (R, HttpResponse)
def post(url String, body String) (R, HttpResponse)
def put(url String, body String) (R, HttpResponse)
def delete(url String) (R, HttpResponse)
def request(method String, url String, headers Array[(String, String)], body String, timeout Float64) (R, HttpResponse)
```

URL 必须带显式的 `http://` 或 `https://` scheme;`https` 走 `net.tls_connect`——证书验证开启。响应:

```emo
class HttpResponse {
  // 字段:status Int64, headers Array[(String, String)], body String
  def header(name String) String   // 大小写不敏感;不存在返回 ""
}
```

服务器侧是两个助手,处理者都以附着块给出:

```emo
http.serve(listener) -> (conn TcpConn) { ... }
http.serve_requests(listener) -> (req HttpRequest) { ... }
def response(status Int64, headers Array[(String, String)], body String) HttpResponse
```

`serve` 每条连接起一个进程,把裸连接交给处理者;`serve_requests` 把每个请求解析成 `HttpRequest`(`method`、`path`、`headers`、`body`,外加 `header(name)`),写回处理者的 `HttpResponse` 然后关闭。多数处理者要的是 `serve_requests`。

```emo
require "http"
require "net"

const (R.ok, listener) = net.listen("127.0.0.1", 8902)

http.serve_requests(listener) -> (req HttpRequest) {
  return http.response(200, [("Content-Type", "text/plain")], "hello from emo\n")
}
```

目标:`["ocaml", "c", "typescript"]`(清单里同时固定 `net`)。在 `c` 上它只覆盖 TCP,继承自 `net`。参考:[`docs/zh-CN/stdlib/http.md`](stdlib/http.md) · 示例:`examples/http_roundtrip`。

## json 包

JSON 读写器:严格、字节级的 RFC 8259 解码进 `Json` 值树,再编码回去——紧凑或带缩进。`Json` 是一个接口,每种 JSON 类一个实现类(`JsonNull`、`JsonBool`、`JsonInt`、`JsonFloat`、`JsonString`、`JsonArray`、`JsonObject`),由 `JsonKind` 枚举区分。

```emo
def decode(text String) (R, Json)
def encode(v Json) String
def encode_pretty(v Json) String   // 两空格缩进
```

标量访问器在接口上——类型不对就抛出;数组和对象通过 `is()` 读进具体类:

```emo
def as_bool() Bool
def as_int() Int64
def as_float() Float64
def as_string() String
def kind() JsonKind
def is_null?() Bool
```

`JsonArray` 返回 `items()`(`Array[Json]`);`JsonObject` 返回 `entries()`(`Array[(String, Json)]`)和 `get(key)`——重复键后写者胜,缺键抛出。值用工厂构造,键和元素以显式数组给出:

```emo
def null() Json
def bool(b Bool) Json
def int64(n Int64) Json
def float64(x Float64) Json
def string(s String) Json
def array(items Array[Json]) Json
def object(entries Array[(String, Json)]) Json
```

解码以 `(R.ok, doc)` 或 `(R.error, reason)` 回答——reason 带字节偏移,覆盖每个格式错误,嵌套超过 512 层同理。浮点以最短往返形式编码,且始终保持可见的浮点形态(`1.0`,绝不是 `1`),因此 encode → decode → encode 是恒等——值与种类都不变。

目标:全部五个——每个目标上都逐字节一致。参考:[`docs/zh-CN/stdlib/json.md`](stdlib/json.md) · 示例:`examples/json_demo`、`examples/json_edge`。

## yaml 包

YAML 读写器:YAML 1.2 的 core schema 解码进与 json 包同构设计的 `Yaml` 值树,再以块风格编码回去。两个包相互独立——require yaml 不需要 json。

```emo
def decode(text String) (R, Yaml)
def encode(v Yaml) String
```

`Yaml` 是一个接口,实现类为 `YamlNull`、`YamlBool`、`YamlInt`、`YamlFloat`、`YamlString`、`YamlArray`、`YamlObject`,由 `YamlKind` 区分;访问器和工厂与 json 完全同名(`yaml.null()`、`yaml.bool(b)`、`yaml.int64(n)`、`yaml.float64(x)`、`yaml.string(s)`、`yaml.array(items)`、`yaml.object(entries)`);映射的键是字符串。

解码覆盖块映射与块序列(含紧凑的 `- key: value` 形式)、flow 集合、带 YAML 转义集的引号标量、注释、带 chomping 的 `|`/`>` 块标量,以及按 core schema 解析的 plain 标量(`null`/`~`、布尔、十进制与 `0x`/`0o` 整数、含 `.inf`/`.nan` 的浮点)。锚点与别名、tag、多文档输入、缩进中的 tab 都以 `(R.error, reason)` 返回并带字节偏移。

目标:全部五个。参考:[`docs/zh-CN/stdlib/yaml.md`](stdlib/yaml.md) · 示例:`examples/yaml_demo`、`examples/yaml_edge`。

## xml 包

XML 读写器:良构的 XML 解码进 `Xml` 值树,再编码回去。XML 全是文本——任何东西都不强转成数字或布尔,全部文本子节点都保留,因此 `encode(decode(x))` 精确复现原树。

```emo
def decode(text String) (R, Xml)
def encode(v Xml) String
```

`Xml` 是一个接口,实现类为 `XmlElement` 与 `XmlText`,由 `XmlKind` 区分:

```emo
def kind() XmlKind
def is_text?() Bool
def as_text() String      // 文本节点;元素节点拒绝
```

容器访问器在 `XmlElement` 上,经 `is()` 读入:`name()`、`attrs()`、`attr(name)`(属性缺失抛出)、`children()`(文档序的全部子节点)、`get(name)`(第一个该名字的子元素;缺失抛出)、`text()`(子树内全部文本)。值用工厂构造:

```emo
def element(name String, attrs Array[(String, String)], children Array[Xml]) Xml
def text(s String) Xml
```

解码严格检查良构性——元素按序嵌套闭合、属性唯一且值带引号、根元素恰好一个——并跳过声明、注释、处理指令和不含内部子集的 DOCTYPE;CDATA 按原始文本解码;五个预定义实体加 `&#ddd;` / `&#xhh;` 字符引用在文本和属性值里处处解码。每个失败都以 `(R.error, reason)` 返回并带字节偏移。

目标:全部五个。参考:[`docs/zh-CN/stdlib/xml.md`](stdlib/xml.md) · 示例:`examples/xml_demo`、`examples/xml_edge`。

## base64 包

RFC 4648 base64 编解码器:字节进,带填充的 base64 文本出,再回来——纯 Emo 写在共享运行时之上,每个目标都给出相同的字节。

```emo
def encode(data String) String
def decode(text String) (R, String)
```

`encode` 永远输出标准字母表加 `=` 填充。`decode` 只接受编码器产出的东西:仅标准字母表,填充只在最后一个量子,RFC 要求为零的填充位必须真的是零——`QR==` 是错误,不是 `QQ==` 的同义词。不容忍空白,不接受换行拆分;每次拒绝都以 `(R.error, reason)` 返回,带出错字节偏移。

目标:全部五个。参考:[`docs/zh-CN/stdlib/base64.md`](stdlib/base64.md) · 示例:`examples/base64_demo`。

## float 包

binary64 与十进制文本之间的精确转换:十进制字面量变成离它最近的那些位,`Float64` 变成能读回它的最短文本。两个方向都是包内 `internal` 子树里的 `Int64` 运算,所以五个目标都逐字节相同;`json`、`sql`、`yaml` 读写数字都经过它。

```emo
def parse_exact(neg Bool, digits Bytes, n Int64, e10 Int64) Int64
def finite_bits(bits Int64) Bool
def to_text(x Float64) String
```

`parse_exact` 只舍入一次——就近舍入、平局取偶,即 `strtod` 的答案——超出 binary64 范围的值给出无穷的位模式。`finite_bits` 说明一个位模式究竟是不是值,json 与 sql 的解码器在把它当数据之前问的就是这一句;`to_text` 打印最短的能读回原值的文本,非有限值没有十进制文本,于是 raise。

目标:全部五个。参考:[`docs/zh-CN/stdlib/float.md`](stdlib/float.md)。

## math 包

初等浮点函数:标量、`sqrt`,以及标准库其余部分所依赖的超越函数。纯 Emo 写在五个目标共享的标量运算之上,级数顺序固定,所以每个函数都逐字节相同。

```emo
const e = 2.718281828459045
const pi = 3.141592653589793

def abs(x Float64) Float64
def min(a Float64, b Float64) Float64
def max(a Float64, b Float64) Float64
def clamp(x Float64, lo Float64, hi Float64) Float64
def sqrt(x Float64) Float64
def exp(x Float64) Float64
def log(x Float64) Float64
def log10(x Float64) Float64
def pow(base Float64, exponent Float64) Float64
```

`exp` 先把参数归约到 `2^k * exp(r)`,再用短 Taylor 级数展开 `exp(r)`;`log` 用 `log(x) = e*ln2 + log(m)` 加 atanh 级数。域外参数是契约违反而不是值——`log` 的非正数、`exp` 的上溢都 raise,因为 beam 目标的 Erlang 浮点根本无法表示 NaN 或无穷,返回值不是可选项。这里刻意不放原生快路径(经 `foreign def` 调宿主 libm):它会拒绝 wasm/typescript/beam,并把输出钉在某个平台上。

目标:全部五个。参考:[`docs/zh-CN/stdlib/math.md`](stdlib/math.md) · 示例:`examples/math_demo`。

## plot 包

声明式二维绘图包:一张图就是一个值——`Figure` 持有 `Axes`,每个 `Axes` 持有 mark——一次调用即渲染成 SVG。纯 Emo,五个目标逐字节相同。

```emo
def figure() Figure
def axes() Axes
def svg(fig Figure) String

def with_title(t String) Figure
def with_size(w Float64, h Float64) Figure
def with_axes(a Array[Axes]) Figure

def with_x_label(s String) Axes
def with_y_label(s String) Axes
def with_marks(m Array[Mark]) Axes
```

`plot.mark` 子模块带着各种 mark;T0 只有柱状 mark `plot.mark.bar(labels, values)`,经 `plot.mark.bar_style()` 细化。颜色是 `(Int64, Int64, Int64)` 的 sRGB 三元组,每通道 0–255。每个标签都是 SVG `<text>` 元素,所以这个包不带字体引擎。

`svg` 返回文档;写进文件是调用方的事——这个包在五个目标上都能跑,而文件 IO 只有原生目标可用。

目标:全部五个。T0 是柱状 mark 加线性坐标轴与 SVG 输出;对数刻度、分面、图例、以及其它 mark 家族均为预留。参考:[`docs/zh-CN/stdlib/plot.md`](stdlib/plot.md) · 示例:`examples/plot_demo`。

## slog 包

结构化日志器:每条记录一行,logfmt 或 JSON,按最低级别过滤。日志器是一个不透明句柄——一个普通的值——自带名字、级别和格式;背后没有可配置的全局状态,没有需要拆除的东西。

```emo
def level_debug() Int64
def level_info() Int64
def level_warn() Int64
def level_error() Int64

def format_logfmt() Int64
def format_json() Int64

def new(name String, min Int64, format Int64) String
def child(handle String, name String) String
def enabled(handle String, level Int64) Bool

def debug(handle String, msg String, attrs Map[String, String])
def info(handle String, msg String, attrs Map[String, String])
def warn(handle String, msg String, attrs Map[String, String])
def error(handle String, msg String, attrs Map[String, String])
def emit(handle String, level Int64, msg String, attrs Map[String, String])
```

级别有序,`debug < info < warn < error`;低于最低级别的记录不打印,`enabled` 让调用方在构造记录之前问同一个问题。`child` 把自己的名字嵌在父名之下(`web` 加 `db` 得 `web.db`),继承级别和格式。记录写到 stdout,不带时间戳——手头有时间的调用方把它当普通属性传入。

```emo
require "slog"

const log = slog.new("web", slog.level_info(), slog.format_logfmt())
slog.info(log, "listening", {"addr": "127.0.0.1:8080"})
// level=info logger=web msg=listening addr=127.0.0.1:8080

const cache = slog.child(log, "cache")
slog.warn(cache, "slow query", {"ms": "412"})
// level=warn logger=web.cache msg="slow query" ms=412
```

attrs 是 `Map[String, String]`;键只能是 ASCII 字母、数字、`_`、`.`、`-`,每次调用先校验句柄和键再过滤——即使记录本来不会打印,坏键也是错误。

目标:`["ocaml", "c", "typescript"]`。参考:[`docs/zh-CN/stdlib/slog.md`](stdlib/slog.md) · 示例:`examples/slog_demo`。

## sync 包

协调包:等待组——一个一次性的倒计数,让一个进程等待 N 份工作完
成。纯 Emo 写在进程原语之上——等待组就是一个持有计数的进程,
`done` 是一条消息,`wait` 是另一条——所以在所有目标上可观察行为
完全一致。它什么也不守卫:Emo 没有可守卫的共享内存(消息是快照拷
贝),这正是包里没有 mutex 的原因——等待组只计数。

```emo
def wait_group(n Int64) Pid
def done(wg Pid) Void
def wait(wg Pid) Void
def stop(wg Pid) Void
```

`wait_group` 启动一个 `n` 份工作的倒计时并回答组的 pid;`done` 宣
告一份工作完成;`wait` 阻塞到计数清零,若已清零则立即返回;`stop`
结束计数进程。多个进程可以在同一个组上 `wait`,每个都会被唤醒。
计数一次性设定、只减不增:等待组是一次性的。超出计数的 `done` 在
调用方抛出而非无声消失;`stop` 落下时仍泊着的 `wait` 会抛出而非悬
挂。

```emo
require "sync"

const wg = sync.wait_group(3)  // 三份工作在前
do worker(wg)                  // ……每个以 sync.done(wg) 收尾
do worker(wg)
do worker(wg)
sync.wait(wg)                  // 第三次 done 时返回
sync.stop(wg)
```

等待组线上的每条消息都是打上 `"sync"`——包名——标签的元组,所以
组的流量永远不会撞上应用自己的消息。

目标:`["ocaml", "c", "typescript", "wasm", "beam"]`。参考:
[`docs/zh-CN/stdlib/sync.md`](stdlib/sync.md) · 示例:
`examples/sync_demo`。

## sql 包

SQL parser:SQL 文本进,抽象语法树出。纯 Emo 实现,只依赖共享
运行时——解析出的树按语法节点一类一个类(`Select` 语句、`Expr`
表达式、`TableRef` 表引用),每个节点都回答 `to_string()`,给出
规范的 SQL 渲染。

```emo
def parse(text String) (R, Stmt)
```

`SELECT` 全链路——带 DISTINCT 的选择列表、带 `ON`/`USING` 的连接、
`WHERE`、`GROUP BY`、`HAVING`、`ORDER BY`、`LIMIT`、`OFFSET`——
之下是完整的表达式语法:字面量、参数(`?`、`?NNN`)、带限定的列名、
函数调用、`CAST`、`CASE`、`EXISTS`、子查询,以及按标准优先级排列的
运算符体系。格式错误的输入返回值 `(R.error, reason)`,reason
准确说明发生了什么、在哪个字节偏移;不 raise、没有错误码、没有 nil。

```emo
require "sql"

const (R.ok, stmt) = sql.parse("SELECT * FROM users WHERE id = ?1")
println(stmt.to_string())   // SELECT * FROM users WHERE id = ?1
```

目标:`["ocaml", "c", "typescript", "wasm", "beam"]`。参考:
[`docs/zh-CN/stdlib/sql.md`](stdlib/sql.md) · 示例:`examples/sql_demo`、
`examples/sql_edge`。

## sqlite3 包

数据库包:对 SQLite 预备语句(prepared statement)API 的直接风格
绑定。`Database` 是一个打开的连接;`Statement` 是一条编译好的
SQL,逐行步进、按类型读取列。它是标准库第一个原生绑定包:调用经
`foreign def` 落到包自带的 C shim,系统 sqlite3 库由清单的 `link`
字段声明——消费方只需 `require`,无需 `--cclib`。

```emo
def open(path String) Database

class Database {
  def exec(sql String) Void
  def prepare(sql String) Statement
  def last_insert_rowid() Int64
  def changes() Int64
  def close() Void
}

class Statement {
  def bind_int(i Int64, v Int64) Void
  def bind_float(i Int64, v Float64) Void
  def bind_text(i Int64, v String) Void
  def bind_null(i Int64) Void
  def step() Bool
  def reset() Void
  def finalize() Void
  def column_count() Int64
  def column_name(i Int64) String
  def column_int(i Int64) Int64
  def column_float(i Int64) Float64
  def column_text(i Int64) String
  def column_is_null(i Int64) Bool
}
```

每个会失败的调用都抛出普通的 Emo 异常,消息指出操作并携带
SQLite 自己的错误文本;而行读到尽头是值(`step()` 回答
`false`),不是失败。绑定下标从 1 起——它们命名 SQL 文本里的
`?NNN` 参数;列下标从 0 起。NULL 列读出为 `""`,用
`column_is_null` 区分两者。字符串过 C 边界时以 NUL 结尾,因此含
内嵌 NUL 的 String 会在边界处截断;blob 要等 `Bytes` 能过 FFI
之后再说。

目标:`["c"]`——这些调用是 foreign def,解释器拒绝执行(E3009),
所以 `emo run` 跑不了用到这个包的程序;请用 `emo build` 构建。参
考:[`docs/zh-CN/stdlib/sqlite3.md`](stdlib/sqlite3.md) · 示例:
`examples/sqlite3_demo`。
