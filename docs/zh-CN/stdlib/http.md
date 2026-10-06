# `http` 包

标准库的 HTTP 客户端与服务器,用纯 Emo 写在 `net` 包之上。通篇直接风格:一次请求读起来就是普通函数调用,socket 忙碌时调度器在底层挂起进程。本包**仅限原生(native)目标**——它的 manifest 声明了 `targets = ["native"]`,依赖解析在其他一切目标上拒绝它。

## 引入

```emo
require "http"
```

`require` 与 manifest 严格配对:`http` 必须在 `package.emo` 里钉版本;如果程序直接碰 listener 或连接,`net` 也要一并钉上:

```emo
package {
  name = "acme/myapp"
  version = "0.1.0"
  targets = ["native"]

  deps {
    http = "0.1.0"
    net = "0.1.0"
  }
}
```

## 客户端

动词助手覆盖常见场景;通用形式把每个开关都显式列出:

```emo
http.get(url)                                // GET,无 body
http.post(url, body)                         // POST,带 body
http.put(url, body)                          // PUT,带 body
http.delete(url)                             // DELETE,无 body
http.request(method, url, headers, body, timeout)
```

`http.request` 的完整签名:

```emo
def request(method String, url String, headers Array[(String, String)], body String, timeout Float64) HttpResponse
```

- `headers` 是 `(name, value)` 元组的数组,追加在内置的 `Host`、`Content-Length`、`Connection: close` 几行之后。
- `timeout` 以秒为单位,传给 `net.connect` / `net.tls_connect`;`0.0`(动词助手用的值)表示无限等待。
- URL 必须带显式的 `http://` 或 `https://` scheme,其他一律 raise。`https://` 走 `net.tls_connect`——TLS 且按 `net` 包的默认开启证书校验。默认端口 80 与 443;`host:port` 可覆盖。

每次调用返回一个 `HttpResponse`:

```emo
class HttpResponse {
  // 字段:status Int64, headers Array[(String, String)], body String
  def header(name String) String   // 大小写不敏感查找;不存在时返回 ""
}
```

```emo
require "http"

const resp = http.get("http://127.0.0.1:8901/hello.txt")
println(resp.status)                 // 200
println(resp.header("content-type")) // text/plain
println(resp.body)
```

重定向从不自动跟随:3xx 和其他响应一样原样返回,跟随它(读 `resp.header("location")` 再发下一个请求)是调用者显式、可见的动作。

每个请求开一条连接、交换完即关——客户端永远发送 `Connection: close`,所以没有连接池需要操心。

## 服务端

两个助手,都建立在 `net.listen(host, port)` 给出的 `TcpListener` 之上:

- `http.serve(listener) -> (conn TcpConn) { ... }`——每连接一进程的助手。每个 accepted 连接运行自己的进程,handler 拿到的是原始连接:读请求、写响应字节都是 handler 的活。handler 返回时连接关闭。
- `http.serve_requests(listener) -> (req HttpRequest) { ... }`——请求级服务器。每条连接上的请求被解析成 `HttpRequest` 交给 handler,handler 返回的 `HttpResponse` 被写回;每次交换后连接关闭。

多数 handler 要的是 `serve_requests`。请求值:

```emo
class HttpRequest {
  // 字段:method String, path String, headers Array[(String, String)], body String
  def header(name String) String   // 大小写不敏感查找;不存在时返回 ""
}
```

`body` 按请求的 `Content-Length` 读取;没有该头的请求得到 `""`。

响应用 `http.response` 工厂构造:

```emo
def response(status Int64, headers Array[(String, String)], body String) HttpResponse
```

服务器会根据 body 写出 `Content-Length`,并为常见状态码(200、201、204、400、404、500)写出 reason phrase。

一个完整的服务器:

```emo
require "http"
require "net"

const listener = net.listen("127.0.0.1", 8902)
println("listening on http://127.0.0.1:8902")

http.serve_requests(listener) -> (req HttpRequest) {
  println(req.method + " " + req.path)
  return http.response(200, [("Content-Type", "text/plain")], "hello from emo\n")
}
```

两个 serve 助手都无限循环;可以直接把它当作程序的主工作来跑,也可以放在 `do` 下让当前进程空出来——这也是客户端与服务器同住一个程序的写法:

```emo
require "http"
require "net"

const listener = net.listen("127.0.0.1", 0)

do http.serve_requests(listener) -> (req HttpRequest) {
  return http.response(201, [], req.method + " " + req.path + " " + req.body)
}

const resp = http.request("POST", "http://127.0.0.1:" + listener.port().to_string() + "/items", [("Content-Type", "text/plain")], "payload", 5.0)
println(resp.status) // 201
println(resp.body)   // POST /items payload
```

## 限制

- **仅限原生目标。** 包声明了 `targets = ["native"]`;wasm、TypeScript、BEAM 构建在解析期就会被拒绝。
- **无连接池。** 每个请求一条 TCP 连接,交换完即关。
- **不跟随重定向。** 3xx 响应原样返回。
- **HTTP/1.1,`Content-Length`  body。** 没有 `Content-Length` 头的请求与响应,body 按连接剩余字节读取(客户端)或视为空(服务端);不支持 chunked 传输编码。
- **无 header 折行、trailer 与压缩**——header 按扁平的 `Name: value` 行读取。
