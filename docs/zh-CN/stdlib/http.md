# `http` 包

标准库的 HTTP 客户端,用纯 Emo 写在 `net` 包之上。通篇直接风格:一次请求读起来就是普通函数调用,socket 忙碌时调度器在底层挂起进程。提供 HTTP 服务是 [`httpd`](stdlib/httpd.md) 包的那半边。本包声明 `ocaml`、`c` 与 `typescript` 三个目标(`targets = ["ocaml", "c", "typescript"]`);依赖解析在其他一切目标上拒绝它。`https://` 在三者之上都走 `net` 的 TLS——`ocaml` 上是 ocaml-ssl,`typescript` 上是 `node:tls`,`c` 上是系统 OpenSSL/LibreSSL(覆盖面细节见 `net` 包文档)。

## 引入

```emo
require "http"
```

标准库随编译器一起发布,但它的包和其他依赖一样带版本:`require "http"` 需要在 manifest 的 `deps` 块里钉上 `"http" = "0.1.0"`;它依赖的 `net` 由 `http` 自己的 manifest 带入。本包声明 `ocaml`、`c`、`typescript` 三个目标。

## 客户端

动词助手覆盖常见场景;通用形式把每个开关都显式列出:

```emo
http.get(url)                                // GET,无 body
http.post(url, body)                         // POST,带 body
http.put(url, body)                          // PUT,带 body
http.delete(url)                             // DELETE,无 body
http.request(method, url, headers, body, timeout)
http.request_with(method, url, headers, body, timeout, tls_options)
```

`http.request` 的完整签名:

```emo
def request(method String, url String, headers Array[(String, String)], body String, timeout Float64) (R, HttpResponse)
```

- `headers` 是 `(name, value)` 元组的数组,追加在内置的 `Host`、`Content-Length`、`Connection: close` 几行之后。
- `timeout` 以秒为单位,传给 `net.connect` / `net.tls_connect`;`0.0`(动词助手用的值)表示无限等待。
- URL 必须带显式的 `http://` 或 `https://` scheme,其他一律以错误元组返回——`net` 包上报的每种传输失败同理:匹配这个元组,别假设响应已到手。`https://` 走 `net.tls_connect`——TLS 且按 `net` 包的默认开启证书校验。默认端口 80 与 443;`host:port` 可覆盖。

成功时以 `(R.ok, resp)` 回答一个 `HttpResponse`:

```emo
class HttpResponse {
  // 字段:status Int64, headers Array[(String, String)], body String
  def header(name String) String   // 大小写不敏感查找;不存在时返回 ""
}
```

`http.request_with` 就是 `http.request` 加上逐连接 TLS 策略:`tls_options` 是 `net.tls_client_options()` 给出的 `net.TlsClientOptions`(`with_ca_file`、`with_client_certificate`、`with_server_name`、`without_verification`),`https://` URL 经 `net.tls_connect_with` 连接。普通 `http://` URL 没有 TLS 环节,所以策略只作用于 `https`。

```emo
require "http"

case http.get("http://127.0.0.1:8901/hello.txt") {
  (R.error, why) then { println("request failed: ${why}") }
  (R.ok, resp)   then {
    println(resp.status)                 // 200
    println(resp.header("content-type")) // text/plain
    println(resp.body)
  }
}
```

重定向从不自动跟随:3xx 和其他响应一样原样返回,跟随它(读 `resp.header("location")` 再发下一个请求)是调用者显式、可见的动作。

每个请求开一条连接、交换完即关——客户端永远发送 `Connection: close`,所以没有连接池需要操心。

## 限制

- **三个目标。** 包声明了 `targets = ["ocaml", "c", "typescript"]`;wasm、BEAM、riscv64 构建在解析期就会被拒绝。在 `c` 上 UDP 与 Unix 域 socket 仍被拒绝(继承自 `net`),名字只解析为 IPv4 地址;`https` 可用。
- **无连接池。** 每个请求一条 TCP 连接,交换完即关。
- **不跟随重定向。** 3xx 响应原样返回。
- **按 `Content-Length` 读响应。** 没有该头的响应按连接剩余字节读取。
- **无 header 折行、trailer 与压缩**——header 按扁平的 `Name: value` 行读取。
