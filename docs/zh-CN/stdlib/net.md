# `net` 包

标准库的 socket 包:TCP、UDP、Unix 域 socket、DNS 与 TLS。它是运行时网络实现之上一层薄薄的、可读的 Emo 源码——这里每个函数都只是对运行时实现的一次调用,语义(超时、EOF、错误)就是运行时的语义。本包声明 `ocaml`、`c` 与 `typescript` 三个目标(`targets = ["ocaml", "c", "typescript"]`);依赖解析在其他一切目标上拒绝它。各目标覆盖面不同:`ocaml` 与 `typescript` 实现完整能力,`c` 只实现 TCP——UDP、Unix 域 socket、`net.resolve` 与 TLS 在 `c` 上运行时被拒绝。

网络是**直接风格**:阻塞调用读起来就是普通函数调用,socket 忙碌时调度器把进程挂起。没有 `async`/`await`,没有回调注册。每一种失败——连接被拒、名字解析不出、超过期限、socket 已关——都以 `(R.error, reason)` 返回:reason 是 String,写明操作、对端与原因。用 `case` 匹配它,别让它崩掉进程。

## 引入

```emo
require "net"
```

标准库随编译器一起发布,但它的包和其他依赖一样带版本:`require "net"` 需要在 manifest 的 `deps` 块里钉上 `"net" = "0.1.0"`。本包声明 `ocaml`、`c`、`typescript` 三个目标。

## 函数

```emo
net.resolve(host)                                   // (R, Array[String])
net.connect(host, port, timeout)                    // (R, TcpConn)
net.listen(host, port)                              // (R, TcpListener)
net.connect_unix(path, timeout)                     // (R, TcpConn)
net.listen_unix(path)                               // (R, TcpListener)
net.tls_connect(host, port, timeout)                // (R, TcpConn)
net.tls_connect_insecure(host, port, timeout)       // (R, TcpConn)
net.listen_tls(host, port, cert_path, key_path)     // (R, TcpListener)
net.udp_bind(host, port)                            // (R, UdpSocket)
```

- `net.resolve(host)` 把名字正向解析为 IP 地址字符串数组;DNS 一无所获时以错误元组回答(``cannot resolve host `...` ``)。数字地址解析为其自身。
- `net.connect(host, port, timeout)` 解析并连接,以 `(R.ok, conn)` 回答 `TcpConn`。`timeout` 以秒计;`0.0` 表示无限等待。连接被拒是错误元组(`connection refused to host:port`)。
- `net.listen(host, port)` 绑定并监听,回答 `TcpListener`。端口 `0` 让内核分配空闲端口,用 `listener.port()` 读回。
- `net.connect_unix(path, timeout)` 与 `net.listen_unix(path)` 是 Unix 域的一对;Unix listener 没有端口。
- `net.tls_connect` 以 TLS 连接并**按系统信任库校验对端证书**——自签证书会让握手失败,失败即错误元组。`net.tls_connect_insecure` 跳过校验;它是显式的、看起来就危险的逃生门,只用于测试与自签开发环境。
- `net.listen_tls(host, port, cert_path, key_path)` 用 PEM 证书/私钥对服务 TLS;证书加载失败以精确 reason 报错(``cannot load the TLS certificate for ... ``)。
- `net.udp_bind(host, port)` 绑定数据报 socket;端口 `0` 挑选空闲端口。

## 连接:`TcpConn`

```emo
conn.read_line()          // (R, String) —— 一行,不含行尾
conn.read_exactly(n)      // (R, String) —— 恰好 n 字节
conn.read_all()           // (R, String) —— 直到对端关闭为止的全部
conn.write(data)          // (R, TcpConn) —— 经解构的 (R.ok, conn) 链式
conn.close()              // (R, TcpConn)
conn.set_timeout(seconds) // TcpConn —— 约束其后的操作
```

- **EOF 永远不会是静默的部分结果。** `read_line` 剥掉 `\n`(以及前面的 `\r`);行边界上的干净关闭返回 `(R.ok, "")`,但**行中途关闭是错误元组**(`the connection to ... closed mid-line`)。`read_exactly(n)` 在对端提前关闭时以 reason 失败(`closed after M of N bytes`)。`read_all` 是唯一把 EOF 视为正常的读:它交付已到达的全部,包括空。
- `write(data)` 写整个字符串(字节而非字符——Emo 字符串是字节串),并回答连接本身,写经解构出的 `(R.ok, conn)` 链下去。优雅的 `close()` 会先交付未发完的写。
- `set_timeout(seconds)` 为其后的读写设置**按操作计**的期限:预算在每个操作开始时计算,多步读取共享一份预算。`0.0`——默认值——表示不超时;负数是错误。超过期限是错误元组(`timed out ...`)。

