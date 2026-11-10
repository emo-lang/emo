# Web 服务器指南

用 `httpd` 包构建 HTTP 服务器——从十行代码的 hello world,到带状态、中间件与优雅关闭的 JSON API。本指南是一架梯子:每一节都是一个能跑的程序,每一节只添一个新想法。这里的每个程序都先在解释器与 `c`、`typescript` 三个目标上逐字节一致地跑过,才落成文字;贴出的会话都是真实输出。

简明参考见 [`docs/zh-CN/stdlib/httpd.md`](stdlib/httpd.md);服务器所骑的线见 [`docs/zh-CN/stdlib/net.md`](stdlib/net.md);客户端那一半见 [`docs/zh-CN/stdlib/http.md`](stdlib/http.md)。可运行的示例在编译器旁边:`examples/httpd_routes`、`examples/httpd_serve`、`examples/httpd_wire`、`examples/https_roundtrip`。

## 模型

一句话:**请求作为值进来,你的 handler 用一个值应答,连接的机制是包自己的。**

- 服务器在自己的进程里 accept 连接,**每连接一个进程**。你的 handler 跑在连接进程里——里面的阻塞读只停靠这一个连接,其余连接照常服务。这就是为什么下面的代码没有事件循环、没有回调、没有任何 async 形状的东西:调度器在底下切换进程,而代码读起来就像阻塞调用。
- keep-alive、请求体(`Content-Length` 与 chunked 两种)、限额、超时、优雅关闭都是包的活,不是你的。
- handler 是任何从 `httpd.Request` 到 `httpd.Response` 的函数——平铺的 `def`、块、或包出来的链。中间件就是组合,因为 handler 本来就是个值。
- 错误的分工是标准库的分工:对端的坏字节以 400 族的纯文本回答回来;程序员的错误(坏的路由模式、冲突的注册)则 raise。

## 准备

程序是一个带 `package.emo` manifest 的目录;`emo` 从不向上查找。`httpd` 自己什么都不依赖,但用 `net.listen` 开监听者的程序要在旁边钉上 `net`:

```emo
package {
  name = "hello"
  version = "0.1.0"
  targets = ["ocaml", "c", "typescript"]

  deps {
    "httpd" = "0.1.0"
    "net" = "0.1.0"
  }
}
```

三个目标就是 `net` 自己声明的那三个——wasm、BEAM、riscv64 构建在解析期拒绝这个包。标准库随编译器内嵌;第一次构建会在 manifest 旁边写 `package.lock`,它应当进版本控制。

## 最小的服务器

```emo
require "httpd"
require "net"

const (R.ok, listener) = net.listen("127.0.0.1", 8080)
println("listening on http://127.0.0.1:8080")

const server = httpd.serve(listener) -> (req httpd.Request) {
  return httpd.response(200, [("Content-Type", "text/plain; charset=utf-8")], "Hello, world!\n")
}

server.wait()
```

从项目根目录跑起来,敲一下它:

```console
$ emo run main.emo        # 或:emo build main.emo && ./main
listening on http://127.0.0.1:8080
```

```console
$ curl -i http://127.0.0.1:8080/
HTTP/1.1 200 OK
Content-Type: text/plain; charset=utf-8
Content-Length: 14

Hello, world!
```

四个形状值得留意,后面每一节都建立在它们之上:

