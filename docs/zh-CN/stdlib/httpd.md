# `httpd` 包

标准库的 HTTP 服务器,用纯 Emo 写在 `net` 包之上:每连接一进程,一个请求作为值进来、处理者用一个值应答。通篇直接风格——连接的机制(keep-alive、请求体、限额、超时、优雅关闭)是包自己的,不住进每个程序的 accept 循环。线的另一半(客户端)是 [`http`](stdlib/http.md) 包。本包声明 `ocaml`、`c` 与 `typescript` 三个目标(`targets = ["ocaml", "c", "typescript"]`);依赖解析在其他一切目标上拒绝它。HTTPS 在三者之上都走 `net` 的 TLS——scheme 由监听者决定。

## 引入

```emo
require "httpd"
```

`require "httpd"` 需要在 manifest 的 `deps` 块里钉上 `"httpd" = "0.1.0"`。`httpd` 跑在运行时的 socket 类型上,自身什么都不钉,所以用 `net.listen` 打开监听者的程序要在旁边钉上 `"net" = "0.1.0"`。本包声明 `ocaml`、`c`、`typescript` 三个目标。

## 服务

最简单的服务器是 `httpd.serve`,处理者以附着块给出——一个 `(Request) Response`:

```emo
require "httpd"
require "net"

const (R.ok, listener) = net.listen("127.0.0.1", 8902)

const server = httpd.serve(listener) -> (req httpd.Request) {
  println(req.method + " " + req.path)
  return httpd.response(200, [("Content-Type", "text/plain")], "hello from emo\n")
}
```

`serve` 立刻应答一个 `Server` 句柄——accept 循环跑在自己的进程里;`server.wait()` 才是阻塞的那一步:

```emo
class Server {
  def stop() (R, Server)   // 关闭监听;在途连接跑完各自的事
  def wait() Server        // 等待排干:最后一个在途请求完成
}
```

`server.stop()` 关闭监听者,让在途连接跑到各自的终点;`server.wait()` 在最后一个完成后返回(空闲的 keep-alive 连接经空闲超时终结——没设超时的服务器对它和对在途请求一样等)。可以直接把 `wait()` 当作程序的主工作来跑,也可以让服务起来后程序自己的逻辑继续——这也是客户端与服务器同住一个程序的写法:

```emo
require "httpd"
require "http"
require "net"

const (R.ok, listener) = net.listen("127.0.0.1", 0)

const server = httpd.serve(listener) -> (req httpd.Request) {
  return httpd.response(201, [], req.method + " " + req.path + " " + req.body)
}

case http.request("POST", "http://127.0.0.1:" + listener.port().to_string() + "/items", [("Content-Type", "text/plain")], "payload", 5.0) {
  (R.error, why) then { println("request failed: ${why}") }
  (R.ok, resp)   then {
    println(resp.status) // 201
    println(resp.body)   // POST /items payload
  }
}

const (R.ok, _) = server.stop()
server.wait()
```

同一个服务器走 TLS——handler 不变,变的只有监听者和客户端的信任库:

```emo
const (R.ok, listener) = net.listen_tls("127.0.0.1", 0, "tls-cert.pem", "tls-key.pem")

const server = httpd.serve(listener) -> (req httpd.Request) {
  return httpd.response(200, [], "hello over https\n")
}
```

`examples/https_roundtrip` 就是这个程序,附带签入的证书对。在开始之前就失败的连接——弄断 TLS 握手的客户端、打到 TLS 端口上的明文 HTTP 客户端——被丢弃,服务器继续接受下一个。

## 请求与响应

每个 handler 收到的是一个完整的 `Request`:

```emo
class Request {
  // 字段:method String, target String, path String, query Map[String, String],
  //         proto String, headers Array[(String, String)], body String,
  //         params Map[String, String]
  def header(name String) String            // 大小写不敏感;不存在返回 ""
  def header_all(name String) Array[String] // 每个值,按线上顺序
}
```

- `path` 是请求目标里路径的原样拼写(裸路径——路由器按裸路径匹配);`query` 把每个键映到它首次出现的解码值(`+` 读作空格);`params` 是路由器的通配捕获(请求不经路由器时为空 map)。
- `body` 按请求的帧定界读取:`Content-Length`,或完整解码的 chunked 传输编码——对端发 `Expect: 100-continue` 时先答 `100 Continue` 再读。
- 头名到达时已规范化(`content-type` 读回为 `Content-Type`);查找经这一个拼写大小写不敏感。

处理者以一个 `Response` 值应答——status、headers、body 在一处可见,线上携带由 body 派生的 `Content-Length`(处理者自带的 `Content-Length` 头算数):

```emo
def response(status Int64, headers Array[(String, String)], body String) Response
def error(status Int64, message String) Response   // 纯文本 body 原样给出
```

