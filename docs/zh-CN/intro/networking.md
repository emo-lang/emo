# 网络

网络是一等公民：几乎所有现代程序都要联网。Emo 提供统一的异步网络 API。在 `ocaml` 后端上，它运行在与并发运行时同一个 effects 调度器之上——非阻塞 socket 由调度器挂起与唤醒，TLS 由 OpenSSL 绑定提供；在 TypeScript 目标上它跑在 Node 的事件循环上，每次调用由生成代码里的 `await` 落地。`net` 与 `http` 包声明 `targets = ["ocaml", "c", "typescript"]`，依赖解析在其他一切目标上拒绝它们；`c` 目标实现 TCP 与 TLS。

API 是**直接风格**：网络调用看起来像普通的阻塞调用，调度器在底层切换进程。没有 `async`/`await`，因此没有函数着色——任何函数都能做 IO，API 生态保持单轨。超时以秒计，每个失败——连接被拒、名字无法解析、超期、socket 关闭——返回 `(R.error, reason)`，reason 写明对端、操作与原因。

socket 面是标准库的 `net` 包；HTTP 在 `http` 包：

- **Socket。** `net.connect(host, port, timeout)`、`net.connect_unix(path, timeout)`、`net.tls_connect(host, port, timeout)` 与 `net.tls_connect_insecure(host, port, timeout)`——证书验证默认开启，insecure 变体是显式、可见危险的退出——返回 `TcpConn`。`net.tls_connect_with(host, port, timeout, options)` 接收 `net.tls_client_options()` 给出的逐连接策略：私有信任库、用于双向 TLS 的客户端证书，或校验名覆盖。`net.listen(host, port)`、`net.listen_unix(path)`、`net.listen_tls(host, port, cert_path, key_path)` 与 `net.listen_tls_with(host, port, cert_path, key_path, options)` 返回 `TcpListener`；`net.udp_bind(host, port)` 返回 `UdpSocket`；`net.resolve(host)` 把名字解析为地址。完整 API 文档见 [docs/zh-CN/stdlib/net.md](../stdlib/net.md)。
- **连接。** `read_line()`、`read_exactly(n)`、`read_all()`、`write(data)`、`close()`——优雅关闭先投递待写数据。`set_timeout(seconds)` 约束其后的操作（默认无超时；`0.0` 无限等待）。监听者服务 `accept()` 并报告 `port()`；数据报 socket `send_to(host, port, data)` 与 `recv_from()`，并报告 `port()`。
- **HTTP 客户端。** `http.get(url)`、`http.post(url, body)`、`http.put(url, body)`、`http.delete(url)` 与通用的 `http.request(method, url, headers, body, timeout)` 返回携带 `status`、`headers`、`body` 的 `HttpResponse`。`http.request_with(..., tls_options)` 为 `https` URL 加上逐连接 TLS 策略。重定向从不自动跟随：3xx 是和其他一样的响应，跟随它是调用者的显式动作。完整 API 文档见 [docs/zh-CN/stdlib/http.md](../stdlib/http.md)。
- **HTTP 服务器。** `httpd` 包每连接一进程：`httpd.serve(listener) -> (req httpd.Request) { ... }` 应答一个 `Server` 句柄（`stop()` 优雅关闭、`wait()` 等待排干），处理者返回一个 `httpd.Response` 值，`httpd.router()` 经 `httpd.serve_routes` 加上模式路由（`{name}` 通配、子树、带 `Allow` 的 405、清理重定向）。来自 `net.listen_tls`/`listen_tls_with` 的监听者让同一个 handler 以 HTTPS 提供服务。完整 API 文档见 [docs/zh-CN/stdlib/httpd.md](../stdlib/httpd.md)。

分层是常规的：socket（TCP/UDP/Unix 域，加 TLS）住在 `net` 包，HTTP 骑在它上面——客户端在 `http` 包，服务器在 `httpd` 包。TLS 在 `ocaml` 上是 OpenSSL 绑定，在 `c` 上是系统 OpenSSL/LibreSSL，在 `typescript` 上是 Node 的 `tls`。
