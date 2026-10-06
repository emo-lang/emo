# `net` 包

标准库的 socket 包:TCP、UDP、Unix 域 socket、DNS 与 TLS。它是运行时网络 builtin 之上一层薄薄的、可读的 Emo 源码——这里每个函数都只是对 builtin 的一次调用,语义(超时、EOF、错误)就是运行时的语义。本包**仅限原生(native)目标**:manifest 声明了 `targets = ["native"]`,依赖解析在其他一切目标上拒绝它。

网络是**直接风格**:阻塞调用读起来就是普通函数调用,socket 忙碌时调度器把进程挂起。没有 `async`/`await`,没有回调注册。每一种失败——连接被拒、名字解析不出、超过期限、socket 已关——都以普通的 Emo 异常上抛,消息里指明对端、操作与原因。

## 引入

```emo
require "net"
```

`require` 与 manifest 严格配对——`net` 必须在 `package.emo` 里钉版本:

```emo
package {
  name = "acme/myapp"
  version = "0.1.0"
  targets = ["native"]

  deps {
    net = "0.1.0"
  }
}
```

## 函数

```emo
net.resolve(host)                                   // Array[String]
net.connect(host, port, timeout)                    // TcpConn
net.listen(host, port)                              // TcpListener
net.connect_unix(path, timeout)                     // TcpConn
net.listen_unix(path)                               // TcpListener
net.tls_connect(host, port, timeout)                // TcpConn
net.tls_connect_insecure(host, port, timeout)       // TcpConn
net.listen_tls(host, port, cert_path, key_path)     // TcpListener
net.udp_bind(host, port)                            // UdpSocket
```

- `net.resolve(host)` 把名字正向解析为 IP 地址字符串数组;DNS 一无所获时抛出 `` cannot resolve host `...` ``。数字地址解析为其自身。
- `net.connect(host, port, timeout)` 解析并连接,返回 `TcpConn`。`timeout` 以秒计;`0.0` 表示无限等待。连接被拒抛出 `connection refused to host:port`。
- `net.listen(host, port)` 绑定并监听,返回 `TcpListener`。端口 `0` 让内核分配空闲端口,用 `listener.port()` 读回。
- `net.connect_unix(path, timeout)` 与 `net.listen_unix(path)` 是 Unix 域的一对;Unix listener 没有端口。
- `net.tls_connect` 以 TLS 连接并**按系统信任库校验对端证书**——自签证书会让握手失败,失败即拒绝。`net.tls_connect_insecure` 跳过校验;它是显式的、看起来就危险的逃生门,只用于测试与自签开发环境。
- `net.listen_tls(host, port, cert_path, key_path)` 用 PEM 证书/私钥对服务 TLS;证书加载失败抛出精确错误(`` cannot load the TLS certificate for ... ``)。
- `net.udp_bind(host, port)` 绑定数据报 socket;端口 `0` 挑选空闲端口。

## 连接:`TcpConn`

```emo
conn.read_line()          // String —— 一行,不含行尾
conn.read_exactly(n)      // String —— 恰好 n 字节
conn.read_all()           // String —— 直到对端关闭为止的全部
conn.write(data)          // TcpConn —— 返回自身,可链式
conn.close()              // TcpConn
conn.set_timeout(seconds) // TcpConn —— 约束其后的操作
```

- **EOF 永远不会是静默的部分结果。** `read_line` 剥掉 `\n`(以及前面的 `\r`);行边界上的干净关闭返回 `""`,但**行中途关闭是错误**(`the connection to ... closed mid-line`)。`read_exactly(n)` 在对端提前关闭时抛出(`closed after M of N bytes`)。`read_all` 是唯一把 EOF 视为正常的读:它交付已到达的全部,包括空。
- `write(data)` 写整个字符串(字节而非字符——Emo 字符串是字节串),并返回连接本身,所以 `conn.write(a).write(b)` 可链式。优雅的 `close()` 会先交付未发完的写。
- `set_timeout(seconds)` 为其后的读写设置**按操作计**的期限:预算在每个操作开始时计算,多步读取共享一份预算。`0.0`——默认值——表示不超时;负数是错误。超过期限抛出 `timed out ...`。

## 监听器:`TcpListener`

```emo
listener.accept()           // TcpConn —— 下一个连接
listener.port()             // Int64 —— 绑定的端口
listener.close()            // TcpListener
listener.set_timeout(seconds)
```

`accept()` 挂起直到有连接到达。**Unix 域 listener 调 `port()` 是错误**(`a unix-domain listener (...) has no port`)——它没有端口可报。`set_timeout` 以同样方式约束 `accept()`。

## 数据报:`UdpSocket`

```emo
socket.send_to(host, port, data)  // UdpSocket —— 返回自身
socket.recv_from()                // (String, String, Int64) —— 数据、主机、端口
socket.port()                     // Int64
socket.close()                    // UdpSocket
socket.set_timeout(seconds)
```

`recv_from()` 等待一个数据报,返回 `(data, host, port)` 元组——用 `case` 解构。`send_to` 每次调用都按名字解析对端。

## 示例

一个程序里的 TCP echo 往返——服务器跑在自己的进程里(`do`),客户端与它对话:

```emo
require "net"

def echo_once(listener TcpListener) Int64 {
  const conn = listener.accept()
  conn.write("echo: " + conn.read_line() + "\n")
  conn.close()
  return 0
}

const listener = net.listen("127.0.0.1", 0)
do echo_once(listener)

const conn = net.connect("127.0.0.1", listener.port(), 5.0)
conn.set_timeout(5.0)
conn.write("hello\n")
println(conn.read_line())  // echo: hello
conn.close()
```

UDP,两端都在 loopback:

```emo
require "net"

const a = net.udp_bind("127.0.0.1", 0)
const b = net.udp_bind("127.0.0.1", 0)

a.send_to("127.0.0.1", b.port(), "ping")
case b.recv_from() {
  (data, host, port) -> {
    println(data + " from " + host + ":" + port.to_string())
  }
}
b.close()
a.close()
```

自签证书的 TLS(开发环境写法——生产客户端用会校验的 `net.tls_connect`):

```emo
require "net"

def serve(listener TcpListener) Int64 {
  const conn = listener.accept()
  conn.write("secure: " + conn.read_line() + "\n")
  conn.close()
  return 0
}

const listener = net.listen_tls("127.0.0.1", 0, "tls-cert.pem", "tls-key.pem")
do serve(listener)

const conn = net.tls_connect_insecure("localhost", listener.port(), 5.0)
conn.write("hello\n")
println(conn.read_line())  // secure: hello
conn.close()
```

## 限制

- **仅限原生目标**——`targets = ["native"]`;wasm、TypeScript、BEAM 构建在解析期被拒绝。
- **DNS 只有正向解析,且在调度循环内同步执行**——`getaddrinfo` 期间整个循环阻塞;没有反向解析。
- **UDP 只有非连接的收发**——没有 `connect` 式数据报,没有组播,没有广播助手。
- **没有原始 socket,没有 socket 选项**——超出上面操作暴露范围的一律没有。