- **`net.listen(host, port)`** 应答 `(R.ok, listener)` 或 `(R.error, reason)`。端口 `0` 让内核给一个空闲端口(用 `listener.port()` 读回来)——编译器自带的示例都用它,金测输出因此不必钉住端口号。进程绑不住的端口是错误元组:上面的平铺解构会把一个错误元组变成终结程序的运行时错误,对一台起不来的服务器这是诚实的答案。想打印后干净退出,就用 `case` 去匹配。
- **尾随块**——`httpd.serve(listener) -> (req) { ... }`——就是 handler:这是 Emo 表达"最后传一个函数"的唯一记法。它必须贴着调用,与圆括号一样。
- **`httpd.serve` 立刻应答一个 `Server` 句柄**——accept 循环已经跑在自己的进程里。`server.wait()` 才是阻塞的那一步:它等到排干完成才返回(见[停下一台服务器](#停下一台服务器))。根进程结束,整个程序随之结束,所以服务器程序要么停在 `wait()` 里,要么起来后继续自己的逻辑——两种写法下面都有。
- **`httpd.response(status, headers, body)`** 是一个普通的值:status 是 `Int64`,headers 是按线上顺序的 `(name, value)` 元组数组,body 是 `String`。线上携带派生的 `Content-Length`(你自带的 `Content-Length` 头算数),`HEAD` 请求收到头而没有体,`204`/`304` 既无体也无长度。

服务器默认以 HTTP/1.1 keep-alive 说话:curl 在这里三个请求复用一条连接,两边谁都没多做任何事。

## 请求,逐项看清

每个 handler 收到的是一个完整的 `Request`。字段:

| 字段 | 是什么 |
| --- | --- |
| `method` | `"GET"`、`"POST"`、……请求行自己的拼写 |
| `target` | 请求目标原样,路径加 `?query` |
| `path` | 目标的路径半边,原样——路由器按原样匹配 |
| `query` | `Map[String, String]`:键首现胜出,`+` 读作空格,`%XX` 已解码 |
| `proto` | `"HTTP/1.1"` 或 `"HTTP/1.0"` |
| `headers` | `Array[(String, String)]`,线上顺序,头名已规范化(`content-type` 读回 `Content-Type`) |
| `body` | 完整的体,按 `Content-Length` 或 chunked 定界——对端等待时先答 `100 Continue` |
| `params` | 路由器的通配捕获(请求不经路由器时是空 map) |

外加两个查找:`req.header(name)` 大小写不敏感地答第一个值(不存在时 `""`),`req.header_all(name)` 按线上顺序答每个值。

```emo
require "httpd"
require "net"

// The query value under `key`, or `fallback` when the request has none.
def query_or(req httpd.Request, key String, fallback String) String {
  if req.query.has(key) {
    return req.query.get(key)
  }
  return fallback
}

def inspect(req httpd.Request) httpd.Response {
  var out = "method: " + req.method + "\n"
  out = out + "target: " + req.target + "\n"
  out = out + "path:   " + req.path + "\n"
  out = out + "proto:  " + req.proto + "\n"
  out = out + "name:   " + query_or(req, "name", "(none)") + "\n"
  out = out + "agent:  " + req.header("user-agent") + "\n"
  out = out + "tags:   " + req.header_all("x-tag").length().to_string() + "\n"
  out = out + "body:   " + req.body + "\n"
  for var i = 0; i < req.headers.length(); i = i + 1 {
    const pair = req.headers[i]
    out = out + "header: " + pair[0] + " = " + pair[1] + "\n"
  }
  return httpd.response(200, [("Content-Type", "text/plain; charset=utf-8")], out)
}

const (R.ok, listener) = net.listen("127.0.0.1", 8080)
const server = httpd.serve(listener, inspect)
server.wait()
```

handler 取了名字(`inspect`,而不是尾随块),调用处读起来一样——`httpd.serve(listener, inspect)`——而且可以不开 socket 就做单元测试。

```console
$ curl -s "http://127.0.0.1:8080/greet?name=Ada+Lovelace" -H "X-Tag: a" -H "X-Tag: b" -d "hi there"
method: POST
target: /greet?name=Ada+Lovelace
path:   /greet
proto:  HTTP/1.1
name:   Ada Lovelace
agent:  curl/8.7.1
tags:   2
body:   hi there
header: Host = 127.0.0.1:8080
header: User-Agent = curl/8.7.1
header: Accept = */*
header: X-Tag = a
header: X-Tag = b
header: Content-Length = 8
header: Content-Type = application/x-www-form-urlencoded
```

查询纪律是可打印 ASCII 专用,这是刻意的:解码到 `0x20–0x7E` 之外的逃逸被拒绝并点名字节,会悄悄乱码的文本永远到不了 handler 手里——

```console
$ curl -s -i "http://127.0.0.1:8080/greet?name=%E4%B8%AD"
HTTP/1.1 400 Bad Request
Content-Type: text/plain; charset=utf-8
Content-Length: 85
Connection: close

httpd: bad request: the escape at byte 0 decodes to byte 228, outside printable ASCII
```

字节级精确的查询值等的是标准库已点名的后续项——公开的 `Bytes` 桥。

## 应答:状态、头、体

`httpd.response(status, headers, body)` 把三者放在一处;`httpd.error(status, message)` 是纯文本捷径——消息原样成为体,内容类型在写出的时刻定好。

```emo
require "httpd"
require "net"

const home_page = "<!doctype html>\n<title>Emo</title>\n<h1>Hello from Emo</h1>\n"

def site(req httpd.Request) httpd.Response {
  if req.path == "/" {
    return httpd.response(200, [("Content-Type", "text/html; charset=utf-8")], home_page)
  }
  if req.path == "/old-home" {
    return httpd.response(301, [("Location", "/")], "")
  }
  if req.path == "/health" {
    return httpd.response(204, [], "")
  }
  if req.path == "/login" {
    return httpd.response(200, [("Set-Cookie", "session=abc123; HttpOnly; Path=/"), ("Set-Cookie", "theme=dark; Path=/")], "signed in\n")
  }
  return httpd.error(404, "nothing at " + req.path + "\n")
}

const (R.ok, listener) = net.listen("127.0.0.1", 8080)
const server = httpd.serve(listener, site)
server.wait()
```

```console
$ curl -i http://127.0.0.1:8080/old-home
HTTP/1.1 301 Moved Permanently
Location: /
Content-Length: 0

$ curl -i http://127.0.0.1:8080/health
HTTP/1.1 204 No Content

$ curl -i http://127.0.0.1:8080/login
HTTP/1.1 200 OK
Set-Cookie: session=abc123; HttpOnly; Path=/
Set-Cookie: theme=dark; Path=/
Content-Length: 10

signed in

$ curl -i http://127.0.0.1:8080/nope
HTTP/1.1 404 Not Found
Content-Type: text/plain; charset=utf-8
Content-Length: 17

nothing at /nope
```

重复的头就是重复的头——给数组两个 `Set-Cookie` 元组,线上就带两行。`Connection`、`Content-Length`(除非你自己设了)以及注入时钟后的 `Date` 归服务器管;handler 若写了这些名字,去留按参考文档的规则。

路径只有几条时,这种 `if` 链是诚实而够用的——下一节是路径变多之后的答案。

## 路由

`httpd.router()` 一次注册一条地建路由表,`httpd.serve_routes` 把表放进 handler 的座位。每次注册应答一个新的 `Router`——表是不可变的值——而一行不能以 `.` 开头,所以 builder 在 def 里经局部重绑串起来:

```emo
require "httpd"
require "net"

def home(req httpd.Request) httpd.Response {
  return httpd.response(200, [], "home\n")
}

def list_users(req httpd.Request) httpd.Response {
  return httpd.response(200, [], "all users\n")
}

def create_user(req httpd.Request) httpd.Response {
  return httpd.response(201, [("Location", "/users/7")], "created\n")
}

def me(req httpd.Request) httpd.Response {
  return httpd.response(200, [], "the signed-in user\n")
}

def show_user(req httpd.Request) httpd.Response {
  return httpd.response(200, [], "user " + req.params.get("id") + "\n")
}

def docs_page(req httpd.Request) httpd.Response {
  return httpd.response(200, [], "docs [" + req.params.get("page") + "]\n")
}

def assets(req httpd.Request) httpd.Response {
  return httpd.response(200, [], req.method + " " + req.path + "\n")
}

def routes() httpd.Router {
  var r = httpd.router()
  r = r.get("/", home)
  r = r.get("/users", list_users)
  r = r.post("/users", create_user)
  r = r.get("/users/me", me)
  r = r.get("/users/{id}", show_user)
  r = r.get("/docs/{page...}", docs_page)
  r = r.handle("/assets/", assets)
  return r
}

const (R.ok, listener) = net.listen("127.0.0.1", 8080)
const server = httpd.serve_routes(listener, routes())
server.wait()
```

模式的形式:

- `r.get(path, handler)` / `post` / `put` / `delete`——方法限定的助手,收裸路径。
- `r.handle(pattern, handler)`——通用形式:模式自带方法(`"GET /users/{id}"`)或不带、应答一切方法。
- `{name}` 捕获一段落进 `req.params`;`{name...}` 把路径其余部分 `/` 连接捕获(没有剩余时为空)。捕获逐段按路径的约定解码——`%XX` 是的,`+` 保持加号——所以编码过的斜杠仍是单段内的一个捕获。
- 尾斜杠标记子树:`/assets/` 应答 `/assets/` 及其下一切。单独的 `/` 是精确的根——上面的 `home` 只应答裸 `/`。

分发逻辑,对着上面的表逐个走:

```console
$ curl http://127.0.0.1:8080/
HTTP/1.1 200 OK

home
$ curl -X POST http://127.0.0.1:8080/users
HTTP/1.1 201 Created
Location: /users/7

created
$ curl http://127.0.0.1:8080/users/me
HTTP/1.1 200 OK

the signed-in user
$ curl http://127.0.0.1:8080/users/42
HTTP/1.1 200 OK

user 42
$ curl http://127.0.0.1:8080/docs/guide/routing
HTTP/1.1 200 OK

docs [guide/routing]
$ curl http://127.0.0.1:8080/docs
HTTP/1.1 200 OK

docs []
```

路由器替你应答的形状,每一个都是它不许放过的一类错误:

```console
$ curl -X DELETE http://127.0.0.1:8080/users
HTTP/1.1 405 Method Not Allowed
Allow: GET, POST

$ curl -i http://127.0.0.1:8080/assets
HTTP/1.1 301 Moved Permanently
Location: /assets/

$ curl "http://127.0.0.1:8080/users//42?tab=posts"
HTTP/1.1 301 Moved Permanently
Location: /users/42?tab=posts

$ curl http://127.0.0.1:8080/users/42/
HTTP/1.1 404 Not Found

404 page not found
```

- **405 带着 `Allow`**——本可匹配这条路径的方法,去重后列出。
- **斜杠重定向**——`/assets` 以 301 到注册过的 `/assets/`;查询串跟着走。
- **清理重定向**——带 `//`、`.`、`..` 的路径以 301 到清理后的拼写(`..` 上爬,到根为止)。你的 handler 永远见不到不干净的路径。
- **精确模式的尾斜杠是地址的一部分**——`/users/42/` 不是 `/users/42`,答 404。
- **最具体的模式胜出**:字面量压过通配,通配压过 rest,共享前缀之外更长者胜——所以 `/users/me` 答 `me`,`/users/42` 答 `show_user`。`GET` 模式也应答 `HEAD`,去体是响应写出那一半的事。
- 坏模式或冲突注册(同形状、方法重叠——`/users/{id}` 对 `/users/{name}`)在注册时 raise,服务器还没 accept 任何一个请求。

有一段警示值得单独立一段,因为没有哪个路由器能替你扛住它:**清理是文本性的,不是语义性的**。`/users/../admin` 到分发器那里是 301 到 `/admin`——但 `/users/%2e%2e/admin` 是**解码后**的捕获 `"../admin"`,作为数据交给你的 handler。路由器按原样匹配路径、诚实地解码捕获;它不知道你的捕获日后会被当成文件名。任何要把捕获变成文件系统路径的 handler 必须自己拒绝 `..` 段——防护的写法见[服务文件](#服务文件)。

## 中间件

handler 是一个从 `Request` 到 `Response` 的值,所以中间件就是收一个 handler、答一个新 handler 的函数。包里没有框架式的词——组合就是全部机制:

```emo
require "httpd"
require "net"

// ---- middleware: each takes a handler and answers a handler ----

def logged(next Block) Block {
  return -> (req httpd.Request) {
    const resp = next(req)
    println(req.method + " " + req.target + " " + resp.status.to_string())
    return resp
  }
}

def secure_headers(next Block) Block {
  return -> (req httpd.Request) {
    const resp = next(req)
    const headers = resp.headers.append(("X-Content-Type-Options", "nosniff")).append(("X-Frame-Options", "DENY"))
    return httpd.response(resp.status, headers, resp.body)
  }
}

def require_token(token String, next Block) Block {
  return -> (req httpd.Request) {
    if req.header("Authorization") != "Bearer " + token {
      return httpd.response(401, [("WWW-Authenticate", "Bearer")], "unauthorized\n")
    }
    return next(req)
  }
}

// ---- the app ----

def home(req httpd.Request) httpd.Response {
  return httpd.response(200, [], "welcome\n")
}

def stats(req httpd.Request) httpd.Response {
  return httpd.response(200, [], "42 requests served\n")
}

def routes() httpd.Router {
  var r = httpd.router()
  r = r.get("/", home)
  r = r.get("/admin/stats", require_token("s3cret", stats))
  return r
}

// The router as a plain handler, so middleware can wrap the whole table.
def app() Block {
  const table = routes()
  const dispatch = -> (req httpd.Request) {
    return httpd.router_dispatch(table, req)
  }
  return logged(secure_headers(dispatch))
}

const (R.ok, listener) = net.listen("127.0.0.1", 8080)
const server = httpd.serve(listener, app())
server.wait()
```

`httpd.router_dispatch(table, req)` 正是 `serve_routes` 内部调用的那一步——暴露出来,是想让中间件**包住整张表**的程序(每个请求都记日志、每个应答都带安全头)能包住它,而 `require_token` 留在路由级,因为它读的是匹配路由自己的世界。

```console
$ curl -i http://127.0.0.1:8080/
HTTP/1.1 200 OK
X-Content-Type-Options: nosniff
X-Frame-Options: DENY
Content-Length: 8

welcome
$ curl -i http://127.0.0.1:8080/admin/stats
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer
X-Content-Type-Options: nosniff
X-Frame-Options: DENY
Content-Length: 13

unauthorized
$ curl -i -H "Authorization: Bearer s3cret" http://127.0.0.1:8080/admin/stats
HTTP/1.1 200 OK
X-Content-Type-Options: nosniff
X-Frame-Options: DENY
Content-Length: 19

42 requests served
```

服务器 stdout 上,每个请求领到自己的日志行:

```text
GET / 200
GET /admin/stats 401
GET /admin/stats 200
GET /missing 404
```

本节倚仗的两个语言事实:

- 类字段或 `const` 里的 `Block` 值,**先绑到局部再调用**:`next(req)` 能用是因为 `next` 是 def 的参数;字段上的 `self.handler(req)` 是 `NoMethodError`,`const f = self.handler; f(req)` 才是写法。
- 被包裹块声明的参数照常检查——应答 `httpd.Response` 的 `-> (req httpd.Request) { ... }` 在任何要 handler 的座位上都合格。

## 状态:计数器,由进程持有

handler 是函数,那状态住在哪里?Emo 的答案就是并发的答案:**一个进程持有它,handler 们去问它**。`do 调用()` 起一个进程并应答它的 pid;`pid <- 消息` 发送;`receive { ... }` 取一条匹配某分支的消息。计数器是能想到的最小的有状态服务:

```emo
require "httpd"
require "net"

// The counter process owns the number. It handles one message at a
// time, in arrival order, so two requests can never race on it.
def counter(n Int64) Int64 {
  receive {
    ("next", from) -> {
      from <- ("count", n + 1)
      return counter(n + 1)
    }
  }
}

// Runs in the connection's process: ask, then wait for the answer.
def next_visit(visits Pid) Int64 {
  visits <- ("next", self_pid())
  receive {
    ("count", n) -> { return n }
  }
}

const visits = do counter(0)

const (R.ok, listener) = net.listen("127.0.0.1", 8080)
const server = httpd.serve(listener) -> (req httpd.Request) {
  return httpd.response(200, [], "you are visitor #" + next_visit(visits).to_string() + "\n")
}
server.wait()
```

二十个并发请求,再来一个——每位访客拿到不同的号,按到达顺序,全程没有一把锁:

```console
$ for i in $(seq 1 20); do curl -s http://127.0.0.1:8080/ & done | sort -t'#' -k2 -n | tr '\n' ' '
you are visitor #7 you are visitor #8 ... you are visitor #26
$ curl -s http://127.0.0.1:8080/
you are visitor #27
```

让这一切安全的原则,正是 `httpd` 自己给排干计数器用的那一条:**可变状态由一个进程持有,其余进程都去问它**。消息以快照副本到达(可变性永不越过进程边界),持有者一次处理一条——所以持有者内部的"先查后动"按构造就是原子的,不靠纪律。

handler 上面倚仗的两个 `receive` 事实:

- 分支可以绑定:`("count", n) -> ...` 在模式里把元组拆开。不匹配的消息留在队列里——邮箱是选择性的。
- 分支里 `return` 值的 `receive` **把这个值从外围 def 返回**(`next_visit` 是个 `Int64` 函数);值走的与普通 `return` 是同一条通道。

## JSON API:状态、解析与测试,合在一处

前面几节拼成这个:带进程持有存储的笔记 API,JSON 出入,路径里的 id,还有不开 socket 的测试。两个文件——`app.emo` 装测试需要的一切;`main.emo` 是服务它的五行外壳。

```emo
// app.emo
require "httpd"
require "json"

// ---- the store: one process owns every note ----

// Every request gets exactly one reply, tagged "notes" so it never
// mixes with other traffic in the asking process's mailbox. An answer
// that can fail travels as the usual (R.ok, value) / (R.error, reason).
def notes_store(notes Map[Int64, String], next_id Int64) Int64 {
  receive {
    ("notes", "add", text, from) -> {
      notes.set(next_id, text)
      from <- ("notes", "added", next_id)
      return notes_store(notes, next_id + 1)
    }
    ("notes", "get", id, from) -> {
      if notes.has(id) {
        from <- ("notes", "got", (R.ok, notes.get(id)))
      } else {
        from <- ("notes", "got", (R.error, "no note " + id.to_string()))
      }
      return notes_store(notes, next_id)
    }
    ("notes", "delete", id, from) -> {
      if notes.has(id) {
        notes.remove(id)
        from <- ("notes", "deleted", (R.ok, id))
      } else {
        from <- ("notes", "deleted", (R.error, "no note " + id.to_string()))
      }
      return notes_store(notes, next_id)
    }
    ("notes", "list", from) -> {
      from <- ("notes", "all", notes)
      return notes_store(notes, next_id)
    }
  }
}

def add_note(store Pid, text String) Int64 {
  store <- ("notes", "add", text, self_pid())
  receive {
    ("notes", "added", id) -> { return id }
  }
}

def find_note(store Pid, id Int64) (R, String) {
  store <- ("notes", "get", id, self_pid())
  receive {
    ("notes", "got", answer) -> { return answer }
  }
}

def delete_note(store Pid, id Int64) (R, Int64) {
  store <- ("notes", "delete", id, self_pid())
  receive {
    ("notes", "deleted", answer) -> { return answer }
  }
}

def all_notes(store Pid) Map[Int64, String] {
  store <- ("notes", "list", self_pid())
  receive {
    ("notes", "all", notes) -> { return notes }
  }
}

// ---- JSON in and out ----

def note_json(id Int64, text String) json.Json {
  return json.object([("id", json.int64(id)), ("text", json.string(text))])
}

def json_response(status Int64, doc json.Json) httpd.Response {
  return httpd.response(status, [("Content-Type", "application/json")], json.encode(doc) + "\n")
}

def json_error(status Int64, message String) httpd.Response {
  return json_response(status, json.object([("error", json.string(message))]))
}

def has_key(entries Array[(String, json.Json)], key String) Bool {
  for var i = 0; i < entries.length(); i = i + 1 {
    if entries[i][0] == key {
      return true
    }
  }
  return false
}

// The body's `text` field, or the reason the body is not a note.
def text_field(body String) (R, String) {
  case json.decode(body) {
    (R.error, why) -> { return (R.error, why) }
    (R.ok, doc) -> {
      if doc.is(json.JsonObject) {
        if !has_key(doc.entries(), "text") {
          return (R.error, "the object needs a \"text\" field")
        }
        const text = doc.get("text")
        if text.kind() != json.JsonKind.jstring {
          return (R.error, "\"text\" must be a string")
        }
        return (R.ok, text.as_string())
      }
      return (R.error, "the body must be a JSON object")
    }
  }
}

// A note id from the path: digits only, at most 18 of them.
def parse_id(s String) (R, Int64) {
  if s == "" || s.length() > 18 {
    return (R.error, "not an id")
  }
  for var i = 0; i < s.length(); i = i + 1 {
    if "0123456789".index_of(s.substring(i, 1)) < 0 {
      return (R.error, "not an id")
    }
  }
  return (R.ok, s.to_int64())
}

// ---- handlers ----

def list_notes(store Pid, req httpd.Request) httpd.Response {
  const notes = all_notes(store)
  const ids = notes.keys()
  var items = []
  for var i = 0; i < ids.length(); i = i + 1 {
    items = items.append(note_json(ids[i], notes.get(ids[i])))
  }
  return json_response(200, json.array(items))
}

def create_note(store Pid, req httpd.Request) httpd.Response {
  case text_field(req.body) {
    (R.error, why) -> { return json_error(400, why) }
    (R.ok, text) -> {
      const id = add_note(store, text)
      const headers = [("Content-Type", "application/json"), ("Location", "/notes/" + id.to_string())]
      return httpd.response(201, headers, json.encode(note_json(id, text)) + "\n")
    }
  }
}

def show_note(store Pid, req httpd.Request) httpd.Response {
  case parse_id(req.params.get("id")) {
    (R.error, _) -> { return json_error(404, "no such note") }
    (R.ok, id) -> {
      case find_note(store, id) {
        (R.error, why) -> { return json_error(404, why) }
        (R.ok, text) -> { return json_response(200, note_json(id, text)) }
      }
    }
  }
}

def remove_note(store Pid, req httpd.Request) httpd.Response {
  case parse_id(req.params.get("id")) {
    (R.error, _) -> { return json_error(404, "no such note") }
    (R.ok, id) -> {
      case delete_note(store, id) {
        (R.error, why) -> { return json_error(404, why) }
        (R.ok, _) -> { return httpd.response(204, [], "") }
      }
    }
  }
}

// ---- the table ----

def routes(store Pid) httpd.Router {
  var r = httpd.router()
  r = r.get("/notes", -> (req httpd.Request) { return list_notes(store, req) })
  r = r.post("/notes", -> (req httpd.Request) { return create_note(store, req) })
  r = r.get("/notes/{id}", -> (req httpd.Request) { return show_note(store, req) })
  r = r.delete("/notes/{id}", -> (req httpd.Request) { return remove_note(store, req) })
  return r
}

def options() httpd.ServerOptions {
  var o = httpd.server_options()
  o = o.with_read_timeout(10.0)
  o = o.with_idle_timeout(30.0)
  o = o.with_max_body_bytes(65536)
  return o
}
```

```emo
// main.emo
require "httpd"
require "net"

const store = do app.notes_store(Map.new(), 1)

const (R.ok, listener) = net.listen("127.0.0.1", 8080)
const server = httpd.serve_routes_with(listener, app.routes(store), app.options())
println("notes API on http://127.0.0.1:8080")
server.wait()
```

走一遍——顺路,再走 handler 们写好应答的每一种拒绝:

```console
$ curl -i -X POST -d '{"text":"buy milk"}' http://127.0.0.1:8080/notes
HTTP/1.1 201 Created
Content-Type: application/json
Location: /notes/1
Content-Length: 27

{"id":1,"text":"buy milk"}
$ curl -X POST -d '{"text":"call Ada"}' http://127.0.0.1:8080/notes
{"id":2,"text":"call Ada"}
$ curl http://127.0.0.1:8080/notes
[{"id":1,"text":"buy milk"},{"id":2,"text":"call Ada"}]
$ curl http://127.0.0.1:8080/notes/2
{"id":2,"text":"call Ada"}
$ curl -i http://127.0.0.1:8080/notes/9
HTTP/1.1 404 Not Found
Content-Type: application/json
Content-Length: 22

{"error":"no note 9"}
$ curl -i http://127.0.0.1:8080/notes/abc
HTTP/1.1 404 Not Found
Content-Type: application/json
Content-Length: 25

{"error":"no such note"}
$ curl -i -X POST -d '{"text": 5}' http://127.0.0.1:8080/notes
HTTP/1.1 400 Bad Request
{"error":"\"text\" must be a string"}
$ curl -i -X POST -d '{oops' http://127.0.0.1:8080/notes
HTTP/1.1 400 Bad Request
{"error":"json: expected object key at byte 1"}
$ curl -i -X POST -d '[1,2]' http://127.0.0.1:8080/notes
HTTP/1.1 400 Bad Request
{"error":"the body must be a JSON object"}
$ curl -i -X POST -d '{"title":"x"}' http://127.0.0.1:8080/notes
HTTP/1.1 400 Bad Request
{"error":"the object needs a \"text\" field"}
$ curl -i -X DELETE http://127.0.0.1:8080/notes/1
HTTP/1.1 204 No Content
$ curl -i -X DELETE http://127.0.0.1:8080/notes/1
HTTP/1.1 404 Not Found
{"error":"no note 1"}
$ curl http://127.0.0.1:8080/notes
[{"id":2,"text":"call Ada"}]
```

这个程序添进架子的模式:

- **错误按它本来的值旅行。** 存储的应答把 `(R.ok, ...)` / `(R.error, ...)` 装在消息里,调用方的 `receive` 把元组直接交给自己的 `case`——从存储到 socket,一条约定。
- **`json.decode` 是边界;边界之后,访问器 raise。** 坏 body 是预期数据(错误元组,答 400);能解码但形状不是笔记的 body 是 handler 的 `case` 去应答;`kind()` 检过之后还用错类型的访问器是 bug,该 raise。`doc.is(json.JsonObject)` 做收窄,`entries()` 与 `get` 才是诚实的调用。
- **路由注册闭包住存储的 pid**,每个 handler 问的是同一个持有者;`routes(store)` 为每个存储建一张新表——测试要的正是这个。
- **`serve_routes_with`** 是带选项的形态——超时与请求体预算来自下面的[调参](#调参-限额与超时)。

### 测试它

`emo test` 收集 `test/` 下的每个 `def test_*`。单元测试用服务器构建请求的同一方式构造请求——`httpd.parse_head` 正是连接循环喂的那只纯解析器——最后一个测试从线上完整走一遭:

```emo
// test/app_test.emo
require "http"
require "httpd"
require "net"

// A request exactly as the server would build it from these bytes.
def request(method String, target String, body String) httpd.Request {
  const (R.ok, req) = httpd.parse_head(method + " " + target + " HTTP/1.1\r\nHost: test\r\n\r\n")
  return req.with_body(body)
}

// Each test gets a fresh store, so no test sees another's notes.
def fresh_routes() httpd.Router {
  return app.routes(do app.notes_store(Map.new(), 1))
}

def test_create_then_show() {
  const routes = fresh_routes()
  const created = httpd.router_dispatch(routes, request("POST", "/notes", "{\"text\":\"buy milk\"}"))
  expect_equal(201, created.status)
  const shown = httpd.router_dispatch(routes, request("GET", "/notes/1", ""))
  expect_equal(200, shown.status)
  expect_equal("{\"id\":1,\"text\":\"buy milk\"}\n", shown.body)
}

def test_bad_json_is_400() {
  const resp = httpd.router_dispatch(fresh_routes(), request("POST", "/notes", "{oops"))
  expect_equal(400, resp.status)
}

def test_unknown_id_is_404() {
  const resp = httpd.router_dispatch(fresh_routes(), request("GET", "/notes/99", ""))
  expect_equal(404, resp.status)
}

def test_over_the_wire() {
  const (R.ok, listener) = net.listen("127.0.0.1", 0)
  const server = httpd.serve_routes(listener, fresh_routes())
  const base = "http://127.0.0.1:" + listener.port().to_string()
  const (R.ok, resp) = http.post(base + "/notes", "{\"text\":\"over the wire\"}")
  expect_equal(201, resp.status)
  expect_equal("/notes/1", resp.header("Location"))
  const (R.ok, _) = server.stop()
  server.wait()
}
```

```console
$ emo test
ok test.app_test.test_bad_json_is_400
ok test.app_test.test_create_then_show
ok test.app_test.test_over_the_wire
ok test.app_test.test_unknown_id_is_404
4 tests, 4 passed
```

线上测试里的端口 `0` 是全部诀窍:内核给测试一个空闲端口,`listener.port()` 读回来,没有任何测试会为固定端口跟另一个打架。

## 表单与 HTML

浏览器以 `application/x-www-form-urlencoded` 提交表单——与查询串同一拼写,所以 `httpd.parse_query(text)`(包自己的纯查询解析器,`parse_head` 喂的正是它)把 body 读成字段。要回到 HTML 里的文本先做转义:

```emo
require "httpd"
require "net"

const form_page = "<!doctype html>\n<form method=\"post\" action=\"/hello\">\n  <input name=\"name\">\n  <button>Greet me</button>\n</form>\n"

// Text from a user is escaped before it goes into HTML.
def html_escape(s String) String {
  var out = ""
  for var i = 0; i < s.length(); i = i + 1 {
    const ch = s.substring(i, 1)
    if ch == "&" {
      out = out + "&amp;"
      continue
    }
    if ch == "<" {
      out = out + "&lt;"
      continue
    }
    if ch == ">" {
      out = out + "&gt;"
      continue
    }
    if ch == "\"" {
      out = out + "&quot;"
      continue
    }
    if ch == "'" {
      out = out + "&#39;"
      continue
    }
    out = out + ch
  }
  return out
}

def show_form(req httpd.Request) httpd.Response {
  return httpd.response(200, [("Content-Type", "text/html; charset=utf-8")], form_page)
}

def greet(req httpd.Request) httpd.Response {
  case httpd.parse_query(req.body) {
    (R.error, why) -> { return httpd.error(400, why + "\n") }
    (R.ok, fields) -> {
      if !fields.has("name") || fields.get("name") == "" {
        return httpd.error(400, "the form needs a name\n")
      }
      const page = "<!doctype html>\n<p>Hello, " + html_escape(fields.get("name")) + "!</p>\n"
      return httpd.response(200, [("Content-Type", "text/html; charset=utf-8")], page)
    }
  }
}

def routes() httpd.Router {
  var r = httpd.router()
  r = r.get("/", show_form)
  r = r.post("/hello", greet)
  return r
}

const (R.ok, listener) = net.listen("127.0.0.1", 8080)
const server = httpd.serve_routes(listener, routes())
server.wait()
```

```console
$ curl -d "name=Ada+%3Cscript%3E" http://127.0.0.1:8080/hello
<!doctype html>
<p>Hello, Ada &lt;script&gt;!</p>
$ curl -i -d "nick=x" http://127.0.0.1:8080/hello
HTTP/1.1 400 Bad Request
Content-Type: text/plain; charset=utf-8
Content-Length: 22

the form needs a name
```

`Ada +<script>` 到达、解码、被转义、然后无害地回去——转义发生在用户文本遇见标记的那唯一一处,也是唯一能被信任每次都发生的地方。(整页的服务器渲染还有 `emo/ui_ssr` 这对搭档——`examples/ssr_page`——树由组件搭出,转义是渲染器的活。)

## 服务文件

rest 通配加 `file.read` 就是一个静态 handler——带着路由器无法替你设的那道防线:**捕获是数据,在它变成路径之前必须拒绝会爬的段**。捕获里解码过的 `..`(`/static/%2e%2e/secret.txt`)是 handler 收到的文本;拒绝点开头的段把这一族全数挡掉,`.`、`..` 连同隐藏文件:

```emo
require "file"
require "httpd"
require "net"

def ends_with(s String, suffix String) Bool {
  if s.length() < suffix.length() {
    return false
  }
  return s.substring(s.length() - suffix.length(), suffix.length()) == suffix
}

def content_type(path String) String {
  if ends_with(path, ".html") {
    return "text/html; charset=utf-8"
  }
  if ends_with(path, ".css") {
    return "text/css; charset=utf-8"
  }
  if ends_with(path, ".js") {
    return "text/javascript; charset=utf-8"
  }
  if ends_with(path, ".png") {
    return "image/png"
  }
  return "application/octet-stream"
}

// Only plain segments reach the file system: no empty segment, and none
// that starts with a dot — that refuses `.`, `..`, and hidden files.
def safe_relative(path String) Bool {
  if path == "" {
    return false
  }
  const segments = path.split("/")
  for var i = 0; i < segments.length(); i = i + 1 {
    if segments[i] == "" || segments[i].starts_with(".") {
      return false
    }
  }
  return true
}

def static_file(req httpd.Request) httpd.Response {
  const rel = req.params.get("path")
  if !safe_relative(rel) {
    return httpd.error(404, "404 page not found\n")
  }
  case file.read("public/" + rel) {
    (R.error, _) -> { return httpd.error(404, "404 page not found\n") }
    (R.ok, data) -> { return httpd.response(200, [("Content-Type", content_type(rel))], data) }
  }
}

def routes() httpd.Router {
  var r = httpd.router()
  r = r.get("/static/{path...}", static_file)
  return r
}

const (R.ok, listener) = net.listen("127.0.0.1", 8080)
const server = httpd.serve_routes(listener, routes())
server.wait()
```

项目根旁放着 `public/index.html`、`public/css/site.css`、`public/logo.png`、`public/.hidden` 和 `secret.txt`:

```console
$ curl -s -i --path-as-is http://127.0.0.1:8080/static/css/site.css | head -5
HTTP/1.1 200 OK
Content-Type: text/css; charset=utf-8
Content-Length: 20

h1 { color: teal; }
$ curl -s -i --path-as-is http://127.0.0.1:8080/static/%2e%2e/secret.txt | head -1
HTTP/1.1 404 Not Found
$ curl -s -i --path-as-is http://127.0.0.1:8080/static/..%2fsecret.txt | head -1
HTTP/1.1 404 Not Found
$ curl -s -i --path-as-is http://127.0.0.1:8080/static/.hidden | head -1
HTTP/1.1 404 Not Found
```

PNG 按字节照走(`curl -o` 与原件逐字节一致)。两个限制要诚实点出,都是包里已写明的形状:`file` 一次读入整个文件,所以这个 handler 服务的是资产,不是视频——流式响应的 writer 是已点名的后续项;`file` 声明 `["ocaml", "c", "wasm"]`,带这个 handler 的项目钉的 `targets` 要与它相交(`typescript` 目标在解析期拒绝 `file` 包)。

## 调参:限额与超时

`httpd.server_options()` 从默认值出发;每个 `with_*` 应答一个新值。默认:无超时(`0.0`——不设上限),头块预算 1 MiB,请求体不设限。

```emo
require "httpd"
require "net"

def options() httpd.ServerOptions {
  var o = httpd.server_options()
  o = o.with_read_timeout(2.0)
  o = o.with_idle_timeout(5.0)
  o = o.with_max_header_bytes(256)
  o = o.with_max_body_bytes(16)
  return o
}

def echo(req httpd.Request) httpd.Response {
  return httpd.response(200, [], "got " + req.body.length().to_string() + " bytes\n")
}

const (R.ok, listener) = net.listen("127.0.0.1", 8080)
const server = httpd.serve_with(listener, echo, options())
server.wait()
```

四个旋钮,逐个对着这台服务器量过:

```console
$ curl -d "small" http://127.0.0.1:8080/
got 5 bytes
$ curl -i -d "this body is longer than sixteen bytes" http://127.0.0.1:8080/ | head -1
HTTP/1.1 413 Content Too Large
$ curl -i -H "X-Big: <300 bytes>" http://127.0.0.1:8080/ | head -1
HTTP/1.1 431 Request Header Fields Too Large
```

- **`with_read_timeout(s)`** 限定连接的每一次读——一个请求的头与体。发半个头就停住的客户端,连接被关闭(这里是 2.0s 后,0 字节应答——读从未完成)。
- **`with_idle_timeout(s)`** 限定 keep-alive 连接上**请求之间**的间隙。预算按操作计:每 1.5s 挤一行头的客户端,在 2.0s 读超时之下能走完——应答在挤了 6.0s 之后到达,而不是被某个总期限拒掉。空闲的 keep-alive 连接由空闲超时关闭(这里 5.0s 后)。
- **`with_max_header_bytes(n)`**——超预算答 431,连接关闭。
- **`with_max_body_bytes(n)`**——超预算答 413,而且是在把 body 读过限额之前就答。chunked body 按到达逐段计,chunked 客户端许小送大没有门。

超时以秒计(`Float64`);`0.0` 让该操作不设上限。不设超时的服务器照常工作——只是空闲的 keep-alive 连接永不自行终结,[停下一台服务器](#停下一台服务器)会把这一点放大。

## 停下一台服务器

`server.stop()` 关闭监听者;`server.wait()` 在最后一条在途连接跑完时返回。优雅的形状:一条路由给主进程捎信,主进程停在 `receive`,程序等到排干发话才结束。

```emo
require "httpd"
require "net"

def options() httpd.ServerOptions {
  var o = httpd.server_options()
  o = o.with_read_timeout(10.0)
  o = o.with_idle_timeout(5.0)
  return o
}

// Tell the main process to stop the server.
def request_shutdown(main_pid Pid) {
  main_pid <- "shutdown"
}

// The app is built with the main process's pid, so the shutdown route
// can reach it.
def app(main_pid Pid) Block {
  return -> (req httpd.Request) {
    if req.method == "POST" && req.path == "/admin/shutdown" {
      request_shutdown(main_pid)
      return httpd.response(202, [], "shutting down\n")
    }
    return httpd.response(200, [], "hello\n")
  }
}

const (R.ok, listener) = net.listen("127.0.0.1", 8080)
const server = httpd.serve_with(listener, app(self_pid()), options())
println("listening on http://127.0.0.1:8080")

receive {
  "shutdown" -> { println("shutdown requested, draining") }
}
const (R.ok, _) = server.stop()
server.wait()
println("drained, bye")
```

```console
$ curl -i -X POST http://127.0.0.1:8080/admin/shutdown
HTTP/1.1 202 Accepted
Content-Length: 14

shutting down
```

程序自己的输出,请求后约 0.05s:

```text
listening on http://127.0.0.1:8080
shutdown requested, draining
drained, bye
```

handler 里那次 `send` 发给 def 类型的参数,三个目标都能编译。`wait()` 等的是每连接一条 `done`:在途请求跑到各自的应答,空闲的 keep-alive 连接经空闲超时终结——设了上面的 `with_idle_timeout(5.0)`,一台挂着一个空闲浏览器标签页的服务器在 stop 后 5s 排干;什么超时都不设,它会永远等那个标签页——所以要被停下的服务器,请设空闲超时。

## HTTPS

handler 一字不改——TLS 是监听者的属性。生成一对证书,把 PEM 文件交给 `net.listen_tls`,同一个 `httpd.serve` 说的就是 `https://`:

```console
$ openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem \
    -days 365 -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
```

```emo
require "httpd"
require "net"

const (R.ok, listener) = net.listen_tls("127.0.0.1", 8443, "cert.pem", "key.pem")
const server = httpd.serve(listener) -> (req httpd.Request) {
  return httpd.response(200, [("Content-Type", "text/plain; charset=utf-8")], "hello over https\n")
}
server.wait()
```

```console
$ curl --cacert cert.pem https://localhost:8443/
hello over https
```

真实部署借两样东西,而不是自签对:公共 CA 的证书(从此 curl 不再需要 `--cacert`),以及客户端必须出示证书时的 `net.listen_tls_with` 配 `net.tls_server_options()`——双向 TLS 是监听者的策略,不是服务器的。握不成的客户端——不受信任的证书、打到 TLS 端口上的明文 HTTP——在门口被丢弃,下一条连接照常服务;`examples/https_roundtrip` 钉住的正是这一段。`c` 目标上,链接 TLS 用的是机器的 OpenSSL:链接器找不到时 `emo doctor` 会说明,修法是 `--cclib=-L<目录>` 指向 Homebrew 或系统 OpenSSL 的库目录(从不需要头文件)。

## 线上的严格性,站在 handler 这头看

本指南到此都假设请求是良构的,坏请求在你的 handler 开跑之前就被服务器应答了。拒绝家族,归拢在一处:

| 对端行为 | 应答 |
| --- | --- |
| 请求行不是 `方法 SP 目标 SP 版本` | 400,引用该行 |
| 版本既非 HTTP/1.1 也非 HTTP/1.0 | 400 |
| 头名不是 token(`Host : h`——空格搭在名字上) | 400 |
| HTTP/1.1 请求没有 `Host` | 400 |
| `Content-Length` 不是计数,或与 `Transfer-Encoding` 并存 | 400 |
| chunk 帧断裂(尺寸不是十六进制、chunk 缺自己的 CRLF) | 400 |
| 逃逸解码出可打印 ASCII 之外,查询或捕获 | 400,点名字节 |
| 头块超过 `with_max_header_bytes` | 431 |
| 请求体超过 `with_max_body_bytes` | 413 |

每一条答完都关闭连接——被服务器拒绝的请求,不是它要继续攀谈的对象。`examples/httpd_wire` 在裸 socket 上走完整张表,三个目标逐字节一致。你 handler 自己的契约是它的镜像:对自己程序的错误断言 raise,对请求的错误断言答 4xx,数据永远不 raise——一次 raise 会让连接进程在对话中途终结,线上一个应答都没有。

## 部署笔记

- **挂在代理后面就绑 `127.0.0.1`,敞开跑就绑 `0.0.0.0`。** 监听者接受 `net` 认的一切主机拼写。前置反向代理(nginx、caddy)替你拿下生产证书对、公网端口和日志采集;应用在回环上说明文 HTTP,一点证书管道都不用碰。
- **应答整体缓冲。** handler 应答一个 `Response` 值,线上因此知道长度——对 API 和页面是好事,对流(SSE、大媒体)是错路,流式要等已点名的 response-writer 形态。内存里的文件同理:`file.read` 把整个资产交给一个 `String`。
- **默认没有 `Date`。** 语言没有时钟;除非你经 `options().with_date(-> () { return date_string() })` 注入一个,线上逐字节确定——块的字符串给每个没自带 `Date` 的响应盖戳。缓存把缺 `Date` 当未知年龄,在会自己补 `Date` 的代理后面这没问题。
- **日志就是 `println`**,或者 `slog` 包的结构化记录——像上面的 `logged` 那样的中间件是天然的位置,每请求一行,而且它跑在连接进程里,从不阻塞别的连接。
- **信号没有接线。** 没有可安装的 `SIGTERM` handler;按[停下一台服务器](#停下一台服务器)的方式停——监督者的 stop 变成那条路由(或者进程终结、内核关掉 socket,那是生硬但诚实的退路)。
- **每连接一进程**也是边界:几千条并发停靠的连接就是几千个调度器进程。这与每连接一线程的服务器记的是同一本账,只是停靠更便宜——下注之前先拿 `benchmarks/http_echo` 量一量。

## 接下来去哪

- `examples/httpd_parse`——纯解析器,十四个夹具,不开 socket 测请求处理。
- `examples/httpd_wire`——keep-alive、chunked + `100 Continue`、HEAD、204,以及裸连接上的整个拒绝家族。
- `examples/httpd_serve`、`examples/httpd_routes`——本指南示例所对照的验收走查。
- `examples/https_roundtrip`——TLS 端到端,坏客户端探针在内。
- [`docs/zh-CN/stdlib/httpd.md`](stdlib/httpd.md)——参考:每个签名、选项、严格性、限制。
- [`docs/zh-CN/stdlib/http.md`](stdlib/http.md)——客户端那一半,给走线的测试,也给服务对服务的调用。