`HEAD` 请求收到响应的头而没有体;`204` 与 `304` 既无体也无长度。keep-alive 是默认:HTTP/1.1 连接跨请求保持,直到对端发送 `Connection: close`;HTTP/1.0 的对端只有主动请求 `keep-alive` 才保持。

## 路由

`httpd.router()` 构建路由表,一次注册一条——每次调用应答一个新的 `Router`,注册经局部重绑串起来:

```emo
def build_routes() httpd.Router {
  var r = httpd.router()
  r = r.get("/", home)                     // 精确的根
  r = r.get("/hello/{name}", greet)        // GET /hello/ada → params["name"] = "ada"
  r = r.post("/users", create_user)        // POST /users
  r = r.put("/users/{id}", update_user)
  r = r.delete("/users/{id}", delete_user)
  r = r.handle("/static/", serve_static)   // 全方法,其下整棵子树
  r = r.get("/files/{path...}", files)     // 路径剩余部分一个捕获
  return r
}

const server = httpd.serve_routes(listener, build_routes())
```

- `handle(pattern, handler)` 是通用形式——模式自带方法(`"GET /users/{id}"`)或不带;方法限定的助手收裸路径。
- `{name}` 捕获一段;`{name...}` 捕获路径的剩余部分(`/` 连接,没有剩余时为空)。捕获按路径的约定解码——`%XX` 是的,`+` 保持加号——落进 `req.params`。
- 尾斜杠标记子树:`/static/` 应答 `/static/` 及其下一切。单独的 `/` 是精确的根——只应答裸 `/`,不含其下任何路径。
- 最具体的模式胜出:字面量压过通配,通配压过 rest,共享前缀之外更长的模式胜。`/users/admin` 胜过 `/users/{id}`。
- 形状匹配而方法不匹配的请求以 `405` 应答,附上会匹配的那些方法;只注册了 `/static/` 时对 `/static` 的请求以 `301` 应答到 `/static/`;带 `//`、`.`、`..` 的路径以 `301` 应答到清理后的拼写(查询串跟着走);彻底没有匹配答 `404 page not found`。
- 模式在注册时解析一次。坏模式——不闭合的花括号、空名字、不在末尾的 rest——会 raise;同形状且方法重叠的第二次注册同样 raise。

## 选项

`httpd.server_options()` 从默认值出发,每个 `with_*` 应答一个新值——超时以秒计,`0.0` 让该操作不设上限。一行不能以 `.` 开头,所以较长的配置靠重绑局部变量:

```emo
def options() httpd.ServerOptions {
  var o = httpd.server_options()
  o = o.with_read_timeout(5.0)        // 每请求的读期限
  o = o.with_idle_timeout(30.0)       // keep-alive 连接上两次请求之间的期限
  o = o.with_max_header_bytes(16384)  // 头块预算(默认 1 MiB)——超出答 431
  o = o.with_max_body_bytes(1048576)  // 请求体预算(默认不限)——超出答 413
  o = o.with_date(-> () { return date_string() })  // 注入的时钟
  return o
}

const server = httpd.serve_with(listener, handler, options())
```

`with_date` 是响应长出 `Date` 头的唯一途径:包保持无钟,默认输出逐字节确定——`Date` 头需要一个调用方选定的时区(`time` 的日历是 UTC),手上有钟的调用方用这个块给每个响应盖戳(`time.now().format_http()` 就是那个读数)。处理者自己的 `Date` 头压过注入的。

## 线上的严格性

对端的坏字节是预期数据——它们以纯文本 400(或预算超出的 431/413)回来,连接关闭:请求行不是三段、版本不是 HTTP/1.1 或 HTTP/1.0、头名不是 token(`Host : h` 拒绝冒号前的空格)、HTTP/1.1 缺 `Host`、`Content-Length` 不是计数、`Content-Length` 与 `Transfer-Encoding` 并存、chunk 帧断裂、逃逸解码出可打印 ASCII 之外(点名字节)。程序员的错误——坏模式、冲突注册——是 raise 那一半。

## 限制

- **三个目标。** 包声明了 `targets = ["ocaml", "c", "typescript"]`;wasm、BEAM、riscv64 构建在解析期被拒绝——与 `net` 声明的覆盖面一致。在 `c` 上 UDP 与 Unix 域 socket 仍被拒绝(继承自 `net`)。
- **整体缓冲的响应。** 处理者以一个 `Response` 值应答,所以线上恒知长度;流式响应(SSE、大文件)是已点名的后续项,以独立的 writer 形态到来。
- **仅 HTTP/1.1。** 无 HTTP/2、无 WebSocket、无响应 chunked、无压缩、无按主机名的模式——各自至多是已点名的后续项。
- **不注入就没有 `Date`**——见 `with_date`;包保持无钟(`time` 的 UTC 时钟是那个读数)。
- **百分比解码仅限可打印 ASCII。** 解码到 0x20–0x7E 之外的逃逸被拒绝并点名字节;字节级精确的查询与路径值等公开的 Bytes 桥。
