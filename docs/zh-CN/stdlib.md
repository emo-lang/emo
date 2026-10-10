# 标准库

标准库是编译器自带的一组包:它们随编译器内置的 registry 一起分发,像普通依赖一样参与解析,也像普通依赖一样在 `package.emo` 里固定版本。使用一个包就是 `require`:

```emo
require "json"
```

同时在清单的 `deps` 下固定精确版本(如 `json = "0.1.0"`)。`require` 没有对应的 pin 是编译错误;包的 `targets` 不含本次构建目标的,在解析阶段直接拒绝——格式类包在所有目标上运行,系统类和网络类包只声明拥有 Unix 形态宿主的目标。

两条约定贯穿所有包:

- **错误就是异常。** 每个失败的调用抛出普通的 Emo 异常,消息精确说明失败原因——`json: expected array element at byte 3`、`os: open_write notes.txt: Permission denied`——没有错误码,没有 nil。流结束不是错误:空字符串表示流结束。
- **语言够用就用纯 Emo。** 格式类包和编解码器用 Emo 写在共享运行时之上,声明的每个目标都给出逐字节相同的答案。只有 `os`(以及构建在它之上的包)分发到 POSIX 支撑的运行时内建,也只有它们是仅原生目标。

各包一览:

| 包 | 提供的能力 | 目标 |
|---|---|---|
| [`file`](#file-包) | 整文件读写 | `ocaml`、`c` |
| [`os`](#os-包) | 进程、管道、裸 fd IO、目录 | `ocaml`、`c` |
| [`bufio`](#bufio-包) | 任意流上的缓冲读写 | `ocaml`、`c` |
| [`net`](#net-包) | TCP、UDP、Unix 域套接字、DNS、TLS | `ocaml`、`c` |
| [`http`](#http-包) | HTTP 客户端与服务器 | `ocaml`、`c` |
| [`json`](#json-包) | JSON 解码与编码 | 全部五个 |
| [`yaml`](#yaml-包) | YAML 1.2(core schema)解码与编码 | 全部五个 |
| [`xml`](#xml-包) | XML 解码与编码 | 全部五个 |
| [`base64`](#base64-包) | RFC 4648 base64 编解码 | 全部五个 |
| [`slog`](#slog-包) | 结构化日志,logfmt 或 JSON | `ocaml`、`c`、`typescript` |
| [`sync`](#sync-包) | 等待组:让一个进程等待 N 份工作完成 | 全部五个 |

所有包版本均为 0.1.0。每个包在 [`docs/stdlib/`](../stdlib/) 下有完整的 API 参考(中文翻译在 [`docs/zh-CN/stdlib/`](stdlib/)),`examples/` 下有可运行的示例。

## file 包

调度器上的直接风格整文件 IO:一次调用读入整个文件,一次调用写出整个文件。路径按原样使用(相对路径相对进程的工作目录解析)。

```emo
def read(path String) String
def write(path String, contents String) Int64
```

`read` 返回文件的字节;文件缺失或不可读则抛出。`write` 创建或截断,写完全部字节,返回写入的字节数。需要流式、缓冲或追加的 IO,用 `os` 和 `bufio`——`file` 是一次性读写的那一档。

```emo
require "file"

file.write("notes.txt", "hello from disk\n")
println(file.read("notes.txt"))
```

参考:[`docs/zh-CN/stdlib/file.md`](stdlib/file.md) · 示例:`examples/file_read`。

## os 包

进程级的外部接口:进程 id、`fork`、`execv`、`waitpid`、管道、工作目录、目录列举,以及裸(无缓冲、基于 fd 的)文件 IO——系统程序在构建任何东西之前需要的机器。

```emo
def getpid() Int64
def getppid() Int64
def fork() Int64
def waitpid(pid Int64) (Int64, Int64)
def execv(path String, argv Array[String]) Void
def _exit(status Int64) Void

def pipe() (Int64, Int64)

def open_read(path String) Int64
def open_write(path String) Int64
def open_append(path String) Int64
def read(fd Int64, n Int64) String
def write(fd Int64, data String) Int64
def close(fd Int64) Int64

def list_dir(path String) Array[String]
def mkdir(path String) Int64
def rmdir(path String) Int64
def unlink(path String) Int64
def rename(old_path String, new_path String) Int64
def getcwd() String
def chdir(path String) Int64
```

`fork()` 返回两次——子进程得 `0`,父进程得子进程的 pid——子进程通过 `_exit` 离开。`waitpid(pid)` 返回 `(pid, status)`,`status` 是内核原始的 16 位状态字,由 `wait_exited` / `wait_exit_code` / `wait_signaled` / `wait_signal` / `wait_stopped` / `wait_stop_signal` 这些助手解码。`open_write` 创建或截断,`open_append` 创建或追加;`read` 最多返回 `n` 字节,文件结束返回空字符串。`list_dir` 返回按字节序排序的目录项名,不含 `.` 和 `..`,两个目标上顺序一致。

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

套接字:TCP、UDP、Unix 域套接字、DNS 和 TLS——一层薄而可读的 Emo 源码,架在运行时的网络内建之上。直接风格:阻塞调用读起来和其他函数调用一样,套接字忙时调度器把进程停驻。每个失败——连接被拒、名字解析不出、超时——都带着对端、操作和原因抛出。

```emo
def resolve(host String) Array[String]
def connect(host String, port Int64, timeout Float64) TcpConn
def listen(host String, port Int64) TcpListener
def connect_unix(path String, timeout Float64) TcpConn
def listen_unix(path String) TcpListener
def tls_connect(host String, port Int64, timeout Float64) TcpConn
def tls_connect_insecure(host String, port Int64, timeout Float64) TcpConn
def listen_tls(host String, port Int64, cert_path String, key_path String) TcpListener
def udp_bind(host String, port Int64) UdpSocket
```

超时以秒计;`0.0` 表示无限等待。`tls_connect` 按系统信任库验证对端证书;`tls_connect_insecure` 是显式、可见危险的退出。

```emo
conn.read_line()          // String —— 一行,不含终止符
conn.read_exactly(n)      // String —— 恰好 n 字节
conn.read_all()           // String —— 读到对端关闭为止
conn.write(data)          // TcpConn —— 返回自身,写入可以链式
conn.close()              // TcpConn
conn.set_timeout(seconds) // TcpConn

listener.accept()         // TcpConn —— 停驻直到连接到来
listener.port()           // Int64 —— 绑定的端口
listener.close()          // TcpListener
listener.set_timeout(seconds)

socket.send_to(host, port, data) // UdpSocket —— 返回自身
socket.recv_from()               // (String, String, Int64) —— 数据、主机、端口
socket.port()                    // Int64
socket.close()                   // UdpSocket
socket.set_timeout(seconds)
```

EOF 绝不是静默的部分结果:对端提前关闭时 `read_exactly` 抛出,行中途中闭是错误,`read_all` 是唯一把 EOF 当作正常读完的读取。Unix 域监听器没有端口——对它调 `port()` 是错误。

目标:`["ocaml", "c"]`。参考:[`docs/zh-CN/stdlib/net.md`](stdlib/net.md) · 示例:`examples/tcp_echo`。

## http 包

构建在 `net` 之上的纯 Emo HTTP 客户端与服务器。全程直接风格;每个请求一条连接,交换完成后关闭;重定向从不自动跟随——3xx 和其他响应一样。

```emo
def get(url String) HttpResponse
def post(url String, body String) HttpResponse
def put(url String, body String) HttpResponse
def delete(url String) HttpResponse
def request(method String, url String, headers Array[(String, String)], body String, timeout Float64) HttpResponse
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

const listener = net.listen("127.0.0.1", 8902)

http.serve_requests(listener) -> (req HttpRequest) {
  return http.response(200, [("Content-Type", "text/plain")], "hello from emo\n")
}
```

目标:`["ocaml", "c"]`(清单里同时固定 `net`)。参考:[`docs/zh-CN/stdlib/http.md`](stdlib/http.md) · 示例:`examples/http_roundtrip`。

## json 包

JSON 读写器:严格、字节级的 RFC 8259 解码进 `Json` 值树,再编码回去——紧凑或带缩进。`Json` 是一个接口,每种 JSON 类一个实现类(`JsonNull`、`JsonBool`、`JsonInt`、`JsonFloat`、`JsonString`、`JsonArray`、`JsonObject`),由 `JsonKind` 枚举区分。

```emo
def decode(text String) Json
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

解码在每个格式错误处带字节偏移抛出;嵌套超过 512 层直接抛出,不赌栈。浮点以最短往返形式编码,且始终保持可见的浮点形态(`1.0`,绝不是 `1`),因此 encode → decode → encode 是恒等——值与种类都不变。

目标:全部五个——每个目标上都逐字节一致。参考:[`docs/zh-CN/stdlib/json.md`](stdlib/json.md) · 示例:`examples/json_demo`、`examples/json_edge`。

## yaml 包

YAML 读写器:YAML 1.2 的 core schema 解码进与 json 包同构设计的 `Yaml` 值树,再以块风格编码回去。两个包相互独立——require yaml 不需要 json。

```emo
def decode(text String) Yaml
def encode(v Yaml) String
```

`Yaml` 是一个接口,实现类为 `YamlNull`、`YamlBool`、`YamlInt`、`YamlFloat`、`YamlString`、`YamlArray`、`YamlObject`,由 `YamlKind` 区分;访问器和工厂与 json 完全同名(`yaml.null()`、`yaml.bool(b)`、`yaml.int64(n)`、`yaml.float64(x)`、`yaml.string(s)`、`yaml.array(items)`、`yaml.object(entries)`);映射的键是字符串。

解码覆盖块映射与块序列(含紧凑的 `- key: value` 形式)、flow 集合、带 YAML 转义集的引号标量、注释、带 chomping 的 `|`/`>` 块标量,以及按 core schema 解析的 plain 标量(`null`/`~`、布尔、十进制与 `0x`/`0o` 整数、含 `.inf`/`.nan` 的浮点)。锚点与别名、tag、多文档输入、缩进中的 tab 都带字节偏移抛出。

目标:全部五个。参考:[`docs/zh-CN/stdlib/yaml.md`](stdlib/yaml.md) · 示例:`examples/yaml_demo`、`examples/yaml_edge`。

## xml 包

XML 读写器:良构的 XML 解码进 `Xml` 值树,再编码回去。XML 全是文本——任何东西都不强转成数字或布尔,全部文本子节点都保留,因此 `encode(decode(x))` 精确复现原树。

```emo
def decode(text String) Xml
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

解码严格检查良构性——元素按序嵌套闭合、属性唯一且值带引号、根元素恰好一个——并跳过声明、注释、处理指令和不含内部子集的 DOCTYPE;CDATA 按原始文本解码;五个预定义实体加 `&#ddd;` / `&#xhh;` 字符引用在文本和属性值里处处解码。每个失败带字节偏移抛出。

目标:全部五个。参考:[`docs/zh-CN/stdlib/xml.md`](stdlib/xml.md) · 示例:`examples/xml_demo`、`examples/xml_edge`。

## base64 包

RFC 4648 base64 编解码器:字节进,带填充的 base64 文本出,再回来——纯 Emo 写在共享运行时之上,每个目标都给出相同的字节。

```emo
def encode(data String) String
def decode(text String) String
```

`encode` 永远输出标准字母表加 `=` 填充。`decode` 只接受编码器产出的东西:仅标准字母表,填充只在最后一个量子,RFC 要求为零的填充位必须真的是零——`QR==` 是错误,不是 `QQ==` 的同义词。不容忍空白,不接受换行拆分;每次拒绝都带出错字节偏移抛出。

目标:全部五个。参考:[`docs/zh-CN/stdlib/base64.md`](stdlib/base64.md) · 示例:`examples/base64_demo`。

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