## 监听器:`TcpListener`

```emo
listener.accept()           // (R, TcpConn) —— 下一个连接
listener.port()             // Int64 —— 绑定的端口
listener.close()            // (R, TcpListener)
listener.set_timeout(seconds)
```

`accept()` 挂起直到有连接到达。**Unix 域 listener 调 `port()` 是错误**(`a unix-domain listener (...) has no port`)——它没有端口可报。`set_timeout` 以同样方式约束 `accept()`。

## 数据报:`UdpSocket`

```emo
socket.send_to(host, port, data)  // (R, UdpSocket)
socket.recv_from()                // (R, (String, String, Int64)) —— 数据、主机、端口
socket.port()                     // Int64
socket.close()                    // (R, UdpSocket)
socket.set_timeout(seconds)
```

`recv_from()` 等待一个数据报,以 `(R.ok, (data, host, port))` 回答——外层 `case` 接失败,内层元组解载荷。`send_to` 每次调用都按名字解析对端。

## 示例

一个程序里的 TCP echo 往返——服务器跑在自己的进程里(`do`),客户端与它对话。失败用 `case` 接住,正常路径走 `(R.ok, ...)`:

```emo
require "net"

def echo_once(listener TcpListener) Int64 {
  case listener.accept() {
    (R.error, why) -> { println("accept failed: ${why}") }
    (R.ok, conn)   -> {
      case conn.read_line() {
        (R.error, why) -> { println("read failed: ${why}") }
        (R.ok, line)   -> {
          conn.write("echo: ${line}\n")
          conn.close()
        }
      }
    }
  }
  return 0
}

const (R.ok, listener) = net.listen("127.0.0.1", 0)
do echo_once(listener)

case net.connect("127.0.0.1", listener.port(), 5.0) {
  (R.error, why) -> { println("connect failed: ${why}") }
  (R.ok, conn)   -> {
    conn.set_timeout(5.0)
    conn.write("hello\n")
    case conn.read_line() {
      (R.error, why) -> { println("read failed: ${why}") }
      (R.ok, line)   -> { println(line) }  // echo: hello
    }
    conn.close()
  }
}
```

UDP,两端都在 loopback:

```emo
require "net"

const (R.ok, a) = net.udp_bind("127.0.0.1", 0)
const (R.ok, b) = net.udp_bind("127.0.0.1", 0)

a.send_to("127.0.0.1", b.port(), "ping")
case b.recv_from() {
  (R.error, why)             -> { println("recv failed: ${why}") }
  (R.ok, (data, host, port)) -> {
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
  case listener.accept() {
    (R.error, why) -> { println("accept failed: ${why}") }
    (R.ok, conn)   -> {
      conn.write("secure: hello\n")
      conn.close()
    }
  }
  return 0
}

const (R.ok, listener) = net.listen_tls("127.0.0.1", 0, "tls-cert.pem", "tls-key.pem")
do serve(listener)

case net.tls_connect_insecure("localhost", listener.port(), 5.0) {
  (R.error, why) -> { println("connect failed: ${why}") }
  (R.ok, conn)   -> {
    conn.write("hello\n")
    case conn.read_line() {
      (R.error, why) -> { println("read failed: ${why}") }
      (R.ok, line)   -> { println(line) }  // secure: hello
    }
    conn.close()
  }
}
```

## 限制

- **三个目标**——`targets = ["ocaml", "c", "typescript"]`;wasm、BEAM、riscv64 构建在解析期被拒绝。`c` 只实现 TCP,其余操作在 `c` 上运行时被拒绝。
- **DNS 只有正向解析。** 在 `ocaml` 上它在调度循环内同步执行——`getaddrinfo` 期间整个循环阻塞;在 `typescript` 上由 Node 的解析器在事件循环中执行。没有反向解析。
- **TLS 的原因文本来自各自的库**——`ocaml` 上是 OpenSSL,`typescript` 上是 Node;两者的证书验证默认都开启。
- **UDP 只有非连接的收发**——没有 `connect` 式数据报,没有组播,没有广播助手。
- **没有原始 socket,没有 socket 选项**——超出上面操作暴露范围的一律没有。
